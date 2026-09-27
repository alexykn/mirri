import Foundation
import Network
import XCTest

@testable import MirriHostCore

final class LoopbackTests: XCTestCase {
  private var fixtureDirectory: URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("protocol/fixtures")
  }
  func testLoopbackOrderedMessagesAndClose() async throws {
    let listener = try LoopbackListener(port: 0, noDelay: true)
    let port = try await listener.boundPort()
    let incoming = Task { try await listener.accept() }
    let client = WireConnection(NWConnection(host: .ipv4(.loopback), port: port, using: .tcp))
    let hello = try XCTUnwrap(
      WireCodec.decode(
        Data(
          contentsOf:
            fixtureDirectory.appendingPathComponent("01-client-hello-v1.bin"))))
    try await client.send(hello)
    let server = try await incoming.value
    guard case .message(let received) = try await server.read() else {
      XCTFail("Expected hello")
      return
    }
    XCTAssertEqual(received.fields, hello.fields)
    XCTAssertEqual(received.sequence, 0)
    let ready = try XCTUnwrap(
      WireCodec.decode(
        Data(
          contentsOf:
            fixtureDirectory.appendingPathComponent("03-client-ready-v1.bin"))))
    try await client.send(ready)
    guard case .message(let second) = try await server.read() else {
      XCTFail("Expected ready")
      return
    }
    XCTAssertEqual(second.type, 3)
    XCTAssertEqual(second.sequence, 1)
    await client.close()
    do {
      _ = try await server.read()
      XCTFail("EOF must end the channel")
    } catch {
      // Expected EOF after the peer closes.
    }
    await server.close()
    listener.close()
  }
}
