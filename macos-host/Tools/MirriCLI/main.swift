import Darwin
import Foundation

/// `mirri`: terminal control for the running Mirri host app over its local
/// control socket. It owns no session state; the app remains the only owner.

let usage = """
  Usage: mirri <command> [options]

    status                      Show connection state, modes and metrics
    devices                     List attached tablets (number and model)
    addresses                   List Mac IPv4 addresses available for streaming
    connect [options]           Connect and wait until streaming
        --address <if|ipv4>       Mac interface or address (default: the only one)
        --device <n|model>        Tablet number or model (default: the only one)
        --media rtc|tcp           Video path: WebRTC over UDP (default) or TLS/TCP
        --timeout <seconds>       Wait limit (default: 45)
        --no-wait                 Return as soon as the attempt starts
    disconnect [--no-wait]      Stop the session
    reconnect                   Restart the current session
    set [options]               Settings for the next connection
        --codec automatic|avc|hevc
        --size native|retina
        --avc-bitrate 20...80     Mbit/s (the ceiling for WebRTC video)
        --adaptive-bitrate on|off WebRTC only: adapt below the ceiling (default on)
        --auto-connect on|off     Start when a paired tablet opens Mirri (default on)
        --hevc-bitrate 25...80    Mbit/s
        --grace 1...60            Reconnect grace in seconds
        --zoom commandKeys|disabled
        --pencil missionControl|contextClick|disabled
    install <apk> [--device n]  Install or upgrade the tablet client
    paired                      List tablets paired for cable-free use
    unpair                      Forget every paired tablet
    watch [--interval seconds]  Print state and metrics until interrupted
    logs                        Print the host log folder
    show [settings]             Open the menu-bar panel, optionally on its Settings page
    launch                      Start the host app if it is not running
    quit                        Stop any session and quit the host app

  Global: --json prints the raw reply.  MIRRI_HOST_APP overrides the app path
  (default ~/Applications/Mirri Development.app).
  """

func fail(_ message: String, code: Int32 = 1) -> Never {
  FileHandle.standardError.write(Data((message + "\n").utf8))
  exit(code)
}

/// Keep in sync with `App/ControlServer.swift`.
let socketPath = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
  .appendingPathComponent("Mirri", isDirectory: true)
  .appendingPathComponent("control.sock").path

func open() -> Int32? {
  let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
  guard descriptor >= 0 else { return nil }
  var address = sockaddr_un()
  address.sun_family = sa_family_t(AF_UNIX)
  let bytes = Array(socketPath.utf8)
  guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
  withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
  let connected = withUnsafePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
    }
  }
  guard connected else {
    close(descriptor)
    return nil
  }
  return descriptor
}

func isRunning() -> Bool {
  guard let descriptor = open() else { return false }
  close(descriptor)
  return true
}

func launch() {
  if isRunning() { return }
  let app =
    ProcessInfo.processInfo.environment["MIRRI_HOST_APP"]
    ?? NSHomeDirectory() + "/Applications/Mirri Development.app"
  guard FileManager.default.fileExists(atPath: app) else { fail("Mirri app not found at \(app)") }
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
  process.arguments = ["-g", app]
  do { try process.run() } catch { fail("Could not launch \(app)") }
  process.waitUntilExit()
  for _ in 0..<100 {
    if isRunning() { return }
    usleep(100_000)
  }
  fail("Mirri did not start its control endpoint")
}

func send(_ request: [String: Any]) -> [String: Any] {
  guard let descriptor = open() else { fail("Mirri is not running (try: mirri launch)") }
  defer { close(descriptor) }
  var payload = (try? JSONSerialization.data(withJSONObject: request)) ?? Data()
  payload.append(0x0A)
  let sent = payload.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
  guard sent == payload.count else { fail("Could not reach Mirri") }
  var reply = Data()
  var chunk = [UInt8](repeating: 0, count: 8192)
  while true {
    let count = read(descriptor, &chunk, chunk.count)
    if count <= 0 { break }
    reply.append(contentsOf: chunk[..<count])
  }
  guard let fields = try? JSONSerialization.jsonObject(with: reply) as? [String: Any] else {
    fail("Mirri returned an invalid reply")
  }
  return fields
}

func checked(_ reply: [String: Any]) -> [String: Any] {
  if reply["ok"] as? Bool != true { fail(reply["error"] as? String ?? "Mirri refused the command") }
  return reply
}

var arguments = Array(CommandLine.arguments.dropFirst())
let json = arguments.contains("--json")
arguments.removeAll { $0 == "--json" }
let noWait = arguments.contains("--no-wait")
arguments.removeAll { $0 == "--no-wait" }
guard let command = arguments.first else { fail(usage, code: 2) }
arguments.removeFirst()

/// Remaining arguments as `--name value` pairs plus positionals.
var options: [String: String] = [:]
var positionals: [String] = []
var index = 0
while index < arguments.count {
  let argument = arguments[index]
  if argument.hasPrefix("--") {
    guard index + 1 < arguments.count else { fail("\(argument) needs a value", code: 2) }
    options[String(argument.dropFirst(2))] = arguments[index + 1]
    index += 2
  } else {
    positionals.append(argument)
    index += 1
  }
}
@MainActor func allow(_ names: String...) {
  if let unknown = options.keys.first(where: { !names.contains($0) }) {
    fail("Unknown option --\(unknown)\n\n\(usage)", code: 2)
  }
}
@MainActor func number(_ name: String) -> Int? {
  guard let text = options[name] else { return nil }
  guard let value = Int(text) else { fail("--\(name) needs a whole number", code: 2) }
  return value
}

@MainActor func emit(_ reply: [String: Any], _ text: () -> String) {
  if json {
    let data = try? JSONSerialization.data(
      withJSONObject: reply, options: [.prettyPrinted, .sortedKeys])
    print(String(data: data ?? Data(), encoding: .utf8) ?? "{}")
  } else {
    print(text())
  }
}

func summary(_ status: [String: Any]) -> String {
  func text(_ key: String) -> String { status[key] as? String ?? "—" }
  var lines = ["\(text("headline")) (\(text("state")))", "  \(text("message"))"]
  if let notice = status["notice"] as? String { lines.append("  notice:  \(notice)") }
  lines += [
    "  tablet:  \(text("device"))", "  mac:     \(text("virtualMode"))",
    "  client:  \(text("clientMode"))", "  video:   \(text("video"))",
    "  metrics: \(text("metrics"))",
  ]
  return lines.joined(separator: "\n")
}

/// Poll the app's own state; the app, not this tool, decides success or failure.
func wait(timeout: Int, until done: ([String: Any]) -> Bool?) -> [String: Any] {
  let deadline = Date().addingTimeInterval(TimeInterval(timeout))
  while true {
    let status = checked(send(["command": "status"]))
    if let succeeded = done(status) {
      if succeeded { return status }
      fail(
        "\(status["headline"] as? String ?? "Failed"): "
          + (status["notice"] as? String ?? status["message"] as? String ?? ""))
    }
    if Date() > deadline {
      fail("Timed out: \(status["headline"] as? String ?? "") \(status["message"] as? String ?? "")")
    }
    usleep(200_000)
  }
}

switch command {
case "help", "--help", "-h":
  print(usage)
case "launch":
  allow()
  launch()
  emit(checked(send(["command": "status"])), { "Mirri is running" })
case "status":
  allow()
  let status = checked(send(["command": "status"]))
  emit(status) { summary(status) }
case "devices":
  allow()
  let status = checked(send(["command": "refresh"]))
  emit(status) {
    let devices = status["devices"] as? [String] ?? []
    let selected = status["selectedDevice"] as? Int
    return devices.isEmpty
      ? "No authorized USB tablet"
      : devices.enumerated().map { "\($0 + 1 == selected ? "*" : " ") \($0 + 1)  \($1)" }
        .joined(separator: "\n")
  }
case "addresses":
  allow()
  let status = checked(send(["command": "refresh"]))
  emit(status) {
    let addresses = status["addresses"] as? [[String: String]] ?? []
    let selected = status["selectedAddress"] as? String
    return addresses.isEmpty
      ? "No active Mac IPv4 address"
      : addresses.map {
        "\($0["address"] == selected ? "*" : " ") \($0["interface"] ?? "")  \($0["address"] ?? "")"
      }.joined(separator: "\n")
  }
case "connect":
  allow("address", "device", "media", "timeout")
  launch()
  var request: [String: Any] = ["command": "connect", "media": options["media"] ?? "rtc"]
  if let address = options["address"] { request["address"] = address }
  if let device = options["device"] { request["device"] = Int(device) ?? device }
  var status = checked(send(request))
  if !noWait {
    status = wait(timeout: number("timeout") ?? 45) { status in
      if status["state"] as? String == "streaming" { return true }
      if status["starting"] as? Bool == true { return nil }
      if status["state"] as? String == "failed" || status["notice"] is String { return false }
      return status["state"] as? String == "idle" ? false : nil
    }
  }
  emit(status) { summary(status) }
case "disconnect":
  allow("timeout")
  guard isRunning() else {
    print("Mirri is not running")
    exit(0)
  }
  var status = checked(send(["command": "disconnect"]))
  if !noWait {
    status = wait(timeout: number("timeout") ?? 30) { $0["busy"] as? Bool == false ? true : nil }
  }
  emit(status) { summary(status) }
case "reconnect":
  allow()
  let status = checked(send(["command": "reconnect"]))
  emit(status) { summary(status) }
case "set":
  allow(
    "codec", "size", "avc-bitrate", "hevc-bitrate", "grace", "zoom", "pencil", "adaptive-bitrate",
    "auto-connect")
  var request: [String: Any] = ["command": "set"]
  for name in ["codec", "size", "zoom", "pencil"] where options[name] != nil {
    request[name] = options[name]
  }
  for (name, key) in [("avc-bitrate", "avcBitrate"), ("hevc-bitrate", "hevcBitrate"), ("grace", "grace")] {
    if let value = number(name) { request[key] = value }
  }
  for (name, key) in [("adaptive-bitrate", "adaptiveBitrate"), ("auto-connect", "autoConnect")] {
    guard let value = options[name] else { continue }
    guard value == "on" || value == "off" else { fail("--\(name) needs on or off", code: 2) }
    request[key] = value == "on"
  }
  let status = checked(send(request))
  emit(status) {
    (status["settings"] as? [String: Any] ?? [:]).sorted { $0.key < $1.key }
      .map { "\($0.key): \($0.value)" }.joined(separator: "\n")
  }
case "install":
  allow("device")
  guard positionals.count == 1 else { fail("install needs one APK path", code: 2) }
  launch()
  var request: [String: Any] = [
    "command": "install",
    "apk": URL(fileURLWithPath: positionals[0]).standardizedFileURL.path,
  ]
  if let device = options["device"] { request["device"] = Int(device) ?? device }
  emit(checked(send(request)), { "Installed" })
case "paired", "unpair":
  allow()
  let reply = checked(send(["command": command]))
  emit(reply) {
    let labels = reply["paired"] as? [String] ?? []
    return labels.isEmpty ? "No paired tablets" : labels.joined(separator: "\n")
  }
case "watch":
  allow("interval")
  let interval = max(1, number("interval") ?? 1)
  setvbuf(stdout, nil, _IOLBF, 0)
  while true {
    let status = checked(send(["command": "status"]))
    emit(status) {
      "\(status["state"] as? String ?? "?") | \(status["video"] as? String ?? "") | "
        + (status["metrics"] as? String ?? "")
    }
    sleep(UInt32(interval))
  }
case "logs":
  allow()
  let status = checked(send(["command": "status"]))
  emit(status) { status["logFolder"] as? String ?? "" }
case "show":
  allow()
  emit(
    checked(send(["command": "show", "settings": positionals.first == "settings"])),
    { "Panel opened" })
case "quit":
  allow()
  guard isRunning() else {
    print("Mirri is not running")
    exit(0)
  }
  emit(checked(send(["command": "quit"])), { "Quitting" })
default:
  fail("Unknown command \(command)\n\n\(usage)", code: 2)
}
