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
  public let address: String
  public let pin: Data
  public init(address: String, pin: Data) {
    self.address = address
    self.pin = pin
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
  public func reverseList(on device: ADBDevice) async throws -> String {
    try await on(device, ["reverse", "--list"])
  }
  public func addReverse(remotePort: UInt16, localPort: UInt16, device: ADBDevice) async throws {
    _ = try await on(device, ["reverse", "tcp:\(remotePort)", "tcp:\(localPort)"])
  }
  public func removeReverse(remotePort: UInt16, device: ADBDevice) async -> Bool {
    (try? await on(device, ["reverse", "--remove", "tcp:\(remotePort)"])) != nil
  }
  public func launchClient(
    device: ADBDevice, token: Data, epoch: UInt32, network: NetworkLaunch? = nil
  ) async throws {
    let hex = token.map { String(format: "%02x", $0) }.joined()
    let mode = network == nil ? "usb" : "network"
    let networkExtras: [String] =
      network.map { selected in
        [
          "--es", "mirri_host", selected.address,
          "--es", "mirri_pin", selected.pin.map { String(format: "%02x", $0) }.joined(),
        ]
      } ?? []
    _ = try await on(
      device,
      [
        // Force-stop only Mirri before each fresh host epoch (including grace
        // reconnect). An old foreground activity can retain its completed
        // controller and miss a new intent; -S starts a new process/activity.
        // SessionCoordinator first closes old sockets/capture. The USB route
        // separately retains its proved-owned reverse mappings; the network
        // route never creates them. No other package or app data is reset.
        "shell", "am", "start", "-S", "-n",
        "\(Self.package)/.MainActivity", "--es", "mirri_token", hex,
        "--ei", "mirri_control_port", "5561",
        "--ei", "mirri_video_port", "5560",
        "--ei", "mirri_protocol_major", "1",
        "--ei", "mirri_epoch", String(epoch), "--es", "mirri_mode", mode,
      ] + networkExtras)
  }
  public func forceStopClient(device: ADBDevice) async {
    _ = try? await on(device, ["shell", "am", "force-stop", Self.package])
  }
}

/// Each reverse mapping is removed only when the exact mapping was absent before creation.
public actor AdbReverseManager {
  private let adb: ADBClient
  private var owned: [UInt16] = []
  // ADB may create a mapping then time out before reporting success. Record
  // both the absent precondition and the in-flight operation before awaiting;
  // only the same live process/device may reconcile this pending lease.
  private var pending: [UInt16] = []
  private var adding: Task<Void, Error>?
  private var removing = false
  // Process-local identity only: never persist or log an ADB serial to guess
  // ownership after a crash or another process replaces a mapping.
  private var ownerSerial: String?
  public init(adb: ADBClient) { self.adb = adb }
  private static func mapping(_ port: UInt16, in list: String) -> String? {
    list.split(separator: "\n").compactMap { line -> String? in
      let columns = line.split(whereSeparator: \.isWhitespace).map(String.init)
      guard columns.count == 3, columns[1] == "tcp:\(port)" else { return nil }
      return columns[2]
    }.first
  }
  public func install(on device: ADBDevice) async throws {
    // A live reconnect must not tear down an already owned mapping while an
    // existing client is still exiting. Recreate only ports actually lost by ADB.
    guard !removing, adding == nil,
      (owned.isEmpty && pending.isEmpty) || ownerSerial == device.serial
    else { throw HostFailure.reverseConflict }
    let list = try await adb.reverseList(on: device)
    for port: UInt16 in [5560, 5561] {
      let mapping = Self.mapping(port, in: list)
      if pending.contains(port) {
        if mapping == "tcp:\(port)" {
          pending.removeAll { $0 == port }
          if !owned.contains(port) { owned.append(port) }
        } else if mapping == nil {
          pending.removeAll { $0 == port }
        } else {
          throw HostFailure.reverseConflict
        }
      }
      if owned.contains(port), mapping == "tcp:\(port)" { continue }
      guard mapping == nil else { throw HostFailure.reverseConflict }
      // Mapping vanished; the same live owner may install it again.
      if owned.contains(port) {
        owned.removeAll { $0 == port }
      }
      ownerSerial = device.serial
      pending.append(port)
      let operation = Task {
        try await adb.addReverse(remotePort: port, localPort: port, device: device)
      }
      adding = operation
      do {
        try await operation.value
        if pending.contains(port) {
          pending.removeAll { $0 == port }
          owned.append(port)
        }
        adding = nil
        if removing { throw HostFailure.invalidState }
      } catch {
        adding = nil
        // Keep the pending lease for release/retry. A failed command can have
        // succeeded on-device; never discard the absent-before proof merely
        // because the ADB response was lost. Do not delete a different target.
        throw error
      }
    }
  }
  public func remove(on device: ADBDevice) async {
    guard ownerSerial == device.serial else { return }
    guard !removing else { return }
    removing = true
    defer { removing = false }
    _ = await adding?.result  // A Stop racing the install must wait for the side effect.
    let ports = Set(owned + pending)
    guard let list = try? await adb.reverseList(on: device) else { return }
    var unresolved: [UInt16] = []
    for port in ports {
      let mapping = Self.mapping(port, in: list)
      if mapping == "tcp:\(port)" {
        let removed = await adb.removeReverse(remotePort: port, device: device)
        if !removed { unresolved.append(port) }
      }
      // Missing or reassigned mappings are not ours to remove.
    }
    owned = unresolved
    pending.removeAll { ports.contains($0) }
    if owned.isEmpty && pending.isEmpty { ownerSerial = nil }
  }
  /// Only the same live process may retry its own cleanup on USB rediscovery.
  public func retryOwnedCleanup(on device: ADBDevice) async {
    if ownerSerial == device.serial && (!owned.isEmpty || !pending.isEmpty) {
      await remove(on: device)
    }
  }
  /// Caller must obtain explicit owner confirmation. Never remove other ports
  /// or ports pointing somewhere other than Mirri's fixed localhost listeners.
  public func explicitCleanup(on device: ADBDevice) async throws {
    let list = try await adb.reverseList(on: device)
    for port: UInt16 in [5560, 5561] where Self.mapping(port, in: list) == "tcp:\(port)" {
      guard await adb.removeReverse(remotePort: port, device: device) else {
        throw HostFailure.adb
      }
    }
    if ownerSerial == device.serial {
      owned.removeAll()
      pending.removeAll()
      ownerSerial = nil
    }
  }
}
