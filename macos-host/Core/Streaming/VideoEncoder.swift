import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

public enum VideoCodec: UInt64, Sendable {
  case avc = 1
  case hevc = 2
  var mediaType: CMVideoCodecType { self == .avc ? kCMVideoCodecType_H264 : kCMVideoCodecType_HEVC }
  var profile: String {
    self == .avc
      ? kVTProfileLevel_H264_High_5_1 as String : kVTProfileLevel_HEVC_Main_AutoLevel as String
  }
  var sets: Int { self == .avc ? 2 : 3 }
}

public struct EncodedUnit: @unchecked Sendable {
  public let accessUnit: Data
  public let parameterSets: [Data]?
  public let keyframe: Bool
  public let pts: UInt64
  public let encodeLatencyMs: Double
  /// Host DispatchTime only; SCK PTS clock/epoch is unverified and not comparable here.
  public let submittedNs: UInt64
  public let captureCallbackNs: UInt64
  public let encoderCallbackNs: UInt64
  public let convertedNs: UInt64
}

public enum HostFrameAge {
  public static func milliseconds(since start: UInt64, until end: UInt64) -> Double? {
    guard start > 0, end >= start else { return nil }
    return Double(end - start) / 1_000_000
  }
}

final class EncodeStamp {
  let start = DispatchTime.now().uptimeNanoseconds
  let captureCallbackNs: UInt64
  init(captureCallbackNs: UInt64) { self.captureCallbackNs = captureCallbackNs }
}

/// Opaque, never-reused refcon tokens; the map owns stamps until callback, failed
/// submission, synchronous drop, or invalidation. No pointer is dereferenced.
/// A token is registered *before* VTEncodeFrame, since VT may call back inline.
/// This counts pending callbacks, NOT retained SCK input surfaces.
/// The experimental four-credit admission gate bounds outstanding stamps even
/// if VT never returns a callback; invalidate clears any remaining entries.
final class PendingVTCallbacks: @unchecked Sendable {
  private let lock = NSLock()
  private var nextToken: Int = 0
  private var stamps: [Int: EncodeStamp] = [:]

  func begin(_ stamp: EncodeStamp) -> UnsafeMutableRawPointer? {
    lock.withLock {
      guard nextToken < Int.max else { return nil }
      nextToken += 1
      stamps[nextToken] = stamp
      return UnsafeMutableRawPointer(bitPattern: nextToken)
    }
  }
  @discardableResult
  func finish(_ token: UnsafeMutableRawPointer?) -> EncodeStamp? {
    guard let token else { return nil }
    return lock.withLock { stamps.removeValue(forKey: Int(bitPattern: token)) }
  }
  func clear() { lock.withLock { stamps.removeAll(keepingCapacity: true) } }
  var count: Int { lock.withLock { stamps.count } }
}

/// The callback is serialized by VideoToolbox, but state is protected for stop/recreation.
public final class VideoEncoder: @unchecked Sendable {
  private let lock = NSLock()
  private let bufferLock = NSLock()
  let pendingCallbacks = PendingVTCallbacks()
  /// Submission-to-callback count, not a measurement of SCK/VT surface retention.
  public var pendingVTCallbacks: Int { pendingCallbacks.count }
  private var annexBBuffers: [Data] = []
  private var session: VTCompressionSession?
  private let codec: VideoCodec
  private let bitrate: UInt32
  private var origin: CMTime?
  private var forceIDR = true
  public var onUnit: (@Sendable (EncodedUnit) -> Void)?
  public var onFailure: (@Sendable () -> Void)?
  public var onSubmissionDuration: (@Sendable (Double) -> Void)?
  public func recycle(_ buffer: Data) {
    bufferLock.lock()
    if annexBBuffers.count < 2 { annexBBuffers.append(buffer) }
    bufferLock.unlock()
  }
  private func reusableBuffer(capacity: Int) -> Data {
    bufferLock.lock()
    var buffer = annexBBuffers.popLast() ?? Data()
    bufferLock.unlock()
    buffer.removeAll(keepingCapacity: true)
    buffer.reserveCapacity(capacity)
    return buffer
  }
  public init(codec: VideoCodec, bitrate: UInt32) {
    self.codec = codec
    self.bitrate = bitrate
  }

  public static func probe(_ codec: VideoCodec) -> Bool {
    let candidate = VideoEncoder(codec: codec, bitrate: codec == .avc ? 40_000_000 : 25_000_000)
    do {
      try candidate.prepare()
      candidate.invalidate()
      return true
    } catch { return false }
  }
  public func prepare() throws {
    lock.lock()
    defer { lock.unlock() }
    guard session == nil else { throw HostFailure.invalidState }
    let options =
      [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true]
      as CFDictionary
    var result: VTCompressionSession?
    let status = VTCompressionSessionCreate(
      allocator: kCFAllocatorDefault, width: 2456, height: 1600,
      codecType: codec.mediaType, encoderSpecification: options, imageBufferAttributes: nil,
      compressedDataAllocator: nil, outputCallback: Self.callback,
      refcon: Unmanaged.passUnretained(self).toOpaque(), compressionSessionOut: &result)
    guard status == noErr, let created = result else { throw HostFailure.hardwareCodec }
    do {
      try Self.set(created, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
      try Self.set(created, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
      try Self.set(created, kVTCompressionPropertyKey_ProfileLevel, codec.profile as CFString)
      try Self.set(
        created, kVTCompressionPropertyKey_ColorPrimaries,
        kCVImageBufferColorPrimaries_ITU_R_709_2)
      try Self.set(
        created, kVTCompressionPropertyKey_TransferFunction,
        kCVImageBufferTransferFunction_sRGB)
      try Self.set(
        created, kVTCompressionPropertyKey_YCbCrMatrix,
        kCVImageBufferYCbCrMatrix_ITU_R_709_2)
      try Self.set(created, kVTCompressionPropertyKey_AverageBitRate, bitrate as CFNumber)
      try Self.set(created, kVTCompressionPropertyKey_MaxKeyFrameInterval, 60 as CFNumber)
      try Self.set(created, kVTCompressionPropertyKey_ExpectedFrameRate, 60 as CFNumber)
      guard VTCompressionSessionPrepareToEncodeFrames(created) == noErr else {
        throw HostFailure.hardwareCodec
      }
      session = created
      origin = nil
      forceIDR = true
    } catch {
      VTCompressionSessionInvalidate(created)
      throw error
    }
  }
  private static func set(_ session: VTCompressionSession, _ key: CFString, _ value: CFTypeRef)
    throws
  {
    guard VTSessionSetProperty(session, key: key, value: value) == noErr else {
      throw HostFailure.hardwareCodec
    }
  }
  public func encode(_ buffer: CVPixelBuffer, time: CMTime, captureCallbackNs: UInt64) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard let session else { return false }
    let first = origin ?? time
    if origin == nil { origin = first }
    let pts = CMTimeSubtract(time, first)
    let force = forceIDR
    let options: CFDictionary? =
      force ? [kVTEncodeFrameOptionKey_ForceKeyFrame as String: true] as CFDictionary : nil
    let stampObject = EncodeStamp(captureCallbackNs: captureCallbackNs)
    let started = stampObject.start
    guard let stamp = pendingCallbacks.begin(stampObject) else { return false }
    var flags = VTEncodeInfoFlags()
    let result = VTCompressionSessionEncodeFrame(
      session, imageBuffer: buffer,
      presentationTimeStamp: pts, duration: CMTime(value: 1, timescale: 60),
      frameProperties: options, sourceFrameRefcon: stamp, infoFlagsOut: &flags)
    let returned = DispatchTime.now().uptimeNanoseconds
    onSubmissionDuration?(Double(returned - started) / 1_000_000)
    let accepted = completeSubmission(result: result, flags: flags, token: stamp)
    if accepted { forceIDR = false }
    return accepted
  }
  /// A callback can precede VTEncodeFrame's return. If it already consumed the
  /// token, the sender/failure path owns the credit; never reject it a second time.
  func completeSubmission(
    result: OSStatus, flags: VTEncodeInfoFlags, token: UnsafeMutableRawPointer
  ) -> Bool {
    if result != noErr {
      return pendingCallbacks.finish(token) == nil
    }
    // SDK reports synchronous drops in infoFlagsOut, but does not promise no
    // callback follows. If one already ran inline it consumed the token;
    // otherwise fail the pipeline rather than strand its capture credit.
    // A later callback for this canceled token is deliberately ignored.
    if flags.contains(.frameDropped) {
      if pendingCallbacks.finish(token) != nil {
        onFailure?()
        return false
      }
    }
    return true
  }
  public func forceKeyframe() {
    lock.lock()
    forceIDR = true
    lock.unlock()
  }
  public func invalidate() {
    // CapturePipeline prepares this encoder once, then stops it; a reconnect
    // constructs a different pipeline/encoder. No same-instance prepare can
    // race with the clear following this instance's VT teardown.
    lock.lock()
    let old = session
    session = nil
    lock.unlock()
    if let old {
      VTCompressionSessionCompleteFrames(old, untilPresentationTimeStamp: .invalid)
      VTCompressionSessionInvalidate(old)
    }
    pendingCallbacks.clear()
  }
  private static let callback: VTCompressionOutputCallback = { ref, frameRef, status, _, sample in
    let callbackNs = DispatchTime.now().uptimeNanoseconds
    guard let ref else { return }
    let encoder = Unmanaged<VideoEncoder>.fromOpaque(ref).takeUnretainedValue()
    guard let stamp = encoder.pendingCallbacks.finish(frameRef) else { return }
    guard status == noErr, let sample else {
      encoder.onFailure?()
      return
    }
    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - stamp.start) / 1e6
    guard
      let unit = encoder.convert(
        sample, latency: elapsed, submittedNs: stamp.start,
        captureCallbackNs: stamp.captureCallbackNs, encoderCallbackNs: callbackNs)
    else {
      encoder.onFailure?()
      return
    }
    encoder.onUnit?(unit)
  }
  private func convert(
    _ sample: CMSampleBuffer, latency: Double, submittedNs: UInt64,
    captureCallbackNs: UInt64, encoderCallbackNs: UInt64
  )
    -> EncodedUnit?
  {
    guard let data = CMSampleBufferGetDataBuffer(sample),
      let array = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
    else { return nil }
    let attachments = (array as? [[CFString: Any]])?.first
    let keyframe = (attachments?[kCMSampleAttachmentKey_NotSync] as? Bool) != true
    let total = CMBlockBufferGetDataLength(data)
    guard total > 4 && total <= 16_777_216 else { return nil }
    var contiguousLength = 0
    var ptr: UnsafeMutablePointer<Int8>?
    let contiguous =
      CMBlockBufferGetDataPointer(
        data, atOffset: 0, lengthAtOffsetOut: &contiguousLength,
        totalLengthOut: nil, dataPointerOut: &ptr) == noErr && contiguousLength == total
    let out: Data?
    if contiguous, let ptr {
      out = annexB(UnsafeRawBufferPointer(start: ptr, count: total))
    } else {
      // VideoToolbox may return a segmented CMBlockBuffer. Copy only this
      // bounded access unit; never assume the first segment covers it all.
      var copied = Data(count: total)
      let status = copied.withUnsafeMutableBytes {
        guard let address = $0.baseAddress else { return kCMBlockBufferBadLengthParameterErr }
        return CMBlockBufferCopyDataBytes(
          data, atOffset: 0, dataLength: total, destination: address)
      }
      guard status == noErr else { return nil }
      out = copied.withUnsafeBytes { annexB($0) }
    }
    guard let out else { return nil }
    var sets: [Data]?
    if keyframe, let format = CMSampleBufferGetFormatDescription(sample) {
      var result: [Data] = []
      for index in 0..<codec.sets {
        var pointer: UnsafePointer<UInt8>?
        var length = 0
        let status: OSStatus
        if codec == .avc {
          status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format,
            parameterSetIndex: index, parameterSetPointerOut: &pointer,
            parameterSetSizeOut: &length, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
        } else {
          status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
            format,
            parameterSetIndex: index, parameterSetPointerOut: &pointer,
            parameterSetSizeOut: &length, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
        }
        guard status == noErr, let pointer, (1...4096).contains(length) else { return nil }
        result.append(Data(bytes: pointer, count: length))
      }
      sets = result
    }
    let pts = CMSampleBufferGetPresentationTimeStamp(sample)
    guard pts.isValid else { return nil }
    return EncodedUnit(
      accessUnit: out, parameterSets: sets, keyframe: keyframe,
      pts: UInt64(max(0, CMTimeGetSeconds(pts)) * 1_000_000_000),
      encodeLatencyMs: latency, submittedNs: submittedNs,
      captureCallbackNs: captureCallbackNs, encoderCallbackNs: encoderCallbackNs,
      convertedNs: DispatchTime.now().uptimeNanoseconds)
  }
  private func annexB(_ input: UnsafeRawBufferPointer) -> Data? {
    let total = input.count
    var out = reusableBuffer(capacity: total)
    var offset = 0
    while offset + 4 <= total {
      let length =
        (Int(input[offset]) << 24) | (Int(input[offset + 1]) << 16)
        | (Int(input[offset + 2]) << 8) | Int(input[offset + 3])
      offset += 4
      guard length > 0 && length <= total - offset else { return nil }
      out.append(contentsOf: [0, 0, 0, 1])
      out.append(contentsOf: input[offset..<(offset + length)])
      offset += length
    }
    guard offset == total else { return nil }
    return out
  }
}
