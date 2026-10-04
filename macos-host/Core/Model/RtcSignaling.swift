import Foundation

/// The pure wire codec validates lengths, UTF-8 and enum ranges. The attempt owner
/// validates ordering, epoch, nonce and attempt identity before interpreting fields.
enum RtcSignal {
  static func number(_ value: WireValue) throws -> UInt64 {
    guard case .integer(let value) = value else { throw HostFailure.malformed }
    return value
  }
  static func bytes(_ value: WireValue) throws -> Data {
    guard case .bytes(let value) = value else { throw HostFailure.malformed }
    return value
  }
  static func text(_ value: WireValue) throws -> String {
    guard case .text(let value) = value else { throw HostFailure.malformed }
    return value
  }
  static func match(_ message: WireMessage, attempt: Data) throws {
    guard (23...31).contains(message.type),
      (try number(message.fields[2])) == 1, (try bytes(message.fields[3])) == attempt
    else { throw HostFailure.malformed }
  }
  static func message(_ kind: MessageKind, session: Data, epoch: UInt32, attempt: Data,
    fields: [WireValue] = []) -> WireMessage {
    WireMessage(type: kind.rawValue, sequence: 0,
      timestamp: DispatchTime.now().uptimeNanoseconds,
      fields: [.bytes(session), .integer(UInt64(epoch)), .integer(1), .bytes(attempt)] + fields)
  }
}

/// An ordered, bounded writer for RTC signaling sharing one TLS control connection.
/// Inputs arrive on the same socket independently; pending ICE never occupies the read loop.
actor RtcSignalWriter {
  let channel: WireConnection
  private var writing = false
  private var waiters: [CheckedContinuation<Void, Never>] = []
  private var iceCount = 0
  init(channel: WireConnection) { self.channel = channel }
  func send(_ message: WireMessage) async throws {
    if message.type == MessageKind.rtcIceCandidate.rawValue {
      guard iceCount < 64 else { throw HostFailure.malformed }
      iceCount += 1
    }
    if writing {
      await withCheckedContinuation { waiters.append($0) }
    } else {
      writing = true
    }
    defer {
      if waiters.isEmpty { writing = false }
      else { waiters.removeFirst().resume() }
    }
    try await channel.send(message)
  }
}
