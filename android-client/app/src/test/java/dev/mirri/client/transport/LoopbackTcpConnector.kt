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

/** Plaintext loopback fixture for owner/cancellation tests; production connects only through pinned TLS. */
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
