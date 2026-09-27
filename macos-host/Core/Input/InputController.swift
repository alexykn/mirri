import CoreGraphics
import Foundation

public struct CoordinateMapper: Sendable {
  public let bounds: CGRect
  public init(bounds: CGRect) { self.bounds = bounds }
  public func point(x: Float, y: Float) -> CGPoint {
    CGPoint(
      x: bounds.minX + min(CGFloat(x), 1) * (bounds.width - 1),
      y: bounds.minY + min(CGFloat(y), 1) * (bounds.height - 1))
  }
}

public struct PointerState: Sendable {
  public private(set) var down: UInt64?
  public private(set) var nextBatch: UInt64 = 0
  private var lastTime: UInt64 = 0
  public init() {}
  public mutating func beginBatch(_ sequence: UInt64) throws {
    guard sequence == nextBatch, nextBatch < UInt64.max else { throw HostFailure.malformed }
    nextBatch += 1
  }
  public mutating func accept(id: UInt64, phase: PointerPhase, time: UInt64) throws {
    guard time >= lastTime else { throw HostFailure.malformed }
    lastTime = time
    switch phase {
    case .down:
      guard down == nil else { throw HostFailure.invalidState }
      down = id
    case .move:
      guard down == id else { throw HostFailure.invalidState }
    case .up, .cancel:
      guard down == id else { throw HostFailure.invalidState }
      down = nil
    case .hoverEnter, .hoverMove, .hoverExit: break
    }
  }
  public mutating func reset() -> Bool {
    let held = down != nil
    self = PointerState()
    return held
  }
}

public final class InputController: @unchecked Sendable {
  private let mapper: CoordinateMapper
  private let zoom: HostPreferences.Zoom
  private let auxiliaryAction: HostPreferences.AuxiliaryAction
  private let lock = NSLock()
  private var pointer = PointerState()
  private var penActive = false
  private var zoomAccumulator = 0.0
  private let source = CGEventSource(stateID: .hidSystemState)
  public init(
    display: ActiveDisplay, zoom: HostPreferences.Zoom = .commandKeys,
    auxiliaryAction: HostPreferences.AuxiliaryAction = .disabled
  ) {
    mapper = CoordinateMapper(bounds: display.bounds)
    self.zoom = zoom
    self.auxiliaryAction = auxiliaryAction
  }
  private func mouse(_ type: CGEventType, at point: CGPoint, button: CGMouseButton = .left) {
    CGEvent(
      mouseEventSource: source, mouseType: type, mouseCursorPosition: point,
      mouseButton: button)?.post(tap: .cghidEventTap)
  }
  private func point(_ value: InputPoint) -> CGPoint { mapper.point(x: value.x, y: value.y) }
  private func key(_ code: CGKeyCode, flags: CGEventFlags = []) {
    for pressed in [true, false] {
      if let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: pressed) {
        event.flags = flags
        event.post(tap: .cghidEventTap)
      }
    }
  }
  private func pointers(batch: UInt64, samples: [PointerReading]) throws {
    try pointer.beginBatch(batch)
    for sample in samples {
      let location = point(sample.point)
      try pointer.accept(id: sample.id, phase: sample.phase, time: sample.time)
      // Pen/eraser have the same button ownership; pressure is included in tablet fields.
      if sample.phase == .down {
        if sample.tool != .finger {
          proximity(enter: true)
          penActive = true
        }
        postPointer(.leftMouseDown, at: location, tool: sample.tool, pressure: sample.pressure)
      } else if sample.phase == .move {
        postPointer(.leftMouseDragged, at: location, tool: sample.tool, pressure: sample.pressure)
      } else if sample.phase == .up || sample.phase == .cancel {
        mouse(.leftMouseUp, at: location)
        if penActive {
          proximity(enter: false)
          penActive = false
        }
      } else if sample.phase == .hoverEnter || sample.phase == .hoverMove
        || sample.phase == .hoverExit
      {
        mouse(.mouseMoved, at: location)
      }
      if sample.tool != .finger && (sample.phase == .down || sample.phase == .move) {
        tabletPoint(at: location, sample: sample)
      }
    }
  }
  public func handle(_ message: RemoteInput) throws {
    lock.lock()
    defer { lock.unlock() }
    switch message {
    case .pointers(let batch, let samples):
      try pointers(batch: batch, samples: samples)
    case .scroll(let phase, let position, let dx, let dy):
      let location = point(position)
      mouse(.mouseMoved, at: location)
      let x = Int32(clamping: Int(dx))
      let y = Int32(clamping: Int(dy))
      if let event = CGEvent(
        scrollWheelEvent2Source: source, units: .pixel,
        wheelCount: 2, wheel1: y, wheel2: x, wheel3: 0)
      {
        let mapped: CGScrollPhase =
          phase == .began
          ? .began : phase == .changed ? .changed : phase == .ended ? .ended : .cancelled
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(mapped.rawValue))
        event.post(tap: .cghidEventTap)
      }
    case .zoom(_, _, let value):
      if zoom == .disabled { break }
      zoomAccumulator += log(Double(value)) / log(1.12)
      let steps = min(6, Int(abs(zoomAccumulator)))
      if steps > 0 {
        for _ in 0..<steps { key(zoomAccumulator > 0 ? 24 : 27, flags: .maskCommand) }
        zoomAccumulator += zoomAccumulator > 0 ? -Double(steps) : Double(steps)
      }
    case .context(let position):
      let location = point(position)
      mouse(.rightMouseDown, at: location, button: .right)
      mouse(.rightMouseUp, at: location, button: .right)
    case .shortcut(let action):
      switch action {
      case .missionControl: key(126, flags: .maskControl)
      case .previousSpace: key(123, flags: .maskControl)
      case .nextSpace: key(124, flags: .maskControl)
      case .showDesktop: key(103)
      case .custom: break  // custom action is deliberately not bound to an arbitrary shortcut
      }
    case .auxiliary(let code, let scan, let phase):
      if code == 190 && scan == 0x0007_006f && phase == 1 {
        switch auxiliaryAction {
        case .missionControl: key(126, flags: .maskControl)
        case .contextClick:
          let cursor = CGEvent(source: source)?.location ?? mapper.point(x: 0, y: 0)
          mouse(.rightMouseDown, at: cursor, button: .right)
          mouse(.rightMouseUp, at: cursor, button: .right)
        case .disabled: break
        }
      }
    }
  }
  private func postPointer(
    _ type: CGEventType, at point: CGPoint, tool: PointerTool,
    pressure: Float
  ) {
    guard
      let event = CGEvent(
        mouseEventSource: source, mouseType: type,
        mouseCursorPosition: point, mouseButton: .left)
    else { return }
    if tool != .finger {
      event.setDoubleValueField(.tabletEventPointPressure, value: Double(pressure))
    }
    event.post(tap: .cghidEventTap)
  }
  private func proximity(enter: Bool) {
    guard let event = CGEvent(source: source) else { return }
    event.type = .tabletProximity
    event.setIntegerValueField(.tabletProximityEventEnterProximity, value: enter ? 1 : 0)
    event.post(tap: .cghidEventTap)
  }
  private func tabletPoint(at location: CGPoint, sample: PointerReading) {
    guard let event = CGEvent(source: source) else { return }
    event.type = .tabletPointer
    event.location = location
    event.setIntegerValueField(.tabletEventPointX, value: Int64(location.x))
    event.setIntegerValueField(.tabletEventPointY, value: Int64(location.y))
    event.setDoubleValueField(.tabletEventPointPressure, value: Double(sample.pressure))
    event.setDoubleValueField(
      .tabletEventTiltX, value: Double(sin(sample.orientation) * sin(sample.tilt)))
    event.setDoubleValueField(
      .tabletEventTiltY, value: Double(cos(sample.orientation) * sin(sample.tilt)))
    event.post(tap: .cghidEventTap)
  }
  public func reset() {
    lock.lock()
    defer { lock.unlock() }
    if pointer.reset() {
      let location = CGEvent(source: source)?.location ?? mapper.point(x: 0, y: 0)
      mouse(.leftMouseUp, at: location)
    }
    if penActive {
      proximity(enter: false)
      penActive = false
    }
    zoomAccumulator = 0
  }
}
