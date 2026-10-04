package dev.mirri.client.video

import android.media.MediaCodec
import android.media.MediaFormat
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.view.Surface
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import java.nio.ByteBuffer
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/** Bounded framework input-index leases; close wakes a pending receive immediately. */
internal class DecoderInputIndices(
    private val onLost: (Int) -> Unit = {},
) {
    private val closed = AtomicBoolean(false)

    // Channel.receive may dequeue an index then lose the dispatch race to
    // cancellation. Restore that *same* framework lease unless shutting down.
    private val available = Channel<Int>(32, onUndeliveredElement = ::restore)

    private fun restore(index: Int) {
        if (!closed.get() && !available.trySend(index).isSuccess) onLost(index)
    }

    fun offer(index: Int): Boolean = available.trySend(index).isSuccess

    suspend fun receive(): Int = available.receive()

    fun clear() {
        while (available.tryReceive().isSuccess) { /* stale generation */ }
    }

    fun close() {
        closed.set(true)
        available.close()
    }
}

/** Sole MediaCodec owner. Callback thread never blocks on network or frame arrival. */
class DecoderController(
    private val onFailure: (Throwable) -> Unit,
    private val onOutput: () -> Unit,
    private val onInput: () -> Unit,
    private val timing: VideoTimingOwner,
) : EncodedVideoConsumer {
    private val thread = HandlerThread("mirri-decoder").also { it.start() }
    private val handler = Handler(thread.looper)
    private var codec: MediaCodec? = null
    private val active = AtomicBoolean(false)
    private val frameAges = DecoderFrameAges()

    // Touched only on the decoder handler thread, like the codec itself.
    private var pacer = PresentationPacer(0)

    internal fun drainFrameAges(): DecoderFrameAges.Summary = frameAges.drain()

    // One index per framework input buffer. Bounded; exhaustion is a codec
    // failure, never an unbounded network-side allocation.
    private val indices =
        DecoderInputIndices {
            if (active.get()) {
                Log.w("MirriDecoder", "decoder index lease lost")
                onFailure(DecoderFailure("decoder index lease lost"))
            }
        }

    // Forward arbitrary codec-operation failures to the suspended caller on its original continuation.
    @Suppress("TooGenericExceptionCaught")
    private suspend fun <T> onOwner(operation: () -> T): T =
        suspendCancellableCoroutine { continuation ->
            if (!handler.post {
                    if (continuation.isActive) {
                        try {
                            continuation.resume(operation())
                        } catch (e: Exception) {
                            continuation.resumeWithException(e)
                        }
                    }
                }
            ) {
                continuation.resumeWithException(DecoderFailure("decoder owner stopped"))
            }
        }

    // Failed vendor setup must release the codec regardless of exception subtype.
    @Suppress("TooGenericExceptionCaught")
    suspend fun configure(
        choice: DecoderChoice,
        surface: Surface,
        panelMilliHz: Long,
    ) = onOwner {
        check(codec == null)
        pacer = PresentationPacer(panelMilliHz)
        val c = MediaCodec.createByCodecName(choice.name)
        try {
            active.set(true)
            c.setCallback(
                object : MediaCodec.Callback() {
                    override fun onInputBufferAvailable(
                        codec: MediaCodec,
                        index: Int,
                    ) {
                        if (!active.get() || codec !== c) return
                        timing.inputAvailable(index, System.nanoTime())
                        if (!indices.offer(index)) {
                            timing.forgetInputIndex(index)
                            Log.w("MirriDecoder", "decoder input index queue full")
                            onFailure(DecoderFailure("decoder input queue full"))
                        }
                    }

                    // Codec callback failures report to the owner, never escape onto framework threads.
                    @Suppress("TooGenericExceptionCaught")
                    override fun onOutputBufferAvailable(
                        codec: MediaCodec,
                        index: Int,
                        info: MediaCodec.BufferInfo,
                    ) {
                        if (!active.get() || codec !== c) return
                        try {
                            if (info.size > 0) timing.outputAvailable(info.presentationTimeUs, System.nanoTime())
                            val releaseRequestNs = if (info.size > 0) System.nanoTime() else 0L
                            if (info.size > 0) {
                                // Wire/media PTS is not an Android clock. Request the
                                // next feasible presentation using local monotonic time,
                                // at most one frame per panel refresh so SurfaceView does
                                // not replace an older frame queued for the same vsync.
                                codec.releaseOutputBuffer(index, pacer.next(releaseRequestNs))
                            } else {
                                codec.releaseOutputBuffer(index, false)
                            }
                            if (info.size > 0) {
                                val releaseReturnedNs = System.nanoTime()
                                frameAges.released(info.presentationTimeUs, releaseReturnedNs)
                                timing.outputReleased(info.presentationTimeUs, releaseRequestNs, releaseReturnedNs)
                                onOutput()
                            }
                        } catch (
                            e: Exception,
                        ) {
                            if (active.get()) {
                                Log.w("MirriDecoder", "release output failed type=${e.javaClass.simpleName}")
                                onFailure(e)
                            }
                        }
                    }

                    override fun onOutputFormatChanged(
                        codec: MediaCodec,
                        format: MediaFormat,
                    ) {
                        if (!active.get()) return
                        val standard =
                            if (format.containsKey(
                                    MediaFormat.KEY_COLOR_STANDARD,
                                )
                            ) {
                                format.getInteger(MediaFormat.KEY_COLOR_STANDARD)
                            } else {
                                null
                            }
                        val range =
                            if (format.containsKey(MediaFormat.KEY_COLOR_RANGE)) format.getInteger(MediaFormat.KEY_COLOR_RANGE) else null
                        val width = format.getInteger(MediaFormat.KEY_WIDTH)
                        val height = format.getInteger(MediaFormat.KEY_HEIGHT)

                        fun crop(key: String): Int? = if (format.containsKey(key)) format.getInteger(key) else null
                        // MediaFormat crop keys are strings on API 30-32 too; the named
                        // constants were only added in API 33.
                        val left = crop("crop-left")
                        val top = crop("crop-top")
                        val right = crop("crop-right")
                        val bottom = crop("crop-bottom")
                        val wrongStandard = standard != null && standard != MediaFormat.COLOR_STANDARD_BT709
                        val wrongRange = range != null && range != MediaFormat.COLOR_RANGE_LIMITED
                        val wrongSize = !DecoderOutputReadback.isExactVisibleFrame(width, height, left, top, right, bottom)
                        Log.i(
                            "MirriDecoder",
                            "output format coded=${width}x$height crop=$left,$top,$right,$bottom standard=$standard range=$range visibleExact=${!wrongSize} colorExact=${!wrongStandard && !wrongRange}",
                        )
                        if (wrongStandard || wrongRange || wrongSize) {
                            onFailure(DecoderFailure("decoder output format mismatch"))
                        }
                    }

                    override fun onError(
                        codec: MediaCodec,
                        e: MediaCodec.CodecException,
                    ) {
                        if (active.get()) {
                            Log.w("MirriDecoder", "codec error code=${e.errorCode} recoverable=${e.isRecoverable}")
                            onFailure(e)
                        }
                    }
                },
                handler,
            )
            val format =
                MediaFormat.createVideoFormat(
                    if (choice.codec == MediaCodecKind.AVC.id) {
                        MediaFormat.MIMETYPE_VIDEO_AVC
                    } else {
                        MediaFormat.MIMETYPE_VIDEO_HEVC
                    },
                    2456,
                    1600,
                )
            format.setInteger(MediaFormat.KEY_COLOR_STANDARD, MediaFormat.COLOR_STANDARD_BT709)
            format.setInteger(MediaFormat.KEY_COLOR_RANGE, MediaFormat.COLOR_RANGE_LIMITED)
            if (choice.lowLatency) format.setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
            format.setInteger(MediaFormat.KEY_OPERATING_RATE, 60)
            c.configure(format, surface, null, 0)
            // Registration is after configure and before rendering. Missing
            // telemetry must not change codec admission or frame policy.
            try {
                c.setOnFrameRenderedListener(
                    { renderedCodec, presentationTimeUs, nanoTime ->
                        if (active.get() && renderedCodec === c) timing.rendered(presentationTimeUs, nanoTime, System.nanoTime())
                    },
                    handler,
                )
                timing.listenerInstalled()
            } catch (_: Exception) {
                timing.listenerUnavailable()
            }
            c.start()
            codec = c
        } catch (e: Exception) {
            active.set(false)
            c.release()
            throw e
        }
    }

    override suspend fun submitConfiguration(data: ByteBuffer) {
        submit(data, 0, config = true)
    }

    override suspend fun submitAccessUnit(
        data: ByteBuffer,
        ptsNs: Long,
        receivedAtNs: Long,
    ) {
        submit(data, ptsNs, receivedAtNs = receivedAtNs)
    }

    private suspend fun submit(
        data: ByteBuffer,
        ptsNs: Long,
        config: Boolean = false,
        receivedAtNs: Long? = null,
    ) {
        val index = indices.receive()
        if (config) timing.forgetInputIndex(index) else timing.inputAcquired(index, System.nanoTime())
        // The index lease has left the callback queue. Finish submission even
        // if the receive coroutine is cancelled, then release the pool lease.
        withContext(NonCancellable) {
            onOwner {
                val c = codec ?: throw DecoderFailure("decoder stopped")
                val input = c.getInputBuffer(index) ?: throw DecoderFailure("decoder input unavailable")
                input.clear()
                if (input.remaining() < data.remaining()) throw DecoderFailure("decoder input too small")
                val length = data.remaining()
                input.put(data)
                val codecPtsUs = ptsNs / 1000
                c.queueInputBuffer(index, 0, length, codecPtsUs, if (config) MediaCodec.BUFFER_FLAG_CODEC_CONFIG else 0)
                if (!config) {
                    if (receivedAtNs != null) frameAges.submitted(codecPtsUs, receivedAtNs)
                    timing.inputQueued(codecPtsUs, System.nanoTime())
                    onInput()
                }
            }
        }
    }

    override suspend fun flushForDiscontinuity() =
        onOwner {
            val c = codec ?: throw DecoderFailure("decoder stopped")
            indices.clear()
            frameAges.clearPending()
            pacer.reset()
            c.flush()
            c.start()
        }

    suspend fun stop() {
        active.set(false)
        indices.close()
        frameAges.clearPending()
        try {
            withContext(NonCancellable) {
                onOwner {
                    val c = codec
                    codec = null
                    try {
                        c?.stop()
                    } catch (_: Exception) {
                        // Codec may already be failed; release still belongs to this owner.
                    }
                    c?.release()
                }
            }
        } finally {
            thread.quitSafely()
        }
    }
}
