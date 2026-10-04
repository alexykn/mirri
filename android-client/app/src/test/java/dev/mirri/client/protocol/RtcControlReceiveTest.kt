package dev.mirri.client.protocol

import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class RtcControlReceiveTest {
    @Test
    fun readyRecordWinsEvenAnImmediatelyReadyTimeoutWithoutBeingUndelivered() =
        runBlocking {
            val undelivered = mutableListOf<Int>()
            val channel = Channel<Int>(2, onUndeliveredElement = undelivered::add)
            channel.send(11)
            // No wall-clock sleep: both selection clauses can complete immediately.
            assertEquals(11, receiveRtcControl(channel, 0))
            assertEquals(emptyList<Int>(), undelivered)
            assertNull(receiveRtcControl(channel, 0))
            channel.send(12)
            assertEquals(12, receiveRtcControl(channel, 0))
            assertEquals(emptyList<Int>(), undelivered)
        }
}
