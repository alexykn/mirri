package dev.mirri.client

import dev.mirri.client.protocol.NetworkBootstrap
import dev.mirri.client.session.AttemptConnections
import dev.mirri.client.transport.PeerAuthenticationException
import dev.mirri.client.transport.PinnedTlsConnector
import dev.mirri.client.transport.blockingBytes
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File
import java.nio.ByteBuffer
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** Desktop JVM connects the production Android adapter to production macOS TLS and MRNB. */
class NetworkInteropTest {
    private fun repositoryRoot(): File {
        var folder = File(requireNotNull(System.getProperty("user.dir"))).canonicalFile
        while (true) {
            if (File(folder, "macos-host/Package.swift").isFile) return folder
            folder = folder.parentFile ?: error("macOS host package unavailable")
        }
    }

    private fun withMacServer(block: suspend (Int, ByteArray) -> Unit) =
        runBlocking {
            assumeTrue("Explicit macOS integration run required", System.getenv("MIRRI_NETWORK_INTEROP") == "1")
            check(System.getProperty("os.name").orEmpty().startsWith("Mac")) { "Integration server requires macOS" }
            val root = repositoryRoot()
            val server =
                ProcessBuilder("swift", "run", "--package-path", "macos-host", "MirriNetworkInteropServer")
                    .directory(root)
                    .redirectError(ProcessBuilder.Redirect.INHERIT)
                    .start()
            val reader = Executors.newSingleThreadExecutor()
            try {
                val greeting =
                    reader
                        .submit<String> { server.inputStream.bufferedReader().readLine() }
                        .get(60, TimeUnit.SECONDS) ?: error("fixture server did not start")
                val fields = greeting.split(" ")
                require(fields.size == 2 && fields[1].length == 64) { "fixture server did not supply endpoint/pin" }
                val pin = ByteArray(32) { fields[1].substring(it * 2, it * 2 + 2).toInt(16).toByte() }
                block(fields[0].toInt(), pin)
            } finally {
                server.destroy()
                if (!server.waitFor(3, TimeUnit.SECONDS)) server.destroyForcibly()
                reader.shutdownNow()
            }
        }

    @Test fun actualMacTLSIdentityAndAndroidConnectorExchangeSyntheticPayload() =
        withMacServer { port, pin ->
            val owner = AttemptConnections()
            try {
                val bytes = PinnedTlsConnector("127.0.0.1", pin).connect(port, owner)
                assertEquals(7u, NetworkBootstrap.exchange(bytes, ByteArray(32) { 0x42 }))
                bytes.finishSetup()
                val payload = "mirri-tls-proof!".toByteArray(Charsets.US_ASCII)
                // Production clears the setup timeout for streaming. Bound this
                // synthetic read and close on cancellation so CI cannot hang.
                withTimeout(5000) {
                    blockingBytes(bytes::close) {
                        bytes.writeFully(ByteBuffer.wrap(payload))
                        val echoed = ByteBuffer.allocate(payload.size)
                        bytes.readFully(echoed)
                        assertArrayEquals(payload, echoed.array())
                    }
                }
            } finally {
                owner.close()
            }
        }

    @Test fun actualMacTLSIdentityRejectsDifferentAndroidPin() =
        withMacServer { port, pin ->
            val owner = AttemptConnections()
            try {
                pin[0] = (pin[0].toInt() xor 1).toByte()
                val failure = runCatching { PinnedTlsConnector("127.0.0.1", pin).connect(port, owner) }.exceptionOrNull()
                assertTrue(failure is PeerAuthenticationException)
            } finally {
                owner.close()
            }
        }
}
