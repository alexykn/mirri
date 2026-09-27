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

    /** An accessibility-service click has no MotionEvent; use the center of the visible surface. */
    fun accessibilityClick() {
        val now = System.nanoTime()
        val sample = Sample(0, 0.5f, 0.5f, 0.5f, 0f, 0f, now, PointerTool.FINGER, 0)
        reset()
        handle(listOf(sample), MotionEvent.ACTION_DOWN, now)
        handle(listOf(sample), MotionEvent.ACTION_UP, now)
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
            handlePen(pen, action, time)
            return
        }
        if (state == State.PEN_ACTIVE || time < cooldownUntil) return
        val first = samples[0]
        if (action == MotionEvent.ACTION_DOWN) {
            beginSingle(first, time)
            return
        }
        if (samples.size >= 3) {
            handleShortcut(samples, first, time)
            return
        }
        if (samples.size == 2 && canBeginMulti()) {
            beginMulti(samples, time)
            return
        }
        handleCurrent(samples, first, action, time)
        last = samples
    }

    private fun canBeginMulti(): Boolean =
        when (state) {
            State.SINGLE_CANDIDATE, State.SINGLE_DRAGGING, State.IDLE -> true
            else -> false
        }

    private fun isHover(action: Int): Boolean =
        when (action) {
            MotionEvent.ACTION_HOVER_ENTER, MotionEvent.ACTION_HOVER_MOVE, MotionEvent.ACTION_HOVER_EXIT -> true
            else -> false
        }

    private fun handleCurrent(
        samples: List<Sample>,
        first: Sample,
        action: Int,
        time: Long,
    ) {
        when (state) {
            State.SINGLE_CANDIDATE -> handleSingle(first, action, time)
            State.SINGLE_DRAGGING -> {
                pointers(listOf(first to if (action == MotionEvent.ACTION_UP) PointerPhase.UP else PointerPhase.MOVE))
                if (action == MotionEvent.ACTION_UP) state = State.IDLE
            }
            State.MULTI_CANDIDATE, State.SCROLLING, State.PINCHING -> handleMulti(samples, first, action, time)
            State.SHORTCUT -> if (action == MotionEvent.ACTION_UP) state = State.IDLE
            else -> Unit
        }
    }

    private fun handlePen(
        pen: Sample,
        action: Int,
        time: Long,
    ) {
        if (isHover(action)) return
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
    }

    private fun beginSingle(
        first: Sample,
        time: Long,
    ) {
        reset()
        state = State.SINGLE_CANDIDATE
        start = listOf(first)
        last = listOf(first)
        startTime = time
        pointers(listOf(first to PointerPhase.HOVER_ENTER, first to PointerPhase.HOVER_EXIT))
    }

    private fun handleShortcut(
        samples: List<Sample>,
        first: Sample,
        time: Long,
    ) {
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
    }

    private fun beginMulti(
        samples: List<Sample>,
        time: Long,
    ) {
        if (state == State.SINGLE_DRAGGING) last.firstOrNull()?.let { pointers(listOf(it to PointerPhase.UP)) }
        state = State.MULTI_CANDIDATE
        start = samples
        last = samples
        startTime = time
        distance = span(samples)
        scrollPoint = center(samples).let { it.x to it.y }
    }

    private fun handleSingle(
        first: Sample,
        action: Int,
        time: Long,
    ) {
        val origin = start[0]
        val moved = hypot(first.x - origin.x, first.y - origin.y) >= slop
        if (action == MotionEvent.ACTION_UP) {
            if (!moved) {
                if (time - startTime > 550_000_000L) {
                    send(InputEvent.Context(point(first), ContextSource.LONG_PRESS, time))
                } else {
                    pointers(listOf(origin to PointerPhase.DOWN, first to PointerPhase.UP))
                }
            }
            state = State.IDLE
        } else if (moved) {
            pointers(listOf(origin to PointerPhase.DOWN, first to PointerPhase.MOVE))
            state = State.SINGLE_DRAGGING
        }
    }

    private fun handleMulti(
        samples: List<Sample>,
        first: Sample,
        action: Int,
        time: Long,
    ) {
        if (samples.size < 2 || action == MotionEvent.ACTION_UP) {
            endMulti(first, time)
            return
        }
        val c = center(samples)
        val nextSpan = span(samples)
        if (state == State.MULTI_CANDIDATE) beginGesture(c, nextSpan)
        if (state == State.SCROLLING) {
            gesture(true, GesturePhase.CHANGED, c, (c.x - scrollPoint.first) * 2456, (c.y - scrollPoint.second) * 1600)
        }
        if (state == State.PINCHING && distance > 0) gesture(false, GesturePhase.CHANGED, c, nextSpan / distance)
        distance = nextSpan
        scrollPoint = c.x to c.y
    }

    private fun endMulti(
        first: Sample,
        time: Long,
    ) {
        if (state == State.MULTI_CANDIDATE && time - startTime < 350_000_000L && last.size == 2) {
            send(InputEvent.Context(point(center(last)), ContextSource.TWO_FINGER_TAP, time))
        }
        if (state == State.SCROLLING) gesture(true, GesturePhase.ENDED, first, 0f)
        if (state == State.PINCHING) gesture(false, GesturePhase.ENDED, first, 1f)
        state = State.IDLE
    }

    private fun beginGesture(
        c: Sample,
        nextSpan: Float,
    ) {
        val translation = hypot(c.x - scrollPoint.first, c.y - scrollPoint.second)
        val pinch = abs(nextSpan - distance) > slop * 1.5f && abs(nextSpan - distance) > translation
        if (pinch) {
            state = State.PINCHING
            gesture(false, GesturePhase.BEGAN, c, 1f)
        } else if (translation > slop) {
            state = State.SCROLLING
            gesture(true, GesturePhase.BEGAN, c, 0f)
        }
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

        if (event.actionMasked ==
            MotionEvent.ACTION_MOVE
        ) {
            for (i in 0 until event.historySize) {
                handle(
                    copy(event, width, height, i),
                    MotionEvent.ACTION_MOVE,
                    event.getHistoricalEventTime(i) * 1_000_000,
                )
            }
        }
        handle(copy(event, width, height, -1), event.actionMasked, event.eventTime * 1_000_000)
        return true
    }

    private fun copy(
        event: MotionEvent,
        width: Int,
        height: Int,
        history: Int,
    ): List<Sample> =
        (0 until event.pointerCount).map { i ->
            val historical = history >= 0
            val x = if (historical) event.getHistoricalX(i, history) else event.getX(i)
            val y = if (historical) event.getHistoricalY(i, history) else event.getY(i)
            val pressure = if (historical) event.getHistoricalPressure(i, history) else event.getPressure(i)
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
                pointerTool(event.getToolType(i)),
                buttons,
            )
        }

    private fun pointerTool(type: Int): PointerTool =
        when (type) {
            MotionEvent.TOOL_TYPE_STYLUS -> PointerTool.PEN
            MotionEvent.TOOL_TYPE_ERASER -> PointerTool.ERASER
            else -> PointerTool.FINGER
        }
}
