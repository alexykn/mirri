import AppKit
import CoreGraphics
import Foundation
import VirtualDisplayShim

public struct ActiveDisplay: Sendable {
  public let id: CGDirectDisplayID
  /// Global desktop coordinates are logical points, not the encoded pixel backing.
  public let bounds: CGRect
  public let refreshHz: Double
  public let logicalSize: HostPreferences.LogicalSize
}

public enum DisplayReadback {
  public static func matchesMode(
    logicalWidth: Int, logicalHeight: Int, pixelWidth: Int, pixelHeight: Int,
    refreshHz: Double, requested: HostPreferences.LogicalSize
  ) -> Bool {
    logicalWidth == requested.width && logicalHeight == requested.height
      && pixelWidth == 2456 && pixelHeight == 1600
      && abs(refreshHz - 60) < 0.01
  }
  /// Fail closed if macOS publishes another logical mode, pixel backing or refresh.
  public static func matches(
    logicalWidth: Int, logicalHeight: Int, pixelWidth: Int, pixelHeight: Int,
    refreshHz: Double, bounds: CGRect, requested: HostPreferences.LogicalSize
  ) -> Bool {
    matchesMode(
      logicalWidth: logicalWidth, logicalHeight: logicalHeight,
      pixelWidth: pixelWidth, pixelHeight: pixelHeight,
      refreshHz: refreshHz, requested: requested)
      && abs(bounds.width - CGFloat(requested.width)) < 0.01
      && abs(bounds.height - CGFloat(requested.height)) < 0.01
  }
}

/// A bounded, numeric-only snapshot; no display identity is formatted or persisted.
struct DisplayGeometry {
  struct Screen {
    let roles: String
    let bounds: CGRect
    let logical: CGSize?
    let pixels: CGSize?
    let frame: CGRect?
    let visibleFrame: CGRect?
  }

  /// The C API writes only `returned` entries; never interpret zero-filled capacity.
  static func candidates(
    _ storage: [CGDirectDisplayID], returned: UInt32, main: CGDirectDisplayID,
    owned: CGDirectDisplayID
  ) -> [CGDirectDisplayID] {
    var ids = Array(storage.prefix(Int(returned))).filter { $0 != 0 }
    for id in [owned, main] where id != 0 && !ids.contains(id) { ids.append(id) }
    return ids
  }

  static func format(_ phase: String, onlineCount: UInt32?, screens: [Screen]) -> String {
    func rect(_ value: CGRect?) -> String {
      guard let value else { return "unavailable" }
      return "\(Int(value.minX)),\(Int(value.minY)),\(Int(value.width)),\(Int(value.height))"
    }
    func size(_ value: CGSize?) -> String {
      guard let value else { return "unavailable" }
      return "\(Int(value.width))x\(Int(value.height))"
    }
    let entries = screens.prefix(8).map { screen in
      "{roles=\(screen.roles) cgXYWH=\(rect(screen.bounds)) "
        + "logical=\(size(screen.logical)) pixels=\(size(screen.pixels)) "
        + "nsXYWH=\(rect(screen.frame)) nsVisibleXYWH=\(rect(screen.visibleFrame))}"
    }.joined(separator: " ")
    return "geometry phase=\(phase) online=\(onlineCount.map(String.init) ?? "unavailable") "
      + "rolesShown=\(min(screens.count, 8)) truncated=\(screens.count > 8) " + entries
  }
}

@MainActor public final class VirtualDisplayManager {
  private var controller: VirtualDisplayController?
  private let logger = SessionLogger()
  public private(set) var active: ActiveDisplay?

  public init() {}
  public func create(logicalSize: HostPreferences.LogicalSize) async throws -> ActiveDisplay {
    if let controller {
      guard let current = Self.verified(controller.displayID, logicalSize: logicalSize) else {
        throw HostFailure.exactDisplay
      }
      active = current
      return current
    }
    logGeometry("beforeCreate")
    let owned = VirtualDisplayController()
    // Never tear down an unrelated live display with our stable identity.
    var serial: UInt32 = 0x4D49_5252
    for attempt in 0..<8 {
      if !Self.identityExists(serial: serial) { break }
      serial = 0x4D49_5252 + UInt32(attempt + 1)
    }
    guard !Self.identityExists(serial: serial) else {
      logger.display("identity unavailable for eight candidate slots")
      throw HostFailure.exactDisplay
    }
    do {
      try owned.create(
        withSerial: serial, logicalWidth: UInt32(logicalSize.width),
        logicalHeight: UInt32(logicalSize.height), hiDPI: logicalSize.hiDPI)
    } catch {
      let failure = error as NSError
      logger.display(
        "shim refused requested \(logicalSize.width)x\(logicalSize.height): "
          + (failure.domain == "dev.mirri.display"
            ? failure.localizedDescription : "unexpected API error code \(failure.code)"))
      throw HostFailure.exactDisplay
    }
    controller = owned
    do {
      // Allow the newly published mode to settle before one explicit selection.
      for _ in 0..<3 {
        guard controller === owned else { throw HostFailure.exactDisplay }
        if let published = Self.verified(owned.displayID, logicalSize: logicalSize) {
          logger.display("verified \(Self.readback(owned.displayID))")
          active = published
          logGeometry("verifiedCreate", ownedID: owned.displayID, serial: serial)
          return published
        }
        try await Task.sleep(for: .milliseconds(100))
      }
      guard controller === owned else { throw HostFailure.exactDisplay }
      let id = owned.displayID
      // Never select on a borrowed/reused ID or a different live display.
      guard id != 0, CGDisplayIsOnline(id) != 0,
        CGDisplayVendorNumber(id) == 0x4D52_5249,
        CGDisplayModelNumber(id) == 0x2456,
        CGDisplaySerialNumber(id) == serial
      else { throw HostFailure.exactDisplay }
      guard let candidate = Self.exactMode(id, logicalSize: logicalSize) else {
        logger.display(
          "exact selectable mode absent observed \(Self.readback(id)) "
            + "available \(Self.availableModes(id)) duplicates \(Self.availableModes(id, includeDuplicates: true))"
        )
        throw HostFailure.exactDisplay
      }
      // Single attempt on our owned display only; no global defaults or toggle loop.
      let result = CGDisplaySetDisplayMode(id, candidate, nil)
      logger.display("owned exact mode selection CGError=\(result.rawValue)")
      guard result == .success else { throw HostFailure.exactDisplay }
      for _ in 0..<30 {
        guard controller === owned else { throw HostFailure.exactDisplay }
        if let published = Self.verified(id, logicalSize: logicalSize) {
          logger.display("verified \(Self.readback(id))")
          active = published
          logGeometry("verifiedCreate", ownedID: id, serial: serial)
          return published
        }
        try await Task.sleep(for: .milliseconds(100))
      }
      logger.display(
        "verification timed out requested \(logicalSize.width)x\(logicalSize.height) "
          + "backing 2456x1600@60 observed \(Self.readback(owned.displayID)) "
          + "available \(Self.availableModes(owned.displayID))")
      throw HostFailure.exactDisplay
    } catch {
      if controller === owned {
        let id = owned.displayID
        destroy()
        // A failed set-mode must not silently leave a virtual display behind.
        if id != 0 {
          for _ in 0..<20 {
            if !Self.identityExists(serial: serial) { break }
            try? await Task.sleep(for: .milliseconds(100))
          }
          logger.display(
            "owned teardown identityStillOnline=\(Self.identityExists(serial: serial))")
        }
      }
      throw error
    }
  }
  public func destroy() {
    let formerID = controller?.displayID
    let formerSerial = formerID.map(CGDisplaySerialNumber)
    active = nil
    controller?.destroy()
    controller = nil
    if let formerID, let formerSerial {
      logGeometry("afterDestroy", ownedID: formerID, serial: formerSerial)
    }
  }
  /// Only role-bearing online displays; never log display IDs or desktop contents.
  private func logGeometry(
    _ phase: String, ownedID: CGDirectDisplayID = 0, serial: UInt32 = 0
  ) {
    var count: UInt32 = 0
    guard CGGetOnlineDisplayList(0, nil, &count) == .success else {
      logger.display(DisplayGeometry.format(phase, onlineCount: nil, screens: []))
      return
    }
    let limit = min(count, 32)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(limit))
    var returned = limit
    guard CGGetOnlineDisplayList(limit, &ids, &returned) == .success else {
      logger.display(DisplayGeometry.format(phase, onlineCount: count, screens: []))
      return
    }
    let main = CGMainDisplayID()
    let selected = DisplayGeometry.candidates(
      ids, returned: returned,
      main: CGDisplayIsOnline(main) != 0 ? main : 0,
      owned: CGDisplayIsOnline(ownedID) != 0 ? ownedID : 0)
    let screens = selected.compactMap { id -> DisplayGeometry.Screen? in
      guard id != 0, CGDisplayIsOnline(id) != 0 else { return nil }
      let owned =
        id == ownedID && CGDisplayVendorNumber(id) == 0x4D52_5249
        && CGDisplayModelNumber(id) == 0x2456 && CGDisplaySerialNumber(id) == serial
      let builtin = CGDisplayIsBuiltin(id) != 0
      let primary = id == main
      let roles = [owned ? "owned" : nil, builtin ? "builtin" : nil, primary ? "main" : nil]
        .compactMap { $0 }.joined(separator: "+")
      guard !roles.isEmpty else { return nil }
      let mode = CGDisplayCopyDisplayMode(id)
      let screen = NSScreen.screens.first {
        ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
          .uint32Value == id
      }
      return DisplayGeometry.Screen(
        roles: roles, bounds: CGDisplayBounds(id),
        logical: mode.map { CGSize(width: $0.width, height: $0.height) },
        pixels: mode.map { CGSize(width: $0.pixelWidth, height: $0.pixelHeight) },
        frame: screen?.frame, visibleFrame: screen?.visibleFrame)
    }
    logger.display(DisplayGeometry.format(phase, onlineCount: count, screens: screens))
  }
  private static func identityExists(serial: UInt32) -> Bool {
    var count: UInt32 = 0
    guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return false }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return false }
    return ids.prefix(Int(count)).contains {
      CGDisplayVendorNumber($0) == 0x4D52_5249 && CGDisplayModelNumber($0) == 0x2456
        && CGDisplaySerialNumber($0) == serial
    }
  }
  /// No display ID/name/serial or captured contents enter this diagnostic.
  private static func readback(_ id: CGDirectDisplayID) -> String {
    guard id != 0 else { return "displayID=absent" }
    let online = CGDisplayIsOnline(id) != 0
    guard let mode = CGDisplayCopyDisplayMode(id) else {
      return "online=\(online) mode=absent"
    }
    let bounds = CGDisplayBounds(id)
    return "online=\(online) logical=\(mode.width)x\(mode.height) "
      + "pixels=\(mode.pixelWidth)x\(mode.pixelHeight) "
      + "hz=\(String(format: "%.3f", mode.refreshRate)) "
      + "bounds=\(Int(bounds.width))x\(Int(bounds.height))"
  }
  /// Bounded numeric-only snapshot of modes advertised by our owned display.
  /// This is diagnostic only: selecting a different macOS mode may orphan a
  /// virtual display, so never switch modes as part of verification.
  private static func displayModes(
    _ id: CGDirectDisplayID, includeDuplicates: Bool
  ) -> [CGDisplayMode]? {
    let options: CFDictionary? =
      includeDuplicates
      ? [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary : nil
    return CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode]
  }
  private static func availableModes(_ id: CGDirectDisplayID, includeDuplicates: Bool = false)
    -> String
  {
    guard id != 0, let modes = displayModes(id, includeDuplicates: includeDuplicates)
    else { return "unavailable" }
    let summary = modes.prefix(16).map { mode in
      "\(mode.width)x\(mode.height)/\(mode.pixelWidth)x\(mode.pixelHeight)@"
        + String(format: "%.3f", mode.refreshRate)
    }.joined(separator: ",")
    return "count=\(modes.count) [\(summary)]"
  }
  private static func exactMode(
    _ id: CGDirectDisplayID, logicalSize: HostPreferences.LogicalSize
  ) -> CGDisplayMode? {
    guard let modes = displayModes(id, includeDuplicates: true) else { return nil }
    return modes.first {
      DisplayReadback.matchesMode(
        logicalWidth: $0.width, logicalHeight: $0.height,
        pixelWidth: $0.pixelWidth, pixelHeight: $0.pixelHeight,
        refreshHz: $0.refreshRate, requested: logicalSize)
    }
  }
  private static func verified(
    _ id: CGDirectDisplayID, logicalSize: HostPreferences.LogicalSize
  ) -> ActiveDisplay? {
    guard id != 0, CGDisplayIsOnline(id) != 0, let mode = CGDisplayCopyDisplayMode(id)
    else { return nil }
    let bounds = CGDisplayBounds(id)
    guard
      DisplayReadback.matches(
        logicalWidth: mode.width, logicalHeight: mode.height,
        pixelWidth: mode.pixelWidth, pixelHeight: mode.pixelHeight,
        refreshHz: mode.refreshRate, bounds: bounds, requested: logicalSize)
    else { return nil }
    return ActiveDisplay(
      id: id, bounds: bounds, refreshHz: mode.refreshRate, logicalSize: logicalSize)
  }
}
