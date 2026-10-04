# Mirri wire protocol 1.0 (normative)

The terms MUST, MUST NOT and SHOULD are normative. All integers are big-endian;
`u8/u16/u32/u64` are unsigned, `i32` is two's-complement, `f32` is IEEE-754
binary32 (big-endian bits). No alignment, padding, JSON, implicit fields or
native-size integers exist. The schema below is also the canonical field order.
Both applications MUST reject an invalid record before passing it to session
logic. Tests use synthetic values; fixtures contain no real device identifiers.

## Frame and transport

Exactly 32 bytes precede every payload: ASCII `MRRI` (4), major `u16=1`,
minor `u16=0`, type `u16`, flags `u16=0`, per-connection direction-local
sequence `u64`, payload length `u32`, sender monotonic timestamp `u64` in ns.
Sequence starts at zero separately in each direction of each TCP connection;
it increases by one including messages subsequently ignored. It MUST NOT wrap.
The header sequence is independent of InputBatch.batchSequence, Ping
probeSequence and VideoFrame.frameSequence. An unknown ignorable message
still advances the header sequence for its direction.
Timestamps and event times are in the sender's monotonic clock domain, never
compared across devices. Video PTS is ns since the first captured frame in the
current configuration generation, rather than a wall clock. Duplicate or
out-of-order sequence is a fatal channel error. Header flags other than zero
are invalid in v1. Major mismatch is fatal. A higher minor version may include
unknown types: only types with bit 15 set (`0x8000..0xffff`) may be skipped,
after checking channel cap and reading their payload. Unknown types with bit
15 clear, unknown enum values, nonzero flags and extra bytes are errors even
at a newer minor. A lower minor version is accepted if its known messages
validate. Known messages never change layout within major 1; additions need
new type IDs. No unknown type may authenticate a connection. The incremental
framers report a skipped type with its header sequence; receivers advance
their per-direction order checker only after a valid authenticated first
message. Type IDs 23..32767 are reserved and fatal until assigned by a future
registry; 32768..65535 are reserved for ignorable higher-minor extensions.

Two separate TCP connections use `adb reverse`: host listeners bind ONLY
`127.0.0.1:5560` (video) and `127.0.0.1:5561` (control); Android connects to
its loopback ports. One authenticated connection of each kind per live epoch;
reject duplicates rather than evicting the incumbent. A reader assembles the
32-byte header first, validates its cap, then reads exactly payload length
bytes; EOF in either part is an error. Control payload <= 1,048,576 bytes,
video frame payload <= 16,777,261 bytes (16,777,216-byte access unit plus
the 45-byte frame prefix), all other video messages <= 65,536
bytes. Message-specific bounds below take precedence. Partial writes and
coalesced frames do not alter the record boundary. No network listener binds
to a public interface; the bearer token does not encrypt traffic or protect
against a compromised local host/device process.

## Scalar and aggregate grammar

`bytes(N)` = `u16` byte length followed by at most N bytes, except `bytes32`
and `bytes16` which are *exactly* 32 and 16 raw bytes (no prefix). `str(N)` =
`u16` byte length then at most N bytes of strictly valid UTF-8, with no BOM,
NUL, or Unicode control characters; not a device serial or identifier.
`list(N){...}` = `u8` element count then records, at most N. `bool` is u8
exactly 0 or 1. Every record MUST consume its entire declared payload.
Non-finite floats and out-of-range values are errors. The pure codecs validate
shape and scalar range; stateful sequencing and authorization belong to the
connection/session owners.

Aliases: `size={width:u32,height:u32}` both positive <= 8192;
`mode={size,refreshMilliHz:u32,modeId:i32}` refresh in 1..240000;
`profile={profile:u8,level:u16}`; AVC `level` is H.264 `level_idc`
(51 for Level 5.1 in the initial profile); HEVC `level` is HEVC
`general_level_idc` (153 for Level 5.1). Selection requires an actual hardware
configure/probe at the exact rate, not merely matching this number.
`codecCap={codec:u8,
profiles:list(16){profile},exactSizeRateSupported:bool,
lowLatencySupported:bool,hardwareAccelerated:bool}`;
`lowLatencySupported` reports an optional decoder feature; it is not a
condition for admitting an otherwise exact, hardware-backed decoder. Enable
the decoder's low-latency mode only when the feature is supported.
`inputs={maxTouchPoints:u8,hasPen:bool,hasPressure:bool,hasTilt:bool,
hasHover:bool,hasPenAuxiliaryKey:bool}` (maxTouchPoints 1..10).
`point={x:f32[0,1],y:f32[0,1]}`; `time=u64` monotonic ns;
`gesturePhase=u8` 1 began, 2 changed, 3 ended, 4 cancelled.
`sample={pointerId:u32,tool:u8,phase:u8,point,pressure:f32[0,1],
tiltRadians:f32[-pi/2,pi/2],orientationRadians:f32[-pi,pi],
buttonMask:u16,eventTimeNs:time}`. Button bits: bit0 primary, bit1
secondary, bit2 pen barrel; all other bits MUST be zero. Tilt and orientation
use radians; unavailable measurements are 0. Positive X points right,
positive Y down in *landscape* normalized display coordinates.
InputBatch.batchSequence starts at zero per connection epoch and increments
by one for each batch (other control messages do not advance it). Samples are
in original event-time order, including copied Android historical samples;
the session input owner, not the stateless byte codec, checks pointer phase,
button release and monotonic sample times.

Enums (only listed numbers valid): codec 1 AVC, 2 HEVC; profile 1 AVC High,
2 HEVC Main; color 1 SDR 8-bit 4:2:0 with BT.709 primaries and YCbCr matrix,
IEC 61966-2-1 sRGB transfer, video/limited range (luma 16–235, chroma
16–240). An endpoint that cannot encode/decode this declared colorimetry
must reject negotiation, not silently substitute HDR or wide/full range;
inputMode 1 directTouch; tool 1 finger, 2 pen, 3 eraser; pointer phase 1
hoverEnter, 2 hoverMove, 3 hoverExit, 4 down, 5 move, 6 up, 7 cancel;
context source 1 longPress, 2 twoFingerTap, 3 penButton;
shortcut action 1 missionControl, 2 previousSpace, 3 nextSpace,
4 showDesktop, 5 custom; key phase 1 down, 2 up; rejection reason
1 exactMode, 2 hardwareCodec, 3 surface, 4 authorization, 5 protocol;
stop reason 1 user, 2 disconnect, 3 failure, 4 shutdown;
error code 1 malformed, 2 version, 3 unauthorized, 4 incompatibleMode,
5 hardwareUnavailable, 6 invalidState, 7 decoderFailed, 8 timeout.

## Message registry

Each line specifies type ID, direction, channel, and ordered payload. `H>C`
means host to client; `C>H` means client to host. No other direction or channel
is legal. `epoch:u32` is the connection incarnation, starting at 1 and
incremented on reconnect within a session. `sessionId:bytes16` is an opaque
cryptographically random session ID stable only through reconnect grace;
`sessionToken:bytes32` is a separate 256-bit CSPRNG value passed only in the
explicit launch intent, compared in constant time, never logged or persisted,
and invalidated at terminal stop/grace expiry. The token is repeated in both
hello messages. Every post-hello message carries sessionId and epoch (the
shared envelope below); a hello instead carries epoch and its authentication
fields. Records with old epochs are discarded; epochs cannot wrap.

For all messages except 1 and 4, payload begins `sessionId:bytes16,epoch:u32`
before the listed fields. Both pure codecs include these fields. Empty bodies
therefore have a 20-byte payload. ClientHello MUST be the first client control
message and VideoChannelHello MUST be the first client video message.
SessionConfig or an explicit fatal ProtocolError is the first host control
message; CodecConfiguration is the first host video message (after video
authentication and readiness). No other traffic is admitted beforehand.

| ID | Name | Direction/channel | Fields after common prefix (or complete hello payload) |
|---|---|---|---|
| 1 | ClientHello | C>H control | epoch:u32,sessionToken:bytes32,deviceName:str(64),nativePixelSize:size,densityDpi:u32,activeDisplayMode:mode,displayModes:list(16){mode},codecCapabilities:list(2){codecCap},inputCapabilities:inputs |
| 2 | SessionConfig | H>C control | codec:u8,profile:u8,level:u16,pixelSize:size,refreshMilliHz:u32,bitrateBitsPerSecond:u32,color:u8,videoPort:u16,inputMode:u8,cursorIncluded:bool |
| 3 | ClientReady | C>H control | selectedDisplayMode:mode,decoderName:str(96),actualSurfaceSize:size |
| 4 | VideoChannelHello | C>H video | epoch:u32,sessionId:bytes16,sessionToken:bytes32 |
| 5 | CodecConfiguration | H>C video | generation:u32,codec:u8,profile:u8,level:u16,color:u8,parameterSets:list(3){bytes(4096)} |
| 6 | VideoFrame | H>C video | generation:u32,frameSequence:u64,presentationTimeNs:u64,frameFlags:u8,accessUnit:bytes32length(16777216) |
| 7 | StartStream | H>C control | generation:u32 |
| 8 | StopSession | H>C control | reason:u8 |
| 9 | InputBatch | C>H control | batchSequence:u64,samples:list(64){sample} |
| 10 | ScrollGesture | C>H control | gesturePhase:u8,point,deltaX:f32[-4096,4096],deltaY:f32[-4096,4096],eventTimeNs:time |
| 11 | ZoomGesture | C>H control | gesturePhase:u8,point,scaleDelta:f32[0.25,4],eventTimeNs:time |
| 12 | ContextClickGesture | C>H control | point,source:u8,eventTimeNs:time |
| 13 | ShortcutGesture | C>H control | action:u8,eventTimeNs:time |
| 14 | AuxiliaryKey | C>H control | androidKeyCode:u32,scanCode:u32,keyPhase:u8,eventTimeNs:time |
| 15 | Ping | H>C control | probeSequence:u64,sentNs:u64,receivedNs:u64,repliedNs:u64 |
| 16 | Pong | C>H control | probeSequence:u64,sentNs:u64,receivedNs:u64,repliedNs:u64 |
| 17 | ClientMetrics | C>H control | receivedFps:f32[0,240],receivedBitsPerSecond:u32,decoderInputFps:f32[0,240],decoderOutputFps:f32[0,240],selectedDisplayMode:mode,videoQueueDepth:u8,droppedFrames:u64 |
| 18 | ProtocolError | both control | code:u8,safeMessage:str(128),fatal:bool |
| 19 | DecoderFailure | C>H control | code:u8 |
| 20 | RequestKeyframe | C>H control | generation:u32 |
| 21 | SessionRejected | C>H control | reason:u8,safeMessage:str(128) |
| 22 | StopAcknowledged | C>H control | (no fields) |

Ping sends its probeSequence and host send time; `receivedNs` and `repliedNs`
are zero. Pong copies probeSequence and sentNs, sets client receive time
and client reply time. The host measures its fourth time locally when Pong
arrives. The clocks have unrelated epochs; do not subtract timestamps across
devices without the full four-time exchange. Responses to fatal errors are
best effort, not a mandatory round trip.

`bytes32length(N)` uses a u32 length and N raw bytes; frame AU must be 1..N
bytes, with no trailing data. Frame flags: bit0 keyframe, bit1 discontinuity;
other bits invalid. Generation must be >= 1. AVC config has SPS then PPS
(exactly two sets), HEVC config has VPS, SPS, PPS (three); each parameter set
has no Annex-B start code, and must contain a complete nonempty NAL. Access
units use Annex-B four-byte start codes, at least one complete NAL, no
length-prefixed NALs; conversion from VideoToolbox replaces each four-byte
length in a reusable bounded buffer. Video payloads are access-unit atomic.
An IDR follows every config before any dependent frame. Reconfiguration
increments generation, sends config, then an IDR with keyframe and
discontinuity bits. Frame sequence starts at 0 per generation and has no
gaps for accepted encoded frames: capture drops *before* encoding do not
consume a frame sequence. A gap/duplicate or generation mismatch triggers
decoder flush and RequestKeyframe, never decoding a dependent frame. Host
restarts generation and sends config+IDR, not a silent P-frame continuation.
The generation counter persists across video connection replacement during
one session's reconnect grace; a new session starts at generation 1. A pure
receive-order checker is initialized with the previous generation on reconnect
and requires the next configuration to increment it by one.

SessionConfig MUST specify 2456x1600, 60000 mHz, color=1, videoPort=5560,
inputMode=1, bitrate AVC 20..80 Mbit/s (initial 40 Mbit/s) or HEVC 25..80
Mbit/s, hardware-backed profile/level supported on *both* endpoints.
Client physical mode is 1600x2456 at 60000 or 120000 mHz (panel refresh only;
the stream stays 60000 mHz); modeId is local diagnostic
only. ClientReady MUST reflect a readback of the active mode, actual surface
2456x1600, and decoder configured on that surface. No codec fallback, scaling,
HDR, or software conversion is implied by capability advertisement. If exact
mode or actual hardware codec setup fails, SessionRejected terminates startup.

## State and resource rules

Listener and both *owned* reverse mappings precede launch; rollback a partial
mapping setup without removing someone else's mappings. Authenticate
ClientHello, verify exact mode and hardware codec, create/verify virtual
display, send SessionConfig; select/read back physical mode and configure
decoder against actual Surface; authenticate VideoChannelHello and accept
ClientReady before StartStream/config/IDR. Input is enabled only after
streaming. Never start capture with an unverified surface. Every failed
acquisition unwinds in reverse order by its resource owner; stale callbacks
cannot revive stopped resources. Reconnect first invalidates old connections,
then uses a *new epoch*, retaining token/session ID only for bounded grace.
Surface loss releases decoder on its owning thread. StopSession is best-effort:
stop input admission and release held synthetic buttons immediately, stop
capture then bounded encoder work, close video, await StopAcknowledged only
for a bounded interval and clean up idempotently. No unbounded socket writes,
buffers or callback waits.

Pointer ID is stable from down to up/cancel (hover enter to hover exit for
hover), may be reused only after release; duplicate down, move/up without
down, out-of-order event times, or duplicate batchSequence are errors. Cancel
releases every held button for that pointer; disconnect releases *all* held
buttons. In a batch event times are nondecreasing. Critical down/up/cancel,
gesture phase transitions and lifecycle writes are never discarded when the
bounded control queue fills; apply backpressure or end the session. Only
adjacent unsent moves of the same pointer may be coalesced without crossing a
state transition. Scroll deltas are pixels (positive X right, positive Y
down); zoom is multiplicative, 1 neutral, and defaults to accumulated
Command-plus/minus; zero scroll and neutral zoom are permitted. Mac input
injection maps coordinates to the active display rectangle and clamps edges.
Errors carry safe static text only, never tokens, serials, paths, pixels or
precise drawn trajectories. Fatal ProtocolError closes the session; nonfatal
requests resynchronization of that channel only. Repeated malformed input
terminates the session. DecoderFailure allows one same-codec reconfigure;
another failure terminates. Host increments generation for recovery and
sends config+IDR; RequestKeyframe cannot silently reset generation.

## Fixture contract

`fixtures/*.bin` are whole framed messages with synthetic values and header
sequence 0, monotonic timestamp 0. Each registered type has one fixture, plus
HEVC negotiation and configuration variants; both
production codecs must parse and re-encode each byte-for-byte. Fixtures prove
wire agreement, not platform readiness. Synthetic parameter sets and the
sample access unit exercise NAL framing/headers; they are not media files or
decodable pictures. Tests additionally exercise malformed
length, enum, UTF-8, float, trailing bytes, flags, version, fragmentation,
skippable types, sequence and generation policy. The pure codecs deliberately
do not manage sockets, ownership, or hardware.
