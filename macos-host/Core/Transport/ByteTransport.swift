import Foundation
import Network

/// Raw, ordered bytes. Framing and outbound wire sequences belong to the Mirri layer.
public protocol ByteConnection: Sendable {
  func receive() async throws -> Data
  func write(_ bytes: Data) async throws
  func close() async
}

public protocol ByteListener: Sendable {
  func accept() async throws -> any ByteConnection
  func close()
}

/// Loopback-only listener; one pending connection and one active connection at a time.
public final class LoopbackByteListener: ByteListener, @unchecked Sendable {
  private let listener: NWListener
  private let queue = DispatchQueue(label: "dev.mirri.listener")
  private let lock = NSLock()
  private var offered: CheckedContinuation<NWConnection, Error>?
  private var waiting: NWConnection?
  private var active: NWConnection?
  private var closed = false
  public init(port: UInt16, noDelay: Bool = false) throws {
    guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
      throw HostFailure.transport
    }
    let tcp = NWProtocolTCP.Options()
    tcp.noDelay = noDelay
    let params = NWParameters(tls: nil, tcp: tcp)
    params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: endpointPort)
    listener = try NWListener(using: params)
    listener.newConnectionHandler = { [weak self] connection in self?.offer(connection) }
    listener.stateUpdateHandler = { [weak self] state in
      if case .failed = state { self?.close() }
    }
    listener.start(queue: queue)
  }
  private func offer(_ connection: NWConnection) {
    lock.lock()
    if closed || active != nil || waiting != nil {
      lock.unlock()
      connection.cancel()
      return
    }
    if let offered {
      self.offered = nil
      active = connection
      lock.unlock()
      offered.resume(returning: connection)
    } else {
      waiting = connection
      lock.unlock()
    }
  }
  public func accept() async throws -> any ByteConnection {
    let connection = try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<NWConnection, Error>) in
      lock.lock()
      if closed {
        lock.unlock()
        continuation.resume(throwing: HostFailure.transport)
      } else if offered != nil || active != nil {
        lock.unlock()
        continuation.resume(throwing: HostFailure.invalidState)
      } else if let waiting {
        self.waiting = nil
        active = waiting
        lock.unlock()
        continuation.resume(returning: waiting)
      } else {
        offered = continuation
        lock.unlock()
      }
    }
    return NetworkByteConnection(connection)
  }
  public func boundPort() async throws -> NWEndpoint.Port {
    for _ in 0..<100 {
      let stopped = lock.withLock { closed }
      if stopped { throw HostFailure.transport }
      if let port = listener.port, port.rawValue != 0 { return port }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw HostFailure.timeout
  }
  var hasPendingAccept: Bool { lock.withLock { offered != nil } }
  public func close() {
    lock.lock()
    closed = true
    let offered = self.offered
    self.offered = nil
    let waiting = self.waiting
    self.waiting = nil
    let active = self.active
    self.active = nil
    lock.unlock()
    offered?.resume(throwing: HostFailure.transport)
    waiting?.cancel()
    active?.cancel()
    listener.cancel()
  }
}

/// Network-framework byte adapter. A pending write is bounded by its completion or 2 s deadline.
public actor NetworkByteConnection: ByteConnection {
  private let connection: NWConnection
  private var pendingWrite: UInt64?
  private var nextWrite: UInt64 = 0
  private var terminated = false
  private var receivedEOF = false
  public init(_ connection: NWConnection) {
    self.connection = connection
    connection.start(queue: DispatchQueue(label: "dev.mirri.socket"))
  }
  public func receive() async throws -> Data {
    guard !terminated, !receivedEOF else { throw HostFailure.transport }
    let (data, complete) = try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<(Data?, Bool), Error>) in
      connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
        data, _, complete, error in
        if error != nil {
          continuation.resume(throwing: HostFailure.transport)
        } else {
          continuation.resume(returning: (data, complete))
        }
      }
    }
    // Network.framework may report final bytes and EOF in the same callback.
    // Deliver those bytes exactly once; only the next read reports EOF.
    if complete { receivedEOF = true }
    guard let data, !data.isEmpty else { throw HostFailure.transport }
    return data
  }
  public func write(_ bytes: Data) async throws {
    guard !terminated, pendingWrite == nil, nextWrite < UInt64.max else {
      throw HostFailure.transport
    }
    nextWrite += 1
    let id = nextWrite
    pendingWrite = id
    let watchdog = Task { [weak self] in
      try? await Task.sleep(for: .seconds(2))
      if !Task.isCancelled { await self?.abortWrite(id) }
    }
    defer {
      watchdog.cancel()
      pendingWrite = nil
    }
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      connection.send(
        content: bytes,
        completion: .contentProcessed { error in
          if error != nil {
            continuation.resume(throwing: HostFailure.transport)
          } else {
            continuation.resume()
          }
        })
    }
  }
  private func abortWrite(_ id: UInt64) {
    guard pendingWrite == id else { return }
    terminated = true
    connection.cancel()
  }
  public func close() {
    terminated = true
    connection.cancel()
  }
}
