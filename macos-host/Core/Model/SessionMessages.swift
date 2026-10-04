import Foundation

/// The framing codec is the only owner of positional wire fields. Session and
/// input owners receive values whose shape was validated at this boundary.
public enum MessageKind: UInt16, Sendable {
  case clientHello = 1
  case sessionConfig, clientReady, videoHello, codecConfig, videoFrame
  case startStream, stopSession, inputBatch, scroll, zoom, contextClick, shortcut
  case auxiliaryKey, ping, pong, clientMetrics, protocolError, decoderFailure
  case requestKeyframe, sessionRejected, stopAcknowledged
  case rtcCapabilities, rtcPrepare, rtcPrepared, rtcOffer, rtcAnswer
  case rtcIceCandidate, rtcIceEnd, rtcMediaReady, rtcStart
}

public struct PhysicalMode: Sendable, Equatable {
  public let width: UInt64
  public let height: UInt64
  public let milliHz: UInt64
  public let identifier: Int32
  public var isExact: Bool {
    width == 1600 && height == 2456 && (milliHz == 60000 || milliHz == 120000)
  }
}

public struct CodecOffer: Sendable {
  public let codec: VideoCodec
  public let profiles: [(UInt64, UInt64)]
  public let exact: Bool
  public let lowLatency: Bool
  public let hardware: Bool
  public func supports(level: UInt64) -> Bool {
    exact && hardware && profiles.contains { $0.0 == codec.rawValue && $0.1 == level }
  }
}

public struct ClientGreeting: Sendable {
  public let token: Data
  public let epoch: UInt32
  public let nativeSize: (UInt64, UInt64)
  public let active: PhysicalMode
  public let modes: [PhysicalMode]
  public let codecs: [CodecOffer]
}

public struct ClientReadiness: Sendable {
  public let mode: PhysicalMode
  public let surface: (UInt64, UInt64)
  public var isExact: Bool { mode.isExact && surface == (2456, 1600) }
}

public struct ClientPerformance: Sendable {
  public let receiveFps: Float
  public let bitsPerSecond: UInt64
  public let decodeInputFps: Float
  public let decodeOutputFps: Float
  public let mode: PhysicalMode
  public let queueDepth: UInt64
  public let dropped: UInt64
}

public struct InputPoint: Sendable {
  public let x: Float
  public let y: Float
}
public enum PointerTool: UInt64, Sendable {
  case finger = 1
  case pen, eraser
}
public enum PointerPhase: UInt64, Sendable {
  case hoverEnter = 1
  case hoverMove, hoverExit, down, move, up, cancel
}
public enum GesturePhase: UInt64, Sendable {
  case began = 1
  case changed, ended, cancelled
}
public enum ShortcutAction: UInt64, Sendable {
  case missionControl = 1
  case previousSpace, nextSpace, showDesktop, custom
}
public struct PointerReading: Sendable {
  public let id: UInt64
  public let tool: PointerTool
  public let phase: PointerPhase
  public let point: InputPoint
  public let pressure: Float
  public let tilt: Float
  public let orientation: Float
  public let buttons: UInt64
  public let time: UInt64
}
public enum RemoteInput: Sendable {
  case pointers(sequence: UInt64, samples: [PointerReading])
  case scroll(phase: GesturePhase, point: InputPoint, x: Float, y: Float)
  case zoom(phase: GesturePhase, point: InputPoint, scale: Float)
  case context(point: InputPoint)
  case shortcut(action: ShortcutAction)
  case auxiliary(code: UInt64, scan: UInt64, phase: UInt64)
}

public enum ClientEvent: Sendable {
  case hello(ClientGreeting)
  case videoHello(token: Data, sessionId: Data, epoch: UInt32)
  case ready(ClientReadiness)
  case input(RemoteInput)
  case metrics(ClientPerformance)
  case pong(sequence: UInt64, sent: UInt64, received: UInt64, replied: UInt64)
  case decoderFailure
  case requestKeyframe
  case rejection
  case stopAcknowledged

  public static func decode(_ message: WireMessage) throws -> ClientEvent {
    guard let kind = MessageKind(rawValue: message.type) else { throw HostFailure.malformed }
    let f = message.fields
    switch kind {
    case .clientHello:
      let offers = try SessionFields.list(f[7]).map { value -> CodecOffer in
        let fields = try SessionFields.object(value)
        guard let codec = VideoCodec(rawValue: try SessionFields.number(fields[0])) else {
          throw HostFailure.malformed
        }
        let profiles = try SessionFields.list(fields[1]).map {
          let pair = try SessionFields.object($0)
          return (try SessionFields.number(pair[0]), try SessionFields.number(pair[1]))
        }
        return CodecOffer(
          codec: codec, profiles: profiles, exact: try SessionFields.number(fields[2]) == 1,
          lowLatency: try SessionFields.number(fields[3]) == 1,
          hardware: try SessionFields.number(fields[4]) == 1)
      }
      return .hello(
        ClientGreeting(
          token: try SessionFields.bytes(f[1]), epoch: UInt32(try SessionFields.number(f[0])),
          nativeSize: try SessionFields.size(f[3]), active: try SessionFields.mode(f[5]),
          modes: try SessionFields.list(f[6]).map(SessionFields.mode), codecs: offers))
    case .videoHello:
      return .videoHello(
        token: try SessionFields.bytes(f[2]), sessionId: try SessionFields.bytes(f[1]),
        epoch: UInt32(try SessionFields.number(f[0])))
    case .clientReady:
      return .ready(
        ClientReadiness(
          mode: try SessionFields.mode(f[2]), surface: try SessionFields.size(f[4])))
    case .inputBatch:
      let readings = try SessionFields.list(f[3]).map { value -> PointerReading in
        let fields = try SessionFields.object(value)
        guard let tool = PointerTool(rawValue: try SessionFields.number(fields[1])),
          let phase = PointerPhase(rawValue: try SessionFields.number(fields[2]))
        else { throw HostFailure.malformed }
        return PointerReading(
          id: try SessionFields.number(fields[0]), tool: tool,
          phase: phase, point: try SessionFields.point(fields[3]),
          pressure: try SessionFields.real(fields[4]), tilt: try SessionFields.real(fields[5]),
          orientation: try SessionFields.real(fields[6]),
          buttons: try SessionFields.number(fields[7]), time: try SessionFields.number(fields[8]))
      }
      return .input(.pointers(sequence: try SessionFields.number(f[2]), samples: readings))
    case .scroll:
      guard let phase = GesturePhase(rawValue: try SessionFields.number(f[2])) else {
        throw HostFailure.malformed
      }
      return .input(
        .scroll(
          phase: phase, point: try SessionFields.point(f[3]),
          x: try SessionFields.real(f[4]), y: try SessionFields.real(f[5])))
    case .zoom:
      guard let phase = GesturePhase(rawValue: try SessionFields.number(f[2])) else {
        throw HostFailure.malformed
      }
      return .input(
        .zoom(
          phase: phase, point: try SessionFields.point(f[3]),
          scale: try SessionFields.real(f[4])))
    case .contextClick: return .input(.context(point: try SessionFields.point(f[2])))
    case .shortcut:
      guard let action = ShortcutAction(rawValue: try SessionFields.number(f[2])) else {
        throw HostFailure.malformed
      }
      return .input(.shortcut(action: action))
    case .auxiliaryKey:
      return .input(
        .auxiliary(
          code: try SessionFields.number(f[2]), scan: try SessionFields.number(f[3]),
          phase: try SessionFields.number(f[4])))
    case .clientMetrics:
      return .metrics(
        ClientPerformance(
          receiveFps: try SessionFields.real(f[2]), bitsPerSecond: try SessionFields.number(f[3]),
          decodeInputFps: try SessionFields.real(f[4]),
          decodeOutputFps: try SessionFields.real(f[5]), mode: try SessionFields.mode(f[6]),
          queueDepth: try SessionFields.number(f[7]), dropped: try SessionFields.number(f[8])))
    case .pong:
      return .pong(
        sequence: try SessionFields.number(f[2]), sent: try SessionFields.number(f[3]),
        received: try SessionFields.number(f[4]), replied: try SessionFields.number(f[5]))
    case .decoderFailure: return .decoderFailure
    case .requestKeyframe: return .requestKeyframe
    case .sessionRejected, .protocolError: return .rejection
    case .stopAcknowledged: return .stopAcknowledged
    default: throw HostFailure.malformed
    }
  }
}

/// All host serialization occurs here, after domain owners have chosen an
/// action. The wire encoder still checks length, exact format and bounds.
public enum HostCommand: Sendable {
  case configuration(NegotiatedConfig)
  case start(generation: UInt32)
  case stop
  case ping(sequence: UInt64, sent: UInt64)
  case error(code: UInt64, description: String)
  case codecConfiguration(generation: UInt32, config: NegotiatedConfig, sets: [Data])
  case frame(generation: UInt32, sequence: UInt64, pts: UInt64, flags: UInt64, data: Data)

  public func wire(sessionId: Data, epoch: UInt32) -> WireMessage {
    let kind: MessageKind
    let payload: [WireValue]
    switch self {
    case .configuration(let config):
      kind = .sessionConfig
      payload = [
        .integer(config.codec.rawValue), .integer(config.profile), .integer(config.level),
        .object([.integer(2456), .integer(1600)]), .integer(60000),
        .integer(UInt64(config.bitrate)), .integer(1), .integer(5560), .integer(1), .integer(1),
      ]
    case .start(let generation):
      kind = .startStream
      payload = [.integer(UInt64(generation))]
    case .stop:
      kind = .stopSession
      payload = [.integer(1)]
    case .ping(let sequence, let sent):
      kind = .ping
      payload = [.integer(sequence), .integer(sent), .integer(0), .integer(0)]
    case .error(let code, let description):
      kind = .protocolError
      payload = [.integer(code), .text(description), .integer(1)]
    case .codecConfiguration(let generation, let config, let sets):
      kind = .codecConfig
      payload = [
        .integer(UInt64(generation)), .integer(config.codec.rawValue), .integer(config.profile),
        .integer(config.level), .integer(1), .items(sets.map(WireValue.bytes)),
      ]
    case .frame(let generation, let sequence, let pts, let flags, let data):
      kind = .videoFrame
      payload = [
        .integer(UInt64(generation)), .integer(sequence), .integer(pts),
        .integer(flags), .bytes(data),
      ]
    }
    return WireMessage(
      type: kind.rawValue, sequence: 0, timestamp: DispatchTime.now().uptimeNanoseconds,
      fields: [.bytes(sessionId), .integer(UInt64(epoch))] + payload)
  }
}

private enum SessionFields {
  static func number(_ value: WireValue) throws -> UInt64 {
    guard case .integer(let n) = value else { throw HostFailure.malformed }
    return n
  }
  static func real(_ value: WireValue) throws -> Float {
    guard case .real(let n) = value else { throw HostFailure.malformed }
    return n
  }
  static func bytes(_ value: WireValue) throws -> Data {
    guard case .bytes(let data) = value else { throw HostFailure.malformed }
    return data
  }
  static func object(_ value: WireValue) throws -> [WireValue] {
    guard case .object(let fields) = value else { throw HostFailure.malformed }
    return fields
  }
  static func list(_ value: WireValue) throws -> [WireValue] {
    guard case .items(let items) = value else { throw HostFailure.malformed }
    return items
  }
  static func size(_ value: WireValue) throws -> (UInt64, UInt64) {
    let fields = try object(value)
    return (try number(fields[0]), try number(fields[1]))
  }
  static func mode(_ value: WireValue) throws -> PhysicalMode {
    let fields = try object(value)
    guard case .signed(let id) = fields[2] else { throw HostFailure.malformed }
    let (width, height) = try size(fields[0])
    return PhysicalMode(
      width: width, height: height, milliHz: try number(fields[1]), identifier: id)
  }
  static func point(_ value: WireValue) throws -> InputPoint {
    let fields = try object(value)
    return InputPoint(x: try real(fields[0]), y: try real(fields[1]))
  }
}
