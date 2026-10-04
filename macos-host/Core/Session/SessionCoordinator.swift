import Foundation
import Security

public enum ClientEpochDisposition: Equatable, Sendable {
  case current, stale, future

  public static func compare(received: UInt64, expected: UInt32) -> Self {
    if received < UInt64(expected) { return .stale }
    if received > UInt64(expected) { return .future }
    return .current
  }
}

/// Sole lifecycle owner; all asynchronous continuations check incarnation before publishing state.
public actor SessionCoordinator {
  /// Identifies one handshake/reconnect attempt. Async completions may install
  /// resources only while both incarnation and epoch still match this lease.
  private struct AttemptIdentity: Sendable {
    let incarnation: UInt64
    let epoch: UInt32
  }
  private struct AuthenticatedControl {
    let channel: WireConnection
    let order: WireOrder
    let greeting: ClientGreeting
  }
  private struct VideoBarrier {
    let channel: WireConnection
    let order: WireOrder
    let route: any HostConnectionRoute
  }
  public typealias StatusHandler = @MainActor @Sendable (HostSnapshot) async -> Void
  private var route: (any HostConnectionRoute)?
  private var display: VirtualDisplayManager?
  private var metrics = MetricsCollector()
  private var videoTiming: HostVideoTiming?
  private var latencyTrace: HostLatencyTrace?
  private var timingReportSamples = 0
  private var timingReportLockMaxNs: UInt64 = 0
  private var timingReportFormatMaxNs: UInt64 = 0
  private var timingReportLogMaxNs: UInt64 = 0
  private let logger: SessionLogger
  private let status: StatusHandler
  private let permissions: @MainActor @Sendable () -> Bool
  private var snapshot = HostSnapshot()
  private var preferences = HostPreferences()
  private var control: WireConnection?
  private var video: WireConnection?
  private var capture: CapturePipeline?
  private var rtcPeer: RtcPeer?
  private var rtcWriter: RtcSignalWriter?
  private var rtcEvents: Task<Void, Never>?
  private var rtcTimer: Task<Void, Never>?
  private var rtcAttempt = Data()
  private var rtcOfferWritten = false
  private var rtcRemote = RtcIceLedger()
  private var rtcCandidates: [(String, UInt16, String)] = []
  private var rtcLocalCandidateCount = 0
  private var rtcMid = ""
  private var rtcFailure = false
  private var rtcTimedOut = false
  private var rtcRttMs: Double?
  private var input: InputController?
  private var token = Data()
  private var sessionId = Data()
  private var epoch: UInt32 = 0
  private var generation: UInt32 = 0
  private var incarnation: UInt64 = 0
  private var reconnectUntil: ContinuousClock.Instant?
  private var tick: Task<Void, Never>?
  private var teardownTask: Task<Void, Never>?
  /// Stop/terminal release owned by the current `.stopping` transition; joiners await this task.
  private var lifecycleCompletion: Task<Void, Never>?
  private var controlReader: Task<Void, Never>?
  private var reconnectTask: Task<Void, Never>?
  private var stopAckReaderId: UInt64?
  private var stopAckReceived = false
  private var stopAckContinuation: CheckedContinuation<Void, Never>?
  private var decoderFailures = 0
  private var authenticatedControl = false
  private var pingSequence: UInt64 = 0
  private var pendingPing: (sequence: UInt64, sent: UInt64)?

  public init(
    permissions: @escaping @MainActor @Sendable () -> Bool,
    status: @escaping StatusHandler, logger: SessionLogger = SessionLogger()
  ) {
    self.permissions = permissions
    self.status = status
    self.logger = logger
  }
  public func configure(_ preferences: HostPreferences) { self.preferences = preferences }
  public func current() -> HostSnapshot { snapshot }
  private func state(_ value: HostState, _ description: String) async {
    snapshot.state = value
    snapshot.message = description
    logger.event(value)
    await status(snapshot)
  }
  private static func random(_ length: Int) throws -> Data {
    var bytes = Data(count: length)
    let result = bytes.withUnsafeMutableBytes {
      guard let address = $0.baseAddress else { return errSecParam }
      return SecRandomCopyBytes(kSecRandomDefault, length, address)
    }
    guard result == errSecSuccess else { throw HostFailure.transport }
    return bytes
  }
  private func valid(_ id: UInt64, epoch expectedEpoch: UInt32? = nil) throws {
    guard incarnation == id, snapshot.state != .stopping,
      expectedEpoch == nil || epoch == expectedEpoch
    else { throw HostFailure.invalidState }
    if let deadline = reconnectUntil, ContinuousClock.now >= deadline {
      throw HostFailure.timeout
    }
  }
  private func valid(_ attempt: AttemptIdentity) throws {
    try valid(attempt.incarnation, epoch: attempt.epoch)
  }
  public func start(route newRoute: any HostConnectionRoute) async {
    guard !Task.isCancelled, snapshot.state == .idle || snapshot.state == .failed else {
      await newRoute.close()
      return
    }
    lifecycleCompletion = nil
    incarnation &+= 1
    let id = incarnation
    route = newRoute  // Join the route before first suspension, including pending ADB work.
    snapshot.device = newRoute.displayLabel
    await state(.checkingPermissions, "Checking macOS permissions")
    do {
      guard await permissions() else { throw HostFailure.permission }
      let installedLabel = try await newRoute.prepare()
      try valid(id)
      snapshot.device = installedLabel
      try valid(id)
      token = try Self.random(32)
      sessionId = try Self.random(16)
      epoch = 1
      generation = 0
      decoderFailures = 0
      pingSequence = 0
      pendingPing = nil
      authenticatedControl = false
      await state(.preparingTransport, newRoute.transportDescription)
      try valid(id)
      await state(.waitingForClient, newRoute.waitingDescription)
      try valid(id)
      try await newRoute.bootstrap(
        AttemptCredentials(token: token, sessionId: sessionId, epoch: epoch))
      try valid(id)
      try await handshake(id: id)
    } catch {
      if incarnation == id && snapshot.state != .stopping {
        let failure: HostFailure = if let error = error as? HostFailure { error }
          else if let wire = error as? WireFailure {
            wire == .unsupported && (newRoute as? NetworkConnectionRoute)?.rtcSelected == true
              ? .version : .malformed
          } else { .transport }
        await terminal(failure)
      }
    }
  }
  private func handshake(id: UInt64) async throws {
    guard let route else { throw HostFailure.transport }
    let attempt = AttemptIdentity(incarnation: id, epoch: epoch)
    // Closing the listener and sockets wakes blocked continuations on handshake timeout.
    let budget =
      reconnectUntil.map {
        max(Duration.zero, min(.seconds(10), ContinuousClock.now.duration(to: $0)))
      } ?? (route is NetworkConnectionRoute && (route as? NetworkConnectionRoute)?.rtcSelected == true
        ? .seconds(36) : .seconds(10))
    let timeout = Task { [weak self] in
      try? await Task.sleep(for: budget)
      if !Task.isCancelled {
        await self?.expireHandshake(incarnation: attempt.incarnation, epoch: attempt.epoch)
      }
    }
    defer { timeout.cancel() }
    let authenticated = try await acceptAuthenticatedControl(route, attempt: attempt)
    if let network = route as? NetworkConnectionRoute, network.rtcSelected {
      do {
        try await rtcHandshake(authenticated, attempt: attempt)
      } catch {
        logger.diagnostic("rtc-handshake-exception-\(String(describing: type(of: error)))")
        if let failure = error as? HostFailure {
          logger.diagnostic("rtc-handshake-failure-\(String(describing: failure))")
        }
        if rtcTimedOut { throw HostFailure.timeout }
        throw error
      }
      return
    }
    let (config, active) = try await prepareExactDisplay(authenticated.greeting, attempt: attempt)
    let barrier = try await awaitClientBarrier(
      channel: authenticated.channel, route: route, order: authenticated.order,
      config: config,
      attempt: attempt)
    try await beginStreaming(
      controlChannel: authenticated.channel, barrier: barrier,
      config: config, active: active, attempt: attempt)
  }

  /// Claim a delivered channel only while the accepting attempt still owns this coordinator.
  /// Both channels use the same lease check immediately before publication.
  func acceptChannel(
    from route: any HostConnectionRoute, incarnation id: UInt64, epoch expectedEpoch: UInt32,
    videoChannel: Bool
  ) async throws -> WireConnection {
    let bytes = try await (videoChannel ? route.acceptVideo() : route.acceptControl())
    var prepared: any ByteConnection = bytes
    if !videoChannel && route.requiresEpochBootstrap {
      do {
        try valid(AttemptIdentity(incarnation: id, epoch: expectedEpoch))
        prepared = try await NetworkBootstrap.accept(bytes, token: token, epoch: expectedEpoch)
      } catch {
        await bytes.close()
        throw error
      }
    }
    let channel = WireConnection(prepared, video: videoChannel)
    do { try valid(AttemptIdentity(incarnation: id, epoch: expectedEpoch)) } catch {
      await channel.close()
      throw error
    }
    if videoChannel { video = channel } else { control = channel }
    return channel
  }

  private func acceptAuthenticatedControl(
    _ route: any HostConnectionRoute, attempt: AttemptIdentity
  ) async throws -> AuthenticatedControl {
    let channel = try await acceptChannel(
      from: route, incarnation: attempt.incarnation, epoch: attempt.epoch, videoChannel: false)
    guard case .message(let hello) = try await channel.read(),
      hello.type == MessageKind.clientHello.rawValue
    else {
      throw HostFailure.malformed
    }
    try valid(attempt)
    var order = WireOrder(receivingFrom: .client, on: .control, epoch: UInt64(attempt.epoch))
    guard case .hello(let greeting) = try ClientEvent.decode(hello) else {
      throw HostFailure.malformed
    }
    guard Authenticator.equals(greeting.token, token) else {
      throw HostFailure.unauthorized
    }
    // An existing activity can retry its previous epoch before the new launch intent
    // arrives. Close that connection and continue the bounded grace retry instead
    // of terminating an otherwise authenticated USB session.
    switch ClientEpochDisposition.compare(received: UInt64(greeting.epoch), expected: attempt.epoch)
    {
    case .stale: throw HostFailure.transport
    case .future: throw HostFailure.unauthorized
    case .current: break
    }
    try order.accept(hello)
    try order.bindSession(sessionId)
    authenticatedControl = true
    return AuthenticatedControl(channel: channel, order: order, greeting: greeting)
  }

  /// RTC deliberately bypasses legacy SessionConfig/video socket/VideoEncoder.
  private func rtcHandshake(_ auth: AuthenticatedControl, attempt: AttemptIdentity) async throws {
    guard auth.greeting.nativeSize == (1600, 2456), auth.greeting.active.isExact,
      auth.greeting.modes.contains(where: \.isExact) else { throw HostFailure.incompatible }
    var order = auth.order
    let channel = auth.channel
    rtcTimedOut = false
    rtcArmDeadline(.seconds(5), attempt: attempt)
    let writer = RtcSignalWriter(channel: channel)
    rtcWriter = writer
    let caps = try await rtcRead(channel, order: &order, attempt: attempt)
    guard caps.type == MessageKind.rtcCapabilities.rawValue,
      (try RtcSignal.number(caps.fields[2])) == 1,
      (try RtcSignal.number(caps.fields[4])) == 1,
      (try RtcSignal.number(caps.fields[5])) == 2,
      (try RtcSignal.number(caps.fields[6])) >= 52,
      (try RtcSignal.number(caps.fields[7])) == 1,
      (try RtcSignal.number(caps.fields[8])) == 1 else { throw HostFailure.hardwareCodec }
    let nonce = try RtcSignal.bytes(caps.fields[3])
    rtcAttempt = try Self.random(16)
    let attemptID = rtcAttempt
    await state(.negotiating, "RTC hardware High 5.2 and exact mode")
    // Probe prior to prepare; the actual RTC encoder independently requires
    // and checks hardware on its own VT session at startEncode.
    guard VideoEncoder.probe(.avc) else { throw HostFailure.hardwareCodec }
    try valid(attempt)
    await state(.creatingDisplay, "Publishing exact virtual display for RTC")
    if display == nil { display = await MainActor.run { VirtualDisplayManager() } }
    guard let display else { throw HostFailure.exactDisplay }
    let active = try await display.create(logicalSize: preferences.logicalSize)
    try valid(attempt)
    snapshot.virtualMode = "\(active.logicalSize.width)x\(active.logicalSize.height) logical, 2456x1600 @ \(Int(active.refreshHz)) Hz"
    try await writer.send(RtcSignal.message(.rtcPrepare, session: sessionId, epoch: epoch,
      attempt: attemptID, fields: [.bytes(nonce), .integer(1), .integer(2), .integer(52),
        .object([.integer(2456), .integer(1600)]), .integer(60000), .integer(1)]))
    rtcArmDeadline(.seconds(10), attempt: attempt)
    await state(.preparingClient, "Awaiting RTC hardware decoder and surface readback")
    let prepared = try await rtcRead(channel, order: &order, attempt: attempt)
    guard prepared.type == MessageKind.rtcPrepared.rawValue else { throw HostFailure.malformed }
    try RtcSignal.match(prepared, attempt: attemptID)
    logger.diagnostic("rtc-prepared-received")
    snapshot.clientMode = "1600x2456 (RTC hardware readback)"
    let decoder = try RtcSignal.text(prepared.fields[6])
    guard !decoder.isEmpty else { throw HostFailure.hardwareCodec }
    // No encoder/capture is started until the authenticated RTC start barrier.
    let peer = RtcPeer()
    rtcPeer = peer // Join ownership before its first asynchronous operation.
    try peer.prepare(ceiling: preferences.avcBitrate, adaptive: preferences.adaptiveBitrate)
    logger.diagnostic("rtc-peer-prepared")
    rtcOfferWritten = false
    rtcRemote = RtcIceLedger()
    rtcCandidates = []
    rtcLocalCandidateCount = 0
    rtcFailure = false
    rtcRttMs = nil
    rtcEvents = Task { [weak self] in
      for await event in peer.events {
        await self?.rtcPeerEvent(event, attempt: attempt)
      }
    }
    let offer: String
    do { offer = try await peer.offer() }
    catch { throw error as? HostFailure ?? .hardwareCodec }
    try valid(attempt)
    guard let mid = peer.videoMid, !mid.isEmpty, mid.utf8.count <= 32 else {
      throw HostFailure.incompatible
    }
    logger.diagnostic("rtc-local-offer-created")
    rtcMid = mid
    guard RtcSDPProof.videoOnlyHigh(sdp: offer, direction: "sendonly", mid: mid) else {
      throw HostFailure.incompatible
    }
    try await writer.send(RtcSignal.message(.rtcOffer, session: sessionId, epoch: epoch,
      attempt: attemptID, fields: [.text(offer)]))
    logger.diagnostic("rtc-offer-written")
    try valid(attempt)
    rtcOfferWritten = true
    try await rtcFlushCandidates(attempt: attempt)
    let deadline = ContinuousClock.now.advanced(by: .seconds(20))
    rtcArmDeadline(.seconds(10), attempt: attempt)
    var answer: WireMessage?
    while answer == nil {
      let message = try await rtcRead(channel, order: &order, attempt: attempt)
      if message.type == MessageKind.rtcAnswer.rawValue { answer = message }
      else if message.type == MessageKind.rtcIceCandidate.rawValue ||
        message.type == MessageKind.rtcIceEnd.rawValue {
        try await rtcRemoteIce(message, attempt: attempt)
      } else { throw HostFailure.malformed }
    }
    guard let answer else { throw HostFailure.malformed }
    guard answer.type == MessageKind.rtcAnswer.rawValue else { throw HostFailure.malformed }
    try RtcSignal.match(answer, attempt: attemptID)
    logger.diagnostic("rtc-answer-received")
    let sdp = try RtcSignal.text(answer.fields[4])
    guard ContinuousClock.now < deadline else { throw HostFailure.timeout }
    rtcArmDeadline(ContinuousClock.now.duration(to: deadline), attempt: attempt)
    guard RtcSDPProof.videoOnlyHigh(sdp: sdp, direction: "recvonly", mid: mid) else {
      throw HostFailure.incompatible
    }
    logger.diagnostic("rtc-answer-profile-accepted")
    do { try await peer.answer(sdp) }
    catch { throw error as? HostFailure ?? .incompatible }
    logger.diagnostic("rtc-remote-answer-applied")
    try valid(attempt)
    let pendingIce = rtcRemote.applyRemoteDescription()
    logger.diagnostic("rtc-remote-ice-pending-\(pendingIce.count)")
    for text in pendingIce {
      do { try await peer.addCandidate(mid: rtcMid, index: 0, text: text) }
      catch { throw error as? HostFailure ?? .incompatible }
      try valid(attempt)
    }
    var ready = false
    logger.diagnostic("rtc-await-media-ready")
    while !ready {
      let message = try await rtcRead(channel, order: &order, attempt: attempt)
      if message.type == MessageKind.rtcMediaReady.rawValue {
        try RtcSignal.match(message, attempt: attemptID)
        ready = true
      } else if message.type == MessageKind.rtcIceCandidate.rawValue ||
        message.type == MessageKind.rtcIceEnd.rawValue {
        try await rtcRemoteIce(message, attempt: attempt)
      } else { throw HostFailure.malformed }
      if rtcFailure || ContinuousClock.now >= deadline { throw HostFailure.timeout }
    }
    // Keep draining authenticated ICE while waiting for the selected pair;
    // otherwise candidates sent after MediaReady could never establish UDP.
    controlReader = Task { [weak self] in
      await self?.readRtcControl(channel, order: order, attempt: attempt)
    }
    while true {
      try valid(attempt)
      let status = await peer.mediaStatus()
      if status == .ready { break }
      if status == .nonUDP { logger.diagnostic("rtc-selected-non-udp"); throw HostFailure.transport }
      if status == .codecOrGeometry { throw HostFailure.hardwareCodec }
      guard !rtcFailure, ContinuousClock.now < deadline else { throw HostFailure.timeout }
      try await Task.sleep(for: .milliseconds(100))
    }
    guard !rtcFailure, ContinuousClock.now < deadline else { throw HostFailure.timeout }
    // An SDK gathering-complete callback cannot prove that all candidate
    // callbacks were delivered. Connection/ready deadline is the ICE barrier.
    try await writer.send(RtcSignal.message(.rtcStart, session: sessionId, epoch: epoch,
      attempt: attemptID))
    try valid(attempt)
    guard !rtcFailure, !rtcTimedOut else { throw HostFailure.transport }
    try await peer.start(display: active)
    try valid(attempt)
    guard !rtcFailure, !rtcTimedOut else { throw HostFailure.transport }
    rtcTimer?.cancel(); rtcTimer = nil
    input = InputController(display: active, zoom: preferences.zoom,
      auxiliaryAction: preferences.auxiliaryAction)
    reconnectUntil = nil
    snapshot.video = "RTC H.264 High 5.2 hardware-required, selected UDP (capture started)"
    await state(.streaming, "RTC video over UDP (USB credential, pinned TLS control)")
    tick?.cancel()
    tick = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(1))
        await self?.updateMetrics(id: attempt.incarnation, channelEpoch: attempt.epoch)
      }
    }
  }
  private func rtcRead(_ channel: WireConnection, order: inout WireOrder,
    attempt: AttemptIdentity) async throws -> WireMessage {
    while true {
      let record = try await channel.read()
      try valid(attempt)
      guard case .message(let message) = record else {
        if case .skipped(let sequence) = record {
          try order.skipUnknown(sequence: sequence)
          continue
        }
        throw HostFailure.malformed
      }
      if (23...31).contains(message.type), message.fields.count >= 2,
        (try RtcSignal.number(message.fields[1])) < UInt64(epoch) {
        try order.skipStaleRtc(message)
        continue
      }
      try order.accept(message)
      guard message.fields.count >= 2,
        (try RtcSignal.bytes(message.fields[0])) == sessionId,
        (try RtcSignal.number(message.fields[1])) == UInt64(epoch) else {
        throw HostFailure.malformed
      }
      return message
    }
  }
  private func rtcRemoteIce(_ message: WireMessage, attempt: AttemptIdentity) async throws {
    try valid(attempt)
    try RtcSignal.match(message, attempt: rtcAttempt)
    let mid = try RtcSignal.text(message.fields[4])
    let index = UInt16(try RtcSignal.number(message.fields[5]))
    if message.type == MessageKind.rtcIceEnd.rawValue {
      try rtcRemote.end(mid: mid, expectedMid: rtcMid, index: index)
      return
    }
    guard message.type == MessageKind.rtcIceCandidate.rawValue,
      let peer = rtcPeer else { throw HostFailure.malformed }
    guard let text = try rtcRemote.candidate(mid: mid, expectedMid: rtcMid,
      index: index, text: RtcSignal.text(message.fields[6])) else { return }
    if rtcRemote.count == 1 || rtcRemote.count.isMultiple(of: 16) {
      logger.diagnostic("rtc-remote-candidates-\(rtcRemote.count)")
    }
    do { try await peer.addCandidate(mid: rtcMid, index: 0, text: text) }
    catch { throw error as? HostFailure ?? .incompatible }
    try valid(attempt)
  }
  private func rtcPeerEvent(_ event: RtcPeerEvent, attempt: AttemptIdentity) async {
    guard incarnation == attempt.incarnation, epoch == attempt.epoch,
      snapshot.state != .stopping else { return }
    switch event {
    case .state(let value): logger.diagnostic("rtc-peer-state-\(value)")
    case .iceState(let value): logger.diagnostic("rtc-ice-state-\(value)")
    case .encoderFailure(let stage):
      logger.diagnostic("rtc-encoder-failed-\(stage)")
      rtcFailure = true
      if snapshot.state == .streaming { await terminal(.hardwareCodec) }
      else { await control?.close() }
    case .mediaProof(let description): logger.diagnostic("rtc-media-proof-\(description)")
    case .outboundFrames(let description): logger.diagnostic("rtc-outbound-\(description)")
    case .failed:
      logger.diagnostic("rtc-peer-failed-before-ready")
      rtcFailure = true
      if snapshot.state == .streaming { await terminal(.transport) }
      else { await control?.close() }
    case .candidate(let mid, let index, let text):
      if rtcLocalCandidateCount == 0 && rtcCandidates.isEmpty {
        let parts = text.split(whereSeparator: \.isWhitespace)
        let udp = parts.count > 7 && parts[2].lowercased() == "udp"
        let host = parts.count > 7 && parts[6] == "typ" && parts[7] == "host"
        let v4 = parts.count > 7 && parts[4].split(separator: ".").count == 4 &&
          parts[4].allSatisfy { $0.isNumber || $0 == "." }
        let selected = parts.count > 7 && LocalIPv4Address.available().contains {
          $0.interface == "en0" && $0.address == String(parts[4])
        }
        logger.diagnostic("rtc-local-candidate-shape-udp=\(udp)-host=\(host)-v4=\(v4)-en0=\(selected)")
      }
      guard rtcCandidates.count < 64,
        mid == rtcMid || !rtcOfferWritten,
        text.utf8.count <= 2048 else {
        logger.diagnostic("rtc-peer-candidate-boundary-failed")
        rtcFailure = true; await control?.close(); return
      }
      rtcCandidates.append((mid, index, text))
      if rtcOfferWritten {
        do { try await rtcFlushCandidates(attempt: attempt) }
        catch { logger.diagnostic("rtc-local-ice-write-failed"); rtcFailure = true; await control?.close() }
      }
    case .connected: break
    }
  }
  private func rtcFlushCandidates(attempt: AttemptIdentity) async throws {
    guard let writer = rtcWriter else { throw HostFailure.invalidState }
    while !rtcCandidates.isEmpty {
      try valid(attempt)
      let (mid, index, text) = rtcCandidates.removeFirst()
      guard mid == rtcMid, index == 0 else { throw HostFailure.malformed }
      try await writer.send(RtcSignal.message(.rtcIceCandidate, session: sessionId,
        epoch: epoch, attempt: rtcAttempt,
        fields: [.text(mid), .integer(UInt64(index)), .text(text)]))
      rtcLocalCandidateCount += 1
      if rtcLocalCandidateCount == 1 || rtcLocalCandidateCount.isMultiple(of: 16) {
        logger.diagnostic("rtc-local-candidates-\(rtcLocalCandidateCount)")
      }
    }
  }
  private func rtcExpire(attempt: AttemptIdentity) async {
    guard incarnation == attempt.incarnation, epoch == attempt.epoch,
      snapshot.state != .streaming && snapshot.state != .stopping else { return }
    rtcTimedOut = true
    await control?.close()
    await rtcPeer?.stop()
  }
  private func rtcArmDeadline(_ duration: Duration, attempt: AttemptIdentity) {
    rtcTimer?.cancel()
    rtcTimer = Task { [weak self] in
      try? await Task.sleep(for: duration)
      if !Task.isCancelled { await self?.rtcExpire(attempt: attempt) }
    }
  }

  private func prepareExactDisplay(
    _ greeting: ClientGreeting, attempt: AttemptIdentity
  ) async throws -> (NegotiatedConfig, ActiveDisplay) {
    await state(.negotiating, "Checking exact tablet mode and hardware codecs")
    try valid(attempt)
    let config = try SessionNegotiator.negotiate(
      greeting, preferences: preferences,
      hardwareProbe: VideoEncoder.probe)
    try valid(attempt)
    await state(.creatingDisplay, "Publishing exact virtual display")
    if display == nil {
      let manager = await MainActor.run { VirtualDisplayManager() }
      try valid(attempt)
      display = manager
    }
    guard let display else { throw HostFailure.exactDisplay }
    let active = try await display.create(logicalSize: preferences.logicalSize)
    do { try valid(attempt) } catch {
      await display.destroy()
      throw error
    }
    snapshot.virtualMode =
      "\(active.logicalSize.width)x\(active.logicalSize.height) logical, 2456x1600 backing @ \(active.refreshHz) Hz (verified)"
    return (config, active)
  }

  private func awaitClientBarrier(
    channel: WireConnection, route: any HostConnectionRoute, order initialOrder: WireOrder,
    config: NegotiatedConfig, attempt: AttemptIdentity
  ) async throws -> VideoBarrier {
    var order = initialOrder
    await state(.preparingClient, "Waiting for client's mode and decoder readback")
    try valid(attempt)
    try await channel.send(
      HostCommand.configuration(config).wire(sessionId: sessionId, epoch: epoch))
    let videoChannel = try await acceptChannel(
      from: route, incarnation: attempt.incarnation, epoch: attempt.epoch, videoChannel: true)
    guard case .message(let videoHello) = try await videoChannel.read(),
      videoHello.type == MessageKind.videoHello.rawValue
    else {
      throw HostFailure.malformed
    }
    var videoOrder = WireOrder(
      receivingFrom: .client, on: .video,
      epoch: UInt64(attempt.epoch), sessionId: sessionId)
    try valid(attempt)
    try videoOrder.accept(videoHello)
    guard
      case .videoHello(let videoToken, let videoId, let videoEpoch) =
        try ClientEvent.decode(videoHello),
      Authenticator.equals(videoToken, token), videoId == sessionId,
      videoEpoch == attempt.epoch
    else { throw HostFailure.unauthorized }
    guard case .message(let ready) = try await channel.read() else { throw HostFailure.malformed }
    try valid(attempt)
    try order.accept(ready)
    guard case .ready(let readiness) = try ClientEvent.decode(ready), readiness.isExact else {
      throw HostFailure.incompatible
    }
    try valid(attempt)
    snapshot.clientMode = "1600x2456 @ \(readiness.mode.milliHz / 1000) Hz (client readback)"
    snapshot.video =
      "Requested hardware \(config.codec == .avc ? "AVC" : "HEVC") \(config.bitrate / 1_000_000) Mbit/s"
    return VideoBarrier(channel: videoChannel, order: order, route: route)
  }

  private func beginStreaming(
    controlChannel channel: WireConnection, barrier: VideoBarrier,
    config: NegotiatedConfig, active: ActiveDisplay, attempt: AttemptIdentity
  ) async throws {
    let id = attempt.incarnation
    generation += 1
    let nextGeneration = generation
    let channelEpoch = epoch
    let stageMetrics = MetricsCollector()
    metrics = stageMetrics
    let stageTiming = HostVideoTiming(epoch: channelEpoch, generation: nextGeneration)
    videoTiming = stageTiming
    let trace = HostLatencyTrace(
      sessionId: sessionId, epoch: channelEpoch, generation: nextGeneration)
    latencyTrace = trace
    timingReportSamples = 0
    timingReportLockMaxNs = 0
    timingReportFormatMaxNs = 0
    timingReportLogMaxNs = 0
    let sink = MirriVideoSink(
      channel: barrier.channel, sessionId: sessionId, epoch: channelEpoch,
      generation: nextGeneration, config: config, latencyTrace: trace)
    let pipeline = CapturePipeline(
      settings: EncodingSettings(codec: config.codec, bitrate: config.bitrate),
      sink: sink, timing: stageTiming, latencyTrace: trace,
      onFailure: { [weak self] cause in
        Task {
          await self?.failTransport(
            id: id, channelEpoch: channelEpoch, source: "pipeline-\(cause.rawValue)")
        }
      },
      onReceived: { stageMetrics.captured() },
      onCompleteCadence: { stageMetrics.completeFrame(gapMilliseconds: $0) },
      onPendingSample: { event, depth in stageMetrics.pendingSample(event, depth: depth) },
      onCaptured: { stageMetrics.admittedFrame() },
      onRejected: { stageMetrics.rejectedFrame($0) },
      onEncodeSubmit: { stageMetrics.encoderSubmission(milliseconds: $0) },
      onEncoded: { count, latency in
        stageMetrics.encodedFrame(bytes: count, latency: latency)
      },
      onSent: { count, submitAge, convertAge in
        stageMetrics.sentFrame(bytes: count, submitAgeMs: submitAge, convertAgeMs: convertAge)
      })
    capture = pipeline
    try await channel.send(
      HostCommand.start(generation: nextGeneration).wire(sessionId: sessionId, epoch: epoch))
    try valid(attempt)
    try await pipeline.start(display: active)
    try valid(attempt)
    let startedNs = DispatchTime.now().uptimeNanoseconds
    stageTiming.activate(atNs: startedNs)
    trace.activate(atNs: startedNs)
    snapshot.video =
      "Hardware \(config.codec == .avc ? "AVC" : "HEVC") \(config.bitrate / 1_000_000) Mbit/s (configured)"
    input = InputController(
      display: active, zoom: preferences.zoom,
      auxiliaryAction: preferences.auxiliaryAction)
    reconnectUntil = nil
    await state(.streaming, barrier.route.streamingDescription)
    try valid(attempt)
    tick?.cancel()
    tick = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(1))
        await self?.updateMetrics(id: id, channelEpoch: channelEpoch)
      }
    }
    controlReader = Task { [weak self] in
      await self?.readControl(channel, order: barrier.order, id: id, channelEpoch: channelEpoch)
    }
  }
  func expireHandshake(incarnation id: UInt64, epoch expectedEpoch: UInt32) async {
    guard incarnation == id, epoch == expectedEpoch, snapshot.state != .streaming,
      snapshot.state != .stopping
    else { return }
    let oldRoute = route
    let oldControl = control
    let oldVideo = video
    await oldRoute?.interrupt()
    await oldControl?.close()
    await oldVideo?.close()
    await rtcPeer?.stop()
  }
  private func updateMetrics(id: UInt64, channelEpoch: UInt32) async {
    guard incarnation == id, epoch == channelEpoch, snapshot.state == .streaming else { return }
    if let rtcPeer {
      let media = await rtcPeer.mediaStatus()
      guard media == .ready else {
        logger.diagnostic("rtc-media-\(media.rawValue)")
        await terminal(media == .codecOrGeometry ? .hardwareCodec : .transport)
        return
      }
      let rtt = rtcRttMs.map { String(format: "%.1f ms", $0) } ?? "unavailable"
      snapshot.metrics = rtcPeer.metricsSummary()
        + " / control RTT \(rtt) / tablet-display and cross-device one-way latency unavailable"
      logger.metrics(snapshot.metrics)
    } else {
      let reports = metrics.snapshotWithPending(queue: capture?.queueDepth ?? 0)
      snapshot.metrics = reports.summary
      logger.metrics(snapshot.metrics)
      logger.metrics(reports.pending)
    }
    if let videoTiming {
      let measured = videoTiming.snapshotMeasured()
      let logStart = DispatchTime.now().uptimeNanoseconds
      logger.metrics(measured.line)
      let logNs = DispatchTime.now().uptimeNanoseconds - logStart
      timingReportSamples += 1
      timingReportLockMaxNs = max(timingReportLockMaxNs, measured.lockNs)
      timingReportFormatMaxNs = max(timingReportFormatMaxNs, measured.formatNs)
      timingReportLogMaxNs = max(timingReportLogMaxNs, logNs)
      if timingReportSamples == 10 {
        logger.metrics(
          "videoTimingReport epoch=\(channelEpoch) samples=10 "
            + "lockMaxUs=\(timingReportLockMaxNs / 1_000) formatMaxUs=\(timingReportFormatMaxNs / 1_000) "
            + "logMaxUs=\(timingReportLogMaxNs / 1_000)")
        timingReportSamples = 0
        timingReportLockMaxNs = 0
        timingReportFormatMaxNs = 0
        timingReportLogMaxNs = 0
      }
    }
    if let latencyTrace { logger.metrics(latencyTrace.report()) }
    await status(snapshot)
    guard incarnation == id, epoch == channelEpoch, snapshot.state == .streaming else { return }
    let now = DispatchTime.now().uptimeNanoseconds
    if let pendingPing, now - pendingPing.sent > 5_000_000_000 {
      await failTransport(id: id, channelEpoch: channelEpoch, source: "heartbeat-timeout")
      return
    }
    guard pendingPing == nil else { return }
    if let control, pingSequence < UInt64.max {
      let sequence = pingSequence
      pingSequence += 1
      let sent = now
      pendingPing = (sequence, sent)
      do {
        let ping = HostCommand.ping(sequence: sequence, sent: sent).wire(
          sessionId: sessionId, epoch: epoch)
        if let rtcWriter { try await rtcWriter.send(ping) }
        else { try await control.send(ping) }
      } catch {
        await failTransport(id: id, channelEpoch: channelEpoch, source: "heartbeat-send")
      }
    }
  }
  private func readControl(
    _ channel: WireConnection, order initial: WireOrder, id: UInt64,
    channelEpoch: UInt32
  ) async {
    var order = initial
    do {
      while (incarnation == id && epoch == channelEpoch && snapshot.state == .streaming)
        || (stopAckReaderId == id && snapshot.state == .stopping)
      {
        let record = try await channel.read()
        switch record {
        case .skipped(let seq): try order.skipUnknown(sequence: seq)
        case .message(let message):
          try order.accept(message)
          let event = try ClientEvent.decode(message)
          if case .stopAcknowledged = event, stopAckReaderId == id {
            stopAckReceived = true
            stopAckReaderId = nil
            stopAckContinuation?.resume()
            stopAckContinuation = nil
            return
          }
          try await handleClientEvent(
            event, attempt: AttemptIdentity(incarnation: id, epoch: channelEpoch))
        }
      }
    } catch {
      guard incarnation == id, epoch == channelEpoch, snapshot.state == .streaming else { return }
      if let failure = error as? HostFailure, failure != .transport {
        await terminal(failure)
      } else if error is WireFailure {
        await terminal(.malformed)
      } else {
        await failTransport(id: id, channelEpoch: channelEpoch, source: "control-read")
      }
    }
  }
  private func readRtcControl(
    _ channel: WireConnection, order initial: WireOrder, attempt: AttemptIdentity
  ) async {
    var order = initial
    var lastKind: UInt16 = 0
    do {
      while incarnation == attempt.incarnation, epoch == attempt.epoch,
        snapshot.state == .streaming || snapshot.state == .preparingClient ||
          stopAckReaderId == attempt.incarnation
      {
        let record = try await channel.read()
        switch record {
        case .skipped(let sequence): try order.skipUnknown(sequence: sequence)
        case .message(let message):
          lastKind = message.type
          if (23...31).contains(message.type), message.fields.count >= 2,
            (try RtcSignal.number(message.fields[1])) < UInt64(attempt.epoch) {
            try order.skipStaleRtc(message)
            continue
          }
          try order.accept(message)
          if message.type == MessageKind.stopAcknowledged.rawValue,
            stopAckReaderId == attempt.incarnation {
            stopAckReceived = true
            stopAckReaderId = nil
            stopAckContinuation?.resume()
            stopAckContinuation = nil
            return
          }
          if message.type == MessageKind.rtcIceCandidate.rawValue ||
            message.type == MessageKind.rtcIceEnd.rawValue {
            try await rtcRemoteIce(message, attempt: attempt)
          } else {
            guard snapshot.state == .streaming else { throw HostFailure.malformed }
            guard [.inputBatch, .scroll, .zoom, .contextClick, .shortcut,
              .auxiliaryKey, .pong, .stopAcknowledged, .protocolError,
              .sessionRejected].contains(MessageKind(rawValue: message.type)) else {
              throw HostFailure.malformed
            }
            let event = try ClientEvent.decode(message)
            try await handleClientEvent(event, attempt: attempt)
          }
        }
      }
    } catch {
      logger.diagnostic("rtc-control-rejected-kind-\(lastKind)-error-\(type(of: error))"
        + "-host=\((error as? HostFailure).map(String.init(describing:)) ?? "none")")
      if incarnation == attempt.incarnation, epoch == attempt.epoch,
        snapshot.state == .streaming {
        await terminal((error as? WireFailure) == .unsupported ? .version : .malformed)
      }
      else if incarnation == attempt.incarnation, epoch == attempt.epoch,
        snapshot.state == .preparingClient {
        rtcFailure = true
        await channel.close()
      }
    }
  }
  private func handleClientEvent(
    _ event: ClientEvent, attempt: AttemptIdentity
  ) async throws {
    guard incarnation == attempt.incarnation, epoch == attempt.epoch,
      snapshot.state == .streaming
    else { return }
    switch event {
    case .input(let action):
      try input?.handle(action)
      metrics.inputMessage()
    case .metrics(let report):
      guard report.mode.isExact else {
        throw HostFailure.incompatible
      }
      metrics.clientMetrics(report)
    case .requestKeyframe:
      logger.diagnostic("client-keyframe-request")
      // A codec generation must restart for any decoder resynchronization.
      throw HostFailure.transport
    case .decoderFailure:
      logger.diagnostic("client-decoder-failure")
      decoderFailures += 1
      guard decoderFailures <= 1 else { throw HostFailure.hardwareCodec }
      throw HostFailure.transport
    case .pong(let sequence, let sent, let received, let replied):
      if let pendingPing, sequence == pendingPing.sequence, sent == pendingPing.sent {
        let now = DispatchTime.now().uptimeNanoseconds
        if rtcPeer != nil { rtcRttMs = Double(now - sent) / 1e6 }
        else { metrics.roundTrip(milliseconds: Double(now - sent) / 1e6) }
        latencyTrace?.pong(
          sequence: sequence, t1: sent, t2: received, t3: replied, t4: now)
        self.pendingPing = nil
      }
    case .stopAcknowledged: break
    case .rejection: throw HostFailure.incompatible
    default: throw HostFailure.malformed
    }
  }
  private func failTransport(id: UInt64, channelEpoch: UInt32, source: String) async {
    guard incarnation == id, epoch == channelEpoch, snapshot.state == .streaming else { return }
    logger.diagnostic("transport-\(source)")
    await transportClosed(id: id, channelEpoch: channelEpoch)
  }
  public func transportClosed(id: UInt64, channelEpoch: UInt32) async {
    guard incarnation == id, epoch == channelEpoch, snapshot.state == .streaming else { return }
    if rtcPeer != nil { await terminal(.transport); return }
    // Claim transition before any await: EOF, encoder callbacks and ping timeouts
    // may arrive together, but exactly one cleanup owns this epoch.
    snapshot.state = .waitingForReconnect
    videoTiming?.freeze()
    latencyTrace?.freeze()
    reconnectUntil = ContinuousClock.now.advanced(by: .seconds(preferences.graceSeconds))
    input?.reset()
    input = nil
    controlReader?.cancel()
    controlReader = nil
    let oldCapture = capture
    capture = nil
    let oldTiming = videoTiming
    videoTiming = nil
    let oldTrace = latencyTrace
    latencyTrace = nil
    let oldControl = control
    control = nil
    let oldVideo = video
    video = nil
    authenticatedControl = false
    pendingPing = nil
    tick?.cancel()
    tick = nil
    metrics.reset()
    let teardown = Task {
      await oldCapture?.stop()
      if let oldTiming { logger.metrics(oldTiming.finish()) }
      if let oldTrace { logger.metrics(oldTrace.report(final: true)) }
      await oldControl?.close()
      await oldVideo?.close()
    }
    teardownTask = teardown
    await teardown.value
    guard incarnation == id, epoch == channelEpoch,
      snapshot.state == .waitingForReconnect
    else { return }
    await state(.waitingForReconnect, "Connection lost; retaining display for bounded grace")
    guard incarnation == id, epoch == channelEpoch,
      snapshot.state == .waitingForReconnect
    else { return }
    reconnectTask = Task { [weak self] in await self?.reconnectLoop(id: id) }
  }
  private func reconnectLoop(id: UInt64) async {
    while incarnation == id && snapshot.state == .waitingForReconnect,
      let deadline = reconnectUntil, ContinuousClock.now < deadline
    {
      guard epoch < UInt32.max else { break }
      epoch += 1
      let retryEpoch = epoch
      do {
        guard let route else { throw HostFailure.transport }
        try await route.retry()
        try valid(id, epoch: retryEpoch)
        try await route.bootstrap(
          AttemptCredentials(token: token, sessionId: sessionId, epoch: retryEpoch))
        try valid(id, epoch: retryEpoch)
        try await handshake(id: id)
        return
      } catch {
        guard incarnation == id, epoch == retryEpoch,
          snapshot.state != .stopping && snapshot.state != .idle
        else { return }
        if let failure = error as? HostFailure {
          switch failure {
          case .unauthorized, .malformed, .version, .incompatible, .exactDisplay, .hardwareCodec,
            .permission:
            await terminal(failure)
            return
          default: break
          }
        } else if error is WireFailure {
          await terminal(.malformed)
          return
        }
        input?.reset()
        input = nil
        let oldCapture = capture
        capture = nil
        let oldTiming = videoTiming
        videoTiming = nil
        let oldTrace = latencyTrace
        latencyTrace = nil
        let oldControl = control
        control = nil
        let oldVideo = video
        video = nil
        authenticatedControl = false
        let oldRoute = route
        let teardown = Task {
          await oldCapture?.stop()
          if let oldTiming { logger.metrics(oldTiming.finish()) }
          if let oldTrace { logger.metrics(oldTrace.report(final: true)) }
          await oldControl?.close()
          await oldVideo?.close()
        }
        teardownTask = teardown
        await oldRoute?.interrupt()
        await teardown.value
        guard incarnation == id, epoch == retryEpoch,
          snapshot.state != .stopping
        else { return }
        if incarnation == id {
          await state(.waitingForReconnect, "Retrying within display grace period")
        }
      }
      try? await Task.sleep(for: .seconds(1))
    }
    if incarnation == id { await terminal(.timeout) }
  }
  public func reconnect() async {
    guard snapshot.state == .streaming else { return }
    await transportClosed(id: incarnation, channelEpoch: epoch)
  }
  public func stop() async {
    if snapshot.state == .stopping {
      // App termination and repeated Stop calls must not race the owner to process exit.
      guard let completion = lifecycleCompletion else {
        preconditionFailure("stopping lifecycle has no completion task")
      }
      await completion.value
      return
    }
    guard snapshot.state != .idle else { return }
    let readerId = incarnation
    if snapshot.state == .streaming, control != nil { stopAckReaderId = readerId }
    stopAckReceived = false
    incarnation &+= 1
    let transition = incarnation
    snapshot.state = .stopping
    videoTiming?.freeze()
    latencyTrace?.freeze()
    input?.reset()
    input = nil
    let completion = Task { await self.completeStop(transition: transition, readerId: readerId) }
    lifecycleCompletion = completion
    await completion.value
  }
  private func completeStop(transition: UInt64, readerId: UInt64) async {
    await state(.stopping, "Stopping stream, releasing input and owned resources")
    if let control, incarnation == transition {
      if let rtcWriter {
        try? await rtcWriter.send(HostCommand.stop.wire(sessionId: sessionId, epoch: epoch))
      } else {
        try? await control.send(HostCommand.stop.wire(sessionId: sessionId, epoch: epoch))
      }
      if stopAckReaderId == readerId { await awaitStopAck(transition: transition) }
    }
    guard incarnation == transition else { return }
    await release()
    if incarnation == transition { await state(.idle, "Stopped") }
  }
  private func awaitStopAck(transition: UInt64) async {
    if stopAckReceived { return }
    let timeout = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(500))
      if !Task.isCancelled { await self?.expireStopAck(transition: transition) }
    }
    defer { timeout.cancel() }
    await withCheckedContinuation { continuation in
      if stopAckReceived || stopAckReaderId == nil {
        continuation.resume()
      } else {
        stopAckContinuation = continuation
      }
    }
  }
  private func expireStopAck(transition: UInt64) {
    guard incarnation == transition, snapshot.state == .stopping else { return }
    stopAckReaderId = nil
    stopAckContinuation?.resume()
    stopAckContinuation = nil
  }
  private func terminal(_ failure: HostFailure) async {
    guard snapshot.state != .stopping else { return }
    incarnation &+= 1
    let transition = incarnation
    snapshot.state = .stopping
    videoTiming?.freeze()
    latencyTrace?.freeze()
    input?.reset()
    input = nil
    logger.error(failure)
    let completion = Task {
      await self.completeTerminal(failure, transition: transition)
    }
    lifecycleCompletion = completion
    await completion.value
  }
  private func completeTerminal(_ failure: HostFailure, transition: UInt64) async {
    if authenticatedControl, let control {
      let code: UInt64 =
        switch failure {
        case .incompatible, .exactDisplay: 4
        case .hardwareCodec: 5
        case .timeout: 8
        case .malformed: 1
        case .version: 2
        case .unauthorized: 3
        default: 6
        }
      let record = HostCommand.error(code: code, description: failure.localizedDescription).wire(
        sessionId: sessionId, epoch: epoch)
      if let rtcWriter { try? await rtcWriter.send(record) }
      else { try? await control.send(record) }
    }
    if incarnation == transition { await state(.stopping, failure.localizedDescription) }
    guard incarnation == transition else { return }
    await release()
    if incarnation == transition { await state(.failed, failure.localizedDescription) }
  }
  private func release() async {
    rtcTimer?.cancel(); rtcTimer = nil
    rtcEvents?.cancel(); rtcEvents = nil
    let oldPeer = rtcPeer; rtcPeer = nil
    rtcWriter = nil
    rtcAttempt = Data()
    rtcCandidates = []
    rtcRemote = RtcIceLedger()
    rtcOfferWritten = false
    rtcRttMs = nil
    tick?.cancel()
    tick = nil
    controlReader?.cancel()
    controlReader = nil
    stopAckReaderId = nil
    stopAckContinuation?.resume()
    stopAckContinuation = nil
    reconnectTask?.cancel()
    reconnectTask = nil
    input?.reset()
    input = nil
    let oldCapture = capture
    capture = nil
    let oldTiming = videoTiming
    videoTiming = nil
    let oldTrace = latencyTrace
    latencyTrace = nil
    let oldVideo = video
    video = nil
    let oldControl = control
    control = nil
    authenticatedControl = false
    let oldRoute = route
    route = nil
    let oldDisplay = display
    display = nil
    let pendingTeardown = teardownTask
    teardownTask = nil
    token.removeAll()
    sessionId.removeAll()
    reconnectUntil = nil
    await pendingTeardown?.value
    await oldPeer?.stop()
    await oldCapture?.stop()
    if let oldTiming { logger.metrics(oldTiming.finish()) }
    if let oldTrace { logger.metrics(oldTrace.report(final: true)) }
    await oldVideo?.close()
    await oldControl?.close()
    await oldDisplay?.destroy()
    await oldRoute?.close()
    snapshot.virtualMode = "Not active (requested 2456x1600 @ 60 Hz)"
    snapshot.clientMode = "Not reported (required 1600x2456 @ 60 or 120 Hz)"
  }
}
