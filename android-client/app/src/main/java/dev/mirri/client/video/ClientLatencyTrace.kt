package dev.mirri.client.video

import java.security.MessageDigest

/** Numeric sampled-frame metadata only; the authoritative frame join remains VideoTimingOwner. */
internal class ClientLatencyTrace(
    sessionId: ByteArray,
    private val route: String,
) {
    init {
        require(route == "usb" || route == "network")
    }

    companion object {
        fun identity(id: ByteArray): String {
            val digest =
                MessageDigest
                    .getInstance("SHA-256")
                    .digest("mirri-latency-v1".toByteArray(Charsets.UTF_8) + id)
            return digest.take(16).joinToString("") { "%02x".format(it.toInt() and 255) }
        }
    }

    class Sample(
        val generation: UInt,
        val sequence: Long,
        val ptsUs: Long,
        val packetNs: Long,
    ) {
        var inputNs = 0L
        var outputNs = 0L
        var releaseRequestNs = 0L
        var releaseNs = 0L
        var renderNs = 0L

        fun line(): String = "$generation,$sequence,$ptsUs,$packetNs,$inputNs,$outputNs,$releaseRequestNs,$releaseNs,$renderNs"
    }

    val id: String = identity(sessionId)
    private val ready = ArrayDeque<Sample>()
    private var selected = 0
    private var missing = 0
    private var dropped = 0
    private var ambiguous = 0
    private var censored = 0
    private var record = 0L
    private var startNs = System.nanoTime()

    fun activate(atNs: Long) {
        startNs = atNs
    }

    fun select(
        generation: UInt,
        sequence: Long,
        ptsUs: Long,
        packetNs: Long,
    ): Sample? {
        if (sequence % 6 != 0L) return null
        selected++
        if (generation == 0u || sequence < 0 || ptsUs < 0) {
            missing++
            return null
        }
        if (packetNs <= 0) {
            missing++
            return null
        }
        return Sample(generation, sequence, ptsUs, packetNs)
    }

    fun complete(
        sample: Sample?,
        reason: Reason = Reason.RENDERED,
    ) {
        if (sample == null) return
        when (reason) {
            Reason.RENDERED -> Unit
            Reason.CENSORED -> censored++
            Reason.AMBIGUOUS -> ambiguous++
        }
        if (ready.size < 20) ready.addLast(sample) else dropped++
    }

    enum class Reason { RENDERED, CENSORED, AMBIGUOUS }

    /** Called only by VideoTimingOwner's synchronized once-a-second reporting/stop path. */
    fun report(
        epoch: UInt,
        generation: UInt?,
        final: Boolean,
        atNs: Long,
    ): String {
        if (final && ready.size > 10) {
            val excess = ready.size - 10
            repeat(excess) { ready.removeLast() }
            dropped += excess
        }
        val batch = ArrayList<String>(10)
        repeat(minOf(10, ready.size)) { batch.add(ready.removeFirst().line()) }
        val result =
            "v=1 side=client trace=$id route=$route epoch=$epoch generation=${generation ?: 0u} " +
                "record=$record startNs=$startNs endNs=$atNs final=${if (final) 1 else 0} " +
                "selected=$selected missing=$missing dropped=$dropped ambiguous=$ambiguous censored=$censored " +
                "frames=${batch.joinToString(";").ifEmpty { "-" }}"
        startNs = atNs
        record++
        selected = 0
        missing = 0
        dropped = 0
        ambiguous = 0
        censored = 0
        return result
    }
}
