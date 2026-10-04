package dev.mirri.client.video

import android.util.Log
import dev.mirri.client.protocol.RtcSdpProof
import dev.mirri.client.protocol.WireException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import org.webrtc.CandidatePairChangeEvent
import org.webrtc.EglBase
import org.webrtc.IceCandidate
import org.webrtc.MediaConstraints
import org.webrtc.MediaStream
import org.webrtc.PeerConnection
import org.webrtc.PeerConnectionFactory
import org.webrtc.RtpTransceiver
import org.webrtc.SdpObserver
import org.webrtc.SessionDescription
import org.webrtc.SurfaceViewRenderer
import org.webrtc.VideoCodecStatus
import org.webrtc.VideoDecoder
import org.webrtc.VideoFrame
import org.webrtc.VideoSink
import org.webrtc.VideoTrack
import java.util.concurrent.atomic.AtomicInteger
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/** One receive-only native video track. The owner joins this resource before asynchronous SDK calls. */
internal class RtcReceiver(
    private val renderer: SurfaceViewRenderer,
    private val name: String,
    private val failed: (String) -> Unit,
) {
    sealed interface Event {
        data class Candidate(
            val mid: String,
            val index: Int,
            val sdp: String,
        ) : Event

        data class Failure(
            val reason: String,
        ) : Event
    }

    val events = Channel<Event>(65)
    private var egl: EglBase? = null
    private var factory: PeerConnectionFactory? = null
    private var peer: PeerConnection? = null
    private var track: VideoTrack? = null

    @Volatile private var active = true

    @Volatile private var frameSeen = false

    @Volatile private var lastIceStatus = ""

    private val renderedFrames = AtomicInteger()
    private var lastMediaReportNs = 0L

    private val sink =
        VideoSink { frame: VideoFrame ->
            if (active) {
                if (!exactFrame(frame)) {
                    failed("RTC frame geometry changed")
                } else {
                    frameSeen = true
                    renderedFrames.incrementAndGet()
                    renderer.onFrame(frame)
                }
            }
        }

    private fun exactFrame(frame: VideoFrame): Boolean {
        val buffer = frame.rotation == 0 && frame.buffer.width == 2456 && frame.buffer.height == 1600
        return buffer && frame.rotatedWidth == 2456 && frame.rotatedHeight == 1600
    }

    suspend fun prepare() {
        withContext(Dispatchers.Main) {
            if (!renderer.holder.surface.isValid || renderer.width != 2456 || renderer.height != 1600) {
                throw WireException("RTC exact renderer surface unavailable")
            }
            egl = EglBase.create()
            renderer.init(requireNotNull(egl).eglBaseContext, null)
            renderer.setEnableHardwareScaler(false)
            renderer.setScalingType(org.webrtc.RendererCommon.ScalingType.SCALE_ASPECT_FIT)
            renderer.disableFpsReduction()
        }
        // Prove that the SDK's *selected* hardware decoder actually configures at
        // native size, not merely that Android advertised a profile/size tuple.
        val preflight = RtcHardwareDecoder.qualified(name, requireNotNull(egl).eglBaseContext, failed)
        val test =
            preflight.createDecoder(preflight.supportedCodecs.single())
                ?: throw WireException("RTC decoder preflight creation failed")
        try {
            if (test.initDecode(VideoDecoder.Settings(4, 2456, 1600)) { _, _, _ -> } != VideoCodecStatus.OK) {
                throw WireException("RTC decoder hardware configure failed")
            }
        } finally {
            test.release()
        }
        val decoder = RtcHardwareDecoder.qualified(name, requireNotNull(egl).eglBaseContext, failed)
        factory = PeerConnectionFactory.builder().setVideoDecoderFactory(decoder).createPeerConnectionFactory()
        val config = PeerConnection.RTCConfiguration(emptyList())
        config.tcpCandidatePolicy = PeerConnection.TcpCandidatePolicy.DISABLED
        val observer =
            object : PeerConnection.Observer {
                override fun onSignalingChange(state: PeerConnection.SignalingState) = Unit

                override fun onIceConnectionChange(state: PeerConnection.IceConnectionState) {
                    Log.i("MirriLifecycle", "RTC native ICE state=${state.name}")
                    if (state == PeerConnection.IceConnectionState.FAILED || state == PeerConnection.IceConnectionState.DISCONNECTED) {
                        emit(Event.Failure("RTC ICE failed"))
                    }
                }

                override fun onIceConnectionReceivingChange(receiving: Boolean) = Unit

                override fun onIceGatheringChange(state: PeerConnection.IceGatheringState) = Unit

                override fun onIceCandidate(candidate: IceCandidate) {
                    emit(Event.Candidate(candidate.sdpMid, candidate.sdpMLineIndex, candidate.sdp))
                }

                override fun onIceCandidatesRemoved(candidates: Array<IceCandidate>) = Unit

                override fun onAddStream(stream: MediaStream) = Unit

                override fun onRemoveStream(stream: MediaStream) = Unit

                override fun onDataChannel(channel: org.webrtc.DataChannel) {
                    emit(Event.Failure("RTC data channel not allowed"))
                }

                override fun onRenegotiationNeeded() = Unit

                override fun onSelectedCandidatePairChanged(event: CandidatePairChangeEvent) {
                    if (!event.local.sdp.contains(" udp ", true) || !event.remote.sdp.contains(" udp ", true)) {
                        emit(Event.Failure("RTC selected non-UDP pair"))
                    }
                }

                override fun onTrack(transceiver: RtpTransceiver) {
                    synchronized(this@RtcReceiver) {
                        if (!active) return
                        val received = transceiver.receiver.track() as? VideoTrack
                        if (received == null ||
                            track != null ||
                            transceiver.mediaType != org.webrtc.MediaStreamTrack.MediaType.MEDIA_TYPE_VIDEO
                        ) {
                            emit(Event.Failure("RTC unexpected media track"))
                        } else {
                            track = received
                            received.addSink(sink)
                        }
                    }
                }
            }
        peer = factory?.createPeerConnection(config, observer) ?: throw WireException("RTC peer unavailable")
        val transceiver =
            requireNotNull(peer).addTransceiver(
                org.webrtc.MediaStreamTrack.MediaType.MEDIA_TYPE_VIDEO,
                RtpTransceiver.RtpTransceiverInit(RtpTransceiver.RtpTransceiverDirection.RECV_ONLY),
            ) ?: throw WireException("RTC recvonly transceiver unavailable")
        val codecs = factory!!.getRtpReceiverCapabilities(org.webrtc.MediaStreamTrack.MediaType.MEDIA_TYPE_VIDEO).codecs
        val high = codecs.filter { it.name.equals("H264", true) && it.parameters["profile-level-id"] == "640034" }
        if (high.isEmpty() || transceiver.setCodecPreferences(high).isError) {
            throw WireException("RTC SDK High 5.2 preference unavailable")
        }
    }

    private fun emit(event: Event) {
        if (active && !events.trySend(event).isSuccess) failed("RTC event queue congested")
    }

    suspend fun answer(offer: String): Pair<String, String> {
        val mid = RtcSdpProof.mid(offer, "sendonly")
        val pc = peer ?: throw WireException("RTC peer closed")
        pc.setRemote(SessionDescription(SessionDescription.Type.OFFER, offer))
        val answer = pc.createAnswerSuspend()
        if (RtcSdpProof.mid(answer.description, "recvonly") != mid) throw WireException("RTC answer mid changed")
        pc.setLocal(answer)
        return mid to answer.description
    }

    suspend fun add(
        mid: String,
        text: String,
    ) {
        val completed = CompletableDeferred<Unit>()
        val pc = peer ?: throw WireException("RTC peer closed")
        val remote = pc.remoteDescription?.description.orEmpty()
        val iceUfragLine = remote.lineSequence().firstOrNull { it.startsWith("a=ice-ufrag:") }.orEmpty()
        val iceUfrag = iceUfragLine.removePrefix("a=ice-ufrag:").trim()
        val parts = text.split(' ')
        val ufragPosition = parts.indexOf("ufrag")
        Log.i(
            "MirriLifecycle",
            "RTC add ICE remoteDescription=${remote.isNotEmpty()} ufrag=${iceUfrag.isNotEmpty()} " +
                "candidateUfrag=${ufragPosition >= 0} matches=${ufragPosition >= 0 && parts.getOrNull(ufragPosition + 1) == iceUfrag} " +
                "signaling=${pc.signalingState().name}",
        )
        pc.addIceCandidate(
            IceCandidate(mid, 0, text),
            object : org.webrtc.AddIceObserver {
                override fun onAddSuccess() {
                    completed.complete(Unit)
                }

                override fun onAddFailure(error: String) {
                    completed.completeExceptionally(WireException("RTC candidate rejected"))
                }
            },
        )
        completed.await()
    }

    @Suppress("CyclomaticComplexMethod")
    suspend fun udpConnected(): Boolean {
        val pc = peer ?: return false
        val summary = "${pc.connectionState().name}/${pc.iceConnectionState().name}/${pc.iceGatheringState().name}"
        if (summary != lastIceStatus) {
            lastIceStatus = summary
            Log.i("MirriLifecycle", "RTC peer/ICE/gather=$summary")
        }
        if (pc.connectionState() != PeerConnection.PeerConnectionState.CONNECTED) return false
        val report =
            suspendCancellableCoroutine<org.webrtc.RTCStatsReport> { continuation ->
                pc.getStats { if (continuation.isActive) continuation.resume(it) }
            }
        val map = report.statsMap
        val nowNs = System.nanoTime()
        if (nowNs - lastMediaReportNs >= 10_000_000_000L) {
            lastMediaReportNs = nowNs
            val inbound = map.values.firstOrNull { it.type == "inbound-rtp" && it.members["kind"] == "video" }
            val decoded = (inbound?.members?.get("framesDecoded") as? Number)?.toLong() ?: 0L
            val emitted = (inbound?.members?.get("jitterBufferEmittedCount") as? Number)?.toLong() ?: 0L

            fun meanMs(
                value: Any?,
                count: Long,
            ): String =
                if (count > 0 && value is Number) {
                    "%.1f".format(java.util.Locale.ROOT, value.toDouble() * 1_000 / count)
                } else {
                    "unavailable"
                }
            Log.i(
                "MirriLifecycle",
                "RTC media frames received=${inbound?.members?.get("framesReceived") ?: "unavailable"} " +
                    "decoded=${inbound?.members?.get("framesDecoded") ?: "unavailable"} " +
                    "exactSink=${renderedFrames.get()} dropped=${inbound?.members?.get("framesDropped") ?: "unavailable"} " +
                    "decodeMeanMs=${meanMs(inbound?.members?.get("totalDecodeTime"), decoded)} " +
                    "jitterMeanMs=${meanMs(inbound?.members?.get("jitterBufferDelay"), emitted)}",
            )
        }
        val pairId =
            map.values
                .firstOrNull { it.type == "transport" }
                ?.members
                ?.get("selectedCandidatePairId")
        val pair =
            map[pairId] ?: map.values.singleOrNull {
                it.type == "candidate-pair" && it.members["selected"] == true && it.members["state"] == "succeeded"
            } ?: return false
        val local = map[pair.members["localCandidateId"]] ?: return false
        val remote = map[pair.members["remoteCandidateId"]] ?: return false
        if (local.members["protocol"] != "udp" || remote.members["protocol"] != "udp") {
            throw WireException("RTC selected non-UDP transport")
        }
        if (frameSeen) {
            val codec =
                map.values.any {
                    it.type == "codec" &&
                        it.members["mimeType"]?.toString()?.equals("video/H264", true) == true &&
                        it.members["sdpFmtpLine"]?.toString()?.let(RtcSdpProof::highParameters) == true
                }
            if (!codec) throw WireException("RTC negotiated High 5.2 codec unavailable")
        }
        return true
    }

    /** Aggregate ICE stats only; never persist candidate addresses or native SDP. */
    suspend fun iceDiagnostic(): String {
        val pc = peer ?: return "closed"
        val report =
            suspendCancellableCoroutine<org.webrtc.RTCStatsReport> { continuation ->
                pc.getStats { if (continuation.isActive) continuation.resume(it) }
            }
        val stats = report.statsMap.values
        val pairs = stats.filter { it.type == "candidate-pair" }
        return "local=${stats.count { it.type == "local-candidate" }} " +
            "remote=${stats.count { it.type == "remote-candidate" }} pairs=${pairs.size} " +
            "checks=${pairs.sumOf { (it.members["requestsSent"] as? Number)?.toLong() ?: 0L }} " +
            "responses=${pairs.sumOf { (it.members["responsesReceived"] as? Number)?.toLong() ?: 0L }}"
    }

    suspend fun close() {
        synchronized(this) {
            active = false
            runCatching { track?.removeSink(sink) }
            track = null
        }
        events.close()
        runCatching { peer?.close() }
        runCatching { peer?.dispose() }
        peer = null
        runCatching { factory?.dispose() }
        factory = null
        withContext(Dispatchers.Main) {
            try {
                renderer.release()
            } finally {
                egl?.release()
                egl = null
            }
        }
    }

    private suspend fun PeerConnection.setRemote(sdp: SessionDescription) =
        suspendCancellableCoroutine<Unit> { c ->
            setRemoteDescription(observer(c), sdp)
        }

    private suspend fun PeerConnection.setLocal(sdp: SessionDescription) =
        suspendCancellableCoroutine<Unit> { c ->
            setLocalDescription(observer(c), sdp)
        }

    private suspend fun PeerConnection.createAnswerSuspend(): SessionDescription =
        suspendCancellableCoroutine { c ->
            createAnswer(
                object : SdpObserver {
                    override fun onCreateSuccess(sdp: SessionDescription) {
                        if (c.isActive) c.resume(sdp)
                    }

                    override fun onSetSuccess() = Unit

                    override fun onCreateFailure(reason: String) {
                        if (c.isActive) c.resumeWithException(WireException("RTC answer failed"))
                    }

                    override fun onSetFailure(reason: String) = Unit
                },
                MediaConstraints(),
            )
        }

    private fun observer(c: kotlinx.coroutines.CancellableContinuation<Unit>) =
        object : SdpObserver {
            override fun onCreateSuccess(sdp: SessionDescription) = Unit

            override fun onSetSuccess() {
                if (c.isActive) c.resume(Unit)
            }

            override fun onCreateFailure(reason: String) = Unit

            override fun onSetFailure(reason: String) {
                if (c.isActive) c.resumeWithException(WireException("RTC description rejected"))
            }
        }
}
