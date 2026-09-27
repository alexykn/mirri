import Foundation
import MirriHostCore

/// Loopback-only test fixture server using the production identity, byte adapter and MRNB owner.
@main struct InteropServer {
  static func main() async throws {
    let identity = try NetworkIdentity.create(
      for: LocalIPv4Address(interface: "lo0", address: "127.0.0.1"))
    let listener = try BoundedByteListener(
      port: 0, address: "127.0.0.1", identity: identity.identity)
    defer { listener.close() }
    let port = try await listener.boundPort()
    let pin = identity.pin.map { String(format: "%02x", $0) }.joined()
    // Read exclusively by the owning JVM test process; never a production log.
    FileHandle.standardOutput.write(Data("\(port.rawValue) \(pin)\n".utf8))
    let raw = try await listener.accept()
    do {
      let control = try await NetworkBootstrap.accept(
        raw, token: Data(repeating: 0x42, count: 32), epoch: 7)
      var payload = Data()
      while payload.count < 16 {
        let fragment = try await control.receive()
        guard !fragment.isEmpty, fragment.count <= 16 - payload.count else {
          throw HostFailure.malformed
        }
        payload.append(fragment)
      }
      try await control.write(payload)
      await control.close()
    } catch {
      // A deliberately mismatched pin closes TLS before MRNB. Never disclose
      // authentication details or turn the test helper into a crash report.
      await raw.close()
    }
  }
}
