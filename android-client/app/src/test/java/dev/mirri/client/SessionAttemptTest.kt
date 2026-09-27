package dev.mirri.client

import dev.mirri.client.protocol.ControlChannel
import dev.mirri.client.protocol.WireException
import dev.mirri.client.protocol.WireOrder
import dev.mirri.client.session.ClientAttempt
import dev.mirri.client.transport.LoopbackTcpConnector
import dev.mirri.client.transport.blockingBytes
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.InetSocketAddress
import java.nio.ByteBuffer
import java.nio.channels.ServerSocketChannel
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

class SessionAttemptTest {
    @Test fun reconnectUsesNewAttemptAndIgnoresCallbacksFromClosedOwner() =
        runBlocking {
            val old = ClientAttempt()
            val fresh = ClientAttempt()
            val reports = AtomicInteger()
            old.reportDecoderFailure({ WireException("first") }) { reports.incrementAndGet() }
            assertEquals(
                "first",
                old.failure
                    .tryReceive()
                    .getOrNull()
                    ?.message,
            )
            old.close()
            old.reportDecoderFailure({ WireException("stale") }) { reports.incrementAndGet() }
            assertEquals(null, old.failure.tryReceive().getOrNull())
            fresh.reportDecoderFailure({ WireException("fresh") }) { reports.incrementAndGet() }
            assertEquals(
                "fresh",
                fresh.failure
                    .tryReceive()
                    .getOrNull()
                    ?.message,
            )
            assertEquals(2, reports.get())
            fresh.close()
        }

    @Test fun prestreamDecoderFailureWakesRealBlockedControlReadOnce() =
        runBlocking {
            ServerSocketChannel.open().use { server ->
                server.bind(InetSocketAddress("127.0.0.1", 0))
                val owner = ClientAttempt()
                val bytes = LoopbackTcpConnector.connect((server.localAddress as InetSocketAddress).port, owner.connections)
                server.accept().use {
                    val writerScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
                    val channel = ControlChannel(bytes, writerScope) {}
                    owner.control = channel
                    val reading = CountDownLatch(1)
                    val read =
                        async(Dispatchers.IO) {
                            runCatching {
                                blockingBytes(channel::close) {
                                    reading.countDown()
                                    channel.read(WireOrder(WireOrder.Peer.HOST, WireOrder.Channel.CONTROL, 1uL))
                                }
                            }
                        }
                    try {
                        assertTrue(reading.await(1, TimeUnit.SECONDS))
                        assertFalse(owner.streaming)
                        val reports = AtomicInteger()
                        owner.reportDecoderFailure({ WireException("decoder failed") }) {
                            reports.incrementAndGet()
                            owner.interrupt()
                        }
                        assertTrue(withTimeout(1500) { read.await().isFailure })
                        assertEquals(
                            "decoder failed",
                            owner.failure
                                .tryReceive()
                                .getOrNull()
                                ?.message,
                        )
                        owner.reportDecoderFailure({ WireException("stale callback") }) { reports.incrementAndGet() }
                        assertEquals(1, reports.get())
                        assertTrue(runCatching { bytes.writeFully(ByteBuffer.wrap(byteArrayOf(1))) }.isFailure)
                    } finally {
                        owner.interrupt()
                        writerScope.cancel()
                    }
                }
            }
        }
}
