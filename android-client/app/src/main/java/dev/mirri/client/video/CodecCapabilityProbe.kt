package dev.mirri.client.video

import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat

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
        val codec: MediaCodecKind,
        val mime: String,
        val androidProfile: Int,
        val androidLevel: Int,
        val wireLevel: Int,
    )

    private val required =
        listOf(
            Profile(
                MediaCodecKind.AVC,
                MediaFormat.MIMETYPE_VIDEO_AVC,
                MediaCodecInfo.CodecProfileLevel.AVCProfileHigh,
                MediaCodecInfo.CodecProfileLevel.AVCLevel51,
                51,
            ),
            Profile(
                MediaCodecKind.HEVC,
                MediaFormat.MIMETYPE_VIDEO_HEVC,
                MediaCodecInfo.CodecProfileLevel.HEVCProfileMain,
                MediaCodecInfo.CodecProfileLevel.HEVCMainTierLevel51,
                153,
            ),
        )

    fun choices(): List<DecoderChoice> =
        MediaCodecList(MediaCodecList.REGULAR_CODECS)
            .codecInfos
            .filter { !it.isEncoder && it.isHardwareAccelerated && !it.isSoftwareOnly }
            .flatMap { info -> required.mapNotNull { profile -> choice(info, profile) } }

    private fun choice(
        info: MediaCodecInfo,
        profile: Profile,
    ): DecoderChoice? {
        if (info.supportedTypes.none { it.equals(profile.mime, ignoreCase = true) }) return null
        val caps =
            try {
                info.getCapabilitiesForType(profile.mime)
            } catch (_: IllegalArgumentException) {
                return null // Vendor advertises a MIME it cannot query; do not advertise it.
            }
        if (!caps.videoCapabilities.areSizeAndRateSupported(2456, 1600, 60.0)) return null
        if (caps.profileLevels.none { it.profile == profile.androidProfile && it.level >= profile.androidLevel }) return null
        return DecoderChoice(
            info.name,
            profile.codec.id,
            profile.codec.id,
            profile.wireLevel,
            caps.isFeatureSupported(MediaCodecInfo.CodecCapabilities.FEATURE_LowLatency),
        )
    }
}
