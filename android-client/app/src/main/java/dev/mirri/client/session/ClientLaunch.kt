package dev.mirri.client.session

import android.content.Intent
import dev.mirri.client.transport.ByteConnector
import dev.mirri.client.transport.PinnedTlsConnector

/** Typed credentials and endpoint accepted once at the application launch boundary. */
data class ClientEndpoint(
    val controlPort: Int,
    val videoPort: Int,
    val host: String? = null,
)

enum class NetworkMedia { COMPARISON, RTC }

class ClientLaunch(
    val token: ByteArray,
    val epoch: UInt,
    val endpoint: ClientEndpoint,
    val connector: ByteConnector,
    val media: NetworkMedia = NetworkMedia.COMPARISON,
    val sessionId: ByteArray? = null,
)

object ClientLaunchBoundary {
    private val tokenPattern = Regex("[0-9a-f]{64}")

    fun decode(intent: Intent): ClientLaunch? =
        validated(
            intent.getStringExtra("mirri_token"),
            intent.getIntExtra("mirri_epoch", 0),
            intent.getIntExtra("mirri_control_port", 0),
            intent.getIntExtra("mirri_video_port", 0),
            intent.getIntExtra("mirri_protocol_major", 0),
            intent.getStringExtra("mirri_mode"),
            intent.getStringExtra("mirri_host"),
            intent.getStringExtra("mirri_pin"),
            intent.getStringExtra("mirri_media"),
            intent.getStringExtra("mirri_session_id"),
        )

    @Suppress("ComplexCondition")
    fun validated(
        token: String?,
        epoch: Int,
        control: Int,
        video: Int,
        major: Int,
        mode: String? = null,
        host: String? = null,
        pin: String? = null,
        media: String? = null,
        sessionId: String? = null,
    ): ClientLaunch? {
        token ?: return null
        if (!tokenPattern.matches(token) || epoch <= 0 || major != 1) return null
        if (control != 5561 || video != 5560) return null
        val bytes = ByteArray(32) { token.substring(it * 2, it * 2 + 2).toInt(16).toByte() }
        if (mode != "network") return null
        return networkLaunch(bytes, epoch.toUInt(), control, video, host, pin, media, sessionId)
    }

    @Suppress("CyclomaticComplexMethod")
    private fun networkLaunch(
        token: ByteArray,
        epoch: UInt,
        control: Int,
        video: Int,
        host: String?,
        pin: String?,
        media: String?,
        sessionId: String?,
    ): ClientLaunch? {
        if (media != null && media != "rtc") return null
        if ((media == "rtc") != (sessionId != null)) return null
        if (sessionId != null && !Regex("[0-9a-f]{32}").matches(sessionId)) return null
        if (host == null || pin == null || !tokenPattern.matches(pin)) return null
        val octets = host.split(".").mapNotNull { it.toIntOrNull()?.takeIf { n -> n in 0..255 } }
        if (octets.size != 4 || octets.joinToString(".") != host) return null
        if (octets[0] !in 1..223 || octets[0] == 127) return null
        val pinned = ByteArray(32) { pin.substring(it * 2, it * 2 + 2).toInt(16).toByte() }
        return ClientLaunch(
            token,
            epoch,
            ClientEndpoint(control, video, host),
            PinnedTlsConnector(host, pinned),
            if (media == "rtc") NetworkMedia.RTC else NetworkMedia.COMPARISON,
            sessionId?.let { hex -> ByteArray(16) { hex.substring(it * 2, it * 2 + 2).toInt(16).toByte() } },
        )
    }
}
