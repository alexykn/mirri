package dev.mirri.client.transport

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import java.io.EOFException
import java.net.InetSocketAddress
import java.nio.ByteBuffer
import java.nio.channels.SocketChannel
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/** An ordered byte stream. No Mirri frame, message or socket implementation escapes this API. */
interface ByteConnection : AutoCloseable {
    fun readFully(buffer: ByteBuffer)

    fun writeFully(buffer: ByteBuffer)

    override fun close()
}

/** The attempt joins the raw connection before connect or cancellable dispatcher delivery. */
interface ConnectionOwner {
    fun own(connection: ByteConnection)
}

interface ByteConnector {
    suspend fun connect(
        port: Int,
        owner: ConnectionOwner,
    ): ByteConnection
}

private class TcpByteConnection(
    val socket: SocketChannel,
) : ByteConnection {
    override fun readFully(buffer: ByteBuffer) {
        while (buffer.hasRemaining()) if (socket.read(buffer) < 0) throw EOFException("connection closed")
    }

    override fun writeFully(buffer: ByteBuffer) {
        while (buffer.hasRemaining()) if (socket.write(buffer) < 0) throw EOFException("connection closed")
    }

    override fun close() = socket.close()
}

/** USB reverse mapping terminates only on 127.0.0.1; no wildcard or LAN fallback. */
object LoopbackTcpConnector : ByteConnector {
    // Provider and IO operations can fail with checked or unchecked exceptions. Close the raw resource in both cases.
    @Suppress("TooGenericExceptionCaught")
    override suspend fun connect(
        port: Int,
        owner: ConnectionOwner,
    ): ByteConnection =
        withContext(Dispatchers.IO) {
            suspendCancellableCoroutine { continuation ->
                val connection = TcpByteConnection(SocketChannel.open())
                try {
                    owner.own(connection)
                    continuation.invokeOnCancellation { runCatching { connection.close() } }
                    val socket = connection.socket
                    socket.configureBlocking(true)
                    socket.socket().tcpNoDelay = true
                    socket.socket().connect(InetSocketAddress("127.0.0.1", port), 3000)
                    continuation.resume(connection)
                } catch (e: Exception) {
                    connection.close()
                    if (continuation.isActive) continuation.resumeWithException(e)
                }
            }
        }
}

/** Cancellation closes the byte stream from the cancelling thread to interrupt blocking IO. */
@Suppress("TooGenericExceptionCaught")
suspend fun <T> blockingBytes(
    close: () -> Unit,
    operation: () -> T,
): T =
    withContext(Dispatchers.IO) {
        suspendCancellableCoroutine { continuation ->
            continuation.invokeOnCancellation { runCatching { close() } }
            try {
                continuation.resume(operation())
            } catch (e: Exception) {
                if (continuation.isActive) continuation.resumeWithException(e)
            }
        }
    }
