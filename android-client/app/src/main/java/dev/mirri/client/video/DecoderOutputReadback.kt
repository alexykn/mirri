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
        val crop = listOfNotNull(left, top, right, bottom)
        if (crop.isEmpty()) {
            return codedWidth == 2456 && codedHeight == 1600
        }
        if (crop.size != 4) return false
        return exactCrop(codedWidth, codedHeight, crop)
    }

    private fun exactCrop(
        codedWidth: Int,
        codedHeight: Int,
        crop: List<Int>,
    ): Boolean {
        val l = crop[0]
        val t = crop[1]
        val r = crop[2]
        val b = crop[3]
        val topLeftValid = l >= 0 && t >= 0
        val bottomRightValid = r >= l && b >= t
        val withinImage = r < codedWidth && b < codedHeight
        val exactSize = r.toLong() - l + 1 == 2456L && b.toLong() - t + 1 == 1600L
        return topLeftValid && bottomRightValid && withinImage && exactSize
    }
}
