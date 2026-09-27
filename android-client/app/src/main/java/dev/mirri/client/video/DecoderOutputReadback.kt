package dev.mirri.client.video

/** Codec allocation may be aligned; only the explicit visible crop is the decoded image. */
internal object DecoderOutputReadback {
    fun isExactVisibleFrame(
        codedWidth: Int,
        codedHeight: Int,
        left: Int?,
        top: Int?,
        right: Int?,
        bottom: Int?,
    ): Boolean {
        if (codedWidth <= 0 || codedHeight <= 0) return false
        if (left == null && top == null && right == null && bottom == null) {
            return codedWidth == 2456 && codedHeight == 1600
        }
        if (left == null || top == null || right == null || bottom == null) return false
        return left >= 0 &&
            top >= 0 &&
            right >= left &&
            bottom >= top &&
            right < codedWidth &&
            bottom < codedHeight &&
            right.toLong() - left + 1 == 2456L &&
            bottom.toLong() - top + 1 == 1600L
    }
}
