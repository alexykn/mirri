import Foundation

/// Per-connection, receive-direction policy. Construct anew for every epoch.
/// Authentication of the hello token is the session owner's responsibility.
public struct WireOrder: Sendable {
  public enum Channel: Sendable { case control, video }
  public enum Peer: Sendable { case host, client }
  private let channel: Channel
  private let peer: Peer
  private let epoch: UInt64
  private var sessionId: Data?
  private var nextSequence: UInt64 = 0
  private var generation: UInt64
  private var nextFrame: UInt64 = 0
  private var needsIDR = false

  public init(
    receivingFrom peer: Peer, on channel: Channel, epoch: UInt64, sessionId: Data? = nil,
    previousGeneration: UInt32 = 0
  ) {
    self.peer = peer
    self.channel = channel
    self.epoch = epoch
    self.sessionId = sessionId
    self.generation = UInt64(previousGeneration)
  }
  /// Bind the session after a valid first ClientHello. All subsequent common
  /// envelopes on this ordered control connection must carry this exact ID.
  public mutating func bindSession(_ id: Data) throws {
    guard id.count == 16, sessionId == nil, nextSequence == 1,
      channel == .control, peer == .client
    else { throw WireFailure.malformed }
    sessionId = id
  }
  private static let clientControl: Set<MessageKind> = [
    .clientHello, .clientReady, .inputBatch, .scroll, .zoom, .contextClick, .shortcut,
    .auxiliaryKey, .pong, .clientMetrics, .protocolError, .decoderFailure,
    .requestKeyframe, .sessionRejected, .stopAcknowledged,
  ]
  private static let hostControl: Set<MessageKind> = [
    .sessionConfig, .startStream, .stopSession, .ping, .protocolError,
  ]
  /// Only call for an ignorable future-minor type already validated by WireFramer.
  public mutating func skipUnknown(sequence: UInt64) throws {
    guard nextSequence > 0, sequence == nextSequence, nextSequence != UInt64.max else {
      throw WireFailure.malformed
    }
    nextSequence += 1
  }
  public mutating func accept(_ message: WireMessage) throws {
    guard let type = MessageKind(rawValue: message.type) else { throw WireFailure.malformed }
    let permitted: Bool
    if channel == .video {
      permitted = peer == .host ? [.codecConfig, .videoFrame].contains(type) : type == .videoHello
    } else {
      permitted = (peer == .host ? Self.hostControl : Self.clientControl).contains(type)
    }
    guard permitted, message.sequence == nextSequence, nextSequence != UInt64.max else {
      throw WireFailure.malformed
    }
    let first: MessageKind =
      channel == .video
      ? (peer == .host ? .codecConfig : .videoHello)
      : (peer == .host ? .sessionConfig : .clientHello)
    guard
      nextSequence != 0 || type == first
        || (channel == .control && peer == .host && type == .protocolError)
    else { throw WireFailure.malformed }
    let fields = message.fields
    let messageEpoch: UInt64
    let id: Data?
    if type == .clientHello || type == .videoHello {
      guard case .integer(let e) = fields[0] else { throw WireFailure.malformed }
      messageEpoch = e
      if type == .videoHello {
        guard case .bytes(let b) = fields[1] else { throw WireFailure.malformed }
        id = b
      } else {
        id = nil
      }
    } else {
      guard case .bytes(let b) = fields[0], case .integer(let e) = fields[1] else {
        throw WireFailure.malformed
      }
      id = b
      messageEpoch = e
    }
    guard messageEpoch == epoch, sessionId == nil || id == sessionId else {
      throw WireFailure.malformed
    }
    if channel == .video && peer == .host {
      guard case .integer(let g) = fields[2] else { throw WireFailure.malformed }
      if type == .codecConfig {
        guard g == generation + 1 else { throw WireFailure.malformed }
        generation = g
        nextFrame = 0
        needsIDR = true
      } else {
        guard g == generation, !needsIDR || (fields[5] == .integer(3)),
          case .integer(let frame) = fields[3], frame == nextFrame, frame != UInt64.max
        else { throw WireFailure.malformed }
        nextFrame += 1
        needsIDR = false
      }
    }
    nextSequence += 1
  }
}
