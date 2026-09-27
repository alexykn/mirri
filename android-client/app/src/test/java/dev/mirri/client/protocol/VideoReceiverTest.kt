package dev.mirri.client.protocol

import dev.mirri.client.transport.ByteConnection
import dev.mirri.client.video.EncodedBufferPool
import dev.mirri.client.video.EncodedVideoConsumer
import dev.mirri.client.video.VideoTimingOwner
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.EOFException
import java.io.File
import java.nio.ByteBuffer

private class FixtureBytes(
    private val input: ByteArray,
) : ByteConnection {
    private var offset = 0

    override fun readFully(buffer: ByteBuffer) {
        val count = buffer.remaining()
        if (input.size - offset < count) throw EOFException("fixture exhausted")
        buffer.put(input, offset, count)
        offset += count
    }

    override fun writeFully(buffer: ByteBuffer) = error("receiver must not write")

    override fun close() = Unit
}

private class RecordingConsumer : EncodedVideoConsumer {
    var configs = 0
    var frames = 0
    var direct = false
    var prefix = 0
    var pts = -1L

    override suspend fun submitConfiguration(data: ByteBuffer) {
        configs++
        assertTrue(data.isDirect)
    }

    override suspend fun submitAccessUnit(
        data: ByteBuffer,
        ptsNs: Long,
        receivedAtNs: Long,
    ) {
        frames++
        direct = data.isDirect
        prefix = data.getInt(data.position())
        pts = ptsNs
        assertTrue(receivedAtNs > 0)
    }

    override suspend fun flushForDiscontinuity() = fail("first generation must not flush")
}

class VideoReceiverTest {
    private val fixtures = File("../../protocol/fixtures")

    @Test fun validatedFrameUsesPooledDirectBufferUntilConsumerReturns() =
        runBlocking {
            val config = fixtures.resolve("05-codec-configuration-v1.bin").readBytes()
            // Golden records each start at sequence zero; this connection sends config then frame.
            val frame = fixtures.resolve("06-video-frame-v1.bin").readBytes().also { it[19] = 1 }
            val identity = SessionMessages.fromVideoConfig(WireCodec.decode(config)!!)
            val pool = EncodedBufferPool(count = 1, size = 256)
            val decoder = RecordingConsumer()
            val timing = VideoTimingOwner()
            timing.setEpoch(identity.epoch)
            timing.activate()
            var received = 0
            val receiver =
                VideoReceiver(
                    VideoChannel(FixtureBytes(config + frame)),
                    pool,
                    decoder,
                    identity.id,
                    identity.epoch,
                    identity.codec.wire,
                    timing,
                ) { received++ }
            try {
                receiver.receive(0u) { fail("valid IDR must not request keyframe") }
                fail("fixture exhaustion must end receive")
            } catch (_: EOFException) {
                // The fixture contains exactly one configuration and one access unit.
            }
            assertEquals(1, decoder.configs)
            assertEquals(1, decoder.frames)
            assertTrue(decoder.direct)
            assertEquals(1, decoder.prefix)
            assertEquals(0L, decoder.pts)
            assertEquals(1, received)
            assertEquals(1, pool.available)
        }
}
