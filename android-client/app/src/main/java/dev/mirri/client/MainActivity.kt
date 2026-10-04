package dev.mirri.client

import android.graphics.Color
import android.os.Bundle
import android.util.Log
import android.view.Gravity
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import android.view.ViewConfiguration
import android.widget.FrameLayout
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import dev.mirri.client.input.TouchInterpreter
import dev.mirri.client.pairing.PairingRevoked
import dev.mirri.client.pairing.PairingStore
import dev.mirri.client.pairing.RendezvousClient
import dev.mirri.client.pairing.RendezvousWire
import dev.mirri.client.session.ClientLaunchBoundary
import dev.mirri.client.session.ClientSessionState
import dev.mirri.client.session.NetworkMedia
import dev.mirri.client.session.SessionController
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.launch
import org.webrtc.SurfaceViewRenderer

/** Immersive, landscape-only SurfaceView; no codec or socket work runs on the UI thread. */
class MainActivity : ComponentActivity() {
    private lateinit var controller: SessionController
    private lateinit var input: TouchInterpreter
    private lateinit var status: TextView
    private lateinit var pairingStore: PairingStore

    /** Why this tablet is waiting for its paired host, or null while a launch owns the activity. */
    private val waitReason = MutableStateFlow<Int?>(null)
    private var sessionSeen = false

    /** Held only while streaming: keeps the Wi-Fi radio out of power save, whose wake-ups arrive as delay spikes. */
    private val wifiLock by lazy {
        applicationContext
            .getSystemService(android.net.wifi.WifiManager::class.java)
            .createWifiLock(android.net.wifi.WifiManager.WIFI_MODE_FULL_LOW_LATENCY, "mirri:stream")
            .apply { setReferenceCounted(false) }
    }

    @Suppress("CyclomaticComplexMethod")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        // Preserve the full-window SurfaceView while swipe-revealed system bars remain transient.
        WindowCompat.setDecorFitsSystemWindows(window, false)
        WindowCompat.getInsetsController(window, window.decorView).apply {
            systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            hide(WindowInsetsCompat.Type.systemBars())
        }
        status =
            TextView(this).apply {
                setTextColor(Color.WHITE)
                setBackgroundColor(0x88000000.toInt())
                textSize = 15f
                setPadding(20, 12, 20, 12)
            }
        controller = SessionController(this)
        lifecycleScope.launch {
            repeatOnLifecycle(Lifecycle.State.STARTED) {
                controller.status.collect { snapshot ->
                    status.text = getString(R.string.session_status, snapshot.state, snapshot.note)
                    status.visibility =
                        if (snapshot.state == ClientSessionState.STREAMING) View.GONE else View.VISIBLE
                    holdWifi(snapshot.state == ClientSessionState.STREAMING)
                    // A finished session hands the tablet back to its paired host:
                    // a failure asks to resume, a host Stop only waits.
                    when (snapshot.state) {
                        ClientSessionState.FAILED -> if (sessionSeen) waitReason.value = RendezvousWire.REASON_RECOVERING
                        ClientSessionState.IDLE -> if (sessionSeen) waitReason.value = RendezvousWire.REASON_IDLE
                        else -> {
                            sessionSeen = true
                            waitReason.value = null
                        }
                    }
                }
            }
        }
        input = TouchInterpreter(controller::onInput)
        val launch = ClientLaunchBoundary.decode(intent)
        pairingStore = PairingStore(this)
        ClientLaunchBoundary.pairing(intent)?.let(pairingStore::save)
        controller.pairedHost = pairingStore.load() != null
        lifecycleScope.launch {
            repeatOnLifecycle(Lifecycle.State.STARTED) {
                waitReason.filterNotNull().collectLatest { reason -> waitForHost(reason) }
            }
        }
        val surface =
            object : SurfaceView(this) {
                private val touchSlop = ViewConfiguration.get(context).scaledTouchSlop
                private var tapCandidate = false
                private var downX = 0f
                private var downY = 0f
                private var touchClick = false

                override fun onTouchEvent(event: MotionEvent): Boolean {
                    when (event.actionMasked) {
                        MotionEvent.ACTION_DOWN -> {
                            tapCandidate = true
                            downX = event.x
                            downY = event.y
                        }
                        MotionEvent.ACTION_MOVE -> {
                            val moved = kotlin.math.hypot(event.x - downX, event.y - downY) > touchSlop
                            if (event.pointerCount != 1 || moved) tapCandidate = false
                        }
                        MotionEvent.ACTION_POINTER_DOWN, MotionEvent.ACTION_CANCEL -> tapCandidate = false
                    }
                    val handled = input.onMotion(event, width, height)
                    if (event.actionMasked == MotionEvent.ACTION_UP && tapCandidate) {
                        tapCandidate = false
                        touchClick = true
                        try {
                            performClick()
                        } finally {
                            touchClick = false
                        }
                    }
                    return handled
                }

                override fun performClick(): Boolean {
                    super.performClick()
                    if (!touchClick) input.accessibilityClick()
                    return true
                }
            }.apply {
                holder.addCallback(
                    object : SurfaceHolder.Callback {
                        override fun surfaceCreated(holder: SurfaceHolder) = Unit

                        override fun surfaceChanged(
                            holder: SurfaceHolder,
                            format: Int,
                            width: Int,
                            height: Int,
                        ) {
                            Log.i("MirriLifecycle", "surfaceChanged ${width}x$height valid=${holder.surface.isValid}")
                            controller.onSurfaceAvailable(holder.surface, width, height)
                        }

                        override fun surfaceDestroyed(holder: SurfaceHolder) {
                            Log.i("MirriLifecycle", "surfaceDestroyed")
                            input.reset()
                            controller.onSurfaceDestroyed()
                        }
                    },
                )
            }
        val mediaSurface: SurfaceView =
            if (launch?.media == NetworkMedia.RTC) {
                object : SurfaceViewRenderer(this) {
                    var touchClick = false
                    var downX = 0f
                    var downY = 0f
                    var tap = false

                    override fun onTouchEvent(event: MotionEvent): Boolean {
                        when (event.actionMasked) {
                            MotionEvent.ACTION_DOWN -> {
                                tap = true
                                downX = event.x
                                downY = event.y
                            }
                            MotionEvent.ACTION_MOVE ->
                                if (event.pointerCount != 1 ||
                                    kotlin.math.hypot(event.x - downX, event.y - downY) > ViewConfiguration.get(context).scaledTouchSlop
                                ) {
                                    tap = false
                                }
                            MotionEvent.ACTION_POINTER_DOWN, MotionEvent.ACTION_CANCEL -> tap = false
                        }
                        val handled = input.onMotion(event, width, height)
                        if (event.actionMasked == MotionEvent.ACTION_UP && tap) {
                            tap = false
                            touchClick = true
                            try {
                                performClick()
                            } finally {
                                touchClick = false
                            }
                        }
                        return handled
                    }

                    override fun performClick(): Boolean {
                        super.performClick()
                        if (!touchClick) input.accessibilityClick()
                        return true
                    }
                }.also { renderer ->
                    controller.setRtcRenderer(renderer)
                    renderer.isClickable = true
                    renderer.holder.addCallback(
                        object : SurfaceHolder.Callback {
                            override fun surfaceCreated(holder: SurfaceHolder) = Unit

                            override fun surfaceChanged(
                                holder: SurfaceHolder,
                                format: Int,
                                width: Int,
                                height: Int,
                            ) {
                                controller.onSurfaceAvailable(holder.surface, width, height)
                            }

                            override fun surfaceDestroyed(holder: SurfaceHolder) {
                                input.reset()
                                controller.onSurfaceDestroyed()
                            }
                        },
                    )
                }
            } else {
                surface
            }
        val view =
            FrameLayout(this).apply {
                addView(mediaSurface, FrameLayout.LayoutParams(-1, -1))
                addView(status, FrameLayout.LayoutParams(-2, -2, Gravity.TOP or Gravity.START))
            }
        setContentView(view)
        if (launch == null) {
            Log.i("MirriLifecycle", "no host launch; waiting for a paired host")
            status.setText(R.string.launch_from_host)
            waitReason.value = RendezvousWire.REASON_OPENED
        } else {
            Log.i("MirriLifecycle", "launch accepted surfacePending=true")
            controller.start(launch)
        }
    }

    /** Hold the authenticated rendezvous open until the host starts a session, then run it like a cable launch. */
    private suspend fun waitForHost(reason: Int) {
        if (pairingStore.load() == null) {
            status.setText(R.string.launch_from_host)
            status.visibility = View.VISIBLE
            return
        }
        status.setText(R.string.waiting_for_paired_host)
        status.visibility = View.VISIBLE
        try {
            val launch = RendezvousClient(this, pairingStore).awaitLaunch(reason)
            Log.i("MirriLifecycle", "paired host launch; recreating owned activity")
            waitReason.value = null
            setIntent(launch.extras(android.content.Intent(this, MainActivity::class.java)))
            recreate()
        } catch (_: PairingRevoked) {
            waitReason.value = null
            status.setText(R.string.launch_from_host)
        }
    }

    /** Some vendors refuse the lock even with WAKE_LOCK granted; streaming works without it. */
    private fun holdWifi(streaming: Boolean) {
        try {
            if (streaming) {
                wifiLock.acquire()
            } else if (wifiLock.isHeld) {
                wifiLock.release()
            }
        } catch (e: SecurityException) {
            Log.i("MirriLifecycle", "low-latency Wi-Fi lock unavailable")
        }
    }

    override fun onStart() {
        super.onStart()
        // Coming back to the app is a person asking for the display again.
        if (waitReason.value == RendezvousWire.REASON_IDLE) waitReason.value = RendezvousWire.REASON_OPENED
    }

    override fun onNewIntent(intent: android.content.Intent) {
        super.onNewIntent(intent)
        Log.i("MirriLifecycle", "new host launch intent; recreating owned activity")
        setIntent(intent)
        recreate()
    }

    override fun onKeyDown(
        keyCode: Int,
        event: KeyEvent,
    ): Boolean = input.auxiliary(event) || super.onKeyDown(keyCode, event)

    override fun onKeyUp(
        keyCode: Int,
        event: KeyEvent,
    ): Boolean = input.auxiliary(event) || super.onKeyUp(keyCode, event)

    override fun onTouchEvent(event: MotionEvent): Boolean = input.onMotion(event, window.decorView.width, window.decorView.height)

    override fun onDestroy() {
        Log.i("MirriLifecycle", "activity destroyed")
        input.reset()
        holdWifi(false)
        controller.stop()
        super.onDestroy()
    }
}
