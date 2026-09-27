import Crypto
import Foundation
import Network
import Security
import SwiftASN1
import X509
import XCTest

@testable import MirriHostCore

private actor BootstrapBytes: ByteConnection {
  private var incoming: [Data]
  private(set) var outbound: [Data] = []
  init(_ incoming: [Data]) { self.incoming = incoming }
  func receive() throws -> Data {
    guard !incoming.isEmpty else { throw HostFailure.transport }
    return incoming.removeFirst()
  }
  func write(_ data: Data) { outbound.append(data) }
  func close() {}
}

final class NetworkBootstrapTests: XCTestCase {
  func testProductionIdentityHasP256KeyIPAndExactDERPin() throws {
    let address = LocalIPv4Address(interface: "synthetic", address: "192.0.2.10")
    let generated = try NetworkIdentity.create(for: address)
    let cert = try Certificate(derEncoded: [UInt8](generated.certificateDER))
    XCTAssertEqual(generated.pin, Data(SHA256.hash(data: generated.certificateDER)))
    let names = try cert.extensions.subjectAlternativeNames
    XCTAssertEqual(names?.count, 1)
    if case .ipAddress(let octets) = names?.first {
      XCTAssertEqual(Array(octets.bytes), address.octets)
    } else {
      XCTFail("certificate must identify the selected IPv4 endpoint")
    }
    XCTAssertEqual(generated.expiresAt.timeIntervalSinceNow, 86_400, accuracy: 10)
  }
  func testBootstrapRetainsCoalescedWireDataAndDeniesBadToken() async throws {
    let token = Data(repeating: 0x36, count: 32)
    let header = Data([0x4d, 0x52, 0x4e, 0x42, 0, 1, 0, 1]) + token
    let source = BootstrapBytes([header.prefix(3), Data(header.dropFirst(3)) + Data([1, 2, 3])])
    let connected = try await NetworkBootstrap.accept(source, token: token, epoch: 7)
    let response = await source.outbound
    XCTAssertEqual(response, [Data([0x4d, 0x52, 0x4e, 0x42, 0, 1, 0, 0, 0, 0, 0, 7])])
    let trailing = try await connected.receive()
    XCTAssertEqual(trailing, Data([1, 2, 3]))
    let wrong = BootstrapBytes([header])
    do {
      _ = try await NetworkBootstrap.accept(wrong, token: Data(repeating: 2, count: 32), epoch: 7)
      XCTFail("invalid token should be rejected explicitly without an epoch")
    } catch {
      XCTAssertEqual(error as? HostFailure, .unauthorized)
    }
    let rejected = await wrong.outbound
    XCTAssertEqual(rejected, [Data([0x4d, 0x52, 0x4e, 0x42, 0, 1, 0, 1, 0, 0, 0, 0])])
    let malformed = BootstrapBytes([Data([0x00]) + Data(header.dropFirst())])
    do {
      _ = try await NetworkBootstrap.accept(malformed, token: token, epoch: 7)
      XCTFail("malformed request should not receive a response")
    } catch {
      XCTAssertEqual(error as? HostFailure, .unauthorized)
    }
    let malformedResponse = await malformed.outbound
    XCTAssertTrue(malformedResponse.isEmpty)
  }
  func testListenerRejectsWildcardNamesMulticastAndUnpinnedLAN() throws {
    let identity = try NetworkIdentity.create(
      for: LocalIPv4Address(interface: "synthetic", address: "127.0.0.1"))
    for address in [
      "0.0.0.0", "0.4.5.6", "239.1.2.3", "255.255.255.255", "example.test", "01.2.3.4", "127.0.0.2",
    ] {
      XCTAssertThrowsError(
        try BoundedByteListener(port: 0, address: address, identity: identity.identity))
    }
    XCTAssertThrowsError(try BoundedByteListener(port: 0, address: "192.0.2.1"))
  }
  func testActualTLSListenerAcceptsExactPinAndRejectsDifferentPin() async throws {
    let identity = try NetworkIdentity.create(
      for: LocalIPv4Address(interface: "synthetic", address: "127.0.0.1"))
    for matching in [true, false] {
      let listener = try BoundedByteListener(
        port: 0, address: "127.0.0.1", identity: identity.identity)
      let port = try await listener.boundPort()
      let incoming = Task { try await listener.accept() }
      let tls = NWProtocolTLS.Options()
      let expected = matching ? identity.pin : Data(repeating: 0x11, count: 32)
      sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
      sec_protocol_options_set_verify_block(
        tls.securityProtocolOptions,
        { _, trust, complete in
          let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
          guard let cert = (SecTrustCopyCertificateChain(secTrust) as? [SecCertificate])?.first
          else {
            complete(false)
            return
          }
          let actual = Data(SHA256.hash(data: SecCertificateCopyData(cert) as Data))
          complete(actual == expected)
        }, DispatchQueue(label: "dev.mirri.tests.verify"))
      let client = NetworkByteConnection(
        NWConnection(
          host: .ipv4(.loopback), port: port, using: NWParameters(tls: tls, tcp: .init())))
      if matching {
        try await client.write(Data([0x42]))
        let server = try await incoming.value
        let data = try await server.receive()
        XCTAssertEqual(data, Data([0x42]))
        await server.close()
      } else {
        do {
          try await client.write(Data([0x42]))
          XCTFail("wrong pin must fail TLS")
        } catch {
          // Pin rejection prevents application bytes.
        }
        let server = try? await incoming.value
        await server?.close()
      }
      await client.close()
      listener.close()
    }
  }
  func testNetworkRetryDoesNotRelaunchADBOrCreateReverseMappings() async throws {
    guard let address = LocalIPv4Address.available().first else {
      throw XCTSkip("No assigned non-loopback IPv4 address for a real listener")
    }
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let calls = folder.appendingPathComponent("calls")
    let binary = folder.appendingPathComponent("fake-adb")
    let script = """
      #!/bin/sh
      echo "$@" >> "\(calls.path)"
      if [ "$1" = devices ]; then
        printf 'List of devices attached\nA device usb:1 model:synthetic\n'
      elif [ "$4" = dumpsys ]; then
        printf 'versionCode=3 versionName=0.2-network\n'
      fi
      """
    try Data(script.utf8).write(to: binary)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
    let service = USBDeviceService(adb: ADBClient(executable: binary, commandTimeout: 3))
    let device = ADBDevice(serial: "A", model: "synthetic")
    let route = try await service.networkRoute(on: device, address: address)
    let credentials = AttemptCredentials(
      token: Data(repeating: 0x22, count: 32), sessionId: Data(repeating: 0x33, count: 16),
      epoch: 1)
    do {
      _ = try await route.prepare()
      try await route.bootstrap(credentials)
      try await route.retry()
      try await route.bootstrap(
        AttemptCredentials(
          token: credentials.token, sessionId: credentials.sessionId, epoch: 2))
      await route.close()
    } catch {
      await route.close()
      throw error
    }
    let log = try String(contentsOf: calls, encoding: .utf8)
    XCTAssertEqual(log.components(separatedBy: " am start ").count - 1, 1)
    XCTAssertFalse(log.contains(" reverse "))
    let next = try await service.route(on: device)
    await next.close()
  }
  func testNetworkStopJoinsInFlightFirstLaunchBeforeReleasingService() async throws {
    guard let address = LocalIPv4Address.available().first else {
      throw XCTSkip("No assigned non-loopback IPv4 address")
    }
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let entered = folder.appendingPathComponent("entered")
    let proceed = folder.appendingPathComponent("proceed")
    let binary = folder.appendingPathComponent("fake-adb")
    let script = """
      #!/bin/sh
      if [ "$1" = devices ]; then
        printf 'List of devices attached\nA device usb:1 model:synthetic\n'
      elif [ "$4" = dumpsys ]; then
        printf 'versionCode=3 versionName=0.2-network\n'
      elif [ "$4" = am ]; then
        touch "\(entered.path)"
        while [ ! -f "\(proceed.path)" ]; do sleep 0.01; done
      fi
      """
    try Data(script.utf8).write(to: binary)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
    let service = USBDeviceService(adb: ADBClient(executable: binary, commandTimeout: 3))
    let device = ADBDevice(serial: "A", model: "synthetic")
    let route = try await service.networkRoute(on: device, address: address)
    _ = try await route.prepare()
    let launching = Task {
      try await route.bootstrap(
        AttemptCredentials(
          token: Data(repeating: 0x12, count: 32), sessionId: Data(repeating: 0x34, count: 16),
          epoch: 1))
    }
    for _ in 0..<100 where !FileManager.default.fileExists(atPath: entered.path) {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: entered.path))
    let closing = Task { await route.close() }
    do {
      _ = try await service.route(on: device)
      XCTFail("pending network launch still owns the service route")
    } catch {
      XCTAssertEqual(error as? HostFailure, .invalidState)
    }
    try Data().write(to: proceed)
    await closing.value
    do {
      try await launching.value
      XCTFail("late bootstrap completion must not revive a closed route")
    } catch {
      XCTAssertEqual(error as? HostFailure, .invalidState)
    }
    let next = try await service.route(on: device)
    await next.close()
  }
}
