package dev.mirri.client.video

/** Device-local monotonic receive-to-decoder-release timing, not panel scanout. */
internal class DecoderFrameAges(
    private val capacity: Int = 64,
) {
    data class Summary(
        val samples: Int,
        val medianMs: Double,
        val p95Ms: Double,
        val evicted: Int,
    )

    private val pending = LinkedHashMap<Long, Long>()
    private val ages = ArrayList<Double>(240)
    private var evicted = 0

    @Synchronized fun submitted(
        ptsUs: Long,
        receivedAtNs: Long,
    ) {
        if (pending.size >= capacity && ptsUs !in pending) {
            pending.remove(pending.keys.first())
            evicted++
        }
        pending[ptsUs] = receivedAtNs
    }

    @Synchronized fun released(
        ptsUs: Long,
        nowNs: Long,
    ) {
        val received = pending.remove(ptsUs) ?: return
        if (nowNs >= received && ages.size < 240) ages.add((nowNs - received) / 1_000_000.0)
    }

    @Synchronized fun clearPending() {
        pending.clear()
    }

    @Synchronized fun drain(): Summary {
        ages.sort()
        val result =
            Summary(
                ages.size,
                ages.getOrElse(ages.size / 2) { 0.0 },
                ages.getOrElse(minOf(ages.lastIndex, (ages.size * 0.95).toInt())) { 0.0 },
                evicted,
            )
        ages.clear()
        evicted = 0
        return result
    }
}
