package dev.mirri.client.protocol

import java.io.ByteArrayOutputStream

sealed interface FramedRecord {
    data class Message(
        val value: WireMessage,
    ) : FramedRecord

    data class Skipped(
        val sequence: ULong,
    ) : FramedRecord
}

/** Incremental bounded framing; not a socket or transport owner. */
class WireFramer(
    private val videoChannel: Boolean = false,
) {
    private val pending = ByteArrayOutputStream()
    private var expected: Int? = null
    val hasIncompleteFrame: Boolean get() = pending.size() != 0

    fun append(chunk: ByteArray): List<FramedRecord> {
        val result = mutableListOf<FramedRecord>()
        var offset = 0
        while (offset < chunk.size) {
            val needed = expected ?: 32
            val count = minOf(needed - pending.size(), chunk.size - offset)
            pending.write(chunk, offset, count)
            offset += count
            if (pending.size() == 32 && expected == null) expected = 32 + WireCodec.payloadLength(pending.toByteArray(), videoChannel)
            if (pending.size() == expected) {
                val bytes = pending.toByteArray()
                val message = WireCodec.decode(bytes)
                if (message == null) {
                    val sequence = bytes.copyOfRange(12, 20).fold(0uL) { n, byte -> (n shl 8) or byte.toUByte().toULong() }
                    result.add(FramedRecord.Skipped(sequence))
                } else {
                    result.add(FramedRecord.Message(message))
                }
                pending.reset()
                expected = null
            }
        }
        return result
    }
}
