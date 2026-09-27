package dev.mirri.client.transport

import dev.mirri.client.protocol.MessageType
import dev.mirri.client.protocol.Value
import dev.mirri.client.protocol.WireCodec
import dev.mirri.client.protocol.WireException
import dev.mirri.client.protocol.WireMessage
import dev.mirri.client.protocol.WireOrder
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import java.net.InetSocketAddress
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.channels.SocketChannel
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

internal fun SocketChannel.readFully(buffer: ByteBuffer) {
    while (buffer.hasRemaining()) if (read(buffer) < 0) throw WireException("connection closed")
}

internal fun SocketChannel.writeFully(buffer: ByteBuffer) {
    while (buffer.hasRemaining()) if (write(buffer) < 0) throw WireException("connection closed")
}

/** Registers the raw socket before connect/hello can block or a dispatcher can cancel delivery.
 * One attempt owns at most its control and video socket, including incomplete connections. */
class AttemptSockets : AutoCloseable {
    private val sockets = mutableListOf<SocketChannel>()
    private var closed = false

    @Synchronized fun own(socket: SocketChannel) {
        if (closed) {
            socket.close()
            throw CancellationException("attempt closed")
        }
        sockets.add(socket)
    }

    override fun close() {
        val owned =
            synchronized(this) {
                if (closed) return
                closed = true
                sockets.toList().also { sockets.clear() }
            }
        owned.forEach { runCatching { it.close() } }
    }
}

/** Cancellation closes the owned SocketChannel immediately, interrupting blocking connect. */
suspend fun connect(
    port: Int,
    owner: AttemptSockets,
): SocketChannel =
    withContext(Dispatchers.IO) {
        suspendCancellableCoroutine { continuation ->
            val socket = SocketChannel.open()
            try {
                owner.own(socket)
                continuation.invokeOnCancellation { runCatching { socket.close() } }
                socket.configureBlocking(true)
                socket.socket().tcpNoDelay = true
                socket.socket().connect(InetSocketAddress("127.0.0.1", port), 3000)
                continuation.resume(socket)
            } catch (e: Exception) {
                socket.close()
                if (continuation.isActive) continuation.resumeWithException(e)
            }
        }
    }

/** Cancellation closes the channel from the cancelling thread, waking blocking read/write. */
suspend fun <T> blockingSocket(
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

/** Raw socket remains owned even if prompt cancellation discards the authenticated wrapper. */
suspend fun openVideo(
    port: Int,
    owner: AttemptSockets,
    epoch: UInt,
    id: ByteArray,
    token: ByteArray,
): VideoChannel {
    val video = VideoChannel(connect(port, owner))
    try {
        blockingSocket(video::close) { video.hello(epoch, id, token) }
    } catch (e: Exception) {
        video.close()
        throw e
    }
    return video
}

/** Single ordered writer with a finite queue; no input can be silently discarded. */
class ControlChannel(
    private val socket: SocketChannel,
    scope: CoroutineScope,
    private val onFailure: (Throwable) -> Unit,
) : AutoCloseable {
    private val outgoing = Channel<Pair<WireMessage, CompletableDeferred<Unit>?>>(128)

    @Volatile private var closed = false
    private var sequence = 0uL

    @Volatile private var inFlight: CompletableDeferred<Unit>? = null
    private val writer: Job =
        scope.launch(Dispatchers.IO) {
            try {
                for ((message, completion) in outgoing) {
                    inFlight = completion
                    socket.writeFully(ByteBuffer.wrap(WireCodec.encode(message.copy(sequence = sequence++))))
                    completion?.complete(Unit)
                    inFlight = null
                }
            } catch (e: Exception) {
                inFlight?.completeExceptionally(e)
                outgoing.close(e)
                while (true) {
                    val pending = outgoing.tryReceive().getOrNull() ?: break
                    pending.second?.completeExceptionally(e)
                }
                if (!closed) onFailure(e)
            }
        }

    fun send(
        type: Int,
        fields: List<Value>,
    ): Boolean {
        val message = WireMessage(type, 0uL, System.nanoTime().toULong(), fields)
        return outgoing.trySend(message to null).isSuccess
    }

    suspend fun sendAndWait(
        type: Int,
        fields: List<Value>,
    ) {
        val done = CompletableDeferred<Unit>()
        outgoing.send(WireMessage(type, 0uL, System.nanoTime().toULong(), fields) to done)
        done.await()
    }

    fun read(order: WireOrder): WireMessage {
        while (true) {
            val header = ByteBuffer.allocate(32)
            socket.readFully(header)
            val bytes = header.array()
            val length = WireCodec.payloadLength(bytes)
            val body = ByteBuffer.allocate(32 + length)
            body.put(bytes)
            socket.readFully(body)
            val message = WireCodec.decode(body.array())
            if (message != null) {
                order.accept(message)
                return message
            }
            val seq =
                ByteBuffer
                    .wrap(bytes, 12, 8)
                    .order(ByteOrder.BIG_ENDIAN)
                    .long
                    .toULong()
            order.skipUnknown(seq)
        }
    }

    override fun close() {
        closed = true
        val failure = WireException("connection closed")
        outgoing.close(failure)
        writer.cancel()
        try {
            socket.close()
        } finally {
            inFlight?.completeExceptionally(failure)
            while (true) {
                val pending = outgoing.tryReceive().getOrNull() ?: break
                pending.second?.completeExceptionally(failure)
            }
        }
    }
}

/** Dedicated video socket; control traffic never waits behind video input. */
class VideoChannel(
    val socket: SocketChannel,
) : AutoCloseable {
    fun hello(
        epoch: UInt,
        sessionId: ByteArray,
        token: ByteArray,
    ) {
        val fields = listOf(Value.Number(epoch.toULong()), Value.Bytes(sessionId), Value.Bytes(token))
        socket.writeFully(
            ByteBuffer.wrap(WireCodec.encode(WireMessage(MessageType.VIDEO_HELLO.id, 0uL, System.nanoTime().toULong(), fields))),
        )
    }

    override fun close() = socket.close()
}
