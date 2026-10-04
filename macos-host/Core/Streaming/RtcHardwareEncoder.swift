import CoreMedia
import CoreVideo
import Foundation
@preconcurrency import LiveKitWebRTC
import VideoToolbox

/// Attempt-local cumulative stage totals. All ages use the Mac monotonic clock;
/// none is a tablet one-way or physical display latency measurement.
final class RtcPerformanceCounters: @unchecked Sendable {
  private let lock = NSLock()
  private let edgesMs: [UInt64] = [1, 2, 4, 8, 12, 16, 24, 32, 40, 48, 56, 64, 80, 100]
  private var sourceAge = [Int](repeating: 0, count: 15)
  private var vtAge = [Int](repeating: 0, count: 15)
  private var deliveryAge = [Int](repeating: 0, count: 15)
  private var sourceCallAge = [Int](repeating: 0, count: 15)
  private var completeGap = [Int](repeating: 0, count: 15)
  private var sourceCallbacks = 0
  private var sourceNonComplete = 0
  private var sourceComplete = 0
  private var sourceForwarded = 0
  private var encoderEntry = 0
  private var vtAdmission = 0
  private var creditDrop = 0
  private var pausedDrop = 0
  private var vtDrop = 0
  private var vtOutput = 0
  private var sdkAccepted = 0
  private var sdkRejected = 0
  private var pending = 0
  private var pendingPeak = 0
  private var rateUpdates = 0
  private var rateZero = 0
  private var bitrateKbps = 0
  private var requestedFPS = 0
  private var encoderMode = -1
  private var encoderMaxKbps = 0
  private var encoderStartKbps = 0

  private func add(_ ns: UInt64, to counts: inout [Int]) {
    let ms = ns / 1_000_000
    let bucket = edgesMs.firstIndex(where: { ms <= $0 }) ?? edgesMs.count
    counts[bucket] += 1
  }
  private func p95(_ counts: [Int]) -> String {
    let count = counts.reduce(0, +)
    guard count > 0 else { return "unavailable" }
    let threshold = (count * 95 + 99) / 100
    var seen = 0
    for (index, value) in counts.enumerated() {
      seen += value
      if seen >= threshold { return index < edgesMs.count ? "<=\(edgesMs[index])" : ">100" }
    }
    return ">100"
  }
  func received(complete: Bool, gapNs: UInt64?) {
    lock.withLock {
      sourceCallbacks += 1
      if complete { sourceComplete += 1 } else { sourceNonComplete += 1 }
      if let gapNs { add(gapNs, to: &completeGap) }
    }
  }
  func forwarded() { lock.withLock { sourceForwarded += 1 } }
  func sourceCall(_ ns: UInt64) { lock.withLock { add(ns, to: &sourceCallAge) } }
  func started(mode: Int, startKbps: Int, maxKbps: Int) {
    lock.withLock { encoderMode = mode; encoderStartKbps = startKbps; encoderMaxKbps = maxKbps }
  }
  func entered(sourceAgeNs: UInt64?, pending depth: Int) {
    lock.withLock {
      encoderEntry += 1
      pendingPeak = max(pendingPeak, depth)
      if let sourceAgeNs { add(sourceAgeNs, to: &sourceAge) }
    }
  }
  func admitted(pending depth: Int) {
    lock.withLock { vtAdmission += 1; pending = depth; pendingPeak = max(pendingPeak, depth) }
  }
  func droppedCredit() { lock.withLock { creditDrop += 1 } }
  func droppedPaused() { lock.withLock { pausedDrop += 1 } }
  func droppedVT(pending depth: Int) { lock.withLock { vtDrop += 1; pending = depth } }
  func output(vtAgeNs: UInt64, pending depth: Int) {
    lock.withLock { vtOutput += 1; pending = depth; add(vtAgeNs, to: &vtAge) }
  }
  func delivered(accepted: Bool, ageNs: UInt64) {
    lock.withLock {
      if accepted { sdkAccepted += 1 } else { sdkRejected += 1 }
      add(ageNs, to: &deliveryAge)
    }
  }
  func released(pending depth: Int) { lock.withLock { pending = depth } }
  func rate(kbps: UInt32, fps: UInt32, paused: Bool) {
    lock.withLock {
      rateUpdates += 1
      if paused { rateZero += 1 }
      bitrateKbps = Int(kbps); requestedFPS = Int(fps)
    }
  }
  func summary() -> String {
    lock.withLock {
      "RTC sourceCallbacks=\(sourceCallbacks) sourceComplete=\(sourceComplete)"
        + " nonComplete=\(sourceNonComplete) forwarded=\(sourceForwarded)"
        + " encoderEntry=\(encoderEntry) vtAdmit=\(vtAdmission)"
        + " creditDrop=\(creditDrop) pausedDrop=\(pausedDrop)"
        + " vtDrop=\(vtDrop) vtOutput=\(vtOutput)"
        + " sdkAccept=\(sdkAccepted) sdkReject=\(sdkRejected)"
        + " frameCredits=\(pending) frameCreditsPeak=\(pendingPeak)"
        + " completeGapP95ms=\(p95(completeGap)) sourceCallP95ms=\(p95(sourceCallAge))"
        + " sourceToEntryP95ms=\(p95(sourceAge)) vtP95ms=\(p95(vtAge))"
        + " callbackToSDKP95ms=\(p95(deliveryAge))"
        + " encoderMode=\(encoderMode) startKbps=\(encoderStartKbps)"
        + " maxKbps=\(encoderMaxKbps) rateKbps=\(bitrateKbps)"
        + " requestedFPS=\(requestedFPS) rateUpdates=\(rateUpdates) zeroRate=\(rateZero)"
    }
  }
}

/// One credit owns a frame from VT admission through SDK delivery/discard.
/// VT may call inline or after a synchronous drop: opaque IDs never dereference a stale pointer.
struct RtcCallbackRegistry<Value> {
  enum Completion {
    case ignored, failed, dropped, ready(Value)
  }
  private var next: UInt = 1
  private var entries: [UInt: Value] = [:]
  private var delivering = Set<UInt>()
  var count: Int { entries.count + delivering.count }
  var isEmpty: Bool { entries.isEmpty && delivering.isEmpty }
  mutating func begin(_ value: Value, limit: Int = 4) -> UnsafeMutableRawPointer? {
    guard count < limit, next < UInt.max,
      let pointer = UnsafeMutableRawPointer(bitPattern: next) else {
      return nil
    }
    entries[next] = value
    next += 1
    return pointer
  }
  mutating func finish(_ pointer: UnsafeMutableRawPointer?) -> Value? {
    guard let pointer else { return nil }
    return entries.removeValue(forKey: UInt(bitPattern: pointer))
  }
  mutating func callback(_ pointer: UnsafeMutableRawPointer?, status: OSStatus,
                         flags: VTEncodeInfoFlags, hasSample: Bool) -> Completion {
    guard let pointer, let value = entries[UInt(bitPattern: pointer)] else { return .ignored }
    if status != noErr {
      _ = finish(pointer)
      return .failed
    }
    if flags.contains(.frameDropped) || !hasSample {
      _ = finish(pointer)
      return .dropped
    }
    return .ready(value)
  }
  mutating func transferToDelivery(_ pointer: UnsafeMutableRawPointer?) -> Value? {
    guard let pointer else { return nil }
    let id = UInt(bitPattern: pointer)
    guard let value = entries.removeValue(forKey: id) else { return nil }
    delivering.insert(id)
    return value
  }
  @discardableResult mutating func finishDelivery(_ id: UInt) -> Bool {
    delivering.remove(id) != nil
  }
  mutating func discardAll() {
    entries.removeAll()
    delivering.removeAll()
  }
}

/// Never offer a software or alternate-profile encoder. WebRTC owns rate/keyframe decisions.
final class RtcHardwareEncoderFactory: NSObject, LKRTCVideoEncoderFactory {
  private let onFailure: @Sendable (String) -> Void
  private let counters: RtcPerformanceCounters?
  init(counters: RtcPerformanceCounters? = nil, onFailure: @escaping @Sendable (String) -> Void) {
    self.counters = counters
    self.onFailure = onFailure
  }
  private static func format() -> LKRTCVideoCodecInfo { LKRTCVideoCodecInfo(name: "H264", parameters: [
    "profile-level-id": "640034", "level-asymmetry-allowed": "1", "packetization-mode": "1",
  ]) }
  func supportedCodecs() -> [LKRTCVideoCodecInfo] { [Self.format()] }
  func createEncoder(_ info: LKRTCVideoCodecInfo) -> (any LKRTCVideoEncoder)? {
    guard info.name.caseInsensitiveCompare("H264") == .orderedSame,
      info.parameters["profile-level-id"]?.lowercased() == "640034",
      info.parameters["packetization-mode"] == "1" else { return nil }
    return RtcHardwareEncoder(counters: counters, onFailure: onFailure)
  }
}

/// An actual hardware-required VT session (not a separate capability probe).
/// VT callbacks own their frame stamp until consumed; release waits for outstanding callbacks.
final class RtcHardwareEncoder: NSObject, LKRTCVideoEncoder, @unchecked Sendable {
  private struct VTProperty {
    let key: CFString
    let value: CFTypeRef
    let stage: String
  }
  static func hardwareFramerate(_ requested: UInt32) -> UInt32? {
    guard (1...120).contains(requested) else { return nil }
    return min(requested, 60) // SDK rate control can request 61 from a 60 Hz source.
  }
  private final class Stamp {
    let frame: LKRTCVideoFrame
    let startedNs: UInt64
    let requestedKeyframe: Bool
    init(_ frame: LKRTCVideoFrame, requestedKeyframe: Bool) {
      self.frame = frame
      self.requestedKeyframe = requestedKeyframe
      startedNs = DispatchTime.now().uptimeNanoseconds
    }
  }
  private let lock = NSRecursiveLock()
  private let delivery = DispatchQueue(label: "dev.mirri.rtc.encoder.delivery")
  private let deliveryKey = DispatchSpecificKey<Bool>()
  private var session: VTCompressionSession?
  private var callback: ((LKRTCEncodedImage, any LKRTCCodecSpecificInfo) -> Bool)?
  private var stamps = RtcCallbackRegistry<Stamp>()
  private var releasing = false
  private var forceIDR = true
  private var generation: UInt64 = 0
  private var failed = false
  private var reportedFailure = false
  private var bitrate: UInt32 = 4_000
  private var fps: UInt32 = 60
  private var paused = false
  private let counters: RtcPerformanceCounters?
  private let onFailure: @Sendable (String) -> Void

  init(counters: RtcPerformanceCounters? = nil, onFailure: @escaping @Sendable (String) -> Void) {
    self.counters = counters
    self.onFailure = onFailure
    super.init()
    delivery.setSpecific(key: deliveryKey, value: true)
  }
  private func fail(_ stage: String) {
    failed = true
    if !reportedFailure { reportedFailure = true; onFailure(stage) }
  }

  func setCallback(_ callback: ((LKRTCEncodedImage, any LKRTCCodecSpecificInfo) -> Bool)?) {
    lock.lock(); defer { lock.unlock() }
    self.callback = callback
  }
  func startEncode(with settings: LKRTCVideoEncoderSettings, numberOfCores: Int32) -> Int {
    lock.lock(); defer { lock.unlock() }
    guard session == nil, !releasing, stamps.isEmpty,
      settings.width == 2456, settings.height == 1600,
      settings.maxFramerate == 60, (1...80_000).contains(settings.startBitrate)
    else { fail("start-settings"); return -1 }
    bitrate = settings.startBitrate
    fps = settings.maxFramerate
    counters?.started(mode: Int(settings.mode.rawValue), startKbps: Int(settings.startBitrate),
      maxKbps: Int(settings.maxBitrate))
    // Low-latency rate control removes ~40 ms of lookahead (the TCP path measured
    // 42 -> 14 ms) and follows SDK rate updates by dropping frames, not by bursting.
    let specification: CFDictionary = [
      kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true,
      kVTVideoEncoderSpecification_EnableLowLatencyRateControl as String: true,
    ] as CFDictionary
    var created: VTCompressionSession?
    guard VTCompressionSessionCreate(allocator: kCFAllocatorDefault, width: 2456, height: 1600,
      codecType: kCMVideoCodecType_H264, encoderSpecification: specification,
      imageBufferAttributes: nil, compressedDataAllocator: nil,
      outputCallback: Self.output, refcon: Unmanaged.passUnretained(self).toOpaque(),
      compressionSessionOut: &created) == noErr, let created else { fail("create-session"); return -1 }
    if let stage = configureSession(created) {
      VTCompressionSessionInvalidate(created)
      fail(stage)
      return -1
    }
    session = created
    failed = false
    reportedFailure = false
    forceIDR = true
    paused = false
    generation &+= 1
    return 0
  }
  /// Apply the actual VT configuration and then prove this session selected hardware.
  private func configureSession(_ created: VTCompressionSession) -> String? {
    let properties: [VTProperty] = [
      VTProperty(key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue, stage: "real-time"),
      VTProperty(key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse,
        stage: "no-reordering"),
      VTProperty(key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_5_2,
        stage: "high52"),
      VTProperty(key: kVTCompressionPropertyKey_ColorPrimaries,
        value: kCVImageBufferColorPrimaries_ITU_R_709_2, stage: "primaries"),
      VTProperty(key: kVTCompressionPropertyKey_TransferFunction,
        value: kCVImageBufferTransferFunction_sRGB, stage: "transfer"),
      VTProperty(key: kVTCompressionPropertyKey_YCbCrMatrix,
        value: kCVImageBufferYCbCrMatrix_ITU_R_709_2, stage: "matrix"),
      VTProperty(key: kVTCompressionPropertyKey_AverageBitRate,
        value: NSNumber(value: bitrate * 1_000), stage: "bitrate"),
      VTProperty(key: kVTCompressionPropertyKey_ExpectedFrameRate,
        value: NSNumber(value: fps), stage: "framerate"),
    ]
    for property in properties {
      guard VTSessionSetProperty(created, key: property.key, value: property.value) == noErr else {
        return property.stage
      }
    }
    guard VTCompressionSessionPrepareToEncodeFrames(created) == noErr else { return "prepare-frames" }
    // The low-latency encoder does not publish this property on this Mac
    // (kVTPropertyNotSupportedErr); creation with RequireHardware already refused
    // software. A readable value must still say hardware.
    var hardware: Unmanaged<CFTypeRef>?
    let query = VTSessionCopyProperty(created,
      key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
      allocator: kCFAllocatorDefault, valueOut: &hardware)
    if query == kVTPropertyNotSupportedErr { return nil }
    guard query == noErr else { return "hardware-property-unavailable" }
    guard (hardware?.takeRetainedValue() as? Bool) == true else { return "hardware-not-selected" }
    return nil
  }
  func encode(_ frame: LKRTCVideoFrame, codecSpecificInfo: (any LKRTCCodecSpecificInfo)?,
              frameTypes: [NSNumber]) -> Int {
    lock.lock(); defer { lock.unlock() }
    let now = DispatchTime.now().uptimeNanoseconds
    counters?.entered(sourceAgeNs: frame.timeStampNs > 0 && UInt64(frame.timeStampNs) <= now
      ? now - UInt64(frame.timeStampNs) : nil, pending: stamps.count)
    guard !failed, let session, frame.width == 2456, frame.height == 1600,
      let buffer = frame.buffer as? LKRTCCVPixelBuffer,
      !buffer.requiresCropping(), !buffer.requiresScaling(toWidth: 2456, height: 1600),
      CVPixelBufferGetPixelFormatType(buffer.pixelBuffer) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    else { fail("frame-input"); return -1 }
    let requested = frameTypes.contains(NSNumber(value: LKRTCFrameType.videoFrameKey.rawValue))
    if requested { forceIDR = true }
    if paused {
      counters?.droppedPaused()
      return 0
    }
    if stamps.count == 4 {
      counters?.droppedCredit()
      return 0 // Keep a requested IDR latched across backpressure.
    }
    let wantKeyframe = forceIDR
    let stamp = Stamp(frame, requestedKeyframe: wantKeyframe)
    let options: CFDictionary? = wantKeyframe
      ? [kVTEncodeFrameOptionKey_ForceKeyFrame as String: true] as CFDictionary : nil
    var flags = VTEncodeInfoFlags()
    guard let pointer = stamps.begin(stamp) else { fail("stamp"); return -1 }
    let result = VTCompressionSessionEncodeFrame(session, imageBuffer: buffer.pixelBuffer,
      presentationTimeStamp: CMTime(value: frame.timeStampNs, timescale: 1_000_000_000),
      duration: .invalid, frameProperties: options, sourceFrameRefcon: pointer,
      infoFlagsOut: &flags)
    if result != noErr {
      // An inline callback may already have consumed this token and published
      // the frame. Do not release it a second time or reinterpret success.
      if stamps.finish(pointer) != nil { fail("encode-frame"); return -1 }
      return failed ? -1 : 0
    }
    if flags.contains(.frameDropped) {
      // A callback can be inline or late; the late one observes no token.
      // A dropped input never entered the reference chain; forcing an IDR here
      // would feed the rate controller a larger frame and more drops.
      if stamps.finish(pointer) != nil {
        counters?.droppedVT(pending: stamps.count)
      }
    } else {
      counters?.admitted(pending: stamps.count)
    }
    return 0
  }
  func setBitrate(_ bitrateKbit: UInt32, framerate: UInt32) -> Int32 {
    lock.lock(); defer { lock.unlock() }
    counters?.rate(kbps: bitrateKbit, fps: framerate,
      paused: bitrateKbit == 0 || framerate == 0)
    guard !failed, let session else { fail("rate-before-start"); return -1 }
    // The pinned bridge accepts UInt32 rates but does not prohibit a zero pause.
    // Keep valid VT properties; resume with a new IDR once both rates are positive.
    if bitrateKbit == 0 || framerate == 0 {
      paused = true
      forceIDR = true
      return 0
    }
    guard (1...80_000).contains(bitrateKbit), let hardwareFPS = Self.hardwareFramerate(framerate) else {
      fail("rate-bound-kbps-\(bitrateKbit)-fps-\(framerate)"); return -1
    }
    guard VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate,
      value: NSNumber(value: bitrateKbit * 1_000)) == noErr else { fail("rate-vt-bitrate"); return -1 }
    guard VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate,
      value: NSNumber(value: hardwareFPS)) == noErr else { fail("rate-vt-fps"); return -1 }
    bitrate = bitrateKbit
    fps = hardwareFPS
    if paused { forceIDR = true }
    paused = false
    return 0
  }
  func release() -> Int {
    let (old, concurrent) = lock.withLock { () -> (VTCompressionSession?, Bool) in
      guard !releasing else { return (nil, true) }
      releasing = true
      let old = session
      session = nil
      generation &+= 1
      return (old, false)
    }
    if concurrent { return -1 }
    guard let old else {
      lock.withLock {
        releasing = false
        callback = nil
        stamps.discardAll()
        counters?.released(pending: 0)
      }
      return 0
    }
    let completed = VTCompressionSessionCompleteFrames(old, untilPresentationTimeStamp: .invalid)
    VTCompressionSessionInvalidate(old)
    // WebRTC delivery is never called inside VT's output callback. Drain any
    // already admitted SDK callbacks before releasing its encoder instance.
    if DispatchQueue.getSpecific(key: deliveryKey) == nil { delivery.sync {} }
    return lock.withLock {
      callback = nil
      let incomplete = !stamps.isEmpty
      // VT is invalidated and the delivery queue is drained. Retire any token
      // for which VT supplied no callback; a stale opaque ID cannot free twice.
      stamps.discardAll()
      counters?.released(pending: 0)
      releasing = false
      return completed == noErr && !incomplete ? 0 : -1
    }
  }
  func implementationName() -> String { "MirriVideoToolboxHardwareH264" }
  func scalingSettings() -> LKRTCVideoEncoderQpThresholds? { nil }
  var resolutionAlignment: Int { 1 }
  var applyAlignmentToAllSimulcastLayers: Bool { false }
  var supportsNativeHandle: Bool { true }

  private static let output: VTCompressionOutputCallback = { ref, frameRef, status, flags, sample in
    guard let ref, let frameRef else { return }
    let encoder = Unmanaged<RtcHardwareEncoder>.fromOpaque(ref).takeUnretainedValue()
    encoder.lock.lock(); defer { encoder.lock.unlock() }
    guard encoder.session != nil, !encoder.releasing, !encoder.failed else {
      _ = encoder.stamps.finish(frameRef)
      return
    }
    let result = encoder.stamps.callback(frameRef, status: status, flags: flags,
      hasSample: sample != nil)
    switch result {
    case .ignored: return
    case .failed:
      encoder.fail("sample-output")
      return
    case .dropped:
      encoder.counters?.droppedVT(pending: encoder.stamps.count)
      return
    case .ready: break
    }
    guard case .ready(let stamp) = result else { return }
    guard let sample, encoder.callback != nil,
      let data = RtcHardwareEncoder.annexB(sample) else {
      _ = encoder.stamps.finish(frameRef)
      encoder.fail("sample-output")
      return
    }
    let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
      as? [[CFString: Any]]
    let key = (attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) != true
    guard !stamp.requestedKeyframe || key else {
      _ = encoder.stamps.finish(frameRef)
      encoder.fail("keyframe")
      return
    }
    guard encoder.stamps.transferToDelivery(frameRef) != nil else { return }
    if key { encoder.forceIDR = false }
    let outputNs = DispatchTime.now().uptimeNanoseconds
    encoder.counters?.output(vtAgeNs: outputNs &- stamp.startedNs,
      pending: encoder.stamps.count)
    let image = LKRTCEncodedImage()
    image.buffer = data
    image.encodedWidth = 2456
    image.encodedHeight = 1600
    image.timeStamp = UInt32(bitPattern: stamp.frame.timeStamp)
    image.captureTimeMs = stamp.frame.timeStampNs / 1_000_000
    image.encodeStartMs = Int64(stamp.startedNs / 1_000_000)
    image.encodeFinishMs = Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000)
    image.frameType = key ? .videoFrameKey : .videoFrameDelta
    image.rotation = stamp.frame.rotation
    let info = LKRTCCodecSpecificInfoH264()
    info.packetizationMode = .nonInterleaved
    let emission = Emission(image: image, info: info)
    let generation = encoder.generation
    let deliveryID = UInt(bitPattern: frameRef)
    encoder.delivery.async { [encoder] in
      defer {
        encoder.lock.withLock {
          _ = encoder.stamps.finishDelivery(deliveryID)
          encoder.counters?.released(pending: encoder.stamps.count)
        }
      }
      let callback = encoder.lock.withLock { () -> ((LKRTCEncodedImage, any LKRTCCodecSpecificInfo) -> Bool)? in
        guard encoder.session != nil, !encoder.failed, !encoder.releasing, !encoder.paused,
          encoder.generation == generation else { return nil }
        return encoder.callback
      }
      if let callback {
        let accepted = callback(emission.image, emission.info)
        encoder.counters?.delivered(accepted: accepted,
          ageNs: DispatchTime.now().uptimeNanoseconds &- outputNs)
        if !accepted { encoder.lock.withLock { encoder.fail("sdk-delivery") } }
      }
    }
  }
  private struct Emission: @unchecked Sendable {
    let image: LKRTCEncodedImage
    let info: LKRTCCodecSpecificInfoH264
  }
  private static func annexB(_ sample: CMSampleBuffer) -> Data? {
    guard let block = CMSampleBufferGetDataBuffer(sample),
      let format = CMSampleBufferGetFormatDescription(sample) else { return nil }
    let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
      as? [[CFString: Any]]
    let key = (attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) != true
    var output = Data()
    if key {
      for index in 0..<2 {
        var pointer: UnsafePointer<UInt8>?
        var length = 0
        guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format,
          parameterSetIndex: index, parameterSetPointerOut: &pointer,
          parameterSetSizeOut: &length, parameterSetCountOut: nil,
          nalUnitHeaderLengthOut: nil) == noErr, let pointer, length > 0 else { return nil }
        // Actual hardware SPS must match the ordinary High 5.2 SDP claim.
        if index == 0 && (length < 4 || pointer[1] != 0x64 || pointer[2] != 0x00 || pointer[3] != 0x34) {
          return nil
        }
        output.append(contentsOf: [0, 0, 0, 1])
        output.append(pointer, count: length)
      }
    }
    let length = CMBlockBufferGetDataLength(block)
    guard length > 4, length < 16_777_216 else { return nil }
    var bytes = Data(count: length)
    let copied = bytes.withUnsafeMutableBytes { raw -> OSStatus in
      guard let destination = raw.baseAddress else { return OSStatus(paramErr) }
      return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length,
        destination: destination)
    }
    guard copied == noErr else { return nil }
    var offset = 0
    while offset + 4 <= bytes.count {
      let size = bytes[offset..<(offset + 4)].reduce(0) { ($0 << 8) | Int($1) }
      offset += 4
      guard size > 0, size <= bytes.count - offset else { return nil }
      output.append(contentsOf: [0, 0, 0, 1])
      output.append(bytes[offset..<(offset + size)])
      offset += size
    }
    return offset == bytes.count ? output : nil
  }
}
