package dev.mirri.client.video

import java.util.concurrent.atomic.AtomicLong

/** Numeric-only, lock-bounded metadata for one client attempt. This owner never
 * queues a codec buffer, holds a pixel, blocks video or changes frame policy.
 * Wire PTS is encoder media time with an unverified epoch, NEVER a System.nanoTime timestamp. */
class VideoTimingOwner(
    private val capacity: Int = 256,
) {
    companion object {
        private val nextOwner = AtomicLong()
        const val SCHEMA = 4
        private const val METADATA_TTL_NS = 30_000_000_000L
        private const val TAIL_CENSOR_NS = 2_000_000_000L
    }

    private val ownerId = nextOwner.incrementAndGet()

    enum class Stage(
        val wireName: String,
    ) {
        PACKET_TO_INPUT("packetInput"),
        INPUT_TO_OUTPUT("inputOutput"),
        OUTPUT_TO_RELEASE("outputRelease"),
        RELEASE_CALL("releaseCall"),
        RELEASE_TO_RENDER("releaseRender"),
        PACKET_TO_RENDER("packetRender"),
        RENDER_CALLBACK_DELAY("renderNotify"),
        INPUT_AVAILABLE_TO_ACQUIRED("bufferIndexWait"),
        PACKET_GAP("packetGap"),
        MEDIA_PTS_GAP("mediaPtsGap"),
        OUTPUT_GAP("outputGap"),
        RENDER_GAP("renderGap"),
        PACKET_TO_RELEASE("packetRelease"),
        KEY_PACKET_GAP("keyPacketGap"),
        KEY_INPUT_TO_OUTPUT("keyInputOutput"),
        KEY_OUTPUT_GAP("keyOutputGap"),
    }

    data class Summary(
        val counters: Map<String, Long>,
        val stages: Map<Stage, TimingHistogram.Summary>,
        val generation: UInt?,
        val outstanding: Int,
        val highWater: Int,
        val totalReleased: Long,
        val totalRendered: Long,
        val validRendered: Long,
        val renderListenerSeen: Boolean,
        val renderListenerInstalled: Boolean,
        val ownerId: Long,
        val epoch: UInt?,
        val record: Long,
        val startNs: Long,
        val endNs: Long,
        val final: Boolean,
        val timingEnabled: Boolean,
        val rightCensored: Long,
        val interiorPending: Long,
    ) {
        fun line(): String =
            "v=$SCHEMA owner=$ownerId epoch=${epoch ?: 0u} record=$record startNs=$startNs endNs=$endNs " +
                "final=${if (final) 1 else 0} rightCensored=$rightCensored interiorPending=$interiorPending " +
                "generation=${generation ?: 0u} joinAvailable=${if (timingEnabled) 1 else 0} " +
                "outstanding=$outstanding highWater=$highWater " +
                "releasedTotal=$totalReleased renderedTotal=$totalRendered validRenderedTotal=$validRendered " +
                "renderInstalled=${if (renderListenerInstalled) 1 else 0} renderSeen=${if (renderListenerSeen) 1 else 0} " +
                counters.entries.joinToString(" ") { "${it.key}=${it.value}" } + " " +
                stages.entries.joinToString(" ") { "${it.key.wireName}=${it.value.line()}" }
    }

    private data class Frame(
        val generation: UInt,
        val sequence: Long,
        val packetNs: Long,
        val keyframe: Boolean,
        var inputQueuedNs: Long? = null,
        var outputAvailableNs: Long? = null,
    )

    /** Only render-join metadata survives release. It never owns an input/output
     * codec lease and cannot evict a frame still needed for decode-stage counts. */
    private data class PendingRender(
        val generation: UInt,
        val sequence: Long,
        val packetNs: Long,
        val releasedNs: Long,
    )

    private val stages =
        Stage.entries.associateWith {
            TimingHistogram(it in setOf(Stage.PACKET_GAP, Stage.MEDIA_PTS_GAP, Stage.OUTPUT_GAP, Stage.RENDER_GAP))
        }
    private val counts =
        linkedMapOf(
            "received" to 0L,
            "queued" to 0L,
            "output" to 0L,
            "released" to 0L,
            "rendered" to 0L,
            "keyReceived" to 0L,
            "keyOutput" to 0L,
            "keyBytes" to 0L,
            "keyMaxBytes" to 0L,
            "otherBytes" to 0L,
            "otherMaxBytes" to 0L,
            "truncatedPts" to 0L,
            "duplicate" to 0L,
            "unmatched" to 0L,
            "late" to 0L,
            "overflow" to 0L,
            "expired" to 0L,
            "missingRender" to 0L,
            "invalidClock" to 0L,
            "renderInvalid" to 0L,
            "ambiguousGeneration" to 0L,
            "ambiguousFrame" to 0L,
            "renderListenerUnavailable" to 0L,
            "missingOutputSeq" to 0L,
            "reorderedOutput" to 0L,
            "ambiguousOutputGap" to 0L,
            "missingRenderSeq" to 0L,
            "reorderedRender" to 0L,
            "ambiguousRenderGap" to 0L,
        )

    // The two maps share ONE capacity. At capacity retire pending renders first;
    // optional callbacks cannot evict still-active decode-stage metadata.
    // outstanding/highWater remain the total of both maps (schema-3 meaning).
    private val frames = LinkedHashMap<Long, Frame>() // decoder PTS microseconds
    private val pendingRenders = LinkedHashMap<Long, PendingRender>()
    private val renderedPts = LinkedHashSet<Long>()
    private val expiredPts = LinkedHashSet<Long>()
    private val indexAvailable = HashMap<Int, Long>()
    private val outputGaps = ReorderedFrameGaps(stages.getValue(Stage.OUTPUT_GAP), stages.getValue(Stage.KEY_OUTPUT_GAP))
    private val renderGaps = ReorderedFrameGaps(stages.getValue(Stage.RENDER_GAP))
    private var generation: UInt? = null
    private var closed = false
    private var timingEnabled = true
    private var finalSummary: Summary? = null
    private var record = 0L
    private var epoch: UInt? = null
    private var started = false
    private var windowEnded = false
    private var intervalStartNs = 0L
    private var rightCensored = 0L
    private var interiorPending = 0L
    private var previousMediaPtsNs: Long? = null
    private var previousPacketNs: Long? = null
    private var highWater = 0
    private var totalReleased = 0L
    private var totalRendered = 0L
    private var validRendered = 0L
    private var renderListenerSeen = false
    private var renderListenerInstalled = false

    init {
        require(capacity in 1..256)
    }

    @Synchronized fun setEpoch(value: UInt) {
        if (epoch == null) epoch = value else check(epoch == value)
    }

    /** Activate only after StartStream; no pre-stream setup time or callback
     * enters the first interval. Decoder input-index callbacks may predate it. */
    @Synchronized fun activate(atNs: Long = System.nanoTime()) {
        if (started || windowEnded) return
        started = true
        intervalStartNs = atNs
        stages.values.forEach { it.drain() }
        counts.keys.forEach { counts[it] = 0 }
        if (!renderListenerInstalled) count("renderListenerUnavailable")
        indexAvailable.clear()
        highWater = 0
        totalReleased = 0
        totalRendered = 0
        validRendered = 0
    }

    /** The measurement ends BEFORE normal decoder teardown. Pending recent
     * render notifications are right-censored, not mislabeled dropped. Older
     * outstanding releases remain explicitly unknown interior coverage. */
    @Synchronized fun endWindow(atNs: Long = System.nanoTime()) {
        if (windowEnded) return
        if (!started) activate(atNs)
        windowEnded = true
        for (frame in pendingRenders.values) {
            val release = frame.releasedNs
            if (release <= atNs && atNs - release <= TAIL_CENSOR_NS) rightCensored++ else interiorPending++
        }
        outputGaps.finish()
        renderGaps.finish()
        stages.values.forEach(TimingHistogram::finishGapRun)
        drain(atNs)
    }

    private fun count(key: String) {
        counts[key] = counts.getValue(key) + 1
    }

    private fun duration(
        stage: Stage,
        start: Long,
        end: Long,
    ): Boolean {
        if (end < start || !stages.getValue(stage).add(end - start)) {
            count("invalidClock")
            return false
        }
        return true
    }

    /** First generation has a fresh codec/attempt owner. Reusing the SAME
     * MediaCodec after flush offers no generation token on output/render PTS;
     * do not join any later-generation frame metadata, even after >64 PTS. */
    @Synchronized fun startGeneration(next: UInt) {
        if (closed || windowEnded) return
        outputGaps.finish()
        renderGaps.finish()
        stages.values.forEach(TimingHistogram::finishGapRun)
        if (generation != null) {
            timingEnabled = false
            count("ambiguousGeneration")
        }
        countMissingRenders()
        frames.clear()
        pendingRenders.clear()
        renderedPts.clear()
        expiredPts.clear()
        indexAvailable.clear()
        outputGaps.reset()
        renderGaps.reset()
        previousMediaPtsNs = null
        previousPacketNs = null
        generation = next
    }

    @Synchronized fun received(
        g: UInt,
        sequence: Long,
        wirePtsNs: Long,
        packetNs: Long,
        keyframe: Boolean = false,
        auBytes: Int = 0,
    ) {
        if (closed || windowEnded || !started || g != generation) {
            count("late")
            return
        }
        if (wirePtsNs < 0 || packetNs <= 0 || sequence < 0 || auBytes < 0) {
            count("invalidClock")
            return
        }
        val codecPtsUs = wirePtsNs / 1000 // MediaCodec.queueInputBuffer truncates nanoseconds to microseconds.
        count("received")
        val size = auBytes.toLong()
        if (keyframe) {
            count("keyReceived")
            counts["keyBytes"] = counts.getValue("keyBytes") + size
            counts["keyMaxBytes"] = maxOf(counts.getValue("keyMaxBytes"), size)
        } else {
            counts["otherBytes"] = counts.getValue("otherBytes") + size
            counts["otherMaxBytes"] = maxOf(counts.getValue("otherMaxBytes"), size)
        }
        previousMediaPtsNs?.let { duration(Stage.MEDIA_PTS_GAP, it, wirePtsNs) }
        previousPacketNs?.let {
            if (duration(Stage.PACKET_GAP, it, packetNs) && keyframe && timingEnabled) {
                stages.getValue(Stage.KEY_PACKET_GAP).add(packetNs - it)
            }
        }
        previousMediaPtsNs = wirePtsNs
        previousPacketNs = packetNs
        if (!timingEnabled) {
            count("ambiguousFrame")
            return
        }
        expireFrames(packetNs)
        if (codecPtsUs in frames || codecPtsUs in pendingRenders || codecPtsUs in renderedPts) {
            count("duplicate")
            return
        }
        if (wirePtsNs % 1000 != 0L) count("truncatedPts")
        if (frames.size + pendingRenders.size >= capacity) {
            if (pendingRenders.isNotEmpty()) {
                val evicted = pendingRenders.entries.first()
                pendingRenders.remove(evicted.key)
                rememberExpired(evicted.key)
                count("missingRender")
            } else {
                // Only an actual pre-release backlog may displace an active frame.
                val evicted = frames.entries.first()
                frames.remove(evicted.key)
                rememberExpired(evicted.key)
            }
            count("overflow")
        }
        frames[codecPtsUs] = Frame(g, sequence, packetNs, keyframe)
        highWater = maxOf(highWater, frames.size + pendingRenders.size)
    }

    private fun rememberExpired(ptsUs: Long) {
        expiredPts.add(ptsUs)
        if (expiredPts.size > 64) expiredPts.remove(expiredPts.first())
    }

    private fun expireFrames(nowNs: Long) {
        val iterator = frames.entries.iterator()
        while (iterator.hasNext()) {
            val entry = iterator.next()
            if (nowNs < entry.value.packetNs || nowNs - entry.value.packetNs < METADATA_TTL_NS) continue
            count("expired")
            rememberExpired(entry.key)
            iterator.remove()
        }
        val pending = pendingRenders.entries.iterator()
        while (pending.hasNext()) {
            val entry = pending.next()
            if (nowNs < entry.value.packetNs || nowNs - entry.value.packetNs < METADATA_TTL_NS) continue
            count("missingRender")
            count("expired")
            rememberExpired(entry.key)
            pending.remove()
        }
    }

    @Synchronized fun inputAvailable(
        index: Int,
        atNs: Long,
    ) {
        if (closed || windowEnded || !started) {
            count("late")
            return
        }
        if (!timingEnabled) return
        if (indexAvailable.size < 32 || index in indexAvailable) indexAvailable[index] = atNs else count("overflow")
    }

    @Synchronized fun inputAcquired(
        index: Int,
        atNs: Long,
    ) {
        if (windowEnded || !started) return
        val available = indexAvailable.remove(index) ?: return
        duration(Stage.INPUT_AVAILABLE_TO_ACQUIRED, available, atNs)
    }

    @Synchronized fun forgetInputIndex(index: Int) {
        indexAvailable.remove(index)
    }

    @Synchronized fun listenerUnavailable() {
        count("renderListenerUnavailable")
    }

    @Synchronized fun listenerInstalled() {
        renderListenerInstalled = true
    }

    private fun matching(ptsUs: Long): Frame? {
        if (closed || windowEnded || !started) {
            count("late")
            return null
        }
        if (!timingEnabled) {
            count("ambiguousFrame")
            return null
        }
        val frame = frames[ptsUs]
        if (frame == null || frame.generation != generation) {
            count(
                if (ptsUs in expiredPts) {
                    "late"
                } else if (ptsUs in pendingRenders || ptsUs in renderedPts) {
                    "duplicate"
                } else {
                    "unmatched"
                },
            )
            return null
        }
        return frame
    }

    @Synchronized fun inputQueued(
        ptsUs: Long,
        atNs: Long,
    ) {
        val frame = matching(ptsUs) ?: return
        if (frame.inputQueuedNs != null) {
            count("duplicate")
            return
        }
        duration(Stage.PACKET_TO_INPUT, frame.packetNs, atNs)
        frame.inputQueuedNs = atNs
        count("queued")
    }

    @Synchronized fun outputAvailable(
        ptsUs: Long,
        atNs: Long,
    ) {
        val frame = matching(ptsUs) ?: return
        if (frame.outputAvailableNs != null) {
            count("duplicate")
            return
        }
        frame.inputQueuedNs?.let {
            if (duration(Stage.INPUT_TO_OUTPUT, it, atNs) && frame.keyframe) {
                stages.getValue(Stage.KEY_INPUT_TO_OUTPUT).add(atNs - it)
            }
        } ?: count("unmatched")
        frame.outputAvailableNs = atNs
        outputGaps.add(frame.sequence, atNs, atNs, frame.keyframe)
        if (frame.keyframe) count("keyOutput")
        count("output")
    }

    @Synchronized fun outputReleased(
        ptsUs: Long,
        requestNs: Long,
        returnedNs: Long,
    ) {
        val frame = matching(ptsUs) ?: return
        frame.outputAvailableNs?.let { duration(Stage.OUTPUT_TO_RELEASE, it, requestNs) } ?: count("unmatched")
        duration(Stage.RELEASE_CALL, requestNs, returnedNs)
        duration(Stage.PACKET_TO_RELEASE, frame.packetNs, requestNs)
        frames.remove(ptsUs)
        pendingRenders[ptsUs] =
            PendingRender(frame.generation, frame.sequence, frame.packetNs, requestNs)
        totalReleased++
        count("released")
    }

    /** The supplied nanoTime is Android's System.nanoTime-domain render time;
     * callback arrival can be delayed or batched and is NEVER presentation. */
    @Synchronized fun rendered(
        ptsUs: Long,
        renderedNs: Long,
        callbackArrivalNs: Long,
    ) {
        if (windowEnded || !started) return
        renderListenerSeen = true
        if (closed || !timingEnabled) {
            count(if (closed) "late" else "ambiguousFrame")
            return
        }
        val frame = pendingRenders[ptsUs]
        if (frame == null || frame.generation != generation) {
            count(
                when {
                    ptsUs in expiredPts -> "late"
                    ptsUs in renderedPts -> "duplicate"
                    else -> "unmatched"
                },
            )
            return
        }
        val validRelease = duration(Stage.RELEASE_TO_RENDER, frame.releasedNs, renderedNs)
        val validPacket = duration(Stage.PACKET_TO_RENDER, frame.packetNs, renderedNs)
        val validCallback = duration(Stage.RENDER_CALLBACK_DELAY, renderedNs, callbackArrivalNs)
        if (validRelease && validPacket && validCallback) {
            renderGaps.add(frame.sequence, renderedNs, callbackArrivalNs)
            validRendered++
        } else {
            count("renderInvalid")
        }
        pendingRenders.remove(ptsUs)
        renderedPts.add(ptsUs)
        if (renderedPts.size > 64) renderedPts.remove(renderedPts.first())
        totalRendered++
        count("rendered")
    }

    private fun countMissingRenders() {
        repeat(pendingRenders.size) { count("missingRender") }
    }

    @Synchronized fun close() {
        if (closed) return
        if (!windowEnded) endWindow()
        closed = true
        frames.clear()
        pendingRenders.clear()
        indexAvailable.clear()
        renderedPts.clear()
    }

    @Synchronized fun drain(nowNs: Long = System.nanoTime()): Summary {
        finalSummary?.let { return it }
        if (!closed && !windowEnded) {
            expireFrames(nowNs)
            outputGaps.expire(nowNs)
            renderGaps.expire(nowNs)
        }
        if (windowEnded) stages.values.forEach(TimingHistogram::finishGapRun)
        counts["missingOutputSeq"] = outputGaps.missing
        counts["reorderedOutput"] = outputGaps.reordered
        counts["ambiguousOutputGap"] = outputGaps.ambiguous
        counts["missingRenderSeq"] = renderGaps.missing
        counts["reorderedRender"] = renderGaps.reordered
        counts["ambiguousRenderGap"] = renderGaps.ambiguous
        counts["invalidClock"] = counts.getValue("invalidClock") + outputGaps.invalid + renderGaps.invalid
        val result =
            Summary(
                counts.toMap(),
                stages.mapValues { it.value.drain() },
                generation,
                frames.size + pendingRenders.size,
                highWater,
                totalReleased,
                totalRendered,
                validRendered,
                renderListenerSeen,
                renderListenerInstalled,
                ownerId,
                epoch,
                record++,
                intervalStartNs,
                nowNs,
                windowEnded,
                timingEnabled,
                rightCensored,
                interiorPending,
            )
        if (windowEnded) finalSummary = result
        counts.keys.forEach { counts[it] = 0 }
        outputGaps.clearStats()
        renderGaps.clearStats()
        highWater = frames.size + pendingRenders.size
        intervalStartNs = nowNs
        return result
    }

    fun drainLine(nowNs: Long = System.nanoTime()): String = drain(nowNs).line()

    fun drainLiveSummary(nowNs: Long = System.nanoTime()): Summary? = synchronized(this) { if (windowEnded) null else drain(nowNs) }

    fun drainLiveLine(nowNs: Long = System.nanoTime()): String? = drainLiveSummary(nowNs)?.line()
}

/** Both production call sites share this exact payload formatter. Android's
 * logcat adds the tag/priority prefix, never a second free-text "final" token. */
object TimingLogMessage {
    fun interval(
        owner: VideoTimingOwner,
        atNs: Long = System.nanoTime(),
    ): String? = owner.drainLiveLine(atNs)

    fun final(owner: VideoTimingOwner): String = owner.drainLine()
}
