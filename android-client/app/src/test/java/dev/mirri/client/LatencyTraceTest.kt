package dev.mirri.client

import dev.mirri.client.video.ClientLatencyTrace
import dev.mirri.client.video.VideoTimingOwner
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class LatencyTraceTest {
    private val id = ByteArray(16) { it.toByte() }

    @Test fun sampledFramesUseActualDecoderJoinsAndRenderCensoring() {
        val owner = VideoTimingOwner()
        owner.setEpoch(9u)
        owner.setTraceIdentity(id)
        owner.activate(atNs = 1_500_000_000L)
        owner.startGeneration(1u)
        owner.received(1u, 0, 999L, 1_560_000_000L)
        owner.inputQueued(0L, 1_561_000_000L)
        owner.outputAvailable(0L, 1_575_000_000L)
        owner.outputReleased(0L, 1_584_000_000L, 1_585_000_000L)
        owner.rendered(0L, 1_584_500_000L, 1_596_000_000L)
        owner.received(1u, 6, 600_999L, 1_660_000_000L)
        owner.inputQueued(600L, 1_661_000_000L)
        owner.outputAvailable(600L, 1_675_000_000L)
        owner.outputReleased(600L, 1_684_000_000L, 1_685_000_000L)
        val first = owner.drainLatencyLine(atNs = 2_700_000_000L)!!
        assertTrue(first.contains("selected=2 missing=0 dropped=0 ambiguous=0 censored=0"))
        assertTrue(first.contains("1,0,0,1560000000,1561000000,1575000000,1584000000,1585000000,1584500000"))
        assertTrue(!first.contains("1,6,600,"))
        assertEquals(ClientLatencyTrace.identity(id), first.substringAfter("trace=").substringBefore(' '))
        owner.rendered(600L, 3_010_000_000L, 3_020_000_000L) // >1s old, still owned by v4.
        val slow = owner.drainLatencyLine(atNs = 3_100_000_000L)!!
        assertTrue(slow.contains("1,6,600,1660000000,1661000000,1675000000,1684000000,1685000000,3010000000"))
        assertTrue(slow.contains("selected=0 missing=0 dropped=0 ambiguous=0 censored=0"))
    }

    @Test fun productionClientLatencyEmitter() {
        val owner = VideoTimingOwner()
        owner.setEpoch(9u)
        owner.setTraceIdentity(id)
        owner.activate(atNs = 1_500_000_000L)
        owner.startGeneration(1u)
        val lines = mutableListOf<String>()
        for (sequence in 0L until 120L) {
            if (sequence == 60L) lines += owner.drainLatencyLine(atNs = 2_550_000_000L)!!
            val pts = sequence * 16_666_666L
            val packet = 1_560_000_000L + pts
            owner.received(1u, sequence, pts, packet)
            owner.inputQueued(pts / 1_000L, packet + 1_000_000L)
            owner.outputAvailable(pts / 1_000L, packet + 15_000_000L)
            owner.outputReleased(pts / 1_000L, packet + 24_000_000L, packet + 25_000_000L)
            owner.rendered(pts / 1_000L, packet + 24_500_000L, packet + 36_000_000L)
        }
        owner.endWindow(atNs = 3_550_000_000L)
        lines += owner.drainLatencyLine(atNs = 3_550_000_000L, final = true)!!
        assertEquals(2, lines.size)
        assertTrue(lines.all { it.toByteArray(Charsets.UTF_8).size < 3_900 })
        assertTrue(lines.last().contains("final=1"))
        System.getenv("MIRRI_TIMING_EMITTER_DIR")?.let { directory ->
            File(directory, "client-latency.log").writeText(
                lines.joinToString(separator = "\n", postfix = "\n") { "1727366400.000 123 456 I MirriLatencyTrace: $it" },
            )
        }
    }

    @Test fun unresolvedRenderIsCensoredAtOwnerFinalNotAtOneSecond() {
        val owner = VideoTimingOwner()
        owner.setEpoch(9u)
        owner.setTraceIdentity(id)
        owner.activate(atNs = 1_500_000_000L)
        owner.startGeneration(1u)
        owner.received(1u, 6, 600_000L, 1_560_000_000L)
        owner.inputQueued(600L, 1_570_000_000L)
        owner.outputAvailable(600L, 1_580_000_000L)
        owner.outputReleased(600L, 1_590_000_000L, 1_591_000_000L)
        val intermediate = owner.drainLatencyLine(atNs = 2_800_000_000L)!!
        assertTrue(intermediate.contains("selected=1 missing=0 dropped=0 ambiguous=0 censored=0"))
        assertTrue(intermediate.contains("frames=-"))
        owner.endWindow(atNs = 3_500_000_000L)
        val final = owner.drainLatencyLine(final = true)!!
        assertTrue(final.contains("selected=0 missing=0 dropped=0 ambiguous=0 censored=1"))
        assertTrue(final.contains("1,6,600,1560000000,1570000000,1580000000,1590000000,1591000000,0"))
    }

    @Test fun readyOverflowIsExplicitAndWorstCaseNumericLineIsBounded() {
        val trace = ClientLatencyTrace(id, "network")
        trace.activate(1)
        val largestSequence = Long.MAX_VALUE - Long.MAX_VALUE % 6
        repeat(26) { index ->
            val sample = trace.select(1u, largestSequence - index * 6, Long.MAX_VALUE, Long.MAX_VALUE - 20)!!
            sample.inputNs = Long.MAX_VALUE - 19
            sample.outputNs = Long.MAX_VALUE - 18
            sample.releaseRequestNs = Long.MAX_VALUE - 17
            sample.releaseNs = Long.MAX_VALUE - 16
            sample.renderNs = Long.MAX_VALUE - 15
            trace.complete(sample)
        }
        val line = trace.report(UInt.MAX_VALUE, UInt.MAX_VALUE, false, Long.MAX_VALUE)
        assertTrue(line.contains("selected=26 missing=0 dropped=6"))
        assertTrue(line.toByteArray(Charsets.US_ASCII).size + 50 < 3_900) // logcat prefix margin
    }
}
