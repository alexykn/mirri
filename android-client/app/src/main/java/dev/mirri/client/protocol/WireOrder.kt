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
        checkOrder(type, message.sequence)
        checkIdentity(type, message.fields)
        if (channel == Channel.VIDEO && peer == Peer.HOST) checkVideo(type, message.fields)
        nextSequence++
    }

    private fun checkOrder(
        type: MessageType,
        sequence: ULong,
    ) {
        val permitted = permitted(type)
        val first = firstType()
        val initialError = channel == Channel.CONTROL && peer == Peer.HOST && type == MessageType.ERROR
        val wrongFirst = nextSequence == 0uL && type != first && !initialError
        val wrongSequence = sequence != nextSequence || nextSequence == ULong.MAX_VALUE
        if (!permitted || wrongSequence || wrongFirst) {
            throw WireException("invalid wire order")
        }
    }

    private fun permitted(type: MessageType): Boolean =
        when (channel) {
            Channel.VIDEO ->
                if (peer ==
                    Peer.HOST
                ) {
                    when (type) {
                        MessageType.CODEC_CONFIG, MessageType.VIDEO_FRAME -> true
                        else -> false
                    }
                } else {
                    type == MessageType.VIDEO_HELLO
                }
            Channel.CONTROL -> type in if (peer == Peer.HOST) hostControl else clientControl
        }

    private fun firstType(): MessageType =
        when (channel) {
            Channel.VIDEO -> if (peer == Peer.HOST) MessageType.CODEC_CONFIG else MessageType.VIDEO_HELLO
            Channel.CONTROL -> if (peer == Peer.HOST) MessageType.SESSION_CONFIG else MessageType.CLIENT_HELLO
        }

    private fun checkIdentity(
        type: MessageType,
        f: List<Value>,
    ) {
        val id: ByteArray?
        val receivedEpoch: ULong
        if (type == MessageType.CLIENT_HELLO || type == MessageType.VIDEO_HELLO) {
            receivedEpoch = (f[0] as? Value.Number)?.value ?: throw WireException("invalid epoch")
            id = if (type == MessageType.VIDEO_HELLO) (f[1] as? Value.Bytes)?.value else null
        } else {
            id = (f[0] as? Value.Bytes)?.value
            receivedEpoch = (f[1] as? Value.Number)?.value ?: throw WireException("invalid epoch")
        }
        val wrongId = sessionId != null && (id == null || !id.contentEquals(sessionId))
        if (receivedEpoch != epoch || wrongId) {
            throw WireException("stale connection")
        }
    }

    private fun checkVideo(
        type: MessageType,
        f: List<Value>,
    ) {
        val g = (f[2] as? Value.Number)?.value ?: throw WireException("invalid generation")
        if (type == MessageType.CODEC_CONFIG) {
            if (g != generation + 1uL) throw WireException("invalid generation")
            generation = g
            nextFrame = 0uL
            needsIdr = true
        } else {
            val frame = (f[3] as? Value.Number)?.value ?: throw WireException("invalid sequence")
            val wrongIdr = needsIdr && f[5] != Value.Number(3uL)
            val wrongFrame = frame != nextFrame || frame == ULong.MAX_VALUE
            if (g != generation || wrongIdr || wrongFrame) {
                throw WireException("invalid video order")
            }
            nextFrame++
            needsIdr = false
        }
    }
}
