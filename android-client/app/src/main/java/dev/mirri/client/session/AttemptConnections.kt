package dev.mirri.client.session

import dev.mirri.client.transport.ByteConnection
import dev.mirri.client.transport.ConnectionOwner
import kotlinx.coroutines.CancellationException

/** Attempt-level resource owner; closing interrupts both pending and authenticated byte connections. */
class AttemptConnections :
    ConnectionOwner,
    AutoCloseable {
    private val connections = mutableListOf<ByteConnection>()
    private var closed = false

    @Synchronized override fun own(connection: ByteConnection) {
        if (closed) {
            connection.close()
            throw CancellationException("attempt closed")
        }
        connections.add(connection)
    }

    override fun close() {
        val owned =
            synchronized(this) {
                if (closed) return
                closed = true
                connections.toList().also { connections.clear() }
            }
        owned.forEach { runCatching { it.close() } }
    }
}
