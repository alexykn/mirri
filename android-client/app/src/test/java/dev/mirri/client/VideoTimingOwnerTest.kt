package dev.mirri.client

import dev.mirri.client.video.ReorderedFrameGaps
import dev.mirri.client.video.TimingHistogram
import dev.mirri.client.video.TimingLogMessage
import dev.mirri.client.video.VideoTimingOwner
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class VideoTimingOwnerTest {
    private val origin = 1_000_000_000L

    @Test fun wireNanosecondsTruncateToCodecMicrosecondsAndRenderUsesSuppliedTimeNotArrival() {
        val owner = VideoTimingOwner()
        owner.activate(atNs = origin)
        owner.setEpoch(3u)
        owner.startGeneration(7u)
        owner.received(7u, 0, 1_000_999L, origin)
        owner.inputAvailable(3, origin + 1_000_000)
        owner.inputAcquired(3, origin + 2_000_000)
        owner.inputQueued(1_000, origin + 4_000_000)
        owner.outputAvailable(1_000, origin + 16_000_000)
        owner.outputReleased(1_000, origin + 17_000_000, origin + 17_100_000)
        owner.outputReleased(1_000, origin + 17_200_000, origin + 17_300_000) // duplicate after transfer to render owner
        owner.rendered(1_000, origin + 21_000_000, origin + 150_000_000)
        val result = owner.drain(origin + 151_000_000)
        assertEquals(1L, result.counters.getValue("truncatedPts"))
        assertEquals(1L, result.counters.getValue("duplicate"))
        assertTrue(result.line().contains("epoch=3"))
        assertEquals(1L, result.totalReleased)
        assertEquals(1L, result.totalRendered)
        assertEquals(4_000_000L, result.stages.getValue(VideoTimingOwner.Stage.PACKET_TO_INPUT).maxNs)
        assertEquals(12_000_000L, result.stages.getValue(VideoTimingOwner.Stage.INPUT_TO_OUTPUT).maxNs)
        assertEquals(4_000_000L, result.stages.getValue(VideoTimingOwner.Stage.RELEASE_TO_RENDER).maxNs)
        assertEquals(21_000_000L, result.stages.getValue(VideoTimingOwner.Stage.PACKET_TO_RENDER).maxNs)
        assertEquals(129_000_000L, result.stages.getValue(VideoTimingOwner.Stage.RENDER_CALLBACK_DELAY).maxNs)
        owner.rendered(1_000, origin + 22_000_000, origin + 200_000_000)
        owner.outputAvailable(2_000, origin + 20_000_000)
        val diagnostics = owner.drain(origin + 201_000_000)
        assertEquals(1L, diagnostics.counters.getValue("duplicate"))
        assertEquals(1L, diagnostics.counters.getValue("unmatched"))
    }

    @Test fun batchedOutOfOrderRenderCallbacksUseRenderTimesInMediaSequence() {
        val owner = VideoTimingOwner()
        owner.activate(atNs = origin)
        owner.startGeneration(1u)
        for (seq in 0L..2) {
            val ptsNs = seq * 16_666_666L
            owner.received(1u, seq, ptsNs, origin + seq * 16_000_000)
            owner.inputQueued(ptsNs / 1000, origin + seq * 16_000_000 + 1_000_000)
            owner.outputAvailable(ptsNs / 1000, origin + seq * 16_000_000 + 2_000_000)
            owner.outputReleased(ptsNs / 1000, origin + seq * 16_000_000 + 3_000_000, origin + seq * 16_000_000 + 3_100_000)
        }
        owner.rendered(33_333, origin + 60_000_000, origin + 160_000_000)
        owner.rendered(0, origin + 25_000_000, origin + 170_000_000)
        owner.rendered(16_666, origin + 45_000_000, origin + 180_000_000)
        val result = owner.drain(origin + 181_000_000)
        assertEquals(3L, result.counters.getValue("rendered"))
        assertTrue(result.counters.getValue("reorderedRender") > 0)
        assertEquals(0L, result.counters.getValue("invalidClock"))
        assertEquals(2L, result.stages.getValue(VideoTimingOwner.Stage.RENDER_GAP).count)
        assertEquals(20_000_000L, result.stages.getValue(VideoTimingOwner.Stage.RENDER_GAP).maxNs)
        assertEquals(145_000_000L, result.stages.getValue(VideoTimingOwner.Stage.RENDER_CALLBACK_DELAY).maxNs)
    }

    @Test fun overflowGenerationReuseAndLateCallbacksStayDiagnosticOnly() {
        val owner = VideoTimingOwner(capacity = 2)
        owner.activate(atNs = origin)
        owner.startGeneration(3u)
        owner.received(3u, 0, 1_000L, origin)
        owner.outputReleased(1, origin + 10_000_000, origin + 10_100_000)
        owner.received(3u, 1, 2_000L, origin + 20_000_000)
        owner.received(3u, 2, 3_000L, origin + 40_000_000) // evicts oldest metadata
        owner.received(3u, 3, 3_999L, origin + 60_000_000) // same codec PTS_us
        val before = owner.drain(origin + 61_000_000)
        assertEquals(1L, before.counters.getValue("overflow"))
        assertEquals(1L, before.counters.getValue("missingRender"))
        assertEquals(1L, before.counters.getValue("duplicate"))
        assertEquals(2, before.highWater)
        owner.startGeneration(4u)
        owner.received(4u, 0, 2_000L, origin + 70_000_000) // ambiguous old media PTS, not attributed
        owner.rendered(2, origin + 80_000_000, origin + 90_000_000)
        owner.received(4u, 1, 5_000L, origin + 100_000_000)
        owner.endWindow(origin + 101_000_000)
        owner.close()
        owner.rendered(5, origin + 110_000_000, origin + 120_000_000)
        val after = owner.drain(origin + 121_000_000)
        assertEquals(0L, after.counters.getValue("late")) // post-window callback is censored, not assigned
        assertTrue(after.counters.getValue("ambiguousFrame") >= 2)
        assertEquals(1L, after.counters.getValue("ambiguousGeneration"))
        assertEquals(0L, after.totalRendered)
    }

    @Test fun absentRenderCallbacksCannotEvictAnActiveDecodeFrameOrLoseLaterStageCounts() {
        val owner = VideoTimingOwner(capacity = 3)
        owner.listenerInstalled()
        owner.activate(atNs = origin)
        owner.startGeneration(1u)

        fun receive(sequence: Long) {
            val pts = sequence * 1_000_000L
            val at = origin + sequence * 10_000_000L + 1_000_000L
            owner.received(1u, sequence, pts, at, keyframe = sequence == 0L, auBytes = if (sequence == 0L) 1_000 else 30)
            owner.inputQueued(pts / 1_000, at + 1_000_000L)
        }

        fun release(
            sequence: Long,
            at: Long,
        ) {
            val ptsUs = sequence * 1_000L
            owner.outputAvailable(ptsUs, at)
            owner.outputReleased(ptsUs, at + 1_000_000L, at + 1_100_000L)
        }

        receive(0) // Keep this older frame awaiting codec output.
        for (sequence in 1L..2L) {
            receive(sequence)
            release(sequence, origin + sequence * 10_000_000L + 3_000_000L)
        }
        receive(3) // Capacity reached: retire pending render 1, NOT active frame 0.
        release(0, origin + 34_000_000L)
        release(3, origin + 36_000_000L)
        for (sequence in 4L..11L) {
            receive(sequence)
            release(sequence, origin + sequence * 10_000_000L + 3_000_000L)
        }
        owner.endWindow(origin + 200_000_000L)
        val final = owner.drain()
        for (stage in listOf("received", "queued", "output", "released")) {
            assertEquals(stage, 12L, (if (stage == "released") final.totalReleased else final.counters.getValue(stage)))
        }
        assertEquals(9L, final.counters.getValue("overflow"))
        assertEquals(9L, final.counters.getValue("missingRender"))
        assertEquals(0L, final.counters.getValue("late"))
        assertEquals(0L, final.counters.getValue("unmatched"))
        assertEquals(0L, final.counters.getValue("missingOutputSeq"))
        assertEquals(3, final.outstanding)
        assertEquals(3, final.highWater) // Both maps share one unchanged capacity.
        assertEquals(3L, final.rightCensored)
        assertEquals(0L, final.interiorPending)
        assertEquals(0L, final.validRendered)
        assertEquals(1L, final.counters.getValue("keyReceived"))
        assertEquals(1L, final.counters.getValue("keyOutput"))
        assertEquals(1_000L, final.counters.getValue("keyBytes"))
        assertEquals(1L, final.stages.getValue(VideoTimingOwner.Stage.KEY_INPUT_TO_OUTPUT).count)
    }

    @Test fun keyAUArrivalAndOrderedOutputGapStayDistinctWithoutRenderCallbacks() {
        val owner = VideoTimingOwner()
        owner.activate(atNs = origin)
        owner.startGeneration(1u)
        for (sequence in 0L..2L) {
            val packet = origin + 1_000_000 + sequence * 20_000_000
            val pts = sequence * 1_000_000L
            owner.received(
                1u,
                sequence,
                pts,
                packet,
                keyframe = sequence == 1L,
                auBytes = if (sequence == 1L) 1_000 else 10 + sequence.toInt() * 10,
            )
            owner.inputQueued(pts / 1_000, packet + 1_000_000)
            owner.outputAvailable(pts / 1_000, packet + if (sequence == 1L) 7_000_000 else 5_000_000)
            owner.outputReleased(pts / 1_000, packet + 8_000_000, packet + 8_100_000)
        }
        owner.endWindow(origin + 100_000_000)
        val result = owner.drain()
        assertEquals(1L, result.counters.getValue("keyReceived"))
        assertEquals(1L, result.counters.getValue("keyOutput"))
        assertEquals(1_000L, result.counters.getValue("keyBytes"))
        assertEquals(40L, result.counters.getValue("otherBytes"))
        assertEquals(30L, result.counters.getValue("otherMaxBytes"))
        assertEquals(1L, result.stages.getValue(VideoTimingOwner.Stage.KEY_PACKET_GAP).count)
        assertEquals(20_000_000L, result.stages.getValue(VideoTimingOwner.Stage.KEY_PACKET_GAP).maxNs)
        assertEquals(6_000_000L, result.stages.getValue(VideoTimingOwner.Stage.KEY_INPUT_TO_OUTPUT).maxNs)
        assertEquals(22_000_000L, result.stages.getValue(VideoTimingOwner.Stage.KEY_OUTPUT_GAP).maxNs)
        assertEquals(2L, result.stages.getValue(VideoTimingOwner.Stage.OUTPUT_GAP).count)
        assertEquals(3L, result.rightCensored)
        assertEquals(0L, result.totalRendered)
        assertTrue(result.line().toByteArray(Charsets.UTF_8).size < 3_900)
    }

    @Test fun reorderedOutputGapClassFollowsSequenceNotCallbackArrival() {
        val total = TimingHistogram()
        val keyed = TimingHistogram()
        val ordered = ReorderedFrameGaps(total, keyed)
        ordered.add(1, origin + 50_000_000, origin + 1_000_000, keyframe = true)
        ordered.add(0, origin + 10_000_000, origin + 2_000_000)
        ordered.add(2, origin + 70_000_000, origin + 3_000_000)
        ordered.finish()
        assertEquals(2L, total.drain().count)
        val keySummary = keyed.drain()
        assertEquals(1L, keySummary.count)
        assertEquals(40_000_000L, keySummary.maxNs)
    }

    @Test fun absentRenderListenerIsUnavailableNotZeroLatencyAndInvalidClockIsCounted() {
        val owner = VideoTimingOwner()
        owner.listenerUnavailable()
        owner.activate(atNs = origin)
        owner.startGeneration(1u)
        owner.received(1u, 0, 0, origin)
        owner.inputQueued(0, origin + 1_000_000)
        owner.outputAvailable(0, origin + 2_000_000)
        owner.outputReleased(0, origin + 3_000_000, origin + 3_100_000)
        val first = owner.drain(origin + 4_000_000)
        assertFalse(first.renderListenerSeen)
        assertEquals(1L, first.totalReleased)
        assertEquals(0L, first.totalRendered)
        assertEquals(0L, first.stages.getValue(VideoTimingOwner.Stage.RELEASE_TO_RENDER).count)
        assertEquals(1L, first.counters.getValue("renderListenerUnavailable"))
        owner.rendered(0, origin + 2_000_000, origin + 10_000_000) // impossible: before release
        val bad = owner.drain(origin + 11_000_000)
        assertTrue(bad.counters.getValue("invalidClock") > 0)
        assertEquals(1L, bad.totalRendered)
        assertEquals(0L, bad.validRendered)
        assertEquals(1L, bad.counters.getValue("renderInvalid"))
    }

    @Test fun fixedBucketsAndMissingFrameExpiryDoNotInventFrames() {
        val histogram = TimingHistogram()
        listOf(1L, 5L, 30L, 100L, 200L).forEach { assertTrue(histogram.add(it * 1_000_000)) }
        assertFalse(histogram.add(-1))
        val results = histogram.drain()
        assertEquals(5L, results.count)
        assertEquals(30.0, results.upperBoundMs(.5)!!, .001)
        assertEquals(200.0, results.upperBoundMs(.95)!!, .001)
        assertEquals(200_000_000L, results.maxNs)
        assertEquals(0L, histogram.drain().count)
        assertTrue(histogram.add(11_000_000_000L))
        assertEquals(null, histogram.drain().upperBoundMs(.95))
        assertEquals(2_000_000L, TimingHistogram.boundsNs[0])
        assertEquals(100_000_000L, TimingHistogram.boundsNs[49])
        assertEquals(10_000_000_000L, TimingHistogram.boundsNs.last())
        assertEquals(59, results.buckets.size)
        listOf(25L to 26.0, 33L to 34.0, 50L to 50.0, 75L to 76.0, 100L to 100.0).forEach { (millis, upper) ->
            val one = TimingHistogram()
            assertTrue(one.add(millis * 1_000_000))
            assertEquals(upper, one.drain().upperBoundMs(.95)!!, .001)
        }

        val gaps = TimingHistogram()
        val reorder = ReorderedFrameGaps(gaps)
        reorder.add(1, origin + 20_000_000, origin)
        reorder.expire(origin + 1_000_000_001)
        assertEquals(1L, reorder.missing)
        assertEquals(0L, gaps.drain().count)
        reorder.add(2, origin + 60_000_000, origin + 1_000_000_002)
        assertEquals(1L, gaps.drain().count)

        val burst = TimingHistogram(trackGaps = true)
        listOf(16L, 33L, 60L).forEach { assertTrue(burst.add(it * 1_000_000)) }
        val open = burst.drain().gaps!!
        assertEquals(2L, open.over25)
        assertEquals(1L, open.over50)
        assertEquals(0L, open.over100)
        assertEquals(2L, open.openLength)
        assertEquals(0L, open.closed.sum())
        burst.add(16_000_000)
        val closed = burst.drain().gaps!!
        assertEquals(1L, closed.closed[1]) // one 2-gap burst across interval boundary
        assertEquals(2L, closed.longestClosed)
        burst.add(120_000_000)
        burst.finishGapRun()
        val final = burst.drain().gaps!!
        assertEquals(1L, final.over100)
        assertEquals(1L, final.closed[0])
    }

    @Test fun generationAndStopCloseOnlyOutstandingGapRuns() {
        val owner = VideoTimingOwner()
        owner.activate(atNs = origin)
        owner.startGeneration(1u)
        owner.received(1u, 0, 0, origin)
        owner.received(1u, 1, 60_000_000, origin + 60_000_000)
        assertEquals(
            1L,
            owner
                .drain(origin + 61_000_000)
                .stages
                .getValue(VideoTimingOwner.Stage.PACKET_GAP)
                .gaps!!
                .openLength,
        )
        owner.startGeneration(2u)
        val boundary =
            owner
                .drain(origin + 62_000_000)
                .stages
                .getValue(VideoTimingOwner.Stage.PACKET_GAP)
                .gaps!!
        assertEquals(1L, boundary.closed[0])
        assertEquals(0L, boundary.openLength)
        owner.received(2u, 0, 1_000_000_000, origin + 100_000_000)
        owner.received(2u, 1, 1_060_000_000, origin + 160_000_000)
        owner.close()
        val stopped =
            owner
                .drain(origin + 170_000_000)
                .stages
                .getValue(VideoTimingOwner.Stage.PACKET_GAP)
                .gaps!!
        assertEquals(1L, stopped.closed[0])
        assertEquals(0L, stopped.openLength)
    }

    @Test fun pendingFirstAndMiddleSequencesAreAccountedAtStopNotMisreadAsFrameGaps() {
        val gap = TimingHistogram(trackGaps = true)
        val ordered = ReorderedFrameGaps(gap)
        ordered.add(1, origin + 60_000_000, origin)
        assertEquals(0L, gap.drain().count)
        ordered.finish() // first sequence missing; no invented 0->1 duration
        assertEquals(1L, ordered.missing)
        assertEquals(0L, gap.drain().count)
        ordered.add(3, origin + 160_000_000, origin + 1)
        ordered.add(4, origin + 220_000_000, origin + 2)
        ordered.finish() // missing middle seq2; 1->3 is ambiguous, 3->4 is valid
        val final = gap.drain()
        assertEquals(2L, ordered.missing)
        assertEquals(1L, ordered.ambiguous)
        assertEquals(1L, final.count)
        assertEquals(60_000_000L, final.maxNs)
        ordered.finish()
        assertEquals(0L, gap.drain().count) // no duplicate on repeat

        val owner = VideoTimingOwner()
        owner.activate(atNs = origin)
        owner.startGeneration(1u)
        owner.received(1u, 1, 1_000L, origin)
        owner.outputAvailable(1, origin + 1)
        owner.startGeneration(2u)
        val boundary = owner.drain(origin + 2)
        assertEquals(1L, boundary.counters.getValue("missingOutputSeq"))
        owner.close()
        val finalLine = owner.drainLine()
        assertEquals(finalLine, owner.drainLine())
        assertTrue(finalLine.contains("final=1"))
    }

    @Test fun oneSecondDrainPreservesPendingAndMarksSkippedPredecessorAmbiguous() {
        val owner = VideoTimingOwner()
        owner.activate(atNs = origin)
        owner.startGeneration(1u)
        owner.received(1u, 0, 0, origin)
        owner.outputAvailable(0, origin + 10)
        owner.received(1u, 2, 20_000_000L, origin + 20_000_000)
        owner.outputAvailable(20_000, origin + 100_000_000)
        val mid = owner.drain(origin + 100_000_001)
        assertEquals(0L, mid.counters.getValue("ambiguousOutputGap"))
        owner.close()
        val end = owner.drain(origin + 100_000_002)
        assertEquals(1L, end.counters.getValue("missingOutputSeq"))
        assertEquals(1L, end.counters.getValue("ambiguousOutputGap"))
        assertEquals(0L, end.stages.getValue(VideoTimingOwner.Stage.OUTPUT_GAP).count)
        assertEquals(
            0L,
            end.stages
                .getValue(VideoTimingOwner.Stage.OUTPUT_GAP)
                .gaps!!
                .openLength,
        )
    }

    @Test fun reusedPtsAfterFlushAndOldCallbackBeyond64RemainUnjoined() {
        val owner = VideoTimingOwner()
        owner.activate(atNs = origin)
        owner.startGeneration(1u)
        for (seq in 0L..80L) owner.received(1u, seq, seq * 1_000, origin + seq * 1_000_000)
        owner.startGeneration(2u)
        owner.received(2u, 0, 1_000, origin + 90_000_000) // legitimate new media PTS, same as old
        owner.outputAvailable(1, origin + 91_000_000) // could be either codec generation
        owner.rendered(1, origin + 92_000_000, origin + 93_000_000)
        owner.received(2u, 1, 81_000L, origin + 94_000_000) // old PTS beyond last64
        val report = owner.drain(origin + 95_000_000)
        assertEquals(0L, report.stages.getValue(VideoTimingOwner.Stage.INPUT_TO_OUTPUT).count)
        assertEquals(0L, report.totalRendered)
        assertEquals(0L, report.validRendered)
        assertEquals(0, report.outstanding)
        assertTrue(report.counters.getValue("ambiguousFrame") >= 4)
        assertEquals(0L, report.counters.getValue("late"))
        assertTrue(report.line().contains("joinAvailable=0"))
    }

    @Test fun metadataExpiresAfterIdleAndLateRenderDoesNotFabricateCoverage() {
        val owner = VideoTimingOwner()
        owner.activate(atNs = origin)
        owner.startGeneration(1u)
        owner.listenerInstalled()
        owner.received(1u, 0, 0, origin)
        owner.outputAvailable(0, origin + 1_000_000)
        owner.outputReleased(0, origin + 2_000_000, origin + 3_000_000)
        val expired = owner.drain(origin + 30_000_000_000)
        assertEquals(1L, expired.counters.getValue("expired"))
        assertEquals(1L, expired.counters.getValue("missingRender"))
        assertEquals(0, expired.outstanding)
        owner.rendered(0, origin + 31_000_000_000, origin + 31_001_000_000)
        val after = owner.drain(origin + 31_002_000_000)
        assertEquals(1L, after.counters.getValue("late"))
        assertEquals(0L, after.totalRendered)
        assertEquals(0L, after.validRendered)
        assertTrue(after.renderListenerInstalled)
        assertTrue(after.renderListenerSeen)
        assertTrue(after.line().toByteArray(Charsets.UTF_8).size < 3_900) // bounded collector record budget
    }

    @Test fun regularStopFreezesRightCensoredTailBeforeDecoderTeardown() {
        val owner = VideoTimingOwner()
        owner.setEpoch(9u)
        owner.listenerInstalled()
        owner.activate(atNs = origin)
        owner.startGeneration(1u)
        owner.received(1u, 0, 0, origin + 1_000_000)
        owner.inputQueued(0, origin + 2_000_000)
        owner.outputAvailable(0, origin + 3_000_000)
        owner.outputReleased(0, origin + 4_000_000, origin + 5_000_000)
        owner.received(1u, 1, 4_000_000_000, origin + 4_000_000_000)
        owner.inputQueued(4_000_000, origin + 4_001_000_000)
        owner.outputAvailable(4_000_000, origin + 4_002_000_000)
        owner.outputReleased(4_000_000, origin + 4_003_000_000, origin + 4_004_000_000)
        owner.endWindow(origin + 5_000_000_000)
        owner.close() // no callbacks available after normal owner teardown
        owner.rendered(4_000_000, origin + 5_100_000_000, origin + 5_200_000_000)
        val summary = owner.drain()
        assertEquals(1L, summary.rightCensored)
        assertEquals(1L, summary.interiorPending)
        assertEquals(0L, summary.counters.getValue("missingRender"))
        assertEquals(2L, summary.totalReleased)
        assertEquals(0L, summary.validRendered)
        assertEquals(origin, summary.startNs)
        assertEquals(origin + 5_000_000_000, summary.endNs)
        assertEquals(summary.line(), owner.drainLine())
    }

    @Test fun productionPayloadEmitterFullAndPartialWindows() {
        val origin = 1_000_000_000L
        for (mode in listOf("full", "partial", "no-render")) {
            val offset = if (mode == "partial") 250_000_000L else 0L
            val start = origin + offset
            val owner = VideoTimingOwner()
            owner.setEpoch(7u)
            if (mode == "no-render") owner.listenerUnavailable() else owner.listenerInstalled()
            owner.activate(atNs = start)
            owner.startGeneration(1u)
            val lines = mutableListOf<String>()
            var nextBoundary = origin + 1_000_000_000L
            for (frame in 0L until 5_400L) {
                val pts = frame * 16_666_666L
                val received = start + pts + 1_000_000L
                while (nextBoundary <= received + 4_000_000L) {
                    lines += TimingLogMessage.interval(owner, nextBoundary)!!
                    nextBoundary += 1_000_000_000L
                }
                owner.received(1u, frame, pts, received, keyframe = frame % 60L == 0L, auBytes = if (frame % 60L == 0L) 80 else 20)
                owner.inputQueued(pts / 1_000L, received) // Packet-to-input zero duration is valid.
                owner.outputAvailable(pts / 1_000L, received + 2_000_000L)
                owner.outputReleased(pts / 1_000L, received + 3_000_000L, received + 3_100_000L)
                if (mode != "no-render") owner.rendered(pts / 1_000L, received + 4_000_000L, received + 4_100_000L)
            }
            owner.endWindow(start + 90_000_000_000L)
            lines += TimingLogMessage.final(owner)
            assertTrue(lines.first().contains("record=0 startNs=$start "))
            assertTrue(lines.last().contains("final=1"))
            assertTrue(lines.maxOf { it.toByteArray(Charsets.UTF_8).size } < 3_900)
            assertEquals(if (offset == 0L) 90 else 91, lines.size)
            System.getenv("MIRRI_TIMING_EMITTER_DIR")?.let { directory ->
                val name = "client-$mode.log"
                File(
                    directory,
                    name,
                ).writeText(lines.joinToString(separator = "\n", postfix = "\n") { "1727366400.000 123 456 I MirriTiming: $it" })
            }
        }
    }
}
