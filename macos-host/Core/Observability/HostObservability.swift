import Foundation
import OSLog

/// Lock-protected interval counters: capture/VT callbacks update in constant
/// time without allocating a Task per frame. Each epoch owns one collector.
public final class MetricsCollector: @unchecked Sendable {
  private let lock = NSLock()
  private var capture = 0
  private var admitted = 0
  private var rejected = 0
  private var nonComplete = 0
  private var idleStatus = 0
  private var blankStatus = 0
  private var suspendedStatus = 0
  private var startedStatus = 0
  private var stoppedStatus = 0
  private var missingStatus = 0
  private var complete = 0
  private var totalComplete = 0
  private var totalSent = 0
  private var completeGapsMs: [Double] = []
  // Sampled at the SCK callback: 0, 1, or >=2 submitted VT frames awaiting
  // their matching output callback. Neither this nor queueDepth counts surfaces.
  private var pendingIdle = [0, 0, 0]
  private var pendingComplete = [0, 0, 0]
  private var pendingGap = [0, 0, 0]
  private var pendingCredit = [0, 0, 0]
  private var wrongFormat = 0
  private var creditFull = 0
  private var submitFailure = 0
  private var encoded = 0
  private var sentBytes = 0
  private var sent = 0
  private var latencies: [Double] = []
  private var submitToWrite: [Double] = []
  private var convertToWrite: [Double] = []
  private var encodeCall: [Double] = []
  private var input = 0
  private var resets = 0
  private var client = "not reported"
  private var rtt: Double?
  private var interval = DispatchTime.now().uptimeNanoseconds
  private let startedAt = DispatchTime.now().uptimeNanoseconds
  public init() {}
  public func captured() { lock.withLock { capture += 1 } }
  /// PTS deltas belong to the ScreenCaptureKit stream; never compared with host or tablet clocks.
  public func completeFrame(gapMilliseconds: Double?) {
    lock.withLock {
      complete += 1
      totalComplete += 1
      if let gapMilliseconds, gapMilliseconds.isFinite, gapMilliseconds > 0,
        gapMilliseconds < 1_000, completeGapsMs.count < 240
      {
        completeGapsMs.append(gapMilliseconds)
      }
    }
  }
  public func pendingSample(_ event: PendingVTEvent, depth: Int) {
    precondition(depth >= 0, "pending VT callback count cannot be negative")
    lock.withLock {
      let bucket = min(2, depth)
      switch event {
      case .idle: pendingIdle[bucket] += 1
      case .complete(let gap25):
        pendingComplete[bucket] += 1
        if gap25 { pendingGap[bucket] += 1 }
      case .creditFull: pendingCredit[bucket] += 1
      }
    }
  }
  public func admittedFrame() { lock.withLock { admitted += 1 } }
  public func rejectedFrame(_ reason: CaptureRejection) {
    lock.withLock {
      rejected += 1
      switch reason {
      case .nonComplete:
        nonComplete += 1
        missingStatus += 1
      case .idle:
        nonComplete += 1
        idleStatus += 1
      case .blank:
        nonComplete += 1
        blankStatus += 1
      case .suspended:
        nonComplete += 1
        suspendedStatus += 1
      case .started:
        nonComplete += 1
        startedStatus += 1
      case .stopped:
        nonComplete += 1
        stoppedStatus += 1
      case .formatMismatch: wrongFormat += 1
      case .creditFull: creditFull += 1
      case .encodeSubmitFailure: submitFailure += 1
      }
    }
  }
  public func encoderSubmission(milliseconds: Double) {
    lock.withLock { if encodeCall.count < 240 { encodeCall.append(milliseconds) } }
  }
  public func encodedFrame(bytes count: Int, latency: Double) {
    lock.withLock {
      encoded += 1
      if latencies.count < 240 { latencies.append(latency) }
    }
  }
  public func sentFrame(bytes count: Int, submitAgeMs: Double?, convertAgeMs: Double?) {
    lock.withLock {
      sent += 1
      totalSent += 1
      sentBytes += count
      if let submitAgeMs, submitToWrite.count < 240 { submitToWrite.append(submitAgeMs) }
      if let convertAgeMs, convertToWrite.count < 240 { convertToWrite.append(convertAgeMs) }
    }
  }
  public func inputMessage() { lock.withLock { input += 1 } }
  public func reset() { lock.withLock { resets += 1 } }
  public func clientMetrics(_ report: ClientPerformance) {
    lock.withLock {
      client = String(
        format:
          "receive %.1f fps %.1f Mbit/s / decode %.1f → %.1f fps (queue %d, dropped %llu)",
        report.receiveFps, Double(report.bitsPerSecond) / 1e6,
        report.decodeInputFps, report.decodeOutputFps, report.queueDepth, report.dropped)
    }
  }
  public func roundTrip(milliseconds: Double) { lock.withLock { rtt = milliseconds } }
  public func snapshot(queue: Int) -> String {
    snapshotWithPending(queue: queue).summary
  }
  /// Same bounded operational interval as snapshot(), separate numeric-only row;
  /// the schema-v4 timing line, wire protocol and offline parser stay unchanged.
  public func snapshotWithPending(queue: Int) -> (summary: String, pending: String) {
    lock.lock()
    defer { lock.unlock() }
    let now = DispatchTime.now().uptimeNanoseconds
    let seconds = max(0.001, Double(now - interval) / 1e9)
    let sorted = latencies.sorted()
    let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
    let p95 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
    let worst = sorted.last ?? 0
    func midpointAndP95(_ values: [Double]) -> (Double, Double) {
      let sorted = values.sorted()
      guard !sorted.isEmpty else { return (0, 0) }
      return (
        sorted[sorted.count / 2], sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
      )
    }
    let submitAge = midpointAndP95(submitToWrite)
    let convertAge = midpointAndP95(convertToWrite)
    let call = midpointAndP95(encodeCall)
    let cadence = midpointAndP95(completeGapsMs)
    let summary = String(
      format:
        "capture %.1f fps (admitted %.1f, skipped %d) / encode %.1f fps (%.1f/%.1f/%.1f ms) / USB %.1f fps %.1f Mbit/s (depth %d) / %@ / input %.1f/s (resets %d, RTT %.1f ms) / host submit-to-write %d samples %.1f/%.1f ms, convert-to-write %.1f/%.1f ms / skip idle=%d format=%d credit=%d submit=%d / VT call %d samples %.1f/%.1f ms / SC complete=%d idle=%d blank=%d suspended=%d started=%d stopped=%d unknown=%d PTSgap %d samples %.1f/%.1f ms >25ms=%d / cumulative complete=%d sent=%d elapsed=%.2fs",
      Double(capture) / seconds, Double(admitted) / seconds, rejected, Double(encoded) / seconds,
      median, p95, worst, Double(sent) / seconds,
      Double(sentBytes) * 8 / seconds / 1e6, queue, client, Double(input) / seconds,
      resets, rtt ?? 0, submitToWrite.count, submitAge.0, submitAge.1,
      convertAge.0, convertAge.1, nonComplete, wrongFormat, creditFull,
      submitFailure, encodeCall.count, call.0, call.1,
      complete, idleStatus, blankStatus, suspendedStatus, startedStatus, stoppedStatus,
      missingStatus, completeGapsMs.count, cadence.0, cadence.1,
      completeGapsMs.filter { $0 > 25 }.count,
      totalComplete, totalSent, Double(now - startedAt) / 1e9)
    let pending = String(
      format:
        "pendingVTCallbacks idle=%d,%d,%d complete=%d,%d,%d completeGap25=%d,%d,%d creditFull=%d,%d,%d",
      pendingIdle[0], pendingIdle[1], pendingIdle[2],
      pendingComplete[0], pendingComplete[1], pendingComplete[2],
      pendingGap[0], pendingGap[1], pendingGap[2],
      pendingCredit[0], pendingCredit[1], pendingCredit[2])
    capture = 0
    admitted = 0
    rejected = 0
    nonComplete = 0
    idleStatus = 0
    blankStatus = 0
    suspendedStatus = 0
    startedStatus = 0
    stoppedStatus = 0
    missingStatus = 0
    complete = 0
    wrongFormat = 0
    creditFull = 0
    submitFailure = 0
    encoded = 0
    sentBytes = 0
    sent = 0
    input = 0
    latencies.removeAll(keepingCapacity: true)
    submitToWrite.removeAll(keepingCapacity: true)
    convertToWrite.removeAll(keepingCapacity: true)
    encodeCall.removeAll(keepingCapacity: true)
    completeGapsMs.removeAll(keepingCapacity: true)
    pendingIdle = [0, 0, 0]
    pendingComplete = [0, 0, 0]
    pendingGap = [0, 0, 0]
    pendingCredit = [0, 0, 0]
    interval = now
    return (summary, pending)
  }
}

/// OSLog is privacy-aware; bounded local operational log never includes identifiers or input paths.
public final class SessionLogger: Sendable {
  private let logger = Logger(subsystem: "dev.mirri.host", category: "session")
  private let files: RotatingLog
  public init(directory: URL = SessionLogger.logFolder) {
    files = RotatingLog(directory: directory)
  }
  public func event(_ state: HostState) {
    logger.info("state: \(state.rawValue, privacy: .public)")
    files.append("state \(state.rawValue)")
  }
  public func error(_ failure: HostFailure) {
    logger.error("session failure: \(failure.localizedDescription, privacy: .public)")
    files.append("error \(failure.localizedDescription)")
  }
  public static func metricsLine(_ summary: String) -> String { "metrics \(summary)" }
  public func metrics(_ summary: String) { files.append(Self.metricsLine(summary)) }
  /// Only fixed numeric mode/readback facts; never a display name, serial or pixel.
  public func display(_ summary: String) { files.append("display \(summary)") }
  /// Fixed stage labels only; never transport errors containing payload or identifiers.
  public func diagnostic(_ stage: String) { files.append("diagnostic \(stage)") }
  public static var logFolder: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Mirri/Logs", isDirectory: true)
  }
}

private final class RotatingLog: @unchecked Sendable {
  private let lock = NSLock()
  private let directory: URL
  init(directory: URL) { self.directory = directory }
  func append(_ line: String) {
    lock.lock()
    defer { lock.unlock() }
    let manager = FileManager.default
    try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("host.log")
    if (try? manager.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0 > 256 * 1024 {
      let oldest = directory.appendingPathComponent("host.2.log")
      let previous = directory.appendingPathComponent("host.1.log")
      try? manager.removeItem(at: oldest)
      try? manager.moveItem(at: previous, to: oldest)
      try? manager.moveItem(at: file, to: previous)
    }
    let bytes = Data("\(ISO8601DateFormatter().string(from: Date())) \(line)\n".utf8)
    if !manager.fileExists(atPath: file.path) {
      _ = manager.createFile(atPath: file.path, contents: nil)
    }
    if let handle = try? FileHandle(forWritingTo: file) {
      defer { try? handle.close() }
      _ = try? handle.seekToEnd()
      try? handle.write(contentsOf: bytes)
    }
  }
}
