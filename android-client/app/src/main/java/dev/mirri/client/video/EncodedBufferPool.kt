package dev.mirri.client.video

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import java.nio.ByteBuffer
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.TimeUnit

/** Three leases at the 16 MiB AU bound; exhausted leases block receive rather than grow memory. */
class EncodedBufferPool(
    count: Int = 3,
    size: Int = 16_777_216,
) {
    private val buffers = ArrayBlockingQueue<ByteBuffer>(count)

    init {
        repeat(count) { buffers.add(ByteBuffer.allocateDirect(size)) }
    }

    val available: Int get() = buffers.size

    fun acquire(): ByteBuffer = buffers.take().apply { clear() }

    fun release(buffer: ByteBuffer) {
        buffer.clear()
        check(buffers.offer(buffer))
    }

    private suspend fun acquireCancellable(): ByteBuffer =
        withContext(Dispatchers.IO) {
            var lease: ByteBuffer? = null
            while (lease == null) {
                currentCoroutineContext().ensureActive()
                lease = buffers.poll(25, TimeUnit.MILLISECONDS)
            }
            lease.clear()
            lease
        }

    suspend fun <T> withLease(block: suspend (ByteBuffer) -> T): T {
        val buffer = acquireCancellable()
        try {
            return block(buffer)
        } finally {
            release(buffer)
        }
    }
}
