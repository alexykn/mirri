import Foundation

/// Bounded ordered trickle ICE input; staged candidates are drained only after
/// setRemoteDescription. A terminal end marker never becomes an empty SDK candidate.
struct RtcIceLedger {
  private(set) var count = 0
  private(set) var bytes = 0
  private(set) var ended = false
  private(set) var remoteDescriptionApplied = false
  private var pending: [String] = []
  mutating func candidate(mid: String, expectedMid: String, index: UInt16,
    text: String) throws -> String? {
    guard mid == expectedMid, index == 0, count < 64,
      !text.isEmpty, text.utf8.count <= 2048,
      bytes + text.utf8.count <= 128 * 1024 else { throw HostFailure.malformed }
    count += 1
    bytes += text.utf8.count
    if remoteDescriptionApplied { return text }
    pending.append(text)
    return nil
  }
  mutating func end(mid: String, expectedMid: String, index: UInt16) throws {
    guard !ended, mid == expectedMid, index == 0 else { throw HostFailure.malformed }
    ended = true
  }
  mutating func applyRemoteDescription() -> [String] {
    remoteDescriptionApplied = true
    let queued = pending
    pending = []
    return queued
  }
}
