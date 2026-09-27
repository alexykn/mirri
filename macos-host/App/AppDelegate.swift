import AppKit
import MirriHostCore
import UniformTypeIdentifiers

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
  private let menu = StatusMenuController()
  private let permissions = PermissionsController()
  private let settings = HostSettings()
  private let devices = USBDeviceService()
  private var coordinator: SessionCoordinator!
  private var poll: Task<Void, Never>?
  private var pendingStart: Task<Void, Never>?
  private var sleepStop: Task<Void, Never>?
  private var selection = ConnectionSelection()
  private var autoAttemptedSerial: String?
  private var allowsAutomaticConnection = !ProcessInfo.processInfo.arguments.contains(
    "--no-auto-connect")
  func applicationDidFinishLaunching(_ notification: Notification) {
    coordinator = SessionCoordinator(
      permissions: { [permissions] in permissions.ready() },
      status: { [weak self] snapshot in
        guard let self else { return }
        selection.update(snapshot)
        render()
      })
    configureConnectionActions()
    configureSettingsActions()
    NSWorkspace.shared.notificationCenter.addObserver(
      self,
      selector: #selector(sleep), name: NSWorkspace.willSleepNotification, object: nil)
    NSWorkspace.shared.notificationCenter.addObserver(
      self,
      selector: #selector(wake), name: NSWorkspace.didWakeNotification, object: nil)
    poll = Task { [weak self] in
      while !Task.isCancelled {
        await self?.refreshDevices()
        try? await Task.sleep(for: .seconds(3))
      }
    }
    render()
    if ProcessInfo.processInfo.arguments.contains("--show-connection") {
      menu.showWhenReady()
    }
  }
  private func configureConnectionActions() {
    menu.panel.onMode = { [weak self] mode in
      guard let self else { return }
      allowsAutomaticConnection = false
      selection.select(mode)
      render()
    }
    menu.panel.onDevice = { [weak self] device in
      guard let self else { return }
      allowsAutomaticConnection = false
      selection.select(device)
      render()
    }
    menu.panel.onAddress = { [weak self] address in
      guard let self else { return }
      allowsAutomaticConnection = false
      selection.select(address)
      render()
    }
    menu.panel.onConnect = { [weak self] in
      self?.allowsAutomaticConnection = false
      self?.connect()
    }
    menu.panel.onStop = { [weak self] in
      guard let self else { return }
      Task { await self.stopSession() }
    }
    menu.panel.onRetry = { [weak self] in
      guard let self else { return }
      Task { await self.coordinator.reconnect() }
    }
    menu.panel.onRemember = { [weak self] in
      guard let self, selection.isEditable, let device = selection.selectedDevice else { return }
      allowsAutomaticConnection = false  // Remembering takes effect on a later launch.
      settings.rememberedSerial = settings.rememberedSerial == device.serial ? nil : device.serial
      render()
    }
    menu.panel.onInstall = { [weak self] in self?.install() }
    menu.panel.onCleanup = { [weak self] in self?.cleanupReverse() }
  }
  private func configureSettingsActions() {
    menu.panel.onCodec = { [weak self] in
      guard let self else { return }
      settings.preferredCodec = $0
      render()
    }
    menu.panel.onSize = { [weak self] in
      guard let self else { return }
      settings.logicalSize = $0
      render()
    }
    menu.panel.onZoom = { [weak self] in
      guard let self else { return }
      settings.zoom = $0
      render()
    }
    menu.panel.onAuxiliary = { [weak self] in
      guard let self else { return }
      settings.auxiliaryAction = $0
      render()
    }
    menu.panel.onAVC = { [weak self] in
      guard let self else { return }
      settings.avcBitrate = $0
      render()
    }
    menu.panel.onHEVC = { [weak self] in
      guard let self else { return }
      settings.hevcBitrate = $0
      render()
    }
    menu.panel.onGrace = { [weak self] in
      guard let self else { return }
      settings.grace = $0
      render()
    }
    menu.panel.onLogs = {
      let folder = SessionLogger.logFolder
      NSWorkspace.shared.open(
        FileManager.default.fileExists(atPath: folder.path)
          ? folder
          : URL(fileURLWithPath: "/System/Applications/Utilities/Console.app"))
    }
  }
  private func render() { menu.render(selection, settings: settings) }
  private func refreshDevices() async {
    selection.availableAddresses(LocalIPv4Address.available())
    render()
    guard selection.isEditable else { return }
    let result: Result<[ADBDevice], Error>
    do { result = .success(try await devices.discover()) } catch { result = .failure(error) }
    guard selection.isEditable else { return }
    selection.discovered(result)
    render()
    guard case .success(let discovered) = result else { return }
    if let attempted = autoAttemptedSerial,
      !discovered.contains(where: { $0.serial == attempted })
    {
      autoAttemptedSerial = nil
    }
    if let remembered = settings.rememberedSerial,
      let candidate = discovered.first(where: { $0.serial == remembered }),
      autoAttemptedSerial != candidate.serial,
      allowsAutomaticConnection, pendingStart == nil,
      selection.mode == .usb, selection.snapshot.state == .idle
    {
      selection.select(candidate)
      render()
      autoAttemptedSerial = candidate.serial
      connect()
    }
  }
  private func connect() {
    guard pendingStart == nil, let target = selection.claimConnect() else { return }
    render()
    pendingStart = Task { [weak self] in
      guard let self else { return }
      var issue: String?
      defer {
        pendingStart = nil
        selection.finishConnect(issue: issue)
        render()
      }
      do {
        let route: any HostConnectionRoute
        if let address = target.address {
          try address.validateCurrent()
          route = try await devices.networkRoute(on: target.device, address: address)
        } else {
          route = try await devices.route(on: target.device)
        }
        if Task.isCancelled {
          await route.close()
          return
        }
        await coordinator.configure(settings.preferences())
        if Task.isCancelled {
          await route.close()
          return
        }
        await coordinator.start(route: route)
      } catch {
        if !Task.isCancelled {
          issue =
            if target.mode == .network && error as? HostFailure == .transport {
              "Selected Mac address changed. Choose an available address and try again."
            } else {
              (error as? HostFailure)?.localizedDescription
                ?? "Could not connect. Check USB authorization and the selected Mac address."
            }
        }
      }
    }
  }
  private func stopSession() async {
    let starting = pendingStart
    starting?.cancel()
    await coordinator.stop()
    await starting?.value
  }
  private func idleForDeviceOperation(_ device: ADBDevice) async -> Bool {
    let state = await coordinator.current().state
    return selection.isMaintaining && selection.selectedDevice == device
      && pendingStart == nil && (state == .idle || state == .failed)
  }
  private func install() {
    guard selection.isEditable, let selected = selection.selectedDevice else { return }
    let panel = NSOpenPanel()
    guard let apkType = UTType(filenameExtension: "apk") else { return }
    panel.allowedContentTypes = [apkType]
    panel.canChooseDirectories = false
    guard panel.runModal() == .OK, let apk = panel.url else { return }
    guard selection.claimOperation(on: selected) else { return }
    render()
    Task {
      var issue: String?
      defer {
        selection.finishOperation(issue: issue)
        render()
      }
      do {
        guard await idleForDeviceOperation(selected) else { throw HostFailure.invalidState }
        try await devices.install(apk: apk, on: selected)
      } catch {
        issue =
          (error as? HostFailure)?.localizedDescription
          ?? "Install failed. Check USB authorization and try again."
      }
    }
  }
  private func cleanupReverse() {
    guard selection.isEditable, let selected = selection.selectedDevice else { return }
    let prompt = NSAlert()
    prompt.messageText = "Remove Mirri USB reverse ports on the selected tablet?"
    prompt.informativeText =
      "Only tcp:5560 and tcp:5561 pointing to the same local ports will be removed. "
      + "Do this only when Mirri is stopped and you have checked they are stale."
    prompt.addButton(withTitle: "Remove these two ports")
    prompt.addButton(withTitle: "Cancel")
    guard prompt.runModal() == .alertFirstButtonReturn else { return }
    guard selection.claimOperation(on: selected) else { return }
    render()
    Task {
      var issue: String?
      defer {
        selection.finishOperation(issue: issue)
        render()
      }
      do {
        guard await idleForDeviceOperation(selected) else { throw HostFailure.invalidState }
        try await devices.explicitReverseCleanup(on: selected)
      } catch {
        issue =
          (error as? HostFailure)?.localizedDescription
          ?? "Cleanup failed. Check the USB device and try again."
      }
    }
  }
  @objc private func sleep() {
    sleepStop = Task { await stopSession() }
  }
  @objc private func wake() {
    Task {
      await sleepStop?.value
      sleepStop = nil
      await stopSession()
      autoAttemptedSerial = nil
      await refreshDevices()
    }
  }
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    poll?.cancel()
    Task {
      await stopSession()
      NSApplication.shared.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }
}
