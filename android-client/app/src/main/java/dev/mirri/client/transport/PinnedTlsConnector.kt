package dev.mirri.client.transport

import android.annotation.SuppressLint
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import java.io.EOFException
import java.io.IOException
import java.net.InetSocketAddress
import java.net.Socket
import java.nio.ByteBuffer
import java.security.MessageDigest
import java.security.SecureRandom
import java.security.cert.CertificateException
import java.security.cert.X509Certificate
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLException
import javax.net.ssl.SSLSocket
import javax.net.ssl.X509TrustManager
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/** Wrong/expired identity is terminal, never an invitation to fall back to plaintext. */
class PeerAuthenticationException(
    cause: Throwable,
) : IOException("TLS server authentication failed", cause)

/**
 * Exact leaf pin and validity, with TLS proving possession of its private key.
 * Public CAs are intentionally not consulted: the ephemeral self-signed leaf is
 * authenticated only by the exact USB-bootstrapped SHA-256 DER pin.
 */
@SuppressLint("CustomX509TrustManager")
class PinnedServerTrust(
    private val pin: ByteArray,
    private val now: () -> java.util.Date = { java.util.Date() },
) : X509TrustManager {
    @Volatile var rejectedIdentity: Boolean = false
        private set

    override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()

    override fun checkClientTrusted(
        chain: Array<X509Certificate>,
        authType: String,
    ): Unit = throw CertificateException("client certificates not accepted")

    override fun checkServerTrusted(
        chain: Array<X509Certificate>,
        authType: String,
    ) {
        try {
            val leaf = chain.firstOrNull() ?: throw CertificateException("missing server certificate")
            leaf.checkValidity(now())
            val actual = MessageDigest.getInstance("SHA-256").digest(leaf.encoded)
            if (pin.size != 32 || !MessageDigest.isEqual(pin, actual)) throw CertificateException("server identity mismatch")
        } catch (e: CertificateException) {
            rejectedIdentity = true
            throw e
        }
    }
}

/** Owns one raw socket before connecting; close interrupts TLS handshake, reads and writes. */
private class TlsByteConnection(
    private val socket: Socket,
) : ByteConnection {
    @Volatile private var tls: SSLSocket? = null

    @Volatile private var closed = false
    private val inputScratch = ByteArray(16 * 1024)
    private val outputScratch = ByteArray(16 * 1024)

    fun attach(value: SSLSocket) {
        tls = value
        if (closed) {
            value.close()
            throw IOException("connection closed")
        }
    }

    override fun readFully(buffer: ByteBuffer) {
        val input = requireNotNull(tls).inputStream
        while (buffer.hasRemaining()) {
            val count = input.read(inputScratch, 0, minOf(buffer.remaining(), inputScratch.size))
            if (count < 0) throw EOFException("connection closed")
            buffer.put(inputScratch, 0, count)
        }
    }

    override fun writeFully(buffer: ByteBuffer) {
        val output = requireNotNull(tls).outputStream
        while (buffer.hasRemaining()) {
            val count = minOf(buffer.remaining(), outputScratch.size)
            buffer.get(outputScratch, 0, count)
            output.write(outputScratch, 0, count)
        }
    }

    override fun finishSetup() {
        tls?.soTimeout = 0
    }

    override fun close() {
        closed = true
        runCatching { socket.close() }
        runCatching { tls?.close() }
    }
}

/** TLS 1.2+ and pinned per-session self-signed identity; no platform-CA fallback. */
class PinnedTlsConnector(
    private val host: String,
    pin: ByteArray,
) : ByteConnector {
    private val pin = pin.clone()

    @Suppress("TooGenericExceptionCaught")
    override suspend fun connect(
        port: Int,
        owner: ConnectionOwner,
    ): ByteConnection =
        withContext(Dispatchers.IO) {
            suspendCancellableCoroutine { continuation ->
                val raw = Socket()
                val connection = TlsByteConnection(raw)
                try {
                    owner.own(connection)
                    continuation.invokeOnCancellation { runCatching { connection.close() } }
                    // A fresh trust manager belongs exclusively to this handshake.
                    // SSLException alone also covers EOF/reset/listener replacement.
                    val trust = PinnedServerTrust(pin)
                    val factory =
                        SSLContext
                            .getInstance("TLS")
                            .apply { init(null, arrayOf(trust), SecureRandom()) }
                            .socketFactory
                    raw.tcpNoDelay = true
                    raw.connect(InetSocketAddress(host, port), 3000)
                    raw.soTimeout = 3000
                    val tls = factory.createSocket(raw, host, port, true) as SSLSocket
                    connection.attach(tls)
                    tls.soTimeout = 3000
                    tls.enabledProtocols = tls.supportedProtocols.filter { it == "TLSv1.3" || it == "TLSv1.2" }.toTypedArray()
                    tls.useClientMode = true
                    try {
                        tls.startHandshake()
                    } catch (e: SSLException) {
                        if (trust.rejectedIdentity) throw PeerAuthenticationException(e)
                        throw e
                    }
                    continuation.resume(connection)
                } catch (e: Exception) {
                    runCatching { connection.close() }
                    if (continuation.isActive) continuation.resumeWithException(e)
                }
            }
        }
}
