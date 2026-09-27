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
        await terminal(error as? HostFailure ?? (error is WireFailure ? .malformed : .transport))
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
      } ?? .seconds(10)
    let timeout = Task { [weak self] in
      try? await Task.sleep(for: budget)
      if !Task.isCancelled {
        await self?.expireHandshake(incarnation: attempt.incarnation, epoch: attempt.epoch)
      }
    }
    defer { timeout.cancel() }
    let authenticated = try await acceptAuthenticatedControl(route, attempt: attempt)
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
    snapshot.clientMode = "1600x2456 @ 60 Hz (client readback)"
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
    timingReportSamples = 0
    timingReportLockMaxNs = 0
    timingReportFormatMaxNs = 0
    timingReportLogMaxNs = 0
    let sink = MirriVideoSink(
      channel: barrier.channel, sessionId: sessionId, epoch: channelEpoch,
      generation: nextGeneration, config: config)
    let pipeline = CapturePipeline(
      settings: EncodingSettings(codec: config.codec, bitrate: config.bitrate),
      sink: sink, timing: stageTiming,
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
    stageTiming.activate()
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
  }
  private func updateMetrics(id: UInt64, channelEpoch: UInt32) async {
    guard incarnation == id, epoch == channelEpoch, snapshot.state == .streaming else { return }
    let reports = metrics.snapshotWithPending(queue: capture?.queueDepth ?? 0)
    snapshot.metrics = reports.summary
    logger.metrics(snapshot.metrics)
    logger.metrics(reports.pending)
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
        try await control.send(
          HostCommand.ping(sequence: sequence, sent: sent).wire(
            sessionId: sessionId, epoch: epoch))
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
    case .pong(let sequence, let sent):
      if let pendingPing, sequence == pendingPing.sequence, sent == pendingPing.sent {
        let now = DispatchTime.now().uptimeNanoseconds
        metrics.roundTrip(milliseconds: Double(now - sent) / 1e6)
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
    // Claim transition before any await: EOF, encoder callbacks and ping timeouts
    // may arrive together, but exactly one cleanup owns this epoch.
    snapshot.state = .waitingForReconnect
    videoTiming?.freeze()
    reconnectUntil = ContinuousClock.now.advanced(by: .seconds(preferences.graceSeconds))
    input?.reset()
    input = nil
    controlReader?.cancel()
    controlReader = nil
    let oldCapture = capture
    capture = nil
    let oldTiming = videoTiming
    videoTiming = nil
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
          case .unauthorized, .malformed, .incompatible, .exactDisplay, .hardwareCodec,
            .permission, .reverseConflict:
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
        let oldControl = control
        control = nil
        let oldVideo = video
        video = nil
        authenticatedControl = false
        let oldRoute = route
        let teardown = Task {
          await oldCapture?.stop()
          if let oldTiming { logger.metrics(oldTiming.finish()) }
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
    input?.reset()
    input = nil
    let completion = Task { await self.completeStop(transition: transition, readerId: readerId) }
    lifecycleCompletion = completion
    await completion.value
  }
  private func completeStop(transition: UInt64, readerId: UInt64) async {
    await state(.stopping, "Stopping stream, releasing input and owned resources")
    if let control, incarnation == transition {
      try? await control.send(HostCommand.stop.wire(sessionId: sessionId, epoch: epoch))
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
        case .unauthorized: 3
        default: 6
        }
      try? await control.send(
        HostCommand.error(code: code, description: failure.localizedDescription).wire(
          sessionId: sessionId, epoch: epoch))
    }
    if incarnation == transition { await state(.stopping, failure.localizedDescription) }
    guard incarnation == transition else { return }
    await release()
    if incarnation == transition { await state(.failed, failure.localizedDescription) }
  }
  private func release() async {
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
    await oldCapture?.stop()
    if let oldTiming { logger.metrics(oldTiming.finish()) }
    await oldVideo?.close()
    await oldControl?.close()
    await oldDisplay?.destroy()
    await oldRoute?.close()
    snapshot.virtualMode = "Not active (requested 2456x1600 @ 60 Hz)"
    snapshot.clientMode = "Not reported (required 1600x2456 @ 60 Hz)"
  }
}
