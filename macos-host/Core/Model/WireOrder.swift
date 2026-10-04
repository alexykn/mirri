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
    .rtcCapabilities, .rtcPrepared, .rtcAnswer, .rtcIceCandidate,
    .rtcIceEnd, .rtcMediaReady,
  ]
  private static let hostControl: Set<MessageKind> = [
    .sessionConfig, .startStream, .stopSession, .ping, .protocolError,
    .rtcPrepare, .rtcOffer, .rtcIceCandidate, .rtcIceEnd, .rtcStart,
  ]
  /// Only call for an ignorable future-minor type already validated by WireFramer.
  public mutating func skipUnknown(sequence: UInt64) throws {
    guard nextSequence > 0, sequence == nextSequence, nextSequence != UInt64.max else {
      throw WireFailure.malformed
    }
    nextSequence += 1
  }
  /// Authenticated RTC retries discard old-epoch RTC records only after their
  /// framing and sequence have been accounted for; never apply their SDP/ICE.
  public mutating func skipStaleRtc(_ message: WireMessage) throws {
    guard channel == .control, peer == .client, nextSequence > 0,
      [.rtcCapabilities, .rtcPrepared, .rtcAnswer, .rtcIceCandidate,
        .rtcIceEnd, .rtcMediaReady].contains(MessageKind(rawValue: message.type)),
      message.sequence == nextSequence,
      nextSequence != UInt64.max, message.fields.count >= 2,
      case .bytes(let id) = message.fields[0], id == sessionId,
      case .integer(let received) = message.fields[1], received < epoch
    else { throw WireFailure.malformed }
    nextSequence += 1
  }
  private func envelope(_ type: MessageKind, fields: [WireValue]) throws -> (UInt64, Data?) {
    if type == .clientHello || type == .videoHello {
      guard case .integer(let epoch) = fields[0] else { throw WireFailure.malformed }
      if type == .videoHello {
        guard case .bytes(let id) = fields[1] else { throw WireFailure.malformed }
        return (epoch, id)
      }
      return (epoch, nil)
    }
    guard case .bytes(let id) = fields[0], case .integer(let epoch) = fields[1] else {
      throw WireFailure.malformed
    }
    return (epoch, id)
  }
  private mutating func acceptVideo(_ type: MessageKind, fields: [WireValue]) throws {
    guard case .integer(let incomingGeneration) = fields[2] else { throw WireFailure.malformed }
    if type == .codecConfig {
      guard incomingGeneration == generation + 1 else { throw WireFailure.malformed }
      generation = incomingGeneration
      nextFrame = 0
      needsIDR = true
    } else {
      guard incomingGeneration == generation, !needsIDR || (fields[5] == .integer(3)),
        case .integer(let frame) = fields[3], frame == nextFrame, frame != UInt64.max
      else { throw WireFailure.malformed }
      nextFrame += 1
      needsIDR = false
    }
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
    let (messageEpoch, id) = try envelope(type, fields: message.fields)
    guard messageEpoch == epoch, sessionId == nil || id == sessionId else {
      throw WireFailure.malformed
    }
    if channel == .video && peer == .host {
      try acceptVideo(type, fields: message.fields)
    }
    nextSequence += 1
  }
}
