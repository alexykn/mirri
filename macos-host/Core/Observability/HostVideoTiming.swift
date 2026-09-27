import CoreMedia
import Foundation

/// Counts frame gaps above fixed thresholds and runs of consecutive >25 ms
/// gaps. An open run crosses interval boundaries until a normal gap or stop.
public struct FrameGapBursts: Sendable {
  public struct Summary: Sendable {
    public let over25: UInt64
    public let over50: UInt64
    public let over100: UInt64
    public let closed: [UInt64]
    public let longestClosed: UInt64
    public let openLength: UInt64
    public func encoded() -> String {
      "\(over25).\(over50).\(over100).\(closed.map(String.init).joined(separator: ".")).\(longestClosed).\(openLength)"
    }
  }
  private var over25: UInt64 = 0
  private var over50: UInt64 = 0
  private var over100: UInt64 = 0
  private var closed = [UInt64](repeating: 0, count: 5)
  private var longestClosed: UInt64 = 0
  private var openLength: UInt64 = 0
  public init() {}
  public mutating func observe(_ ns: UInt64) {
    if ns > 25_000_000 {
      over25 += 1
      openLength += 1
    } else {
      finish()
    }
    if ns > 50_000_000 { over50 += 1 }
    if ns > 100_000_000 { over100 += 1 }
  }
  public mutating func finish() {
    guard openLength > 0 else { return }
    let bucket: Int
    switch openLength {
    case 1: bucket = 0
    case 2: bucket = 1
    case 3...5: bucket = 2
    case 6...15: bucket = 3
    default: bucket = 4
    }
    closed[bucket] += 1
    longestClosed = max(longestClosed, openLength)
    openLength = 0
  }
  public func summary() -> Summary {
    Summary(
      over25: over25, over50: over50, over100: over100, closed: closed,
      longestClosed: longestClosed, openLength: openLength)
  }
  public mutating func drain() -> Summary {
    let result = summary()
    over25 = 0
    over50 = 0
    over100 = 0
    closed = [UInt64](repeating: 0, count: 5)
    longestClosed = 0
    return result
  }
}

/// Schema 3: 2 ms bins through 100 ms, eight bounded tail bins and an
/// unbounded overflow bin. Overflow has no finite percentile upper bound.
public struct StageTimingHistogram: Sendable {
  public static let boundsNs: [UInt64] =
    (1...50).map { UInt64($0) * 2_000_000 }
    + [125, 150, 200, 250, 500, 1_000, 5_000, 10_000].map { UInt64($0) * 1_000_000 }
  private var bins = [UInt64](repeating: 0, count: boundsNs.count + 1)
  private var sampleCount: UInt64 = 0
  private var maximum: UInt64 = 0
  private var gaps: FrameGapBursts?
  public init(trackGaps: Bool = false) { gaps = trackGaps ? FrameGapBursts() : nil }
  @discardableResult public mutating func observe(_ nanos: UInt64) -> Bool {
    let index = Self.boundsNs.firstIndex(where: { nanos <= $0 }) ?? Self.boundsNs.count
    bins[index] += 1
    sampleCount += 1
    maximum = max(maximum, nanos)
    gaps?.observe(nanos)
    return true
  }
  public mutating func finishGapRun() { gaps?.finish() }
  public var count: UInt64 { sampleCount }
  /// Empty means no samples were observed, including zero-duration samples.
  public var isEmpty: Bool { sampleCount == 0 }
  public var maxNs: UInt64 { maximum }
  public func upperBoundMs(_ fraction: Double) -> Double? {
    let total = count
    guard total > 0 else { return nil }
    let rank = max(UInt64(1), UInt64(ceil(Double(total) * fraction)))
    var cumulative: UInt64 = 0
    for (index, value) in bins.enumerated() {
      cumulative += value
      if cumulative >= rank {
        return index < Self.boundsNs.count ? Double(Self.boundsNs[index]) / 1e6 : nil
      }
    }
    return nil
  }
  public func encoded() -> String {
    "\(count):\(upperBoundMs(0.5) ?? -1):\(upperBoundMs(0.95) ?? -1):"
      + "\(upperBoundMs(0.99) ?? -1):\(!isEmpty ? Double(maximum) / 1e6 : -1):"
      + bins.map(String.init).joined(separator: ".") + ":" + (gaps?.summary().encoded() ?? "na")
  }
  public mutating func drain() -> StageTimingHistogram {
    let current = self
    bins = [UInt64](repeating: 0, count: bins.count)
    sampleCount = 0
    maximum = 0
    // The returned copy owns interval counts, while an open run carries on.
    if gaps != nil { _ = gaps?.drain() }
    return current
  }
}

/// SCK PTS epoch/domain is unverified; compare only successive PTS from this
/// same SCK stream. Encoder-rebased wire PTS is a separate media sequence.
/// Host callback/write stamps use DispatchTime uptime; no PTS-to-host subtraction.
public final class HostVideoTiming: @unchecked Sendable {
  public struct MeasuredReport: Sendable {
    public let line: String
    public let lockNs: UInt64
    public let formatNs: UInt64
  }
  private struct Counts {
    let completed: UInt64
    let encoded: UInt64
    let written: UInt64
    let missingPTS: UInt64
    let invalidClock: UInt64
    let sequenceMismatch: UInt64
    let truncatedDecoderPTS: UInt64
    let creditHigh: Int
    let encodedQueueHigh: Int
    let keyEncoded: UInt64
    let keyWritten: UInt64
    let keyBytes: UInt64
    let keyMaxBytes: UInt64
    let otherBytes: UInt64
    let otherMaxBytes: UInt64
  }
  public static let schema = 4
  public enum Stage: String, CaseIterable, Sendable {
    case mediaPtsGap, completeCallbackGap, vtCall, vtCallback, conversion
    case callbackToWrite, outputToWrite, conversionToWrite, sendGap, sentPtsGap
    case keyVtCallback
  }
  private let lock = NSLock()
  // Serializes only low-frequency snapshot/format work, never capture callbacks.
  private let reportLock = NSLock()
  private let epoch: UInt32
  private let generation: UInt32
  private var histograms: [Stage: StageTimingHistogram] =
    Dictionary(
      uniqueKeysWithValues: Stage.allCases.map { stage in
        (stage, StageTimingHistogram(trackGaps: HostVideoTiming.gapStages.contains(stage)))
      })
  private static let gapStages: Set<Stage> = [
    .mediaPtsGap, .completeCallbackGap, .sendGap, .sentPtsGap,
  ]
  private var previousCapturePTS: CMTime?
  private var previousCompleteCallbackNs: UInt64?
  private var previousWriteNs: UInt64?
  private var previousSentPTS: UInt64?
  private var previousSequence: UInt64?
  private var completed: UInt64 = 0
  private var encoded: UInt64 = 0
  private var written: UInt64 = 0
  private var keyEncoded: UInt64 = 0
  private var keyWritten: UInt64 = 0
  private var keyBytes: UInt64 = 0
  private var keyMaxBytes: UInt64 = 0
  private var otherBytes: UInt64 = 0
  private var otherMaxBytes: UInt64 = 0
  private var missingPTS: UInt64 = 0
  private var invalidClock: UInt64 = 0
  private var sequenceMismatch: UInt64 = 0
  private var truncatedDecoderPTS: UInt64 = 0
  private var maxCreditDepth = 0
  private var maxEncodedQueue = 0
  private var record: UInt64 = 0
  private var finalReport: String?
  private var active = false
  private var intervalStartNs: UInt64 = 0
  private var windowStartNs: UInt64 = 0

  /// Stage.allCases is the complete timing schema; a missing entry is a programmer error.
  private func histogram(_ stage: Stage, observe nanos: UInt64) {
    guard histograms[stage]?.observe(nanos) != nil else {
      preconditionFailure("Missing timing histogram: \(stage.rawValue)")
    }
  }

  public init(epoch: UInt32, generation: UInt32) {
    self.epoch = epoch
    self.generation = generation
  }
  /// Called after SCK start succeeds: pre-stream setup/callbacks cannot bias
  /// the first numerator or denominator. Counts stop at freeze, not teardown.
  public func activate(atNs: UInt64 = DispatchTime.now().uptimeNanoseconds) {
    lock.lock()
    defer { lock.unlock() }
    guard !active, finalReport == nil else { return }
    active = true
    windowStartNs = atNs
    intervalStartNs = atNs
    histograms = Dictionary(
      uniqueKeysWithValues: Stage.allCases.map { stage in
        (stage, StageTimingHistogram(trackGaps: Self.gapStages.contains(stage)))
      })
    previousCapturePTS = nil
    previousCompleteCallbackNs = nil
    previousWriteNs = nil
    previousSentPTS = nil
    previousSequence = nil
    completed = 0
    encoded = 0
    written = 0
    keyEncoded = 0
    keyWritten = 0
    keyBytes = 0
    keyMaxBytes = 0
    otherBytes = 0
    otherMaxBytes = 0
    missingPTS = 0
    invalidClock = 0
    sequenceMismatch = 0
    truncatedDecoderPTS = 0
    maxCreditDepth = 0
    maxEncodedQueue = 0
  }
  private func duration(_ stage: Stage, start: UInt64, end: UInt64) {
    guard end >= start else {
      invalidClock += 1
      return
    }
    histogram(stage, observe: end - start)
  }
  private func mediaDuration(_ stage: Stage, seconds: Double) {
    guard seconds.isFinite, seconds >= 0 else {
      invalidClock += 1
      return
    }
    // Saturated astronomical media values remain visibly in overflow.
    let ns = seconds >= Double(UInt64.max) / 1e9 ? UInt64.max : UInt64(seconds * 1e9)
    histogram(stage, observe: ns)
  }
  public func complete(pts: CMTime, callbackNs: UInt64) {
    lock.lock()
    defer { lock.unlock() }
    guard active, callbackNs >= windowStartNs else { return }
    completed += 1
    if pts.isValid, !pts.isIndefinite {
      if let old = previousCapturePTS {
        mediaDuration(.mediaPtsGap, seconds: CMTimeGetSeconds(CMTimeSubtract(pts, old)))
      }
      previousCapturePTS = pts
    } else {
      missingPTS += 1
    }
    if let old = previousCompleteCallbackNs {
      duration(.completeCallbackGap, start: old, end: callbackNs)
    }
    previousCompleteCallbackNs = callbackNs
  }
  public func admitted(depth: Int) {
    lock.lock()
    guard active else {
      lock.unlock()
      return
    }
    maxCreditDepth = max(maxCreditDepth, depth)
    lock.unlock()
  }
  public func encoderCall(milliseconds: Double) {
    lock.lock()
    guard active else {
      lock.unlock()
      return
    }
    mediaDuration(.vtCall, seconds: milliseconds / 1_000)
    lock.unlock()
  }
  public func encoderOutput(_ unit: EncodedUnit) {
    lock.lock()
    defer { lock.unlock() }
    guard active, unit.captureCallbackNs >= windowStartNs else { return }
    encoded += 1
    let bytes = UInt64(unit.accessUnit.count)
    if unit.keyframe {
      keyEncoded += 1
      keyBytes += bytes
      keyMaxBytes = max(keyMaxBytes, bytes)
      if unit.encoderCallbackNs >= unit.submittedNs {
        duration(.keyVtCallback, start: unit.submittedNs, end: unit.encoderCallbackNs)
      }
    } else {
      otherBytes += bytes
      otherMaxBytes = max(otherMaxBytes, bytes)
    }
    duration(.vtCallback, start: unit.submittedNs, end: unit.encoderCallbackNs)
    duration(.conversion, start: unit.encoderCallbackNs, end: unit.convertedNs)
  }
  public func encodedQueue(depth: Int) {
    lock.lock()
    guard active else {
      lock.unlock()
      return
    }
    maxEncodedQueue = max(maxEncodedQueue, depth)
    lock.unlock()
  }
  public func written(_ unit: EncodedUnit, sequence: UInt64, atNs: UInt64) {
    lock.lock()
    defer { lock.unlock() }
    guard active, unit.captureCallbackNs >= windowStartNs else { return }
    written += 1
    if unit.keyframe { keyWritten += 1 }
    if let old = previousSequence, sequence != old + 1 { sequenceMismatch += 1 }
    previousSequence = sequence
    if unit.pts % 1_000 != 0 { truncatedDecoderPTS += 1 }
    if let old = previousSentPTS { duration(.sentPtsGap, start: old, end: unit.pts) }
    previousSentPTS = unit.pts
    if let old = previousWriteNs { duration(.sendGap, start: old, end: atNs) }
    previousWriteNs = atNs
    duration(.callbackToWrite, start: unit.captureCallbackNs, end: atNs)
    duration(.outputToWrite, start: unit.encoderCallbackNs, end: atNs)
    duration(.conversionToWrite, start: unit.convertedNs, end: atNs)
  }
  private func report(final: Bool, atNs: UInt64) -> MeasuredReport {
    reportLock.lock()
    defer { reportLock.unlock() }
    let lockStart = DispatchTime.now().uptimeNanoseconds
    lock.lock()
    if let finalReport {
      lock.unlock()
      return MeasuredReport(line: finalReport, lockNs: 0, formatNs: 0)
    }
    let startNs = intervalStartNs
    let endNs = max(atNs, startNs)
    if final { active = false }
    if final {
      for stage in Self.gapStages {
        guard histograms[stage]?.finishGapRun() != nil else {
          preconditionFailure("Missing timing histogram: \(stage.rawValue)")
        }
      }
    }
    let copied = Stage.allCases.map { stage in
      guard let drained = histograms[stage]?.drain() else {
        preconditionFailure("Missing timing histogram: \(stage.rawValue)")
      }
      return (stage, drained)
    }
    intervalStartNs = endNs
    let nextRecord = record
    record += 1
    let counts = Counts(
      completed: completed, encoded: encoded, written: written, missingPTS: missingPTS,
      invalidClock: invalidClock, sequenceMismatch: sequenceMismatch,
      truncatedDecoderPTS: truncatedDecoderPTS, creditHigh: maxCreditDepth,
      encodedQueueHigh: maxEncodedQueue, keyEncoded: keyEncoded, keyWritten: keyWritten,
      keyBytes: keyBytes, keyMaxBytes: keyMaxBytes, otherBytes: otherBytes,
      otherMaxBytes: otherMaxBytes)
    completed = 0
    encoded = 0
    written = 0
    keyEncoded = 0
    keyWritten = 0
    keyBytes = 0
    keyMaxBytes = 0
    otherBytes = 0
    otherMaxBytes = 0
    missingPTS = 0
    invalidClock = 0
    sequenceMismatch = 0
    truncatedDecoderPTS = 0
    maxCreditDepth = 0
    maxEncodedQueue = 0
    lock.unlock()
    let formatStart = DispatchTime.now().uptimeNanoseconds
    let stages = copied.map { "\($0.0.rawValue)=\($0.1.encoded())" }.joined(separator: " ")
    let result =
      "videoTiming v=\(Self.schema) epoch=\(epoch) generation=\(generation) record=\(nextRecord) "
      + "startNs=\(startNs) endNs=\(endNs) final=\(final ? 1 : 0) "
      + "complete=\(counts.completed) encoded=\(counts.encoded) written=\(counts.written) missingPTS=\(counts.missingPTS) invalidClock=\(counts.invalidClock) "
      + "sequenceMismatch=\(counts.sequenceMismatch) truncatedDecoderPTS=\(counts.truncatedDecoderPTS) "
      + "creditHigh=\(counts.creditHigh) encodedQueueHigh=\(counts.encodedQueueHigh) "
      + "keyEncoded=\(counts.keyEncoded) keyWritten=\(counts.keyWritten) keyBytes=\(counts.keyBytes) "
      + "keyMaxBytes=\(counts.keyMaxBytes) otherBytes=\(counts.otherBytes) otherMaxBytes=\(counts.otherMaxBytes) "
      + "capturePtsToCallback=unavailable-unverified-clock \(stages)"
    let formatEnd = DispatchTime.now().uptimeNanoseconds
    if final {
      lock.lock()
      finalReport = result
      lock.unlock()
    }
    return MeasuredReport(
      line: result, lockNs: formatStart - lockStart, formatNs: formatEnd - formatStart)
  }
  public func snapshot(atNs: UInt64 = DispatchTime.now().uptimeNanoseconds) -> String {
    report(final: false, atNs: atNs).line
  }
  /// Off-hot-path report phases: capture-lock/copy and subsequent formatting.
  public func snapshotMeasured(atNs: UInt64 = DispatchTime.now().uptimeNanoseconds)
    -> MeasuredReport
  {
    report(final: false, atNs: atNs)
  }
  /// Freeze the measurement before regular Stop/disconnect teardown; no
  /// socket/codec callback after this boundary enters the numeric window.
  public func freeze(atNs: UInt64 = DispatchTime.now().uptimeNanoseconds) {
    _ = report(final: true, atNs: atNs)
  }
  /// Called only after capture/send teardown to close a trailing gap burst.
  public func finish() -> String {
    report(final: true, atNs: DispatchTime.now().uptimeNanoseconds).line
  }
}
