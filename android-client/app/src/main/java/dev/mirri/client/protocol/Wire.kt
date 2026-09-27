package dev.mirri.client.protocol

import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.CharBuffer
import java.nio.charset.CodingErrorAction

/** Pure, platform-independent wire representation. Arrays use content equality. */
sealed interface Value {
    data class Number(
        val value: ULong,
    ) : Value

    data class Signed(
        val value: Int,
    ) : Value

    data class Real(
        val value: Float,
    ) : Value

    class Bytes(
        val value: ByteArray,
    ) : Value {
        override fun equals(other: Any?) = other is Bytes && value.contentEquals(other.value)

        override fun hashCode() = value.contentHashCode()
    }

    data class Text(
        val value: String,
    ) : Value

    data class Items(
        val value: List<Value>,
    ) : Value

    data class Object(
        val value: List<Value>,
    ) : Value
}

data class WireMessage(
    val type: Int,
    val sequence: ULong,
    val timestamp: ULong,
    val fields: List<Value>,
)

class WireException(
    message: String,
) : IllegalArgumentException(message)

/** No sockets, video codecs, platform state, or unbounded allocations. */
object WireCodec {
    private val definitions =
        mapOf(
            1 to "epoch bytes32 str64 size u32 mode list16mode list2cap inputs",
            2 to "codec profile level size u32 u32 color port inputMode bool",
            3 to "mode str96 size",
            4 to "epoch bytes16 bytes32",
            5 to "generation codec profile level color list3param",
            6 to "generation u64 u64 frameFlags au",
            7 to "generation",
            8 to "stopReason",
            9 to "u64 list64sample",
            10 to "gesturePhase point delta delta u64",
            11 to "gesturePhase point scale u64",
            12 to "point contextSource u64",
            13 to "shortcut u64",
            14 to "u32 u32 keyPhase u64",
            15 to "u64 u64 u64 u64",
            16 to "u64 u64 u64 u64",
            17 to "fps u32 fps fps mode u8 u64",
            18 to "errorCode str128 bool",
            19 to "errorCode",
            20 to "generation",
            21 to "rejectReason str128",
            22 to "",
        )

    private fun bad(): Nothing = throw WireException("malformed wire record")

    private fun number(v: Value) = (v as? Value.Number)?.value ?: bad()

    private fun size(v: Value): Pair<ULong, ULong> {
        val fields = (v as? Value.Object)?.value ?: bad()
        if (fields.size != 2) bad()
        return number(fields[0]) to number(fields[1])
    }

    private fun exactPhysicalMode(v: Value): Boolean {
        val fields = (v as? Value.Object)?.value ?: bad()
        return fields.size == 3 && size(fields[0]) == (1600uL to 2456uL) && number(fields[1]) == 60000uL
    }

    private fun validate(message: WireMessage) {
        val f = message.fields
        when (message.type) {
            1 -> if (size(f[3]) != (1600uL to 2456uL) || number(f[4]) !in 1uL..1200uL) bad()
            2 -> {
                val codec = number(f[2])
                val bitrate = number(f[7])
                val range = if (codec == 1uL) 20_000_000uL..80_000_000uL else 25_000_000uL..80_000_000uL
                if (codec != number(f[3]) ||
                    size(f[5]) != (2456uL to 1600uL) ||
                    number(f[6]) != 60000uL ||
                    bitrate !in range
                ) {
                    bad()
                }
            }
            3 -> if (size(f[4]) != (2456uL to 1600uL) || !exactPhysicalMode(f[2])) bad()
            5 -> {
                val codec = number(f[3])
                val sets = (f[7] as? Value.Items)?.value ?: bad()
                if (codec != number(f[4]) || sets.size != (if (codec == 1uL) 2 else 3)) bad()
                sets.forEachIndexed { index, set ->
                    val nal = (set as? Value.Bytes)?.value ?: bad()
                    if (nal.size < (if (codec == 1uL) 1 else 2)) bad()
                    val actual = if (codec == 1uL) nal[0].toInt() and 0x1f else (nal[0].toInt() ushr 1) and 0x3f
                    val expected = if (codec == 1uL) listOf(7, 8)[index] else listOf(32, 33, 34)[index]
                    if (actual != expected) bad()
                }
            }
            6 -> {
                val au = (f[6] as? Value.Bytes)?.value ?: bad()
                if (au.size < 5 || !au.copyOfRange(0, 4).contentEquals(byteArrayOf(0, 0, 0, 1))) bad()
            }
        }
    }

    private fun schema(type: Int): List<String> =
        (
            (if (type == 1 || type == 4) "" else "bytes16 epoch ") +
                (definitions[type] ?: throw WireException("unknown type"))
        ).trim().split(' ').filter { it.isNotEmpty() }

    private fun cap(type: Int) =
        when (type) {
            6 -> 16_777_261
            4, 5 -> 65_536
            else -> 1_048_576
        }

    private fun width(t: String) =
        when (t) {
            "u64" -> 8
            "u32", "epoch", "generation", "dimension", "refresh" -> 4
            "level", "port", "buttons" -> 2
            else -> 1
        }

    private fun children(t: String): List<String>? =
        when (t) {
            "size" -> listOf("dimension", "dimension")
            "mode" -> listOf("size", "refresh", "i32")
            "profileLevel" -> listOf("profile", "level")
            "cap" -> listOf("codec", "list16profileLevel", "bool", "bool", "bool")
            "inputs" -> listOf("touchCount", "bool", "bool", "bool", "bool", "bool")
            "point" -> listOf("unit", "unit")
            "sample" -> listOf("u32", "tool", "pointerPhase", "point", "unit", "tilt", "orientation", "buttons", "u64")
            else -> null
        }

    private fun list(t: String): Pair<Int, String>? =
        listOf("list16" to 16, "list2" to 2, "list3" to 3, "list64" to 64)
            .firstOrNull { t.startsWith(it.first) }
            ?.let { it.second to t.removePrefix(it.first) }

    private fun bounds(t: String): ULongRange? =
        when (t) {
            "bool" -> 0uL..1uL
            "codec", "profile", "keyPhase" -> 1uL..2uL
            "color", "inputMode" -> 1uL..1uL
            "gesturePhase", "stopReason" -> 1uL..4uL
            "contextSource", "tool" -> 1uL..3uL
            "shortcut", "rejectReason" -> 1uL..5uL
            "pointerPhase" -> 1uL..7uL
            "errorCode" -> 1uL..8uL
            "frameFlags" -> 0uL..3uL
            "buttons" -> 0uL..7uL
            "generation", "epoch" -> 1uL..UInt.MAX_VALUE.toULong()
            "port" -> 5560uL..5560uL
            "dimension" -> 1uL..8192uL
            "refresh" -> 1uL..240000uL
            "touchCount" -> 1uL..10uL
            else -> null
        }

    private fun validateNumber(
        t: String,
        n: ULong,
    ) {
        val w = width(t)
        if ((w < 8 && n >= (1uL shl (8 * w))) || (bounds(t)?.contains(n) == false)) bad()
    }

    private fun validateReal(
        t: String,
        n: Float,
    ) {
        val range =
            when (t) {
                "unit" -> 0f..1f
                "tilt" -> (-Math.PI.toFloat() / 2)..(Math.PI.toFloat() / 2)
                "orientation" -> (-Math.PI.toFloat())..Math.PI.toFloat()
                "delta" -> -4096f..4096f
                "scale" -> 0.25f..4f
                else -> 0f..240f
            }
        if (!n.isFinite() || n !in range) bad()
    }

    private fun stringLimit(t: String): Int? =
        when (t) {
            "str64" -> 64
            "str96" -> 96
            "str128" -> 128
            else -> null
        }

    private fun validateText(
        s: String,
        limit: Int,
    ): ByteArray {
        val encoder =
            Charsets.UTF_8
                .newEncoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
        val encoded =
            try {
                encoder.encode(CharBuffer.wrap(s))
            } catch (_: Exception) {
                bad()
            }
        val bytes = ByteArray(encoded.remaining()).also(encoded::get)
        if (bytes.size > limit || s.any { it.isISOControl() || it == '\uFEFF' }) bad()
        return bytes
    }

    private fun writeNumber(
        out: ByteArrayOutputStream,
        n: ULong,
        width: Int,
    ) {
        for (i in width - 1 downTo 0) out.write(((n shr (i * 8)) and 255uL).toInt())
    }

    private fun write(
        out: ByteArrayOutputStream,
        t: String,
        value: Value,
    ) {
        children(t)?.let { spec ->
            val fields = (value as? Value.Object)?.value ?: bad()
            if (fields.size != spec.size) bad()
            spec.zip(fields).forEach { (child, field) -> write(out, child, field) }
            return
        }
        list(t)?.let { (max, child) ->
            val items = (value as? Value.Items)?.value ?: bad()
            if (items.size > max) bad()
            writeNumber(out, items.size.toULong(), 1)
            items.forEach { write(out, child, it) }
            return
        }
        if (t == "i32") {
            writeNumber(out, ((value as? Value.Signed)?.value ?: bad()).toUInt().toULong(), 4)
            return
        }
        if (t in listOf("unit", "tilt", "orientation", "delta", "scale", "fps")) {
            val n = (value as? Value.Real)?.value ?: bad()
            validateReal(t, n)
            writeNumber(out, n.toRawBits().toUInt().toULong(), 4)
            return
        }
        stringLimit(t)?.let { max ->
            val bytes = validateText((value as? Value.Text)?.value ?: bad(), max)
            writeNumber(out, bytes.size.toULong(), 2)
            out.write(bytes)
            return
        }
        if (t in listOf("bytes16", "bytes32", "param", "au")) {
            val bytes = (value as? Value.Bytes)?.value ?: bad()
            val valid =
                when (t) {
                    "bytes16" -> bytes.size == 16
                    "bytes32" -> bytes.size == 32
                    "param" -> bytes.size in 1..4096
                    else -> bytes.size in 1..16_777_216
                }
            if (!valid) bad()
            if (t == "param" || t == "au") writeNumber(out, bytes.size.toULong(), if (t == "param") 2 else 4)
            out.write(bytes)
            return
        }
        val n = (value as? Value.Number)?.value ?: bad()
        validateNumber(t, n)
        writeNumber(out, n, width(t))
    }

    private class Reader(
        val data: ByteArray,
    ) {
        var offset = 0

        fun take(count: Int): ByteArray {
            if (count < 0 || count > data.size - offset) bad()
            val bytes = data.copyOfRange(offset, offset + count)
            offset += count
            return bytes
        }

        fun number(width: Int): ULong {
            var n = 0uL
            repeat(width) { n = (n shl 8) or take(1)[0].toUByte().toULong() }
            return n
        }

        fun read(t: String): Value {
            children(t)?.let { return Value.Object(it.map(::read)) }
            list(t)?.let { (max, child) ->
                val count = number(1).toInt()
                if (count > max) bad()
                return Value.Items(List(count) { read(child) })
            }
            if (t == "i32") return Value.Signed(number(4).toUInt().toInt())
            if (t in listOf("unit", "tilt", "orientation", "delta", "scale", "fps")) {
                val n = Float.fromBits(number(4).toUInt().toInt())
                validateReal(t, n)
                return Value.Real(n)
            }
            stringLimit(t)?.let { max ->
                val length = number(2).toInt()
                if (length > max) bad()
                val decoder =
                    Charsets.UTF_8
                        .newDecoder()
                        .onMalformedInput(
                            CodingErrorAction.REPORT,
                        ).onUnmappableCharacter(CodingErrorAction.REPORT)
                val s =
                    try {
                        decoder.decode(ByteBuffer.wrap(take(length))).toString()
                    } catch (_: Exception) {
                        bad()
                    }
                validateText(s, max)
                return Value.Text(s)
            }
            if (t == "bytes16" || t == "bytes32") return Value.Bytes(take(if (t == "bytes16") 16 else 32))
            if (t == "param" || t == "au") {
                val length = number(if (t == "param") 2 else 4)
                if (length < 1uL || length > (if (t == "param") 4096uL else 16_777_216uL)) bad()
                return Value.Bytes(take(length.toInt()))
            }
            val n = number(width(t))
            validateNumber(t, n)
            return Value.Number(n)
        }
    }

    fun encode(message: WireMessage): ByteArray {
        val spec = schema(message.type)
        if (message.fields.size != spec.size) bad()
        validate(message)
        val payload = ByteArrayOutputStream()
        spec.zip(message.fields).forEach { (t, v) -> write(payload, t, v) }
        if (payload.size() > cap(message.type)) bad()
        val out = ByteArrayOutputStream()
        out.write("MRRI".toByteArray(Charsets.US_ASCII))
        writeNumber(out, 1uL, 2)
        writeNumber(out, 0uL, 2)
        writeNumber(out, message.type.toULong(), 2)
        writeNumber(out, 0uL, 2)
        writeNumber(out, message.sequence, 8)
        writeNumber(out, payload.size().toULong(), 4)
        writeNumber(out, message.timestamp, 8)
        out.write(payload.toByteArray())
        return out.toByteArray()
    }

    fun payloadLength(
        header: ByteArray,
        videoChannel: Boolean = false,
    ): Int {
        if (header.size != 32) bad()
        if (!header.copyOfRange(0, 4).contentEquals("MRRI".toByteArray(Charsets.US_ASCII))) bad()
        if (header[4] != 0.toByte() || header[5] != 1.toByte()) bad()
        val minor = ((header[6].toInt() and 255) shl 8) or (header[7].toInt() and 255)
        val type = ((header[8].toInt() and 255) shl 8) or (header[9].toInt() and 255)
        if (header[10] != 0.toByte() || header[11] != 0.toByte()) bad()
        if (type !in definitions && (minor == 0 || type and 0x8000 == 0)) bad()
        if (videoChannel && type !in setOf(4, 5, 6) && (minor == 0 || type and 0x8000 == 0)) bad()
        val size = header.copyOfRange(20, 24).fold(0uL) { n, byte -> (n shl 8) or byte.toUByte().toULong() }
        val limit = if (videoChannel && type !in definitions) 65_536 else cap(type)
        if (size > limit.toULong()) bad()
        return size.toInt()
    }

    /** Returns null only for bounded ignorable future-minor extension types. */
    fun decode(data: ByteArray): WireMessage? {
        if (data.size < 32) bad()
        val r = Reader(data)
        if (!r.take(4).contentEquals("MRRI".toByteArray(Charsets.US_ASCII)) || r.number(2) != 1uL) bad()
        val minor = r.number(2)
        val type = r.number(2).toInt()
        if (r.number(2) != 0uL) bad()
        val seq = r.number(8)
        val length = r.number(4)
        val timestamp = r.number(8)
        if (length > cap(type).toULong() || length.toInt() != data.size - 32) bad()
        if (type !in definitions) {
            if (minor > 0uL && type and 0x8000 != 0) return null
            bad()
        }
        val fields = schema(type).map(r::read)
        if (r.offset != data.size) bad()
        val message = WireMessage(type, seq, timestamp, fields)
        validate(message)
        return message
    }
}
