package dev.mirri.client.protocol

import dev.mirri.client.video.EncodedBufferPool
import dev.mirri.client.video.EncodedVideoConsumer
import dev.mirri.client.video.VideoTimingOwner
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** Reads AU payload into a pooled direct buffer; never materializes a frame ByteArray. */
class VideoReceiver(
    private val channel: VideoChannel,
    private val pool: EncodedBufferPool,
    private val decoder: EncodedVideoConsumer,
    private val sessionId: ByteArray,
    private val epoch: UInt,
    private val codec: Int,
    private val timing: VideoTimingOwner,
    private val received: (Int) -> Unit,
) {
    private class ReceiveState(
        previousGeneration: UInt,
    ) {
        var headerSequence = 0L
        var generation = previousGeneration.toLong()
        var frameSequence = 0L
        var awaitingIdr = true
        var configured = false
    }

    // Reused per connection: receipt must not allocate heap records at the 60 fps frame rate.
    private class Header(
        var minor: Int = 0,
        var type: Int = 0,
        var length: Int = 0,
    )

    private class FramePrefix(
        var generation: Long = 0,
        var frame: Long = 0,
        var pts: Long = 0,
        var flags: Int = 0,
        var auLength: Int = 0,
    )

    suspend fun receive(
        previousGeneration: UInt,
        requestKeyframe: (UInt) -> Unit,
    ) = withContext(Dispatchers.IO) {
        val state = ReceiveState(previousGeneration)
        val header = ByteBuffer.allocateDirect(32).order(ByteOrder.BIG_ENDIAN)
        val prefix = ByteBuffer.allocateDirect(45).order(ByteOrder.BIG_ENDIAN)
        val skip = ByteBuffer.allocateDirect(8192)
        val record = Header()
        val frame = FramePrefix()
        while (true) {
            readHeader(header, state, record)
            when (record.type) {
                MessageType.CODEC_CONFIG.id -> configure(header, record.length, state)
                MessageType.VIDEO_FRAME.id -> receiveFrame(prefix, record.length, state, frame, requestKeyframe)
                else -> skipExtension(record, skip)
            }
        }
    }

    private fun readHeader(
        header: ByteBuffer,
        state: ReceiveState,
        record: Header,
    ) {
        header.clear()
        channel.readFully(header)
        header.flip()
        if (header.int != 0x4d525249 || header.short.toInt() != 1) throw WireException("video header")
        val minor = header.short.toInt() and 65535
        val type = header.short.toInt() and 65535
        if (header.short.toInt() != 0 || header.long != state.headerSequence++) throw WireException("video sequence")
        val length = header.int
        header.long
        val limit = if (type == MessageType.VIDEO_FRAME.id) 16_777_261 else 65_536
        if (length < 0 || length > limit) throw WireException("video length")
        record.minor = minor
        record.type = type
        record.length = length
    }

    private fun skipExtension(
        record: Header,
        skip: ByteBuffer,
    ) {
        if (record.minor == 0 || record.type and 0x8000 == 0) throw WireException("video type")
        var remaining = record.length
        while (remaining > 0) {
            skip.clear()
            skip.limit(minOf(remaining, skip.capacity()))
            channel.readFully(skip)
            remaining -= skip.position()
        }
    }

    private suspend fun configure(
        header: ByteBuffer,
        length: Int,
        state: ReceiveState,
    ) {
        val body = ByteBuffer.allocate(32 + length).order(ByteOrder.BIG_ENDIAN)
        header.rewind()
        body.put(header)
        channel.readFully(body)
        val message = WireCodec.decode(body.array()) ?: throw WireException("video config")
        val configuration = SessionMessages.fromVideoConfig(message)
        val wrongIdentity = !configuration.id.contentEquals(sessionId) || configuration.epoch != epoch
        if (wrongIdentity || configuration.codec.wire != codec) throw WireException("video config envelope")
        val next = configuration.generation
        if (next != state.generation + 1) throw WireException("video generation")
        if (state.configured) decoder.flushForDiscontinuity()
        timing.startGeneration(next.toUInt())
        state.generation = next
        state.frameSequence = 0
        state.awaitingIdr = true
        val sets = configuration.parameterSets
        val csd = ByteBuffer.allocateDirect(sets.sumOf { it.size + 4 })
        sets.forEach {
            csd.putInt(1)
            csd.put(it)
        }
        csd.flip()
        decoder.submitConfiguration(csd)
        state.configured = true
    }

    private suspend fun receiveFrame(
        prefix: ByteBuffer,
        length: Int,
        state: ReceiveState,
        record: FramePrefix,
        requestKeyframe: (UInt) -> Unit,
    ) {
        readFramePrefix(prefix, length, record)
        val wrongFrame = record.generation != state.generation || record.frame != state.frameSequence
        if (wrongFrame || (state.awaitingIdr && record.flags != 3)) {
            requestKeyframe(record.generation.toUInt())
            throw WireException("video discontinuity")
        }
        pool.withLease { buffer ->
            buffer.limit(record.auLength)
            channel.readFully(buffer)
            val receivedAtNs = System.nanoTime()
            buffer.flip()
            if (buffer.getInt(0) != 1) throw WireException("Annex-B required")
            received(record.auLength)
            // The validated wire flag remains only numeric join metadata, never decoder admission.
            timing.received(record.generation.toUInt(), record.frame, record.pts, receivedAtNs, record.flags and 1 != 0, record.auLength)
            decoder.submitAccessUnit(buffer, record.pts, receivedAtNs)
            state.frameSequence++
            state.awaitingIdr = false
        }
    }

    private fun readFramePrefix(
        prefix: ByteBuffer,
        length: Int,
        record: FramePrefix,
    ) {
        if (length < 50) throw WireException("video frame length")
        prefix.clear()
        channel.readFully(prefix)
        prefix.flip()
        var matchingId = true
        for (i in sessionId.indices) if (prefix.get() != sessionId[i]) matchingId = false
        val frameEpoch = prefix.int
        val g = prefix.int.toLong() and 0xffffffffL
        val frame = prefix.long
        val pts = prefix.long
        val flags = prefix.get().toInt() and 255
        val auLength = prefix.int
        val invalidSize = length != 45 + auLength || auLength !in 5..16_777_216
        if (invalidSize || flags and 0xfc != 0) throw WireException("video AU length")
        if (!matchingId || frameEpoch.toUInt() != epoch) throw WireException("video frame envelope")
        record.generation = g
        record.frame = frame
        record.pts = pts
        record.flags = flags
        record.auLength = auLength
    }
}
