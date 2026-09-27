import AppKit
import MirriHostCore
import SwiftUI
import SystemConfiguration

@MainActor final class ConnectionPanelModel: ObservableObject {
  @Published private(set) var selection = ConnectionSelection()
  @Published private(set) var preferences = HostPreferences()
  @Published private(set) var remembersTablet = false
  @Published var height: CGFloat = 475
  var onMode: ((ConnectionMode) -> Void)?
  var onDevice: ((ADBDevice) -> Void)?
  var onAddress: ((LocalIPv4Address) -> Void)?
  var onConnect: (() -> Void)?
  var onStop: (() -> Void)?
  var onRetry: (() -> Void)?
  var onRemember: (() -> Void)?
  var onInstall: (() -> Void)?
  var onCleanup: (() -> Void)?
  var onLogs: (() -> Void)?
  var onCodec: ((HostPreferences.Codec) -> Void)?
  var onSize: ((HostPreferences.LogicalSize) -> Void)?
  var onZoom: ((HostPreferences.Zoom) -> Void)?
  var onAuxiliary: ((HostPreferences.AuxiliaryAction) -> Void)?
  var onAVC: ((UInt32) -> Void)?
  var onHEVC: ((UInt32) -> Void)?
  var onGrace: ((Int) -> Void)?

  func render(_ selection: ConnectionSelection, settings: HostSettings) {
    self.selection = selection
    preferences = settings.preferences()
    remembersTablet =
      settings.rememberedSerial == selection.selectedDevice?.serial
      && selection.selectedDevice != nil
  }

  func addressLabel(_ address: LocalIPv4Address) -> String {
    let matches = (SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? []).first {
      (SCNetworkInterfaceGetBSDName($0) as String?) == address.interface
    }
    let name = matches.flatMap { SCNetworkInterfaceGetLocalizedDisplayName($0) as String? }
    return "\(name ?? address.interface) (\(address.interface)) · \(address.address)"
  }

  var title: String { selection.headline }

  var detail: String {
    if selection.discoveryFailed && selection.isEditable {
      return selection.readinessHelp ?? "Can't check USB devices."
    }
    if let notice = selection.notice { return notice.message }
    if selection.isMaintaining { return "Waiting for the selected USB tablet…" }
    if selection.isStarting && selection.snapshot.state == .idle {
      return selection.mode == .usb
        ? "Preparing USB connection…" : "Preparing secure network connection…"
    }
    if selection.snapshot.state == .failed { return selection.snapshot.message }
    if let help = selection.readinessHelp { return help }
    let snapshot = selection.snapshot
    if snapshot.state == .idle { return "Choose how to connect, then press Connect." }
    if snapshot.state == .streaming { return snapshot.device }
    return snapshot.message
  }
}

private struct ConnectionPanel: View {
  @ObservedObject var model: ConnectionPanelModel
  @State private var showSettings = false
  @State private var showDetails = false
  @State private var showAdvanced = false

  private var selection: ConnectionSelection { model.selection }

  var body: some View {
    VStack(spacing: 0) {
      ScrollView {
        VStack(alignment: .leading, spacing: 13) {
          header
          Divider()
          connectionChoices
          Divider()
          deviceChoice
          if selection.mode == .network { networkChoice }
          Text(
            selection.mode == .usb
              ? "USB stays attached while streaming. Unlock the tablet and allow USB debugging."
              : "Share a Wi-Fi LAN or tablet hotspot. USB is needed to start; after Connected you may unplug it. Not Wi-Fi Direct."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          DisclosureGroup("Settings · next connection", isExpanded: $showSettings) {
            settings
              .padding(.top, 6)
          }
          .font(.subheadline)
          DisclosureGroup("Session details", isExpanded: $showDetails) {
            VStack(alignment: .leading, spacing: 5) {
              Text(selection.snapshot.virtualMode)
              Text(selection.snapshot.clientMode)
              Text(selection.snapshot.video)
              Text(selection.snapshot.metrics)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .padding(.top, 6)
          }
          .font(.subheadline)
          DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
            advanced
              .padding(.top, 6)
          }
          .font(.subheadline)
          Divider()
          footer
        }
        .padding(18)
      }
      Divider()
      controls
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }
    .frame(width: 350, height: model.height)
    .accessibilityElement(children: .contain)
  }

  private var header: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: "display.2")
        .font(.title2)
        .foregroundStyle(.tint)
        .frame(width: 30, height: 30)
      VStack(alignment: .leading, spacing: 4) {
        Text("Mirri").font(.headline)
        HStack(spacing: 6) {
          Circle()
            .fill(
              selection.snapshot.state == .streaming
                ? Color.green
                : selection.snapshot.state == .failed || selection.notice != nil
                  ? Color.orange : Color.secondary
            )
            .frame(width: 7, height: 7)
          Text(model.title).font(.subheadline.weight(.medium))
        }
        Text(model.detail)
          .font(.caption)
          .foregroundStyle(
            selection.snapshot.state == .failed || selection.discoveryFailed
              || selection.notice != nil
              ? Color.orange : Color.secondary
          )
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 0)
    }
  }

  private var connectionChoices: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("CONNECTION").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
      HStack(spacing: 8) {
        modeButton(.usb, title: "USB", symbol: "cable.connector")
        modeButton(.network, title: "Network", symbol: "wifi")
      }
    }
  }

  private func modeButton(_ mode: ConnectionMode, title: String, symbol: String) -> some View {
    Button {
      model.onMode?(mode)
    } label: {
      HStack(spacing: 7) {
        Image(systemName: symbol)
        Text(title)
        Spacer(minLength: 0)
        if selection.mode == mode { Image(systemName: "checkmark").font(.caption.bold()) }
      }
      .frame(maxWidth: .infinity)
      .padding(.horizontal, 10)
      .padding(.vertical, 9)
      .background(
        selection.mode == mode ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.08),
        in: RoundedRectangle(cornerRadius: 9))
    }
    .buttonStyle(.plain)
    .disabled(!selection.isEditable)
    .accessibilityLabel("\(title) connection")
    .accessibilityAddTraits(selection.mode == mode ? [.isSelected] : [])
  }

  private var deviceChoice: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("TABLET").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
      Menu {
        ForEach(Array(selection.devices.enumerated()), id: \.offset) { index, device in
          Button {
            model.onDevice?(device)
          } label: {
            if selection.selectedDevice == device {
              Label("\(device.model) · USB \(index + 1)", systemImage: "checkmark")
            } else {
              Text("\(device.model) · USB \(index + 1)")
            }
          }
        }
      } label: {
        choiceLabel(selectedTabletLabel, symbol: "ipad")
      }
      .disabled(!selection.isEditable || selection.devices.isEmpty)
      .accessibilityLabel("Selected tablet: \(selection.selectedDevice?.model ?? "none")")
    }
  }

  private var selectedTabletLabel: String {
    guard let selectedDevice = selection.selectedDevice,
      let index = selection.devices.firstIndex(of: selectedDevice)
    else { return selection.selectedDevice?.model ?? "Choose a USB tablet" }
    return "\(selectedDevice.model) · USB \(index + 1)"
  }

  private var networkChoice: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("MAC ADDRESS · IPv4").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
      Menu {
        ForEach(Array(selection.addresses.enumerated()), id: \.offset) { _, address in
          Button {
            model.onAddress?(address)
          } label: {
            if selection.selectedAddress == address {
              Label(model.addressLabel(address), systemImage: "checkmark")
            } else {
              Text(model.addressLabel(address))
            }
          }
        }
      } label: {
        choiceLabel(
          selection.selectedAddress.map(model.addressLabel) ?? "Choose a Mac interface",
          symbol: "network")
      }
      .disabled(!selection.isEditable || selection.addresses.isEmpty)
      .accessibilityLabel("Mac network address: \(selection.selectedAddress?.address ?? "none")")
    }
  }

  private func choiceLabel(_ title: String, symbol: String) -> some View {
    HStack(spacing: 8) {
      Image(systemName: symbol).frame(width: 17)
      Text(title).lineLimit(1).truncationMode(.middle)
      Spacer(minLength: 3)
    }
    .frame(maxWidth: .infinity)
  }

  private var controls: some View {
    HStack(spacing: 8) {
      if selection.canStop {
        Button(stopLabel) {
          model.onStop?()
        }
        .buttonStyle(.borderedProminent)
        .disabled(selection.snapshot.state == .stopping)
        .frame(maxWidth: .infinity)
        if selection.canRetry {
          Button("Reconnect") { model.onRetry?() }
            .buttonStyle(.bordered)
        }
      } else {
        Button("Connect") { model.onConnect?() }
          .buttonStyle(.borderedProminent)
          .disabled(!selection.canConnect)
          .frame(maxWidth: .infinity)
      }
    }
    .controlSize(.large)
  }

  private var stopLabel: String {
    switch selection.snapshot.state {
    case .streaming, .waitingForReconnect: "Disconnect"
    case .stopping: "Disconnecting…"
    default: "Cancel"
    }
  }

  private var settings: some View {
    VStack(alignment: .leading, spacing: 6) {
      Picker(
        "Codec",
        selection: Binding(
          get: { model.preferences.codec }, set: { model.onCodec?($0) })
      ) {
        Text("Automatic").tag(HostPreferences.Codec.automatic)
        Text("AVC").tag(HostPreferences.Codec.avc)
        Text("HEVC").tag(HostPreferences.Codec.hevc)
      }
      Picker(
        "Mac resolution",
        selection: Binding(
          get: { model.preferences.logicalSize }, set: { model.onSize?($0) })
      ) {
        Text("Native 2456 × 1600").tag(HostPreferences.LogicalSize.native)
        Text("HiDPI 1228 × 800").tag(HostPreferences.LogicalSize.retina)
      }
      Picker(
        "Pinch",
        selection: Binding(
          get: { model.preferences.zoom }, set: { model.onZoom?($0) })
      ) {
        Text("Command keys").tag(HostPreferences.Zoom.commandKeys)
        Text("Disabled").tag(HostPreferences.Zoom.disabled)
      }
      Picker(
        "Pencil button",
        selection: Binding(
          get: { model.preferences.auxiliaryAction }, set: { model.onAuxiliary?($0) })
      ) {
        Text("Mission Control").tag(HostPreferences.AuxiliaryAction.missionControl)
        Text("Context click").tag(HostPreferences.AuxiliaryAction.contextClick)
        Text("Disabled").tag(HostPreferences.AuxiliaryAction.disabled)
      }
      Picker(
        "AVC bitrate",
        selection: Binding(
          get: { model.preferences.avcBitrate }, set: { model.onAVC?($0) })
      ) {
        ForEach([20, 40, 80], id: \.self) { n in
          Text("\(n) Mbit/s").tag(UInt32(n * 1_000_000))
        }
      }
      Picker(
        "HEVC bitrate",
        selection: Binding(
          get: { model.preferences.hevcBitrate }, set: { model.onHEVC?($0) })
      ) {
        ForEach([25, 40, 80], id: \.self) { n in
          Text("\(n) Mbit/s").tag(UInt32(n * 1_000_000))
        }
      }
      Picker(
        "Reconnect grace",
        selection: Binding(
          get: { model.preferences.graceSeconds }, set: { model.onGrace?($0) })
      ) {
        ForEach([5, 15, 30], id: \.self) { n in Text("\(n) seconds").tag(n) }
      }
    }
    .pickerStyle(.menu)
    .disabled(!selection.isEditable)
  }

  private var advanced: some View {
    VStack(alignment: .leading, spacing: 7) {
      Button(
        model.remembersTablet
          ? "Forget automatic USB connection" : "Remember tablet for USB auto-connect"
      ) {
        model.onRemember?()
      }
      .disabled(!selection.isEditable || selection.selectedDevice == nil)
      Button("Install or upgrade client APK…") { model.onInstall?() }
        .disabled(!selection.isEditable || selection.selectedDevice == nil)
      Button("Clean up USB reverse ports…") { model.onCleanup?() }
        .disabled(!selection.isEditable || selection.selectedDevice == nil)
    }
    .buttonStyle(.link)
    .font(.caption)
  }

  private var footer: some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack {
        Button("Open logs") { model.onLogs?() }
        Spacer()
        Button("Quit Mirri") { NSApplication.shared.terminate(nil) }
      }
    }
    .buttonStyle(.link)
    .font(.caption)
  }
}

@MainActor func makeConnectionPanel(_ model: ConnectionPanelModel) -> NSViewController {
  NSHostingController(rootView: ConnectionPanel(model: model))
}
