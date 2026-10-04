import Foundation

/// USB is setup tooling only (discovery, install, first launch); media never travels over ADB.
public actor USBDeviceService {
  private let adb: ADBClient
  private let pairing: PairingStore?
  private var activeRoute: (any HostConnectionRoute)?
  private var maintenance = false
  /// With a pairing store, every cable launch also pairs the tablet for cable-free use.
  public init(adb: ADBClient = ADBClient(), pairing: PairingStore? = nil) {
    self.adb = adb
    self.pairing = pairing
  }
  public func discover() async throws -> [ADBDevice] { try await adb.listDevices() }
  public func installed(on device: ADBDevice) async throws -> InstalledClient? {
    try await adb.packageVersion(on: device)
  }
  public func install(apk: URL, on device: ADBDevice) async throws {
    guard activeRoute == nil, !maintenance else { throw HostFailure.invalidState }
    maintenance = true
    defer { maintenance = false }
    try await adb.installClient(apk: apk, on: device)
  }
  public func networkRoute(on device: ADBDevice, address: LocalIPv4Address) throws
    -> NetworkConnectionRoute
  {
    guard activeRoute == nil, !maintenance else { throw HostFailure.invalidState }
    let route = NetworkConnectionRoute(
      launcher: ADBLauncher(device: device, address: address, adb: adb, pairing: pairing),
      address: address, service: self)
    activeRoute = route
    return route
  }
  /// WebRTC video over UDP with the same pinned TLS control connection.
  public func rtcRoute(on device: ADBDevice, address: LocalIPv4Address) throws
    -> NetworkConnectionRoute
  {
    guard activeRoute == nil, !maintenance else { throw HostFailure.invalidState }
    let route = NetworkConnectionRoute(
      launcher: ADBLauncher(device: device, address: address, adb: adb, pairing: pairing),
      address: address, service: self, rtcSelected: true)
    activeRoute = route
    return route
  }
  /// A paired tablet that reached the host over the LAN; no cable or ADB involved.
  public func pairedRoute(
    presence: RendezvousPresence, address: LocalIPv4Address, rtc: Bool
  ) throws -> NetworkConnectionRoute {
    guard activeRoute == nil, !maintenance else { throw HostFailure.invalidState }
    let route = NetworkConnectionRoute(
      launcher: RendezvousLauncher(presence: presence, address: address),
      address: address, service: self, rtcSelected: rtc)
    activeRoute = route
    return route
  }
  func released(_ route: any HostConnectionRoute) {
    if activeRoute === route { activeRoute = nil }
  }
}
