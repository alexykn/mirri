import Foundation

/// Application-level USB operations. Install and explicit reverse cleanup require an idle route.
public actor USBDeviceService {
  private let adb: ADBClient
  private let reverses: AdbReverseManager
  private var activeRoute: USBConnectionRoute?
  private var maintenance = false
  public init(adb: ADBClient = ADBClient()) {
    self.adb = adb
    reverses = AdbReverseManager(adb: adb)
  }
  public func discover() async throws -> [ADBDevice] {
    let devices = try await adb.listDevices()
    if activeRoute == nil && !maintenance {
      maintenance = true
      defer { maintenance = false }
      for device in devices { await reverses.retryOwnedCleanup(on: device) }
    }
    return devices
  }
  public func installed(on device: ADBDevice) async throws -> InstalledClient? {
    try await adb.packageVersion(on: device)
  }
  public func install(apk: URL, on device: ADBDevice) async throws {
    guard activeRoute == nil, !maintenance else { throw HostFailure.invalidState }
    maintenance = true
    defer { maintenance = false }
    try await adb.installClient(apk: apk, on: device)
  }
  public func explicitReverseCleanup(on device: ADBDevice) async throws {
    guard activeRoute == nil, !maintenance else { throw HostFailure.invalidState }
    maintenance = true
    defer { maintenance = false }
    guard try await adb.listDevices().contains(device)
    else { throw HostFailure.invalidState }
    try await reverses.explicitCleanup(on: device)
  }
  public func route(on device: ADBDevice) throws -> USBConnectionRoute {
    guard activeRoute == nil, !maintenance else { throw HostFailure.invalidState }
    let route = USBConnectionRoute(device: device, adb: adb, reverses: reverses, service: self)
    activeRoute = route
    return route
  }
  func released(_ route: USBConnectionRoute) {
    if activeRoute === route { activeRoute = nil }
  }
}

/// USB bootstrap and listener ownership; no handshake, display or streaming decisions.
public actor USBConnectionRoute: HostConnectionRoute {
  public nonisolated let displayLabel: String
  private let device: ADBDevice
  private let adb: ADBClient
  private let reverses: AdbReverseManager
  private weak var service: USBDeviceService?
  private var control: LoopbackByteListener?
  private var video: LoopbackByteListener?
  private var closed = false
  private var closing: Task<Void, Never>?
  private var pendingADB: Task<Void, Never>?
  var closureStarted: Bool { closed }
  init(device: ADBDevice, adb: ADBClient, reverses: AdbReverseManager, service: USBDeviceService) {
    self.device = device
    self.adb = adb
    self.reverses = reverses
    self.service = service
    displayLabel = device.model  // never expose the ADB serial in UI/logs
  }
  private func checkOpen() throws {
    guard !closed else { throw HostFailure.invalidState }
  }
  // Join every command (including discovery and launch), not just reverse-map
  // creation, before releasing the route to a new session.
  private func tracked<T: Sendable>(
    _ operation: @escaping @Sendable () async throws -> T
  ) async throws -> T {
    try checkOpen()
    guard pendingADB == nil else { throw HostFailure.invalidState }
    let command = Task { try await operation() }
    pendingADB = Task { _ = await command.result }
    defer { pendingADB = nil }
    let result = try await command.value
    try checkOpen()
    return result
  }
  private func bindListeners() throws {
    try checkOpen()
    // Join both listeners before any asynchronous reverse-map or launch call.
    let control = try LoopbackByteListener(port: 5561, noDelay: true)
    self.control = control
    video = try LoopbackByteListener(port: 5560)
  }
  public func prepare() async throws -> String {
    try checkOpen()
    let adb = self.adb
    let device = self.device
    let reverses = self.reverses
    guard try await tracked({ try await adb.listDevices() }).contains(device)
    else { throw HostFailure.adb }
    guard let installed = try await tracked({ try await adb.packageVersion(on: device) }),
      installed.versionCode >= 2
    else { throw HostFailure.incompatible }
    try bindListeners()
    try await tracked { try await reverses.install(on: device) }
    return "\(displayLabel) · client \(installed.versionName) (v\(installed.versionCode))"
  }
  public func retry() async throws {
    try checkOpen()
    interrupt()
    try bindListeners()
    // The reverse owner only reclaims mappings proved absent in this live process.
    let reverses = self.reverses
    let device = self.device
    try await tracked { try await reverses.install(on: device) }
  }
  public func bootstrap(_ credentials: AttemptCredentials) async throws {
    try checkOpen()
    guard credentials.token.count == 32, credentials.sessionId.count == 16,
      credentials.epoch > 0
    else { throw HostFailure.invalidState }
    let adb = self.adb
    let device = self.device
    try await tracked {
      try await adb.launchClient(device: device, token: credentials.token, epoch: credentials.epoch)
    }
  }
  public func acceptControl() async throws -> any ByteConnection {
    try checkOpen()
    guard let control else { throw HostFailure.transport }
    let byteConnection = try await control.accept()
    if closed {
      await byteConnection.close()
      throw HostFailure.invalidState
    }
    return byteConnection
  }
  public func acceptVideo() async throws -> any ByteConnection {
    try checkOpen()
    guard let video else { throw HostFailure.transport }
    let byteConnection = try await video.accept()
    if closed {
      await byteConnection.close()
      throw HostFailure.invalidState
    }
    return byteConnection
  }
  public func interrupt() {
    control?.close()
    control = nil
    video?.close()
    video = nil
  }
  public func close() async {
    if let closing {
      await closing.value
      return
    }
    closed = true
    interrupt()
    // A pending launch or discovery must finish before the service can offer a
    // new route. An in-flight install must finish before reverse cleanup.
    let owner = service
    let inFlight = pendingADB
    let closing = Task { [reverses, device] in
      await inFlight?.value
      await reverses.remove(on: device)
      await owner?.released(self)
    }
    self.closing = closing
    await closing.value
  }
}
