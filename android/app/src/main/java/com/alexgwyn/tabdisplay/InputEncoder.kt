package com.alexgwyn.tabdisplay

import android.os.Handler
import android.os.Looper
import android.view.MotionEvent
import android.view.View
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.cos
import kotlin.math.sin

/**
 * Serializes MotionEvents into PEN / TOUCH messages and hands them to the native writer
 * immediately. Every historical sample is sent with its own timestamp. Coordinates are
 * normalized to the view (= the video area).
 */
class InputEncoder(private val view: View) {
    private val buf = ByteBuffer.allocate(64 * 1024).order(ByteOrder.LITTLE_ENDIAN)
    private val main = Handler(Looper.getMainLooper())
    private var inProximity = false
    private var last = FloatArray(3)  // x, y of the last pen sample, plus tool
    private var lastT = 0L

    // Android sends HOVER_EXIT right before ACTION_DOWN; only report proximity-out if the
    // pen really left (no DOWN/HOVER_ENTER within a short window).
    private val proximityOut = Runnable {
        if (inProximity) {
            inProximity = false
            begin()
            penSample(System.nanoTime(), last[0], last[1], 0f, 0f, 0f, 0, PenPhase.PROXIMITY_OUT, last[2].toInt())
            flush(MsgType.PEN, System.nanoTime())
        }
    }

    fun onPen(e: MotionEvent) {
        val tool = if (e.getToolType(0) == MotionEvent.TOOL_TYPE_ERASER) PenTool.ERASER else PenTool.PEN
        begin()
        when (e.actionMasked) {
            MotionEvent.ACTION_HOVER_ENTER, MotionEvent.ACTION_DOWN -> {
                main.removeCallbacks(proximityOut)
                if (!inProximity) {
                    inProximity = true
                    addPen(e, -1, PenPhase.PROXIMITY_IN, tool)
                }
                addPen(e, -1, if (e.actionMasked == MotionEvent.ACTION_DOWN) PenPhase.DOWN else PenPhase.HOVER, tool)
            }
            MotionEvent.ACTION_HOVER_MOVE -> addAll(e, PenPhase.HOVER, tool)
            MotionEvent.ACTION_MOVE -> addAll(e, PenPhase.MOVE, tool)
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> addPen(e, -1, PenPhase.UP, tool)
            MotionEvent.ACTION_HOVER_EXIT -> {
                addPen(e, -1, PenPhase.HOVER, tool)
                main.postDelayed(proximityOut, 150)
            }
            else -> return
        }
        flush(MsgType.PEN, e.eventTimeNanos)
    }

    fun onTouch(e: MotionEvent) {
        begin()
        val idx = e.actionIndex
        for (i in 0 until e.pointerCount) {
            if (e.getToolType(i) != MotionEvent.TOOL_TYPE_FINGER) continue
            val action = when (e.actionMasked) {
                MotionEvent.ACTION_DOWN -> TouchAction.DOWN
                MotionEvent.ACTION_POINTER_DOWN -> if (i == idx) TouchAction.DOWN else continue
                MotionEvent.ACTION_MOVE -> TouchAction.MOVE
                MotionEvent.ACTION_UP -> TouchAction.UP
                MotionEvent.ACTION_POINTER_UP -> if (i == idx) TouchAction.UP else continue
                MotionEvent.ACTION_CANCEL -> TouchAction.CANCEL
                else -> continue
            }
            buf.putLong(e.eventTimeNanos)
            buf.put(e.getPointerId(i).toByte())
            buf.put(action.toByte())
            buf.putFloat(e.getX(i) / view.width)
            buf.putFloat(e.getY(i) / view.height)
            count++
        }
        flush(MsgType.TOUCH, e.eventTimeNanos)
    }

    private var count = 0

    private fun begin() {
        buf.clear()
        buf.putShort(0)  // count, patched in flush()
        count = 0
    }

    private fun flush(type: Int, t: Long) {
        if (count == 0) return
        buf.putShort(0, count.toShort())
        NativeBridge.sendInput(type, buf.array(), buf.position(), t)
    }

    private fun addAll(e: MotionEvent, phase: Int, tool: Int) {
        for (h in 0 until e.historySize) addPen(e, h, phase, tool)
        addPen(e, -1, phase, tool)
    }

    /** h = historical index, or -1 for the current sample. */
    private fun addPen(e: MotionEvent, h: Int, phase: Int, tool: Int) {
        fun axis(a: Int) = if (h < 0) e.getAxisValue(a) else e.getHistoricalAxisValue(a, h)
        val t = if (h < 0) e.eventTimeNanos else e.getHistoricalEventTimeNanos(h)
        val x = (if (h < 0) e.x else e.getHistoricalX(h)) / view.width
        val y = (if (h < 0) e.y else e.getHistoricalY(h)) / view.height
        val pressure = if (phase == PenPhase.DOWN || phase == PenPhase.MOVE) (if (h < 0) e.pressure else e.getHistoricalPressure(h)) else 0f
        // AXIS_TILT: angle from perpendicular; AXIS_ORIENTATION: direction the pen leans (0 = up, +pi/2 = right).
        val tilt = axis(MotionEvent.AXIS_TILT)
        val orient = axis(MotionEvent.AXIS_ORIENTATION)
        val tiltX = sin(tilt) * sin(orient)
        val tiltY = -sin(tilt) * cos(orient)
        var buttons = 0
        if (e.buttonState and MotionEvent.BUTTON_STYLUS_PRIMARY != 0) buttons = buttons or PenButton.PRIMARY
        if (e.buttonState and MotionEvent.BUTTON_STYLUS_SECONDARY != 0) buttons = buttons or PenButton.SECONDARY
        penSample(t, x, y, pressure, tiltX, tiltY, buttons, phase, tool)
    }

    private fun penSample(t: Long, x: Float, y: Float, pressure: Float, tiltX: Float, tiltY: Float, buttons: Int, phase: Int, tool: Int) {
        buf.putLong(t)
        buf.putFloat(x); buf.putFloat(y); buf.putFloat(pressure)
        buf.putFloat(tiltX); buf.putFloat(tiltY); buf.putFloat(0f)
        buf.put(buttons.toByte()); buf.put(phase.toByte()); buf.put(tool.toByte())
        last[0] = x; last[1] = y; last[2] = tool.toFloat()
        lastT = t
        count++
    }
}
