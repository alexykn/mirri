import CoreMedia
import CoreVideo
import Foundation
@preconcurrency import LiveKitWebRTC
import ScreenCaptureKit

enum RtcPeerEvent: Sendable {
  case candidate(mid: String, index: UInt16, text: String)
  case state(Int)
  case iceState(Int)
  case encoderFailure(String)
  case mediaProof(String)
  case outboundFrames(String)
  case connected
  case failed
}
enum RtcMediaStatus: String, Sendable {
  case ready, waiting, nonUDP, codecOrGeometry
}
enum RtcOutboundGeometry {
  // Some pinned SDK reports omit both dimensions until a continuously changing frame.
  // The hardware encoder input and Android decoded-frame guard still enforce exact size.
  static func accepts(width: Int, height: Int) -> Bool {
    (width == 0 && height == 0) || (width == 2456 && height == 1600)
  }
}

/// One send-only peer/source/capture for one authenticated session attempt.
/// Delegate callbacks carry no wire credentials and are consumed by the attempt owner.
final class RtcPeer: NSObject, LKRTCPeerConnectionDelegate, SCStreamOutput, @unchecked Sendable {
  private struct Description: @unchecked Sendable {
    let value: LKRTCSessionDescription
  }
  private struct Report: @unchecked Sendable {
    let value: LKRTCStatisticsReport
  }
  private final class Once<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    init(_ continuation: CheckedContinuation<Value, Error>) { self.continuation = continuation }
    func finish(_ result: Result<Value, Error>) {
      let continuation = lock.withLock { () -> CheckedContinuation<Value, Error>? in
        let old = self.continuation
        self.continuation = nil
        return old
      }
      continuation?.resume(with: result)
    }
  }
  let events: AsyncStream<RtcPeerEvent>
  private let continuation: AsyncStream<RtcPeerEvent>.Continuation
  private let counters: RtcPerformanceCounters
  private let factory: LKRTCPeerConnectionFactory
  private let source: LKRTCVideoSource
  private let capturer: LKRTCVideoCapturer
  private var peer: LKRTCPeerConnection?
  private var transceiver: LKRTCRtpTransceiver?
  private var stream: SCStream?
  private var starting: Task<Void, Error>?
  private let lock = NSLock()
  private var closed = false
  private var pending: [UUID: () -> Void] = [:]
  private var captureEnabled = false
  private var candidateCount = 0
  private var lastFrameReport = UInt64(0)
  private var lastTimestamp: Int64 = 0
  private var lastOutbound = "SDK outbound unavailable"
  // SCStreamOutput is serialized on the dedicated sampleHandlerQueue below.
  private var lastCompletePTS: CMTime?
  private var limiter = CaptureRateLimiter()
  var videoMid: String? { transceiver?.mid }
  func metricsSummary() -> String {
    let outbound = lock.withLock { lastOutbound }
    return counters.summary() + " / " + outbound
  }
  private func operation<Value: Sendable>(_ start: @escaping (@escaping @Sendable (Result<Value, Error>) -> Void) -> Void)
    async throws -> Value {
    try await withCheckedThrowingContinuation { continuation in
      let once = Once(continuation)
      let id = UUID()
      let open = lock.withLock { () -> Bool in
        guard !closed else { return false }
        pending[id] = { once.finish(.failure(HostFailure.invalidState)) }
        return true
      }
      guard open else { once.finish(.failure(HostFailure.invalidState)); return }
      start { [weak self] result in
        if let self { _ = self.lock.withLock { self.pending.removeValue(forKey: id) } }
        once.finish(result)
      }
    }
  }

  override init() {
    var sink: AsyncStream<RtcPeerEvent>.Continuation!
    events = AsyncStream(bufferingPolicy: .bufferingOldest(68)) { sink = $0 }
    let eventSink = sink!
    continuation = eventSink
    let metrics = RtcPerformanceCounters()
    counters = metrics
    let encoder = RtcHardwareEncoderFactory(counters: metrics, onFailure: { reason in
      eventSink.yield(.encoderFailure(reason))
    })
    factory = LKRTCPeerConnectionFactory(encoderFactory: encoder,
      decoderFactory: LKRTCDefaultVideoDecoderFactory())
    source = factory.videoSource(forScreenCast: true)
    capturer = LKRTCVideoCapturer(delegate: source)
    super.init()
  }
  /// `ceiling` is the configured AVC bitrate. Adaptive: congestion control moves
  /// between the floor and the ceiling. Fixed: floor, start and ceiling coincide.
  /// The floor is where the low-latency encoder still lowers quality instead of
  /// dropping frames: full-screen motion at 2456x1600 lost a third to half of
  /// its frames near 3 Mbit/s and still some at 6, but none from about 7.6.
  func prepare(ceiling: UInt32, adaptive: Bool) throws {
    let floor = adaptive ? min(10_000_000, ceiling) : ceiling
    let configuration = LKRTCConfiguration()
    configuration.iceServers = []
    configuration.tcpCandidatePolicy = .disabled
    configuration.sdpSemantics = .unifiedPlan
    let constraints = LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
    // The delegate must be installed after NSObject initialization.
    guard let peer = factory.peerConnection(with: configuration, constraints: constraints, delegate: self) else {
      throw HostFailure.hardwareCodec
    }
    self.peer = peer
    let initOptions = LKRTCRtpTransceiverInit()
    initOptions.direction = .sendOnly
    // The pinned SDK otherwise initializes this 2456x1600 screen track with a
    // 2.5 Mbit/s maximum. This raises only its ceiling: congestion control may
    // still choose a lower live bitrate, and no minimum/forced BWE is set.
    let encoding = LKRTCRtpEncodingParameters()
    encoding.maxBitrateBps = NSNumber(value: ceiling)
    encoding.minBitrateBps = NSNumber(value: floor)
    encoding.maxFramerate = NSNumber(value: 60)
    initOptions.sendEncodings = [encoding]
    let track = factory.videoTrack(with: source, trackId: "mirri-screen")
    guard let tx = peer.addTransceiver(with: track, init: initOptions) else {
      peer.close()
      throw HostFailure.hardwareCodec
    }
    transceiver = tx
    // The SDK's 300 kbit/s start estimate makes the low-latency encoder drop
    // nearly every 2456x1600 frame until the estimate ramps. This is a LAN start
    // hint only; congestion control still lowers or raises it within the bounds.
    guard peer.setBweMinBitrateBps(NSNumber(value: floor),
      currentBitrateBps: NSNumber(value: adaptive ? min(12_000_000, ceiling) : ceiling),
      maxBitrateBps: NSNumber(value: ceiling)) else {
      peer.close()
      throw HostFailure.hardwareCodec
    }
    let applied = tx.sender.parameters.encodings
    guard applied.count == 1, applied[0].maxBitrateBps?.uint32Value == ceiling,
      applied[0].maxFramerate?.intValue == 60 else {
      peer.close()
      throw HostFailure.hardwareCodec
    }
  }

  func offer() async throws -> String {
    guard let peer, let transceiver else { throw HostFailure.invalidState }
    let codecs = factory.rtpSenderCapabilities(forKind: "video").codecs.filter {
      $0.name.caseInsensitiveCompare("H264") == .orderedSame &&
        $0.parameters["profile-level-id"]?.lowercased() == "640034" &&
        $0.parameters["packetization-mode"] == "1"
    }
    guard codecs.count == 1 else {
      throw HostFailure.hardwareCodec
    }
    try transceiver.setCodecPreferences(codecs, error: ())
    let constraints = LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
    let description: LKRTCSessionDescription = try await operation { resume in
      peer.offer(for: constraints) { sdp, error in
        if let sdp { resume(.success(Description(value: sdp))) }
        else { resume(.failure(error ?? HostFailure.incompatible)) }
      }
    }.value
    let _: Void = try await operation { resume in
      peer.setLocalDescription(description) { error in
        if let error { resume(.failure(error)) } else { resume(.success(())) }
      }
    }
    guard description.sdp.utf8.count <= 32768 else { throw HostFailure.incompatible }
    return description.sdp
  }
  func answer(_ sdp: String) async throws {
    guard let peer else { throw HostFailure.invalidState }
    let description = LKRTCSessionDescription(type: .answer, sdp: sdp)
    let _: Void = try await operation { resume in
      peer.setRemoteDescription(description) { error in
        if let error { resume(.failure(error)) } else { resume(.success(())) }
      }
    }
  }
  func addCandidate(mid: String, index: UInt16, text: String) async throws {
    guard let peer else { throw HostFailure.invalidState }
    let candidate = LKRTCIceCandidate(sdp: text, sdpMLineIndex: Int32(index), sdpMid: mid)
    let _: Void = try await operation { resume in
      peer.add(candidate) { error in
        if let error { resume(.failure(error)) } else { resume(.success(())) }
      }
    }
  }
  /// The pinned Objective-C peer API has no remote EndOfCandidates method;
  /// optional wire end is advisory and bounded by the signaling owner.
  func selectedUDP() async -> Bool { await mediaStatus() == .ready }
  func mediaStatus() async -> RtcMediaStatus {
    guard let peer, peer.connectionState == .connected else { return .waiting }
    guard let report: Report = try? await operation({ resume in
      peer.statistics { resume(.success(Report(value: $0))) }
    }) else { return .waiting }
    let all = report.value.statistics
    for value in all.values where value.type == "transport" {
      guard let pairId = value.values["selectedCandidatePairId"] as? String,
        let pair = all[pairId], pair.type == "candidate-pair",
        let localId = pair.values["localCandidateId"] as? String,
        let remoteId = pair.values["remoteCandidateId"] as? String,
        let local = all[localId], let remote = all[remoteId]
      else { continue }
      if (local.values["protocol"] as? String)?.lowercased() == "udp" &&
        (remote.values["protocol"] as? String)?.lowercased() == "udp" {
        for outbound in all.values where outbound.type == "outbound-rtp" &&
          outbound.values["kind"] as? String == "video" {
          let frames = (outbound.values["framesEncoded"] as? NSNumber)?.intValue ?? 0
          let codec = (outbound.values["codecId"] as? String).flatMap { all[$0] }
          let width = (outbound.values["frameWidth"] as? NSNumber)?.intValue ?? 0
          let height = (outbound.values["frameHeight"] as? NSNumber)?.intValue ?? 0
          let mimeMatches = codec?.values["mimeType"] as? String == "video/H264"
          let fmtp = codec?.values["sdpFmtpLine"] as? String
          let high = fmtp.map(RtcSDPProof.highParameters) == true
          let now = DispatchTime.now().uptimeNanoseconds
          let outboundSummary = "RTC native encoded=\(frames) fps=\((outbound.values["framesPerSecond"] as? NSNumber)?.intValue ?? 0)"
            + " sentFrames=\((outbound.values["framesSent"] as? NSNumber)?.intValue ?? 0)"
            + " bytes=\((outbound.values["bytesSent"] as? NSNumber)?.intValue ?? 0)"
            + " targetBps=\((outbound.values["targetBitrate"] as? NSNumber)?.intValue ?? 0)"
          lock.withLock { lastOutbound = outboundSummary }
          if now &- lastFrameReport >= 10_000_000_000 {
            lastFrameReport = now
            let captureFrames = counters.summary()
            let target = (outbound.values["targetBitrate"] as? NSNumber)?.intValue ?? 0
            let fps = (outbound.values["framesPerSecond"] as? NSNumber)?.intValue ?? 0
            let bytes = (outbound.values["bytesSent"] as? NSNumber)?.intValue ?? 0
            let reason = outbound.values["qualityLimitationReason"] as? String
            let knownReason = reason.flatMap {
              ["none", "bandwidth", "cpu", "other"].contains($0) ? $0 : nil
            } ?? "unavailable"
            continuation.yield(.outboundFrames("encoded=\(frames)-width=\(width)-height=\(height)"
              + "-pipeline=\(captureFrames)-h264=\(mimeMatches)-high=\(high)"
              + "-fps=\(fps)-bytes=\(bytes)"
              + "-targetBps=\(target)-limit=\(knownReason)"))
          }
          guard frames == 0 || (RtcOutboundGeometry.accepts(width: width, height: height) &&
            mimeMatches && high) else {
            continuation.yield(.mediaProof("frames=\(frames)-width=\(width)-height=\(height)"
              + "-mime=\(mimeMatches)-fmtpPresent=\(fmtp != nil)-high=\(high)"))
            return .codecOrGeometry
          }
        }
        return .ready
      }
      return .nonUDP
    }
    return .waiting
  }
  func start(display: ActiveDisplay) async throws {
    guard let task = lock.withLock({ () -> Task<Void, Error>? in
      guard !closed, starting == nil else { return nil }
      let task = Task { try await self.startCapture(display: display) }
      starting = task
      return task
    }) else { throw HostFailure.invalidState }
    defer { lock.withLock { starting = nil } }
    try await task.value
  }
  private func startCapture(display: ActiveDisplay) async throws {
    let content = try await SCShareableContent.excludingDesktopWindows(false,
      onScreenWindowsOnly: false)
    guard let target = content.displays.first(where: { $0.displayID == display.id }) else {
      throw HostFailure.exactDisplay
    }
    let config = SCStreamConfiguration()
    config.width = 2456; config.height = 1600
    config.minimumFrameInterval = .zero
    config.queueDepth = 6  // Surface pool; see CapturePipeline for the measured starvation at 2.
    config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    config.colorSpaceName = CGColorSpace.sRGB
    config.showsCursor = true
    let created = SCStream(filter: SCContentFilter(display: target, excludingWindows: []),
      configuration: config, delegate: nil)
    try created.addStreamOutput(self, type: .screen,
      sampleHandlerQueue: DispatchQueue(label: "dev.mirri.rtc.capture"))
    guard lock.withLock({ () -> Bool in
      guard !closed else { return false }
      stream = created; captureEnabled = true
      return true
    }) else { throw HostFailure.invalidState }
    do { try await created.startCapture() } catch {
      lock.withLock { stream = nil; captureEnabled = false }
      throw error
    }
    if lock.withLock({ closed }) {
      try? await created.stopCapture()
      throw HostFailure.invalidState
    }
  }
  func stop() async {
    let (old, start, cancellations) = lock.withLock {
      () -> (SCStream?, Task<Void, Error>?, [() -> Void]) in
      closed = true; captureEnabled = false
      let previous = stream; stream = nil
      let inFlight = starting; starting = nil
      let operations = Array(pending.values); pending.removeAll()
      return (previous, inFlight, operations)
    }
    for cancel in cancellations { cancel() }
    peer?.close()
    _ = try? await start?.value
    if let old { try? await old.stopCapture() }
    peer = nil
    transceiver = nil
    continuation.finish()
  }
  func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer,
    of type: SCStreamOutputType) {
    guard type == .screen else { return }
    let attachments = CMSampleBufferGetSampleAttachmentsArray(sample,
      createIfNecessary: false) as? [[SCStreamFrameInfo: Any]]
    let complete = (attachments?.first?[.status] as? Int) == SCFrameStatus.complete.rawValue
    var gapNs: UInt64?
    if complete {
      let pts = CMSampleBufferGetPresentationTimeStamp(sample)
      guard !pts.isValid || limiter.admit(pts) else { return }
      if pts.isValid {
        if let prior = lastCompletePTS {
          let seconds = CMTimeGetSeconds(CMTimeSubtract(pts, prior))
          if seconds.isFinite, seconds > 0, seconds < 1 {
            gapNs = UInt64(seconds * 1_000_000_000)
          }
        }
        lastCompletePTS = pts
      }
    }
    counters.received(complete: complete, gapNs: gapNs)
    guard complete else { return }
    guard
      let pixel = CMSampleBufferGetImageBuffer(sample),
      CVPixelBufferGetWidth(pixel) == 2456, CVPixelBufferGetHeight(pixel) == 1600,
      CVPixelBufferGetPixelFormatType(pixel) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    else { return }
    lock.lock(); defer { lock.unlock() }
    guard !closed, captureEnabled else { return }
    let timestamp = Int64(DispatchTime.now().uptimeNanoseconds)
    guard timestamp > lastTimestamp else { return }
    lastTimestamp = timestamp
    counters.forwarded()
    let rtcFrame = LKRTCVideoFrame(buffer: LKRTCCVPixelBuffer(pixelBuffer: pixel),
      rotation: ._0, timeStampNs: timestamp)
    source.capturer(capturer, didCapture: rtcFrame)
    counters.sourceCall(DispatchTime.now().uptimeNanoseconds &- UInt64(timestamp))
  }
  func peerConnection(_ peerConnection: LKRTCPeerConnection,
    didGenerate candidate: LKRTCIceCandidate) {
    lock.lock(); defer { lock.unlock() }
    guard !closed else { return }
    candidateCount += 1
    guard candidateCount <= 64, let mid = candidate.sdpMid, mid.utf8.count <= 32,
      candidate.sdpMLineIndex == 0, candidate.sdp.utf8.count <= 2048 else {
      continuation.yield(.failed); return
    }
    if case .dropped = continuation.yield(.candidate(mid: mid, index: 0,
      text: candidate.sdp)) { continuation.yield(.failed) }
  }
  func peerConnection(_ peerConnection: LKRTCPeerConnection,
    didChange newState: LKRTCIceGatheringState) {
    // This notification does not order candidate callbacks on the attempt owner.
  }
  func peerConnection(_ peerConnection: LKRTCPeerConnection,
    didChange newState: LKRTCPeerConnectionState) {
    continuation.yield(.state(newState.rawValue))
    if newState == .connected { continuation.yield(.connected) }
    if newState == .failed || newState == .disconnected { continuation.yield(.failed) }
  }
  func peerConnection(_ peerConnection: LKRTCPeerConnection,
    didChange stateChanged: LKRTCSignalingState) {}
  func peerConnection(_ peerConnection: LKRTCPeerConnection,
    didAdd stream: LKRTCMediaStream) {}
  func peerConnection(_ peerConnection: LKRTCPeerConnection,
    didRemove stream: LKRTCMediaStream) {}
  func peerConnectionShouldNegotiate(_ peerConnection: LKRTCPeerConnection) {}
  func peerConnection(_ peerConnection: LKRTCPeerConnection,
    didChange newState: LKRTCIceConnectionState) {
    continuation.yield(.iceState(newState.rawValue))
  }
  func peerConnection(_ peerConnection: LKRTCPeerConnection,
    didRemove candidates: [LKRTCIceCandidate]) {}
  func peerConnection(_ peerConnection: LKRTCPeerConnection,
    didOpen dataChannel: LKRTCDataChannel) { continuation.yield(.failed) }
}
