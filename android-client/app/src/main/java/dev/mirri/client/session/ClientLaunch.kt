package dev.mirri.client.session

import android.content.Intent
import dev.mirri.client.transport.ByteConnector
import dev.mirri.client.transport.LoopbackTcpConnector

/** Typed credentials and endpoint accepted once at the application launch boundary. */
data class ClientEndpoint(
    val controlPort: Int,
    val videoPort: Int,
)

class ClientLaunch(
    val token: ByteArray,
    val epoch: UInt,
    val endpoint: ClientEndpoint,
    val connector: ByteConnector,
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
        )

    fun validated(
        token: String?,
        epoch: Int,
        control: Int,
        video: Int,
        major: Int,
    ): ClientLaunch? {
        token ?: return null
        if (!tokenPattern.matches(token) || epoch <= 0 || major != 1) return null
        if (control != 5561 || video != 5560) return null
        val bytes = ByteArray(32) { token.substring(it * 2, it * 2 + 2).toInt(16).toByte() }
        return ClientLaunch(bytes, epoch.toUInt(), ClientEndpoint(control, video), LoopbackTcpConnector)
    }
}
