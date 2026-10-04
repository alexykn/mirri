import AppKit
import MirriHostCore

/// A transient, keyboard-dismissable menu-bar popover; never creates a main window.
@MainActor final class StatusMenuController: NSObject {
  private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
  private let popover = NSPopover()
  let panel = ConnectionPanelModel()

  override init() {
    super.init()
    popover.behavior = .transient  // Outside click and Escape dismiss the panel.
    popover.animates = true
    // Sit flush under the menu bar like the system's own menus, without the
    // callout arrow. Not public API; if it is ever refused the arrow returns.
    if popover.responds(to: NSSelectorFromString("setShouldHideAnchor:")) {
      popover.setValue(true, forKey: "shouldHideAnchor")
    }
    popover.contentViewController = makeConnectionPanel(panel)
    if let button = item.button {
      button.title = "▣ Mirri"
      button.toolTip = "Mirri · Connection"
      button.target = self
      button.action = #selector(toggle)
      button.setAccessibilityLabel("Mirri connection")
    }
  }

  func render(
    _ selection: ConnectionSelection, settings: HostSettings, pairedCount: Int,
    manualAddress: LocalIPv4Address?
  ) {
    panel.render(
      selection, settings: settings, pairedCount: pairedCount, manualAddress: manualAddress)
  }

  func showWhenReady() {
    Task { [weak self] in
      // Status-item layout can trail applicationDidFinishLaunching. A first
      // show may be ignored even with an attached status-bar window.
      try? await Task.sleep(for: .milliseconds(200))
      for _ in 0..<50 {
        guard let self else { return }
        if show() { return }
        try? await Task.sleep(for: .milliseconds(100))
      }
      NSLog("Mirri connection panel could not open: status icon is not ready")
    }
  }

  @discardableResult func show() -> Bool {
    guard let button = item.button, button.window?.screen != nil else { return false }
    if popover.isShown { return true }
    // Do not activate the accessory app here: activation during `open -n`
    // briefly made it frontmost before the launcher's previous app reclaimed
    // focus, which dismissed the transient popover immediately.
    popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    popover.contentViewController?.view.window?.makeKey()
    // Like a system menu: keyboard focus starts nowhere rather than ringing the first button.
    popover.contentViewController?.view.window?.makeFirstResponder(nil)
    return popover.isShown
  }

  func hide() { popover.performClose(nil) }

  @objc private func toggle() {
    if popover.isShown { popover.performClose(nil) } else if !show() { showWhenReady() }
  }
}
