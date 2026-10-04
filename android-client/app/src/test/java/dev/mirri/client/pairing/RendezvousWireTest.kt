package dev.mirri.client.pairing

import dev.mirri.client.protocol.WireException
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.ByteBuffer

class RendezvousWireTest {
    private val pairing = Pairing(ByteArray(16) { 0x11 }, ByteArray(32) { 0x22 }, ByteArray(32) { 0x33 }, null)

    @Test fun helloMatchesTheHostLayout() {
        val hello = ByteArray(57).also { RendezvousWire.hello(pairing, RendezvousWire.REASON_RECOVERING).get(it) }
        assertArrayEquals(byteArrayOf(0x4d, 0x52, 0x52, 0x56, 0, 1, 0, 1), hello.copyOfRange(0, 8))
        assertArrayEquals(pairing.id, hello.copyOfRange(8, 24))
        assertArrayEquals(pairing.key, hello.copyOfRange(24, 56))
        assertEquals(2, hello[56].toInt())
    }

    @Test fun launchDecodesTheHostFrameAndRejectsBadShapes() {
        val body = ByteBuffer.allocate(89)
        body.put(ByteArray(32) { 0x12 })
        body.putInt(7)
        body.put(byteArrayOf(192.toByte(), 0, 2, 15))
        body.put(ByteArray(32) { 0x34 })
        body.put(1)
        body.put(ByteArray(16) { 0x56 })
        body.flip()
        val launch = RendezvousWire.launch(body)
        assertEquals(7, launch.epoch)
        assertEquals("192.0.2.15", launch.host)
        assertTrue(launch.rtc)
        assertArrayEquals(ByteArray(16) { 0x56 }, launch.sessionId)
        assertThrows(WireException::class.java) { RendezvousWire.launch(ByteBuffer.allocate(88)) }
        val zeroEpoch = ByteBuffer.allocate(89)
        assertThrows(WireException::class.java) { RendezvousWire.launch(zeroEpoch) }
    }

    @Test fun headerKindRequiresMagicAndVersion() {
        fun header(vararg bytes: Int) = ByteBuffer.wrap(ByteArray(bytes.size) { bytes[it].toByte() })
        assertEquals(RendezvousWire.KIND_WAIT, RendezvousWire.kind(header(0x4d, 0x52, 0x52, 0x56, 0, 1, 0, 2)))
        assertEquals(RendezvousWire.KIND_LAUNCH, RendezvousWire.kind(header(0x4d, 0x52, 0x52, 0x56, 0, 1, 0, 3)))
        assertThrows(WireException::class.java) { RendezvousWire.kind(header(0x4d, 0x52, 0x4e, 0x42, 0, 1, 0, 2)) }
        assertThrows(WireException::class.java) { RendezvousWire.kind(header(0x4d, 0x52, 0x52, 0x56, 0, 2, 0, 2)) }
    }

    @Test fun hexAcceptsOnlyLowercasePairs() {
        assertArrayEquals(byteArrayOf(0x0a, 0xff.toByte()), Hex.decode("0aff"))
        assertNull(Hex.decode("0AFF"))
        assertNull(Hex.decode("abc"))
        assertEquals("0aff", Hex.encode(byteArrayOf(0x0a, 0xff.toByte())))
    }
}
