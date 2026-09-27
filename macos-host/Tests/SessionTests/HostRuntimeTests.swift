import CoreGraphics
import CoreMedia
import Foundation
import VideoToolbox
import XCTest

@testable import MirriHostCore

private actor OneShotSignal {
  private var signalled = false
  private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]

  func wait(timeout: Duration? = nil) async -> Bool {
    if signalled { return true }
    let id = UUID()
    return await withCheckedContinuation { continuation in
      waiters[id] = continuation
      if let timeout {
        Task {
          try? await Task.sleep(for: timeout)
          self.expire(id)
        }
      }
    }
  }

  func signal() {
    guard !signalled else { return }
    signalled = true
    let pending = Array(waiters.values)
    waiters.removeAll()
    for waiter in pending { waiter.resume(returning: true) }
  }

  private func expire(_ id: UUID) {
    waiters.removeValue(forKey: id)?.resume(returning: false)
  }
}

private actor PausedLifecycleStatus {
  private let message: String
  private let entered = OneShotSignal()
  private let release = OneShotSignal()

  init(message: String) { self.message = message }

  func handle(_ snapshot: HostSnapshot) async {
    guard snapshot.state == .stopping, snapshot.message == message else { return }
    await entered.signal()
    _ = await release.wait()
  }

  func waitUntilEntered(timeout: Duration) async -> Bool {
    await entered.wait(timeout: timeout)
  }

  func open() async { await release.signal() }
}

final class HostRuntimeTests: XCTestCase {
  private var fixtures: URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("protocol/fixtures")
  }
  private func hello() throws -> WireMessage {
    try XCTUnwrap(
      WireCodec.decode(Data(contentsOf: fixtures.appendingPathComponent("01-client-hello-v1.bin"))))
  }
  func testNegotiationRequiresExactHardwareAndClientCapabilities() throws {
    let original = try hello()
    guard case .hello(let greeting) = try ClientEvent.decode(original) else {
      return XCTFail("fixture is not ClientHello")
    }
    let avc = try SessionNegotiator.negotiate(
      greeting, preferences: HostPreferences(),
      hardwareProbe: { $0 == .avc })
    XCTAssertEqual(avc.codec, .avc)
    XCTAssertEqual(avc.bitrate, 40_000_000)
    XCTAssertEqual(
      HostCommand.configuration(avc).wire(sessionId: Data(repeating: 0, count: 16), epoch: 1)
        .fields[5], .object([.integer(2456), .integer(1600)]))
    XCTAssertThrowsError(
      try SessionNegotiator.negotiate(
        greeting,
        preferences: HostPreferences(), hardwareProbe: { _ in false }))
    var fields = original.fields
    fields[6] = .items([])
    let incompatible = WireMessage(type: 1, sequence: 0, timestamp: 0, fields: fields)
    guard case .hello(let incorrectGreeting) = try ClientEvent.decode(incompatible) else {
      return XCTFail("fixture is not ClientHello")
    }
    XCTAssertThrowsError(
      try SessionNegotiator.negotiate(
        incorrectGreeting,
        preferences: HostPreferences(), hardwareProbe: { _ in true }))
  }
  func testOptionalDecoderLowLatencyDoesNotRejectExactHardware() throws {
    let original = try hello()
    guard case .hello(let greeting) = try ClientEvent.decode(original) else {
      return XCTFail("fixture is not ClientHello")
    }
    let software = CodecOffer(
      codec: .avc, profiles: [(1, 51)], exact: true, lowLatency: true, hardware: false)
    let inexact = CodecOffer(
      codec: .avc, profiles: [(1, 51)], exact: false, lowLatency: true, hardware: true)
    let exact = CodecOffer(
      codec: .avc, profiles: [(1, 51)], exact: true, lowLatency: false, hardware: true)
    XCTAssertFalse(software.supports(level: 51))
    XCTAssertFalse(inexact.supports(level: 51))
    XCTAssertTrue(exact.supports(level: 51))
    var fields = original.fields
    guard case .items(let offers) = fields[7], case .object(let first) = offers[0] else {
      return XCTFail("fixture codec offer missing")
    }
    var withoutOptionalFeature = first
    withoutOptionalFeature[3] = .integer(0)
    fields[7] = .items([.object(withoutOptionalFeature)])
    let message = WireMessage(type: original.type, sequence: 0, timestamp: 0, fields: fields)
    guard case .hello(let noLowLatency) = try ClientEvent.decode(message) else {
      return XCTFail("fixture codec offer not decoded")
    }
    XCTAssertEqual(
      try SessionNegotiator.negotiate(
        noLowLatency, preferences: HostPreferences(), hardwareProbe: { $0 == .avc }
      ).codec,
      .avc)
  }
  func testRuntimeBoundaryInputAndConfigAgreeWithGoldenBytes() throws {
    let input = try XCTUnwrap(
      WireCodec.decode(
        Data(
          contentsOf:
            fixtures.appendingPathComponent("09-input-batch-v1.bin"))))
    guard case .input(.pointers(let sequence, let samples)) = try ClientEvent.decode(input) else {
      return XCTFail("fixture is not a typed pointer batch")
    }
    XCTAssertEqual(sequence, 0)
    XCTAssertEqual(samples.count, 1)
    XCTAssertEqual(samples[0].tool, .finger)
    XCTAssertEqual(samples[0].phase, .down)
    guard case .hello(let greeting) = try ClientEvent.decode(hello()) else {
      return XCTFail("fixture is not ClientHello")
    }
    let config = try SessionNegotiator.negotiate(
      greeting, preferences: HostPreferences(), hardwareProbe: { $0 == .avc })
    let packet = try WireCodec.encode(
      HostCommand.configuration(config).wire(sessionId: Data((0..<16).map(UInt8.init)), epoch: 1))
    let golden = try Data(contentsOf: fixtures.appendingPathComponent("02-session-config-v1.bin"))
    XCTAssertEqual(packet.dropFirst(32), golden.dropFirst(32))
  }
  func testAuthorizationComparesExactBytesAndRejectsWrongLength() {
    let token = Data(repeating: 0x64, count: 32)
    XCTAssertTrue(Authenticator.equals(token, token))
    var different = token
    different[31] ^= 1
    XCTAssertFalse(Authenticator.equals(token, different))
    XCTAssertFalse(Authenticator.equals(token, Data(repeating: 0x64, count: 31)))
  }
  func testControlOrderBindsSessionIdAfterAuthenticatedHello() throws {
    var order = WireOrder(receivingFrom: .client, on: .control, epoch: 1)
    try order.accept(hello())
    let id = Data((0..<16).map(UInt8.init))
    try order.bindSession(id)
    let ready = try XCTUnwrap(
      WireCodec.decode(
        Data(
          contentsOf:
            fixtures.appendingPathComponent("03-client-ready-v1.bin"))))
    var fields = ready.fields
    fields[0] = .bytes(Data(repeating: 0x55, count: 16))
    XCTAssertThrowsError(
      try order.accept(
        WireMessage(
          type: ready.type, sequence: 1, timestamp: 0, fields: fields)))
    try order.accept(
      WireMessage(
        type: ready.type, sequence: 1, timestamp: 0,
        fields: ready.fields))
  }
  func testOldEpochRetryIsDistinctFromFutureEpochRejection() {
    XCTAssertEqual(ClientEpochDisposition.compare(received: 1, expected: 2), .stale)
    XCTAssertEqual(ClientEpochDisposition.compare(received: 2, expected: 2), .current)
    XCTAssertEqual(ClientEpochDisposition.compare(received: 3, expected: 2), .future)
    XCTAssertEqual(ClientEpochDisposition.compare(received: 0, expected: 1), .stale)
  }
  @MainActor func testCoordinatorClaimsStopAndRejectsStaleTransportCallback() async {
    var snapshots: [HostState] = []
    let coordinator = SessionCoordinator(
      permissions: { false }, status: { snapshots.append($0.state) })
    await coordinator.start(device: ADBDevice(serial: "synthetic", model: "synthetic"))
    let failed = await coordinator.current().state
    XCTAssertEqual(failed, .failed)
    async let first: Void = coordinator.stop()
    async let second: Void = coordinator.stop()
    _ = await (first, second)
    await coordinator.transportClosed(id: 1, channelEpoch: 1)
    let stopped = await coordinator.current().state
    XCTAssertEqual(stopped, .idle)
    XCTAssertEqual(snapshots.filter { $0 == .stopping }.count, 2)
    // One stopping transition for terminal failure and one for concurrent stop.
    XCTAssertFalse(snapshots.contains(.waitingForReconnect))
  }
  func testStopWaitsForTerminalCleanupAlreadyInProgress() async {
    let gate = PausedLifecycleStatus(message: HostFailure.permission.localizedDescription)
    let coordinator = SessionCoordinator(
      permissions: { false },
      status: { await gate.handle($0) })
    let start = Task {
      await coordinator.start(device: ADBDevice(serial: "synthetic", model: "synthetic"))
    }
    let entered = await gate.waitUntilEntered(timeout: .seconds(2))
    guard entered else {
      await gate.open()
      await start.value
      return XCTFail("terminal cleanup did not reach its stopping state")
    }
    let stopReturned = OneShotSignal()
    let stop = Task {
      await coordinator.stop()
      await stopReturned.signal()
    }
    let returnedBeforeCleanup = await stopReturned.wait(timeout: .milliseconds(150))
    await gate.open()
    await start.value
    await stop.value
    XCTAssertFalse(returnedBeforeCleanup, "stop returned before terminal cleanup completed")
    let state = await coordinator.current().state
    XCTAssertEqual(state, .failed)
  }
  func testConcurrentStopWaitsForExistingStopCleanup() async {
    let gate = PausedLifecycleStatus(
      message: "Stopping stream, releasing input and owned resources")
    let coordinator = SessionCoordinator(
      permissions: { false }, status: { await gate.handle($0) })
    await coordinator.start(device: ADBDevice(serial: "synthetic", model: "synthetic"))
    let firstStop = Task { await coordinator.stop() }
    let entered = await gate.waitUntilEntered(timeout: .seconds(2))
    guard entered else {
      await gate.open()
      await firstStop.value
      return XCTFail("stop cleanup did not reach its stopping state")
    }
    let secondStopReturned = OneShotSignal()
    let secondStop = Task {
      await coordinator.stop()
      await secondStopReturned.signal()
    }
    // Bounded observation: actor scheduling may delay the second request before this check.
    let returnedBeforeCleanup = await secondStopReturned.wait(timeout: .milliseconds(150))
    await gate.open()
    await firstStop.value
    await secondStop.value
    XCTAssertFalse(returnedBeforeCleanup, "second stop returned before cleanup completed")
    let state = await coordinator.current().state
    XCTAssertEqual(state, .idle)
  }
  func testOnlyAuthorizedPhysicalUSBDevicesAreDiscovered() {
    let output =
      "List of devices attached\nUSB01 device usb:1-3 model:TXZ-W09\n"
      + "192.168.1.3:5555 device model:TXZ-W09\n"
      + "USB02 unauthorized usb:2-1 model:TXZ-W09\n"
    XCTAssertEqual(ADBClient.parseDevices(output), [ADBDevice(serial: "USB01", model: "TXZ-W09")])
  }
  func testClientLaunchResetsOnlyItsOwnPackageBeforeDeliveringNewIntent() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let calls = folder.appendingPathComponent("calls")
    let executable = folder.appendingPathComponent("fake-adb")
    try Data(
      "#!/bin/sh\nprintf '%s\\n' \"$@\" >> '\(calls.path)'\nprintf 'END\\n' >> '\(calls.path)'\n"
        .utf8
    )
    .write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let adb = ADBClient(executable: executable)
    try await adb.launchClient(
      device: ADBDevice(serial: "synthetic", model: "synthetic"),
      token: Data(repeating: 0x12, count: 32), epoch: 1)
    try await adb.launchClient(
      device: ADBDevice(serial: "synthetic", model: "synthetic"),
      token: Data(repeating: 0x34, count: 32), epoch: 2)
    let invocations = try String(contentsOf: calls, encoding: .utf8)
      .components(separatedBy: "END\n").dropLast()
    XCTAssertEqual(invocations.count, 2)
    for (index, invocation) in invocations.enumerated() {
      let arguments = invocation.split(separator: "\n")
      XCTAssertEqual(
        arguments.prefix(8).map(String.init),
        [
          "-s", "synthetic", "shell", "am", "start", "-S", "-n", "dev.mirri.client/.MainActivity",
        ])
      XCTAssertEqual(arguments.filter { $0 == "-S" }.count, 1)
      XCTAssertEqual(arguments.last, Substring(String(index + 1)))
      XCTAssertFalse(invocation.contains("force-stop"))
    }
  }
  func testReverseOwnerNeverCleansAnotherDeviceAndRetriesSameDevice() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let calls = folder.appendingPathComponent("calls")
    let marker = folder.appendingPathComponent("installed")
    let executable = folder.appendingPathComponent("fake-adb")
    let script = """
      #!/bin/sh
      echo "$@" >> "\(calls.path)"
      if [ "$3" = reverse ] && [ "$4" = --list ]; then
        if [ -f "\(marker.path)" ]; then
          printf 'A tcp:5560 tcp:5560\\nA tcp:5561 tcp:5561\\n'
        fi
      fi
      if [ "$3" = reverse ] && [ "$4" = tcp:5561 ]; then touch "\(marker.path)"; fi
      exit 0
      """
    try Data(script.utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let owner = AdbReverseManager(adb: ADBClient(executable: executable))
    let first = ADBDevice(serial: "A", model: "synthetic")
    try await owner.install(on: first)
    await owner.remove(on: ADBDevice(serial: "B", model: "synthetic"))
    var logged = try String(contentsOf: calls, encoding: .utf8)
    XCTAssertFalse(logged.contains("--remove"))
    await owner.retryOwnedCleanup(on: first)
    logged = try String(contentsOf: calls, encoding: .utf8)
    XCTAssertEqual(logged.components(separatedBy: "--remove").count - 1, 2)
  }
  func testReverseLeaseSurvivesAddTimeoutAfterSideEffect() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let calls = folder.appendingPathComponent("calls")
    let mapped = folder.appendingPathComponent("mapped")
    let executable = folder.appendingPathComponent("fake-adb")
    let script = """
      #!/bin/sh
      echo "$@" >> "\(calls.path)"
      if [ "$3" = reverse ] && [ "$4" = --list ]; then
        [ ! -f "\(mapped.path)" ] || printf 'A tcp:5560 tcp:5560\\n'
        printf 'A tcp:5562 tcp:6000\\n'
      fi
      if [ "$3" = reverse ] && [ "$4" = tcp:5560 ]; then
        touch "\(mapped.path)"
        exec sleep 5
      fi
      if [ "$3" = reverse ] && [ "$4" = --remove ] && [ "$5" = tcp:5560 ]; then
        rm "\(mapped.path)"
      fi
      exit 0
      """
    try Data(script.utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let owner = AdbReverseManager(adb: ADBClient(executable: executable, commandTimeout: 2))
    let device = ADBDevice(serial: "A", model: "synthetic")
    do {
      try await owner.install(on: device)
      XCTFail("reverse add response should time out after creating the mapping")
    } catch HostFailure.timeout {
      XCTAssertTrue(FileManager.default.fileExists(atPath: mapped.path))
    }
    await owner.remove(on: device)
    XCTAssertFalse(FileManager.default.fileExists(atPath: mapped.path))
    let logged = try String(contentsOf: calls, encoding: .utf8)
    XCTAssertEqual(logged.components(separatedBy: "reverse --remove tcp:5560").count - 1, 1)
    XCTAssertFalse(logged.contains("--remove tcp:5561"))
    XCTAssertFalse(logged.contains("--remove tcp:5562"))
  }
  func testReverseSecondAddFailureReleasesBothSideEffectsOnly() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let calls = folder.appendingPathComponent("calls")
    let first = folder.appendingPathComponent("first")
    let second = folder.appendingPathComponent("second")
    let executable = folder.appendingPathComponent("fake-adb")
    let script = """
      #!/bin/sh
      echo "$@" >> "\(calls.path)"
      if [ "$3" = reverse ] && [ "$4" = --list ]; then
        [ ! -f "\(first.path)" ] || printf 'A tcp:5560 tcp:5560\\n'
        [ ! -f "\(second.path)" ] || printf 'A tcp:5561 tcp:5561\\n'
        printf 'A tcp:5562 tcp:6000\\n'
      fi
      if [ "$3" = reverse ] && [ "$4" = tcp:5560 ]; then touch "\(first.path)"; fi
      if [ "$3" = reverse ] && [ "$4" = tcp:5561 ]; then touch "\(second.path)"; exit 1; fi
      if [ "$3" = reverse ] && [ "$4" = --remove ]; then
        [ "$5" != tcp:5560 ] || rm "\(first.path)"
        [ "$5" != tcp:5561 ] || rm "\(second.path)"
      fi
      exit 0
      """
    try Data(script.utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let owner = AdbReverseManager(adb: ADBClient(executable: executable))
    let device = ADBDevice(serial: "A", model: "synthetic")
    do {
      try await owner.install(on: device)
      XCTFail("second command should fail after its side effect")
    } catch HostFailure.adb {
      XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
      XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
    }
    await owner.remove(on: device)
    XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
    let logged = try String(contentsOf: calls, encoding: .utf8)
    XCTAssertEqual(logged.components(separatedBy: "reverse --remove").count - 1, 2)
    XCTAssertFalse(logged.contains("--remove tcp:5562"))
  }
  func testExplicitReverseCleanupSkipsUnrelatedTarget() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let calls = folder.appendingPathComponent("calls")
    let executable = folder.appendingPathComponent("fake-adb")
    let script = """
      #!/bin/sh
      echo "$@" >> "\(calls.path)"
      if [ "$3" = reverse ] && [ "$4" = --list ]; then
        printf 'A tcp:5560 tcp:6000\\nA tcp:5561 tcp:5561\\n'
      fi
      exit 0
      """
    try Data(script.utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let owner = AdbReverseManager(adb: ADBClient(executable: executable))
    try await owner.explicitCleanup(on: ADBDevice(serial: "A", model: "synthetic"))
    let logged = try String(contentsOf: calls, encoding: .utf8)
    XCTAssertFalse(logged.contains("--remove tcp:5560"))
    XCTAssertTrue(logged.contains("--remove tcp:5561"))
  }
  func testOwnedReverseMappingsReinstalledAfterSyntheticUsbLoss() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let calls = folder.appendingPathComponent("calls")
    let marker = folder.appendingPathComponent("mapped")
    let executable = folder.appendingPathComponent("fake-adb")
    let script = """
      #!/bin/sh
      echo "$@" >> "\(calls.path)"
      if [ "$3" = reverse ] && [ "$4" = --list ] && [ -f "\(marker.path)" ]; then
        printf 'A tcp:5560 tcp:5560\\nA tcp:5561 tcp:5561\\n'
      fi
      if [ "$3" = reverse ] && [ "$4" = tcp:5561 ]; then touch "\(marker.path)"; fi
      exit 0
      """
    try Data(script.utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let owner = AdbReverseManager(adb: ADBClient(executable: executable))
    let device = ADBDevice(serial: "A", model: "synthetic")
    try await owner.install(on: device)
    try FileManager.default.removeItem(at: marker)  // ADB lost mappings on synthetic USB loss.
    try await owner.install(on: device)
    let logged = try String(contentsOf: calls, encoding: .utf8)
    XCTAssertEqual(logged.components(separatedBy: "reverse tcp:5560 tcp:5560").count - 1, 2)
    XCTAssertFalse(logged.contains("--remove"))
  }
  func testReconnectKeepsExistingOwnedReverseMappings() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let calls = folder.appendingPathComponent("calls")
    let marker = folder.appendingPathComponent("mapped")
    let executable = folder.appendingPathComponent("fake-adb")
    let script = """
      #!/bin/sh
      echo "$@" >> "\(calls.path)"
      if [ "$3" = reverse ] && [ "$4" = --list ] && [ -f "\(marker.path)" ]; then
        printf 'A tcp:5560 tcp:5560\\nA tcp:5561 tcp:5561\\n'
      fi
      if [ "$3" = reverse ] && [ "$4" = tcp:5561 ]; then touch "\(marker.path)"; fi
      exit 0
      """
    try Data(script.utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let owner = AdbReverseManager(adb: ADBClient(executable: executable))
    let device = ADBDevice(serial: "A", model: "synthetic")
    try await owner.install(on: device)
    try await owner.install(on: device)
    let logged = try String(contentsOf: calls, encoding: .utf8)
    XCTAssertEqual(logged.components(separatedBy: "reverse tcp:5560 tcp:5560").count - 1, 1)
    XCTAssertEqual(logged.components(separatedBy: "reverse tcp:5561 tcp:5561").count - 1, 1)
    XCTAssertFalse(logged.contains("--remove"))
  }
  func testAdmissionBoundAndReleaseAfterWrite() {
    let admission = VideoAdmission()
    XCTAssertTrue(admission.reserve())
    XCTAssertTrue(admission.reserve())
    XCTAssertTrue(admission.reserve())
    XCTAssertTrue(admission.reserve())
    XCTAssertFalse(admission.reserve())
    XCTAssertEqual(admission.depth, 4)
    admission.release()
    XCTAssertTrue(admission.reserve())
    XCTAssertFalse(admission.reserve())  // still bounded after releasing/re-reserving
    admission.close()
    admission.release()
    admission.release()
    admission.release()
    admission.release()
    XCTAssertEqual(admission.depth, 0)
    XCTAssertFalse(admission.reserve())
  }
  func testActualEncoderPendingCallbackOwnerNormalInlineErrorDropAndInvalidate() throws {
    // Exercise the same owner used by VideoEncoder.encode and its VT callback,
    // without assuming an available hardware encoder or consuming SCK pixels.
    let encoder = VideoEncoder(codec: .avc, bitrate: 40_000_000)
    let owner = encoder.pendingCallbacks
    let normal = EncodeStamp(captureCallbackNs: 11)
    let normalToken = try XCTUnwrap(owner.begin(normal))
    XCTAssertEqual(encoder.pendingVTCallbacks, 1)
    XCTAssertTrue(
      encoder.completeSubmission(result: noErr, flags: VTEncodeInfoFlags(), token: normalToken))
    XCTAssertEqual(encoder.pendingVTCallbacks, 1)  // accepted, output still pending
    XCTAssertTrue(owner.finish(normalToken) === normal)
    XCTAssertNil(owner.finish(normalToken))  // duplicate callback ignored
    XCTAssertEqual(encoder.pendingVTCallbacks, 0)

    let inline = EncodeStamp(captureCallbackNs: 22)
    let inlineToken = try XCTUnwrap(owner.begin(inline))
    XCTAssertTrue(owner.finish(inlineToken) === inline)  // callback before call returns
    XCTAssertTrue(
      encoder.completeSubmission(result: -1, flags: VTEncodeInfoFlags(), token: inlineToken))
    XCTAssertNil(owner.finish(inlineToken))  // late cleanup is idempotent

    let failedToken = try XCTUnwrap(owner.begin(EncodeStamp(captureCallbackNs: 33)))
    XCTAssertFalse(
      encoder.completeSubmission(result: -1, flags: VTEncodeInfoFlags(), token: failedToken))
    XCTAssertNil(owner.finish(failedToken))  // late callback cannot re-decrement
    let droppedToken = try XCTUnwrap(owner.begin(EncodeStamp(captureCallbackNs: 44)))
    let failureProbe = VideoAdmission()
    encoder.onFailure = { _ = failureProbe.reserve() }
    XCTAssertFalse(
      encoder.completeSubmission(result: noErr, flags: .frameDropped, token: droppedToken))
    XCTAssertEqual(failureProbe.depth, 1)
    XCTAssertEqual(encoder.pendingVTCallbacks, 0)

    let inlineDropped = try XCTUnwrap(owner.begin(EncodeStamp(captureCallbackNs: 45)))
    XCTAssertNotNil(owner.finish(inlineDropped))
    XCTAssertTrue(
      encoder.completeSubmission(result: noErr, flags: .frameDropped, token: inlineDropped))
    XCTAssertEqual(failureProbe.depth, 1)  // callback already owns failure handling

    let invalidatedToken = try XCTUnwrap(owner.begin(EncodeStamp(captureCallbackNs: 55)))
    owner.clear()  // invalidate drains callbacks first, then discards any stragglers
    XCTAssertEqual(encoder.pendingVTCallbacks, 0)
    XCTAssertNil(owner.finish(invalidatedToken))
    let nextToken = try XCTUnwrap(owner.begin(EncodeStamp(captureCallbackNs: 66)))
    XCTAssertNotEqual(nextToken, invalidatedToken)  // old generation never joins new
    XCTAssertEqual(encoder.pendingVTCallbacks, 1)
    XCTAssertNotNil(owner.finish(nextToken))
    XCTAssertEqual(encoder.pendingVTCallbacks, 0)

    let racingToken = try XCTUnwrap(owner.begin(EncodeStamp(captureCallbackNs: 77)))
    let racingId = Int(bitPattern: racingToken)
    let wins = MetricsCollector()
    DispatchQueue.concurrentPerform(iterations: 32) { _ in
      if owner.finish(UnsafeMutableRawPointer(bitPattern: racingId)) != nil {
        wins.pendingSample(.creditFull, depth: 0)
      }
    }
    XCTAssertEqual(encoder.pendingVTCallbacks, 0)
    XCTAssertTrue(wins.snapshotWithPending(queue: 0).pending.contains("creditFull=1,0,0"))
  }
  func testPendingVTOperationalBucketsResetWithExistingInterval() {
    let metrics = MetricsCollector()
    metrics.pendingSample(.idle, depth: 0)
    metrics.pendingSample(.idle, depth: 1)
    metrics.pendingSample(.idle, depth: 3)
    metrics.pendingSample(.complete(gap25: false), depth: 0)
    metrics.pendingSample(.complete(gap25: false), depth: 1)
    metrics.pendingSample(.complete(gap25: true), depth: 2)
    metrics.pendingSample(.complete(gap25: false), depth: 3)
    metrics.pendingSample(.creditFull, depth: 0)
    metrics.pendingSample(.creditFull, depth: 2)
    let first = metrics.snapshotWithPending(queue: 3)
    XCTAssertTrue(
      first.pending.contains(
        "idle=1,1,1 complete=1,1,2 completeGap25=0,0,1 creditFull=1,0,1"))
    XCTAssertTrue(first.summary.contains("cumulative complete=0 sent=0"))
    XCTAssertTrue(
      metrics.snapshotWithPending(queue: 3).pending.contains(
        "idle=0,0,0 complete=0,0,0 completeGap25=0,0,0 creditFull=0,0,0"))
  }
  func testPendingVTOperationalOfflineMicrobenchmark() {
    // Bounded local-only owner/metric-path timing; not a VT/SCK or CPU-load proof.
    let iterations = 6_000
    let owner = VideoEncoder(codec: .avc, bitrate: 40_000_000).pendingCallbacks
    let metrics = MetricsCollector()
    let started = DispatchTime.now().uptimeNanoseconds
    for index in 0..<iterations {
      guard let token = owner.begin(EncodeStamp(captureCallbackNs: UInt64(index))) else {
        return XCTFail("unexpected tracker token exhaustion")
      }
      metrics.pendingSample(.complete(gap25: index.isMultiple(of: 10)), depth: owner.count)
      if index.isMultiple(of: 20) { metrics.pendingSample(.idle, depth: owner.count) }
      if index.isMultiple(of: 30) { metrics.pendingSample(.creditFull, depth: owner.count) }
      guard owner.finish(token) != nil else { return XCTFail("lost tracker token") }
      if index % 60 == 59 { _ = metrics.snapshotWithPending(queue: 3) }
    }
    let elapsedNs = DispatchTime.now().uptimeNanoseconds - started
    XCTAssertEqual(owner.count, 0)
    print(
      String(
        format: "pendingVTCallbacks offline-only loops=%d elapsedMs=%.3f meanUs=%.3f",
        iterations, Double(elapsedNs) / 1e6, Double(elapsedNs) / Double(iterations) / 1e3))
  }
  func testPipelineFailureGateAdmitsOnlyOneTransition() {
    let gate = PipelineFailureGate()
    var transitions = 0
    for _ in 0..<100 { gate.report { transitions += 1 } }
    XCTAssertEqual(transitions, 1)
  }
  func testCoordinateMappingEdgesAndNonzeroDisplayOrigin() {
    let mapper = CoordinateMapper(bounds: CGRect(x: -2456, y: 900, width: 2456, height: 1600))
    XCTAssertEqual(mapper.point(x: 0, y: 0), CGPoint(x: -2456, y: 900))
    XCTAssertEqual(mapper.point(x: 1, y: 1), CGPoint(x: -1, y: 2499))
    XCTAssertEqual(mapper.point(x: 0.5, y: 0.5), CGPoint(x: -1228.5, y: 1699.5))
  }
  func testHiDPILogicalReadbackRequiresExactBackingAndMapsGlobalPoints() {
    let logical = HostPreferences.LogicalSize.retina
    let bounds = CGRect(x: -1228, y: 900, width: 1228, height: 800)
    XCTAssertEqual(logical.width, 1228)
    XCTAssertTrue(logical.hiDPI)
    XCTAssertTrue(
      DisplayReadback.matches(
        logicalWidth: 1228, logicalHeight: 800, pixelWidth: 2456, pixelHeight: 1600,
        refreshHz: 60, bounds: bounds, requested: logical))
    XCTAssertFalse(
      DisplayReadback.matches(
        logicalWidth: 1228, logicalHeight: 800, pixelWidth: 1228, pixelHeight: 800,
        refreshHz: 60, bounds: bounds, requested: logical))
    XCTAssertFalse(
      DisplayReadback.matches(
        logicalWidth: 2456, logicalHeight: 1600, pixelWidth: 2456, pixelHeight: 1600,
        refreshHz: 60, bounds: bounds, requested: logical))
    XCTAssertFalse(
      DisplayReadback.matches(
        logicalWidth: 1228, logicalHeight: 800, pixelWidth: 2456, pixelHeight: 1600,
        refreshHz: 59, bounds: bounds, requested: logical))
    let mapper = CoordinateMapper(bounds: bounds)
    XCTAssertEqual(mapper.point(x: 0, y: 0), CGPoint(x: -1228, y: 900))
    XCTAssertEqual(mapper.point(x: 1, y: 1), CGPoint(x: -1, y: 1699))
    XCTAssertEqual(mapper.point(x: 0.5, y: 0.5), CGPoint(x: -614.5, y: 1299.5))
    let native = HostPreferences().logicalSize
    XCTAssertEqual(native, .native)
    XCTAssertTrue(
      DisplayReadback.matches(
        logicalWidth: 2456, logicalHeight: 1600, pixelWidth: 2456, pixelHeight: 1600,
        refreshHz: 60, bounds: CGRect(x: 0, y: 0, width: 2456, height: 1600), requested: native))
  }
  func testClientMetricsModeMustRemainExact() throws {
    let message = try XCTUnwrap(
      WireCodec.decode(
        Data(contentsOf: fixtures.appendingPathComponent("17-client-metrics-v1.bin"))))
    guard case .metrics(let accepted) = try ClientEvent.decode(message) else {
      return XCTFail("fixture is not ClientMetrics")
    }
    XCTAssertTrue(accepted.mode.isExact)
    let mode = WireValue.object([
      .object([.integer(1600), .integer(2456)]), .integer(90000), .signed(1),
    ])
    var fields = message.fields
    fields[6] = mode
    guard
      case .metrics(let rejected) = try ClientEvent.decode(
        WireMessage(
          type: message.type, sequence: message.sequence, timestamp: message.timestamp,
          fields: fields))
    else { return XCTFail("fixture is not ClientMetrics") }
    XCTAssertFalse(rejected.mode.isExact)
  }
  @MainActor func testPhysicalVirtualDisplayExactMode() async throws {
    guard ProcessInfo.processInfo.environment["MIRRI_PHYSICAL_DISPLAY_TEST"] == "1" else {
      throw XCTSkip("requires an explicit physical-display test opt-in")
    }
    let manager = VirtualDisplayManager()
    defer { manager.destroy() }
    let display = try await manager.create(logicalSize: .native)
    XCTAssertEqual(display.logicalSize, .native)
    XCTAssertEqual(display.refreshHz, 60, accuracy: 0.01)
  }
  @MainActor func testPhysicalHiDPIDisplayKeepsExactPixelBacking() async throws {
    guard ProcessInfo.processInfo.environment["MIRRI_PHYSICAL_DISPLAY_TEST"] == "1" else {
      throw XCTSkip("requires an explicit physical-display test opt-in")
    }
    let manager = VirtualDisplayManager()
    defer { manager.destroy() }
    let display = try await manager.create(logicalSize: .retina)
    XCTAssertEqual(display.logicalSize, .retina)
    XCTAssertEqual(display.bounds.size, CGSize(width: 1228, height: 800))
    XCTAssertEqual(display.refreshHz, 60, accuracy: 0.01)
  }
  func testSelectableDisplayModeRequiresLogicalPixelAndRateAgreement() {
    let native = HostPreferences.LogicalSize.native
    let retina = HostPreferences.LogicalSize.retina
    XCTAssertTrue(
      DisplayReadback.matchesMode(
        logicalWidth: 2456, logicalHeight: 1600, pixelWidth: 2456, pixelHeight: 1600,
        refreshHz: 60, requested: native))
    XCTAssertTrue(
      DisplayReadback.matchesMode(
        logicalWidth: 1228, logicalHeight: 800, pixelWidth: 2456, pixelHeight: 1600,
        refreshHz: 60, requested: retina))
    for (width, height, pixelsWide, pixelsHigh, hz) in [
      (1228, 800, 1228, 800, 60.0), (2456, 1600, 1228, 800, 60.0),
      (2456, 1600, 2456, 1600, 59.0), (2456, 1600, 2456, 1600, 90.0),
    ] {
      XCTAssertFalse(
        DisplayReadback.matchesMode(
          logicalWidth: width, logicalHeight: height, pixelWidth: pixelsWide,
          pixelHeight: pixelsHigh, refreshHz: hz, requested: native))
    }
  }
  func testDisplayGeometryFormatsOnlyBoundedNumericRoles() {
    let screen = DisplayGeometry.Screen(
      roles: "builtin+main", bounds: CGRect(x: 0, y: -800, width: 1228, height: 800),
      logical: CGSize(width: 1228, height: 800),
      pixels: CGSize(width: 2456, height: 1600),
      frame: CGRect(x: 0, y: 0, width: 1228, height: 800),
      visibleFrame: CGRect(x: 0, y: 24, width: 1228, height: 776))
    let result = DisplayGeometry.format(
      "beforeCreate", onlineCount: 9, screens: Array(repeating: screen, count: 9))
    XCTAssertTrue(result.contains("online=9 rolesShown=8 truncated=true"))
    XCTAssertTrue(result.contains("roles=builtin+main cgXYWH=0,-800,1228,800"))
    XCTAssertTrue(result.contains("logical=1228x800 pixels=2456x1600"))
    XCTAssertTrue(result.contains("nsXYWH=0,0,1228,800 nsVisibleXYWH=0,24,1228,776"))
    XCTAssertEqual(result.components(separatedBy: "{roles=").count - 1, 8)
    let owned = DisplayGeometry.Screen(
      roles: "owned", bounds: CGRect(x: 0, y: 800, width: 1228, height: 800),
      logical: nil, pixels: nil, frame: nil, visibleFrame: nil)
    let absent = DisplayGeometry.format("afterDestroy", onlineCount: 2, screens: [owned])
    XCTAssertTrue(absent.contains("roles=owned cgXYWH=0,800,1228,800"))
    XCTAssertTrue(absent.contains("logical=unavailable pixels=unavailable"))
    XCTAssertTrue(absent.contains("nsXYWH=unavailable nsVisibleXYWH=unavailable"))
    XCTAssertTrue(
      DisplayGeometry.format("afterDestroy", onlineCount: nil, screens: []).contains(
        "online=unavailable rolesShown=0"))
  }
  func testDisplayGeometryRejectsZeroFilledUnreturnedDisplaySlots() {
    XCTAssertEqual(
      DisplayGeometry.candidates([31, 0, 0, 0], returned: 1, main: 31, owned: 47),
      [31, 47])
    XCTAssertEqual(
      DisplayGeometry.candidates([31, 0, 47, 0], returned: 4, main: 31, owned: 47),
      [31, 47])
    XCTAssertEqual(
      DisplayGeometry.candidates([31, 0, 0], returned: 1, main: 0, owned: 0),
      [31])
  }
  func testPointerResetReleasesDragAndRejectsOutOfOrderInput() throws {
    var state = PointerState()
    try state.beginBatch(0)
    try state.accept(id: 17, phase: .down, time: 10)
    try state.accept(id: 17, phase: .move, time: 11)
    XCTAssertThrowsError(try state.accept(id: 18, phase: .up, time: 12))
    XCTAssertThrowsError(try state.accept(id: 17, phase: .move, time: 9))
    XCTAssertTrue(state.reset())
    XCTAssertNil(state.down)
    XCTAssertFalse(state.reset())
    try state.beginBatch(0)
    XCTAssertThrowsError(try state.accept(id: 17, phase: .up, time: 12))
  }
  func testHostFrameAgeUsesOnlyOneMonotonicClockAndBoundedSamples() {
    XCTAssertNil(HostFrameAge.milliseconds(since: 0, until: 100_000))
    XCTAssertNil(HostFrameAge.milliseconds(since: 200, until: 100))
    XCTAssertEqual(HostFrameAge.milliseconds(since: 1_000_000, until: 16_000_000), 15)
    let metrics = MetricsCollector()
    metrics.sentFrame(bytes: 100, submitAgeMs: 15, convertAgeMs: 5)
    metrics.completeFrame(gapMilliseconds: nil)
    metrics.completeFrame(gapMilliseconds: 16.7)
    metrics.completeFrame(gapMilliseconds: 16.7)
    metrics.completeFrame(gapMilliseconds: 33.4)
    metrics.rejectedFrame(.nonComplete)
    metrics.rejectedFrame(.idle)
    metrics.rejectedFrame(.creditFull)
    metrics.encoderSubmission(milliseconds: 0.4)
    let first = metrics.snapshot(queue: 0)
    XCTAssertTrue(first.contains("submit-to-write 1 samples 15.0/15.0 ms"))
    XCTAssertTrue(first.contains("convert-to-write 5.0/5.0 ms"))
    XCTAssertTrue(first.contains("skip idle=2 format=0 credit=1 submit=0"))
    XCTAssertTrue(first.contains("VT call 1 samples 0.4/0.4 ms"))
    XCTAssertTrue(first.contains("SC complete=4 idle=1 blank=0 suspended=0"))
    XCTAssertTrue(first.contains("PTSgap 3 samples 16.7/33.4 ms >25ms=1"))
    XCTAssertTrue(first.contains("cumulative complete=4 sent=1"))
    XCTAssertTrue(metrics.snapshot(queue: 0).contains("submit-to-write 0 samples"))
    XCTAssertTrue(metrics.snapshot(queue: 0).contains("cumulative complete=4 sent=1"))
  }
  func testFixedStageHistogramQuantilesBucketsAndReset() {
    var histogram = StageTimingHistogram()
    for millis: UInt64 in [1, 5, 30, 100, 200] {
      XCTAssertTrue(histogram.observe(millis * 1_000_000))
    }
    XCTAssertEqual(histogram.count, 5)
    XCTAssertEqual(histogram.upperBoundMs(0.5), 30)
    XCTAssertEqual(histogram.upperBoundMs(0.95), 200)
    XCTAssertEqual(histogram.upperBoundMs(0.99), 200)
    XCTAssertEqual(histogram.maxNs, 200_000_000)
    let snapshot = histogram.drain()
    XCTAssertEqual(snapshot.count, 5)
    XCTAssertEqual(histogram.count, 0)
    XCTAssertEqual(snapshot.encoded().split(separator: ":")[5].split(separator: ".").count, 59)
    XCTAssertTrue(histogram.observe(11_000_000_000))
    XCTAssertNil(histogram.upperBoundMs(0.95))  // >10 s has no finite bucket upper bound.
    XCTAssertEqual(histogram.maxNs, 11_000_000_000)
    XCTAssertEqual(histogram.drain().count, 1)
    XCTAssertEqual(StageTimingHistogram.boundsNs[0], 2_000_000)
    XCTAssertEqual(StageTimingHistogram.boundsNs[49], 100_000_000)
    XCTAssertEqual(StageTimingHistogram.boundsNs.last, 10_000_000_000)
    for (ms, upper) in [(UInt64(25), Double(26)), (33, 34), (50, 50), (75, 76), (100, 100)] {
      var bounded = StageTimingHistogram()
      XCTAssertTrue(bounded.observe(ms * 1_000_000))
      XCTAssertEqual(bounded.upperBoundMs(0.95), upper)
    }
    var gapHistogram = StageTimingHistogram(trackGaps: true)
    for millis: UInt64 in [16, 33, 60] {
      XCTAssertTrue(gapHistogram.observe(millis * 1_000_000))
    }
    let first = gapHistogram.drain()
    XCTAssertEqual(first.encoded().split(separator: ":").last, "2.1.0.0.0.0.0.0.0.2")
    XCTAssertTrue(gapHistogram.observe(16_000_000))
    let second = gapHistogram.drain()
    XCTAssertEqual(second.encoded().split(separator: ":").last, "0.0.0.0.1.0.0.0.2.0")
    XCTAssertTrue(gapHistogram.observe(120_000_000))
    gapHistogram.finishGapRun()
    XCTAssertEqual(gapHistogram.drain().encoded().split(separator: ":").last, "1.1.1.1.0.0.0.0.1.0")
  }
  func testHostTimelineKeepsMediaPTSSeparateFromMonotonicCallbacksAndMatchesWrittenUnit() {
    let timing = HostVideoTiming(epoch: 2, generation: 3)
    timing.activate(atNs: 1_000_000_000)
    timing.complete(pts: CMTime(value: 0, timescale: 60_000), callbackNs: 1_000_000_000)
    timing.complete(pts: CMTime(value: 1_000, timescale: 60_000), callbackNs: 1_033_000_000)
    timing.admitted(depth: 3)
    timing.encoderCall(milliseconds: 0.2)
    let unit = EncodedUnit(
      accessUnit: Data([0, 0, 0, 1, 0x65]), parameterSets: nil, keyframe: true,
      pts: 16_666_666, encodeLatencyMs: 10, submittedNs: 1_040_000_000,
      captureCallbackNs: 1_033_000_000, encoderCallbackNs: 1_050_000_000,
      convertedNs: 1_052_000_000)
    timing.encoderOutput(unit)
    timing.encodedQueue(depth: 2)
    timing.written(unit, sequence: 0, atNs: 1_060_000_000)
    let measured = timing.snapshotMeasured(atNs: 1_100_000_000)
    let report = measured.line
    XCTAssertGreaterThanOrEqual(measured.lockNs, 0)
    XCTAssertGreaterThanOrEqual(measured.formatNs, 0)
    XCTAssertTrue(
      report.contains("v=4 epoch=2 generation=3 record=0 startNs=1000000000 endNs=1100000000"))
    XCTAssertTrue(report.contains("final=0 complete=2 encoded=1 written=1"))
    XCTAssertTrue(report.contains("capturePtsToCallback=unavailable-unverified-clock"))
    XCTAssertTrue(report.contains("truncatedDecoderPTS=1 creditHigh=3 encodedQueueHigh=2"))
    XCTAssertTrue(report.contains("mediaPtsGap=1:18.0:18.0:18.0:"))
    XCTAssertTrue(report.contains(":0.0.0.0.0.0.0.0.0.0 completeCallbackGap="))
    XCTAssertTrue(report.contains("completeCallbackGap=1:34.0:34.0:34.0:"))
    XCTAssertTrue(report.contains("vtCallback=1:10.0:10.0:10.0:10.0:"))
    XCTAssertTrue(report.contains("keyVtCallback=1:10.0:10.0:10.0:10.0:"))
    XCTAssertTrue(
      report.contains(
        "keyEncoded=1 keyWritten=1 keyBytes=5 keyMaxBytes=5 otherBytes=0 otherMaxBytes=0"))
    XCTAssertTrue(report.contains("callbackToWrite=1:28.0:28.0:28.0:27.0:"))
    XCTAssertTrue(report.contains("conversionToWrite=1:8.0:8.0:8.0:8.0:"))
    XCTAssertTrue(timing.snapshot(atNs: 1_200_000_000).contains("complete=0 encoded=0 written=0"))

    timing.written(unit, sequence: 0, atNs: 1_070_000_000)  // synthetic duplicate sequence
    timing.complete(pts: CMTime(value: 0, timescale: 60_000), callbackNs: 1_032_000_000)
    let invalid = timing.snapshot(atNs: 1_300_000_000)
    XCTAssertTrue(invalid.contains("sequenceMismatch=1"))
    XCTAssertTrue(invalid.contains("invalidClock=2"))  // negative PTS and callback cadence
    timing.freeze(atNs: 1_350_000_000)
    XCTAssertTrue(timing.finish().contains("final=1"))
    XCTAssertEqual(timing.finish(), timing.finish())
  }
  func testKeyAUClassIsCountedWithoutChangingOtherVTObservations() {
    let timing = HostVideoTiming(epoch: 9, generation: 1)
    timing.activate(atNs: 1_000_000_000)
    for (index, keyframe) in [true, false, false].enumerated() {
      let start = UInt64(1_010_000_000 + index * 20_000_000)
      let unit = EncodedUnit(
        accessUnit: Data(repeating: 1, count: keyframe ? 80 : index * 100),
        parameterSets: nil, keyframe: keyframe, pts: UInt64(index * 20_000_000),
        encodeLatencyMs: 0, submittedNs: start, captureCallbackNs: start,
        encoderCallbackNs: start + UInt64(keyframe ? 12_000_000 : 4_000_000),
        convertedNs: start + 13_000_000)
      timing.encoderOutput(unit)
      timing.written(unit, sequence: UInt64(index), atNs: start + 14_000_000)
    }
    let report = timing.snapshot(atNs: 1_100_000_000)
    XCTAssertTrue(report.contains("encoded=3 written=3"))
    XCTAssertTrue(
      report.contains(
        "keyEncoded=1 keyWritten=1 keyBytes=80 keyMaxBytes=80 otherBytes=300 otherMaxBytes=200"))
    XCTAssertTrue(report.contains("keyVtCallback=1:12.0:12.0:12.0:12.0:"))
    XCTAssertTrue(report.contains("vtCallback=3:"))
    XCTAssertTrue(
      timing.snapshot(atNs: 1_200_000_000).contains("keyEncoded=0 keyWritten=0 keyBytes=0"))
  }
  func testProductionHostTimingEmitterFullAndPartialWindows() throws {
    let origin: UInt64 = 1_000_000_000
    for offset: UInt64 in [0, 250_000_000] {
      let start = origin + offset
      let timing = HostVideoTiming(epoch: 7, generation: 1)
      timing.activate(atNs: start)
      var nextBoundary = origin + 1_000_000_000
      var lines: [String] = []
      for frame in 0..<5400 {
        let pts = UInt64(frame) * 16_666_666
        let callback = start + pts + 1_000_000
        while nextBoundary <= callback + 4_000_000 {
          lines.append(timing.snapshot(atNs: nextBoundary))
          nextBoundary += 1_000_000_000
        }
        timing.complete(
          pts: CMTime(value: Int64(pts), timescale: 1_000_000_000), callbackNs: callback)
        // Production histogram permits synchronous zero duration.
        timing.encoderCall(milliseconds: 0)
        let keyframe = frame % 60 == 0
        let unit = EncodedUnit(
          accessUnit: Data(repeating: keyframe ? 0x65 : 0x41, count: keyframe ? 80 : 20),
          parameterSets: nil, keyframe: keyframe,
          pts: pts, encodeLatencyMs: 1, submittedNs: callback + 1_000_000,
          captureCallbackNs: callback, encoderCallbackNs: callback + 2_000_000,
          convertedNs: callback + 3_000_000)
        timing.encoderOutput(unit)
        timing.written(unit, sequence: UInt64(frame), atNs: callback + 4_000_000)
      }
      timing.freeze(atNs: start + 90_000_000_000)
      lines.append(timing.finish())
      XCTAssertTrue(lines.first?.contains("record=0 startNs=\(start) ") == true)
      XCTAssertTrue(lines.last?.contains("final=1") == true)
      XCTAssertLessThan(lines.map { $0.utf8.count }.max() ?? 0, 3_900)
      XCTAssertEqual(lines.count, offset == 0 ? 90 : 91)
      if let directory = ProcessInfo.processInfo.environment["MIRRI_TIMING_EMITTER_DIR"] {
        let name = offset == 0 ? "host-full.log" : "host-partial.log"
        let body = lines.map {
          "2026-09-26T16:00:00Z \(SessionLogger.metricsLine($0))\n"
        }.joined()
        try body.write(
          to: URL(fileURLWithPath: directory).appendingPathComponent(name), atomically: true,
          encoding: .utf8)
      }
    }
  }
}
