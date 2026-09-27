package dev.mirri.client.protocol

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.fail
import org.junit.Test
import java.io.File

class WireTest {
    private val directory = File("../../protocol/fixtures")

    private fun fixtures() = directory.listFiles { file -> file.extension == "bin" }!!.sortedBy { it.name }

    private fun changed(
        source: ByteArray,
        index: Int,
        value: Int,
    ) = source.clone().also { it[index] = value.toByte() }

    private fun fails(source: ByteArray) {
        try {
            WireCodec.decode(source)
            fail("accepted malformed input")
        } catch (_: WireException) {
        }
    }

    @Test fun productionSessionBoundaryPreservesGoldenReadyAndRejectsFallback() {
        val config = SessionMessages.fromHost(WireCodec.decode(fixtures()[1].readBytes())!!) as HostEvent.Configure
        assertEquals(VideoCodecId.AVC, config.config.codec)
        assertEquals(40_000_000L, config.config.bitrate)
        val videoConfig = SessionMessages.fromVideoConfig(WireCodec.decode(fixtures()[4].readBytes())!!)
        assertEquals(2, videoConfig.parameterSets.size)
        val ready = ClientCommand.Ready(PhysicalMode(1600, 2456, 60000, 7), "synthetic")
        val (type, fields) = ready.fields(ByteArray(16) { it.toByte() }, 1u)
        assertArrayEquals(fixtures()[2].readBytes(), WireCodec.encode(WireMessage(type.id, 0uL, 0uL, fields)))
        val pointer =
            PointerReading(
                40_000_000,
                PointerTool.FINGER,
                PointerPhase.DOWN,
                InputPoint(0.5f, 0.5f),
                0.5f,
                0.5f,
                0.5f,
                0,
                0,
            )
        val (inputType, inputFields) =
            ClientCommand
                .Input(InputEvent.Pointers(listOf(pointer)), 0uL)
                .fields(ByteArray(16) { it.toByte() }, 1u)
        assertArrayEquals(fixtures()[8].readBytes(), WireCodec.encode(WireMessage(inputType.id, 0uL, 0uL, inputFields)))
        val invalid =
            WireCodec.decode(fixtures()[1].readBytes())!!.let {
                it.copy(fields = it.fields.toMutableList().also { fields -> fields[9] = Value.Number(5561uL) })
            }
        try {
            SessionMessages.fromHost(invalid)
            fail("accepted changed video port")
        } catch (_: WireException) {
        }
    }

    @Test fun everyRegisteredFixtureRoundTripsExactly() {
        val files = fixtures()
        assertEquals(24, files.size)
        files.forEachIndexed { index, file ->
            val data = file.readBytes()
            val message = WireCodec.decode(data)!!
            val expected =
                if (index < 22) {
                    index + 1
                } else if (index == 22) {
                    2
                } else {
                    5
                }
            assertEquals(file.name, expected, message.type)
            assertArrayEquals(file.name, data, WireCodec.encode(message))
            assertEquals(data.size - 32, WireCodec.payloadLength(data.copyOfRange(0, 32)))
        }
    }

    @Test fun malformedAndBounded() {
        val source = fixtures()[0].readBytes()
        fails(source.copyOfRange(0, 31))
        fails(changed(source, 0, 0))
        fails(changed(source, 5, 2))
        fails(changed(source, 11, 1))
        try {
            WireCodec.payloadLength(changed(source, 0, 0).copyOfRange(0, 32))
            fail("bad magic accepted before allocation")
        } catch (_: WireException) {
        }
        fails(changed(source, 20, 255))
        fails(source + byteArrayOf(0))
        val unknown = changed(changed(source, 8, 128), 9, 0)
        fails(unknown)
        assertNull(WireCodec.decode(changed(unknown, 7, 1)))
        fails(changed(fixtures()[1].readBytes(), 52, 9))
        val scroll = fixtures()[9].readBytes().clone()
        byteArrayOf(0x7f, 0xc0.toByte(), 0, 0).copyInto(scroll, 53)
        fails(scroll)
        val rejected = fixtures()[20].readBytes()
        fails(changed(rejected, rejected.size - 9, 255))
        fails(changed(source, source.size - 1, 2))
        assertEquals(Value.Text("Écran 💠"), WireCodec.decode(source)!!.fields[2])
        fails(changed(fixtures()[1].readBytes(), 32 + 16 + 4 + 1 + 1 + 2, 255))
        fails(changed(fixtures()[1].readBytes(), 32 + 16 + 4 + 1 + 1 + 2 + 8 + 3, 59))
        fails(changed(fixtures()[2].readBytes(), 32 + 16 + 4 + 3, 0))
        fails(changed(fixtures()[4].readBytes(), 70, 0x67))
        try {
            WireCodec.payloadLength(source.copyOfRange(0, 32), videoChannel = true)
            fail("control type accepted on video channel")
        } catch (_: WireException) {
        }
    }

    @Test fun fragmentedAndCoalescedReads() {
        val first = fixtures()[0].readBytes()
        val second = fixtures()[1].readBytes()
        val framer = WireFramer()
        val messages = first.flatMap { framer.append(byteArrayOf(it)) }.toMutableList()
        assertFalse(framer.hasIncompleteFrame)
        messages += framer.append(second + first)
        assertEquals(listOf(1, 2, 1), messages.map { (it as FramedRecord.Message).value.type })
        assertFalse(framer.hasIncompleteFrame)
        try {
            framer.append(changed(first, 20, 255))
            fail("oversize header")
        } catch (_: WireException) {
        }
    }

    @Test fun directionSequenceEpochAndVideoGeneration() {
        val hello = WireCodec.decode(fixtures()[0].readBytes())!!
        val order = WireOrder(WireOrder.Peer.CLIENT, WireOrder.Channel.CONTROL, 1uL)
        order.accept(hello)
        try {
            order.accept(hello)
            fail("duplicate")
        } catch (_: WireException) {
        }
        val unknown = changed(changed(changed(changed(fixtures()[0].readBytes(), 7, 1), 8, 128), 9, 0), 19, 1)
        val skipped = WireFramer().append(unknown).single() as FramedRecord.Skipped
        order.skipUnknown(skipped.sequence)
        val ready = WireCodec.decode(fixtures()[2].readBytes())!!
        order.accept(ready.copy(sequence = 2uL))
        try {
            WireOrder(WireOrder.Peer.HOST, WireOrder.Channel.CONTROL, 1uL).accept(hello)
            fail("direction")
        } catch (_: WireException) {
        }
        try {
            WireOrder(WireOrder.Peer.CLIENT, WireOrder.Channel.CONTROL, 2uL).accept(hello)
            fail("epoch")
        } catch (_: WireException) {
        }
        val config = WireCodec.decode(fixtures()[4].readBytes())!!
        val frame = WireCodec.decode(fixtures()[5].readBytes())!!
        val video = WireOrder(WireOrder.Peer.HOST, WireOrder.Channel.VIDEO, 1uL)
        try {
            video.accept(frame)
            fail("missing config")
        } catch (_: WireException) {
        }
        video.accept(config)
        video.accept(frame.copy(sequence = 1uL))
        try {
            video.accept(frame.copy(sequence = 2uL))
            fail("duplicate frame")
        } catch (_: WireException) {
        }
        val nextConfig =
            config.fields.toMutableList().also {
                it[1] = Value.Number(2uL)
                it[2] = Value.Number(2uL)
            }
        val nextFrame =
            frame.fields.toMutableList().also {
                it[1] = Value.Number(2uL)
                it[2] = Value.Number(2uL)
            }
        val reconnect = WireOrder(WireOrder.Peer.HOST, WireOrder.Channel.VIDEO, 2uL, previousGeneration = 1u)
        reconnect.accept(config.copy(fields = nextConfig))
        reconnect.accept(frame.copy(sequence = 1uL, fields = nextFrame))
    }
}
