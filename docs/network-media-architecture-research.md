# Network media architecture: research and proposed validation

**Status: proposal, not an accepted architecture or implementation plan.**
This records the research requested after questioning the TCP network path.
It does not supersede `network-streaming.md` or authorize a transport migration.
No dependency, application, device configuration, or installed build was changed
for this research. The earlier local-presentation experiment remains unresolved.

## Recommendation

Evaluate **full native WebRTC media** first, using libwebrtc on macOS and Android.
Use an actual video track with RTP/RTCP and DTLS-SRTP, not encoded video sent over
a WebRTC data channel. Prove hardware compatibility and latency in a bounded
prototype before choosing it for production.

The reason is ownership of media behavior: congestion feedback, encoder rate
adaptation, packet pacing, loss recovery, receive buffering, and frame delivery
need to work together. A smaller socket library can reduce initial integration
work while leaving these difficult responsibilities in Mirri.

The previous TCP choice favored reuse of the USB byte-stream protocol. That was
an implementation convenience, not a user requirement. Neither preserving that
wire format nor retaining the exact current encoder/decoder adapters should
dictate the network design. Preserve the required outcomes: native display
geometry, hardware acceleration, responsiveness, secure input, and reliable
session teardown.

UDP removes transport-level stream head-of-line blocking; it does not remove
Wi-Fi contention, codec dependencies, decoder queues, or presentation delay.
Current timing evidence does not prove TCP retransmission caused the observed
network tail latency. A successful migration still needs comparative evidence.

## Candidate comparison

| Candidate | Useful functionality | Remaining concern / assessment |
| --- | --- | --- |
| Full libwebrtc | Integrated real-time video engine, RTP/RTCP, congestion control, pacing, recovery, ICE and encrypted media; native codec integration | Packaging, hardware profile support, capture/render integration and buffering require proof. First candidate. |
| libdatachannel media tracks | Smaller native WebRTC transport and RTP handling primitives | Its v0.24.5 API explicitly says track sends have no flow/congestion control. Recovery/pacing helpers are not a complete adaptive video engine. Not the default merely because encoded H.264 is easy to submit. |
| GStreamer RTP / WebRTC | Mature RTP sessions, jitter buffering, codec/payload plugins and WebRTC integration | Credible alternative framework. Specify the actual congestion-control, encoder and recovery pipeline; `rtpbin` alone is insufficient. Native packaging and rendering remain substantial. |
| SRT / RIST | Established contribution-video transport and packet recovery | Recovery windows and latency policy need scrutiny for interactive display use. Not a finished interactive media/input engine; not the first candidate for this goal. SRT supports live/message modes and should not be reduced to “TCP over UDP.” |
| QUIC DATAGRAM | Congestion-controlled unreliable datagrams alongside reliable streams | Does not supply video packetization, decode deadlines, keyframe recovery or encoder adaptation. Too much new media policy for this task. Reliable QUIC streams still have per-stream head-of-line blocking. |
| SIP / PJSIP | Session signaling and media components for communications applications | SIP interoperability is not a stated requirement. SIP itself does not solve screen-video latency, discovery or pairing. |
| Sunshine / Moonlight | A working remote-streaming design worth studying | Not a neutral drop-in library. GPL licensing and protocol/product assumptions require an explicit reuse decision. Mirri currently uses MIT. |

## The first compatibility gate: this tablet

The current target uses 2456×1600 encoded video at 60 Hz, including H.264 High
Profile level 5.1. The inspected upstream Android
`MediaCodecVideoDecoderFactory` advertises H.264 High Profile through
Qualcomm/Exynos-specific checks, not the tablet's HiSilicon decoder. The same
behavior was confirmed in the accessible webrtc-sdk source mirror.

This is an **advertisement/integration risk**, not evidence that the hardware
cannot decode the stream. `HardwareVideoDecoderFactory` exposes a codec-selection
predicate, but selecting HiSilicon does not itself change profile advertisement.
A narrowly scoped factory/source adjustment or a separately validated profile
may be needed. Do not silently fall back to software decoding, scaling, or a
different profile and call the test successful.

The Android decoder API also returns decoded `VideoFrame` objects through a
callback. Mirri's existing direct MediaCodec-to-SurfaceView path is not an
assumed drop-in implementation of that contract. Rendering/texture ownership and
their latency must be evaluated. Apple's peer-connection factory supports
injectable encoder/decoder factories, but this is an integration opportunity,
not proof that the current encoder can be reused unchanged. In particular,
Mirri's current fixed encoder bitrate is not sufficient for adaptive media.

Use pinned source and artifacts for a prototype. Native distribution projects
such as webrtc-sdk are candidates, not endorsed binaries: check revision, fork
changes, target architectures, build flags, hardware codec behavior, and notices.
Audit the exact selected dependencies; protocol names do not establish licensing
or codec patent obligations.

## Discovery, pairing, and session ownership

Proposed flow:

1. A running/available Mirri receiver advertises a versioned service using
   Bonjour / Android NSD (mDNS/DNS-SD). Discovery is not authentication.
2. First-use pairing establishes a persistent peer identity with explicit user
   approval. Use a reviewed pairing protocol: for example a PAKE for a short
   code, or a QR flow binding a full identity key and high-entropy one-time
   credential. A short code is not a truncated certificate pin. Do not design
   custom cryptography.
3. Authenticated signaling carries application capabilities, SDP and ICE, and
   binds the media DTLS fingerprint to the paired identity. Negotiate display
   geometry and input permission at the application layer, beyond SDP codecs.
4. A video track carries media. A separate reliable ordered control data channel
   can carry critical input transitions and lifecycle messages, with bounded
   traffic. Coalescible pointer motion must not create an unbounded queue or
   displace key/button transitions. No bulk video on this channel.
5. Mirri owns authorization, disconnect/reconnect generations, stop/revoke,
   display cleanup, and releasing held keys/buttons on failure.

Start LAN-first. Direct local ICE candidates do not require a cloud signaling
service, SFU, public STUN, or TURN server. Internet support would require separate
rendezvous/relay and operational decisions. WebRTC can select TCP/relay paths;
record the selected candidate pair/protocol and do not label those measurements
as direct UDP.

Offer manual endpoint/pairing entry when multicast discovery is unavailable;
this cannot overcome blocked unicast connectivity or AP isolation. Discovery
also cannot launch an arbitrary dormant Android app. Receiver availability,
foreground/background behavior and applicable platform permissions need explicit
product treatment. Finding multiple receivers is not a requirement to stream to
them simultaneously. Miracast and Google Cast are not synonymous with this
app-to-app discovery and media design.

## Bounded prototype proposed for approval

Do not begin by replacing the production network path or building a complete
pairing UI. Keep USB as an independent reference implementation.

1. **Packaging and codec feasibility:** pin one native WebRTC build; establish
   a video-only local session on the actual Mac/tablet using explicitly verified
   peer identity for the test. Record negotiated profile/level, actual stream
   dimensions, selected hardware codec names and the selected ICE transport.
   Resolve the HiSilicon advertisement issue explicitly. Stop if the necessary
   customization is disproportionate or hardware behavior is unsuitable.
2. **End-to-end media proof:** feed owned synthetic desktop content through the
   real capture, hardware encode, UDP media, hardware decode and presentation
   path. Integrate encoder rate updates and keyframe requests. Record queue
   growth, frame age, delivered cadence, loss/recovery, bitrate and quality.
3. **Controlled comparison:** compare existing USB and TCP network baselines
   against WebRTC under matched content and network conditions. Include sustained
   operation, constrained bandwidth, loss/jitter, and recovery. Only apply network
   impairment in an isolated test environment, not globally on the user's working
   network. Retain interior stalls in analysis. Distinguish decoder callbacks,
   compositor presentation and physical display/input-to-photon measurements.
4. **Decision:** require native geometry/hardware behavior, materially improved
   network tail frame age without unacceptable quality/cadence degradation,
   bounded behavior under congestion, prompt recovery, and correct disconnect
   cleanup. Agree numeric latency/quality thresholds before running the comparison,
   using the existing baseline rather than inventing a performance promise.
   Reject or revise the candidate if it fails; do not conceal failure through
   silent fallback. Only then design the production integration and full pairing.

This work has **not** been run. Research establishes a preferred candidate and
specific ways to reject it, not verified device compatibility or a latency win.

## Primary sources and inspection scope

- [RFC 8834: WebRTC media transport](https://www.rfc-editor.org/rfc/rfc8834.html)
  — RTP/RTCP, congestion control and recovery requirements.
- [RFC 8835: WebRTC transports](https://www.rfc-editor.org/rfc/rfc8835.html)
  — ICE, secure media and transport alternatives.
- [Upstream Android decoder factory](https://webrtc.googlesource.com/src/+/refs/heads/main/sdk/android/src/java/org/webrtc/MediaCodecVideoDecoderFactory.java)
  — inspected blob `875d781abd2f24306f745679bf0e6639009f12c3`; the final complete
  High Profile predicate was also checked in the
  [webrtc-sdk mirror](https://github.com/webrtc-sdk/webrtc/blob/main/sdk/android/src/java/org/webrtc/MediaCodecVideoDecoderFactory.java)
  after upstream fetches returned HTTP 503.
- [Upstream hardware decoder factory](https://webrtc.googlesource.com/src/+/refs/heads/main/sdk/android/api/org/webrtc/HardwareVideoDecoderFactory.java)
  — inspected blob `215598a85d3904d3c899c6040c1ec47fc2fdccca`.
- [Android decoder callback contract](https://github.com/webrtc-sdk/webrtc/blob/main/sdk/android/api/org/webrtc/VideoDecoder.java)
  and [Apple factory API](https://webrtc.googlesource.com/src/+/refs/heads/main/sdk/objc/api/peerconnection/RTCPeerConnectionFactory.h)
  — native integration boundaries; Apple blob
  `abfa679a1c4d92bc58abd830e0c914356b9a98f8`.
- [libdatachannel v0.24.5 API documentation](https://github.com/paullouisageneau/libdatachannel/blob/v0.24.5/DOC.md)
  — `rtcSendMessage` track flow/congestion-control limitation.
- [GStreamer RTP session manager](https://gstreamer.freedesktop.org/documentation/rtpmanager/rtpbin.html),
  [jitter buffer](https://gstreamer.freedesktop.org/documentation/rtpmanager/rtpjitterbuffer.html),
  and [WebRTC element](https://gstreamer.freedesktop.org/documentation/webrtc/index.html).
- [RFC 9221: QUIC DATAGRAM](https://www.rfc-editor.org/rfc/rfc9221.html),
  [SRT project](https://github.com/Haivision/srt),
  [Sunshine](https://github.com/LizardByte/Sunshine),
  [Moonlight common client](https://github.com/moonlight-stream/moonlight-common-c).
- [Android NSD](https://developer.android.com/develop/connectivity/wifi/use-nsd)
  and [Apple Bonjour](https://developer.apple.com/bonjour/).
- [webrtc-sdk native distribution project](https://github.com/webrtc-sdk/webrtc)
  and [GStreamer licensing guidance](https://gstreamer.freedesktop.org/documentation/frequently-asked-questions/licensing.html).

Links to `main` are mutable source references, not selected dependency versions.
No native artifacts were built or evaluated during this research.
