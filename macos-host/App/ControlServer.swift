import Darwin
import Foundation

/// Local endpoint for the `mirri` terminal command. One JSON object per line,
/// one request per connection, over a user-only Unix socket. It carries no
/// credentials and reaches only the same owner actions as the menu-bar panel.
final class ControlServer: @unchecked Sendable {
  /// Keep in sync with `Tools/MirriCLI/main.swift`.
  static var socketURL: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Mirri", isDirectory: true)
      .appendingPathComponent("control.sock")
  }

  private let handler: @MainActor @Sendable (Data) async -> Data
  private let queue = DispatchQueue(label: "dev.mirri.control")
  private var listener: Int32 = -1
  private var source: DispatchSourceRead?

  init(handler: @escaping @MainActor @Sendable (Data) async -> Data) {
    self.handler = handler
  }

  private static func address(_ path: String) -> sockaddr_un? {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
    return address
  }

  private static func isLive(_ address: sockaddr_un) -> Bool {
    let probe = socket(AF_UNIX, SOCK_STREAM, 0)
    guard probe >= 0 else { return false }
    defer { close(probe) }
    var address = address
    return withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
      }
    }
  }

  /// Returns false if another running Mirri already owns the endpoint.
  @discardableResult func start() -> Bool {
    let url = Self.socketURL
    try? FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    guard var address = Self.address(url.path), !Self.isLive(address) else { return false }
    unlink(url.path)  // Only a stale socket: the live probe above failed.
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return false }
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
      }
    }
    guard bound, chmod(url.path, 0o600) == 0, listen(descriptor, 8) == 0 else {
      close(descriptor)
      return false
    }
    listener = descriptor
    let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
    source.setEventHandler { [weak self] in self?.accept() }
    source.resume()
    self.source = source
    return true
  }

  func stop() {
    source?.cancel()
    source = nil
    if listener >= 0 {
      close(listener)
      listener = -1
      unlink(Self.socketURL.path)
    }
  }

  private func accept() {
    let client = Darwin.accept(listener, nil, nil)
    guard client >= 0 else { return }
    var enabled: Int32 = 1
    setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
    var deadline = timeval(tv_sec: 5, tv_usec: 0)
    setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &deadline, socklen_t(MemoryLayout<timeval>.size))
    let handler = self.handler
    DispatchQueue.global(qos: .userInitiated).async {
      guard let request = Self.readLine(client) else {
        close(client)
        return
      }
      Task {
        var reply = await handler(request)
        reply.append(0x0A)
        reply.withUnsafeBytes { bytes in
          var offset = 0
          while offset < bytes.count {
            let written = write(client, bytes.baseAddress! + offset, bytes.count - offset)
            if written <= 0 { break }
            offset += written
          }
        }
        close(client)
      }
    }
  }

  private static func readLine(_ descriptor: Int32) -> Data? {
    var line = Data()
    var chunk = [UInt8](repeating: 0, count: 4096)
    while line.count <= 64 * 1024 {
      let count = read(descriptor, &chunk, chunk.count)
      guard count > 0 else { return nil }
      if let end = chunk[..<count].firstIndex(of: 0x0A) {
        line.append(contentsOf: chunk[..<end])
        return line
      }
      line.append(contentsOf: chunk[..<count])
    }
    return nil
  }
}
