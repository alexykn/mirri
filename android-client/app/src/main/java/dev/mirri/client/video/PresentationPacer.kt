package dev.mirri.client.video

/**
 * Presentation timestamps for decoder releases. Two frames that become due at
 * the same vsync make the Surface keep only the newer one. A frame released now
 * can reach the compositor after it has already decided the next refresh, so it
 * is stamped [leadNs] ahead: the compositor then sees each frame before it is
 * due. Frames are
 * then spaced one refresh apart. This is a jitter buffer of at most one 60 fps
 * frame: a burst beyond that collapses instead of adding lasting delay.
 */
internal class PresentationPacer(
    panelMilliHz: Long,
    private val leadNs: Long = DEFAULT_LEAD_NS,
) {
    // Exactly one refresh, rounded up so the spacing is never short.
    private val spacingNs = if (panelMilliHz > 0) (1_000_000_000_000L + panelMilliHz - 1) / panelMilliHz else 0L
    private var lastNs = Long.MIN_VALUE

    fun next(nowNs: Long): Long {
        if (spacingNs == 0L) return nowNs
        val earliest = nowNs + leadNs
        val spaced = if (lastNs == Long.MIN_VALUE) earliest else maxOf(earliest, lastNs + spacingNs)
        lastNs = minOf(spaced, earliest + MAX_AHEAD_NS)
        return lastNs
    }

    fun reset() {
        lastNs = Long.MIN_VALUE
    }

    companion object {
        /**
         * Measured on the TXZ-W09 at 60 Hz over 90 s of motion: with no lead about
         * 10% of released frames were never presented; 11 ms left that unchanged;
         * 24 ms cut it to about 3% for roughly 12 ms more release-to-present time.
         */
        const val DEFAULT_LEAD_NS = 24_000_000L
        private const val MAX_AHEAD_NS = 16_666_667L
    }
}
