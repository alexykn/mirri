package dev.mirri.client.transport

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import java.nio.ByteBuffer
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/** An ordered byte stream. No Mirri frame, message or socket implementation escapes this API. */
interface ByteConnection : AutoCloseable {
    fun readFully(buffer: ByteBuffer)

    fun writeFully(buffer: ByteBuffer)

    /** Clear connection-establishment read deadlines once the authenticated setup completes. */
    fun finishSetup() = Unit

    /** Bound a blocking read where silence means the peer is gone; 0 waits forever. */
    fun setReadTimeout(milliseconds: Int) = Unit

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
