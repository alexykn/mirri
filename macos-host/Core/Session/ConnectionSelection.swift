import Foundation

/// Presentation-facing choice only; the connection route and coordinator still own every resource.
public struct ConnectionTarget: Sendable, Equatable {
  public let device: ADBDevice
  public let address: LocalIPv4Address
}

public enum ConnectionNotice: Sendable, Equatable {
  case connection(String)
  case operation(String)

  public var message: String {
    switch self {
    case .connection(let message), .operation(let message): message
    }
  }
}

/// Single owner of selectable endpoints, discovery readiness and the in-flight Connect claim.
public struct ConnectionSelection: Sendable {
  public private(set) var devices: [ADBDevice] = []
  public private(set) var addresses: [LocalIPv4Address] = []
  public private(set) var selectedDevice: ADBDevice?
  public private(set) var selectedAddress: LocalIPv4Address?
  public private(set) var snapshot = HostSnapshot()
  public private(set) var isStarting = false
  public private(set) var isMaintaining = false
  public private(set) var discoveryFailed = false
  public private(set) var notice: ConnectionNotice?
  public private(set) var hasCheckedDevices = false

  public init() {}

  public var isEditable: Bool {
    !isStarting && !isMaintaining && (snapshot.state == .idle || snapshot.state == .failed)
  }
  public var canStop: Bool {
    isStarting || (snapshot.state != .idle && snapshot.state != .failed)
  }
  public var canRetry: Bool { !isStarting && snapshot.state == .streaming }
  public var canConnect: Bool { target != nil }

  public var headline: String {
    if isMaintaining { return "Working on tablet…" }
    if isStarting && (snapshot.state == .idle || snapshot.state == .failed) {
      return "Connecting…"
    }
    if discoveryFailed && isEditable { return "Unable to find tablets" }
    if let notice {
      switch notice {
      case .connection: return "Connection failed"
      case .operation: return "Needs attention"
      }
    }
    switch snapshot.state {
    case .idle:
      if !hasCheckedDevices { return "Checking for tablet…" }
      if devices.isEmpty { return "Connect your tablet" }
      if selectedDevice == nil { return "Choose a tablet" }
      if addresses.isEmpty { return "Connect Mac to a network" }
      if selectedAddress == nil { return "Choose network address" }
      return "Ready to connect"
    case .streaming: return "Connected"
    case .waitingForReconnect: return "Reconnecting…"
    case .failed: return "Connection failed"
    case .stopping: return "Disconnecting…"
    default: return "Connecting…"
    }
  }

  public var readinessHelp: String? {
    guard isEditable else { return nil }
    if discoveryFailed { return "Can't check USB devices. Check ADB, the cable and USB debugging." }
    if !hasCheckedDevices { return "Connect a USB cable and unlock the tablet." }
    if devices.isEmpty { return "Attach and authorize a USB tablet to begin." }
    if selectedDevice == nil { return "Choose the tablet you want to use." }
    if addresses.isEmpty {
      return "No active Mac IPv4 address. Connect both devices to a LAN or hotspot."
    }
    if selectedAddress == nil { return "Select the IPv4 interface on the same LAN or hotspot." }
    return nil
  }

  public var target: ConnectionTarget? {
    guard isEditable, !discoveryFailed, let selectedDevice,
      devices.contains(selectedDevice),
      let selectedAddress, addresses.contains(selectedAddress)
    else { return nil }
    return ConnectionTarget(device: selectedDevice, address: selectedAddress)
  }

  public mutating func update(_ value: HostSnapshot) { snapshot = value }

  public mutating func discovered(_ result: Result<[ADBDevice], Error>) {
    guard isEditable else { return }
    switch result {
    case .failure:
      discoveryFailed = true
      devices = []
      selectedDevice = nil
    case .success(let found):
      discoveryFailed = false
      devices = found
      if let selectedDevice, !found.contains(selectedDevice) { self.selectedDevice = nil }
      if !hasCheckedDevices && selectedDevice == nil && found.count == 1 {
        selectedDevice = found[0]
      }
      hasCheckedDevices = true
    }
  }

  public mutating func availableAddresses(_ found: [LocalIPv4Address]) {
    guard isEditable else { return }
    addresses = found
    if let selectedAddress, !found.contains(selectedAddress) { self.selectedAddress = nil }
  }

  public mutating func select(_ device: ADBDevice) {
    guard isEditable, devices.contains(device) else { return }
    selectedDevice = device
  }
  public mutating func select(_ address: LocalIPv4Address) {
    guard isEditable, addresses.contains(address) else { return }
    selectedAddress = address
  }

  /// Atomic synchronous claim before starting any asynchronous ADB or coordinator work.
  public mutating func claimConnect() -> ConnectionTarget? {
    guard let target else { return nil }
    isStarting = true
    notice = nil
    return target
  }
  public mutating func finishConnect(issue: String? = nil) {
    isStarting = false
    notice = issue.map(ConnectionNotice.connection)
  }

  /// Claim explicit maintenance separately from Connect; success clears stale notices.
  public mutating func claimOperation(on device: ADBDevice) -> Bool {
    guard isEditable, selectedDevice == device, devices.contains(device) else { return false }
    isMaintaining = true
    notice = nil
    return true
  }
  public mutating func finishOperation(issue: String? = nil) {
    isMaintaining = false
    notice = issue.map(ConnectionNotice.operation)
  }
}
