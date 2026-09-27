package dev.mirri.client.protocol

import dev.mirri.client.transport.ByteConnection
import dev.mirri.client.transport.ByteConnector
import dev.mirri.client.transport.ConnectionOwner
import dev.mirri.client.transport.blockingBytes
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.launch
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** Authenticated video bootstrap occurs above the raw byte connector. */
@Suppress("TooGenericExceptionCaught")
suspend fun openVideo(
    connector: ByteConnector,
    port: Int,
    owner: ConnectionOwner,
    epoch: UInt,
    id: ByteArray,
    token: ByteArray,
): VideoChannel {
    val video = VideoChannel(connector.connect(port, owner))
    try {
        blockingBytes(video::close) { video.hello(epoch, id, token) }
    } catch (e: Exception) {
        video.close()
        throw e
    }
    return video
}

/** Mirri control framing and a single ordered writer with a finite 128-entry queue. */
class ControlChannel(
    private val bytes: ByteConnection,
    scope: CoroutineScope,
    private val onFailure: (Throwable) -> Unit,
) : AutoCloseable {
    private val outgoing = Channel<Pair<WireMessage, CompletableDeferred<Unit>?>>(128)

    @Volatile private var closed = false
    private var sequence = 0uL

    @Volatile private var inFlight: CompletableDeferred<Unit>? = null

    @Suppress("TooGenericExceptionCaught")
    private val writer: Job =
        scope.launch(Dispatchers.IO) {
            try {
                for ((message, completion) in outgoing) {
                    inFlight = completion
                    bytes.writeFully(ByteBuffer.wrap(WireCodec.encode(message.copy(sequence = sequence++))))
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
            bytes.readFully(header)
            val raw = header.array()
            val length = WireCodec.payloadLength(raw)
            val body = ByteBuffer.allocate(32 + length)
            body.put(raw)
            bytes.readFully(body)
            val message = WireCodec.decode(body.array())
            if (message != null) {
                order.accept(message)
                return message
            }
            val sequence =
                ByteBuffer
                    .wrap(raw, 12, 8)
                    .order(ByteOrder.BIG_ENDIAN)
                    .long
                    .toULong()
            order.skipUnknown(sequence)
        }
    }

    override fun close() {
        closed = true
        val failure = WireException("connection closed")
        outgoing.close(failure)
        writer.cancel()
        try {
            bytes.close()
        } finally {
            inFlight?.completeExceptionally(failure)
            while (true) {
                val pending = outgoing.tryReceive().getOrNull() ?: break
                pending.second?.completeExceptionally(failure)
            }
        }
    }
}

/** Dedicated Mirri video channel; receive buffers remain caller-owned. */
class VideoChannel(
    private val bytes: ByteConnection,
) : AutoCloseable {
    fun hello(
        epoch: UInt,
        sessionId: ByteArray,
        token: ByteArray,
    ) {
        val fields = listOf(Value.Number(epoch.toULong()), Value.Bytes(sessionId), Value.Bytes(token))
        bytes.writeFully(
            ByteBuffer.wrap(WireCodec.encode(WireMessage(MessageType.VIDEO_HELLO.id, 0uL, System.nanoTime().toULong(), fields))),
        )
    }

    fun readFully(buffer: ByteBuffer) = bytes.readFully(buffer)

    override fun close() = bytes.close()
}
