# Native WebRTC network media: architecture and delivery

## Decision

The user selected full libwebrtc and authorized Sol implementation agents after
architecture planning. This document is the implementation direction; the earlier
network-media research records the reasoning, not a further approval requirement.
Production readiness still depends on the gates below.

Use libwebrtc as the network **media owner**, not as a byte connection or an
encoded-unit sink. Keep USB's current Mirri video protocol and media pipeline.
Do not force both backends through a transport-shaped abstraction.

## Ownership

```
Application / session coordinator (one active attempt and cleanup owner)
  authenticated control session
    capabilities, display/input permission, SDP/ICE, stop and failures
  USB media backend
    existing capture/encode -> Mirri video wire -> MediaCodec / SurfaceView
  WebRTC media backend
    ScreenCaptureKit pixel buffers -> RTC video source
      -> hardware VideoToolbox encoder under libwebrtc rate/keyframe control
      -> RTP/RTCP, pacing, congestion control, DTLS-SRTP, ICE
      -> hardware Android decoder -> RTC frame renderer
```

The session chooses exactly one media backend. Share display acquisition and
capture facilities where their ownership is already clear; do not run two
encoders or maintain two independent capture/admission queues. A small lifecycle
contract (prepare/start/stop/events) may unify session orchestration, but must not
erase fundamentally different frame ownership. Keep RTC types inside platform
adapters; core session messages expose typed, bounded signaling values.

### Control and security

For the first working delivery, retain the existing pinned TLS control connection
and USB credential bootstrap. It carries capability negotiation, SDP/ICE and
existing input/lifecycle messages; **video never travels on it**. This preserves
an authenticated channel for binding SDP's DTLS fingerprint without inventing a
pairing system during media integration. Do not add a second control data channel
with duplicated session ownership. Small signaling messages are bounded, versioned
and ordered with existing control traffic; critical input transitions must not
be displaced by unbounded signaling queues.

Define a distinct media capability/version so old clients fail explicitly rather
than misparse SDP or fall back silently. Host is the offerer, Android the answerer.
Negotiate H.264 send-only/receive-only video, no audio. Use trickle ICE only with
bounded candidate staging; the pinned SDK gathering-complete callback does not
guarantee the last candidate callback was delivered. An optional end record is
advisory, not a terminal barrier; connection/ready/start has a bounded deadline.
Reject unsupported versions, oversized messages, unexpected states and stale
attempts at the boundary. RTC consumes SDP; avoid handwritten SDP surgery unless
the pinned API demonstrably lacks a necessary setting and the change is tested.

This is LAN-first: no public STUN/TURN or cloud service dependency. Record the
selected candidate pair and transport; the UDP gate must fail or clearly report
degraded transport rather than silently benchmark TCP. Do not log credentials,
raw SDP or private frame content.

### Capture, codec, and rendering

Use native pixel-buffer/texture paths where supported; preserve explicit retain /
release ownership across SDK callbacks. Libwebrtc owns encoder rate updates,
keyframe requests, network pacing and receive timing. Prefer its hardware codec
implementations over duplicating those policies in the current fixed-rate encoder.
Any custom encoder must implement the complete SDK callback/rate/lifecycle contract.

The first hardware gate is the current 2456×1600, 60 Hz target. Verify actual
hardware encoder and decoder, H.264 profile/level and output dimensions. Android's
HiSilicon High Profile advertisement needs explicit inspection against the selected
SDK. A narrowly scoped factory fix is acceptable; silently switching to software,
lower resolution or another profile is not. Do not promise HEVC in the first slice.
Bitrate may adapt; geometry must not silently adapt. Report achieved cadence,
quality and frame age rather than claiming configured 60 Hz equals delivered 60 fps.

### Current opt-in hardware integration evidence and limitations

On the authorized TXZ-W09, the existing USB launch and pinned TLS control
established an authenticated WebRTC offer/answer and selected local UDP candidate
pair. A signed host's actual hardware-required VideoToolbox session produced
ordinary H.264 High 5.2 at 2456×1600; Android's selected HiSilicon hardware
decoder configured at the same size and its exact-size sink received frames.
The pinned Android JNI supplies nullable `VideoDecoder.DecodeInfo`; the Kotlin
hardware decorator must accept it as nullable or an exception aborts the native
decoder thread. The receiver's trickle ledger must mark the remote description
applied before draining control records, otherwise every ICE candidate remains
staged and no UDP pair is formed. Neither SDK's gathering-complete callback is
an authoritative last-candidate notification.

The pinned sender stats can transiently omit **both** frame dimensions (0/0)
even after encoding frames; a partial or nonzero wrong-size report remains fatal,
and exact geometry is additionally checked at the encoder input and Android
decoded-frame sink. The optional VT low-latency-rate-control creation flag made
the hardware-selection property unavailable on this Mac; the RTC session uses
hardware-required VT, real-time and disabled reordering, then confirms hardware
selection. An SDK rate-control request of 61 fps is capped at the physical
60 fps mode, not treated as hardware failure.
The pinned macOS `RTCVideoEncoder` bridge declares `setBitrate(uint32_t,
uint32_t)` without a nonzero precondition; the five-minute device trial
observed zero pause requests, but this does not prove they are unreachable.
If either SDK rate is zero the custom encoder pauses admission without sending
invalid zero VT properties, and a positive resume reapplies VT rates and latches
an IDR. A focused actual hardware-session pause/resume test covers this contract.

Initial 90-second synthetic-only owned-display trials delivered about 30 fps.
With the pinned SDK transceiver's explicit 20 Mbit/s / 60 fps ceilings (not a
forced bitrate or congestion-control override), a subsequent 300.27-second
same-tablet trial generated 18,017 owned-display ticks; host accepted 12,682
hardware VT frames and Android received 12,561, decoded 12,556 and accepted
12,546 exact-size frames near the end. VT credit drops were zero, but achieved
motion cadence remains about **42 fps**, not 60 fps. Native SDK frame dimensions
may transiently read 0/0 as described above; the input/sink geometry checks
remain authoritative.

Repeated short-session heartbeat failures were traced to Android's RTC-only
`100 ms` `withTimeoutOrNull { inbound.receive() }`. A Ping was framed by the
authenticated TLS reader and sent into the coroutine Channel, then its
`onUndeliveredElement` fired when the timed receive was cancelled before
dispatch. The owning RTC read loop now atomically selects receive versus
timeout; the five-minute motion trial stayed Connected, then explicit Stop and
reconnect remained Connected another 35 seconds. This validates that single
physical reliability gate, **not** 30-minute endurance, roaming/unplug, or
other networks. Android native stats remain on a separate monitor, not the
control reader. The encoder retains one admission credit until SDK delivery
or discard, including successful VT frame-dropped callbacks; stop drains
delivery and retires late opaque callback tokens.

The legacy host `MetricsCollector` is not wired to this RTC pipeline;
its displayed 0 fps is not RTC evidence. Use bounded native outbound/inbound
and exact-size sink counters. No matched cross-device frame-age/photons,
subjective fidelity, 60 fps, input parity, or latest matched TCP/USB latency
acceptance is established. Keep RTC behind its explicit test route and
preserve the existing TCP comparison and USB media.

Android's RTC renderer owns decoded frame/texture presentation. Keep the existing
USB renderer intact; make surface attach/detach, rotation and activity teardown
explicit. The earlier USB local-timestamp experiment is unrelated and must not be
silently accepted, reverted or used as evidence for RTC presentation behavior.

### Lifecycle

Use the existing session/attempt identity as the sole authority. SDK callbacks
must be marshaled to that owner and ignored after the attempt is invalidated.
Resources join the attempt before asynchronous work can outlive it. Stop invalidates
callbacks, stops capture, closes the peer connection, releases renderer/codec
resources, closes control and releases input/display resources in a defined order.
Stop/retry must not overlap old capture or decoder teardown. Establish bounded
negotiation/connection deadlines and fail explicitly on hardware or signaling errors.

## Delivery stages and exclusive ownership

This is multi-seam work: wire contract, macOS media, Android media, then integration.
The working tree contains substantial existing uncommitted work. Preserve it;
do not stash, reset or commit it to manufacture worktree isolation. Run component
writers **sequentially** in the repository root, with one writer
at a time, fresh contexts and durable handoffs. Parent performs final acceptance.

| Lane | Exclusive responsibility | Gate / handoff |
| --- | --- | --- |
| Contract | `protocol/` RTC signaling specification, new dependency lock/provenance document and dependency feasibility probes; no application implementation | Exact usable Apple/Android artifacts and APIs; bounded wire schema, lifecycle sequence, fixtures and commands documented before platform work |
| macOS | `macos-host/` RTC dependency/build integration, capture/source, hardware encoding, peer connection, host signaling and focused tests | Compile/type/lint and behavioral checks; changes and SDK limitations documented |
| Android | `android-client/` RTC dependency/build integration, decoder selection/rendering, client signaling/lifecycle and focused tests | Compile/lint/unit checks; hardware-only selection and teardown evidence documented |
| Integration | Only cross-platform wiring corrections, tools, documentation and validation after both component handoffs; no substitute media implementation | One broad final validation pass, actual-device smoke/measurements where available, explicit acceptance or blocker |

Each lane records baseline state and its own changed files, applicable tests,
consequential choices, unresolved risks and durable report. Stop dependent stages
on failed infrastructure or a blocked contract; ask the parent for consequential
changes rather than replacing libwebrtc with another library. Pin artifact versions
and checksums/provenance. Do not check binary SDKs into Git. Verify macOS support,
architectures, minimum versions, H.264 capability and dependency licensing before
committing to a distribution. Avoid a full Chromium source build unless needed;
escalate its resource cost before starting it.

## Validation and completion

Test malformed/stale signaling, negotiation failure, stop during setup, renderer
loss and reconnect at the owning boundaries. Preserve USB tests. Use existing
measurement tooling where meaningful; RTC stats and decoder/compositor timing are
not interchangeable with physical display latency. Real-device checks use owned
synthetic content, not the user's working desktop. Do not change global network
settings, permissions, or disrupt other applications. Coordinate device installs
and measurements with the parent; no benchmarks during heavy builds.

The first delivery is a working, authenticated native WebRTC media path with
documented hardware/latency evidence or an explicit blocked gate—not scaffolding
reported as completion. Keep the old network video backend only as an explicitly
named comparison path during validation; deletion gate is accepted RTC parity and
latency results. No silent fallback. Update documentation to match what actually
works, and remove superseded network-only paths when that gate passes.

The target follow-on connection layer is Bonjour/NSD discovery plus persistent,
reviewed pairing, manual endpoint fallback and authenticated signaling without
USB. This remains separately sequenced after media feasibility, not forgotten or
represented as implemented by retaining USB bootstrap. Internet relays, multi-peer
streaming, audio, and new codec families are outside this delivery.
