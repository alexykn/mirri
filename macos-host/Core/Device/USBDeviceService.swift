import Foundation

/// USB is setup tooling only (discovery, install, first launch); media never travels over ADB.
public actor USBDeviceService {
  private let adb: ADBClient
  private var activeRoute: (any HostConnectionRoute)?
  private var maintenance = false
  public init(adb: ADBClient = ADBClient()) {
    self.adb = adb
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
    let route = NetworkConnectionRoute(device: device, address: address, adb: adb, service: self)
    activeRoute = route
    return route
  }
  /// WebRTC video over UDP with the same pinned TLS control connection.
  public func rtcRoute(on device: ADBDevice, address: LocalIPv4Address) throws
    -> NetworkConnectionRoute
  {
    guard activeRoute == nil, !maintenance else { throw HostFailure.invalidState }
    let route = NetworkConnectionRoute(device: device, address: address, adb: adb,
      service: self, rtcSelected: true)
    activeRoute = route
    return route
  }
  func released(_ route: any HostConnectionRoute) {
    if activeRoute === route { activeRoute = nil }
  }
}
