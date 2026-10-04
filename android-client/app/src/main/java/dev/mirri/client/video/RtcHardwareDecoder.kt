package dev.mirri.client.video

import android.content.Context
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import android.util.Log
import dev.mirri.client.protocol.WireException
import org.webrtc.EglBase
import org.webrtc.HardwareVideoDecoderFactory
import org.webrtc.PeerConnectionFactory
import org.webrtc.VideoCodecInfo
import org.webrtc.VideoCodecStatus
import org.webrtc.VideoDecoder
import org.webrtc.VideoDecoderFactory
import java.util.concurrent.atomic.AtomicBoolean

/** The stock M150 factory omits HiSilicon High from its advertisement. Admit one proven codec only. */
internal class RtcHardwareDecoder private constructor(
    val name: String,
    context: EglBase.Context,
    private val failed: (String) -> Unit,
) : VideoDecoderFactory {
    private val backing = HardwareVideoDecoderFactory(context) { info -> info.name == name && info.isHardwareAccelerated }
    private val format =
        VideoCodecInfo(
            "H264",
            mapOf("profile-level-id" to "640034", "packetization-mode" to "1", "level-asymmetry-allowed" to "1"),
            emptyList(),
        )
    private val created = AtomicBoolean()

    override fun getSupportedCodecs(): Array<VideoCodecInfo> = arrayOf(format)

    override fun createDecoder(codec: VideoCodecInfo): VideoDecoder? {
        Log.i("MirriLifecycle", "RTC decoder factory requested matched=${codec.name == format.name && codec.params == format.params}")
        if (codec.name != format.name || codec.params != format.params || !created.compareAndSet(false, true)) {
            failed("RTC decoder selection rejected")
            return null
        }
        val decoder =
            backing.createDecoder(format) ?: run {
                failed("RTC hardware decoder unavailable")
                return null
            }
        if (decoder.implementationName != name) {
            decoder.release()
            failed("RTC decoder implementation changed")
            return null
        }
        return object : VideoDecoder by decoder {
            private var firstDecode = true

            override fun initDecode(
                settings: VideoDecoder.Settings,
                callback: VideoDecoder.Callback,
            ): VideoCodecStatus {
                Log.i("MirriLifecycle", "RTC decoder init geometry=${settings.width}x${settings.height}")
                if (settings.width != 2456 || settings.height != 1600) {
                    failed("RTC decoder configuration geometry changed")
                    return VideoCodecStatus.ERROR
                }
                val status =
                    decoder.initDecode(settings) { frame, decodeTimeMs, qp ->
                        if (frame.rotatedWidth != 2456 || frame.rotatedHeight != 1600) {
                            failed("RTC decoded geometry changed")
                        } else {
                            callback.onDecodedFrame(frame, decodeTimeMs, qp)
                        }
                    }
                Log.i("MirriLifecycle", "RTC decoder init status=${status.name}")
                if (status != VideoCodecStatus.OK) failed("RTC decoder configuration failed")
                return status
            }

            override fun decode(
                frame: org.webrtc.EncodedImage,
                info: VideoDecoder.DecodeInfo?,
            ): VideoCodecStatus {
                if (firstDecode) {
                    firstDecode = false
                    Log.i("MirriLifecycle", "RTC decoder first input geometry=${frame.encodedWidth}x${frame.encodedHeight}")
                }
                val status = decoder.decode(frame, info)
                if (status != VideoCodecStatus.OK && status != VideoCodecStatus.NO_OUTPUT) failed("RTC hardware decode failed")
                return status
            }
        }
    }

    companion object {
        private var initialized = false

        // The pinned SDK offers no other way to set a receive-side field trial.
        @Suppress("DEPRECATION")
        @Synchronized
        fun initialize(context: Context) {
            if (initialized) return
            PeerConnectionFactory.initialize(
                PeerConnectionFactory.InitializationOptions
                    .builder(context.applicationContext)
                    // A display mirror wants each frame as soon as it decodes, not the
                    // SDK's conferencing playout buffer. Unknown trials are ignored.
                    .setFieldTrials("WebRTC-ForcePlayoutDelay/min_ms:0,max_ms:0/")
                    .createInitializationOptions(),
            )
            initialized = true
        }

        fun preflight(name: String) {
            val egl = EglBase.create()
            try {
                val factory = qualified(name, egl.eglBaseContext) { throw WireException(it) }
                val decoder =
                    factory.createDecoder(factory.supportedCodecs.single())
                        ?: throw WireException("RTC hardware decoder creation failed")
                try {
                    if (decoder.initDecode(VideoDecoder.Settings(4, 2456, 1600)) { _, _, _ -> } != VideoCodecStatus.OK) {
                        throw WireException("RTC hardware decoder configure failed")
                    }
                } finally {
                    decoder.release()
                }
            } finally {
                egl.release()
            }
        }

        fun probe(): String? =
            MediaCodecList(MediaCodecList.REGULAR_CODECS)
                .codecInfos
                .firstOrNull { info ->
                    if (info.isEncoder ||
                        !info.isHardwareAccelerated ||
                        !info.supportedTypes.any {
                            it.equals(MediaFormat.MIMETYPE_VIDEO_AVC, true)
                        }
                    ) {
                        return@firstOrNull false
                    }
                    runCatching {
                        val capabilities = info.getCapabilitiesForType(MediaFormat.MIMETYPE_VIDEO_AVC)
                        capabilities.profileLevels.any {
                            it.profile == MediaCodecInfo.CodecProfileLevel.AVCProfileHigh &&
                                it.level >= MediaCodecInfo.CodecProfileLevel.AVCLevel52
                        } &&
                            capabilities.videoCapabilities.areSizeAndRateSupported(2456, 1600, 60.0)
                    }.getOrDefault(false)
                }?.name

        fun qualified(
            name: String?,
            context: EglBase.Context,
            failed: (String) -> Unit,
        ): RtcHardwareDecoder {
            if (name == null || probe() != name) throw WireException("RTC exact hardware decoder unavailable")
            return RtcHardwareDecoder(name, context, failed)
        }
    }
}
