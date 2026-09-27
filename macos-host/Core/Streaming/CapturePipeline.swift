import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

public final class VideoAdmission: @unchecked Sendable {
  private let lock = NSLock()
  private var outstanding = 0
  private var enabled = true
  // Experimental fourth credit remains a fixed bound on encoder/socket work;
  // release still waits for socket write, not just the VT output callback.
  public init() {}
  public func reserve() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard enabled, outstanding < 4 else { return false }
    outstanding += 1
    return true
  }
  public func release() {
    lock.lock()
    outstanding = max(0, outstanding - 1)
    lock.unlock()
  }
  public func close() {
    lock.lock()
    enabled = false
    lock.unlock()
  }
  public var depth: Int {
    lock.lock()
    defer { lock.unlock() }
    return outstanding
  }
}

/// VT/socket callbacks can race. Only one failure transition is enqueued for
/// this pipeline incarnation; later callbacks cannot spawn unlimited tasks.
public final class PipelineFailureGate: @unchecked Sendable {
  private let lock = NSLock()
  private var reported = false
  public init() {}
  public func report(_ action: () -> Void) {
    lock.lock()
    let first = !reported
    reported = true
    lock.unlock()
    if first { action() }
  }
}

/// Callback order is preserved in the FIFO. A slot is held from capture admission until send completion.
public final class VideoSender: @unchecked Sendable {
  private let lock = NSLock()
  private var queue: [EncodedUnit] = []
  private var pumping = false
  private var stopped = false
  private var sequence: UInt64 = 0
  private var configured = false
  private let gate: VideoAdmission
  private let socket: WireConnection
  private let sessionId: Data
  private let epoch: UInt32
  private let generation: UInt32
  private let config: NegotiatedConfig
  public var onFailure: (@Sendable () -> Void)?
  public var onSent: (@Sendable (Int, Double?, Double?) -> Void)?
  public var onTimelineSent: (@Sendable (EncodedUnit, UInt64, UInt64) -> Void)?
  public var onQueuedDepth: (@Sendable (Int) -> Void)?
  public var onRelease: (@Sendable (Data) -> Void)?
  public init(
    socket: WireConnection, id: Data, epoch: UInt32, generation: UInt32,
    config: NegotiatedConfig, gate: VideoAdmission
  ) {
    self.socket = socket
    sessionId = id
    self.epoch = epoch
    self.generation = generation
    self.config = config
    self.gate = gate
  }
  public func enqueue(_ unit: EncodedUnit) {
    lock.lock()
    if stopped {
      lock.unlock()
      gate.release()
      return
    }
    queue.append(unit)
    let depth = queue.count
    let start = !pumping
    if start { pumping = true }
    lock.unlock()
    onQueuedDepth?(depth)
    if start { Task { await pump() } }
  }
  private func pump() async {
    while true {
      guard let unit = next() else { return }
      do {
        if !configured {
          guard unit.keyframe, let sets = unit.parameterSets else {
            throw HostFailure.hardwareCodec
          }
          try await socket.send(
            HostCommand.codecConfiguration(generation: generation, config: config, sets: sets)
              .wire(sessionId: sessionId, epoch: epoch))
          configured = true
        }
        let sentSequence = sequence
        let flags: UInt64 = unit.keyframe ? (sentSequence == 0 ? 3 : 1) : 0
        try await socket.send(
          HostCommand.frame(
            generation: generation, sequence: sentSequence, pts: unit.pts, flags: flags,
            data: unit.accessUnit
          ).wire(sessionId: sessionId, epoch: epoch))
        sequence += 1
        let writtenNs = DispatchTime.now().uptimeNanoseconds
        onSent?(
          unit.accessUnit.count,
          HostFrameAge.milliseconds(since: unit.submittedNs, until: writtenNs),
          HostFrameAge.milliseconds(since: unit.convertedNs, until: writtenNs))
        onTimelineSent?(unit, sentSequence, writtenNs)
        onRelease?(unit.accessUnit)
        gate.release()
      } catch {
        gate.release()
        onFailure?()
        stop()
        return
      }
    }
  }
  private func next() -> EncodedUnit? {
    lock.lock()
    defer { lock.unlock() }
    guard !queue.isEmpty, !stopped else {
      pumping = false
      return nil
    }
    return queue.removeFirst()
  }
  public func stop() {
    lock.lock()
    stopped = true
    let removed = queue.count
    queue.removeAll()
    lock.unlock()
    for _ in 0..<removed { gate.release() }
  }
}

public final class ScreenCapturer: NSObject, SCStreamOutput, @unchecked Sendable {
  private var stream: SCStream?
  private let encoder: VideoEncoder
  private let gate: VideoAdmission
  /// SCStream delivers callbacks on the single sampleHandlerQueue configured below.
  private var lastCompletePTS: CMTime?
  public var onReceived: (@Sendable () -> Void)?
  public var onCompleteCadence: (@Sendable (Double?) -> Void)?
  public var onCompleteTiming: (@Sendable (CMTime, UInt64) -> Void)?
  public var onPendingSample: (@Sendable (PendingVTEvent, Int) -> Void)?
  public var onAdmittedDepth: (@Sendable (Int) -> Void)?
  public var onCaptured: (@Sendable () -> Void)?
  public var onRejected: (@Sendable (CaptureRejection) -> Void)?
  public init(encoder: VideoEncoder, gate: VideoAdmission) {
    self.encoder = encoder
    self.gate = gate
  }
  public func start(display: ActiveDisplay) async throws {
    let content = try await SCShareableContent.excludingDesktopWindows(
      false, onScreenWindowsOnly: false)
    guard let target = content.displays.first(where: { $0.displayID == display.id }) else {
      throw HostFailure.exactDisplay
    }
    let filter = SCContentFilter(display: target, excludingWindows: [])
    let configuration = SCStreamConfiguration()
    configuration.width = 2456
    configuration.height = 1600
    // The verified virtual display is already 60 Hz. Request its native
    // ScreenCaptureKit cadence: 1/60 imposed a second throttle and measured
    // 56.64 fps, while .zero measured 59.92 fps in matched 90 s motion.
    // Do not treat this short run as the still-pending 30-minute acceptance.
    configuration.minimumFrameInterval = .zero
    configuration.queueDepth = 2
    configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    configuration.colorSpaceName = CGColorSpace.sRGB
    configuration.showsCursor = true
    let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
    try stream.addStreamOutput(
      self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "dev.mirri.capture"))
    self.stream = stream
    do { try await stream.startCapture() } catch {
      self.stream = nil
      throw error
    }
  }
  public func stop() async {
    gate.close()
    if let stream { try? await stream.stopCapture() }
    stream = nil
  }
  public func stream(
    _ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer,
    of type: SCStreamOutputType
  ) {
    let callbackNs = DispatchTime.now().uptimeNanoseconds
    if type == .screen { onReceived?() }
    guard type == .screen else { return }
    guard
      let attachments = CMSampleBufferGetSampleAttachmentsArray(
        buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
      let status = attachments.first?[.status] as? Int
    else {
      onRejected?(.nonComplete)
      return
    }
    guard status == SCFrameStatus.complete.rawValue else {
      switch SCFrameStatus(rawValue: status) {
      case .idle:
        onPendingSample?(.idle, encoder.pendingVTCallbacks)
        onRejected?(.idle)
      case .blank: onRejected?(.blank)
      case .suspended: onRejected?(.suspended)
      case .started: onRejected?(.started)
      case .stopped: onRejected?(.stopped)
      default: onRejected?(.nonComplete)
      }
      return
    }
    let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
    var gap: Double?
    if let previous = lastCompletePTS {
      let milliseconds = CMTimeGetSeconds(CMTimeSubtract(pts, previous)) * 1_000
      if milliseconds.isFinite, milliseconds > 0, milliseconds < 1_000 {
        gap = milliseconds
      }
    }
    lastCompletePTS = pts
    // Sample once for every complete SCK callback; reuse this exact depth for
    // the following-frame PTS-gap subset (not an independently timed sample).
    let pending = encoder.pendingVTCallbacks
    onPendingSample?(.complete(gap25: gap.map { $0 > 25 } ?? false), pending)
    onCompleteCadence?(gap)
    onCompleteTiming?(pts, callbackNs)
    guard let image = CMSampleBufferGetImageBuffer(buffer),
      CVPixelBufferGetWidth(image) == 2456, CVPixelBufferGetHeight(image) == 1600,
      CVPixelBufferGetPixelFormatType(image) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    else {
      onRejected?(.formatMismatch)
      return
    }
    guard gate.reserve() else {
      onPendingSample?(.creditFull, encoder.pendingVTCallbacks)
      onRejected?(.creditFull)
      return
    }
    onCaptured?()
    onAdmittedDepth?(gate.depth)
    if !encoder.encode(image, time: pts, captureCallbackNs: callbackNs) {
      gate.release()
      onRejected?(.encodeSubmitFailure)
    }
  }
}

public enum CaptureRejection: Sendable {
  case nonComplete, idle, blank, suspended, started, stopped
  case formatMismatch, creditFull, encodeSubmitFailure
}

public enum PendingVTEvent: Sendable {
  case idle
  case complete(gap25: Bool)
  case creditFull
}

public enum PipelineFailureCause: String, Sendable {
  case videoSender, encoder
}

public final class CapturePipeline: @unchecked Sendable {
  private let capturer: ScreenCapturer
  private let encoder: VideoEncoder
  private let sender: VideoSender
  private let gate = VideoAdmission()
  public init(
    display: ActiveDisplay, socket: WireConnection, id: Data, epoch: UInt32,
    generation: UInt32, config: NegotiatedConfig, timing: HostVideoTiming,
    onFailure: @escaping @Sendable (PipelineFailureCause) -> Void,
    onReceived: @escaping @Sendable () -> Void,
    onCompleteCadence: @escaping @Sendable (Double?) -> Void,
    onPendingSample: @escaping @Sendable (PendingVTEvent, Int) -> Void,
    onCaptured: @escaping @Sendable () -> Void,
    onRejected: @escaping @Sendable (CaptureRejection) -> Void,
    onEncodeSubmit: @escaping @Sendable (Double) -> Void,
    onEncoded: @escaping @Sendable (Int, Double) -> Void,
    onSent: @escaping @Sendable (Int, Double?, Double?) -> Void
  ) {
    encoder = VideoEncoder(codec: config.codec, bitrate: config.bitrate)
    sender = VideoSender(
      socket: socket, id: id, epoch: epoch, generation: generation,
      config: config, gate: gate)
    capturer = ScreenCapturer(encoder: encoder, gate: gate)
    encoder.onUnit = { [sender, timing] unit in
      timing.encoderOutput(unit)
      onEncoded(unit.accessUnit.count, unit.encodeLatencyMs)
      sender.enqueue(unit)
    }
    encoder.onSubmissionDuration = { duration in
      timing.encoderCall(milliseconds: duration)
      onEncodeSubmit(duration)
    }
    let failure = PipelineFailureGate()
    sender.onFailure = { failure.report { onFailure(.videoSender) } }
    sender.onRelease = { [encoder] in encoder.recycle($0) }
    encoder.onFailure = { failure.report { onFailure(.encoder) } }
    sender.onSent = onSent
    sender.onTimelineSent = { [timing] unit, sequence, atNs in
      timing.written(unit, sequence: sequence, atNs: atNs)
    }
    sender.onQueuedDepth = { [timing] depth in timing.encodedQueue(depth: depth) }
    capturer.onReceived = onReceived
    capturer.onCompleteCadence = onCompleteCadence
    capturer.onPendingSample = onPendingSample
    capturer.onCompleteTiming = { [timing] pts, callbackNs in
      timing.complete(pts: pts, callbackNs: callbackNs)
    }
    capturer.onAdmittedDepth = { [timing] depth in timing.admitted(depth: depth) }
    capturer.onCaptured = onCaptured
    capturer.onRejected = onRejected
  }
  public func start(display: ActiveDisplay) async throws {
    try encoder.prepare()
    do { try await capturer.start(display: display) } catch {
      encoder.invalidate()
      throw error
    }
  }
  public func stop() async {
    await capturer.stop()
    encoder.invalidate()
    sender.stop()
  }
  public var queueDepth: Int { gate.depth }
}
