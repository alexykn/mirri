import Foundation
import Network

/// Listener never binds wildcard or accepts more than one pending connection.
public final class LoopbackListener: @unchecked Sendable {
  private let listener: NWListener
  private let queue = DispatchQueue(label: "dev.mirri.listener")
  private let lock = NSLock()
  private var offered: CheckedContinuation<NWConnection, Error>?
  private var waiting: NWConnection?
  private var closed = false
  private var occupied = false
  private let video: Bool
  public init(port: UInt16, noDelay: Bool = false, video: Bool = false) throws {
    self.video = video
    guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
      throw HostFailure.transport
    }
    let tcp = NWProtocolTCP.Options()
    tcp.noDelay = noDelay
    let params = NWParameters(tls: nil, tcp: tcp)
    params.requiredLocalEndpoint = .hostPort(
      host: .ipv4(.loopback), port: endpointPort)
    listener = try NWListener(using: params)
    listener.newConnectionHandler = { [weak self] conn in self?.offer(conn) }
    listener.stateUpdateHandler = { [weak self] state in
      if case .failed = state { self?.close() }
    }
    listener.start(queue: queue)
  }
  private func offer(_ connection: NWConnection) {
    lock.lock()
    if closed || occupied || waiting != nil {
      lock.unlock()
      connection.cancel()
      return
    }
    if let offered {
      self.offered = nil
      occupied = true
      lock.unlock()
      offered.resume(returning: connection)
    } else {
      occupied = true
      waiting = connection
      lock.unlock()
    }
  }
  public func accept() async throws -> WireConnection {
    let connection = try await withCheckedThrowingContinuation {
      (c: CheckedContinuation<NWConnection, Error>) in
      lock.lock()
      if closed {
        lock.unlock()
        c.resume(throwing: HostFailure.transport)
        return
      }
      if let waiting {
        self.waiting = nil
        lock.unlock()
        c.resume(returning: waiting)
      } else {
        offered = c
        lock.unlock()
      }
    }
    return WireConnection(connection, video: video)
  }
  public func boundPort() async throws -> NWEndpoint.Port {
    for _ in 0..<100 {
      if isClosed { throw HostFailure.transport }
      if let port = listener.port, port.rawValue != 0 { return port }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw HostFailure.timeout
  }
  private var isClosed: Bool {
    lock.lock()
    defer { lock.unlock() }
    return closed
  }
  public func releaseSlot() {
    lock.lock()
    occupied = false
    lock.unlock()
  }
  public func close() {
    lock.lock()
    closed = true
    let offered = self.offered
    self.offered = nil
    let waiting = self.waiting
    self.waiting = nil
    lock.unlock()
    offered?.resume(throwing: HostFailure.transport)
    waiting?.cancel()
    listener.cancel()
  }
}

/// One reader and serialized bounded writes. Receive frames are decoded before dispatch.
public actor WireConnection {
  private let connection: NWConnection
  private var framer: WireFramer
  private var records: [FramedRecord] = []
  private var nextOutbound: UInt64 = 0
  private var pendingWrite: UInt64?
  private var terminated = false
  public init(_ connection: NWConnection, video: Bool = false) {
    self.connection = connection
    framer = WireFramer(videoChannel: video)
    connection.start(queue: DispatchQueue(label: "dev.mirri.socket"))
  }
  public func read() async throws -> FramedRecord {
    while records.isEmpty {
      guard !terminated else { throw HostFailure.transport }
      let data: Data = try await withCheckedThrowingContinuation { continuation in
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
          data, _, complete, error in
          if error != nil || complete {
            continuation.resume(throwing: HostFailure.transport)
          } else if let data, !data.isEmpty {
            continuation.resume(returning: data)
          } else {
            continuation.resume(throwing: HostFailure.transport)
          }
        }
      }
      records += try framer.append(data)
    }
    return records.removeFirst()
  }
  /// No more than one write is outstanding on this actor. Caller must apply an admission limit.
  public func send(_ message: WireMessage) async throws {
    guard !terminated, pendingWrite == nil, nextOutbound < UInt64.max else {
      throw HostFailure.transport
    }
    let frame = try WireCodec.encode(
      WireMessage(
        type: message.type, sequence: nextOutbound,
        timestamp: DispatchTime.now().uptimeNanoseconds, fields: message.fields))
    nextOutbound += 1
    let writeId = nextOutbound
    pendingWrite = writeId
    let watchdog = Task { [weak self] in
      try? await Task.sleep(for: .seconds(2))
      if !Task.isCancelled { await self?.abortWrite(writeId) }
    }
    defer {
      watchdog.cancel()
      pendingWrite = nil
    }
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      connection.send(
        content: frame,
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

public enum Authenticator {
  /// Fixed-size constant-time comparison; never log either value.
  public static func equals(_ lhs: Data, _ rhs: Data) -> Bool {
    guard lhs.count == 32, rhs.count == 32 else { return false }
    var difference: UInt8 = 0
    for index in 0..<32 { difference |= lhs[index] ^ rhs[index] }
    return difference == 0
  }
}
