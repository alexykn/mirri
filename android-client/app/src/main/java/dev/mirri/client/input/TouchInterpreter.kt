package dev.mirri.client.input

import android.view.KeyEvent
import android.view.MotionEvent
import dev.mirri.client.protocol.ContextSource
import dev.mirri.client.protocol.GesturePhase
import dev.mirri.client.protocol.InputEvent
import dev.mirri.client.protocol.InputPoint
import dev.mirri.client.protocol.KeyPhase
import dev.mirri.client.protocol.PointerPhase
import dev.mirri.client.protocol.PointerReading
import dev.mirri.client.protocol.PointerTool
import dev.mirri.client.protocol.ShortcutAction
import kotlin.math.abs
import kotlin.math.hypot

/** Pure gesture state machine for copied samples; never retains a framework MotionEvent. */
class TouchInterpreter(
    private val send: (InputEvent) -> Unit,
) {
    enum class State { IDLE, SINGLE_CANDIDATE, SINGLE_DRAGGING, MULTI_CANDIDATE, SCROLLING, PINCHING, SHORTCUT, PEN_ACTIVE }

    data class Sample(
        val id: Int,
        val x: Float,
        val y: Float,
        val pressure: Float,
        val tilt: Float,
        val orientation: Float,
        val time: Long,
        val tool: PointerTool,
        val buttons: Int,
    )

    var state = State.IDLE
        private set
    private var start = emptyList<Sample>()
    private var last = emptyList<Sample>()
    private var startTime = 0L
    private var cooldownUntil = 0L
    private var scrollPoint = 0f to 0f
    private var distance = 0f
    private var shortcutEmitted = false
    private val slop = 0.012f

    private fun point(s: Sample) = InputPoint(s.x.coerceIn(0f, 1f), s.y.coerceIn(0f, 1f))

    private fun pointer(
        s: Sample,
        phase: PointerPhase,
    ) = PointerReading(
        s.id,
        s.tool,
        phase,
        point(s),
        s.pressure.coerceIn(0f, 1f),
        s.tilt.coerceIn(-1.5707964f, 1.5707964f),
        s.orientation.coerceIn(-3.1415927f, 3.1415927f),
        s.buttons and 7,
        s.time,
    )

    private fun pointers(samples: List<Pair<Sample, PointerPhase>>) {
        if (samples.isNotEmpty()) send(InputEvent.Pointers(samples.map { pointer(it.first, it.second) }))
    }

    private fun gesture(
        scroll: Boolean,
        phase: GesturePhase,
        s: Sample,
        dx: Float,
        dy: Float = 0f,
    ) {
        if (scroll) {
            send(
                InputEvent.Scroll(
                    phase,
                    point(s),
                    dx.coerceIn(-4096f, 4096f),
                    dy.coerceIn(-4096f, 4096f),
                    s.time,
                ),
            )
        } else {
            send(InputEvent.Zoom(phase, point(s), dx.coerceIn(0.25f, 4f), s.time))
        }
    }

    private fun center(s: List<Sample>) = s[0].copy(x = (s[0].x + s[1].x) / 2, y = (s[0].y + s[1].y) / 2)

    private fun span(s: List<Sample>) = hypot(s[1].x - s[0].x, s[1].y - s[0].y)

    fun reset() {
        when (state) {
            State.SINGLE_DRAGGING, State.PEN_ACTIVE -> last.firstOrNull()?.let { pointers(listOf(it to PointerPhase.CANCEL)) }
            State.SCROLLING -> last.firstOrNull()?.let { gesture(true, GesturePhase.CANCELLED, it, 0f) }
            State.PINCHING -> last.firstOrNull()?.let { gesture(false, GesturePhase.CANCELLED, it, 1f) }
            else -> Unit
        }
        state = State.IDLE
        start = emptyList()
        last = emptyList()
        shortcutEmitted = false
    }

    fun handle(
        samples: List<Sample>,
        action: Int,
        time: Long,
    ) {
        if (action == MotionEvent.ACTION_CANCEL || samples.isEmpty()) {
            reset()
            return
        }
        val pen = samples.firstOrNull { it.tool != PointerTool.FINGER }
        if (pen != null) {
            if (action == MotionEvent.ACTION_HOVER_ENTER ||
                action == MotionEvent.ACTION_HOVER_MOVE ||
                action == MotionEvent.ACTION_HOVER_EXIT
            ) {
                return
            }
            if (state != State.PEN_ACTIVE) {
                reset()
                state = State.PEN_ACTIVE
                pointers(listOf(pen to PointerPhase.DOWN))
            } else {
                pointers(listOf(pen to if (action == MotionEvent.ACTION_UP) PointerPhase.UP else PointerPhase.MOVE))
            }
            last = listOf(pen)
            if (action == MotionEvent.ACTION_UP) {
                state = State.IDLE
                cooldownUntil = time + 250_000_000L
            }
            return
        }
        if (state == State.PEN_ACTIVE || time < cooldownUntil) return
        val first = samples[0]
        if (action == MotionEvent.ACTION_DOWN) {
            reset()
            state = State.SINGLE_CANDIDATE
            start = listOf(first)
            last = listOf(first)
            startTime = time
            // Position the pointer without holding a mouse button.
            pointers(listOf(first to PointerPhase.HOVER_ENTER, first to PointerPhase.HOVER_EXIT))
            return
        }
        if (samples.size >= 3) {
            if (state == State.SINGLE_DRAGGING) last.firstOrNull()?.let { pointers(listOf(it to PointerPhase.UP)) }
            if (state != State.SHORTCUT) {
                start = samples
                startTime = time
                state = State.SHORTCUT
                shortcutEmitted = false
            }
            val origin = start.firstOrNull { it.id == first.id } ?: start[0]
            val dx = first.x - origin.x
            val dy = first.y - origin.y
            if (!shortcutEmitted && (abs(dy) > 0.09f || abs(dx) > 0.09f)) {
                val direction =
                    if (abs(dy) >= abs(dx)) {
                        if (dy < 0) ShortcutAction.MISSION_CONTROL else ShortcutAction.SHOW_DESKTOP
                    } else {
                        if (dx < 0) ShortcutAction.PREVIOUS_SPACE else ShortcutAction.NEXT_SPACE
                    }
                send(InputEvent.Shortcut(direction, time))
                shortcutEmitted = true
            }
            last = samples
            return
        }
        if (samples.size == 2 && (state == State.SINGLE_CANDIDATE || state == State.SINGLE_DRAGGING || state == State.IDLE)) {
            if (state == State.SINGLE_DRAGGING) last.firstOrNull()?.let { pointers(listOf(it to PointerPhase.UP)) }
            state = State.MULTI_CANDIDATE
            start = samples
            last = samples
            startTime = time
            distance = span(samples)
            scrollPoint = center(samples).let { it.x to it.y }
            return
        }
        when (state) {
            State.SINGLE_CANDIDATE -> {
                val origin = start[0]
                if (action == MotionEvent.ACTION_UP) {
                    if (hypot(first.x - origin.x, first.y - origin.y) < slop) {
                        if (time - startTime > 550_000_000L) {
                            send(InputEvent.Context(point(first), ContextSource.LONG_PRESS, time))
                        } else {
                            pointers(listOf(origin to PointerPhase.DOWN, first to PointerPhase.UP))
                        }
                    }
                    state = State.IDLE
                } else if (hypot(first.x - origin.x, first.y - origin.y) >= slop) {
                    pointers(listOf(origin to PointerPhase.DOWN, first to PointerPhase.MOVE))
                    state = State.SINGLE_DRAGGING
                }
            }
            State.SINGLE_DRAGGING -> {
                pointers(listOf(first to if (action == MotionEvent.ACTION_UP) PointerPhase.UP else PointerPhase.MOVE))
                if (action == MotionEvent.ACTION_UP) state = State.IDLE
            }
            State.MULTI_CANDIDATE, State.SCROLLING, State.PINCHING -> {
                if (samples.size < 2 || action == MotionEvent.ACTION_UP) {
                    if (state == State.MULTI_CANDIDATE &&
                        time - startTime < 350_000_000L &&
                        last.size == 2
                    ) {
                        send(InputEvent.Context(point(center(last)), ContextSource.TWO_FINGER_TAP, time))
                    }
                    if (state == State.SCROLLING) gesture(true, GesturePhase.ENDED, first, 0f)
                    if (state == State.PINCHING) gesture(false, GesturePhase.ENDED, first, 1f)
                    state = State.IDLE
                } else {
                    val c = center(samples)
                    val span = span(samples)
                    if (state == State.MULTI_CANDIDATE) {
                        val translation = hypot(c.x - scrollPoint.first, c.y - scrollPoint.second)
                        if (abs(span - distance) > slop * 1.5f &&
                            abs(span - distance) > translation
                        ) {
                            state = State.PINCHING
                            gesture(false, GesturePhase.BEGAN, c, 1f)
                        } else if (translation > slop) {
                            state = State.SCROLLING
                            gesture(true, GesturePhase.BEGAN, c, 0f)
                        }
                    }
                    if (state ==
                        State.SCROLLING
                    ) {
                        gesture(
                            true,
                            GesturePhase.CHANGED,
                            c,
                            (c.x - scrollPoint.first) * 2456,
                            (c.y - scrollPoint.second) * 1600,
                        )
                    }
                    if (state == State.PINCHING && distance > 0) gesture(false, GesturePhase.CHANGED, c, span / distance)
                    distance = span
                    scrollPoint = c.x to c.y
                }
            }
            State.SHORTCUT -> if (action == MotionEvent.ACTION_UP) state = State.IDLE
            else -> Unit
        }
        last = samples
    }

    fun auxiliary(event: KeyEvent): Boolean {
        if (event.keyCode != 190 || event.scanCode != 0x7006f) return false
        if (event.action == KeyEvent.ACTION_DOWN || event.action == KeyEvent.ACTION_UP) {
            send(
                InputEvent.Auxiliary(
                    event.keyCode,
                    event.scanCode,
                    if (event.action == KeyEvent.ACTION_DOWN) KeyPhase.DOWN else KeyPhase.UP,
                    event.eventTime * 1_000_000,
                ),
            )
        }
        return true
    }

    fun onMotion(
        event: MotionEvent,
        width: Int,
        height: Int,
    ): Boolean {
        if (width <= 0 || height <= 0) return true

        fun copy(history: Int): List<Sample> =
            (0 until event.pointerCount).map { i ->
                val historical = history >= 0
                val x = if (historical) event.getHistoricalX(i, history) else event.getX(i)
                val y = if (historical) event.getHistoricalY(i, history) else event.getY(i)
                val pressure = if (historical) event.getHistoricalPressure(i, history) else event.getPressure(i)
                val tool =
                    if (event.getToolType(i) ==
                        MotionEvent.TOOL_TYPE_STYLUS
                    ) {
                        PointerTool.PEN
                    } else if (event.getToolType(i) == MotionEvent.TOOL_TYPE_ERASER) {
                        PointerTool.ERASER
                    } else {
                        PointerTool.FINGER
                    }
                val t = if (historical) event.getHistoricalEventTime(history) else event.eventTime
                val tilt =
                    if (historical) {
                        event.getHistoricalAxisValue(
                            MotionEvent.AXIS_TILT,
                            i,
                            history,
                        )
                    } else {
                        event.getAxisValue(MotionEvent.AXIS_TILT, i)
                    }
                val orientation = if (historical) event.getHistoricalOrientation(i, history) else event.getOrientation(i)
                val buttons = (event.buttonState and 3) or (if (event.buttonState and MotionEvent.BUTTON_STYLUS_PRIMARY != 0) 4 else 0)
                Sample(
                    event.getPointerId(i),
                    (x / width).coerceIn(0f, 1f),
                    (y / height).coerceIn(0f, 1f),
                    pressure.coerceIn(0f, 1f),
                    tilt,
                    orientation,
                    t * 1_000_000,
                    tool,
                    buttons,
                )
            }
        if (event.actionMasked ==
            MotionEvent.ACTION_MOVE
        ) {
            for (i in 0 until event.historySize) {
                handle(
                    copy(i),
                    MotionEvent.ACTION_MOVE,
                    event.getHistoricalEventTime(i) * 1_000_000,
                )
            }
        }
        handle(copy(-1), event.actionMasked, event.eventTime * 1_000_000)
        return true
    }
}
