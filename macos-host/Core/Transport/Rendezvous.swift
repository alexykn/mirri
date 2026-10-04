import Foundation
import Network

/// Why a paired tablet is waiting. Only a person opening the app, or a session
/// that broke, asks the host to start streaming by itself.
public enum RendezvousReason: UInt8, Sendable { case idle = 0, opened = 1, recovering = 2 }

/// The same facts an ADB launch passes as Intent extras.
public struct RendezvousLaunch: Sendable, Equatable {
  public let token: Data
  public let epoch: UInt32
  public let address: [UInt8]
  public let pin: Data
  public let rtc: Bool
  public let sessionId: Data
  public init(
    token: Data, epoch: UInt32, address: [UInt8], pin: Data, rtc: Bool, sessionId: Data
  ) {
    self.token = token
    self.epoch = epoch
    self.address = address
    self.pin = pin
    self.rtc = rtc
    self.sessionId = sessionId
  }
}

/// MRRV v1, spoken only inside TLS to the host's pinned persistent certificate.
public enum RendezvousWire {
  public static let helloLength = 57
  private static func header(_ kind: UInt8) -> Data {
    Data([0x4d, 0x52, 0x52, 0x56, 0, 1, 0, kind])
  }
  public static func hello(_ data: Data) -> (id: Data, key: Data, reason: RendezvousReason)? {
    let bytes = Data(data)
    guard bytes.count == helloLength, bytes.prefix(8) == header(1),
      let reason = RendezvousReason(rawValue: bytes[56])
    else { return nil }
    return (Data(bytes[8..<24]), Data(bytes[24..<56]), reason)
  }
  public static let wait = header(2)
  public static let rejected = header(4)
  public static func launch(_ launch: RendezvousLaunch) -> Data? {
    guard launch.token.count == 32, launch.epoch > 0, launch.address.count == 4,
      launch.pin.count == 32, launch.sessionId.count == 16
    else { return nil }
    var frame = header(3)
    frame.append(launch.token)
    frame.append(contentsOf: [
      UInt8(truncatingIfNeeded: launch.epoch >> 24), UInt8(truncatingIfNeeded: launch.epoch >> 16),
      UInt8(truncatingIfNeeded: launch.epoch >> 8), UInt8(truncatingIfNeeded: launch.epoch),
    ])
    frame.append(contentsOf: launch.address)
    frame.append(launch.pin)
    frame.append(launch.rtc ? 1 : 0)
    frame.append(launch.sessionId)
    return frame
  }
}

/// One authenticated tablet holding its rendezvous connection open.
public final class RendezvousPresence: @unchecked Sendable {
  public let tablet: PairedTablet
  public let reason: RendezvousReason
  /// The host IPv4 address the tablet reached; the session binds the same one.
  public let localAddress: LocalIPv4Address?
  private let connection: NWConnection
  private let lock = NSLock()
  private var gone = false
  private var heartbeat: Task<Void, Never>?
  private var onGone: (@Sendable (RendezvousPresence) -> Void)?

  init(
    tablet: PairedTablet, reason: RendezvousReason, localAddress: LocalIPv4Address?,
    connection: NWConnection, onGone: @escaping @Sendable (RendezvousPresence) -> Void
  ) {
    self.tablet = tablet
    self.reason = reason
    self.localAddress = localAddress
    self.connection = connection
    self.onGone = onGone
    // The tablet treats silence as a dead host and looks for it again.
    heartbeat = Task { [weak self] in
      while !Task.isCancelled {
        guard let self, (try? await self.send(RendezvousWire.wait)) != nil else { break }
        try? await Task.sleep(for: .seconds(2))
      }
      // Cancelled means a launch is being sent on this connection; only a
      // failed heartbeat ends the presence.
      if !Task.isCancelled { self?.close() }
    }
  }

  public var isAlive: Bool { lock.withLock { !gone } }

  private func send(_ data: Data) async throws {
    guard isAlive else { throw HostFailure.transport }
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      connection.send(
        content: data,
        completion: .contentProcessed { error in
          if error != nil {
            continuation.resume(throwing: HostFailure.transport)
          } else {
            continuation.resume()
          }
        })
    }
  }

  /// Hands the tablet its session and ends this presence.
  public func sendLaunch(_ launch: RendezvousLaunch) async throws {
    guard let frame = RendezvousWire.launch(launch) else { throw HostFailure.invalidState }
    heartbeat?.cancel()
    defer { close() }
    try await send(frame)
  }

  public func close() {
    let callback = lock.withLock { () -> (@Sendable (RendezvousPresence) -> Void)? in
      guard !gone else { return nil }
      gone = true
      let callback = onGone
      onGone = nil
      return callback
    }
    guard let callback else { return }
    heartbeat?.cancel()
    connection.cancel()
    callback(self)
  }
}

/// Advertises the host on the LAN and admits only tablets that hold a pairing
/// secret. TLS uses the persistent identity the tablet pinned when it was paired.
public final class RendezvousListener: @unchecked Sendable {
  public static let port: UInt16 = 5562
  public static let serviceType = "_mirri._tcp"

  private let listener: NWListener
  private let queue = DispatchQueue(label: "dev.mirri.rendezvous")
  private let lock = NSLock()
  private var pending = 0
  private let verify: @Sendable (Data, Data) async -> PairedTablet?
  private let onArrival: @Sendable (RendezvousPresence) -> Void
  private let onGone: @Sendable (RendezvousPresence) -> Void

  public init(
    identity: NetworkIdentity, port: UInt16 = RendezvousListener.port,
    verify: @escaping @Sendable (Data, Data) async -> PairedTablet?,
    onArrival: @escaping @Sendable (RendezvousPresence) -> Void,
    onGone: @escaping @Sendable (RendezvousPresence) -> Void
  ) throws {
    let tls = NWProtocolTLS.Options()
    sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
    sec_protocol_options_set_local_identity(tls.securityProtocolOptions, identity.identity)
    let tcp = NWProtocolTCP.Options()
    tcp.noDelay = true
    let parameters = NWParameters(tls: tls, tcp: tcp)
    // The session that follows is IPv4-only, so the tablet must reach an IPv4 address.
    (parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
    listener = try NWListener(
      using: parameters, on: port == 0 ? .any : NWEndpoint.Port(rawValue: port) ?? .any)
    listener.service = NWListener.Service(type: Self.serviceType)
    self.verify = verify
    self.onArrival = onArrival
    self.onGone = onGone
  }

  public func start() {
    listener.newConnectionHandler = { [weak self] connection in self?.admit(connection) }
    listener.start(queue: queue)
  }
  public func stop() { listener.cancel() }
  public var boundPort: UInt16? { listener.port?.rawValue }

  private func admit(_ connection: NWConnection) {
    let accepted = lock.withLock { () -> Bool in
      guard pending < 8 else { return false }
      pending += 1
      return true
    }
    guard accepted else {
      connection.cancel()
      return
    }
    let settled = Settled { [weak self] in self?.lock.withLock { self?.pending -= 1 } }
    connection.start(queue: queue)
    // An unauthenticated peer gets five seconds, not an open slot.
    queue.asyncAfter(deadline: .now() + 5) {
      if settled.claim() { connection.cancel() }
    }
    connection.receive(
      minimumIncompleteLength: RendezvousWire.helloLength,
      maximumLength: RendezvousWire.helloLength
    ) { [weak self] data, _, _, error in
      guard let self, error == nil, let data, let hello = RendezvousWire.hello(data) else {
        if settled.claim() { connection.cancel() }
        return
      }
      Task {
        let tablet = await self.verify(hello.id, hello.key)
        guard settled.claim() else { return }
        guard let tablet else {
          connection.send(
            content: RendezvousWire.rejected, completion: .contentProcessed { _ in connection.cancel() })
          return
        }
        self.onArrival(
          RendezvousPresence(
            tablet: tablet, reason: hello.reason, localAddress: Self.localAddress(connection),
            connection: connection, onGone: self.onGone))
      }
    }
  }

  private static func localAddress(_ connection: NWConnection) -> LocalIPv4Address? {
    guard case .hostPort(let host, _) = connection.currentPath?.localEndpoint else { return nil }
    let text = "\(host)".split(separator: "%").first.map(String.init) ?? ""
    return LocalIPv4Address.available().first { $0.address == text }
  }
}

/// Exactly one of: authenticated, rejected, or timed out.
private final class Settled: @unchecked Sendable {
  private let lock = NSLock()
  private var done = false
  private let release: @Sendable () -> Void
  init(release: @escaping @Sendable () -> Void) { self.release = release }
  func claim() -> Bool {
    let first = lock.withLock { () -> Bool in
      guard !done else { return false }
      done = true
      return true
    }
    if first { release() }
    return first
  }
}
