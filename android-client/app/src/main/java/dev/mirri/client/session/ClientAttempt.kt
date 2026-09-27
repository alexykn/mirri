package dev.mirri.client.session

import dev.mirri.client.transport.AttemptSockets
import dev.mirri.client.transport.ControlChannel
import dev.mirri.client.transport.VideoChannel
import dev.mirri.client.video.DecoderController
import dev.mirri.client.video.VideoTimingOwner
import kotlinx.coroutines.channels.Channel
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

/** One attempt owns even sockets still connecting; old callbacks can touch only this context. */
internal class ClientAttempt {
    val sockets = AttemptSockets()
    val timing = VideoTimingOwner()

    @Volatile var control: ControlChannel? = null

    @Volatile var video: VideoChannel? = null

    @Volatile var decoder: DecoderController? = null
    var id: ByteArray? = null
    var epoch = 0u
    var generation = 0u

    @Volatile var streaming = false

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
        sockets.close()
        // The raw sockets are already shut down. Finish both wrappers even if
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
                timing.close()
            }
        }
    }
}
