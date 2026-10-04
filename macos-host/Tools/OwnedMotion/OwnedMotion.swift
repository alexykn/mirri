import AppKit
import CoreGraphics
import QuartzCore

/// Deliberately only the Mirri-owned virtual display, never the user's physical screen.
@MainActor private final class Checkerboard: NSView {
  private var phase = false
  private(set) var draws = 0
  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    draws += 1
    NSColor.black.setFill()
    bounds.fill()
    for row in 0..<10 {
      for column in 0..<16 where (row + column).isMultiple(of: 2) != phase {
        let tile = NSRect(
          x: bounds.minX + bounds.width * CGFloat(column) / 16,
          y: bounds.minY + bounds.height * CGFloat(row) / 10,
          width: bounds.width / 16, height: bounds.height / 10)
        (phase ? NSColor.systemTeal : NSColor.systemOrange).setFill()
        tile.fill()
      }
    }
  }
  func advance() {
    phase.toggle()
    needsDisplay = true
  }
}

@MainActor private final class Motion: NSObject, NSApplicationDelegate {
  private var displayLink: CADisplayLink?
  private var window: NSWindow?
  private var checkerboard: Checkerboard?
  private var ticks = 0
  private var startedNs: UInt64 = 0
  private let seconds: Int

  init(seconds: Int) { self.seconds = seconds }

  func applicationDidFinishLaunching(_ notification: Notification) {
    var found = [CGDirectDisplayID](repeating: 0, count: 16)
    var count: UInt32 = 0
    guard CGGetOnlineDisplayList(UInt32(found.count), &found, &count) == .success else {
      fail("display enumeration unavailable")
    }
    let owned = found.prefix(Int(count)).filter { id in
      guard id != CGMainDisplayID(), CGDisplayIsOnline(id) != 0,
        let mode = CGDisplayCopyDisplayMode(id)
      else { return false }
      return
        CGDisplayVendorNumber(id) == 0x4D52_5249
        && CGDisplayModelNumber(id) == 0x2456
        && mode.pixelWidth == 2456 && mode.pixelHeight == 1600
    }
    guard owned.count == 1,
      let screen = NSScreen.screens.first(where: {
        ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
          == owned[0]
      })
    else { fail("exactly one owned Mirri display required") }
    let view = Checkerboard(frame: NSRect(origin: .zero, size: screen.frame.size))
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: screen.frame.size),
      styleMask: .borderless, backing: .buffered,
      defer: false, screen: screen)
    window.contentView = view
    window.ignoresMouseEvents = true
    // The initializer takes screen-relative coordinates; setFrame takes global
    // desktop coordinates. Do not apply a non-main display's origin twice.
    window.setFrame(screen.frame, display: true)
    guard window.frame == screen.frame, window.screen == screen else {
      fail("motion window is not on the owned display")
    }
    window.orderFront(nil)
    self.window = window
    checkerboard = view
    let link = screen.displayLink(target: self, selector: #selector(advance(_:)))
    link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
    link.add(to: .main, forMode: .common)
    displayLink = link
    startedNs = DispatchTime.now().uptimeNanoseconds
    DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(seconds)) { [weak self] in
      self?.finish()
    }
  }

  @objc private func advance(_ sender: CADisplayLink) {
    ticks += 1
    checkerboard?.advance()
  }

  private func finish() {
    displayLink?.invalidate()
    window?.orderOut(nil)
    // Stimulus ticks are not capture, transport or scanout counts.
    let elapsedNs = DispatchTime.now().uptimeNanoseconds - startedNs
    print(
      "ownedMotion durationSeconds=\(seconds) elapsedNs=\(elapsedNs) "
        + "displayLinkTicks=\(ticks) viewDraws=\(checkerboard?.draws ?? 0)")
    NSApplication.shared.terminate(nil)
  }

  private func fail(_ reason: String) -> Never {
    fputs("ownedMotion refused: \(reason)\n", stderr)
    exit(2)
  }
}

@MainActor private enum OwnedMotionMain {
  static func main() {
    let arguments = CommandLine.arguments
    guard arguments.count == 4, arguments[1] == "--arm-owned-display",
      arguments[2] == "--active-seconds",
      let seconds = Int(arguments[3]), [90, 300, 1800].contains(seconds)
    else {
      fputs("usage: MirriOwnedMotion --arm-owned-display --active-seconds 90|300|1800\n", stderr)
      exit(2)
    }
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    let controller = Motion(seconds: seconds)
    application.delegate = controller
    application.run()
    withExtendedLifetime(controller) {}
  }
}

OwnedMotionMain.main()
