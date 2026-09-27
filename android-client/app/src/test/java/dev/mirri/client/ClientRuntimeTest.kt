package dev.mirri.client

import dev.mirri.client.display.ExactModeReadback
import dev.mirri.client.display.ModeDetails
import dev.mirri.client.input.TouchInterpreter
import dev.mirri.client.protocol.ContextSource
import dev.mirri.client.protocol.GesturePhase
import dev.mirri.client.protocol.InputEvent
import dev.mirri.client.protocol.PointerTool
import dev.mirri.client.session.ClientLaunchBoundary
import dev.mirri.client.session.ReconnectPolicy
import dev.mirri.client.video.DecoderChoice
import dev.mirri.client.video.DecoderFrameAges
import dev.mirri.client.video.DecoderInputIndices
import dev.mirri.client.video.DecoderOutputReadback
import dev.mirri.client.video.EncodedBufferPool
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withTimeoutOrNull
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

class ClientRuntimeTest {
    @Test fun launchBoundaryProducesOnlyValidatedLoopbackCredentials() {
        val token = "ab".repeat(32)
        val launch = ClientLaunchBoundary.validated(token, 7, 5561, 5560, 1) ?: error("valid launch rejected")
        assertEquals(7u, launch.epoch)
        assertEquals(5561, launch.endpoint.controlPort)
        assertEquals(5560, launch.endpoint.videoPort)
        assertTrue(launch.token.all { it == 0xab.toByte() })
        assertEquals(null, ClientLaunchBoundary.validated(token.uppercase(), 7, 5561, 5560, 1))
        assertEquals(null, ClientLaunchBoundary.validated(token, 0, 5561, 5560, 1))
        assertEquals(null, ClientLaunchBoundary.validated(token, 7, 5561, 5560, 2))
        assertEquals(null, ClientLaunchBoundary.validated(token, 7, 5562, 5560, 1))
        assertEquals(null, ClientLaunchBoundary.validated(token, 7, 5561, 5562, 1))
    }

    @Test fun displayOwnerWaitsForRealExactTransitionAndCancelsListenerOnTimeout() =
        runBlocking {
            val requested = ModeDetails(1, 1600, 2456, 60000)
            val at90 = ModeDetails(2, 1600, 2456, 90000)
            val at60 = ModeDetails(1, 1600, 2456, 60000)
            var current = at90
            val seen = mutableListOf<ModeDetails>()
            ExactModeReadback.awaitMatch(
                flow {
                    emit(Unit)
                    current = at60
                    emit(Unit)
                },
                requested,
                { current },
                seen::add,
            )
            assertEquals(listOf(at90, at60), seen)

            val unregistered = AtomicBoolean()
            val neverExact =
                callbackFlow {
                    trySend(Unit)
                    awaitClose { unregistered.set(true) }
                }
            current = at90
            assertEquals(
                null,
                withTimeoutOrNull(120) {
                    ExactModeReadback.awaitMatch(neverExact, requested, { current }, seen::add)
                },
            )
            assertTrue(unregistered.get())
        }

    @Test fun actualDisplayOwnerReportsPhaseAndRequestedVsObservedWithoutWeakeningExactMode() {
        val requested = ModeDetails(1, 1600, 2456, 60000)
        val active60 = ModeDetails(1, 1600, 2456, 60000)
        val active90 = ModeDetails(2, 1600, 2456, 90000)
        assertTrue(ExactModeReadback.matches(requested, active60))
        assertFalse(ExactModeReadback.matches(requested, active90))
        assertFalse(ExactModeReadback.matches(requested, ModeDetails(2, 1600, 2456, 60000)))
        assertFalse(ExactModeReadback.matches(requested, ModeDetails(1, 2456, 1600, 60000)))
        val message =
            ExactModeReadback.diagnostic(
                "pre-hello",
                requested,
                active90,
                listOf(active90),
                2456,
                1600,
                vote = 1,
                rotation = 1,
                attached = true,
                valid = true,
            )
        assertTrue(message.contains("pre-hello mode readback failed"))
        assertTrue(message.contains("req=1:1600x2456@60000 observed=2:1600x2456@90000"))
        assertTrue(message.contains("surface=2456x1600"))
        assertTrue(message.length < 256)
    }

    @Test fun pendingCodecIndexReceiveCancelsAndCloseWakesWaiter() =
        runBlocking {
            val indices = DecoderInputIndices()
            val canceled = async(Dispatchers.IO) { indices.receive() }
            delay(25)
            withTimeout(1500) { canceled.cancelAndJoin() }
            assertTrue(indices.offer(3))
            assertEquals(3, indices.receive()) // Cancellation did not consume a future lease.
            val waiting = async(Dispatchers.IO) { runCatching { indices.receive() } }
            delay(25)
            indices.close()
            assertTrue(withTimeout(1500) { waiting.await().isFailure })
            assertFalse(indices.offer(4))
        }

    @Test fun cancellationAfterIndexDeliveryRestoresFrameworkLease() =
        runBlocking {
            val indices = DecoderInputIndices()
            val executor = Executors.newSingleThreadExecutor()
            val dispatcher = executor.asCoroutineDispatcher()
            val unblock = CountDownLatch(1)
            val workerEntered = CountDownLatch(1)
            try {
                val waiting = async(dispatcher, start = CoroutineStart.UNDISPATCHED) { indices.receive() }
                executor.execute {
                    workerEntered.countDown()
                    unblock.await(1, TimeUnit.SECONDS)
                }
                assertTrue(workerEntered.await(1, TimeUnit.SECONDS))
                assertTrue(indices.offer(17)) // Receive removed it; dispatch is blocked.
                waiting.cancel()
                unblock.countDown()
                withTimeout(1500) { waiting.cancelAndJoin() }
                assertEquals(17, withTimeout(1500) { indices.receive() })
            } finally {
                unblock.countDown()
                indices.close()
                dispatcher.close()
            }
        }

    @Test fun exactDecoderSelectionDoesNotRequireOptionalLowLatency() {
        val choice = DecoderChoice("hardware", 1, 1, 51, lowLatency = false)
        assertTrue(choice.matches(1, 1, 51))
        assertFalse(choice.matches(2, 1, 51))
        assertFalse(choice.matches(1, 1, 50))
    }

    @Test fun pooledFrameReturnsAfterCancellationAndFailure() =
        runBlocking {
            val pool = EncodedBufferPool(count = 1, size = 64)
            for (failure in listOf(CancellationException("cancel"), IllegalStateException("codec"))) {
                try {
                    pool.withLease<Unit> { buffer ->
                        assertEquals(0, pool.available)
                        buffer.put(1)
                        throw failure
                    }
                    throw AssertionError("expected lease failure")
                } catch (e: Exception) {
                    assertEquals(failure, e)
                }
                assertEquals(1, pool.available)
            }
            val held = pool.acquire()
            val waiting = async(Dispatchers.IO) { pool.withLease { it.put(1) } }
            delay(75)
            waiting.cancelAndJoin()
            pool.release(held)
            assertEquals(1, pool.available)
        }

    private fun s(
        id: Int,
        x: Float,
        y: Float,
        time: Long = 1000L,
    ) = TouchInterpreter.Sample(id, x, y, 0.5f, 0f, 0f, time, PointerTool.FINGER, 0)

    private fun phases(messages: List<InputEvent>): List<Int> =
        messages.filterIsInstance<InputEvent.Pointers>().flatMap { batch -> batch.samples.map { it.phase.wire } }

    @Test fun tapAndDrag() {
        val out = mutableListOf<InputEvent>()
        val interpreter = TouchInterpreter(out::add)
        interpreter.handle(listOf(s(0, 0.2f, 0.2f)), 0, 1000)
        interpreter.handle(listOf(s(0, 0.2f, 0.2f, 2000)), 1, 2000)
        assertEquals(listOf(1, 3, 4, 6), phases(out))
        out.clear()
        interpreter.handle(listOf(s(0, 0.2f, 0.2f)), 0, 1000)
        interpreter.handle(listOf(s(0, 0.4f, 0.2f, 3000)), 2, 3000)
        interpreter.handle(listOf(s(0, 0.5f, 0.2f, 4000)), 1, 4000)
        assertEquals(listOf(1, 3, 4, 5, 6), phases(out))
    }

    @Test fun accessibilityClickEmitsOneCenteredTap() {
        val out = mutableListOf<InputEvent>()
        TouchInterpreter(out::add).accessibilityClick()
        assertEquals(listOf(1, 3, 4, 6), phases(out))
        val samples = out.filterIsInstance<InputEvent.Pointers>().flatMap { it.samples }
        assertTrue(samples.all { it.point.x == 0.5f && it.point.y == 0.5f })
    }

    @Test fun secondFingerReleasesDragAndNoPhantomTap() {
        val out = mutableListOf<InputEvent>()
        val interpreter = TouchInterpreter(out::add)
        interpreter.handle(listOf(s(0, 0.2f, 0.2f)), 0, 1000)
        interpreter.handle(listOf(s(0, 0.4f, 0.2f)), 2, 2000)
        interpreter.handle(listOf(s(0, 0.4f, 0.2f), s(1, 0.6f, 0.2f)), 5, 3000)
        assertEquals(TouchInterpreter.State.MULTI_CANDIDATE, interpreter.state)
        assertEquals(6, phases(out).last())
        interpreter.reset()
        assertEquals(TouchInterpreter.State.IDLE, interpreter.state)
    }

    @Test fun pinchCommitsAndCancelEnds() {
        val out = mutableListOf<InputEvent>()
        val interpreter = TouchInterpreter(out::add)
        interpreter.handle(listOf(s(0, 0.2f, 0.2f)), 0, 1000)
        interpreter.handle(listOf(s(0, 0.2f, 0.2f), s(1, 0.4f, 0.2f)), 5, 2000)
        interpreter.handle(listOf(s(0, 0.1f, 0.2f), s(1, 0.5f, 0.2f)), 2, 3000)
        assertEquals(TouchInterpreter.State.PINCHING, interpreter.state)
        interpreter.handle(listOf(s(0, 0.1f, 0.2f)), 3, 4000)
        assertEquals(TouchInterpreter.State.IDLE, interpreter.state)
        assertTrue(out.any { it is InputEvent.Zoom && it.phase == GesturePhase.CANCELLED })
    }

    @Test fun scrollDoesNotSwitchToPinch() {
        val out = mutableListOf<InputEvent>()
        val interpreter = TouchInterpreter(out::add)
        interpreter.handle(listOf(s(0, 0.2f, 0.2f)), 0, 1000)
        interpreter.handle(listOf(s(0, 0.2f, 0.2f), s(1, 0.4f, 0.2f)), 5, 2000)
        interpreter.handle(listOf(s(0, 0.2f, 0.3f), s(1, 0.4f, 0.3f)), 2, 3000)
        interpreter.handle(listOf(s(0, 0.1f, 0.3f), s(1, 0.5f, 0.3f)), 2, 4000)
        assertEquals(TouchInterpreter.State.SCROLLING, interpreter.state)
        assertTrue(out.any { it is InputEvent.Scroll })
        assertFalse(out.any { it is InputEvent.Zoom })
    }

    @Test fun penPrecedenceCooldownAndLongPress() {
        val out = mutableListOf<InputEvent>()
        val interpreter = TouchInterpreter(out::add)
        val pen = s(7, 0.5f, 0.5f, 1000).copy(tool = PointerTool.PEN)
        interpreter.handle(listOf(pen), 0, 1000)
        assertEquals(TouchInterpreter.State.PEN_ACTIVE, interpreter.state)
        interpreter.handle(listOf(s(0, 0.2f, 0.2f)), 0, 2000)
        interpreter.handle(listOf(pen.copy(time = 3000)), 1, 3000)
        val count = out.size
        interpreter.handle(listOf(s(0, 0.2f, 0.2f)), 0, 4000)
        assertEquals(count, out.size)
        interpreter.handle(listOf(s(0, 0.2f, 0.2f, 300_000_000)), 0, 300_000_000)
        interpreter.handle(listOf(s(0, 0.2f, 0.2f, 900_000_000)), 1, 900_000_000)
        assertTrue(out.any { it is InputEvent.Context && it.source == ContextSource.LONG_PRESS })
    }

    @Test fun multiFingerShortcutEmitsOnlyOnce() {
        val out = mutableListOf<InputEvent>()
        val interpreter = TouchInterpreter(out::add)
        interpreter.handle(listOf(s(0, 0.2f, 0.6f), s(1, 0.4f, 0.6f), s(2, 0.6f, 0.6f)), 5, 1000)
        interpreter.handle(listOf(s(0, 0.2f, 0.4f), s(1, 0.4f, 0.4f), s(2, 0.6f, 0.4f)), 2, 2000)
        interpreter.handle(listOf(s(0, 0.2f, 0.2f), s(1, 0.4f, 0.2f), s(2, 0.6f, 0.2f)), 2, 3000)
        assertEquals(1, out.count { it is InputEvent.Shortcut })
    }

    @Test fun resourcesAndBackoffAreBounded() {
        val pool = EncodedBufferPool(2, 32)
        val lease = pool.acquire()
        assertEquals(1, pool.available)
        pool.release(lease)
        assertEquals(2, pool.available)
        assertEquals(250, ReconnectPolicy.delayMs(0))
        assertEquals(8000, ReconnectPolicy.delayMs(100))
        assertFalse(lease.hasRemaining().not())
    }

    @Test fun decoderOutputRequiresExactVisibleCropWithinCodedBuffer() {
        val exact = DecoderOutputReadback::isExactVisibleFrame
        assertTrue(exact(2456, 1600, null, null, null, null))
        assertTrue(exact(2464, 1600, 0, 0, 2455, 1599))
        assertFalse(exact(2464, 1600, null, null, null, null))
        assertFalse(exact(2464, 1600, 0, null, 2455, 1599))
        assertFalse(exact(2464, 1600, 0, 0, 2463, 1599))
        assertFalse(exact(2456, 1600, 1, 0, 2455, 1599))
        assertFalse(exact(2456, 1600, -1, 0, 2454, 1599))
        assertFalse(exact(2464, 1600, 9, 0, 2464, 1599))
    }

    @Test fun decoderFrameAgeMatchesPtsWithinDeviceClockAndBoundsOutstanding() {
        val ages = DecoderFrameAges(capacity = 2)
        ages.submitted(1, 1_000_000)
        ages.submitted(2, 2_000_000)
        ages.submitted(3, 3_000_000)
        ages.released(1, 4_000_000) // Evicted and never misattributes to another PTS.
        ages.released(3, 9_000_000)
        ages.released(2, 4_000_000)
        val first = ages.drain()
        assertEquals(2, first.samples)
        assertEquals(1, first.evicted)
        assertEquals(6.0, first.p95Ms, 0.001)
        ages.submitted(4, 5_000_000)
        ages.released(4, 8_000_000)
        val summary = ages.drain()
        assertEquals(1, summary.samples)
        assertEquals(3.0, summary.medianMs, 0.001)
        assertEquals(3.0, summary.p95Ms, 0.001)
        assertEquals(0, summary.evicted)
        assertEquals(0, ages.drain().samples)
    }
}
