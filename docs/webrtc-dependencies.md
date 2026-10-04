# Pinned native WebRTC dependency contract (first delivery)

**Selected distributions, not checked-in binaries.** Both are M150 builds of
the webrtc-sdk WebRTC fork, but have separate packaging revisions. This is a
build/API feasibility check, **not** a claim that the tablet hardware or LAN
session has passed. Keep `protocol/webrtc.md`'s RTC mode explicitly selected;
USB does not link to or use this new media backend.

| Platform | Immutable artifact / integration | SHA-256 of downloaded artifact | Provenance |
| --- | --- | --- | --- |
| Apple macOS | SwiftPM exact `https://github.com/livekit/webrtc-xcframework.git` tag `150.7871.02` (tag commit `c73deceaddd9c07293871ae28f24d4326cc86d62`), product/module `LiveKitWebRTC`; [release zip](https://github.com/livekit/webrtc-xcframework/releases/download/150.7871.02/LiveKitWebRTC.xcframework.zip) | `a523cd141d2aa6c3638d49fea1f72b0aafd28a8818c35fc240e08418da3d2fda` | Package.swift at tag pins the **same** zip/checksum; release says built by [`webrtc-sdk/webrtc-build@66ed9c7b07b2ad6ad624df0317e408dca562f91b`](https://github.com/webrtc-sdk/webrtc-build/commit/66ed9c7b07b2ad6ad624df0317e408dca562f91b). |
| Android | Maven Central `io.github.webrtc-sdk:android:150.7871.01` (`org.webrtc` package), [AAR](https://repo.maven.apache.org/maven2/io/github/webrtc-sdk/android/150.7871.01/android-150.7871.01.aar) | `0a1627b1a48c2bc17d9a40d62fc47bd45166f44a311e95917f147c402de379b0` | [distribution tag](https://github.com/webrtc-sdk/android/releases/tag/v150.7871.01), tag commit `7b6390fb098303b31af76906bf15f7decaa4ef95`, published Maven [POM](https://repo.maven.apache.org/maven2/io/github/webrtc-sdk/android/150.7871.01/android-150.7871.01.pom). Use normal artifact, **not** `android-prefixed` or stripped variants. |

Artifact SHA-256 values above were computed locally after successful HTTPS
downloads, not guessed from release naming. The released Apple framework has
`macos-arm64_x86_64` with `arm64` and `x86_64` slices (`lipo -info`), macOS
minimum 10.15 (`otool -l`), so the project's macOS 14 target is in range.
The AAR contains `jni/arm64-v8a/libjingle_peerconnection_so.so` (verified
AArch64 ELF), plus armeabi-v7a, x86, x86_64. Android app minSdk=30. Its
`classes.jar` contains the Java peer connection, codec and renderer APIs below.
These package/ABI facts do **not** prove device codec capability or link safety
when another WebRTC SDK is present; do not load a second `org.webrtc` version.

## Apple owner: specific API and integration checks

SwiftPM can depend on the exact tag and add `.product(name:
"LiveKitWebRTC", package: "webrtc-xcframework")` to the host target; verify
the package identity resolved by SwiftPM (may be `webrtc-xcframework`) before
editing targets. An Xcode project may instead resolve the same package product;
share one resolved binary, do not embed two framework copies. This binary's
module is `LiveKitWebRTC` and **Objective-C types have an `LK` prefix**, e.g.
`LKRTCPeerConnectionFactory`, `LKRTCVideoFrame`, `LKRTCCVPixelBuffer` (not
`RTC...`). Framework inspected at
`LiveKitWebRTC.xcframework/macos-arm64_x86_64/LiveKitWebRTC.framework/Headers`:

- `LKRTCPeerConnectionFactory(encoderFactory:decoderFactory:)`, with
  `LKRTCDefaultVideoEncoderFactory` or a narrowly injected factory; `videoSource(forScreenCast:)`,
  `videoTrack(with:trackId:)`, `peerConnection(with:constraints:delegate:)`,
  sender/receiver capabilities for `video`.
- `LKRTCPeerConnection` add video transceiver, create offer, set local/remote
  SDP, `addIceCandidate(_:completionHandler:)`, gathering/connection
  callbacks, `getStats`, `close`; `LKRTCConfiguration.iceServers=[]`,
  `tcpCandidatePolicy` and SDP semantics. Confirm selected pair UDP with stats
  even if TCP candidates are disabled; no public ICE servers.
- Source conforms to `LKRTCVideoCapturerDelegate`: feed
  `capturer(_:didCapture:)` using an owned `LKRTCVideoCapturer` and a
  `LKRTCVideoFrame(buffer: LKRTCCVPixelBuffer(pixelBuffer: ...), rotation:,
  timeStampNs:)`. Retain/release CVPixelBuffer across callback boundaries;
  do not assume the existing fixed-rate VideoToolbox encoder meets the SDK's
  rate/keyframe contract. `LKRTCVideoEncoderH264.supportedCodecs()` on this
  arm64 host **actually returned** constrained High H.264 `640c34` and
  constrained Baseline `42e034`, both packetization-mode=1. This is an API
  runtime result, not proof of hardware encoding at 2456×1600@60.
  An opt-in native VideoToolbox synthetic 2456×1600 frame probe subsequently
  **did** create a hardware-required High 5.2 session, but its actual SPS was
  `27 64 00 34` (ordinary High 5.2, not constrained High). The RTC custom
  factory now advertises `640034`, checks that exact hardware SPS and uses
  profile enum 2; the earlier SDK built-in `640c34` listing is not evidence
  for advertising a mismatched custom hardware bitstream.

`swiftc -typecheck -F <extracted macOS slice> <throwaway Swift API probe>`
passed with factory/source/transceiver/CVPixelBuffer and H264 API calls. A
small process dynamically linked against this released framework and printed
the two codec formats above. No project source or device was changed.
Confirm real encoder is hardware VideoToolbox and its SDK-controlled rate and
keyframe behavior under load; **reject** software or scaled output. Level
`0x34` (52) from the factory must not be misrepresented as level 51; use only
an SDK-negotiated High level supported by both actual endpoints without
handwritten SDP surgery.

## Android owner: narrow HiSilicon factory contract

Add `implementation("io.github.webrtc-sdk:android:150.7871.01")` through the
existing `mavenCentral()` repository. Inspected `classes.jar` with `javap`:
`PeerConnectionFactory.builder().setVideoDecoderFactory(...)`,
`HardwareVideoDecoderFactory(EglBase.Context, Predicate<MediaCodecInfo>)`,
`VideoDecoderFactory.getSupportedCodecs()/createDecoder(VideoCodecInfo)`,
`PeerConnection.addTransceiver(...)`, `setRemoteDescription`, `createAnswer`,
`addIceCandidate(..., AddIceObserver)`, `onTrack`, `onIceCandidate`,
`onSelectedCandidatePairChanged`; `SurfaceViewRenderer` implements `VideoSink`
with `init`/`release`. `VideoDecoder` returns `VideoFrame` through its decoder
callback, not Mirri's existing direct Surface MediaCodec contract. Use SDK
renderer and verify no implicit render scaling/fps reduction, or fail the
exact-geometry gate. Do not insert `DefaultVideoDecoderFactory`, which includes
software codecs, as a failure fallback.

Disassembly of **this AAR** shows `MediaCodecVideoDecoderFactory` (package
private) advertises H264 High only for codec names beginning `OMX.qcom.` or
`OMX.Exynos.` (SDK>=23). Merely supplying a HiSilicon predicate to
`HardwareVideoDecoderFactory` does **not** advertise High. Its `createDecoder`
does select the permitted hardware `MediaCodecInfo` by MIME and returns an
`AndroidVideoDecoder`, independent of this advertisement. The viable narrow
adapter is a `VideoDecoderFactory` wrapper around a hardware factory restricted
to the **probed exact codec name**: offer only H.264 ordinary High
(`profile-level-id=640034`, packetization-mode=1,
level-asymmetry-allowed=1) **if** Android `MediaCodecInfo` confirms hardware,
H.264 High profile, exact geometry/rate and sufficient level (52 here), and
the factory actually creates/configures that same codec. Otherwise report
`RtcCapabilities` unsupported and end RTC setup. Never simply add High to
`getSupportedCodecs()` without hardware probing and output verification; the
source factory chooses the first allowed codec, so restrict it to the tested
codec name. If tablet hardware proves only level 51, negotiate a supported
High level with SDK APIs and explicit proof from both sides; if not possible,
fail instead of claiming 640034 support. Filter `createDecoder` to the
advertised codec parameters and reject everything else; verify actual codec
implementation name and decoded frame geometry at runtime. The existing
`CodecCapabilityProbe` for USB does not authorize RTC hardware support.

`javac -classpath <downloaded classes.jar>:<android-35 android.jar>` compiled a
throwaway implementation of this wrapper interface/predicate/high-codec map.
This proves accessible API signatures, **not** a successful runtime decoder
or that High 5.2 is supported by this tablet. Hardware qualification is the
first device gate after coordinated install; no device run was performed.

## Licensing, provenance and unresolved gates

The Apple binary includes a WebRTC 3-clause BSD `LICENSE`; the Android
distribution's [POM](https://repo.maven.apache.org/maven2/io/github/webrtc-sdk/android/150.7871.01/android-150.7871.01.pom)
declares BSD-3-Clause while its
[packaging repository](https://github.com/webrtc-sdk/android/tree/v150.7871.01)
has an [MIT LICENSE](https://github.com/webrtc-sdk/android/blob/v150.7871.01/LICENSE).
This metadata mismatch needs clarification for redistributed binaries; the
underlying WebRTC project uses BSD-3-Clause and has further bundled notices.
The WebRTC source headers mention a separate PATENTS grant; H.264 patent
licensing and bundled third-party notices require a **release/legal audit**,
not inference from the BSD label. The Apple release identifies a build-tool
commit and both distributions identify M150 versions, but **neither downloaded
binary embeds a verifiable exact webrtc-sdk/webrtc source-tree commit/build
flags provenance** in the inspected metadata. Upstream build instructions at
[`webrtc-build@66ed9c7/docs/build.md`](https://github.com/webrtc-sdk/webrtc-build/blob/66ed9c7b07b2ad6ad624df0317e408dca562f91b/docs/build.md)
show `rtc_use_h264=false` for Android/macOS (WebRTC's platform hardware H264
implementations are exposed in these artifacts nevertheless); do not equate
this flag with certified hardware performance. If policy requires reproducible
source-tree SHA/flags or complete third-party notices before adopting binaries,
request publisher provenance or a controlled build rather than silently
assuming it. A full Chromium checkout/build was **not** started.

Next gate is actual host/tablet hardware H264 High capability at native
2456×1600@60, correct negotiated SDP profile/level, UDP candidate pair,
hardware name, delivered cadence/frame age, and clean stop/retry. Persistent
pairing/discovery is a documented subsequent connection-layer effort; initial
delivery relies on current USB credential bootstrap and pinned TLS control.
