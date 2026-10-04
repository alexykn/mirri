package dev.mirri.client.session

import android.app.Activity
import android.util.Log
import android.view.Surface
import dev.mirri.client.display.DisplaySurfaceController
import dev.mirri.client.model.DeviceCapabilitiesCollector
import dev.mirri.client.protocol.ClientCommand
import dev.mirri.client.protocol.ControlChannel
import dev.mirri.client.protocol.HostEvent
import dev.mirri.client.protocol.InputEvent
import dev.mirri.client.protocol.MessageType
import dev.mirri.client.protocol.NetworkBootstrap
import dev.mirri.client.protocol.PhysicalMode
import dev.mirri.client.protocol.RtcIceLedger
import dev.mirri.client.protocol.RtcSignals
import dev.mirri.client.protocol.RtcStartupGate
import dev.mirri.client.protocol.SessionConfiguration
import dev.mirri.client.protocol.SessionMessages
import dev.mirri.client.protocol.Value
import dev.mirri.client.protocol.VideoChannel
import dev.mirri.client.protocol.VideoReceiver
import dev.mirri.client.protocol.WireException
import dev.mirri.client.protocol.WireMessage
import dev.mirri.client.protocol.WireOrder
import dev.mirri.client.protocol.openVideo
import dev.mirri.client.protocol.receiveRtcControl
import dev.mirri.client.transport.PeerAuthenticationException
import dev.mirri.client.transport.blockingBytes
import dev.mirri.client.video.CodecCapabilityProbe
import dev.mirri.client.video.DecoderChoice
import dev.mirri.client.video.DecoderController
import dev.mirri.client.video.DecoderFailure
import dev.mirri.client.video.EncodedBufferPool
import dev.mirri.client.video.RtcHardwareDecoder
import dev.mirri.client.video.RtcReceiver
import dev.mirri.client.video.TimingLogMessage
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.cancel
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withTimeoutOrNull
import org.webrtc.SurfaceViewRenderer
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import kotlin.math.roundToInt

enum class ClientSessionState {
    IDLE,
    WAITING_FOR_SURFACE,
    CONNECTING_CONTROL,
    NEGOTIATING,
    CONFIGURING_DISPLAY,
    CONFIGURING_DECODER,
    CONNECTING_VIDEO,
    STREAMING,
    RECONNECTING,
    STOPPING,
    FAILED,
}

data class ClientStatus(
    val state: ClientSessionState,
    val note: String,
)

object ReconnectPolicy {
    fun delayMs(attempt: Int): Long = (250L shl attempt.coerceIn(0, 5)).coerceAtMost(8000)
}

/** Exclusive lifecycle owner. Only this class closes sockets or stops the decoder. */
class SessionController(
    private val activity: Activity,
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val mutableStatus = MutableStateFlow(ClientStatus(ClientSessionState.IDLE, "Not connected"))
    val status = mutableStatus.asStateFlow()
    private val display = DisplaySurfaceController(activity)
    private val encodedBuffers = EncodedBufferPool()
    private var surface: Surface? = null
    private var surfaceWidth = 0
    private var surfaceHeight = 0
    private var rtcRenderer: SurfaceViewRenderer? = null
    private var launch: ClientLaunch? = null
    private var job: Job? = null
    private var terminalLaunch = false

    /** With a paired host the tablet can ask for a new session, so it stops retrying a dead one sooner. */
    var pairedHost = false
    private var refused = false

    @Volatile
    private var attempt: ClientAttempt? = null
    private val dropped = AtomicLong()

    // Across attempts in this activity, repeated codec failures are terminal;
    // the first-failure gate and frame/queue counters belong to ClientAttempt.
    private val decoderFailures = AtomicInteger()

    private data class PreparedSession(
        val surface: Surface,
        val channel: ControlChannel,
        val config: SessionConfiguration,
        val choice: DecoderChoice,
        val mode: PhysicalMode,
        val first: WireMessage,
    )

    private data class ActiveStream(
        val video: VideoChannel,
        val order: WireOrder,
    )

    private enum class AttemptResult { CONNECTED, RETRY, TERMINAL }

    private fun state(
        value: ClientSessionState,
        note: String,
    ) {
        Log.i("MirriLifecycle", "state=${value.name}")
        mutableStatus.value = ClientStatus(value, note)
    }

    fun start(value: ClientLaunch) {
        Log.i("MirriLifecycle", "start surfacePresent=${surface != null}")
        terminalLaunch = false
        launch = value
        if (surface == null) state(ClientSessionState.WAITING_FOR_SURFACE, "Waiting for landscape SurfaceView") else restart()
    }

    fun setRtcRenderer(renderer: SurfaceViewRenderer) {
        rtcRenderer = renderer
    }

    fun onSurfaceAvailable(
        value: Surface,
        width: Int,
        height: Int,
    ) {
        if (surface === value && surfaceWidth == width && surfaceHeight == height) return
        surface = value
        surfaceWidth = width
        surfaceHeight = height
        if (launch != null && !terminalLaunch) restart()
    }

    fun onSurfaceDestroyed() {
        surface = null
        job?.cancel()
        attempt?.interrupt()
        if (!terminalLaunch) state(ClientSessionState.WAITING_FOR_SURFACE, "Surface lost; releasing decoder")
    }

    private fun restart() {
        if (terminalLaunch) return
        val previous = job
        previous?.cancel()
        attempt?.interrupt()
        job =
            scope.launch {
                previous?.cancelAndJoin()
                run()
            }
    }

    fun onInput(message: InputEvent) {
        val owner = attempt?.takeIf { it.streaming } ?: return
        val id = owner.id ?: return
        val batch = if (message is InputEvent.Pointers) owner.inputBatchSequence++.also { check(it < ULong.MAX_VALUE) } else 0uL
        if (owner.control?.let { send(it, id, owner.epoch, ClientCommand.Input(message, batch)) } != true) {
            job?.cancel()
            owner.interrupt()
            state(ClientSessionState.FAILED, "Control queue congested")
        }
    }

    fun stop() {
        launch = null
        terminalLaunch = false
        job?.cancel()
        job = null
        attempt?.interrupt()
        scope.cancel()
        state(ClientSessionState.IDLE, "Stopped")
    }

    private suspend fun sendAndWait(
        channel: ControlChannel,
        id: ByteArray,
        epoch: UInt,
        command: ClientCommand,
    ) {
        val (type, fields) = command.fields(id, epoch)
        channel.sendAndWait(type.id, fields)
    }

    private fun send(
        channel: ControlChannel,
        id: ByteArray,
        epoch: UInt,
        command: ClientCommand,
    ): Boolean {
        val (type, fields) = command.fields(id, epoch)
        return channel.send(type.id, fields)
    }

    private suspend fun run() {
        var retryCount = 0
        var refusals = 0
        var terminal = false
        while (scope.isActive && hasActiveSession() && !terminal) {
            val spec = requireNotNull(launch)
            val owner = ClientAttempt()
            attempt = owner
            refused = false
            when (runAttempt(spec, owner)) {
                AttemptResult.CONNECTED -> retryCount = 0
                AttemptResult.RETRY -> Unit
                AttemptResult.TERMINAL -> {
                    terminal = true
                    terminalLaunch = true
                }
            }
            if (!terminal && hasActiveSession()) {
                // A reachable host that twice refuses the control port has ended this session.
                refusals = if (refused) refusals + 1 else 0
                if (pairedHost && refusals >= 2) {
                    state(ClientSessionState.FAILED, "Host ended the session")
                    terminal = true
                    terminalLaunch = true
                    continue
                }
                delay(ReconnectPolicy.delayMs(retryCount++))
                if (retryCount > if (pairedHost) 8 else 16) {
                    state(ClientSessionState.FAILED, "Reconnect window expired")
                    terminal = true
                    terminalLaunch = true
                }
            }
        }
        if (scope.isActive && launch == null) state(ClientSessionState.IDLE, "Host stopped session")
    }

    private fun hasActiveSession(): Boolean = surface != null && launch != null

    // Exceptions from the external codec/socket stack must be classified after owner cleanup.
    @Suppress("TooGenericExceptionCaught", "SwallowedException")
    private suspend fun runAttempt(
        spec: ClientLaunch,
        owner: ClientAttempt,
    ): AttemptResult =
        try {
            connectOnce(spec, owner)
            AttemptResult.CONNECTED
        } catch (e: TimeoutCancellationException) {
            rtcFailureNotice(spec, owner, 8)
            state(ClientSessionState.FAILED, "RTC negotiation timeout")
            AttemptResult.TERMINAL
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            if (spec.media == NetworkMedia.RTC) Log.i("MirriLifecycle", "RTC attempt exception class=${e.javaClass.simpleName}")
            refused = e is java.net.ConnectException && e.message?.contains("ECONNREFUSED") == true
            // An RTC stream that was running and then lost its path or control
            // connection is retried on the host's next epoch, like a closed socket.
            val interrupted = spec.media == NetworkMedia.RTC && owner.reachedStreaming && e is WireException
            if (!interrupted) rtcFailureNotice(spec, owner, if (e.message?.contains("hardware", true) == true) 5 else 6)
            if (!interrupted && (e is DecoderFailure || e is PeerAuthenticationException || fatalProtocol(e))) {
                terminalLaunch = true
                state(ClientSessionState.FAILED, e.message ?: "Protocol rejected")
                AttemptResult.TERMINAL
            } else {
                state(
                    ClientSessionState.RECONNECTING,
                    "Network/host connection interrupted; retrying",
                )
                AttemptResult.RETRY
            }
        } finally {
            cleanupAttempt(owner)
        }

    private fun fatalProtocol(error: Exception): Boolean =
        error is WireException && error.message !in setOf("connection closed", "decoder failed")

    private suspend fun rtcFailureNotice(
        spec: ClientLaunch,
        owner: ClientAttempt,
        code: Int,
    ) {
        if (spec.media != NetworkMedia.RTC || !owner.active || !owner.rtcHelloSent) return
        val channel = owner.control ?: return
        val id = owner.id ?: return
        withTimeoutOrNull(300) {
            runCatching { sendAndWait(channel, id, owner.epoch, ClientCommand.ProtocolFailure(code)) }
        }
    }

    private suspend fun cleanupAttempt(owner: ClientAttempt) {
        try {
            owner.timing.endWindow()
            owner.timing.drainLatencyLine(final = true)?.let { Log.i("MirriLatencyTrace", it) }
            withContext(NonCancellable + Dispatchers.IO) { owner.close() }
        } finally {
            withContext(NonCancellable + Dispatchers.Main) {
                if (attempt === owner) {
                    Log.i("MirriTiming", TimingLogMessage.final(owner.timing))
                    attempt = null
                    display.detach()
                    if (surface == null && launch != null) {
                        state(ClientSessionState.WAITING_FOR_SURFACE, "Surface lost; decoder released")
                    }
                }
            }
        }
    }

    private suspend fun connectOnce(
        spec: ClientLaunch,
        owner: ClientAttempt,
    ) {
        val currentSurface = surface ?: return
        Log.i("MirriLifecycle", "precheck surface=${surfaceWidth}x$surfaceHeight valid=${currentSurface.isValid}")
        if (surfaceWidth != 2456 || surfaceHeight != 1600) throw WireException("exact landscape surface unavailable")
        if (spec.media == NetworkMedia.RTC) {
            connectRtc(spec, owner, currentSurface)
            return
        }
        val prepared = negotiateControl(spec, owner, currentSurface)
        val decoder = configureDecoder(owner, prepared)
        val active = awaitMediaBarrier(spec, owner, prepared)
        streamUntilClosed(owner, prepared, decoder, active)
    }

    // Display/framework readback failures require an explicit wire rejection, not a half-open attempt.
    @Suppress("TooGenericExceptionCaught")
    private suspend fun negotiateControl(
        spec: ClientLaunch,
        owner: ClientAttempt,
        currentSurface: Surface,
    ): PreparedSession {
        state(ClientSessionState.CONNECTING_CONTROL, "Connecting pinned TLS control")
        // The raw socket joins this attempt *before* blocking connect or a
        // cancellable IO -> Main handoff; finally closes it even if delivery fails.
        val bytes = spec.connector.connect(spec.endpoint.controlPort, owner.connections)
        // TLS pin and validity are checked by the connector before this token-bearing preface.
        val epoch = blockingBytes(bytes::close) { NetworkBootstrap.exchange(bytes, spec.token) }
        bytes.finishSetup()
        val channel =
            ControlChannel(bytes, scope) {
                owner.failure.trySend(it)
                bytes.close()
            }
        owner.control = channel
        // Every current epoch is learned over pinned TLS, not from the launch intent.
        owner.epoch = epoch
        owner.timing.setEpoch(epoch)
        // Pinned TLS and MRNB are verified before the display mode is touched.
        selectPreHelloSurface(currentSurface)
        state(ClientSessionState.NEGOTIATING, "Reporting exact display and decoder support")
        val hello = withContext(Dispatchers.Main) { DeviceCapabilitiesCollector.collect(activity, epoch, spec.token) }
        channel.sendAndWait(MessageType.CLIENT_HELLO.id, SessionMessages.clientHelloFields(hello))
        val first =
            blockingBytes(channel::close) { channel.read(WireOrder(WireOrder.Peer.HOST, WireOrder.Channel.CONTROL, epoch.toULong())) }
        val config =
            (SessionMessages.fromHost(first) as? HostEvent.Configure)?.config
                ?: throw WireException("expected SessionConfig")
        val id = config.id
        owner.id = id
        if (config.epoch != epoch || surfaceWidth != 2456 || surfaceHeight != 1600) {
            sendAndWait(channel, id, epoch, ClientCommand.Rejection(1, "Exact tablet surface unavailable"))
            throw WireException("exact surface/config mismatch")
        }
        val choice =
            CodecCapabilityProbe.choices().firstOrNull {
                it.matches(config.codec.wire, config.profile, config.level)
            }
        if (choice == null) {
            sendAndWait(channel, id, epoch, ClientCommand.Rejection(2, "Exact hardware decoder unavailable"))
            throw WireException("no exact hardware codec")
        }
        state(ClientSessionState.CONFIGURING_DISPLAY, "Selecting and reading back panel mode")
        val mode =
            try {
                withContext(Dispatchers.Main) {
                    display.selectAndVerify(currentSurface, "post-config", surfaceWidth, surfaceHeight)
                }
            } catch (e: CancellationException) {
                throw e
            } catch (
                e: Exception,
            ) {
                sendAndWait(channel, id, epoch, ClientCommand.Rejection(1, "Exact mode readback failed"))
                throw (e as? WireException ?: WireException("post-config exact mode readback failed", e))
            }
        val selected =
            PhysicalMode(
                mode.physicalWidth.toLong(),
                mode.physicalHeight.toLong(),
                (mode.refreshRate * 1000).roundToInt().toLong(),
                mode.modeId,
            )
        return PreparedSession(currentSurface, channel, config, choice, selected, first)
    }

    /** RTC branch: no legacy SessionConfig, decoder Surface codec or video socket. */
    @Suppress("CyclomaticComplexMethod", "ComplexCondition", "TooGenericExceptionCaught")
    private suspend fun connectRtc(
        spec: ClientLaunch,
        owner: ClientAttempt,
        currentSurface: Surface,
    ) {
        val session = spec.sessionId ?: throw WireException("RTC session ID missing")
        val renderer = rtcRenderer ?: throw WireException("RTC renderer missing")
        RtcHardwareDecoder.initialize(activity)
        val codecName =
            withContext(Dispatchers.IO) { RtcHardwareDecoder.probe()?.also(RtcHardwareDecoder::preflight) }
                ?: throw WireException("RTC High 5.2 hardware decoder unavailable")
        state(ClientSessionState.CONNECTING_CONTROL, "Connecting RTC pinned TLS control")
        val bytes = spec.connector.connect(spec.endpoint.controlPort, owner.connections)
        val epoch = blockingBytes(bytes::close) { NetworkBootstrap.exchange(bytes, spec.token) }
        bytes.finishSetup()
        val channel =
            ControlChannel(bytes, scope) {
                owner.failure.trySend(it)
                bytes.close()
            }
        owner.control = channel
        owner.epoch = epoch
        owner.id = session
        // Pinned TLS and MRNB are verified before the display mode is touched.
        selectPreHelloSurface(currentSurface)
        val hello = withContext(Dispatchers.Main) { DeviceCapabilitiesCollector.collect(activity, epoch, spec.token) }
        channel.sendAndWait(MessageType.CLIENT_HELLO.id, SessionMessages.clientHelloFields(hello))
        owner.rtcHelloSent = true
        val nonce = RtcSignals.nonce()
        channel.sendAndWait(
            MessageType.RTC_CAPABILITIES.id,
            listOf(
                Value.Bytes(session),
                Value.Number(epoch.toULong()),
                Value.Number(1uL),
                Value.Bytes(nonce),
                Value.Number(1uL),
                Value.Number(2uL),
                Value.Number(52uL),
                Value.Number(1uL),
                Value.Number(1uL),
            ),
        )
        val order = WireOrder(WireOrder.Peer.HOST, WireOrder.Channel.CONTROL, epoch.toULong(), session, rtc = true)
        val inbound = Channel<WireMessage>(80)
        val readJob =
            scope.launch(Dispatchers.IO) {
                try {
                    while (owner.active) inbound.send(blockingBytes(channel::close) { channel.read(order) })
                } catch (e: Exception) {
                    Log.i("MirriLifecycle", "RTC reader exception class=${e.javaClass.simpleName}")
                    val safeReason =
                        (e as? WireException)?.message?.takeIf {
                            it in setOf("invalid wire order", "stale connection", "malformed wire record", "unknown wire type")
                        }
                    if (safeReason != null) Log.i("MirriLifecycle", "RTC reader rejected $safeReason")
                    inbound.close(e)
                }
            }
        try {
            rtcPrepareAndRun(owner, channel, inbound, session, epoch, nonce, currentSurface, renderer, codecName)
        } finally {
            channel.close()
            readJob.cancelAndJoin()
        }
    }

    @Suppress("CyclomaticComplexMethod", "ComplexCondition", "TooGenericExceptionCaught")
    private suspend fun rtcPrepareAndRun(
        owner: ClientAttempt,
        channel: ControlChannel,
        inbound: Channel<WireMessage>,
        session: ByteArray,
        epoch: UInt,
        nonce: ByteArray,
        currentSurface: Surface,
        renderer: SurfaceViewRenderer,
        codecName: String,
    ) {
        val gate = RtcStartupGate()
        val prepare = withTimeout(10_000) { inbound.receive() }
        if (prepare.type != MessageType.RTC_PREPARE.id) throw WireException("RTC prepare expected")
        RtcSignals.check(prepare, session, epoch)
        val fields = prepare.fields
        if (!RtcSignals.bytes(fields[4]).contentEquals(nonce) ||
            RtcSignals.number(fields[5]) != 1uL ||
            RtcSignals.number(fields[6]) != 2uL ||
            RtcSignals.number(fields[7]) != 52uL ||
            RtcSignals.number(fields[10]) != 1uL
        ) {
            throw WireException("RTC High 5.2 prepare rejected")
        }
        val rtcAttempt = RtcSignals.bytes(fields[3])
        val prepareAt = System.nanoTime()
        val mode =
            try {
                withContext(Dispatchers.Main) {
                    display.selectAndVerify(currentSurface, "rtc-prepare", surfaceWidth, surfaceHeight)
                }
            } catch (e: Exception) {
                withTimeoutOrNull(
                    300,
                ) { runCatching { sendAndWait(channel, session, epoch, ClientCommand.Rejection(1, "Exact mode unavailable")) } }
                throw e
            }
        val selected =
            PhysicalMode(
                mode.physicalWidth.toLong(),
                mode.physicalHeight.toLong(),
                (mode.refreshRate * 1000).roundToInt().toLong(),
                mode.modeId,
            )
        val peer =
            RtcReceiver(renderer, codecName) { reason ->
                owner.failure.trySend(WireException(reason))
                owner.interrupt()
            }
        owner.rtc = peer
        val remainingMs = (9_000 - (System.nanoTime() - prepareAt) / 1_000_000).coerceAtLeast(1)
        try {
            withTimeout(remainingMs) { peer.prepare() }
        } catch (e: Exception) {
            withTimeoutOrNull(
                300,
            ) { runCatching { sendAndWait(channel, session, epoch, ClientCommand.Rejection(2, "RTC hardware unavailable")) } }
            throw e
        }
        channel.sendAndWait(
            MessageType.RTC_PREPARED.id,
            RtcSignals.fields(
                session,
                epoch,
                rtcAttempt,
                listOf(
                    Value.Object(
                        listOf(
                            Value.Object(listOf(Value.Number(1600uL), Value.Number(2456uL))),
                            Value.Number(60000uL),
                            Value.Signed(selected.identifier),
                        ),
                    ),
                    Value.Object(listOf(Value.Number(2456uL), Value.Number(1600uL))),
                    Value.Text(codecName),
                ),
            ),
        )
        Log.i("MirriLifecycle", "RTC prepared written")
        gate.prepared()
        val offer = withTimeout(10_000) { inbound.receive() }
        val offerAt = System.nanoTime()
        if (offer.type != MessageType.RTC_OFFER.id) throw WireException("RTC offer expected")
        Log.i("MirriLifecycle", "RTC offer received")
        RtcSignals.check(offer, session, epoch, rtcAttempt)
        gate.offered()
        val (mid, answer) = withTimeout(9_000) { peer.answer(RtcSignals.text(offer.fields[4])) }
        Log.i("MirriLifecycle", "RTC local answer created")
        val ledger = RtcIceLedger()
        channel.sendAndWait(MessageType.RTC_ANSWER.id, RtcSignals.fields(session, epoch, rtcAttempt, listOf(Value.Text(answer))))
        Log.i("MirriLifecycle", "RTC answer written")
        gate.answered()
        // This owner processes inbound trickle only after the offer has already
        // been applied. Open the ledger before draining queued control records;
        // otherwise it stages every candidate indefinitely instead of calling add().
        check(ledger.applied().isEmpty())
        runRtcMedia(owner, channel, inbound, peer, renderer, session, epoch, rtcAttempt, codecName, mid, ledger, offerAt, gate)
    }

    @Suppress("CyclomaticComplexMethod", "ComplexCondition", "NestedBlockDepth", "TooGenericExceptionCaught")
    private suspend fun runRtcMedia(
        owner: ClientAttempt,
        channel: ControlChannel,
        inbound: Channel<WireMessage>,
        peer: RtcReceiver,
        renderer: SurfaceViewRenderer,
        session: ByteArray,
        epoch: UInt,
        rtcAttempt: ByteArray,
        codecName: String,
        mid: String,
        ledger: RtcIceLedger,
        offerAt: Long,
        gate: RtcStartupGate,
    ) {
        val outgoing =
            scope.launch(Dispatchers.IO) {
                var count = 0
                try {
                    for (event in peer.events) {
                        if (!owner.active) break
                        when (event) {
                            is RtcReceiver.Event.Candidate -> {
                                if (count == 0) {
                                    val parts = event.sdp.split(' ')
                                    val udp = parts.size > 7 && parts[2].equals("udp", true)
                                    val host = parts.size > 7 && parts[6] == "typ" && parts[7] == "host"
                                    val v4 = parts.size > 7 && parts[4].matches(Regex("[0-9.]+")) && parts[4].count { it == '.' } == 3
                                    val wlan0 =
                                        parts.size > 7 &&
                                            runCatching {
                                                java.net.NetworkInterface.getByName("wlan0")?.inetAddresses?.toList()?.any {
                                                    it.hostAddress == parts[4]
                                                } == true
                                            }.getOrDefault(false)
                                    Log.i("MirriLifecycle", "RTC local ICE shape udp=$udp host=$host v4=$v4 wlan0=$wlan0")
                                }
                                if (++count > 64 || event.mid != mid || event.index != 0) {
                                    Log.i(
                                        "MirriLifecycle",
                                        "RTC local ICE boundary count=$count midMatches=${event.mid == mid} index=${event.index}",
                                    )
                                    throw WireException("RTC local ICE rejected")
                                }
                                channel.sendAndWait(
                                    MessageType.RTC_ICE_CANDIDATE.id,
                                    RtcSignals.fields(
                                        session,
                                        epoch,
                                        rtcAttempt,
                                        listOf(Value.Text(mid), Value.Number(0uL), Value.Text(event.sdp)),
                                    ),
                                )
                                if (count == 1 || count % 16 == 0) Log.i("MirriLifecycle", "RTC local candidates=$count")
                            }
                            is RtcReceiver.Event.Failure -> {
                                Log.i("MirriLifecycle", "RTC peer failure event")
                                throw WireException(event.reason)
                            }
                        }
                    }
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    Log.i("MirriLifecycle", "RTC outgoing exception class=${e.javaClass.simpleName}")
                    val safeReason =
                        (e as? WireException)?.message?.takeIf {
                            it in
                                setOf(
                                    "RTC local ICE rejected",
                                    "malformed wire record",
                                    "RTC event queue congested",
                                )
                        }
                    if (safeReason != null) Log.i("MirriLifecycle", "RTC outgoing rejected $safeReason")
                    owner.failure.trySend(e)
                    owner.interrupt()
                }
            }
        val monitor =
            scope.launch(Dispatchers.IO) {
                try {
                    while (owner.active) {
                        delay(1_000)
                        if (!gate.started) continue
                        // Native stats can wait behind the hardware decoder. Never let
                        // that SDK queue block authenticated control Ping/Stop handling.
                        val healthy =
                            withTimeoutOrNull(4_500) {
                                renderer.holder.surface.isValid && peer.udpConnected()
                            } ?: throw WireException("RTC stats health timeout")
                        if (!healthy) throw WireException("RTC transport or surface changed")
                    }
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    Log.i("MirriLifecycle", "RTC monitor exception class=${e.javaClass.simpleName}")
                    owner.failure.trySend(e)
                    owner.interrupt()
                }
            }
        try {
            val deadline = offerAt + 20_000_000_000L
            var nextIceDiagnosticNs = System.nanoTime() + 2_000_000_000L
            var remoteCandidateCount = 0
            while (owner.active) {
                owner.throwIfFailed()
                if (!gate.ready && System.nanoTime() >= nextIceDiagnosticNs) {
                    Log.i("MirriLifecycle", "RTC ICE stats ${peer.iceDiagnostic()}")
                    nextIceDiagnosticNs = System.nanoTime() + 3_000_000_000L
                }
                if (!gate.started && System.nanoTime() >= deadline) {
                    throw WireException("RTC signaling timeout")
                }
                if (!gate.ready && peer.udpConnected() && renderer.holder.surface.isValid) {
                    channel.sendAndWait(MessageType.RTC_MEDIA_READY.id, RtcSignals.fields(session, epoch, rtcAttempt))
                    gate.mediaReady()
                }
                val record = receiveRtcControl(inbound, 100) ?: continue
                when (record.type) {
                    MessageType.RTC_ICE_CANDIDATE.id, MessageType.RTC_ICE_END.id -> {
                        RtcSignals.check(record, session, epoch, rtcAttempt)
                        val remoteMid = RtcSignals.text(record.fields[4])
                        val index = RtcSignals.number(record.fields[5]).toInt()
                        if (record.type == MessageType.RTC_ICE_END.id) {
                            ledger.end(remoteMid, mid, index)
                        } else {
                            ledger.candidate(remoteMid, mid, index, RtcSignals.text(record.fields[6]))?.let {
                                withTimeout(5_000) { peer.add(mid, it) }
                            }
                            remoteCandidateCount++
                            if (remoteCandidateCount == 1 || remoteCandidateCount % 16 == 0) {
                                Log.i("MirriLifecycle", "RTC remote candidates=$remoteCandidateCount")
                            }
                        }
                    }
                    MessageType.RTC_START.id -> {
                        RtcSignals.check(record, session, epoch, rtcAttempt)
                        if (!peer.udpConnected()) throw WireException("RTC start before UDP")
                        gate.start()
                        owner.streaming = true
                        owner.reachedStreaming = true
                        state(ClientSessionState.STREAMING, "RTC 2456x1600 @ 60 Hz hardware $codecName")
                    }
                    MessageType.STOP_SESSION.id -> {
                        gate.stop()
                        owner.streaming = false
                        sendAndWait(channel, session, epoch, ClientCommand.Acknowledged)
                        launch = null
                        return
                    }
                    MessageType.PING.id -> {
                        val received = System.nanoTime()
                        if (!send(
                                channel,
                                session,
                                epoch,
                                ClientCommand.Pong(
                                    RtcSignals.number(record.fields[2]),
                                    RtcSignals.number(record.fields[3]),
                                    received,
                                    System.nanoTime(),
                                ),
                            )
                        ) {
                            throw WireException("RTC control queue congested")
                        }
                    }
                    else -> throw WireException("unexpected RTC control message")
                }
            }
            owner.throwIfFailed()
            throw WireException("RTC attempt interrupted")
        } finally {
            monitor.cancelAndJoin()
            outgoing.cancelAndJoin()
        }
    }

    private suspend fun selectPreHelloSurface(value: Surface) {
        state(ClientSessionState.CONFIGURING_DISPLAY, "Selecting and reading back panel mode")
        withContext(Dispatchers.Main) {
            display.selectAndVerify(value, "pre-hello", surfaceWidth, surfaceHeight)
        }
    }

    // Codec implementations throw multiple checked and unchecked exceptions during configure.
    @Suppress("TooGenericExceptionCaught")
    private suspend fun configureDecoder(
        owner: ClientAttempt,
        prepared: PreparedSession,
    ): DecoderController {
        val currentSurface = prepared.surface
        val channel = prepared.channel
        val config = prepared.config
        val choice = prepared.choice
        val id = config.id
        val epoch = config.epoch
        state(ClientSessionState.CONFIGURING_DECODER, "Configuring hardware decoder")
        val d =
            DecoderController({
                if (attempt === owner) {
                    owner.reportDecoderFailure({
                        if (decoderFailures.incrementAndGet() >
                            1
                        ) {
                            WireException("decoder failed repeatedly")
                        } else {
                            WireException("decoder failed")
                        }
                    }) {
                        scope.launch(Dispatchers.IO) {
                            try {
                                withTimeoutOrNull(500) {
                                    sendAndWait(channel, id, epoch, ClientCommand.Failure(7))
                                }
                            } catch (e: CancellationException) {
                                throw e
                            } catch (e: Exception) {
                                // The old connection may already be gone. Cleanup still wakes reads.
                                Log.i("MirriLifecycle", "failure notice unavailable type=${e.javaClass.simpleName}")
                            } finally {
                                owner.interrupt()
                            }
                        }
                    }
                }
            }, { owner.decoded.incrementAndGet() }, { owner.decoderInputs.incrementAndGet() }, owner.timing)
        owner.decoder = d
        try {
            withContext(Dispatchers.IO) { d.configure(choice, currentSurface, prepared.mode.milliHz) }
        } catch (e: CancellationException) {
            throw e
        } catch (
            e: Exception,
        ) {
            sendAndWait(channel, id, epoch, ClientCommand.Rejection(2, "Hardware codec configure failed"))
            throw WireException("hardware codec configure failed", e)
        }
        owner.throwIfFailed()
        return d
    }

    private suspend fun awaitMediaBarrier(
        spec: ClientLaunch,
        owner: ClientAttempt,
        prepared: PreparedSession,
    ): ActiveStream {
        val channel = prepared.channel
        val config = prepared.config
        val choice = prepared.choice
        val selected = prepared.mode
        val id = config.id
        val epoch = config.epoch
        state(ClientSessionState.CONNECTING_VIDEO, "Authenticating video channel")
        val v = openVideo(spec.connector, spec.endpoint.videoPort, owner.connections, epoch, id, spec.token)
        owner.video = v
        owner.throwIfFailed()
        sendAndWait(channel, id, epoch, ClientCommand.Ready(selected, choice.name))
        val order = WireOrder(WireOrder.Peer.HOST, WireOrder.Channel.CONTROL, epoch.toULong(), id)
        // SessionConfig was read with a first-message order checker; subsequent reads must advance it.
        order.accept(prepared.first)
        val start = blockingBytes(channel::close) { channel.read(order) }
        val started =
            SessionMessages.fromHost(start) as? HostEvent.Start
                ?: throw WireException("expected StartStream")
        owner.generation = started.generation - 1u
        owner.streaming = true
        owner.timing.setTraceIdentity(id, "network")
        owner.timing.activate()
        state(
            ClientSessionState.STREAMING,
            "Network TLS: 2456x1600 @ 60 Hz hardware ${choice.name}",
        )
        return ActiveStream(v, order)
    }

    // Independent video/control children must report arbitrary external socket/codec failures to their owner.
    @Suppress("TooGenericExceptionCaught")
    private suspend fun streamUntilClosed(
        owner: ClientAttempt,
        prepared: PreparedSession,
        d: DecoderController,
        active: ActiveStream,
    ) {
        val channel = prepared.channel
        val config = prepared.config
        val selected = prepared.mode
        val id = config.id
        val epoch = config.epoch
        val v = active.video
        val order = active.order
        val receiver =
            VideoReceiver(v, encodedBuffers, d, id, epoch, config.codec.wire, owner.timing) { length ->
                owner.received.incrementAndGet()
                owner.bytes.addAndGet(length.toLong())
            }
        coroutineScope {
            val videoJob =
                launch(Dispatchers.IO) {
                    try {
                        receiver.receive(owner.generation) { g ->
                            dropped.incrementAndGet()
                            if (!send(channel, id, epoch, ClientCommand.Keyframe(g))) {
                                throw WireException("control queue congested")
                            }
                        }
                    } catch (e: CancellationException) {
                        throw e
                    } catch (
                        e: Exception,
                    ) {
                        owner.failure.trySend(e)
                        channel.close()
                    }
                }
            val metricJob = launchMetrics(owner, d, channel, id, epoch, selected)
            try {
                while (true) {
                    val message = blockingBytes(channel::close) { channel.read(order) }
                    if (handleHostEvent(SessionMessages.fromHost(message), channel, id, epoch, owner)) return@coroutineScope
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                throw owner.failure.tryReceive().getOrNull() ?: e
            } finally {
                owner.timing.endWindow()
                metricJob.cancel()
                videoJob.cancel()
                owner.interrupt()
                metricJob.join()
                videoJob.join()
            }
        }
    }

    private fun CoroutineScope.launchMetrics(
        owner: ClientAttempt,
        d: DecoderController,
        channel: ControlChannel,
        id: ByteArray,
        epoch: UInt,
        selected: PhysicalMode,
    ): Job =
        launch(Dispatchers.IO) {
            var timingReportSamples = 0
            var lockMaxNs = 0L
            var formatMaxNs = 0L
            var logMaxNs = 0L
            while (isActive) {
                delay(1000)
                val fps =
                    owner.received
                        .getAndSet(0)
                        .toFloat()
                        .coerceIn(0f, 240f)
                val bits = (owner.bytes.getAndSet(0) * 8).coerceIn(0, UInt.MAX_VALUE.toLong())
                val outputs =
                    owner.decoded
                        .getAndSet(0)
                        .toFloat()
                        .coerceIn(0f, 240f)
                val inputs =
                    owner.decoderInputs
                        .getAndSet(0)
                        .toFloat()
                        .coerceIn(0f, 240f)
                val frameAge = d.drainFrameAges()
                // Report-only costs; no per-frame work or extra diagnostic line each second.
                val lockStart = System.nanoTime()
                val timingSummary = owner.timing.drainLiveSummary()
                val lockNs = (System.nanoTime() - lockStart).coerceAtLeast(0)
                if (timingSummary != null) {
                    val formatStart = System.nanoTime()
                    val timingLine = timingSummary.line()
                    val formatNs = (System.nanoTime() - formatStart).coerceAtLeast(0)
                    val logStart = System.nanoTime()
                    Log.i("MirriTiming", timingLine)
                    val logNs = (System.nanoTime() - logStart).coerceAtLeast(0)
                    timingReportSamples++
                    lockMaxNs = maxOf(lockMaxNs, lockNs)
                    formatMaxNs = maxOf(formatMaxNs, formatNs)
                    logMaxNs = maxOf(logMaxNs, logNs)
                    if (timingReportSamples == 10) {
                        Log.i(
                            "MirriTimingReport",
                            "epoch=$epoch samples=10 lockMaxUs=${lockMaxNs / 1000} " +
                                "formatMaxUs=${formatMaxNs / 1000} logMaxUs=${logMaxNs / 1000}",
                        )
                        timingReportSamples = 0
                        lockMaxNs = 0
                        formatMaxNs = 0
                        logMaxNs = 0
                    }
                }
                owner.timing.drainLatencyLine()?.let { Log.i("MirriLatencyTrace", it) }
                if (frameAge.samples > 0 || frameAge.evicted > 0) {
                    Log.i(
                        "MirriLatency",
                        "receive-to-decoder-release samples=${frameAge.samples} medianMs=${frameAge.medianMs} p95Ms=${frameAge.p95Ms} evicted=${frameAge.evicted}",
                    )
                }
                // Metrics may be omitted under control congestion; input and
                // lifecycle messages still fail rather than silently drop.
                send(
                    channel,
                    id,
                    epoch,
                    ClientCommand.Metrics(fps, bits, inputs, outputs, selected, 3 - encodedBuffers.available, dropped.get()),
                )
            }
        }

    private suspend fun handleHostEvent(
        event: HostEvent,
        channel: ControlChannel,
        id: ByteArray,
        epoch: UInt,
        owner: ClientAttempt,
    ): Boolean {
        when (event) {
            HostEvent.Stop -> {
                owner.timing.endWindow()
                sendAndWait(channel, id, epoch, ClientCommand.Acknowledged)
                launch = null
                state(ClientSessionState.STOPPING, "Host stopped; releasing owned resources")
                return true
            }
            is HostEvent.Ping -> {
                val receivedNs = System.nanoTime()
                if (!send(channel, id, epoch, ClientCommand.Pong(event.sequence, event.sent, receivedNs, System.nanoTime()))) {
                    throw WireException("control queue congested")
                }
            }
            HostEvent.Error -> throw WireException("host protocol error")
            else -> throw WireException("unexpected session message")
        }
        return false
    }
}
