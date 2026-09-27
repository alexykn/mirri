package dev.mirri.client

import dev.mirri.client.protocol.Value
import dev.mirri.client.protocol.WireCodec
import dev.mirri.client.protocol.WireOrder
import dev.mirri.client.transport.AttemptSockets
import dev.mirri.client.transport.ControlChannel
import dev.mirri.client.transport.blockingSocket
import dev.mirri.client.transport.connect
import dev.mirri.client.transport.openVideo
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.cancel
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.net.InetSocketAddress
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.channels.ServerSocketChannel
import java.nio.channels.SocketChannel
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

class ControlChannelTest {
    @Test fun rawControlSocketIsOwnedBeforeChannelConstruction() =
        runBlocking {
            ServerSocketChannel.open().use { server ->
                server.bind(InetSocketAddress("127.0.0.1", 0))
                val owner = AttemptSockets()
                val socket = connect((server.localAddress as InetSocketAddress).port, owner)
                server.accept().use { peer ->
                    owner.close() // Simulates cancellation between IO -> Main and wrapper assignment.
                    assertFalse(socket.isOpen)
                    assertEquals(-1, peer.read(ByteBuffer.allocate(1)))
                }
            }
        }

    @Test fun cancellingActualControlReadClosesSocketAndWakesIO() =
        runBlocking {
            ServerSocketChannel.open().use { server ->
                server.bind(InetSocketAddress("127.0.0.1", 0))
                val owner = AttemptSockets()
                val socket = connect((server.localAddress as InetSocketAddress).port, owner)
                server.accept().use {
                    val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
                    val channel = ControlChannel(socket, scope) { }
                    val started = CountDownLatch(1)
                    try {
                        val read =
                            async {
                                blockingSocket(channel::close) {
                                    started.countDown()
                                    channel.read(WireOrder(WireOrder.Peer.HOST, WireOrder.Channel.CONTROL, 1uL))
                                }
                            }
                        assertTrue(withContext(Dispatchers.IO) { started.await(1, TimeUnit.SECONDS) })
                        withTimeout(1500) { read.cancelAndJoin() }
                        assertFalse(socket.isOpen)
                    } finally {
                        owner.close()
                        scope.cancel()
                    }
                }
            }
        }

    @Test fun videoHelloFailureClosesOwnedSocketBeforeAttemptFinally() =
        runBlocking {
            ServerSocketChannel.open().use { server ->
                server.bind(InetSocketAddress("127.0.0.1", 0))
                val owner = AttemptSockets()
                val peer = async(Dispatchers.IO) { server.accept() }
                try {
                    openVideo((server.localAddress as InetSocketAddress).port, owner, 1u, ByteArray(16), ByteArray(1))
                    fail("invalid authentication token must fail before hello write")
                } catch (_: IllegalArgumentException) {
                    withTimeout(1500) {
                        peer.await().use { assertEquals(-1, it.read(ByteBuffer.allocate(1))) }
                    }
                } finally {
                    owner.close()
                    peer.cancel()
                }
            }
        }

    @Test fun orderedWritesAreFramedAcrossLocalhostSocket() =
        runBlocking {
            val server = ServerSocketChannel.open()
            server.bind(InetSocketAddress("127.0.0.1", 0))
            val port = (server.localAddress as InetSocketAddress).port
            val received = mutableListOf<ULong>()
            val reader =
                Thread {
                    server.accept().use { peer ->
                        repeat(2) {
                            val header = ByteBuffer.allocate(32).order(ByteOrder.BIG_ENDIAN)
                            while (header.hasRemaining()) check(peer.read(header) >= 0)
                            val bytes = header.array()
                            val payload = ByteBuffer.allocate(32 + WireCodec.payloadLength(bytes))
                            payload.put(bytes)
                            while (payload.hasRemaining()) check(peer.read(payload) >= 0)
                            received.add(WireCodec.decode(payload.array())!!.sequence)
                        }
                    }
                }
            reader.start()
            val socket = SocketChannel.open(InetSocketAddress("127.0.0.1", port))
            val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
            var failure: Throwable? = null
            val channel = ControlChannel(socket, scope) { failure = it }
            val fields = listOf(Value.Bytes(ByteArray(16)), Value.Number(1uL))
            channel.sendAndWait(22, fields)
            channel.sendAndWait(22, fields)
            reader.join(3000)
            channel.close()
            scope.cancel()
            server.close()
            assertEquals(listOf(0uL, 1uL), received)
            assertNull(failure)
        }
}
