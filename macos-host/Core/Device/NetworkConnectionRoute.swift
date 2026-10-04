import Foundation

/// How the tablet learns one session's credentials: over the cable, or over
/// the authenticated rendezvous connection of an already paired tablet.
protocol ClientLauncher: Sendable {
  var displayLabel: String { get }
  var waitingDescription: String { get }
  var streamingDescription: String { get }
  /// Returns the text shown as the connected device; throws if the tablet is not usable.
  func preflight() async throws -> String
  func launch(token: Data, epoch: UInt32, network: NetworkLaunch) async throws
}

struct ADBLauncher: ClientLauncher {
  let device: ADBDevice
  let address: LocalIPv4Address
  let adb: ADBClient
  let pairing: PairingStore?
  var displayLabel: String { "\(device.model) · Network \(address.address) (USB setup)" }
  var waitingDescription: String { "Waiting for pinned TLS control (USB setup on first launch)" }
  var streamingDescription: String { "Streaming over Network (USB setup)" }
  func preflight() async throws -> String {
    guard try await adb.listDevices().contains(device) else { throw HostFailure.adb }
    guard let installed = try await adb.packageVersion(on: device), installed.versionCode >= 3
    else { throw HostFailure.incompatible }
    return "\(displayLabel) · client \(installed.versionName) (v\(installed.versionCode))"
  }
  func launch(token: Data, epoch: UInt32, network: NetworkLaunch) async throws {
    // Every cable launch pairs the tablet, so the next one needs no cable.
    let grant = try? await pairing?.issue(label: device.model)
    try await adb.launchClient(
      device: device, token: token, epoch: epoch,
      network: NetworkLaunch(
        address: network.address, pin: network.pin, media: network.media,
        sessionId: network.sessionId, pairing: grant))
  }
}

struct RendezvousLauncher: ClientLauncher {
  let presence: RendezvousPresence
  let address: LocalIPv4Address
  var displayLabel: String { "\(presence.tablet.label) · Network \(address.address) (paired)" }
  var waitingDescription: String { "Waiting for the paired tablet on pinned TLS control" }
  var streamingDescription: String { "Streaming over Network (paired, no cable)" }
  func preflight() async throws -> String {
    guard presence.isAlive else { throw HostFailure.transport }
    return displayLabel
  }
  func launch(token: Data, epoch: UInt32, network: NetworkLaunch) async throws {
    guard let sessionId = network.sessionId else { throw HostFailure.invalidState }
    try await presence.sendLaunch(
      RendezvousLaunch(
        token: token, epoch: epoch, address: address.octets, pin: network.pin,
        rtc: network.media == .rtc, sessionId: sessionId))
  }
}

/// Launcher-assisted first launch, then TLS-only retries; never creates ADB reverse mappings.
public actor NetworkConnectionRoute: HostConnectionRoute {
  public nonisolated let displayLabel: String
  public nonisolated let transportDescription: String
  public nonisolated let streamingDescription: String
  public nonisolated let waitingDescription: String
  public nonisolated let requiresEpochBootstrap = true
  public nonisolated let rtcSelected: Bool
  private let launcher: any ClientLauncher
  private let address: LocalIPv4Address
  private weak var service: USBDeviceService?
  private var identity: NetworkIdentity?
  private var control: BoundedByteListener?
  private var video: BoundedByteListener?
  private var launched = false
  private var closed = false
  private var inFlight: Task<Void, Never>?
  private var closing: Task<Void, Never>?

  init(
    launcher: any ClientLauncher, address: LocalIPv4Address, service: USBDeviceService,
    rtcSelected: Bool = false
  ) {
    self.launcher = launcher
    self.address = address
    self.service = service
    self.rtcSelected = rtcSelected
    displayLabel = launcher.displayLabel
    transportDescription = "Binding selected \(address.interface) · \(address.address) with TLS"
    streamingDescription = launcher.streamingDescription
    waitingDescription = launcher.waitingDescription
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
    if !rtcSelected {
      // One write per access unit: Nagle would hold each frame's final partial
      // segment until the tablet ACKs the rest.
      video = try BoundedByteListener(
        port: 5560, noDelay: true, address: address.address, identity: identity.identity)
    }
  }
  private func awaitBoundPorts() async throws {
    guard let control else { throw HostFailure.transport }
    _ = try await control.boundPort()
    try checkOpen()
    if let video { _ = try await video.boundPort() }
    try checkOpen()
    try address.validateCurrent()
  }
  /// A just-cancelled listener can still hold its port for a moment; rebinding
  /// at once then fails and would turn a reconnect into a transport error.
  private func bindListeners() async throws {
    for attempt in 0..<10 {
      do {
        try bind()
        try await awaitBoundPorts()
        return
      } catch HostFailure.transport where attempt < 9 {
        interrupt()
        try await Task.sleep(for: .milliseconds(100))
        try checkOpen()
      }
    }
  }
  public func prepare() async throws -> String {
    try checkOpen()
    try address.validateCurrent()
    let launcher = self.launcher
    let label = try await tracked { try await launcher.preflight() }
    try checkOpen()
    identity = try NetworkIdentity.create(for: address)
    try await bindListeners()
    return label
  }
  public func retry() async throws {
    try checkOpen()
    interrupt()
    try await bindListeners()
  }
  public func bootstrap(_ credentials: AttemptCredentials) async throws {
    try checkOpen()
    guard credentials.token.count == 32, credentials.sessionId.count == 16,
      credentials.epoch > 0, let identity, Date() < identity.expiresAt
    else { throw HostFailure.unauthorized }
    guard !launched else { return }  // All later epochs are learned over authenticated TLS.
    let launcher = self.launcher
    let launch = NetworkLaunch(address: address.address, pin: identity.pin,
      media: rtcSelected ? .rtc : .comparison, sessionId: credentials.sessionId)
    try await tracked {
      try await launcher.launch(
        token: credentials.token, epoch: credentials.epoch, network: launch)
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
