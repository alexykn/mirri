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
  private var control: ControlServer?
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
    let server = ControlServer { [weak self] request in
      await self?.control(request) ?? Data(#"{"ok":false,"error":"Mirri is quitting"}"#.utf8)
    }
    if server.start() { control = server }
  }
  private func configureConnectionActions() {
    menu.panel.onDevice = { [weak self] device in
      guard let self else { return }
      selection.select(device)
      render()
    }
    menu.panel.onAddress = { [weak self] address in
      guard let self else { return }
      selection.select(address)
      render()
    }
    menu.panel.onConnect = { [weak self] in
      // WebRTC over UDP is the default; the TCP/TLS video path stays for comparison.
      self?.connect(rtc: !ProcessInfo.processInfo.arguments.contains("--tcp-video"))
    }
    menu.panel.onStop = { [weak self] in
      guard let self else { return }
      Task { await self.stopSession() }
    }
    menu.panel.onRetry = { [weak self] in self?.reconnect() }
    menu.panel.onInstall = { [weak self] in self?.install() }
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
    menu.panel.onAdaptive = { [weak self] in
      guard let self else { return }
      settings.adaptiveBitrate = $0
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
  }
  private func reconnect() {
    Task { await coordinator.reconnect() }
  }
  private func connect(rtc: Bool) {
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
        try target.address.validateCurrent()
        if rtc {
          route = try await devices.rtcRoute(on: target.device, address: target.address)
        } else {
          route = try await devices.networkRoute(on: target.device, address: target.address)
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
            if error as? HostFailure == .transport {
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
    Task { await install(apk: apk, on: selected) }
  }
  /// Returns the failure shown to the user, or nil on success.
  @discardableResult private func install(apk: URL, on selected: ADBDevice) async -> String? {
    guard selection.claimOperation(on: selected) else { return "Mirri is busy" }
    render()
    var issue: String?
    do {
      guard await idleForDeviceOperation(selected) else { throw HostFailure.invalidState }
      try await devices.install(apk: apk, on: selected)
    } catch {
      issue =
        (error as? HostFailure)?.localizedDescription
        ?? "Install failed. Check USB authorization and try again."
    }
    selection.finishOperation(issue: issue)
    render()
    return issue
  }
  @objc private func sleep() {
    sleepStop = Task { await stopSession() }
  }
  @objc private func wake() {
    Task {
      await sleepStop?.value
      sleepStop = nil
      await stopSession()
      await refreshDevices()
    }
  }
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    poll?.cancel()
    control?.stop()
    Task {
      await stopSession()
      NSApplication.shared.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }
}

// MARK: - `mirri` terminal command

extension AppDelegate {
  private func reply(_ fields: [String: Any]) -> Data {
    (try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]))
      ?? Data(#"{"ok":false,"error":"encoding"}"#.utf8)
  }
  private func failure(_ message: String) -> Data { reply(["ok": false, "error": message]) }

  /// Numeric and model facts only; the ADB serial never leaves the app.
  private func status() -> [String: Any] {
    let snapshot = selection.snapshot
    let preferences = settings.preferences()
    return [
      "ok": true, "headline": selection.headline, "state": snapshot.state.rawValue,
      "message": snapshot.message, "starting": selection.isStarting,
      "busy": !selection.isEditable, "notice": selection.notice?.message ?? NSNull(),
      "device": snapshot.device, "virtualMode": snapshot.virtualMode,
      "clientMode": snapshot.clientMode, "video": snapshot.video, "metrics": snapshot.metrics,
      "devices": selection.devices.map(\.model),
      "selectedDevice": selection.selectedDevice.flatMap(selection.devices.firstIndex)
        .map { $0 + 1 } ?? NSNull(),
      "addresses": selection.addresses.map { ["interface": $0.interface, "address": $0.address] },
      "selectedAddress": selection.selectedAddress?.address ?? NSNull(),
      "logFolder": SessionLogger.logFolder.path,
      "settings": [
        "codec": preferences.codec.rawValue, "size": preferences.logicalSize.rawValue,
        "zoom": preferences.zoom.rawValue, "pencil": preferences.auxiliaryAction.rawValue,
        "avcBitrate": preferences.avcBitrate / 1_000_000,
        "hevcBitrate": preferences.hevcBitrate / 1_000_000, "grace": preferences.graceSeconds,
        "adaptiveBitrate": preferences.adaptiveBitrate,
      ],
    ]
  }

  private func chooseDevice(_ wanted: Any?) -> String? {
    if let index = wanted as? Int {
      guard selection.devices.indices.contains(index - 1) else { return "No tablet \(index)" }
      selection.select(selection.devices[index - 1])
    } else if let model = wanted as? String {
      let matches = selection.devices.filter { $0.model == model }
      guard matches.count == 1 else { return "Expected one tablet named \(model)" }
      selection.select(matches[0])
    } else if selection.selectedDevice == nil, selection.devices.count == 1 {
      selection.select(selection.devices[0])
    }
    return selection.selectedDevice == nil
      ? (selection.readinessHelp ?? "Choose a tablet with --device") : nil
  }

  private func chooseAddress(_ wanted: Any?) -> String? {
    if let wanted = wanted as? String {
      let matches = selection.addresses.filter { $0.interface == wanted || $0.address == wanted }
      guard matches.count == 1 else { return "No single Mac address matches \(wanted)" }
      selection.select(matches[0])
    } else if selection.selectedAddress == nil, selection.addresses.count == 1 {
      selection.select(selection.addresses[0])
    }
    return selection.selectedAddress == nil
      ? (selection.readinessHelp ?? "Choose a Mac address with --address") : nil
  }

  private func applySettings(_ request: [String: Any]) -> String? {
    if let value = request["codec"] as? String {
      guard let codec = HostPreferences.Codec(rawValue: value) else { return "Unknown codec" }
      settings.preferredCodec = codec
    }
    if let value = request["size"] as? String {
      guard let size = HostPreferences.LogicalSize(rawValue: value) else { return "Unknown size" }
      settings.logicalSize = size
    }
    if let value = request["zoom"] as? String {
      guard let zoom = HostPreferences.Zoom(rawValue: value) else { return "Unknown zoom" }
      settings.zoom = zoom
    }
    if let value = request["pencil"] as? String {
      guard let action = HostPreferences.AuxiliaryAction(rawValue: value) else {
        return "Unknown pencil action"
      }
      settings.auxiliaryAction = action
    }
    if let value = request["adaptiveBitrate"] {
      guard let adaptive = value as? Bool else { return "adaptiveBitrate must be true or false" }
      settings.adaptiveBitrate = adaptive
    }
    for (key, range) in [("avcBitrate", 20...80), ("hevcBitrate", 25...80), ("grace", 1...60)] {
      guard let value = request[key] else { continue }
      guard let number = value as? Int, range.contains(number) else {
        return "\(key) must be \(range.lowerBound)...\(range.upperBound)"
      }
      switch key {
      case "avcBitrate": settings.avcBitrate = UInt32(number) * 1_000_000
      case "hevcBitrate": settings.hevcBitrate = UInt32(number) * 1_000_000
      default: settings.grace = number
      }
    }
    return nil
  }

  func control(_ data: Data) async -> Data {
    guard let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let command = request["command"] as? String
    else { return failure("Malformed request") }
    switch command {
    case "status":
      return reply(status())
    case "refresh":
      await refreshDevices()
      return reply(status())
    case "show":
      menu.showWhenReady()
      return reply(status())
    case "connect":
      guard selection.isEditable else { return failure("Mirri is busy; disconnect first") }
      await refreshDevices()
      guard selection.isEditable else { return failure("Mirri is busy; disconnect first") }
      if let problem = chooseDevice(request["device"]) ?? chooseAddress(request["address"]) {
        render()
        return failure(problem)
      }
      let media = request["media"] as? String ?? "rtc"
      guard media == "tcp" || media == "rtc" else { return failure("Unknown media") }
      connect(rtc: media == "rtc")
      guard pendingStart != nil else {
        return failure(selection.readinessHelp ?? "Cannot connect")
      }
      return reply(status())
    case "disconnect":
      Task { await self.stopSession() }
      return reply(status())
    case "reconnect":
      guard selection.canRetry else { return failure("Not connected") }
      reconnect()
      return reply(status())
    case "set":
      guard selection.isEditable else { return failure("Settings apply to the next connection") }
      if let problem = applySettings(request) { return failure(problem) }
      render()
      return reply(status())
    case "install":
      guard let path = request["apk"] as? String, path.hasSuffix(".apk"),
        FileManager.default.fileExists(atPath: path)
      else { return failure("APK not found") }
      guard selection.isEditable else { return failure("Mirri is busy; disconnect first") }
      await refreshDevices()
      if let problem = chooseDevice(request["device"]) { return failure(problem) }
      guard let selected = selection.selectedDevice else { return failure("No tablet") }
      if let issue = await install(apk: URL(fileURLWithPath: path), on: selected) {
        return failure(issue)
      }
      return reply(status())
    case "quit":
      // Not from a main-queue job: the terminate-later run loop could not then
      // drain the main queue to run the session stop it waits for.
      NSApplication.shared.perform(
        #selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
      return reply(["ok": true])
    default:
      return failure("Unknown command")
    }
  }
}
