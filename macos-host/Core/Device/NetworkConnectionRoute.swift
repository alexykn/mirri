import Foundation

/// USB-assisted first launch, then TLS-only retries; never creates ADB reverse mappings.
public actor NetworkConnectionRoute: HostConnectionRoute {
  public nonisolated let displayLabel: String
  public nonisolated let transportDescription: String
  public nonisolated let streamingDescription: String
  public nonisolated let waitingDescription =
    "Waiting for pinned TLS control (USB setup on first launch)"
  public nonisolated let requiresEpochBootstrap = true
  private let device: ADBDevice
  private let address: LocalIPv4Address
  private let adb: ADBClient
  private weak var service: USBDeviceService?
  private var identity: NetworkIdentity?
  private var control: BoundedByteListener?
  private var video: BoundedByteListener?
  private var launched = false
  private var closed = false
  private var inFlight: Task<Void, Never>?
  private var closing: Task<Void, Never>?

  init(device: ADBDevice, address: LocalIPv4Address, adb: ADBClient, service: USBDeviceService) {
    self.device = device
    self.address = address
    self.adb = adb
    self.service = service
    displayLabel = "\(device.model) · Network \(address.address) (USB setup)"
    transportDescription = "Binding selected \(address.interface) · \(address.address) with TLS"
    streamingDescription = "Streaming over Network (USB setup)"
  }
  private func checkOpen() throws {
    guard !closed else { throw HostFailure.invalidState }
  }
  private func tracked<T: Sendable>(
    _ operation: @escaping @Sendable () async throws -> T
  ) async throws -> T {
    try checkOpen()
    guard inFlight == nil else { throw HostFailure.invalidState }
    let command = Task { try await operation() }
    inFlight = Task { _ = await command.result }
    defer { inFlight = nil }
    let result = try await command.value
    try checkOpen()
    return result
  }
  private func bind() throws {
    try checkOpen()
    guard let identity, Date() < identity.expiresAt else { throw HostFailure.unauthorized }
    try address.validateCurrent()
    let control = try BoundedByteListener(
      port: 5561, noDelay: true, address: address.address, identity: identity.identity)
    self.control = control
    video = try BoundedByteListener(
      port: 5560, address: address.address, identity: identity.identity)
  }
  private func awaitBoundPorts() async throws {
    guard let control, let video else { throw HostFailure.transport }
    _ = try await control.boundPort()
    try checkOpen()
    _ = try await video.boundPort()
    try checkOpen()
    try address.validateCurrent()
  }
  public func prepare() async throws -> String {
    try checkOpen()
    try address.validateCurrent()
    let adb = self.adb
    let device = self.device
    guard try await tracked({ try await adb.listDevices() }).contains(device)
    else { throw HostFailure.adb }
    guard let installed = try await tracked({ try await adb.packageVersion(on: device) }),
      installed.versionCode >= 3
    else { throw HostFailure.incompatible }
    try checkOpen()
    identity = try NetworkIdentity.create(for: address)
    try bind()
    try await awaitBoundPorts()
    return "\(displayLabel) · client \(installed.versionName) (v\(installed.versionCode))"
  }
  public func retry() async throws {
    try checkOpen()
    interrupt()
    try bind()
    try await awaitBoundPorts()
  }
  public func bootstrap(_ credentials: AttemptCredentials) async throws {
    try checkOpen()
    guard credentials.token.count == 32, credentials.sessionId.count == 16,
      credentials.epoch > 0, let identity, Date() < identity.expiresAt
    else { throw HostFailure.unauthorized }
    guard !launched else { return }  // All later epochs are learned over authenticated TLS.
    let adb = self.adb
    let device = self.device
    let launch = NetworkLaunch(address: address.address, pin: identity.pin)
    try await tracked {
      try await adb.launchClient(
        device: device, token: credentials.token,
        epoch: credentials.epoch, network: launch)
    }
    launched = true
  }
  public func acceptControl() async throws -> any ByteConnection {
    try checkOpen()
    guard let control else { throw HostFailure.transport }
    let bytes = try await control.accept()
    if closed {
      await bytes.close()
      throw HostFailure.invalidState
    }
    return bytes
  }
  public func acceptVideo() async throws -> any ByteConnection {
    try checkOpen()
    guard let video else { throw HostFailure.transport }
    let bytes = try await video.accept()
    if closed {
      await bytes.close()
      throw HostFailure.invalidState
    }
    return bytes
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
    identity = nil
    let command = inFlight
    let owner = service
    let closing = Task {
      await command?.value
      await owner?.released(self)
    }
    self.closing = closing
    await closing.value
  }
}
