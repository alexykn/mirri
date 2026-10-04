package dev.mirri.client.session

import dev.mirri.client.protocol.ControlChannel
import dev.mirri.client.protocol.VideoChannel
import dev.mirri.client.video.DecoderController
import dev.mirri.client.video.RtcReceiver
import dev.mirri.client.video.VideoTimingOwner
import kotlinx.coroutines.channels.Channel
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

/** One attempt owns even byte connections still connecting; old callbacks touch only this context. */
internal class ClientAttempt {
    val connections = AttemptConnections()
    val timing = VideoTimingOwner()

    @Volatile var control: ControlChannel? = null

    @Volatile var video: VideoChannel? = null

    @Volatile var decoder: DecoderController? = null

    @Volatile var rtc: RtcReceiver? = null
    var id: ByteArray? = null
    var epoch = 0u
    var generation = 0u

    @Volatile var streaming = false

    @Volatile var rtcHelloSent = false

    /** Set once per attempt and kept through interrupt: a later loss is an interruption, not a rejected negotiation. */
    @Volatile var reachedStreaming = false

    @Volatile var active = true
    var inputBatchSequence = 0uL
    private val decoderFailureReported = AtomicBoolean()
    val failure = Channel<Throwable>(1)
    val received = AtomicLong()
    val bytes = AtomicLong()
    val decoded = AtomicLong()
    val decoderInputs = AtomicLong()

    /** Does not require streaming: codec callbacks can fail during configure/barrier. */
    fun reportDecoderFailure(
        error: () -> Throwable,
        onFirst: () -> Unit,
    ) {
        if (!active || !decoderFailureReported.compareAndSet(false, true) || !active) return
        failure.trySend(error())
        onFirst()
    }

    fun interrupt() {
        active = false
        streaming = false
        connections.close()
        // Raw byte connections are already shut down. Finish both wrappers even if
        // one races a concurrent close or a failing writer.
        runCatching { video?.close() }
        runCatching { control?.close() }
    }

    fun throwIfFailed() {
        failure.tryReceive().getOrNull()?.let { throw it }
    }

    suspend fun close() {
        try {
            interrupt()
        } finally {
            try {
                decoder?.stop()
            } finally {
                decoder = null
                try {
                    rtc?.close()
                } finally {
                    rtc = null
                    timing.close()
                }
            }
        }
    }
}
