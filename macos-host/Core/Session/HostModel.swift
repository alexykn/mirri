import Foundation

public enum HostFailure: Error, LocalizedError, Sendable, Equatable {
  case permission, adb, unauthorized, incompatible, exactDisplay, hardwareCodec, transport
  case invalidState, timeout, malformed, reverseConflict
  public var errorDescription: String? {
    switch self {
    case .permission: "Grant Screen Recording and Accessibility, then restart Mirri if prompted"
    case .adb: "ADB is unavailable or the USB tablet is not authorized"
    case .unauthorized: "Client session authentication failed"
    case .incompatible: "Client rejected the fixed resolution, refresh or hardware codec"
    case .exactDisplay: "Cannot publish the exact 2456x1600 at 60 Hz virtual display"
    case .hardwareCodec: "No hardware encoder accepts the exact format"
    case .transport: "Connection interrupted. Check the tablet and selected connection"
    case .invalidState: "Invalid session transition"
    case .timeout: "Session handshake timed out"
    case .malformed: "Invalid protocol message"
    case .reverseConflict:
      "ADB reverse tcp:5560/5561 already exists; inspect and explicitly clean up these ports on the selected USB tablet"
    }
  }
}

public enum HostState: String, Sendable {
  case idle, checkingPermissions, preparingTransport, waitingForClient, negotiating
  case creatingDisplay, preparingClient, streaming, waitingForReconnect, stopping, failed
}

public struct HostSnapshot: Sendable {
  public var state: HostState = .idle
  public var message = "Attach an authorized USB tablet"
  public var device = "None"
  public var virtualMode = "Not active (requested 2456x1600 @ 60 Hz)"
  public var clientMode = "Not reported (required 1600x2456 @ 60 Hz)"
  public var video = "Hardware AVC 40 Mbit/s requested"
  public var metrics = "Capture / encode / transport / client: —"
  public init() {}
}

public struct HostPreferences: Sendable {
  public enum Codec: String, Sendable { case automatic, avc, hevc }
  /// Native points or an exact 2x HiDPI logical mode; both retain 2456x1600 pixels.
  public enum LogicalSize: String, Sendable {
    case native, retina
    public var width: Int { self == .native ? 2456 : 1228 }
    public var height: Int { self == .native ? 1600 : 800 }
    public var hiDPI: Bool { self == .retina }
  }
  public enum Zoom: String, Sendable { case commandKeys, disabled }
  public enum AuxiliaryAction: String, Sendable { case missionControl, contextClick, disabled }
  public let codec: Codec
  public let logicalSize: LogicalSize
  public let zoom: Zoom
  public let auxiliaryAction: AuxiliaryAction
  public let avcBitrate: UInt32
  public let hevcBitrate: UInt32
  public let graceSeconds: Int
  public init(
    codec: Codec = .automatic, logicalSize: LogicalSize = .native,
    zoom: Zoom = .commandKeys,
    auxiliaryAction: AuxiliaryAction = .disabled,
    avcBitrate: UInt32 = 40_000_000,
    hevcBitrate: UInt32 = 25_000_000, graceSeconds: Int = 15
  ) {
    self.codec = codec
    self.logicalSize = logicalSize
    self.zoom = zoom
    self.auxiliaryAction = auxiliaryAction
    self.avcBitrate = min(80_000_000, max(20_000_000, avcBitrate))
    self.hevcBitrate = min(80_000_000, max(25_000_000, hevcBitrate))
    self.graceSeconds = min(60, max(1, graceSeconds))
  }
}
