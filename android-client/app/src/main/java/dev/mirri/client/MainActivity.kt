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
import dev.mirri.client.session.ClientLaunchBoundary
import dev.mirri.client.session.ClientSessionState
import dev.mirri.client.session.SessionController
import kotlinx.coroutines.launch

/** Immersive, landscape-only SurfaceView; no codec or socket work runs on the UI thread. */
class MainActivity : ComponentActivity() {
    private lateinit var controller: SessionController
    private lateinit var input: TouchInterpreter
    private lateinit var status: TextView

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
                }
            }
        }
        input = TouchInterpreter(controller::onInput)
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
        val view =
            FrameLayout(this).apply {
                addView(surface, FrameLayout.LayoutParams(-1, -1))
                addView(status, FrameLayout.LayoutParams(-2, -2, Gravity.TOP or Gravity.START))
            }
        setContentView(view)
        val launch = ClientLaunchBoundary.decode(intent)
        if (launch == null) {
            Log.w("MirriLifecycle", "launch rejected (invalid extras)")
            status.setText(R.string.launch_from_host)
        } else {
            Log.i("MirriLifecycle", "launch accepted surfacePending=true")
            controller.start(launch)
        }
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
        controller.stop()
        super.onDestroy()
    }
}
