package dev.mirri.client

import dev.mirri.client.video.PresentationPacer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PresentationPacerTest {
    private fun spacing(milliHz: Long): Long = (1_000_000_000_000L + milliHz - 1) / milliHz

    @Test fun evenlySpacedFramesAreReleasedImmediately() {
        for (panel in listOf(60_000L, 120_000L)) {
            val pacer = PresentationPacer(panel, leadNs = 0)
            for (frame in 0L until 10L) {
                val now = frame * 16_666_667L
                assertEquals(now, pacer.next(now))
            }
        }
    }

    @Test fun twoFramesInsideOneRefreshAreSpacedOneRefreshApart() {
        val pacer = PresentationPacer(120_000, leadNs = 0)
        assertEquals(1_000_000L, pacer.next(1_000_000L))
        assertEquals(1_000_000L + spacing(120_000), pacer.next(3_000_000L))
        // The next on-time frame is not delayed by the earlier spacing.
        assertEquals(20_000_000L, pacer.next(20_000_000L))
    }

    @Test fun sixtyHertzPanelNeverStampsTwoFramesInsideOneRefresh() {
        val pacer = PresentationPacer(60_000, leadNs = 0)
        // Arrival jitter: a late frame followed by frames only 12 ms apart.
        val arrivals = listOf(0L, 26_000_000L, 38_000_000L, 50_000_000L, 66_000_000L, 100_000_000L)
        val stamps = arrivals.map { pacer.next(it) }
        stamps.zipWithNext().forEach { (a, b) -> assertTrue(b - a >= spacing(60_000)) }
        stamps.zip(arrivals).forEach { (stamp, now) -> assertTrue(stamp - now in 0..16_666_667L) }
        // A frame arriving after the queued delay has passed is on time again.
        assertEquals(100_000_000L, stamps.last())
    }

    @Test fun burstAfterStallIsBoundedToOneStreamFrameAhead() {
        for (panel in listOf(60_000L, 120_000L)) {
            val pacer = PresentationPacer(panel, leadNs = 0)
            val now = 500_000_000L
            val stamps = (0 until 6).map { pacer.next(now) }
            assertEquals(now, stamps.first())
            assertEquals(now + minOf(spacing(panel), 16_666_667L), stamps[1])
            assertTrue(stamps.all { it <= now + 16_666_667L })
            assertEquals(stamps, stamps.sorted())
        }
    }

    @Test fun unknownPanelAndResetKeepImmediateRelease() {
        val unknown = PresentationPacer(0)
        assertEquals(5L, unknown.next(5L))
        assertEquals(6L, unknown.next(6L))
        val pacer = PresentationPacer(120_000, leadNs = 0)
        pacer.next(1_000_000L)
        pacer.reset()
        assertEquals(1_500_000L, pacer.next(1_500_000L))
    }

    @Test fun leadShiftsEveryStampWithoutChangingSpacing() {
        val pacer = PresentationPacer(60_000, leadNs = 24_000_000L)
        assertEquals(24_000_000L, pacer.next(0L))
        // 5 ms later: spaced one refresh after the first, not one lead after now.
        assertEquals(24_000_000L + spacing(60_000), pacer.next(5_000_000L))
        assertEquals(124_000_000L, pacer.next(100_000_000L))
    }
}
