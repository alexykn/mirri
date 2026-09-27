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
  private var selected: ADBDevice?
  private var autoAttemptedSerial: String?
  func applicationDidFinishLaunching(_ notification: Notification) {
    coordinator = SessionCoordinator(
      permissions: { [permissions] in permissions.ready() },
      status: { [menu] snapshot in menu.update(snapshot) })
    menu.onSelect = { [weak self] device in self?.selected = device }
    menu.onStart = { [weak self] in self?.start() }
    menu.onStop = { [weak self] in
      guard let self else { return }
      Task { await self.stopSession() }
    }
    menu.onReconnect = { [weak self] in
      guard let self else { return }
      Task { await self.coordinator.reconnect() }
    }
    menu.onRemember = { [weak self] in
      guard let self, let selected = self.selected else { return }
      self.settings.rememberedSerial = selected.serial
    }
    menu.onInstall = { [weak self] in self?.install() }
    menu.onReverseCleanup = { [weak self] in self?.cleanupReverse() }
    menu.onCodec = { [weak self] in self?.settings.preferredCodec = $0 }
    menu.onLogicalSize = { [weak self] in self?.settings.logicalSize = $0 }
    menu.onZoom = { [weak self] in self?.settings.zoom = $0 }
    menu.onAuxiliaryAction = { [weak self] in self?.settings.auxiliaryAction = $0 }
    menu.onAVCBitrate = { [weak self] in self?.settings.avcBitrate = $0 }
    menu.onHEVCBitrate = { [weak self] in self?.settings.hevcBitrate = $0 }
    menu.onGrace = { [weak self] in self?.settings.grace = $0 }
    menu.onOpenLogs = {
      let folder = SessionLogger.logFolder
      NSWorkspace.shared.open(
        FileManager.default.fileExists(atPath: folder.path)
          ? folder
          : URL(fileURLWithPath: "/System/Applications/Utilities/Console.app"))
    }
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
  }
  private func refreshDevices() async {
    let state = await coordinator.current().state
    guard state == .idle || state == .failed else { return }
    guard let discovered = try? await devices.discover() else { return }
    menu.discovered(discovered)
    if let attempted = autoAttemptedSerial,
      !discovered.contains(where: { $0.serial == attempted })
    {
      autoAttemptedSerial = nil
    }
    if let selected, !discovered.contains(selected) { self.selected = nil }
    if selected == nil { selected = discovered.first }
    if let remembered = settings.rememberedSerial,
      let candidate = discovered.first(where: { $0.serial == remembered }),
      autoAttemptedSerial != candidate.serial,
      (await coordinator.current()).state == .idle
    {
      selected = candidate
      autoAttemptedSerial = candidate.serial
      start()
    }
  }
  private func start() {
    guard let selected, pendingStart == nil else { return }
    pendingStart = Task { [weak self] in
      guard let self else { return }
      defer { pendingStart = nil }
      do {
        let route = try await devices.route(on: selected)
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
        if !Task.isCancelled { NSApplication.shared.presentError(error) }
      }
    }
  }
  private func stopSession() async {
    let starting = pendingStart
    starting?.cancel()
    await coordinator.stop()
    await starting?.value
  }
  private func idleForDeviceOperation() async -> Bool {
    let state = await coordinator.current().state
    return state == .idle || state == .failed
  }
  private func install() {
    guard let selected else { return }
    let panel = NSOpenPanel()
    guard let apkType = UTType(filenameExtension: "apk") else { return }
    panel.allowedContentTypes = [apkType]
    panel.canChooseDirectories = false
    guard panel.runModal() == .OK, let apk = panel.url else { return }
    Task {
      do {
        guard await idleForDeviceOperation() else { throw HostFailure.invalidState }
        try await devices.install(apk: apk, on: selected)
      } catch {
        NSApplication.shared.presentError(error)
      }
    }
  }
  private func cleanupReverse() {
    guard let selected else { return }
    let prompt = NSAlert()
    prompt.messageText = "Remove Mirri USB reverse ports on the selected tablet?"
    prompt.informativeText =
      "Only tcp:5560 and tcp:5561 pointing to the same local ports will be removed. "
      + "Do this only when Mirri is stopped and you have checked they are stale."
    prompt.addButton(withTitle: "Remove these two ports")
    prompt.addButton(withTitle: "Cancel")
    guard prompt.runModal() == .alertFirstButtonReturn else { return }
    Task {
      do {
        guard await idleForDeviceOperation() else { throw HostFailure.invalidState }
        try await devices.explicitReverseCleanup(on: selected)
      } catch {
        NSApplication.shared.presentError(error)
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
