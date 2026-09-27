package dev.mirri.client.video

import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import dev.mirri.client.protocol.VideoCodecId

data class DecoderChoice(
    val name: String,
    val codec: Int,
    val profile: Int,
    val level: Int,
    val lowLatency: Boolean,
) {
    fun matches(
        codec: Int,
        profile: Int,
        level: Int,
    ): Boolean = this.codec == codec && this.profile == profile && this.level == level
}

object CodecCapabilityProbe {
    private data class Profile(
        val codec: VideoCodecId,
        val mime: String,
        val androidProfile: Int,
        val androidLevel: Int,
        val wireLevel: Int,
    )

    private val required =
        listOf(
            Profile(
                VideoCodecId.AVC,
                MediaFormat.MIMETYPE_VIDEO_AVC,
                MediaCodecInfo.CodecProfileLevel.AVCProfileHigh,
                MediaCodecInfo.CodecProfileLevel.AVCLevel51,
                51,
            ),
            Profile(
                VideoCodecId.HEVC,
                MediaFormat.MIMETYPE_VIDEO_HEVC,
                MediaCodecInfo.CodecProfileLevel.HEVCProfileMain,
                MediaCodecInfo.CodecProfileLevel.HEVCMainTierLevel51,
                153,
            ),
        )

    fun choices(): List<DecoderChoice> {
        val result = mutableListOf<DecoderChoice>()
        for (info in MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos) {
            if (info.isEncoder || !info.isHardwareAccelerated || info.isSoftwareOnly) continue
            for (profile in required) {
                if (info.supportedTypes.none { it.equals(profile.mime, ignoreCase = true) }) continue
                val caps =
                    try {
                        info.getCapabilitiesForType(profile.mime)
                    } catch (_: IllegalArgumentException) {
                        continue // Vendor advertises a MIME it cannot query; do not advertise it.
                    }
                if (!caps.videoCapabilities.areSizeAndRateSupported(2456, 1600, 60.0)) continue
                if (caps.profileLevels.none { it.profile == profile.androidProfile && it.level >= profile.androidLevel }) continue
                result +=
                    DecoderChoice(
                        info.name,
                        profile.codec.wire,
                        profile.codec.wire,
                        profile.wireLevel,
                        caps.isFeatureSupported(MediaCodecInfo.CodecCapabilities.FEATURE_LowLatency),
                    )
            }
        }
        return result
    }
}
