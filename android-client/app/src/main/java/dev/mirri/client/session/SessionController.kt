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
import dev.mirri.client.protocol.SessionConfiguration
import dev.mirri.client.protocol.SessionMessages
import dev.mirri.client.protocol.VideoChannel
import dev.mirri.client.protocol.VideoReceiver
import dev.mirri.client.protocol.WireException
import dev.mirri.client.protocol.WireMessage
import dev.mirri.client.protocol.WireOrder
import dev.mirri.client.protocol.openVideo
import dev.mirri.client.transport.PeerAuthenticationException
import dev.mirri.client.transport.blockingBytes
import dev.mirri.client.video.CodecCapabilityProbe
import dev.mirri.client.video.DecoderChoice
import dev.mirri.client.video.DecoderController
import dev.mirri.client.video.DecoderFailure
import dev.mirri.client.video.EncodedBufferPool
import dev.mirri.client.video.TimingLogMessage
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
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
    private var launch: ClientLaunch? = null
    private var job: Job? = null
    private var terminalLaunch = false

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
        var terminal = false
        while (scope.isActive && hasActiveSession() && !terminal) {
            val spec = requireNotNull(launch)
            val owner = ClientAttempt()
            attempt = owner
            when (runAttempt(spec, owner)) {
                AttemptResult.CONNECTED -> retryCount = 0
                AttemptResult.RETRY -> Unit
                AttemptResult.TERMINAL -> {
                    terminal = true
                    terminalLaunch = true
                }
            }
            if (!terminal && hasActiveSession()) {
                delay(ReconnectPolicy.delayMs(retryCount++))
                if (retryCount > 16) {
                    state(ClientSessionState.FAILED, "Reconnect window expired")
                    terminal = true
                }
            }
        }
        if (scope.isActive && launch == null) state(ClientSessionState.IDLE, "Host stopped session")
    }

    private fun hasActiveSession(): Boolean = surface != null && launch != null

    // Exceptions from the external codec/socket stack must be classified after owner cleanup.
    @Suppress("TooGenericExceptionCaught")
    private suspend fun runAttempt(
        spec: ClientLaunch,
        owner: ClientAttempt,
    ): AttemptResult =
        try {
            connectOnce(spec, owner)
            AttemptResult.CONNECTED
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            if (e is DecoderFailure || e is PeerAuthenticationException || fatalProtocol(e)) {
                terminalLaunch = true
                state(ClientSessionState.FAILED, e.message ?: "Protocol rejected")
                AttemptResult.TERMINAL
            } else {
                state(
                    ClientSessionState.RECONNECTING,
                    "${if (spec.mode == BootstrapMode.USB) "USB" else "Network"}/host connection interrupted; retrying",
                )
                AttemptResult.RETRY
            }
        } finally {
            cleanupAttempt(owner)
        }

    private fun fatalProtocol(error: Exception): Boolean =
        error is WireException && error.message !in setOf("connection closed", "decoder failed")

    private suspend fun cleanupAttempt(owner: ClientAttempt) {
        try {
            owner.timing.endWindow()
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
        // Preserve USB setup order; network verifies pinned TLS and MRNB first.
        selectPreHelloSurface(spec.mode, beforeConnection = true, value = currentSurface)
        state(
            ClientSessionState.CONNECTING_CONTROL,
            if (spec.mode == BootstrapMode.USB) "Connecting USB control" else "Connecting pinned TLS control",
        )
        // The raw socket joins this attempt *before* blocking connect or a
        // cancellable IO -> Main handoff; finally closes it even if delivery fails.
        val bytes = spec.connector.connect(spec.endpoint.controlPort, owner.connections)
        // TLS pin and validity are checked by the connector before this token-bearing preface.
        val epoch =
            if (spec.mode == BootstrapMode.NETWORK) {
                blockingBytes(bytes::close) { NetworkBootstrap.exchange(bytes, spec.token) }
            } else {
                spec.epoch
            }
        bytes.finishSetup()
        val channel =
            ControlChannel(bytes, scope) {
                owner.failure.trySend(it)
                bytes.close()
            }
        owner.control = channel
        // USB advances via ADB relaunch; network learns every current epoch over pinned TLS.
        owner.epoch = epoch
        owner.timing.setEpoch(epoch)
        selectPreHelloSurface(spec.mode, beforeConnection = false, value = currentSurface)
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
        state(ClientSessionState.CONFIGURING_DISPLAY, "Selecting and reading back 60 Hz")
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

    private suspend fun selectPreHelloSurface(
        mode: BootstrapMode,
        beforeConnection: Boolean,
        value: Surface,
    ) {
        if ((mode == BootstrapMode.USB) != beforeConnection) return
        state(ClientSessionState.CONFIGURING_DISPLAY, "Selecting and reading back 60 Hz")
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
            withContext(Dispatchers.IO) { d.configure(choice, currentSurface) }
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
        owner.timing.activate()
        state(
            ClientSessionState.STREAMING,
            "${if (spec.mode == BootstrapMode.USB) "USB" else "Network TLS"}: 2456x1600 @ 60 Hz hardware ${choice.name}",
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
