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
import android.widget.FrameLayout
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import dev.mirri.client.input.TouchInterpreter
import dev.mirri.client.session.ClientLaunch
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
        window.decorView.systemUiVisibility =
            View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY or View.SYSTEM_UI_FLAG_FULLSCREEN or View.SYSTEM_UI_FLAG_HIDE_NAVIGATION or
            View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN or
            View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION or
            View.SYSTEM_UI_FLAG_LAYOUT_STABLE
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
                    status.text = "Mirri: ${snapshot.state}\n${snapshot.note}"
                    status.visibility =
                        if (snapshot.state == ClientSessionState.STREAMING) View.GONE else View.VISIBLE
                }
            }
        }
        input = TouchInterpreter(controller::onInput)
        val surface =
            SurfaceView(this).apply {
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
                setOnTouchListener { v, event -> input.onMotion(event, v.width, v.height) }
            }
        val view =
            FrameLayout(this).apply {
                addView(surface, FrameLayout.LayoutParams(-1, -1))
                addView(status, FrameLayout.LayoutParams(-2, -2, Gravity.TOP or Gravity.START))
            }
        setContentView(view)
        val token = intent.getStringExtra("mirri_token")
        val epoch = intent.getIntExtra("mirri_epoch", 0)
        val control = intent.getIntExtra("mirri_control_port", 0)
        val video = intent.getIntExtra("mirri_video_port", 0)
        if (token == null ||
            !token.matches(Regex("[0-9a-f]{64}")) ||
            epoch <= 0 ||
            control != 5561 ||
            video != 5560 ||
            intent.getIntExtra("mirri_protocol_major", 0) != 1
        ) {
            Log.w("MirriLifecycle", "launch rejected (invalid extras)")
            status.text = "Mirri: launch from the Mac host over USB"
        } else {
            Log.i("MirriLifecycle", "launch accepted surfacePending=true")
            val bytes = ByteArray(32) { token.substring(it * 2, it * 2 + 2).toInt(16).toByte() }
            controller.start(ClientLaunch(bytes, epoch.toUInt(), control, video))
        }
    }

    override fun onNewIntent(intent: android.content.Intent) {
        super.onNewIntent(intent)
        Log.i("MirriLifecycle", "new host launch intent; recreating owned activity")
        setIntent(intent)
        recreate()
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean = input.auxiliary(event) || super.dispatchKeyEvent(event)

    override fun onTouchEvent(event: MotionEvent): Boolean = input.onMotion(event, window.decorView.width, window.decorView.height)

    override fun onDestroy() {
        Log.i("MirriLifecycle", "activity destroyed")
        input.reset()
        controller.stop()
        super.onDestroy()
    }
}
