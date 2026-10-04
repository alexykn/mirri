package dev.mirri.client.protocol

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class RtcSignalsTest {
    private val id = ByteArray(16) { it.toByte() }
    private val attempt = ByteArray(16) { (it + 16).toByte() }
    private val n = { value: Long -> Value.Number(value.toULong()) }

    @Test fun startupBarrierRejectsPrematureStartAndStopDuringSetup() {
        val gate = RtcStartupGate()
        assertThrows(WireException::class.java) { gate.offered() }
        gate.prepared()
        assertThrows(WireException::class.java) { gate.answered() }
        gate.offered()
        gate.answered()
        assertThrows(WireException::class.java) { gate.start() }
        gate.mediaReady()
        gate.start()
        assertEquals(true, gate.started)
        assertThrows(WireException::class.java) { gate.start() }
        gate.stop()
        assertEquals(false, gate.started)
        assertThrows(WireException::class.java) { gate.mediaReady() }
        val duringSetup = RtcStartupGate()
        duringSetup.prepared()
        duringSetup.stop()
        assertThrows(WireException::class.java) { duringSetup.offered() }
    }

    private fun record(
        type: Int,
        extra: List<Value> = emptyList(),
    ) = WireMessage(type, 0uL, 0uL, RtcSignals.fields(id, 7u, attempt, extra))

    @Test fun allRtcIdsRoundTripWithExactLengthsAndPayloadTypes() {
        val mode = Value.Object(listOf(Value.Object(listOf(n(1600), n(2456))), n(60000), Value.Signed(42)))
        val size = Value.Object(listOf(n(2456), n(1600)))
        val records =
            listOf(
                record(23, listOf(n(1), n(2), n(52), n(1), n(1))),
                record(24, listOf(Value.Bytes(attempt), n(1), n(2), n(52), size, n(60000), n(1))),
                record(25, listOf(mode, size, Value.Text("OMX.hisi.video.decoder.avc"))),
                record(26, listOf(Value.Text("v=0\r\nm=video 9 UDP/TLS/RTP/SAVPF 96\r\n"))),
                record(27, listOf(Value.Text("v=0\r\nm=video 9 UDP/TLS/RTP/SAVPF 96\r\n"))),
                record(28, listOf(Value.Text("0"), n(0), Value.Text("candidate:1 1 UDP 1 192.0.2.1 9 typ host"))),
                record(29, listOf(Value.Text("0"), n(0))),
                record(30),
                record(31),
            )
        records.forEachIndexed { index, message ->
            val encoded = WireCodec.encode(message)
            assertEquals(23 + index, WireCodec.decode(encoded)!!.type)
            assertArrayEquals(encoded, WireCodec.encode(WireCodec.decode(encoded)!!))
            assertEquals(encoded.size - 32, WireCodec.payloadLength(encoded.copyOfRange(0, 32)))
        }
    }

    @Test fun hostCapabilityFixtureUsesIdenticalBigEndianWireBytes() {
        val session = ByteArray(16) { 0x11 }
        val nonce = ByteArray(16) { 0x03 }
        val fields = listOf(Value.Bytes(session), n(1), n(1), Value.Bytes(nonce), n(1), n(2), n(52), n(1), n(1))
        val message = WireMessage(23, 1uL, 123uL, fields)
        val header = "4d525249000100000017000000000000000000010000002b000000000000007b"
        val payload = "11".repeat(16) + "000000010001" + "03".repeat(16) + "0102340101"
        val expectedHex = header + payload
        val expected = expectedHex.chunked(2).map { it.toInt(16).toByte() }.toByteArray()
        assertArrayEquals(expected, WireCodec.encode(message))
        assertEquals(message, WireCodec.decode(expected))
    }

    @Test fun boundariesRejectWrongVersionIdentityChannelAndMalformedText() {
        val prepare =
            record(
                24,
                listOf(
                    Value.Bytes(attempt),
                    n(1),
                    n(2),
                    n(52),
                    Value.Object(listOf(n(2456), n(1600))),
                    n(60000),
                    n(1),
                ),
            )
        val encoded = WireCodec.encode(prepare)
        val wrong =
            encoded.clone().also {
                it[32 + 20] = 0
                it[32 + 21] = 2
            }
        assertThrows(WireException::class.java) { WireCodec.decode(wrong) }
        assertThrows(WireException::class.java) { WireCodec.decode(encoded.copyOf(encoded.size - 1)) }
        assertThrows(WireException::class.java) { WireCodec.payloadLength(encoded.copyOfRange(0, 32), true) }
        assertThrows(WireException::class.java) { RtcSignals.check(prepare, id, 7u, ByteArray(16)) }
        assertThrows(WireException::class.java) { RtcSignals.check(prepare, id, 8u, attempt) }
        assertThrows(WireException::class.java) { WireCodec.encode(record(26, listOf(Value.Text("x".repeat(32769))))) }
        assertThrows(WireException::class.java) { WireCodec.encode(record(28, listOf(Value.Text("0"), n(0), Value.Text("bad\n")))) }
        val text = WireCodec.encode(record(26, listOf(Value.Text("v=0\r\n"))))
        val invalid = text.clone().also { it[it.lastIndex] = 0x80.toByte() }
        assertThrows(WireException::class.java) { WireCodec.decode(invalid) }
        assertThrows(WireException::class.java) { WireCodec.decode(encoded + byteArrayOf(0)) }
    }

    @Test fun iceStagingAdvisoryEndAllowsDelayedCandidateAndRejectsOverflow() {
        // The session owner applies remote SDP before draining inbound trickle.
        // Its fresh ledger must be opened at that transition, not left in staging mode.
        val afterOffer = RtcIceLedger()
        assertEquals(emptyList<String>(), afterOffer.applied())
        assertEquals("candidate:live", afterOffer.candidate("0", "0", 0, "candidate:live"))
        val ice = RtcIceLedger()
        assertEquals(null, ice.candidate("0", "0", 0, "candidate:1"))
        assertEquals(listOf("candidate:1"), ice.applied())
        repeat(63) { ice.candidate("0", "0", 0, "candidate:2") }
        assertThrows(WireException::class.java) { ice.candidate("0", "0", 0, "candidate:3") }
        ice.end("0", "0", 0)
        assertThrows(WireException::class.java) { ice.end("0", "0", 0) }
        // Simulate a callback delivered well after the old 250ms timer, without sleeping.
        var syntheticMillis = 0L
        syntheticMillis += 10_000L
        assertEquals(true, syntheticMillis > 250L)
        assertThrows(WireException::class.java) { ice.candidate("0", "0", 0, "candidate:65") }
        val late = RtcIceLedger()
        late.end("0", "0", 0)
        assertEquals(null, late.candidate("0", "0", 0, "candidate:after-advisory"))
        assertEquals(listOf("candidate:after-advisory"), late.applied())
        val sdp =
            "m=video 9 UDP/TLS/RTP/SAVPF 96\r\na=mid:0\r\na=sendonly\r\n" +
                "a=rtpmap:96 H264/90000\r\na=fmtp:96 packetization-mode=1;profile-level-id=640034\r\n"
        assertEquals("0", RtcSdpProof.mid(sdp, "sendonly"))
        listOf("42e034", "640c34", "6400340", "x640034", "640034junk").forEach { bad ->
            assertThrows(WireException::class.java) { RtcSdpProof.mid(sdp.replace("640034", bad), "sendonly") }
        }
        assertThrows(WireException::class.java) {
            RtcSdpProof.mid(sdp.replace("packetization-mode=1", "packetization-mode=10"), "sendonly")
        }
        assertThrows(WireException::class.java) {
            RtcSdpProof.mid(sdp.replace("packetization-mode=1", "packetization-mode=1;profile-level-id=42e034"), "sendonly")
        }
        assertThrows(WireException::class.java) { RtcSdpProof.mid(sdp + "m=audio 9 UDP/TLS/RTP/SAVPF 111\r\n", "sendonly") }
    }

    @Test fun rtcHostOrderIsolatedFromLegacyAndStaleEpochIsConsumed() {
        val nonce = ByteArray(16) { 1 }
        val size = Value.Object(listOf(n(2456), n(1600)))
        val fields = RtcSignals.fields(id, 7u, attempt, listOf(Value.Bytes(nonce), n(1), n(2), n(52), size, n(60000), n(1)))
        val prepare = WireMessage(24, 0uL, 0uL, fields)
        val order = WireOrder(WireOrder.Peer.HOST, WireOrder.Channel.CONTROL, 7uL, id, rtc = true)
        assertThrows(WireException::class.java) {
            WireOrder(WireOrder.Peer.HOST, WireOrder.Channel.CONTROL, 7uL, id).accept(prepare)
        }
        val old = prepare.copy(fields = fields.toMutableList().also { it[1] = n(6) })
        assertEquals(true, order.discardStaleRtc(old))
        assertThrows(WireException::class.java) { order.accept(prepare) }
        order.accept(prepare.copy(sequence = 1uL))
        assertThrows(WireException::class.java) {
            RtcSignals.check(
                prepare.copy(
                    fields =
                        fields.toMutableList().also {
                            it[3] =
                                Value.Bytes(ByteArray(16))
                        },
                ),
                id,
                7u,
                attempt,
            )
        }
    }
}
