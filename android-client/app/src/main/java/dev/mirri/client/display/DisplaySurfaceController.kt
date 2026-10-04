package dev.mirri.client.display

import android.app.Activity
import android.hardware.display.DisplayManager
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.Display
import android.view.Surface
import dev.mirri.client.protocol.WireException
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.flow.conflate
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withTimeoutOrNull
import kotlin.math.abs
import kotlin.math.roundToInt

/** Only numeric mode/surface facts; safe to show on the tablet or in filtered logcat. */
internal data class ModeDetails(
    val id: Int,
    val width: Int,
    val height: Int,
    val milliHz: Int,
) {
    fun summary(): String = "$id:${width}x$height@$milliHz"
}

internal object ExactModeReadback {
    fun matches(
        requested: ModeDetails,
        observed: ModeDetails,
    ): Boolean =
        requested.id == observed.id &&
            observed.width == 1600 &&
            observed.height == 2456 &&
            abs(observed.milliHz - requested.milliHz) < 10

    /** A real display change, not a number of sleeps, advances each observation. */
    suspend fun awaitMatch(
        changes: Flow<Unit>,
        requested: ModeDetails,
        read: () -> ModeDetails,
        onObserved: (ModeDetails) -> Unit,
    ) {
        changes.first {
            val observed = read()
            onObserved(observed)
            matches(requested, observed)
        }
    }

    fun diagnostic(
        phase: String,
        requested: ModeDetails,
        observed: ModeDetails,
        seen: List<ModeDetails>,
        surfaceWidth: Int,
        surfaceHeight: Int,
        vote: Int,
        rotation: Int,
        attached: Boolean,
        valid: Boolean,
    ): String =
        "$phase mode readback failed req=${requested.summary()} observed=${observed.summary()} " +
            "seen=${seen.take(4).joinToString("/") { it.summary() }} " +
            "vote=$vote surface=${surfaceWidth}x$surfaceHeight rot=$rotation attached=$attached valid=$valid"
}

class DisplaySurfaceController(
    private val activity: Activity,
) {
    private var surface: Surface? = null

    /** Register before the first read, conflate redundant changes, and always
     * unregister after success, timeout or attempt/surface cancellation. */
    private fun DisplayManager.modeChanges(id: Int): Flow<Unit> =
        callbackFlow {
            val listener =
                object : DisplayManager.DisplayListener {
                    override fun onDisplayAdded(displayId: Int) = Unit

                    override fun onDisplayChanged(displayId: Int) {
                        if (displayId == id) trySend(Unit)
                    }

                    override fun onDisplayRemoved(displayId: Int) {
                        if (displayId == id) close(WireException("internal display removed"))
                    }
                }
            registerDisplayListener(listener, Handler(Looper.getMainLooper()))
            trySend(Unit) // A transition may have finished before registration.
            awaitClose { unregisterDisplayListener(listener) }
        }.conflate()

    // A vendor frame-rate policy can list 120 Hz yet refuse it for this app.
    private var highRefreshRefused = false

    suspend fun selectAndVerify(
        surface: Surface,
        phase: String,
        surfaceWidth: Int,
        surfaceHeight: Int,
    ): Display.Mode {
        val manager = activity.getSystemService(DisplayManager::class.java)
        val display = owningDisplay(manager)
        if (display.displayId != Display.DEFAULT_DISPLAY) throw WireException("$phase non-internal display")
        // The stream stays 60 fps. A 120 Hz panel halves the vsync slot, so arrival
        // jitter rarely puts two frames in one refresh; 60 Hz is the fallback.
        val candidates =
            listOfNotNull(
                display.supportedModes.firstOrNull { isExactMode(it, 120f) }.takeUnless { highRefreshRefused },
                display.supportedModes.firstOrNull { isExactMode(it, 60f) },
            )
        if (candidates.isEmpty()) throw WireException("exact 60/120 Hz mode unavailable")
        surface.setFrameRate(60f, Surface.FRAME_RATE_COMPATIBILITY_FIXED_SOURCE)
        for (mode in candidates) {
            val fallbackRemains = mode !== candidates.last()
            val requested = mode.details()
            val params = activity.window.attributes
            params.preferredDisplayModeId = mode.modeId
            activity.window.attributes = params
            val seen = linkedSetOf<ModeDetails>()
            val changes = manager.modeChanges(display.displayId)
            // 5 s fits within the host's 10 s handshake budget while allowing an
            // actual display-policy transition; a refused 120 Hz gets less.
            withTimeoutOrNull(if (fallbackRemains) 2_000 else 5_000) {
                ExactModeReadback.awaitMatch(
                    changes,
                    requested,
                    read = {
                        if (!surface.isValid) throw WireException("$phase surface destroyed")
                        (activity.window.decorView.display ?: activity.display ?: display).mode.details()
                    },
                    onObserved = { if (seen.size < 4) seen += it },
                )
            }
            // Do not trust the event alone: verify the actual owning display at
            // the instant ClientHello/ClientReady can be sent.
            val active = (activity.window.decorView.display ?: activity.display ?: display).mode
            val observed = active.details()
            if (ExactModeReadback.matches(requested, observed)) {
                Log.i(
                    "MirriDisplay",
                    "$phase mode verified req=${requested.summary()} observed=${observed.summary()} " +
                        "surface=${surfaceWidth}x$surfaceHeight",
                )
                this.surface = surface
                return active
            }
            val diagnostic =
                ExactModeReadback.diagnostic(
                    phase,
                    requested,
                    observed,
                    seen.toList(),
                    surfaceWidth,
                    surfaceHeight,
                    activity.window.attributes.preferredDisplayModeId,
                    display.rotation,
                    activity.window.decorView.isAttachedToWindow,
                    surface.isValid,
                )
            Log.w("MirriDisplay", diagnostic)
            if (!fallbackRemains) throw WireException(diagnostic)
            highRefreshRefused = true
        }
        throw WireException("exact 60/120 Hz mode unavailable")
    }

    private fun owningDisplay(manager: DisplayManager): Display =
        activity.window.decorView.display ?: activity.display
            ?: manager.getDisplay(Display.DEFAULT_DISPLAY)
            ?: throw WireException("internal display unavailable")

    private fun isExactMode(
        mode: Display.Mode,
        hz: Float,
    ): Boolean = mode.physicalWidth == 1600 && mode.physicalHeight == 2456 && abs(mode.refreshRate - hz) < 0.01f

    private fun Display.Mode.details() = ModeDetails(modeId, physicalWidth, physicalHeight, (refreshRate * 1000).roundToInt())

    fun detach() {
        try {
            surface?.setFrameRate(0f, Surface.FRAME_RATE_COMPATIBILITY_DEFAULT)
        } catch (
            _: IllegalStateException,
        ) {
            // already destroyed
        }
        surface = null
        val params = activity.window.attributes
        params.preferredDisplayModeId = 0
        activity.window.attributes = params
    }
}
