package dev.mirri.client.protocol

import dev.mirri.client.transport.ByteConnection
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** Fixed-size control preface after TLS identity verification; no Mirri frame is consumed. */
object NetworkBootstrap {
    fun exchange(
        bytes: ByteConnection,
        token: ByteArray,
    ): UInt {
        if (token.size != 32) throw WireException("invalid network token")
        val request = ByteBuffer.allocate(40).order(ByteOrder.BIG_ENDIAN)
        request
            .putInt(0x4d524e42)
            .putShort(1)
            .putShort(1)
            .put(token)
            .flip()
        bytes.writeFully(request)
        val response = ByteBuffer.allocate(12).order(ByteOrder.BIG_ENDIAN)
        // EOF or interrupted TLS is a transport loss; only an explicit status
        // authenticates rejection. The session owner will retry within grace.
        bytes.readFully(response)
        response.flip()
        if (response.int != 0x4d524e42 || response.short.toInt() != 1) throw WireException("invalid network bootstrap response")
        val status = response.short.toInt()
        val epoch = response.int.toUInt()
        if (status == 1 && epoch == 0u) throw WireException("network bootstrap token rejected")
        if (status != 0 || epoch == 0u) throw WireException("invalid network bootstrap response")
        return epoch
    }
}
