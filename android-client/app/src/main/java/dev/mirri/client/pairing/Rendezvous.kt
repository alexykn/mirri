package dev.mirri.client.pairing

import android.content.Context
import android.content.Intent
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.util.Log
import dev.mirri.client.protocol.WireException
import dev.mirri.client.transport.ByteConnection
import dev.mirri.client.transport.ConnectionOwner
import dev.mirri.client.transport.PeerAuthenticationException
import dev.mirri.client.transport.PinnedTlsConnector
import dev.mirri.client.transport.blockingBytes
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeoutOrNull
import java.net.Inet4Address
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.coroutines.resume

/** What a cable launch stores so the tablet can find and trust the host again without one. */
data class Pairing(
    val id: ByteArray,
    val key: ByteArray,
    val pin: ByteArray,
    val lastHost: String?,
)

/** App-private storage; another app can only reach it by replacing this one. */
class PairingStore(
    context: Context,
) {
    private val preferences = context.applicationContext.getSharedPreferences("mirri_pairing", Context.MODE_PRIVATE)

    fun load(): Pairing? {
        val id = preferences.getString("id", null)?.let(Hex::decode)?.takeIf { it.size == 16 } ?: return null
        val key = preferences.getString("key", null)?.let(Hex::decode)?.takeIf { it.size == 32 } ?: return null
        val pin = preferences.getString("pin", null)?.let(Hex::decode)?.takeIf { it.size == 32 } ?: return null
        return Pairing(id, key, pin, preferences.getString("host", null))
    }

    fun save(pairing: Pairing) {
        preferences
            .edit()
            .putString("id", Hex.encode(pairing.id))
            .putString("key", Hex.encode(pairing.key))
            .putString("pin", Hex.encode(pairing.pin))
            .putString("host", pairing.lastHost)
            .apply()
    }

    fun rememberHost(host: String) {
        if (load() != null) preferences.edit().putString("host", host).apply()
    }

    fun clear() {
        preferences.edit().clear().apply()
    }
}

object Hex {
    private val pattern = Regex("([0-9a-f]{2})*")

    fun decode(text: String): ByteArray? =
        if (pattern.matches(text)) ByteArray(text.length / 2) { text.substring(it * 2, it * 2 + 2).toInt(16).toByte() } else null

    fun encode(bytes: ByteArray): String = bytes.joinToString("") { "%02x".format(it) }
}

/** The same facts an ADB launch passes as Intent extras. */
data class RendezvousLaunch(
    val token: ByteArray,
    val epoch: Int,
    val host: String,
    val pin: ByteArray,
    val rtc: Boolean,
    val sessionId: ByteArray,
) {
    fun extras(intent: Intent): Intent =
        intent.apply {
            putExtra("mirri_token", Hex.encode(token))
            putExtra("mirri_epoch", epoch)
            putExtra("mirri_control_port", 5561)
            putExtra("mirri_video_port", 5560)
            putExtra("mirri_protocol_major", 1)
            putExtra("mirri_mode", "network")
            putExtra("mirri_host", host)
            putExtra("mirri_pin", Hex.encode(pin))
            if (rtc) {
                putExtra("mirri_media", "rtc")
                putExtra("mirri_session_id", Hex.encode(sessionId))
            }
        }
}

/** MRRV v1, spoken only inside TLS to the host's pinned persistent certificate. */
object RendezvousWire {
    const val REASON_IDLE = 0
    const val REASON_OPENED = 1
    const val REASON_RECOVERING = 2
    const val KIND_WAIT = 2
    const val KIND_LAUNCH = 3
    const val KIND_REJECTED = 4
    const val LAUNCH_BODY = 89
    private const val MAGIC = 0x4d525256

    fun hello(
        pairing: Pairing,
        reason: Int,
    ): ByteBuffer =
        ByteBuffer.allocate(57).order(ByteOrder.BIG_ENDIAN).apply {
            putInt(MAGIC)
            putShort(1)
            putShort(1)
            put(pairing.id)
            put(pairing.key)
            put(reason.toByte())
            flip()
        }

    /** Returns the message kind; anything but a v1 MRRV header is a protocol error. */
    fun kind(header: ByteBuffer): Int {
        if (header.remaining() != 8 || header.int != MAGIC || header.short.toInt() != 1) throw WireException("invalid rendezvous reply")
        return header.short.toInt()
    }

    fun launch(body: ByteBuffer): RendezvousLaunch {
        if (body.remaining() != LAUNCH_BODY) throw WireException("invalid rendezvous launch")
        val token = ByteArray(32).also(body::get)
        val epoch = body.int
        val address = ByteArray(4).also(body::get)
        val pin = ByteArray(32).also(body::get)
        val media = body.get().toInt()
        val session = ByteArray(16).also(body::get)
        if (epoch <= 0 || media !in 0..1) throw WireException("invalid rendezvous launch")
        return RendezvousLaunch(token, epoch, address.joinToString(".") { (it.toInt() and 255).toString() }, pin, media == 1, session)
    }
}

/** The host no longer knows this pairing; only a new cable launch can replace it. */
class PairingRevoked : Exception("pairing revoked")

/** Finds the paired host on the LAN and waits, authenticated, for it to start a session. */
class RendezvousClient(
    context: Context,
    private val store: PairingStore,
) {
    private val nsd = context.applicationContext.getSystemService(NsdManager::class.java)

    /** Returns only with a launch; throws [PairingRevoked] if the host rejects the stored secret. */
    @Suppress("TooGenericExceptionCaught")
    suspend fun awaitLaunch(reason: Int): RendezvousLaunch {
        var currentReason = reason
        while (true) {
            val pairing = store.load() ?: throw PairingRevoked()
            for ((host, port) in candidates(pairing)) {
                try {
                    val launch = attempt(pairing, host, port, currentReason)
                    store.rememberHost(host)
                    return launch
                } catch (e: CancellationException) {
                    throw e
                } catch (e: PairingRevoked) {
                    store.clear()
                    throw e
                } catch (e: PeerAuthenticationException) {
                    // Something else answers at that address; keep looking for the pinned host.
                    Log.i("MirriRendezvous", "peer at candidate is not the paired host")
                } catch (e: Exception) {
                    Log.i("MirriRendezvous", "candidate unavailable type=${e.javaClass.simpleName}")
                }
            }
            // Only the first try speaks for a person opening the app.
            if (currentReason == RendezvousWire.REASON_OPENED) currentReason = RendezvousWire.REASON_IDLE
            delay(1_500)
        }
    }

    private suspend fun attempt(
        pairing: Pairing,
        host: String,
        port: Int,
        reason: Int,
    ): RendezvousLaunch {
        var owned: ByteConnection? = null
        val owner =
            object : ConnectionOwner {
                override fun own(connection: ByteConnection) {
                    owned = connection
                }
            }
        val connection = PinnedTlsConnector(host, pairing.pin).connect(port, owner)
        try {
            return blockingBytes(connection::close) {
                connection.writeFully(RendezvousWire.hello(pairing, reason))
                // The host sends a wait frame every two seconds while it is alive.
                connection.setReadTimeout(8_000)
                val header = ByteBuffer.allocate(8).order(ByteOrder.BIG_ENDIAN)
                while (true) {
                    header.clear()
                    connection.readFully(header)
                    header.flip()
                    when (RendezvousWire.kind(header)) {
                        RendezvousWire.KIND_WAIT -> continue
                        RendezvousWire.KIND_REJECTED -> throw PairingRevoked()
                        RendezvousWire.KIND_LAUNCH -> {
                            val body = ByteBuffer.allocate(RendezvousWire.LAUNCH_BODY).order(ByteOrder.BIG_ENDIAN)
                            connection.readFully(body)
                            body.flip()
                            return@blockingBytes RendezvousWire.launch(body)
                        }
                        else -> throw WireException("invalid rendezvous reply")
                    }
                }
                @Suppress("UNREACHABLE_CODE")
                throw WireException("rendezvous ended")
            }
        } finally {
            runCatching { (owned ?: connection).close() }
        }
    }

    /** Service discovery first; the address that worked last time covers networks that block multicast. */
    private suspend fun candidates(pairing: Pairing): List<Pair<String, Int>> {
        val found = withTimeoutOrNull(3_000) { discover() }
        return listOfNotNull(found, pairing.lastHost?.let { it to PORT }).distinct()
    }

    private suspend fun discover(): Pair<String, Int>? =
        suspendCancellableCoroutine { continuation ->
            var listener: NsdManager.DiscoveryListener? = null
            var resolving = false

            fun finish(result: Pair<String, Int>?) {
                listener?.let { runCatching { nsd.stopServiceDiscovery(it) } }
                listener = null
                if (continuation.isActive) continuation.resume(result)
            }
            val resolver =
                object : NsdManager.ResolveListener {
                    override fun onResolveFailed(
                        info: NsdServiceInfo,
                        code: Int,
                    ) {
                        resolving = false
                    }

                    // The replacement API needs API 34; this client targets 31.
                    @Suppress("DEPRECATION")
                    override fun onServiceResolved(info: NsdServiceInfo) {
                        val address = (info.host as? Inet4Address)?.hostAddress
                        if (address != null && info.port in 1..65535) finish(address to info.port) else resolving = false
                    }
                }
            val created =
                object : NsdManager.DiscoveryListener {
                    override fun onDiscoveryStarted(type: String) = Unit

                    override fun onDiscoveryStopped(type: String) = Unit

                    override fun onStartDiscoveryFailed(
                        type: String,
                        code: Int,
                    ) = finish(null)

                    override fun onStopDiscoveryFailed(
                        type: String,
                        code: Int,
                    ) = Unit

                    override fun onServiceLost(info: NsdServiceInfo) = Unit

                    @Suppress("DEPRECATION")
                    override fun onServiceFound(info: NsdServiceInfo) {
                        // The platform resolves one service at a time.
                        if (!resolving) {
                            resolving = true
                            runCatching { nsd.resolveService(info, resolver) }.onFailure { resolving = false }
                        }
                    }
                }
            listener = created
            continuation.invokeOnCancellation { runCatching { nsd.stopServiceDiscovery(created) } }
            runCatching { nsd.discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, created) }.onFailure { finish(null) }
        }

    companion object {
        const val SERVICE_TYPE = "_mirri._tcp"
        const val PORT = 5562
    }
}
