package dev.mirri.client.video

import java.nio.ByteBuffer

/** The caller owns a direct buffer lease until each submission returns. */
interface EncodedVideoConsumer {
    suspend fun submitConfiguration(data: ByteBuffer)

    suspend fun submitAccessUnit(
        data: ByteBuffer,
        ptsNs: Long,
        receivedAtNs: Long,
    )

    suspend fun flushForDiscontinuity()
}

/** Media failure is independent of Mirri framing and raw byte transport. */
class DecoderFailure(
    message: String,
) : IllegalStateException(message)

enum class MediaCodecKind(
    val id: Int,
) {
    AVC(1),
    HEVC(2),
}
