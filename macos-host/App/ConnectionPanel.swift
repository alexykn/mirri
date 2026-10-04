import AppKit
import MirriHostCore
import SwiftUI
import SystemConfiguration

/// What the panel leads with. Everything technical lives on the Settings page.
enum PanelPhase: Equatable {
  case idle
  case working(String)
  case connecting(String)
  case reconnecting
  case connected
}

struct PanelStat: Identifiable, Equatable {
  let id: String
  let value: String
  let unit: String
}

@MainActor final class ConnectionPanelModel: ObservableObject {
  @Published private(set) var selection = ConnectionSelection()
  @Published private(set) var preferences = HostPreferences()
  @Published private(set) var autoConnect = true
  @Published private(set) var pairedCount = 0
  /// nil means the interface is chosen automatically.
  @Published private(set) var manualAddress: LocalIPv4Address?
  @Published var showSettings = false
  var onConnect: ((ADBDevice) -> Void)?
  var onAddress: ((LocalIPv4Address?) -> Void)?
  var onStop: (() -> Void)?
  var onRetry: (() -> Void)?
  var onInstall: (() -> Void)?
  var onUnpair: (() -> Void)?
  var onLogs: (() -> Void)?
  var onCodec: ((HostPreferences.Codec) -> Void)?
  var onSize: ((HostPreferences.LogicalSize) -> Void)?
  var onZoom: ((HostPreferences.Zoom) -> Void)?
  var onAuxiliary: ((HostPreferences.AuxiliaryAction) -> Void)?
  var onAVC: ((UInt32) -> Void)?
  var onHEVC: ((UInt32) -> Void)?
  var onGrace: ((Int) -> Void)?
  var onAdaptive: ((Bool) -> Void)?
  var onAutoConnect: ((Bool) -> Void)?

  func render(
    _ selection: ConnectionSelection, settings: HostSettings, pairedCount: Int,
    manualAddress: LocalIPv4Address?
  ) {
    self.selection = selection
    preferences = settings.preferences()
    autoConnect = settings.autoConnect
    self.pairedCount = pairedCount
    self.manualAddress = manualAddress
  }

  func addressLabel(_ address: LocalIPv4Address) -> String {
    let matches = (SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? []).first {
      (SCNetworkInterfaceGetBSDName($0) as String?) == address.interface
    }
    let name = matches.flatMap { SCNetworkInterfaceGetLocalizedDisplayName($0) as String? }
    return "\(name ?? address.interface) · \(address.address)"
  }

  var phase: PanelPhase {
    if selection.isMaintaining { return .working("Installing on tablet…") }
    switch selection.snapshot.state {
    case .streaming: return .connected
    case .waitingForReconnect: return .reconnecting
    case .stopping: return .working("Disconnecting…")
    case .checkingPermissions: return .connecting("Checking permissions")
    case .preparingTransport: return .connecting("Preparing connection")
    case .waitingForClient: return .connecting("Waiting for tablet")
    case .negotiating: return .connecting("Agreeing on video")
    case .creatingDisplay: return .connecting("Creating display")
    case .preparingClient: return .connecting("Starting video")
    case .idle, .failed: return selection.isStarting ? .connecting("Preparing connection") : .idle
    }
  }

  /// A problem worth a sentence; a missing cable or ADB alone is not one.
  var issue: String? {
    if let notice = selection.notice { return notice.message }
    if selection.snapshot.state == .failed, !selection.isStarting {
      return selection.snapshot.message
    }
    return nil
  }

  static func isPaired(_ device: ADBDevice) -> Bool { device.serial.hasPrefix("paired:") }

  /// A tablet that is both on the cable and waiting over Wi-Fi is one tablet to
  /// the person looking at the panel; the Wi-Fi entry needs no cable to stay up.
  var listedDevices: [ADBDevice] {
    let wireless = Set(selection.devices.filter(Self.isPaired).map(\.model))
    return selection.devices.filter { Self.isPaired($0) || !wireless.contains($0.model) }
  }

  static func name(_ device: ADBDevice) -> String {
    device.model.replacingOccurrences(of: "_", with: "-")
  }

  var activeName: String {
    selection.selectedDevice.map(Self.name) ?? "Tablet"
  }

  /// Frame rate, bitrate and control round trip, read from the session's metrics line.
  var stats: [PanelStat] {
    let text = selection.snapshot.metrics
    func first(_ patterns: [String]) -> Double? {
      for pattern in patterns {
        guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
          let range = Range(match.range(at: 1), in: text), let value = Double(text[range])
        else { continue }
        return value
      }
      return nil
    }
    var result: [PanelStat] = []
    if let fps = first([#"native encoded=\d+ fps=(\d+)"#, #"sent ([\d.]+) fps"#]) {
      // A still desktop sends nothing; that is idle, not a stalled stream.
      let rounded = Int(fps.rounded())
      result.append(
        PanelStat(id: "fps", value: rounded == 0 ? "Idle" : String(rounded), unit: "fps"))
    }
    if let bits = first([#"targetBps=(\d+)"#]) {
      result.append(
        PanelStat(id: "rate", value: String(Int((bits / 1e6).rounded())), unit: "Mbit/s"))
    } else if let megabits = first([#"sent [\d.]+ fps ([\d.]+) Mbit/s"#]) {
      result.append(PanelStat(id: "rate", value: String(Int(megabits.rounded())), unit: "Mbit/s"))
    }
    if let rtt = first([#"RTT ([\d.]+) ms"#]), rtt > 0 {
      result.append(PanelStat(id: "rtt", value: String(Int(rtt.rounded())), unit: "ms ping"))
    }
    return result
  }
}

// MARK: - Styling

extension View {
  @ViewBuilder fileprivate func secondaryAction() -> some View {
    if #available(macOS 26.0, *) {
      buttonStyle(.glass)
    } else {
      buttonStyle(.bordered)
    }
  }
  fileprivate func card() -> some View {
    padding(12)
      .background(
        .quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
  }
}

/// A full-width row that highlights under the pointer, like a system menu item.
private struct RowButtonStyle: ButtonStyle {
  @State private var hovering = false
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
      .background(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .fill(.primary.opacity(configuration.isPressed ? 0.14 : hovering ? 0.08 : 0))
      )
      .onHover { hovering = $0 }
      .animation(.easeOut(duration: 0.12), value: hovering)
      .focusEffectDisabled()
  }
}

private struct DeviceGlyph: View {
  let active: Bool
  var body: some View {
    RoundedRectangle(cornerRadius: 10, style: .continuous)
      .fill(active ? AnyShapeStyle(Color.accentColor.gradient) : AnyShapeStyle(.quaternary))
      .frame(width: 40, height: 40)
      .overlay {
        Image(systemName: "ipad.landscape")
          .font(.system(size: 18, weight: .medium))
          .foregroundStyle(active ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
      }
      .accessibilityHidden(true)
  }
}

// MARK: - Panel

private struct ConnectionPanel: View {
  @ObservedObject var model: ConnectionPanelModel

  private var selection: ConnectionSelection { model.selection }

  var body: some View {
    Group {
      if model.showSettings {
        SettingsPage(model: model) { model.showSettings = false }
      } else {
        main
      }
    }
    .frame(width: 320)
    .accessibilityElement(children: .contain)
  }

  private var main: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Mirri").font(.title3.weight(.semibold))
        Spacer()
        Button {
          model.showSettings = true
        } label: {
          Image(systemName: "gearshape").font(.system(size: 14, weight: .medium))
            .frame(width: 24, height: 24)
        }
        .buttonStyle(RowButtonStyle())
        .focusable(false)
        .foregroundStyle(.secondary)
        .help("Settings")
        .accessibilityLabel("Settings")
      }
      if let issue = model.issue { issueBanner(issue) }
      switch model.phase {
      case .idle: devices
      case .connected: activeCard(status: "Connected over Wi-Fi", busy: false)
      case .reconnecting: activeCard(status: "Reconnecting…", busy: true)
      case .connecting(let step): activeCard(status: "\(step)…", busy: true)
      case .working(let step): activeCard(status: step, busy: true)
      }
      Divider().padding(.horizontal, -4)
      Button {
        NSApplication.shared.terminate(nil)
      } label: {
        Text("Quit Mirri").frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 8).padding(.vertical, 5)
      }
      .buttonStyle(RowButtonStyle())
      .padding(.horizontal, -8)
      .padding(.top, -6)
    }
    .padding(.horizontal, 16)
    .padding(.top, 14)
    .padding(.bottom, 8)
  }

  private func issueBanner(_ message: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
      Text(message).font(.callout).fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
    }
    .padding(10)
    .background(.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
  }

  // MARK: Idle

  @ViewBuilder private var devices: some View {
    if model.listedDevices.isEmpty {
      VStack(spacing: 6) {
        Image(systemName: "ipad.landscape")
          .font(.system(size: 30, weight: .light))
          .foregroundStyle(.tertiary)
          .padding(.bottom, 2)
        Text(selection.hasCheckedDevices ? "No tablet nearby" : "Looking for tablets…")
          .font(.headline)
        Text(
          model.pairedCount > 0
            ? "Open Mirri on your tablet to use it as a display."
            : "Connect your tablet with a USB cable once to pair it."
        )
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity)
      .padding(.vertical, 18)
    } else {
      VStack(alignment: .leading, spacing: 2) {
        Text("Tablets").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
          .padding(.bottom, 2)
        ForEach(Array(model.listedDevices.enumerated()), id: \.offset) { _, device in
          Button {
            model.onConnect?(device)
          } label: {
            HStack(spacing: 12) {
              DeviceGlyph(active: false)
              VStack(alignment: .leading, spacing: 1) {
                Text(ConnectionPanelModel.name(device)).font(.body.weight(.medium))
                Text(
                  ConnectionPanelModel.isPaired(device) ? "Ready over Wi-Fi" : "Connected by cable"
                )
                .font(.subheadline).foregroundStyle(.secondary)
              }
              Spacer(minLength: 8)
              Text("Connect")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 11).padding(.vertical, 5)
                .background(Color.accentColor.opacity(0.16), in: Capsule())
            }
            .padding(.horizontal, 8).padding(.vertical, 7)
          }
          .buttonStyle(RowButtonStyle())
          .padding(.horizontal, -8)
          .disabled(!selection.isEditable)
          .accessibilityLabel("Connect \(ConnectionPanelModel.name(device))")
        }
      }
    }
  }

  // MARK: Active

  private func activeCard(status: String, busy: Bool) -> some View {
    let connected = model.phase == .connected
    return VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 12) {
        DeviceGlyph(active: connected)
        VStack(alignment: .leading, spacing: 1) {
          Text(model.activeName).font(.body.weight(.semibold))
          Text(status).font(.subheadline).foregroundStyle(.secondary)
        }
        Spacer(minLength: 8)
        if busy { ProgressView().controlSize(.small) }
      }
      if connected, !model.stats.isEmpty {
        HStack(spacing: 8) {
          ForEach(model.stats) { stat in
            VStack(spacing: 1) {
              Text(stat.value).font(.title3.weight(.semibold).monospacedDigit())
                .contentTransition(.numericText())
              Text(stat.unit).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(
              .quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .accessibilityElement(children: .combine)
          }
        }
      }
      HStack(spacing: 8) {
        Button {
          model.onStop?()
        } label: {
          Text(connected || model.phase == .reconnecting ? "Disconnect" : "Cancel")
            .frame(maxWidth: .infinity)
        }
        .secondaryAction()
        .disabled(selection.snapshot.state == .stopping || selection.isMaintaining)
        if selection.canRetry {
          Button {
            model.onRetry?()
          } label: {
            Image(systemName: "arrow.clockwise")
          }
          .secondaryAction()
          .help("Reconnect")
          .accessibilityLabel("Reconnect")
        }
      }
      .controlSize(.large)
    }
    .card()
  }
}

// MARK: - Settings

private struct SettingsPage: View {
  @ObservedObject var model: ConnectionPanelModel
  let back: () -> Void
  @State private var showAdvanced = false

  private var selection: ConnectionSelection { model.selection }
  private var locked: Bool { !selection.isEditable }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 6) {
        Button(action: back) {
          Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold))
            .frame(width: 24, height: 24)
        }
        .buttonStyle(RowButtonStyle())
        .focusable(false)
        .accessibilityLabel("Back")
        Text("Settings").font(.title3.weight(.semibold))
        Spacer()
      }
      .padding(.horizontal, 12)
      .padding(.top, 12)
      .padding(.bottom, 8)
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          if locked {
            Text("Changes apply to the next connection. Disconnect to edit them.")
              .font(.callout).foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          group("Display") {
            row("Resolution") {
              Picker(
                "Resolution",
                selection: Binding(
                  get: { model.preferences.logicalSize }, set: { model.onSize?($0) })
              ) {
                Text("Sharper text").tag(HostPreferences.LogicalSize.retina)
                Text("More space").tag(HostPreferences.LogicalSize.native)
              }
            }
          }
          group("Video") {
            row("Quality") {
              Picker(
                "Quality",
                selection: Binding(
                  get: { model.preferences.avcBitrate }, set: { model.onAVC?($0) })
              ) {
                Text("Standard").tag(UInt32(20_000_000))
                Text("High").tag(UInt32(40_000_000))
                Text("Maximum").tag(UInt32(80_000_000))
              }
            }
            Divider()
            toggle("Adapt to the network", isOn: model.preferences.adaptiveBitrate) {
              model.onAdaptive?($0)
            }
          }
          group("Touch and Pencil") {
            row("Pinch") {
              Picker(
                "Pinch",
                selection: Binding(
                  get: { model.preferences.zoom }, set: { model.onZoom?($0) })
              ) {
                Text("Zoom").tag(HostPreferences.Zoom.commandKeys)
                Text("Off").tag(HostPreferences.Zoom.disabled)
              }
            }
            Divider()
            row("Pencil button") {
              Picker(
                "Pencil button",
                selection: Binding(
                  get: { model.preferences.auxiliaryAction }, set: { model.onAuxiliary?($0) })
              ) {
                Text("Mission Control").tag(HostPreferences.AuxiliaryAction.missionControl)
                Text("Right click").tag(HostPreferences.AuxiliaryAction.contextClick)
                Text("Off").tag(HostPreferences.AuxiliaryAction.disabled)
              }
            }
          }
          group("Connection") {
            toggle("Connect automatically", isOn: model.autoConnect) {
              model.onAutoConnect?($0)
            }
            Divider()
            row("Network") {
              Picker(
                "Network",
                selection: Binding(
                  get: { model.manualAddress }, set: { model.onAddress?($0) })
              ) {
                Text("Automatic").tag(LocalIPv4Address?.none)
                ForEach(Array(selection.addresses.enumerated()), id: \.offset) { _, address in
                  Text(model.addressLabel(address)).tag(LocalIPv4Address?.some(address))
                }
              }
            }
          }
          group("Tablet") {
            action(
              "Install or update the tablet app…",
              enabled: selection.devices.contains { !ConnectionPanelModel.isPaired($0) }
            ) {
              model.onInstall?()
            }
            Divider()
            action(
              model.pairedCount == 0 ? "No paired tablets" : "Forget paired tablets",
              enabled: model.pairedCount > 0
            ) { model.onUnpair?() }
          }
          DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
            VStack(alignment: .leading, spacing: 10) {
              group(nil) {
                row("Codec (TLS video)") {
                  Picker(
                    "Codec",
                    selection: Binding(
                      get: { model.preferences.codec }, set: { model.onCodec?($0) })
                  ) {
                    Text("Automatic").tag(HostPreferences.Codec.automatic)
                    Text("H.264").tag(HostPreferences.Codec.avc)
                    Text("HEVC").tag(HostPreferences.Codec.hevc)
                  }
                }
                Divider()
                row("HEVC bitrate") {
                  Picker(
                    "HEVC bitrate",
                    selection: Binding(
                      get: { model.preferences.hevcBitrate }, set: { model.onHEVC?($0) })
                  ) {
                    ForEach([25, 40, 80], id: \.self) { n in
                      Text("\(n) Mbit/s").tag(UInt32(n * 1_000_000))
                    }
                  }
                }
                Divider()
                row("Keep display while reconnecting") {
                  Picker(
                    "Grace",
                    selection: Binding(
                      get: { model.preferences.graceSeconds }, set: { model.onGrace?($0) })
                  ) {
                    ForEach([5, 15, 30], id: \.self) { n in Text("\(n) s").tag(n) }
                  }
                }
              }
              VStack(alignment: .leading, spacing: 3) {
                Text(selection.snapshot.virtualMode)
                Text(selection.snapshot.clientMode)
                Text(selection.snapshot.video)
              }
              .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
              Button("Open Logs") { model.onLogs?() }.buttonStyle(.link).font(.callout)
            }
            .padding(.top, 8)
          }
          .font(.subheadline.weight(.medium))
          .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
      }
      .frame(maxHeight: 460)
    }
  }

  private func group<Content: View>(_ title: String?, @ViewBuilder content: () -> Content)
    -> some View
  {
    VStack(alignment: .leading, spacing: 5) {
      if let title {
        Text(title).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
          .padding(.leading, 4)
      }
      VStack(spacing: 0) { content() }
        .padding(.horizontal, 12)
        .background(
          .quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
    .foregroundStyle(.primary)
    .font(.body)
  }

  private func row<Control: View>(_ label: String, @ViewBuilder control: () -> Control)
    -> some View
  {
    HStack {
      Text(label)
      Spacer(minLength: 8)
      control().labelsHidden().pickerStyle(.menu).fixedSize().disabled(locked)
    }
    .padding(.vertical, 6)
  }

  private func toggle(_ label: String, isOn: Bool, set: @escaping (Bool) -> Void) -> some View {
    Toggle(isOn: Binding(get: { isOn }, set: set)) {
      Text(label).fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .toggleStyle(.switch)
    .controlSize(.small)
    .padding(.vertical, 7)
    .disabled(locked)
  }

  private func action(_ label: String, enabled: Bool, perform: @escaping () -> Void) -> some View {
    Button(action: perform) {
      Text(label).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .foregroundStyle(enabled && !locked ? Color.accentColor : Color.secondary)
    .disabled(!enabled || locked)
  }
}

@MainActor func makeConnectionPanel(_ model: ConnectionPanelModel) -> NSViewController {
  let controller = NSHostingController(rootView: ConnectionPanel(model: model))
  // The popover follows the content: a short list when idle, a card when connected.
  controller.sizingOptions = [.preferredContentSize]
  return controller
}
