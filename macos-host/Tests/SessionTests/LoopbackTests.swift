import Foundation
import Network
import XCTest

@testable import MirriHostCore

private actor FragmentedBytes: ByteConnection {
  private var fragments: [Data] = []
  private var waiting: CheckedContinuation<Data, Error>?
  private var closed = false
  func feed(_ fragment: Data) {
    if let waiting {
      self.waiting = nil
      waiting.resume(returning: fragment)
    } else {
      fragments.append(fragment)
    }
  }
  func receive() async throws -> Data {
    if closed { throw HostFailure.transport }
    if !fragments.isEmpty { return fragments.removeFirst() }
    return try await withCheckedThrowingContinuation { waiting = $0 }
  }
  func write(_ bytes: Data) async throws {
    if closed { throw HostFailure.transport }
    feed(bytes)
  }
  func close() {
    closed = true
    waiting?.resume(throwing: HostFailure.transport)
    waiting = nil
  }
}

final class LoopbackTests: XCTestCase {
  private var fixtureDirectory: URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("protocol/fixtures")
  }
  func testLoopbackOrderedMessagesAndClose() async throws {
    let listener = try BoundedByteListener(port: 0, noDelay: true, address: "127.0.0.1")
    let port = try await listener.boundPort()
    let incoming = Task { try await listener.accept() }
    let client = WireConnection(
      NetworkByteConnection(NWConnection(host: .ipv4(.loopback), port: port, using: .tcp)))
    let hello = try XCTUnwrap(
      WireCodec.decode(
        Data(
          contentsOf:
            fixtureDirectory.appendingPathComponent("01-client-hello-v1.bin"))))
    try await client.send(hello)
    let server = WireConnection(try await incoming.value)
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
  func testMirriFramingAcrossRawByteFragmentsAndClose() async throws {
    let bytes = FragmentedBytes()
    let channel = WireConnection(bytes)
    let fixture = try Data(
      contentsOf: fixtureDirectory.appendingPathComponent("01-client-hello-v1.bin"))
    let reading = Task { try await channel.read() }
    for offset in stride(from: 0, to: fixture.count, by: 7) {
      await bytes.feed(fixture.subdata(in: offset..<min(offset + 7, fixture.count)))
    }
    guard case .message(let received) = try await reading.value else {
      return XCTFail("Expected assembled ClientHello")
    }
    XCTAssertEqual(received.type, 1)
    await channel.close()
    do {
      _ = try await channel.read()
      XCTFail("Closing the byte connection must wake Mirri reads")
    } catch {
      // Expected after closing the byte owner.
    }
  }
  func testAdapterDeliversFinalBytesBeforeHalfCloseEOF() async throws {
    let listener = try BoundedByteListener(port: 0, address: "127.0.0.1")
    defer { listener.close() }
    let port = try await listener.boundPort()
    let accepting = Task { try await listener.accept() }
    let client = NWConnection(host: .ipv4(.loopback), port: port, using: .tcp)
    client.start(queue: DispatchQueue(label: "dev.mirri.tests.half-close"))
    let watchdog = Task {
      try? await Task.sleep(for: .seconds(3))
      if !Task.isCancelled {
        client.cancel()
        listener.close()  // Interrupt accept/read if the platform never delivers FIN.
      }
    }
    defer {
      watchdog.cancel()
      client.cancel()
    }
    let fixture = try Data(
      contentsOf: fixtureDirectory.appendingPathComponent("01-client-hello-v1.bin"))
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      client.send(
        content: fixture, contentContext: .finalMessage, isComplete: true,
        completion: .contentProcessed { error in
          if error == nil {
            continuation.resume()
          } else {
            continuation.resume(throwing: HostFailure.transport)
          }
        })
    }
    let server = try await accepting.value
    var received = Data()
    while received.count < fixture.count { received.append(try await server.receive()) }
    XCTAssertEqual(received, fixture)
    do {
      _ = try await server.receive()
      XCTFail("EOF after final bytes must end the byte stream")
    } catch {
      XCTAssertEqual(error as? HostFailure, .transport)
    }
    await server.close()
  }
  func testConcurrentListenerAcceptFailsInsteadOfLosingPendingReader() async throws {
    let listener = try BoundedByteListener(port: 0, address: "127.0.0.1")
    defer { listener.close() }
    let first = Task { try await listener.accept() }
    for _ in 0..<100 {
      if listener.hasPendingAccept { break }
      await Task.yield()
    }
    guard listener.hasPendingAccept else {
      listener.close()
      _ = await first.result
      return XCTFail("first accept was never registered")
    }
    do {
      _ = try await listener.accept()
      XCTFail("second accept must not replace the pending continuation")
    } catch {
      XCTAssertEqual(error as? HostFailure, .invalidState)
    }
    let port = try await listener.boundPort()
    let client = NetworkByteConnection(
      NWConnection(
        host: .ipv4(.loopback), port: port,
        using: .tcp))
    try await client.write(Data([42]))
    let server = try await first.value
    let received = try await server.receive()
    XCTAssertEqual(received, Data([42]))
    await client.close()
    await server.close()
  }
}
