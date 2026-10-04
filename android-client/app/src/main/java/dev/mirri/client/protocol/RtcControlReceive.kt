package dev.mirri.client.protocol

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.channels.ReceiveChannel
import kotlinx.coroutines.selects.onTimeout
import kotlinx.coroutines.selects.select

/** Select one winner atomically: cancelling a timed receive can consume an undelivered control record. */
@OptIn(ExperimentalCoroutinesApi::class)
internal suspend fun <T> receiveRtcControl(
    channel: ReceiveChannel<T>,
    timeoutMs: Long,
): T? =
    select {
        channel.onReceive { it }
        onTimeout(timeoutMs) { null }
    }
