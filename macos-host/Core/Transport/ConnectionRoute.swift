import Foundation

/// Credentials for one host-authoritative attempt. Routes never interpret Mirri messages.
public struct AttemptCredentials: Sendable {
  public let token: Data
  public let sessionId: Data
  public let epoch: UInt32
  public init(token: Data, sessionId: Data, epoch: UInt32) {
    self.token = token
    self.sessionId = sessionId
    self.epoch = epoch
  }
}

/// Supplies independently accepted, ordered byte streams. Lifecycle policy stays in the coordinator.
public protocol HostConnectionRoute: Sendable {
  var displayLabel: String { get }
  func prepare() async throws -> String
  func retry() async throws
  func bootstrap(_ credentials: AttemptCredentials) async throws
  func acceptControl() async throws -> any ByteConnection
  func acceptVideo() async throws -> any ByteConnection
  func interrupt() async
  func close() async
}
