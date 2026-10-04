package dev.mirri.client

import dev.mirri.client.protocol.NetworkBootstrap
import dev.mirri.client.protocol.WireException
import dev.mirri.client.session.AttemptConnections
import dev.mirri.client.session.ClientLaunchBoundary
import dev.mirri.client.transport.ByteConnection
import dev.mirri.client.transport.PeerAuthenticationException
import dev.mirri.client.transport.PinnedServerTrust
import dev.mirri.client.transport.PinnedTlsConnector
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.EOFException
import java.net.ServerSocket
import java.nio.ByteBuffer
import java.security.KeyStore
import java.security.MessageDigest
import java.security.cert.CertificateException
import java.security.cert.CertificateExpiredException
import java.util.Date
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import javax.net.ssl.TrustManagerFactory
import javax.net.ssl.X509TrustManager

private class FragmentedBootstrapBytes(
    response: ByteArray,
) : ByteConnection {
    private val incoming = ByteBuffer.wrap(response)
    val request = ByteBuffer.allocate(40)

    override fun readFully(buffer: ByteBuffer) {
        while (buffer.hasRemaining() && incoming.hasRemaining()) {
            repeat(minOf(3, buffer.remaining(), incoming.remaining())) { buffer.put(incoming.get()) }
        }
        if (buffer.hasRemaining()) throw java.io.EOFException("connection closed")
    }

    override fun writeFully(buffer: ByteBuffer) {
        request.put(buffer)
    }

    override fun close() = Unit
}

class NetworkBootstrapTest {
    private val token = ByteArray(32) { 0x42 }

    @Test fun rtcSelectionRequiresExactBootstrappedSessionId() {
        val hex = "ab".repeat(32)
        val pin = "cd".repeat(32)

        fun selected(
            media: String?,
            id: String?,
        ) = ClientLaunchBoundary.validated(hex, 1, 5561, 5560, 1, "network", "192.0.2.15", pin, media, id)
        assertEquals(null, selected("rtc", null))
        assertEquals(null, selected("rtc", "ab".repeat(15)))
        assertEquals(null, selected("RTC", "ab".repeat(16)))
        assertEquals(null, selected(null, "ab".repeat(16)))
        val rtc = selected("rtc", "ab".repeat(16))!!
        assertEquals(dev.mirri.client.session.NetworkMedia.RTC, rtc.media)
        assertArrayEquals(ByteArray(16) { 0xab.toByte() }, rtc.sessionId)
        assertEquals(dev.mirri.client.session.NetworkMedia.COMPARISON, selected(null, null)?.media)
    }

    @Test fun fixedRequestAndFragmentedResponseYieldHostEpoch() {
        val bytes = FragmentedBootstrapBytes(byteArrayOf(0x4d, 0x52, 0x4e, 0x42, 0, 1, 0, 0, 0, 0, 0, 7))
        assertEquals(7u, NetworkBootstrap.exchange(bytes, token))
        val sent = bytes.request.array()
        assertArrayEquals(byteArrayOf(0x4d, 0x52, 0x4e, 0x42, 0, 1, 0, 1), sent.copyOfRange(0, 8))
        assertArrayEquals(token, sent.copyOfRange(8, 40))
    }

    @Test fun explicitRejectionIsTerminalButTruncatedPrefaceIsRetryable() {
        val reject = FragmentedBootstrapBytes(byteArrayOf(0x4d, 0x52, 0x4e, 0x42, 0, 1, 0, 1, 0, 0, 0, 0))
        assertThrows(WireException::class.java) { NetworkBootstrap.exchange(reject, token) }
        val truncated = FragmentedBootstrapBytes(byteArrayOf(0x4d, 0x52))
        assertThrows(EOFException::class.java) { NetworkBootstrap.exchange(truncated, token) }
        val malformed = FragmentedBootstrapBytes(byteArrayOf(0x4d, 0x52, 0x4e, 0x42, 0, 1, 0, 1, 0, 0, 0, 7))
        assertThrows(WireException::class.java) { NetworkBootstrap.exchange(malformed, token) }
    }

    @Test fun mixedUnknownAndInvalidEndpointLaunchesFailClosed() {
        val hex = "ab".repeat(32)
        val pin = "cd".repeat(32)
        val valid = ClientLaunchBoundary.validated(hex, 1, 5561, 5560, 1, "network", "192.0.2.15", pin)
        assertEquals("192.0.2.15", valid?.endpoint?.host)
        assertNull(ClientLaunchBoundary.validated(hex, 1, 5561, 5560, 1, "usb", "192.0.2.15", pin))
        assertNull(ClientLaunchBoundary.validated(hex, 1, 5561, 5560, 1, "network", "127.0.0.1", pin))
        assertNull(ClientLaunchBoundary.validated(hex, 1, 5561, 5560, 1, "network", "192.0.2.15", null))
        assertNull(ClientLaunchBoundary.validated(hex, 1, 5561, 5560, 1, "bogus"))
        assertNull(ClientLaunchBoundary.validated(hex, 1, 5561, 5560, 1, null))
    }

    @Test fun exactPinAndValidityRejectWrongIdentity() {
        val trustStore = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm())
        trustStore.init(null as KeyStore?)
        val cert =
            trustStore.trustManagers
                .filterIsInstance<X509TrustManager>()
                .flatMap { it.acceptedIssuers.asList() }
                .first { runCatching { it.checkValidity(Date()) }.isSuccess }
        val pin = MessageDigest.getInstance("SHA-256").digest(cert.encoded)
        val trust = PinnedServerTrust(pin)
        trust.checkServerTrusted(arrayOf(cert), "EC")
        assertTrue(trust.acceptedIssuers.isEmpty())
        assertThrows(CertificateException::class.java) {
            PinnedServerTrust(ByteArray(32)).checkServerTrusted(arrayOf(cert), "EC")
        }
        assertThrows(CertificateException::class.java) { trust.checkServerTrusted(emptyArray(), "EC") }
        assertThrows(CertificateExpiredException::class.java) {
            PinnedServerTrust(pin) { Date(cert.notAfter.time + TimeUnit.DAYS.toMillis(1)) }
                .checkServerTrusted(arrayOf(cert), "EC")
        }
    }

    @Test fun interruptedPeerHandshakeIsRetryableNotAuthenticationFailure() =
        runBlocking {
            ServerSocket(0, 1, java.net.InetAddress.getByName("127.0.0.1")).use { server ->
                val responder =
                    Thread { runCatching { server.accept().use { it.close() } } }.apply {
                        isDaemon = true
                        start()
                    }
                val owner = AttemptConnections()
                try {
                    val failure =
                        withTimeout(5000) {
                            runCatching { PinnedTlsConnector("127.0.0.1", ByteArray(32)).connect(server.localPort, owner) }
                        }.exceptionOrNull()
                    assertTrue(failure is java.io.IOException)
                    assertTrue(failure !is PeerAuthenticationException)
                } finally {
                    owner.close()
                    server.close()
                    responder.join(1000)
                }
            }
        }

    @Test fun closingOwnedSocketInterruptsPendingTlsHandshake() =
        runBlocking {
            ServerSocket(0, 1, java.net.InetAddress.getByName("127.0.0.1")).use { server ->
                val accepted = CountDownLatch(1)
                val responder =
                    Thread {
                        runCatching {
                            server.accept().use {
                                accepted.countDown()
                                Thread.sleep(2000)
                            }
                        }
                    }.apply {
                        isDaemon = true
                        start()
                    }
                val owner = AttemptConnections()
                try {
                    val connecting =
                        async(Dispatchers.IO) {
                            runCatching { PinnedTlsConnector("127.0.0.1", ByteArray(32)).connect(server.localPort, owner) }
                        }
                    assertTrue(accepted.await(1, TimeUnit.SECONDS))
                    owner.close()
                    val failure = withTimeout(1500) { connecting.await().exceptionOrNull() }
                    assertTrue(failure is java.io.IOException)
                    assertTrue(failure !is PeerAuthenticationException)
                } finally {
                    owner.close()
                    server.close()
                    responder.join(2200)
                }
            }
        }
}
