package dev.mirri.client.video

import java.util.TreeMap

/** Consecutive >25 ms frame-gap runs span reporting intervals. Only closed
 * runs enter the five bounded length buckets (1, 2, 3–5, 6–15, 16+). */
class GapBursts {
    data class Summary(
        val over25: Long,
        val over50: Long,
        val over100: Long,
        val closed: LongArray,
        val longestClosed: Long,
        val openLength: Long,
    ) {
        fun line(): String = "$over25.$over50.$over100.${closed.joinToString(".")}.$longestClosed.$openLength"
    }

    private var over25 = 0L
    private var over50 = 0L
    private var over100 = 0L
    private val closed = LongArray(5)
    private var longestClosed = 0L
    private var openLength = 0L

    fun observe(ns: Long) {
        if (ns > 25_000_000) {
            over25++
            openLength++
        } else {
            finish()
        }
        if (ns > 50_000_000) over50++
        if (ns > 100_000_000) over100++
    }

    fun finish() {
        if (openLength == 0L) return
        val bucket =
            when (openLength) {
                1L -> 0
                2L -> 1
                in 3L..5L -> 2
                in 6L..15L -> 3
                else -> 4
            }
        closed[bucket]++
        longestClosed = maxOf(longestClosed, openLength)
        openLength = 0
    }

    fun drain(): Summary =
        Summary(over25, over50, over100, closed.clone(), longestClosed, openLength).also {
            over25 = 0
            over50 = 0
            over100 = 0
            closed.fill(0)
            longestClosed = 0
        }
}

/** Schema 4 retains the 2 ms bins to 100 ms, bounded tail, and >10 s overflow.
 * Quantiles are conservative bucket bounds; overflow has no finite bound. */
class TimingHistogram(
    trackGaps: Boolean = false,
) {
    companion object {
        val boundsNs =
            (1L..50L).map { it * 2_000_000 }.toLongArray() +
                longArrayOf(125, 150, 200, 250, 500, 1_000, 5_000, 10_000).map { it * 1_000_000 }.toLongArray()
    }

    data class Summary(
        val buckets: LongArray,
        val maxNs: Long,
        val gaps: GapBursts.Summary?,
    ) {
        val count: Long get() = buckets.sum()

        fun upperBoundMs(fraction: Double): Double? {
            if (count == 0L) return null
            val rank =
                kotlin.math
                    .ceil(count * fraction)
                    .toLong()
                    .coerceAtLeast(1)
            var n = 0L
            for ((index, value) in buckets.withIndex()) {
                n += value
                if (n >= rank) return boundsNs.getOrNull(index)?.div(1e6)
            }
            return null
        }

        fun line(): String =
            "$count:${upperBoundMs(.5) ?: -1.0}:${upperBoundMs(.95) ?: -1.0}:" +
                "${upperBoundMs(.99) ?: -1.0}:${if (count > 0) maxNs / 1e6 else -1.0}:" +
                buckets.joinToString(".") + ":${gaps?.line() ?: "na"}"
    }

    private val buckets = LongArray(boundsNs.size + 1)
    private val gaps = if (trackGaps) GapBursts() else null
    private var maxNs = 0L

    /** Negative deltas are invalid; arbitrarily long positive stalls remain in overflow. */
    fun add(nanos: Long): Boolean {
        if (nanos < 0) return false
        val position = boundsNs.indexOfFirst { nanos <= it }.let { if (it < 0) boundsNs.size else it }
        buckets[position]++
        maxNs = maxOf(maxNs, nanos)
        gaps?.observe(nanos)
        return true
    }

    fun finishGapRun() {
        gaps?.finish()
    }

    fun drain(): Summary =
        Summary(buckets.clone(), maxNs, gaps?.drain()).also {
            buckets.fill(0)
            maxNs = 0
        }
}

/** Each sequence is ordered by media sequence, not callback arrival. Missing
 * callbacks expire after 1 s or 64 pending records; no synthetic frame is emitted. */
internal class ReorderedFrameGaps(
    private val histogram: TimingHistogram,
    private val keyedHistogram: TimingHistogram? = null,
) {
    private data class Observed(
        val timestampNs: Long,
        val observedNs: Long,
        val keyframe: Boolean,
    )

    private val pending = TreeMap<Long, Observed>() // sequence -> timestamp, observed-at, keyframe
    private var expected = 0L
    private var previousNs: Long? = null
    var missing = 0L
    var reordered = 0L
    var ambiguous = 0L
    var invalid = 0L
        private set

    fun reset() {
        check(pending.isEmpty()) { "finish outstanding reorder records before reset" }
        pending.clear()
        expected = 0
        previousNs = null
    }

    fun clearStats() {
        missing = 0
        reordered = 0
        ambiguous = 0
        invalid = 0
    }

    fun add(
        sequence: Long,
        timestampNs: Long,
        observedNs: Long,
        keyframe: Boolean = false,
    ) {
        if (sequence < expected || pending.containsKey(sequence)) {
            reordered++
            return
        }
        if (sequence > expected) reordered++
        pending[sequence] = Observed(timestampNs, observedNs, keyframe)
        expire(observedNs)
    }

    fun expire(observedNs: Long) = consume(observedNs, force = false)

    /** A final boundary consumes every available record in sequence order,
     * but NEVER interprets a multi-frame gap over unknown predecessors as a
     * single physical stutter. Idempotent when called again. */
    fun finish() = consume(Long.MAX_VALUE, force = true)

    private fun consume(
        observedNs: Long,
        force: Boolean,
    ) {
        while (pending.isNotEmpty()) {
            if (!pending.containsKey(expected) && !advanceMissing(observedNs, force)) return
            val next = pending.remove(expected) ?: return
            previousNs?.let {
                val gap = next.timestampNs - it
                if (!histogram.add(gap)) {
                    invalid++
                } else if (next.keyframe) {
                    keyedHistogram?.add(gap)
                }
            }
            previousNs = next.timestampNs
            expected++
        }
    }

    private fun advanceMissing(
        observedNs: Long,
        force: Boolean,
    ): Boolean {
        val oldest = pending.firstEntry() ?: return false
        val fresh = observedNs < oldest.value.observedNs || observedNs - oldest.value.observedNs < 1_000_000_000
        if (!force && pending.size < 64 && fresh) return false
        missing += (oldest.key - expected).coerceAtLeast(0)
        if (previousNs != null) ambiguous++
        histogram.finishGapRun()
        previousNs = null
        expected = oldest.key
        return true
    }
}
