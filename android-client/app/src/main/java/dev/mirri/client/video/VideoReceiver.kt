package dev.mirri.client.video

import dev.mirri.client.protocol.MessageType
import dev.mirri.client.protocol.SessionMessages
import dev.mirri.client.protocol.WireCodec
import dev.mirri.client.protocol.WireException
import dev.mirri.client.transport.VideoChannel
import dev.mirri.client.transport.readFully
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** Reads AU payload into a pooled direct buffer; never materializes a frame ByteArray. */
class VideoReceiver(
    private val channel: VideoChannel,
    private val pool: EncodedBufferPool,
    private val decoder: DecoderController,
    private val sessionId: ByteArray,
    private val epoch: UInt,
    private val codec: Int,
    private val timing: VideoTimingOwner,
    private val received: (Int) -> Unit,
) {
    suspend fun receive(
        previousGeneration: UInt,
        requestKeyframe: (UInt) -> Unit,
    ) = withContext(Dispatchers.IO) {
        var headerSequence = 0L
        var generation = previousGeneration.toLong()
        var frameSequence = 0L
        var awaitingIdr = true
        var configured = false
        val header = ByteBuffer.allocateDirect(32).order(ByteOrder.BIG_ENDIAN)
        val prefix = ByteBuffer.allocateDirect(45).order(ByteOrder.BIG_ENDIAN)
        val skip = ByteBuffer.allocateDirect(8192)
        while (true) {
            header.clear()
            channel.socket.readFully(header)
            header.flip()
            if (header.int != 0x4d525249 || header.short.toInt() != 1) throw WireException("video header")
            val minor = header.short.toInt() and 65535
            val type = header.short.toInt() and 65535
            if (header.short.toInt() != 0 || header.long != headerSequence++) throw WireException("video sequence")
            val length = header.int
            header.long
            val limit = if (type == MessageType.VIDEO_FRAME.id) 16_777_261 else 65_536
            if (length < 0 || length > limit) throw WireException("video length")
            if (type != MessageType.CODEC_CONFIG.id && type != MessageType.VIDEO_FRAME.id) {
                if (minor == 0 || type and 0x8000 == 0) throw WireException("video type")
                var remaining = length
                while (remaining >
                    0
                ) {
                    skip.clear()
                    skip.limit(minOf(remaining, skip.capacity()))
                    channel.socket.readFully(skip)
                    remaining -=
                        skip.position()
                }
                continue
            }
            if (type == MessageType.CODEC_CONFIG.id) {
                val body = ByteBuffer.allocate(32 + length).order(ByteOrder.BIG_ENDIAN)
                header.rewind()
                body.put(header)
                channel.socket.readFully(body)
                val message = WireCodec.decode(body.array()) ?: throw WireException("video config")
                val configuration = SessionMessages.fromVideoConfig(message)
                if (!configuration.id.contentEquals(sessionId) ||
                    configuration.epoch != epoch ||
                    configuration.codec.wire != codec
                ) {
                    throw WireException("video config envelope")
                }
                val next = configuration.generation
                if (next != generation + 1) throw WireException("video generation")
                if (configured) decoder.flushForDiscontinuity()
                timing.startGeneration(next.toUInt())
                generation = next
                frameSequence = 0
                awaitingIdr = true
                val sets = configuration.parameterSets
                val csd = ByteBuffer.allocateDirect(sets.sumOf { it.size + 4 })
                sets.forEach {
                    csd.putInt(1)
                    csd.put(it)
                }
                csd.flip()
                decoder.submit(csd, 0, true)
                configured = true
                continue
            }
            if (length < 50) throw WireException("video frame length")
            prefix.clear()
            channel.socket.readFully(prefix)
            prefix.flip()
            var matchingId = true
            for (i in sessionId.indices) if (prefix.get() != sessionId[i]) matchingId = false
            val epoch = prefix.int
            val g = prefix.int.toLong() and 0xffffffffL
            val frame = prefix.long
            val pts = prefix.long
            val flags = prefix.get().toInt() and 255
            val auLength = prefix.int
            if (length != 45 + auLength || auLength !in 5..16_777_216 || flags and 0xfc != 0) throw WireException("video AU length")
            if (!matchingId || epoch.toUInt() != this@VideoReceiver.epoch) throw WireException("video frame envelope")
            if (g != generation || frame != frameSequence || (awaitingIdr && flags != 3)) {
                requestKeyframe(g.toUInt())
                throw WireException("video discontinuity")
            }
            pool.withLease { buffer ->
                buffer.limit(auLength)
                channel.socket.readFully(buffer)
                val receivedAtNs = System.nanoTime()
                buffer.flip()
                if (buffer.getInt(0) != 1) throw WireException("Annex-B required")
                received(auLength)
                // The validated wire flag is preserved only as numeric join metadata;
                // it does not change decoder admission or the Annex-B AU bytes.
                timing.received(g.toUInt(), frame, pts, receivedAtNs, flags and 1 != 0, auLength)
                decoder.submit(buffer, pts, receivedAtNs = receivedAtNs)
                frameSequence++
                awaitingIdr = false
            }
        }
    }
}
