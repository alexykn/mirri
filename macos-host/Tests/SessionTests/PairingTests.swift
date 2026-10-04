import Foundation
import Network
import XCTest

@testable import MirriHostCore

final class PairingTests: XCTestCase {
  private func temporaryStore() -> (PairingStore, URL) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    return (PairingStore(directory: directory), directory)
  }

  func testGrantVerifiesOnlyWithItsOwnSecretAndSurvivesReload() async throws {
    let (store, directory) = temporaryStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let grant = try await store.issue(label: "Tablet")
    let pin = try await store.identity().pin
    XCTAssertEqual(grant.pin, pin)
    let verified = await store.verify(id: grant.id, key: grant.key)
    XCTAssertEqual(verified, PairedTablet(id: grant.id, label: "Tablet"))
    let wrongKey = await store.verify(id: grant.id, key: Data(repeating: 0, count: 32))
    XCTAssertNil(wrongKey)
    let wrongID = await store.verify(id: Data(repeating: 0, count: 16), key: grant.key)
    XCTAssertNil(wrongID)
    // A new process sees the same identity and the same tablet.
    let reloaded = PairingStore(directory: directory)
    let reloadedPin = try await reloaded.identity().pin
    XCTAssertEqual(reloadedPin, pin)
    let stillPaired = await reloaded.verify(id: grant.id, key: grant.key)
    XCTAssertNotNil(stillPaired)
    try await reloaded.removeAll()
    let removed = await reloaded.verify(id: grant.id, key: grant.key)
    XCTAssertNil(removed)
  }

  func testStoreFilesAreOwnerOnlyAndNeverHoldTheTabletSecret() async throws {
    let (store, directory) = temporaryStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let grant = try await store.issue(label: "Tablet")
    for name in ["identity.json", "tablets.json"] {
      let path = directory.appendingPathComponent(name).path
      let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
      XCTAssertEqual(mode, 0o600)
    }
    let tablets = try Data(contentsOf: directory.appendingPathComponent("tablets.json"))
    XCTAssertNil(tablets.range(of: grant.key.base64EncodedData()))
    XCTAssertNil(tablets.range(of: grant.key))
  }

  func testOnlyEightMostRecentGrantsRemain() async throws {
    let (store, directory) = temporaryStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    var grants: [PairingGrant] = []
    for index in 0..<9 { grants.append(try await store.issue(label: "T\(index)")) }
    let oldest = await store.verify(id: grants[0].id, key: grants[0].key)
    XCTAssertNil(oldest)
    let newest = await store.verify(id: grants[8].id, key: grants[8].key)
    XCTAssertNotNil(newest)
    let count = await store.paired().count
    XCTAssertEqual(count, 8)
  }

  func testRendezvousWireLayoutMatchesTheTablet() {
    var hello = Data([0x4d, 0x52, 0x52, 0x56, 0, 1, 0, 1])
    hello.append(Data(repeating: 0x11, count: 16))
    hello.append(Data(repeating: 0x22, count: 32))
    hello.append(2)
    let parsed = RendezvousWire.hello(hello)
    XCTAssertEqual(parsed?.id, Data(repeating: 0x11, count: 16))
    XCTAssertEqual(parsed?.key, Data(repeating: 0x22, count: 32))
    XCTAssertEqual(parsed?.reason, .recovering)
    XCTAssertNil(RendezvousWire.hello(hello.dropLast()))
    var badReason = hello
    badReason[56] = 9
    XCTAssertNil(RendezvousWire.hello(badReason))
    let launch = RendezvousLaunch(
      token: Data(repeating: 0x12, count: 32), epoch: 7, address: [192, 0, 2, 15],
      pin: Data(repeating: 0x34, count: 32), rtc: true, sessionId: Data(repeating: 0x56, count: 16))
    let frame = RendezvousWire.launch(launch)
    XCTAssertEqual(frame?.count, 8 + 89)
    XCTAssertEqual(frame?.prefix(8), Data([0x4d, 0x52, 0x52, 0x56, 0, 1, 0, 3]))
    XCTAssertEqual(frame.map { Array($0[40..<48]) }, [0, 0, 0, 7, 192, 0, 2, 15])
    XCTAssertEqual(frame?[80], 1)
    XCTAssertNil(
      RendezvousWire.launch(
        RendezvousLaunch(
          token: Data(), epoch: 7, address: [192, 0, 2, 15], pin: launch.pin, rtc: true,
          sessionId: launch.sessionId)))
  }

  /// Real TLS on loopback: a paired secret is admitted and held; a wrong one is rejected.
  func testListenerAdmitsOnlyAPairedSecret() async throws {
    let (store, directory) = temporaryStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let grant = try await store.issue(label: "Tablet")
    let arrivals = AsyncStream<RendezvousPresence>.makeStream()
    let listener = try RendezvousListener(
      identity: try await store.identity(), port: 0,
      verify: { id, key in await store.verify(id: id, key: key) },
      onArrival: { arrivals.continuation.yield($0) }, onGone: { _ in })
    listener.start()
    defer { listener.stop() }
    var port: UInt16?
    for _ in 0..<100 where port == nil {
      port = listener.boundPort.flatMap { $0 == 0 ? nil : $0 }
      if port == nil { try await Task.sleep(for: .milliseconds(10)) }
    }
    let bound = try XCTUnwrap(port)

    func exchange(key: Data) async throws -> Data {
      let tls = NWProtocolTLS.Options()
      sec_protocol_options_set_verify_block(
        tls.securityProtocolOptions, { _, _, complete in complete(true) },
        DispatchQueue(label: "test.verify"))
      let connection = NWConnection(
        host: "127.0.0.1", port: NWEndpoint.Port(rawValue: bound)!,
        using: NWParameters(tls: tls, tcp: NWProtocolTCP.Options()))
      connection.start(queue: DispatchQueue(label: "test.client"))
      defer { connection.cancel() }
      var hello = Data([0x4d, 0x52, 0x52, 0x56, 0, 1, 0, 1])
      hello.append(grant.id)
      hello.append(key)
      hello.append(1)
      connection.send(content: hello, completion: .contentProcessed { _ in })
      return try await withCheckedThrowingContinuation { continuation in
        connection.receive(minimumIncompleteLength: 8, maximumLength: 8) { data, _, _, error in
          if let data, data.count == 8 {
            continuation.resume(returning: data)
          } else {
            continuation.resume(throwing: error ?? HostFailure.transport)
          }
        }
      }
    }
    let rejected = try await exchange(key: Data(repeating: 0, count: 32))
    XCTAssertEqual(rejected, RendezvousWire.rejected)
    let waiting = try await exchange(key: grant.key)
    XCTAssertEqual(waiting, RendezvousWire.wait)
    var iterator = arrivals.stream.makeAsyncIterator()
    let presence = await iterator.next()
    XCTAssertEqual(presence?.tablet.label, "Tablet")
    XCTAssertEqual(presence?.reason, .opened)
    presence?.close()
  }
}
