import Foundation
import MirriHostCore

@MainActor final class HostSettings {
  private let store = UserDefaults.standard
  var preferredCodec: HostPreferences.Codec {
    get {
      HostPreferences.Codec(rawValue: store.string(forKey: "preferredCodec") ?? "automatic")
        ?? .automatic
    }
    set { store.set(newValue.rawValue, forKey: "preferredCodec") }
  }
  var logicalSize: HostPreferences.LogicalSize {
    get {
      HostPreferences.LogicalSize(rawValue: store.string(forKey: "logicalSize") ?? "native")
        ?? .native
    }
    set { store.set(newValue.rawValue, forKey: "logicalSize") }
  }
  var grace: Int {
    get { store.object(forKey: "grace") as? Int ?? 15 }
    set { store.set(min(60, max(1, newValue)), forKey: "grace") }
  }
  var zoom: HostPreferences.Zoom {
    get {
      HostPreferences.Zoom(rawValue: store.string(forKey: "zoom") ?? "commandKeys") ?? .commandKeys
    }
    set { store.set(newValue.rawValue, forKey: "zoom") }
  }
  var auxiliaryAction: HostPreferences.AuxiliaryAction {
    get {
      HostPreferences.AuxiliaryAction(
        rawValue: store.string(forKey: "auxiliaryAction") ?? "disabled")
        ?? .disabled
    }
    set { store.set(newValue.rawValue, forKey: "auxiliaryAction") }
  }
  var avcBitrate: UInt32 {
    get {
      UInt32(
        clamping: store.integer(forKey: "avcBitrate") == 0
          ? 40_000_000 : store.integer(forKey: "avcBitrate"))
    }
    set { store.set(min(80_000_000, max(20_000_000, newValue)), forKey: "avcBitrate") }
  }
  var hevcBitrate: UInt32 {
    get {
      UInt32(
        clamping: store.integer(forKey: "hevcBitrate") == 0
          ? 25_000_000 : store.integer(forKey: "hevcBitrate"))
    }
    set { store.set(min(80_000_000, max(25_000_000, newValue)), forKey: "hevcBitrate") }
  }
  var adaptiveBitrate: Bool {
    get { store.object(forKey: "adaptiveBitrate") as? Bool ?? true }
    set { store.set(newValue, forKey: "adaptiveBitrate") }
  }
  func preferences() -> HostPreferences {
    HostPreferences(
      codec: preferredCodec, logicalSize: logicalSize, zoom: zoom,
      auxiliaryAction: auxiliaryAction,
      avcBitrate: avcBitrate, hevcBitrate: hevcBitrate, graceSeconds: grace,
      adaptiveBitrate: adaptiveBitrate)
  }
}
