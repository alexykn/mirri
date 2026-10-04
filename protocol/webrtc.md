# Mirri native WebRTC signaling 1 (normative extension)

This extension is **only** for an explicitly selected `RTC` media attempt. It
does not change `protocol.md`'s USB or existing TCP-video records, ports,
capabilities, or state machine. The terms and scalar encodings in `protocol.md`
apply except where overridden below. Implementations MUST add the new IDs to
the control-channel registry; an old parser's rejection of ID 23 is intentional,
not an invitation to reinterpret it as ignorable. No RTC message is sent on the
video socket, nor is any video sent on the control connection. RTC media uses a
real libwebrtc video track (RTP/RTCP over ICE/DTLS-SRTP), not a data channel.

## Selection and authentication

The host explicitly selects RTC for this attempt **before** launching the
client. The launch/bootstrap mode and host attempt owner are local state, not a
new unauthenticated wire hint. The existing USB-delivered credential, pinned
TLS server verification, network epoch preface and authenticated `ClientHello`
(type 1) remain the first control steps, in that order. For the USB-assisted
network launch preserve
`mirri_mode=network`, `mirri_host`, `mirri_pin` and existing token/epoch extras.
An RTC-selected launch additionally requires string extra `mirri_session_id`,
the host's current session ID encoded as exactly 32 lowercase hex characters
(16 bytes); it remains the same across reconnect epochs for that session.
The client rejects missing/malformed IDs. This bootstrapped context is not
authentication: pinned TLS, token and epoch checks still precede signaling,
and every inbound RTC session ID must equal this value.
An explicitly RTC-selected launch additionally supplies string extra
`mirri_media=rtc`; absence means the comparison TCP path. Android MUST reject
unknown `mirri_media` values instead of treating them as TCP. This is local
selection, not authentication. Keep RTC selection unavailable in production UI
until both endpoints implement the bootstrap and the hardware gate passes.
Never send RTC signaling
until TLS pin and hello token/session ID/epoch are verified. `ClientHello` is
byte-for-byte unchanged, including its existing codec capability list; that
list describes the legacy byte-stream decoder and does **not** authorize an
RTC profile. The RTC-selected client sends `RtcCapabilities` immediately after
`ClientHello`; the RTC-selected host waits for it, not `SessionConfig` (2).
Neither side treats an absent/invalid RTC capability or an old host's
`SessionConfig` as permission to switch to TCP/USB video. Fail the RTC attempt
explicitly. Conversely the USB and comparison TCP paths retain their existing
hello/config/video-channel sequences; never send these new records to them.

Retain header major=1, minor=0, flags=0 and the 32-byte header, endian,
sequence and timestamp rules in `protocol.md`. Assign IDs 23–31 below to the
RTC-selected **control** channel only (these previously reserved values are
now allocated by this extension). Reject them on USB, legacy network, video,
wrong direction or before authenticated hello. Type IDs >=32768 still obey the
existing future-minor ignorable rule; none may affect negotiation or auth.
The existing `sessionId:bytes16,epoch:u32` prefix starts every RTC record. The
session owner MUST additionally check the current local attempt incarnation,
epoch and RTC attempt ID before delivering callbacks or applying a record.
There is exactly one RTC attempt per epoch; a retry uses a new epoch and new
RTC attempt ID. No automatic in-epoch ICE restart or new offer is defined.

`rtcVersion:u16` MUST equal 1 on **every** RTC record. No range negotiation:
unknown value fails with ProtocolError code 2 (version), fatal=true, then
closes; no fallback. `rtcAttemptId:bytes16` is an unpredictable host-generated
value, distinct from `sessionId`, assigned in `RtcPrepare`. Prior to prepare,
`RtcCapabilities` instead contains a client-generated `clientNonce:bytes16`;
prepare echoes it. Reject a mismatched/duplicate nonce, repeated prepare, or
stale attempt. No tokens, SDP, candidates, or private addresses in logs.

## Payload grammar and limits

The following `utf8(N)` is `u16` length followed by exactly that many bytes,
1..N, strictly valid UTF-8 without BOM or NUL. Unlike `str(N)`, LF and CR are
allowed because SDP contains line endings; no other C0/C1 controls are allowed.
For candidates allow ordinary SDP token characters and space, but no CR/LF.
The pure codec validates lengths and encoding; pass SDP/candidate contents to
the pinned WebRTC API, not a hand-written SDP editor. `mid` uses existing
`str(32)` and MUST be nonempty. `candidate` is the candidate attribute string
as returned by the SDK (including its `candidate:` prefix), without `a=`;
`sdp` is the entire SDK-produced SDP text including its own line endings.
All listed max lengths are bytes, not UTF-16 code units. No trailing bytes,
unknown fields, empty SDP/candidate, extra records or unsupported enum values.
Common prefix is always 20 bytes; `R` below adds `rtcVersion:u16,
rtcAttemptId:bytes16` in that order (total prefix 38 bytes). Candidates carry
`mid` and `mLineIndex:u16` (0..15); both MUST match exactly one previously
negotiated media section. Only one video m-line, with no audio or data m-line,
is accepted in version 1; thus its index MUST be 0. Do not put full frames,
raw pixel data or credential material in any record. Max SDP 32768 bytes,
candidate 2048 bytes, max 64 candidates *per direction per attempt*; max
combined pending remote candidates 64 / 128 KiB before setRemote completes.
Check these limits before allocating, enqueuing, or handing data to the SDK.

| ID | Name | Direction | Payload fields after common prefix |
|---|---|---|---|
| 23 | RtcCapabilities | C>H | rtcVersion:u16,clientNonce:bytes16,codec:u8=1 (H.264),profile:u8=2 (ordinary High),maxLevelIdc:u8 (51..52),hardwareDecoder:bool,exactSizeRateSupported:bool |
| 24 | RtcPrepare | H>C | R,clientNonce:bytes16,codec:u8=1,profile:u8=2,levelIdc:u8 (51..52),pixelSize:size,refreshMilliHz:u32,color:u8=1 |
| 25 | RtcPrepared | C>H | R,selectedDisplayMode:mode,actualSurfaceSize:size,decoderName:str(96) |
| 26 | RtcOffer | H>C | R,sdp:utf8(32768) |
| 27 | RtcAnswer | C>H | R,sdp:utf8(32768) |
| 28 | RtcIceCandidate | both | R,mid:str(32),mLineIndex:u16,candidate:utf8(2048) |
| 29 | RtcIceEnd (optional advisory, not emitted by current endpoints) | both | R,mid:str(32),mLineIndex:u16 |
| 30 | RtcMediaReady | C>H | R (no additional fields) |
| 31 | RtcStart | H>C | R (no additional fields) |

`RtcCapabilities` is an RTC-specific hardware/SDK advertisement and MUST only
claim High with the exact 2456×1600, 60000 mHz decode path if a real hardware
capability probe succeeds. The HiSilicon decoder is **not** automatically
advertised as High by the pinned Android factory; see
`docs/webrtc-dependencies.md` for the restricted adapter required. Profile 1
remains reserved for constrained High (`640c34`) and MUST be rejected by this
first-delivery sender/receiver pair. Profile 2 means ordinary H.264 High
(`profile-level-id=640034`, `packetization-mode=1`), matching the actual
hardware VideoToolbox SPS (`64 00 34`) on this host. Level IDCs 51 (`33` hex)
and 52 (`34` hex) are
permitted *only if both endpoints prove the negotiated level and geometry*.
The initial target is 2456×1600 at 60 Hz, color=1, hardware encode/decode,
one sendonly/recvonly video track. `RtcPrepare` MUST exactly specify this
size/rate and a level <= the probed remote maximum; no substitution of
Constrained Baseline (`42e0`), software codec, lower rate/resolution or
different color mode. The generated offer/answer MUST agree on a High profile
and level that actually supports this size/rate; if the SDK cannot produce it
without SDP rewriting, fail and report the reason. No blind use of SDP
`level-asymmetry-allowed` to assert receiver support for a higher level.
H.264 capability advertisement alone is not successful codec setup: verify
encoder and decoder hardware and actual RTP codec/profile and frame geometry.

## Ordering and lifetimes

All control records share the existing ordered writer and sequence counter;
the network control socket remains pinned TLS. The RTC attempt owns its peer
connection, capture source, renderer, and callbacks before asynchronous work.

1. Authenticated `ClientHello`, then exactly one `RtcCapabilities`. Host checks
   explicit RTC selection, version, geometry/codec authorization and creates
   a fresh attempt ID. Within **5 s** of hello, either send `RtcPrepare` or
   report a fatal error and close. Host may acquire the virtual display and
   verify encoder before prepare, but does not capture or send media yet.
2. Client checks prepare's echoed nonce, supported level, mode, surface and
   hardware decoder; selects/readbacks physical mode and sends `RtcPrepared`
   within **10 s** of prepare. Failed exact setup sends `SessionRejected` (21)
   with a safe static reason and closes. Host checks dimensions/readback and
   admits only then the RTC offer. Host constructs one sendonly H.264 video
   transceiver, no audio/data, configures local-host ICE (no public STUN/TURN),
   and sends `RtcOffer` only after `setLocalDescription` succeeds.
3. Client applies remote offer; creates a recvonly answer, sets local
   description, then sends `RtcAnswer` (within **10 s** of offer). Host sets
   remote answer. Outgoing ICE candidates are staged until **its own** SDP
   message has been written. On receipt, queue remote candidates in wire
   order until remote description completes, then drain through the SDK and
   check each add result. Neither endpoint emits `RtcIceEnd`: the pinned SDK
   can deliver a candidate callback *after* its gathering-complete callback,
   including after a 250 ms quiet period. The callback is therefore not a
   terminal barrier. A received ID 29 is an optional authenticated advisory
   observation (at most once for the video mid); it does not terminate
   candidate admission. Even after this advisory, candidate count/size,
   session/epoch/attempt/mid/index and ordered control checks still apply.
   Duplicate advisory, wrong mid/index, count or pending-budget overflow are
   fatal. The bounded **20 s** connection/ready/start deadline, not an ICE
   end marker or a silent fallback, decides failed setup. On an established
   session the same candidate bounds remain in force until stop; no in-epoch
   ICE restart or renegotiation is introduced. This clarification supersedes
   the earlier mandatory/terminal end marker rule for the unshipped version 1.
4. Client sends `RtcMediaReady` once, only after its remote offer and local
   answer succeeded, renderer/surface are attached, the hardware decoder is
   selected and peer connection is connected via a **UDP** selected pair.
   Host sends `RtcStart` once only after applying answer, receiving ready,
   and observing a connected UDP selected pair and valid H.264 negotiation.
   No media capture before `RtcStart`; then input and video admission open.
   Complete connection and ready/start within **20 s** of offer or fail.
  Monitor selected pair/codec/geometry thereafter; any TCP switch, codec
   fallback, hardware failure or geometry change fails this RTC attempt
   rather than silently degrading. Log only redacted selected pair protocol,
   codec, size and rate, not host candidates/SDP.

Before `RtcStart`, `InputBatch` (9), gestures (10–14), and auxiliary keys are
not admitted, as for existing startup. After start they retain their **exact**
wire encoding, event/held-button semantics, permission checks and bounded
ordered control writer. Input must remain live through ICE signaling: candidate
writers may use at most 64 slots and 128 KiB per direction; give priority to
critical input/lifecycle writes, coalesce only permitted pointer moves, never
drop down/up/cancel. If bounded control backpressure cannot preserve input,
fail the attempt rather than allowing unbounded signaling to displace it.
Existing Ping/Pong may remain enabled; legacy video metrics, generation and
keyframe messages 3–7, 17, 19–20 are invalid on RTC. StopSession (8),
StopAcknowledged (22) and ProtocolError (18) retain their wire schema and
existing best-effort semantics. Existing SessionRejected (21) can report
pre-start exact hardware/surface/authorization failure. No RTC renegotiation
or retry is implied by any legacy decoder failure/keyframe request.

Malformed payload, unauthorized direction, unexpected order/state, stale
attempt, SDK signaling rejection, or hardware failure terminates the RTC
attempt; safe static `ProtocolError` (18: code 1 malformed, 2 version, 5
hardwareUnavailable, 6 invalidState, 8 timeout) or `SessionRejected` (21) is
best effort if authenticated, not a required acknowledgment. Old epochs are
discarded after valid framing and sequence accounting, as in `protocol.md`;
records with the current epoch but wrong attempt ID are fatal. No logs of
payloads. On stop/failure invalidate attempt first; stop admitting input,
release held keys/buttons, stop capture, close peer connection and renderer,
then close control and display after bounded cleanup. Retry uses a new epoch
and newly authenticated hello; never replay SDP/candidates across attempts.

## Boundary tests required of the platform owners

Byte-for-byte cross-platform encode/decode for IDs 23–31, with synthetic
session/attempt IDs and SDP/candidate text; reject truncated header/length,
oversized SDP, invalid UTF-8, extra bytes, wrong direction, lower/higher
version, current-epoch wrong attempt ID, stale epoch, candidate-before-SDP,
candidate delayed past the SDK gathered callback (and after an advisory ID 29),
>64 candidate entries and connection/ready/start timeout. Test
prepared-before-offer, answer-before-start, stop during setup, wrong profile,
input transitions during candidate bursts, and USB existing fixtures without
any byte changes. Pure wire fixtures do not prove actual hardware readiness.
