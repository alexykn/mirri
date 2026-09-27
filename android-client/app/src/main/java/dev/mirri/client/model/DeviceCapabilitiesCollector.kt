package dev.mirri.client.model

import android.app.Activity
import android.hardware.display.DisplayManager
import android.view.Display
import android.view.InputDevice
import dev.mirri.client.protocol.ClientDeviceHello
import dev.mirri.client.protocol.CodecOffer
import dev.mirri.client.protocol.InputCapabilities
import dev.mirri.client.protocol.PhysicalMode
import dev.mirri.client.protocol.VideoCodecId
import dev.mirri.client.video.CodecCapabilityProbe
import kotlin.math.roundToInt

object DeviceCapabilitiesCollector {
    private fun mode(m: Display.Mode) =
        PhysicalMode(
            m.physicalWidth.toLong(),
            m.physicalHeight.toLong(),
            (m.refreshRate * 1000).roundToInt().toLong(),
            m.modeId,
        )

    fun collect(
        activity: Activity,
        epoch: UInt,
        token: ByteArray,
    ): ClientDeviceHello {
        val display =
            activity.getSystemService(DisplayManager::class.java).getDisplay(Display.DEFAULT_DISPLAY)
                ?: error("internal display missing")
        val modes = (listOf(display.mode) + display.supportedModes.filterNot { it.modeId == display.mode.modeId }).take(16)
        val devices = InputDevice.getDeviceIds().toList().mapNotNull(InputDevice::getDevice)
        val pen = devices.any { it.sources and InputDevice.SOURCE_STYLUS == InputDevice.SOURCE_STYLUS }
        val pressure = devices.any { it.getMotionRange(android.view.MotionEvent.AXIS_PRESSURE, InputDevice.SOURCE_STYLUS) != null }
        val tilt = devices.any { it.getMotionRange(android.view.MotionEvent.AXIS_TILT, InputDevice.SOURCE_STYLUS) != null }
        val caps =
            CodecCapabilityProbe.choices().sortedByDescending { it.lowLatency }.distinctBy { it.codec }.map { choice ->
                CodecOffer(
                    VideoCodecId.fromWire(choice.codec),
                    choice.profile,
                    choice.level,
                    exact = true,
                    lowLatency = choice.lowLatency,
                    hardware = true,
                )
            }
        return ClientDeviceHello(
            epoch,
            token,
            "Mirri tablet",
            display.mode.physicalWidth,
            display.mode.physicalHeight,
            activity.resources.displayMetrics.densityDpi,
            mode(display.mode),
            modes.map(::mode),
            caps,
            InputCapabilities(5, pen, pressure, tilt, hover = false, auxiliary = true),
        )
    }
}
