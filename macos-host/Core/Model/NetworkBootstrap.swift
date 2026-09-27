import Foundation

/// MRNB v1 is a Mirri-layer control preface, never part of raw TLS transport.
public enum NetworkBootstrap {
  public static func accept(
    _ connection: any ByteConnection, token: Data, epoch: UInt32
  ) async throws -> any ByteConnection {
    guard token.count == 32, epoch > 0 else { throw HostFailure.invalidState }
    var collected = Data()
    while collected.count < 40 {
      let fragment = try await connection.receive()
      // At most 39 preface bytes plus the adapter's single 64 KiB receive.
      guard !fragment.isEmpty, collected.count + fragment.count <= 40 + 65_536
      else { throw HostFailure.unauthorized }
      collected.append(fragment)
    }
    let header = collected.prefix(8)
    guard header.elementsEqual([0x4d, 0x52, 0x4e, 0x42, 0, 1, 0, 1])
    else { throw HostFailure.unauthorized }
    guard Authenticator.equals(Data(collected[8..<40]), token) else {
      // A complete, correctly shaped request with a wrong token receives an
      // explicit rejection; no host epoch or partial Mirri frame is disclosed.
      try await connection.write(Data([0x4d, 0x52, 0x4e, 0x42, 0, 1, 0, 1, 0, 0, 0, 0]))
      throw HostFailure.unauthorized
    }
    var response = Data([0x4d, 0x52, 0x4e, 0x42, 0, 1, 0, 0])
    response.append(contentsOf: [
      UInt8(truncatingIfNeeded: epoch >> 24), UInt8(truncatingIfNeeded: epoch >> 16),
      UInt8(truncatingIfNeeded: epoch >> 8), UInt8(truncatingIfNeeded: epoch),
    ])
    try await connection.write(response)
    let extra = Data(collected.dropFirst(40))
    return extra.isEmpty ? connection : BufferedBootstrapConnection(connection, extra: extra)
  }
}

/// A bounded one-shot suffix when TLS coalesces the preface and first Mirri message.
private actor BufferedBootstrapConnection: ByteConnection {
  private let underlying: any ByteConnection
  private var extra: Data
  init(_ underlying: any ByteConnection, extra: Data) {
    self.underlying = underlying
    self.extra = extra
  }
  func receive() async throws -> Data {
    if !extra.isEmpty {
      let result = extra
      extra.removeAll()
      return result
    }
    return try await underlying.receive()
  }
  func write(_ bytes: Data) async throws { try await underlying.write(bytes) }
  func close() async { await underlying.close() }
}
