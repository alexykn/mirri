import Foundation

/// Mirri framing and outbound sequencing over an ordered byte connection.
public actor WireConnection {
  private let bytes: any ByteConnection
  private var framer: WireFramer
  private var records: [FramedRecord] = []
  private var nextOutbound: UInt64 = 0
  private var pendingWrite = false
  private var terminated = false
  public init(_ bytes: any ByteConnection, video: Bool = false) {
    self.bytes = bytes
    framer = WireFramer(videoChannel: video)
  }
  public func read() async throws -> FramedRecord {
    while records.isEmpty {
      guard !terminated else { throw HostFailure.transport }
      records += try framer.append(await bytes.receive())
    }
    return records.removeFirst()
  }
  public func send(_ message: WireMessage) async throws {
    guard !terminated, !pendingWrite, nextOutbound < UInt64.max else {
      throw HostFailure.transport
    }
    let frame = try WireCodec.encode(
      WireMessage(
        type: message.type, sequence: nextOutbound,
        timestamp: DispatchTime.now().uptimeNanoseconds, fields: message.fields))
    nextOutbound += 1
    pendingWrite = true
    defer { pendingWrite = false }
    try await bytes.write(frame)
  }
  public func close() async {
    terminated = true
    await bytes.close()
  }
}

public enum Authenticator {
  /// Fixed-size constant-time comparison; never log either value.
  public static func equals(_ lhs: Data, _ rhs: Data) -> Bool {
    guard lhs.count == 32, rhs.count == 32 else { return false }
    var difference: UInt8 = 0
    for index in 0..<32 { difference |= lhs[index] ^ rhs[index] }
    return difference == 0
  }
}
