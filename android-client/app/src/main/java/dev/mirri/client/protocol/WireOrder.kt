package dev.mirri.client.protocol

/** Receive-direction-only ordering state. Recreate for each connection epoch. */
class WireOrder(
    private val peer: Peer,
    private val channel: Channel,
    private val epoch: ULong,
    private val sessionId: ByteArray? = null,
    previousGeneration: UInt = 0u,
) {
    enum class Peer { HOST, CLIENT }

    enum class Channel { CONTROL, VIDEO }

    private companion object {
        val hostControl =
            setOf(
                MessageType.SESSION_CONFIG,
                MessageType.START_STREAM,
                MessageType.STOP_SESSION,
                MessageType.PING,
                MessageType.ERROR,
            )
        val clientControl =
            setOf(
                MessageType.CLIENT_HELLO,
                MessageType.CLIENT_READY,
                MessageType.INPUT_BATCH,
                MessageType.SCROLL,
                MessageType.ZOOM,
                MessageType.CONTEXT,
                MessageType.SHORTCUT,
                MessageType.AUXILIARY,
                MessageType.PONG,
                MessageType.CLIENT_METRICS,
                MessageType.ERROR,
                MessageType.DECODER_FAILURE,
                MessageType.REQUEST_KEYFRAME,
                MessageType.REJECTED,
                MessageType.STOP_ACK,
            )
    }

    private var nextSequence = 0uL
    private var generation = previousGeneration.toULong()
    private var nextFrame = 0uL
    private var needsIdr = false

    /** Only call for an ignorable future-minor type validated by WireFramer. */
    fun skipUnknown(sequence: ULong) {
        if (nextSequence == 0uL || sequence != nextSequence || nextSequence == ULong.MAX_VALUE) {
            throw WireException("invalid skip sequence")
        }
        nextSequence++
    }

    fun accept(message: WireMessage) {
        val type = MessageType.entries.firstOrNull { it.id == message.type } ?: throw WireException("unknown wire type")
        val permitted =
            if (channel == Channel.VIDEO) {
                if (peer ==
                    Peer.HOST
                ) {
                    type == MessageType.CODEC_CONFIG || type == MessageType.VIDEO_FRAME
                } else {
                    type == MessageType.VIDEO_HELLO
                }
            } else {
                type in if (peer == Peer.HOST) hostControl else clientControl
            }
        val first =
            if (channel == Channel.VIDEO) {
                if (peer == Peer.HOST) MessageType.CODEC_CONFIG else MessageType.VIDEO_HELLO
            } else {
                if (peer == Peer.HOST) MessageType.SESSION_CONFIG else MessageType.CLIENT_HELLO
            }
        if (!permitted ||
            message.sequence != nextSequence ||
            nextSequence == ULong.MAX_VALUE ||
            (nextSequence == 0uL && type != first && !(channel == Channel.CONTROL && peer == Peer.HOST && type == MessageType.ERROR))
        ) {
            throw WireException("invalid wire order")
        }
        val f = message.fields
        val id: ByteArray?
        val receivedEpoch: ULong
        if (type == MessageType.CLIENT_HELLO || type == MessageType.VIDEO_HELLO) {
            receivedEpoch = (f[0] as? Value.Number)?.value ?: throw WireException("invalid epoch")
            id = if (type == MessageType.VIDEO_HELLO) (f[1] as? Value.Bytes)?.value else null
        } else {
            id = (f[0] as? Value.Bytes)?.value
            receivedEpoch = (f[1] as? Value.Number)?.value ?: throw WireException("invalid epoch")
        }
        if (receivedEpoch != epoch || (sessionId != null && (id == null || !id.contentEquals(sessionId)))) {
            throw WireException("stale connection")
        }
        if (channel == Channel.VIDEO && peer == Peer.HOST) {
            val g = (f[2] as? Value.Number)?.value ?: throw WireException("invalid generation")
            if (type == MessageType.CODEC_CONFIG) {
                if (g != generation + 1uL) throw WireException("invalid generation")
                generation = g
                nextFrame = 0uL
                needsIdr = true
            } else {
                val frame = (f[3] as? Value.Number)?.value ?: throw WireException("invalid sequence")
                if (g != generation ||
                    (needsIdr && f[5] != Value.Number(3uL)) ||
                    frame != nextFrame ||
                    frame == ULong.MAX_VALUE
                ) {
                    throw WireException("invalid video order")
                }
                nextFrame++
                needsIdr = false
            }
        }
        nextSequence++
    }
}
