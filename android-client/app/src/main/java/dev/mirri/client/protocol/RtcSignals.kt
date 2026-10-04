package dev.mirri.client.protocol

import java.security.SecureRandom

/** Payloads alone have no authority; the attempt owner checks state, epoch and identity. */
internal object RtcSignals {
    fun number(value: Value): ULong = (value as? Value.Number)?.value ?: throw WireException("invalid RTC record")

    fun bytes(value: Value): ByteArray = (value as? Value.Bytes)?.value ?: throw WireException("invalid RTC record")

    fun text(value: Value): String = (value as? Value.Text)?.value ?: throw WireException("invalid RTC record")

    fun nonce(): ByteArray = ByteArray(16).also { SecureRandom().nextBytes(it) }

    fun fields(
        id: ByteArray,
        epoch: UInt,
        attempt: ByteArray,
        tail: List<Value> = emptyList(),
    ): List<Value> = listOf(Value.Bytes(id), Value.Number(epoch.toULong()), Value.Number(1uL), Value.Bytes(attempt)) + tail

    @Suppress("ComplexCondition")
    fun check(
        message: WireMessage,
        id: ByteArray,
        epoch: UInt,
        attempt: ByteArray? = null,
    ) {
        val f = message.fields
        if (!bytes(f[0]).contentEquals(id) ||
            number(f[1]) != epoch.toULong() ||
            number(f[2]) != 1uL ||
            (attempt != null && !bytes(f[3]).contentEquals(attempt))
        ) {
            throw WireException("stale RTC attempt")
        }
    }
}

/** Candidate state is per remote direction; accepts trickle before remote SDP application. */
internal class RtcIceLedger {
    private val pending = mutableListOf<String>()
    private var bytes = 0
    private var count = 0
    var ended = false
        private set
    var remoteApplied = false
        private set

    @Suppress("ComplexCondition")
    fun candidate(
        mid: String,
        expected: String,
        index: Int,
        text: String,
    ): String? {
        if (mid != expected ||
            index != 0 ||
            count >= 64 ||
            text.isEmpty() ||
            text.toByteArray(Charsets.UTF_8).size > 2048 ||
            bytes + text.toByteArray(Charsets.UTF_8).size > 131072
        ) {
            throw WireException("invalid RTC candidate")
        }
        bytes += text.toByteArray(Charsets.UTF_8).size
        count++
        if (remoteApplied) return text
        pending += text
        return null
    }

    fun end(
        mid: String,
        expected: String,
        index: Int,
    ) {
        if (ended || mid != expected || index != 0) throw WireException("invalid RTC ICE end")
        ended = true
    }

    fun applied(): List<String> {
        remoteApplied = true
        return pending.toList().also { pending.clear() }
    }
}

/** Attempt-local one-way startup barrier; stopping during setup cannot be resumed. */
internal class RtcStartupGate {
    private enum class Phase { NEW, PREPARED, OFFERED, ANSWERED, READY, STARTED, STOPPED }

    @Volatile private var phase = Phase.NEW
    val ready: Boolean get() = phase == Phase.READY || phase == Phase.STARTED
    val started: Boolean get() = phase == Phase.STARTED

    private fun advance(
        expected: Phase,
        next: Phase,
    ) {
        if (phase != expected) throw WireException("invalid RTC startup order")
        phase = next
    }

    fun prepared() = advance(Phase.NEW, Phase.PREPARED)

    fun offered() = advance(Phase.PREPARED, Phase.OFFERED)

    fun answered() = advance(Phase.OFFERED, Phase.ANSWERED)

    fun mediaReady() = advance(Phase.ANSWERED, Phase.READY)

    fun start() = advance(Phase.READY, Phase.STARTED)

    fun stop() {
        phase = Phase.STOPPED
    }
}

/** Read-only SDP admission; native WebRTC parses and generates the actual descriptions. */
internal object RtcSdpProof {
    fun highParameters(text: String): Boolean {
        val parameters = mutableMapOf<String, String>()
        for (part in text.split(';')) {
            val pair = part.split('=', limit = 2)
            if (pair.size != 2) continue
            val key = pair[0].trim().lowercase()
            val value = pair[1].trim().lowercase()
            if (key.isEmpty() || parameters.put(key, value) != null) return false
        }
        return parameters["profile-level-id"] == "640034" && parameters["packetization-mode"] == "1"
    }

    @Suppress("CyclomaticComplexMethod")
    fun mid(
        sdp: String,
        direction: String,
    ): String {
        val lines = sdp.lineSequence().map(String::trim).toList()
        val media = lines.filter { it.startsWith("m=") }
        if (media.size != 1 || !media[0].startsWith("m=video ") || "a=$direction" !in lines) {
            throw WireException("RTC video-only SDP required")
        }
        val mid =
            lines.singleOrNull { it.startsWith("a=mid:") }?.removePrefix("a=mid:")
                ?: throw WireException("RTC video mid unavailable")
        if (mid.isEmpty() || mid.toByteArray().size > 32) throw WireException("RTC video mid invalid")
        val payloads = media[0].split(' ').drop(3).toSet()
        val high =
            lines.any { line ->
                if (!line.startsWith("a=rtpmap:")) return@any false
                val number = line.substringAfter(':').substringBefore(' ')
                number in payloads &&
                    line.substringAfter(' ').equals("H264/90000", true) &&
                    lines.any { fmtp ->
                        fmtp.startsWith("a=fmtp:$number ") &&
                            highParameters(fmtp.removePrefix("a=fmtp:$number "))
                    }
            }
        if (!high) throw WireException("RTC High 5.2 SDP required")
        return mid
    }
}
