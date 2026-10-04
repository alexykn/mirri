import CryptoKit
import Foundation

/// Sparse, numeric-only observations of actual frame writes. No media payload is retained.
/// A trace ID is a domain-separated digest of the random *non-token* session ID.
public final class HostLatencyTrace: @unchecked Sendable {
  public static func identity(_ sessionId: Data) -> String {
    let digest = SHA256.hash(data: Data("mirri-latency-v1".utf8) + sessionId)
    return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
  }

  private struct Frame {
    let sequence: UInt64
    let ptsUs: UInt64
    let callback: UInt64
    let submit: UInt64
    let encoder: UInt64
    let prewrite: UInt64
    var written: UInt64

    var line: String {
      "\(sequence),\(ptsUs),\(callback),\(submit),\(encoder),\(prewrite),\(written)"
    }
  }

  private let lock = NSLock()
  public let id: String
  private let epoch: UInt32
  private let generation: UInt32
  private let route: String
  private var pending: [UInt64: Frame] = [:]
  private var ready: [Frame] = []
  private var clocks: [String] = []
  private var selected = 0
  private var missing = 0
  private var dropped = 0
  private var rejectedClock = 0
  private var record: UInt64 = 0
  private var startNs: UInt64
  private var frozenNs: UInt64?
  private var active = false

  public init(
    sessionId: Data, epoch: UInt32, generation: UInt32, route: String = "network",
    startNs: UInt64 = DispatchTime.now().uptimeNanoseconds
  ) {
    id = Self.identity(sessionId)
    self.epoch = epoch
    self.generation = generation
    precondition(route == "usb" || route == "network")
    self.route = route
    self.startNs = startNs
  }

  public func activate(atNs: UInt64 = DispatchTime.now().uptimeNanoseconds) {
    lock.lock()
    if !active {
      startNs = atNs
      active = true
    }
    lock.unlock()
  }

  /// Called immediately before the frame's production socket write, after any codec config.
  public func prewrite(_ unit: EncodedUnit, sequence: UInt64, atNs: UInt64) {
    guard sequence % 6 == 0 else { return }
    lock.lock()
    defer { lock.unlock() }
    guard active, frozenNs == nil else { return }
    selected += 1
    guard pending.count < 16 else {
      dropped += 1
      return
    }
    guard unit.captureCallbackNs > 0, unit.submittedNs >= unit.captureCallbackNs,
      unit.encoderCallbackNs >= unit.submittedNs, atNs >= unit.encoderCallbackNs
    else {
      missing += 1
      return
    }
    pending[sequence] = Frame(
      sequence: sequence, ptsUs: unit.pts / 1_000, callback: unit.captureCallbackNs,
      submit: unit.submittedNs, encoder: unit.encoderCallbackNs, prewrite: atNs, written: 0)
  }

  public func written(sequence: UInt64, atNs: UInt64) {
    guard sequence % 6 == 0 else { return }
    lock.lock()
    defer { lock.unlock() }
    guard active, frozenNs == nil else { return }
    guard var frame = pending.removeValue(forKey: sequence) else { return }
    guard atNs >= frame.prewrite else {
      missing += 1
      return
    }
    frame.written = atNs
    if ready.count < 20 { ready.append(frame) } else { dropped += 1 }
  }

  /// Pending Ping sequence/sent is checked by the coordinator before reaching this method.
  public func pong(sequence: UInt64, t1: UInt64, t2: UInt64, t3: UInt64, t4: UInt64) {
    lock.lock()
    defer { lock.unlock() }
    guard active, frozenNs == nil else { return }
    guard t1 > 0, t2 > 0, t3 >= t2, t4 >= t1, t4 - t1 <= 5_000_000_000 else {
      rejectedClock += 1
      return
    }
    if clocks.count < 10 { clocks.append("\(sequence),\(t1),\(t2),\(t3),\(t4)") }
  }

  public func freeze(atNs: UInt64 = DispatchTime.now().uptimeNanoseconds) {
    lock.lock()
    if frozenNs == nil { frozenNs = atNs }
    lock.unlock()
  }

  /// One bounded line per second, independent of the existing v4 histogram owner.
  public func report(final: Bool = false, atNs: UInt64 = DispatchTime.now().uptimeNanoseconds)
    -> String
  {
    lock.lock()
    defer { lock.unlock() }
    let endNs = final ? frozenNs ?? atNs : atNs
    if final {
      let available = max(0, 20 - ready.count)
      let survivors = pending.values.prefix(available)
      ready.append(contentsOf: survivors)
      missing += pending.count  // No post-freeze completion is evidence of an active-window write.
      pending.removeAll()
      if ready.count > 10 {
        dropped += ready.count - 10
        ready.removeLast(ready.count - 10)
      }
    }
    let batch = Array(ready.prefix(10))
    ready.removeFirst(batch.count)
    let result =
      "latencyTrace v=1 side=host trace=\(id) route=\(route) epoch=\(epoch) generation=\(generation) "
      + "record=\(record) startNs=\(startNs) endNs=\(endNs) final=\(final ? 1 : 0) "
      + "selected=\(selected) missing=\(missing) dropped=\(dropped) rejectedClock=\(rejectedClock) "
      + "frames=\(batch.map(\.line).joined(separator: ";").ifEmptyDash) "
      + "clocks=\(clocks.joined(separator: ";").ifEmptyDash)"
    record += 1
    startNs = endNs
    selected = 0
    missing = 0
    dropped = 0
    rejectedClock = 0
    clocks.removeAll(keepingCapacity: true)
    return result
  }
}

extension String {
  fileprivate var ifEmptyDash: String { isEmpty ? "-" : self }
}
