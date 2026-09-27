import AppKit
import MirriHostCore

@MainActor final class StatusMenuController: NSObject {
  private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
  var onStart: (() -> Void)?
  var onStop: (() -> Void)?
  var onReconnect: (() -> Void)?
  var onInstall: (() -> Void)?
  var onReverseCleanup: (() -> Void)?
  var onSelect: ((ADBDevice) -> Void)?
  var onRemember: (() -> Void)?
  var onOpenLogs: (() -> Void)?
  var onCodec: ((HostPreferences.Codec) -> Void)?
  var onLogicalSize: ((HostPreferences.LogicalSize) -> Void)?
  var onZoom: ((HostPreferences.Zoom) -> Void)?
  var onAuxiliaryAction: ((HostPreferences.AuxiliaryAction) -> Void)?
  var onAVCBitrate: ((UInt32) -> Void)?
  var onHEVCBitrate: ((UInt32) -> Void)?
  var onGrace: ((Int) -> Void)?
  private var latest = HostSnapshot()
  private var devices: [ADBDevice] = []
  func update(_ snapshot: HostSnapshot) {
    latest = snapshot
    rebuild()
  }
  func discovered(_ devices: [ADBDevice]) {
    self.devices = devices
    rebuild()
  }
  override init() {
    super.init()
    item.button?.title = "▣ Mirri"
    rebuild()
  }
  private func line(_ label: String) -> NSMenuItem {
    let item = NSMenuItem(title: label, action: nil, keyEquivalent: "")
    item.isEnabled = false
    return item
  }
  private func action(_ label: String, _ selector: Selector) -> NSMenuItem {
    let entry = NSMenuItem(title: label, action: selector, keyEquivalent: "")
    entry.target = self
    return entry
  }
  private func rebuild() {
    let menu = NSMenu(title: "Mirri")
    menu.addItem(line("State: \(latest.state.rawValue) — \(latest.message)"))
    menu.addItem(line("Device: \(latest.device)"))
    menu.addItem(line("Mac display: \(latest.virtualMode)"))
    menu.addItem(line("Tablet: \(latest.clientMode)"))
    menu.addItem(line(latest.video))
    menu.addItem(line(latest.metrics))
    menu.addItem(.separator())
    for (index, device) in devices.enumerated() {
      let entry = action("Select \(device.model) [USB \(index + 1)]", #selector(selectDevice(_:)))
      entry.tag = index
      menu.addItem(entry)
    }
    let start = action("Start", #selector(startSession))
    start.isEnabled = latest.state == .idle || latest.state == .failed
    menu.addItem(start)
    let stop = action("Stop", #selector(stopSession))
    stop.isEnabled = latest.state != .idle && latest.state != .failed
    menu.addItem(stop)
    let reconnect = action("Reconnect", #selector(reconnectSession))
    reconnect.isEnabled = latest.state == .streaming
    menu.addItem(reconnect)
    menu.addItem(action("Remember selected USB device for auto-connect", #selector(remember)))
    let options = NSMenu(title: "Settings")
    for (index, codec) in [HostPreferences.Codec.automatic, .avc, .hevc].enumerated() {
      let entry = action("Codec: \(codec.rawValue)", #selector(setCodec(_:)))
      entry.tag = index
      options.addItem(entry)
    }
    for (index, size) in [HostPreferences.LogicalSize.native, .retina].enumerated() {
      let label = size == .native ? "2456x1600 native" : "1228x800 HiDPI (2x backing)"
      let entry = action("Mac logical size: \(label)", #selector(setLogicalSize(_:)))
      entry.tag = index
      options.addItem(entry)
    }
    for (index, zoom) in [HostPreferences.Zoom.commandKeys, .disabled].enumerated() {
      let entry = action("Pinch: \(zoom.rawValue)", #selector(setZoom(_:)))
      entry.tag = index
      options.addItem(entry)
    }
    for (index, choice) in [
      HostPreferences.AuxiliaryAction.missionControl, .contextClick, .disabled,
    ]
    .enumerated() {
      let entry = action("M-Pencil F20: \(choice.rawValue)", #selector(setAuxiliaryAction(_:)))
      entry.tag = index
      options.addItem(entry)
    }
    for value in [20, 40, 80] {
      let entry = action("AVC: \(value) Mbit/s", #selector(setAVC(_:)))
      entry.tag = value
      options.addItem(entry)
    }
    for value in [25, 40, 80] {
      let entry = action("HEVC: \(value) Mbit/s", #selector(setHEVC(_:)))
      entry.tag = value
      options.addItem(entry)
    }
    for value in [5, 15, 30] {
      let entry = action("Disconnect grace: \(value)s", #selector(setGrace(_:)))
      entry.tag = value
      options.addItem(entry)
    }
    let settingsItem = NSMenuItem(title: "Settings (next session)", action: nil, keyEquivalent: "")
    settingsItem.submenu = options
    menu.addItem(settingsItem)
    menu.addItem(action("Install/Upgrade client APK… (explicit)", #selector(install)))
    let cleanup = action("Clean up Mirri USB reverse ports…", #selector(cleanupReverse))
    cleanup.isEnabled = latest.state == .idle || latest.state == .failed
    menu.addItem(cleanup)
    menu.addItem(action("Open local logs", #selector(openLogs)))
    menu.addItem(.separator())
    menu.addItem(action("Quit Mirri", #selector(quit)))
    item.menu = menu
  }
  @objc private func selectDevice(_ sender: NSMenuItem) {
    if devices.indices.contains(sender.tag) { onSelect?(devices[sender.tag]) }
  }
  @objc private func startSession() { onStart?() }
  @objc private func stopSession() { onStop?() }
  @objc private func reconnectSession() { onReconnect?() }
  @objc private func install() { onInstall?() }
  @objc private func cleanupReverse() { onReverseCleanup?() }
  @objc private func remember() { onRemember?() }
  @objc private func openLogs() { onOpenLogs?() }
  @objc private func setCodec(_ sender: NSMenuItem) {
    let choices: [HostPreferences.Codec] = [.automatic, .avc, .hevc]
    if choices.indices.contains(sender.tag) { onCodec?(choices[sender.tag]) }
  }
  @objc private func setLogicalSize(_ sender: NSMenuItem) {
    let choices: [HostPreferences.LogicalSize] = [.native, .retina]
    if choices.indices.contains(sender.tag) { onLogicalSize?(choices[sender.tag]) }
  }
  @objc private func setZoom(_ sender: NSMenuItem) {
    let choices: [HostPreferences.Zoom] = [.commandKeys, .disabled]
    if choices.indices.contains(sender.tag) { onZoom?(choices[sender.tag]) }
  }
  @objc private func setAuxiliaryAction(_ sender: NSMenuItem) {
    let choices: [HostPreferences.AuxiliaryAction] = [.missionControl, .contextClick, .disabled]
    if choices.indices.contains(sender.tag) { onAuxiliaryAction?(choices[sender.tag]) }
  }
  @objc private func setAVC(_ sender: NSMenuItem) {
    onAVCBitrate?(UInt32(sender.tag) * 1_000_000)
  }
  @objc private func setHEVC(_ sender: NSMenuItem) {
    onHEVCBitrate?(UInt32(sender.tag) * 1_000_000)
  }
  @objc private func setGrace(_ sender: NSMenuItem) { onGrace?(sender.tag) }
  @objc private func quit() { NSApplication.shared.terminate(nil) }
}
