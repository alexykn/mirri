import Foundation

public struct ADBDevice: Sendable, Equatable {
  public let serial: String
  public let model: String
  public init(serial: String, model: String) {
    self.serial = serial
    self.model = model
  }
}

public struct InstalledClient: Sendable {
  public let versionCode: Int
  public let versionName: String
}

public struct NetworkLaunch: Sendable {
  public enum Media: Sendable { case comparison, rtc }
  public let address: String
  public let pin: Data
  public let media: Media
  public let sessionId: Data?
  public init(address: String, pin: Data, media: Media = .comparison, sessionId: Data? = nil) {
    self.address = address
    self.pin = pin
    self.media = media
    self.sessionId = sessionId
  }
}

private final class ProcessOutcome: @unchecked Sendable {
  private let lock = NSLock()
  private var finished = false
  private var output: Data?
  private var exitStatus: Int32?
  private let continuation: CheckedContinuation<String, Error>
  init(_ continuation: CheckedContinuation<String, Error>) { self.continuation = continuation }
  @discardableResult func finish(_ result: Result<String, Error>) -> Bool {
    lock.lock()
    guard !finished else {
      lock.unlock()
      return false
    }
    finished = true
    lock.unlock()
    continuation.resume(with: result)
    return true
  }
  // A pipe can reach EOF before Process has reported its exit, or vice
  // versa. Neither event by itself establishes a completed command.
  func stdoutEnded(_ data: Data) {
    lock.lock()
    output = data
    let status = exitStatus
    lock.unlock()
    if let status { resolve(data, status: status) }
  }
  func processExited(_ status: Int32) {
    lock.lock()
    exitStatus = status
    let data = output
    lock.unlock()
    if let data { resolve(data, status: status) }
  }
  private func resolve(_ data: Data, status: Int32) {
    guard let text = String(bytes: data, encoding: .utf8) else {
      finish(.failure(HostFailure.adb))
      return
    }
    finish(status == 0 ? .success(text) : .failure(HostFailure.adb))
  }
}

public actor ADBClient {
  public static let package = "dev.mirri.client"
  private let executable: URL
  private let commandTimeout: TimeInterval
  public init(
    executable: URL = URL(fileURLWithPath: "/opt/homebrew/bin/adb"),
    commandTimeout: TimeInterval = 8
  ) {
    self.executable = executable
    self.commandTimeout = commandTimeout
  }
  private func run(_ args: [String]) async throws -> String {
    let executable = self.executable
    let timeout = commandTimeout
    return try await withCheckedThrowingContinuation { continuation in
      let process = Process()
      process.executableURL = executable
      process.arguments = args
      let output = Pipe()
      process.standardOutput = output
      process.standardError = output
      let outcome = ProcessOutcome(continuation)
      process.terminationHandler = { ended in outcome.processExited(ended.terminationStatus) }
      do {
        try process.run()
      } catch {
        outcome.finish(.failure(HostFailure.adb))
        return
      }
      DispatchQueue.global(qos: .utility).async {
        var data = Data()
        while true {
          let chunk = output.fileHandleForReading.readData(ofLength: 4096)
          if chunk.isEmpty { break }
          if data.count < 64 * 1024 { data.append(chunk.prefix(64 * 1024 - data.count)) }
        }
        // Foundation waitUntilExit can stall after a concurrently terminated
        // subprocess is gone. Join pipe EOF with terminationHandler instead.
        outcome.stdoutEnded(data)
      }
      DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
        // A successful/failed process completion that already claimed the
        // outcome wins. Otherwise claim the timeout BEFORE terminate can wake
        // the reader with a spurious process-exit (.adb) result.
        if outcome.finish(.failure(HostFailure.timeout)), process.isRunning {
          process.terminate()
        }
      }
    }
  }
  private func on(_ device: ADBDevice, _ arguments: [String]) async throws -> String {
    try await run(["-s", device.serial] + arguments)
  }
  public func listDevices() async throws -> [ADBDevice] {
    let text = try await run(["devices", "-l"])
    return Self.parseDevices(text)
  }
  public nonisolated static func parseDevices(_ text: String) -> [ADBDevice] {
    return text.split(separator: "\n").dropFirst().compactMap { line in
      let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
      guard parts.count >= 2, parts[1] == "device", !parts[0].isEmpty,
        parts.contains(where: { $0.hasPrefix("usb:") })
      else { return nil }
      return ADBDevice(
        serial: parts[0],
        model: parts.first { $0.hasPrefix("model:") }
          .map { String($0.dropFirst(6)) } ?? "USB device")
    }
  }
  public func packageVersion(on device: ADBDevice) async throws -> InstalledClient? {
    let text = try await on(device, ["shell", "dumpsys", "package", Self.package])
    guard let code = text.range(of: #"versionCode=(\d+)"#, options: .regularExpression),
      let value = Int(text[code].dropFirst("versionCode=".count))
    else { return nil }
    let name =
      text.range(of: #"versionName=[^\s]+"#, options: .regularExpression)
      .map { String(text[$0].dropFirst("versionName=".count)) } ?? "unknown"
    return InstalledClient(versionCode: value, versionName: name)
  }
  public func installClient(apk: URL, on device: ADBDevice) async throws {
    guard apk.isFileURL, apk.pathExtension == "apk" else { throw HostFailure.adb }
    _ = try await on(device, ["install", "-r", apk.path])
  }
  public func launchClient(
    device: ADBDevice, token: Data, epoch: UInt32, network: NetworkLaunch
  ) async throws {
    if network.media == .rtc, network.sessionId?.count != 16 {
      throw HostFailure.unauthorized
    }
    let hex = token.map { String(format: "%02x", $0) }.joined()
    let networkExtras: [String] =
      [
        "--es", "mirri_host", network.address,
        "--es", "mirri_pin", network.pin.map { String(format: "%02x", $0) }.joined(),
      ] + (network.media == .rtc ? [
        "--es", "mirri_media", "rtc", "--es", "mirri_session_id",
        network.sessionId!.map { String(format: "%02x", $0) }.joined(),
      ] : [])
    _ = try await on(
      device,
      [
        // Force-stop only Mirri before each fresh host epoch (including grace
        // reconnect). An old foreground activity can retain its completed
        // controller and miss a new intent; -S starts a new process/activity.
        // SessionCoordinator first closes old sockets/capture. No other
        // package or app data is reset.
        "shell", "am", "start", "-S", "-n",
        "\(Self.package)/.MainActivity", "--es", "mirri_token", hex,
        "--ei", "mirri_control_port", "5561",
        "--ei", "mirri_video_port", "5560",
        "--ei", "mirri_protocol_major", "1",
        "--ei", "mirri_epoch", String(epoch), "--es", "mirri_mode", "network",
      ] + networkExtras)
  }
  public func forceStopClient(device: ADBDevice) async {
    _ = try? await on(device, ["shell", "am", "force-stop", Self.package])
  }
}
