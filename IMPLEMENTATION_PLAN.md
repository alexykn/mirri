# Mirri implementation plan: TXZ-W09 touch-enabled second display

## 1. Goal and fixed first-release scope

Build a local, USB-connected second-display system for the existing TXZ-W09
and Apple Silicon Mac. macOS must see a real extended display, render it at the
tablet's full landscape resolution, stream it to the tablet, and accept direct
touch input from the same surface.

The first release has these fixed requirements:

- native video backing size: **2456×1600** in landscape;
- virtual-display and stream target: **60 Hz / 60 fps**;
- transport: USB through `adb reverse`, with no Wi-Fi implementation yet;
- direct one-finger touch, tap, drag, two-finger scroll and configurable zoom;
- M-Pencil position and button support where the Android application exposes
  it; pressure and tilt remain in the protocol but are not release gates;
- sRGB, SDR, 8-bit video;
- automatic recovery from an application restart or temporary USB disconnect;
- explicit metrics showing the resolution, refresh mode and achieved frame
  rate at every pipeline stage.

The initial measured configuration is hardware AVC at 40 Mbit/s. The host may
offer an explicit 20–80 Mbit/s AVC setting and a hardware HEVC alternative
starting at 25 Mbit/s, but bitrate or codec changes never change the fixed
2456×1600 backing size. Automatic quality adaptation is deferred until the
fixed USB pipeline has measurements that justify it.

The first release does **not** include audio, HDR, portrait rotation, remote
Internet access, file transfer, a Bluetooth tablet mode, a generic Android
device matrix, or native macOS three/four/five-finger trackpad injection.
Existing touch and pen capability tests are authoritative and will not be
repeated as hardware reconnaissance.

### 1.1 Existing evidence accepted as an input contract

The implementation starts from the curated evidence already in the repository:

- `../txz-recon/reports/input-map.md` identifies the touch, pen and auxiliary
  M-Pencil endpoints and their capabilities;
- `../txz-recon/sanitized/touch-trials-20260924.md` records five simultaneous
  contacts for about 2.52 seconds across 303 consecutive five-contact frames,
  plus a separate two-finger pinch/spread capture with 436 two-contact frames;
- `../txz-recon/sanitized/pen-trials-20260924.md` records live X/Y, pressure and
  both tilt axes, including 364 distinct pressure values in 367 updates and a
  maximum observed pressure of 16,375 out of 16,384;
- the same pen report records the side double-tap as `KEY_F20` with scan code
  `0007006f` on the M-Pencil auxiliary keyboard endpoint;
- the dedicated hover capture recorded no events, so hover is not a required
  or assumed feature.

Integration tests may verify coordinate mapping and application delivery, but
they must not repeat contact-count, raw-pressure, tilt or physical gesture
reconnaissance already established by these records.

#### Capture path index

The following paths are relative to this `mirri/` repository. The files under
`../txz-recon/raw/` contain private device records: Mirri may read them locally
for engineering reference but must not copy, stage, commit, publish or upload
them. Curated sanitized summaries may be linked but do not become Mirri source
files.

| Evidence | Existing path | Established fact used by Mirri |
| --- | --- | --- |
| Static input enumeration | `../txz-recon/raw/20260924T163757Z/input-devices.json` | Identifies the touch, pen, keyboard, M-Pencil auxiliary and physical-button event devices present during enumeration. Event numbers are not treated as stable runtime identifiers. |
| Static pen capabilities | `../txz-recon/raw/20260924T163951Z/pen-capabilities.json` | Pen advertises X/Y, pressure 0–16,384, tilt X/Y −90..90, `BTN_TOUCH`, `BTN_DIGI` and `BTN_STYLUS`. |
| Static accessory capabilities | `../txz-recon/raw/20260924T163951Z/keyboard-capabilities.json` | Records the Bluetooth HID capabilities of the keyboard and M-Pencil auxiliary endpoints. |
| First multitouch trial | `../txz-recon/raw/20260924T174455641609Z/touch-multifinger.json` | Live one-, two-, three- and four-contact frames plus position, pressure, major/minor and orientation samples. The attempted five-finger swipe in this particular capture reached four contacts and is not the five-contact proof. |
| First touch endpoint identity | `../txz-recon/raw/20260924T174455641609Z/event-identity-event1.json` | Captures the `input_mt_wrapper` identity and advertised ranges used to interpret the first touch stream. |
| Dedicated five-contact hold | `../txz-recon/raw/20260924T174651821738Z/touch-multifinger.json` | 303 five-contact frames in one contiguous run lasting about 2.52 seconds; authoritative five-contact evidence. |
| Five-contact endpoint identity | `../txz-recon/raw/20260924T174651821738Z/event-identity-event1.json` | Confirms the touch endpoint used for the dedicated five-contact capture. |
| Dedicated pinch/spread | `../txz-recon/raw/20260924T182059405241Z/touch-multifinger.json` | 436 two-contact frames; pairwise distance contracted from about 8,560 to 1,296 raw units and expanded to about 10,540. |
| Pinch endpoint identity | `../txz-recon/raw/20260924T182059405241Z/event-identity-event1.json` | Confirms the touch endpoint used for the pinch/spread capture. |
| Pen hover trial | `../txz-recon/raw/20260924T170438544544Z/pen-hover.json` | Zero event lines during the bounded hover action; Mirri must not require hover. |
| Pen contact trial | `../txz-recon/raw/20260924T170506953545Z/pen-touch.json` | 10,008 events with changing X/Y, 2,434 pressure samples and live tilt samples. |
| Pen tilt trial | `../txz-recon/raw/20260924T170533134028Z/pen-tilt.json` | Both tilt axes changed during the owner-directed action; pressure also varied. |
| Pen pressure trial | `../txz-recon/raw/20260924T171504975618Z/pen-pressure.json` | 367 pressure samples, 364 distinct values and observed range 0–16,375. |
| Pen-button trial on digitizer endpoint | `../txz-recon/raw/20260924T170602360133Z/pen-button.json` | No events on `huawei,ts_pen`; the side gesture is not assumed to be a digitizer button. |
| Pen-button trial on M-Pencil mouse endpoint | `../txz-recon/raw/20260924T171907995296Z/pen-button.json` | No events on the M-Pencil mouse endpoint even though the owner observed the tablet action. |
| Pen-button trial on M-Pencil keyboard endpoint | `../txz-recon/raw/20260924T172136175158Z/pen-button.json` | `KEY_F20` plus scan code `0007006f`; 22 down and 22 up transitions in the bounded action. |
| Display modes | `../txz-recon/raw/20260924T182637919402Z/display-modes.json` | Internal panel is 1600×2456 with 60, 90 and 120 Hz modes; landscape application space is 2456×1600. The first Mirri release intentionally selects 60 Hz. |
| Curated touch summary | `../txz-recon/sanitized/touch-trials-20260924.md` | Privacy-safe aggregate interpretation of the three live touch captures. |
| Curated pen summary | `../txz-recon/sanitized/pen-trials-20260924.md` | Privacy-safe aggregate interpretation of the live pen and auxiliary-button captures. |
| Consolidated input map | `../txz-recon/reports/input-map.md` | Authoritative high-level input map and caveats. |
| Hardware map | `../txz-recon/reports/TXZ-W09-hardware-map.md` | Display, GPU, USB, touch, pen and wider hardware context; not an application API contract unless repeated above. |

The first implementation should use the existing open-source Android display
project only as a source reference. Its virtual-display declarations, display
lifecycle findings, ADB discovery and some input handling are useful. Its
streaming pipeline is not accepted unchanged because it captures BGRA, defaults
to 60 fps at 15 Mbit/s, allocates/copies encoded frames, uses synchronous
decoder handling, and exposes HEVC on the host while the Android decoder path
is hardcoded to AVC.

## 2. Technology decisions

### 2.1 macOS host

- **Swift 6** for the application, orchestration, protocol, networking,
  capture, encoding, input injection and diagnostics.
- A small **Objective-C shim** for the private CoreGraphics virtual-display
  classes. No other Objective-C production logic.
- An ordinary unsandboxed `.app` bundle. Screen Recording and Accessibility
  permission are bound to the application identity and must survive relaunch.

Apple frameworks:

- `ScreenCaptureKit` for display-only capture;
- `VideoToolbox` for hardware AVC and HEVC encoding;
- `CoreMedia` and `CoreVideo` for frame buffers and timing;
- `CoreGraphics` / Quartz Event Services for pointer, scroll, keyboard and pen
  event injection;
- `AppKit` for the menu-bar UI, permissions and lifecycle;
- `Network.framework` for loopback TCP listeners and connections;
- `Metal` only if ScreenCaptureKit cannot supply an encoder-compatible NV12
  buffer directly;
- `OSLog` for structured local diagnostics.

### 2.2 Android client

- **Kotlin**, Gradle Kotlin DSL and JDK 17.
- One Android application module. Use cohesive packages rather than creating a
  Gradle module for every responsibility.
- API 31 is the known target. `minSdk` may be 30 to retain
  `Surface.setFrameRate`; compatibility below that is not a requirement.

Android APIs:

- `SurfaceView` and its `Surface` for direct decoder output;
- `MediaCodec` in asynchronous callback mode;
- `MediaCodecList` and `VideoCapabilities` for codec negotiation;
- `DisplayManager`, `Display.Mode`,
  `WindowManager.LayoutParams.preferredDisplayModeId` and
  `Surface.setFrameRate` for explicit 60 Hz selection and verification;
- `MotionEvent`, `VelocityTracker` and a small owned gesture state machine for
  touch and pen;
- `SocketChannel` and direct `ByteBuffer`s for framed protocol I/O;
- AndroidX Core, Activity/AppCompat and Lifecycle;
- Kotlin coroutines for session lifecycle and control-plane work, not one
  coroutine per frame.

Do not use Compose, `TextureView`, FFmpeg, GStreamer, WebRTC, WebSockets,
HTTP/JSON framing, protobuf, software video decoding or CPU color conversion
in the first implementation.

### 2.3 Python

Python is limited to offline benchmark and log-analysis tools managed through
the repository's `uv` environment. It is not part of either live application.

## 3. Repository and module layout

The `mirri/` directory is its own Git repository. Reconnaissance remains under
the parent repository's `txz-recon/` directory and is referenced rather than
copied.

```text
mirri/
├── README.md
├── protocol/
│   ├── protocol.md
│   └── fixtures/
│       ├── client-hello-v1.bin
│       ├── session-config-v1.bin
│       ├── input-batch-v1.bin
│       └── video-header-v1.bin
├── macos-host/
│   ├── MirriHost.xcodeproj
│   ├── App/
│   │   ├── AppDelegate.swift
│   │   ├── StatusMenuController.swift
│   │   ├── PermissionsController.swift
│   │   └── HostSettings.swift
│   ├── Core/
│   │   ├── Model/
│   │   ├── Session/
│   │   ├── Device/
│   │   ├── Display/
│   │   ├── Streaming/
│   │   ├── Transport/
│   │   ├── Input/
│   │   └── Observability/
│   ├── VirtualDisplayShim/
│   │   ├── CGVirtualDisplay.h
│   │   ├── CGVirtualDisplayDescriptor.h
│   │   ├── CGVirtualDisplayMode.h
│   │   ├── CGVirtualDisplaySettings.h
│   │   ├── VirtualDisplayController.h
│   │   └── VirtualDisplayController.m
│   └── Tests/
│       ├── ProtocolTests/
│       ├── SessionTests/
│       ├── InputTests/
│       └── StreamingTests/
├── android-client/
│   ├── settings.gradle.kts
│   ├── build.gradle.kts
│   ├── gradle.properties
│   └── app/
│       ├── build.gradle.kts
│       └── src/
│           ├── main/
│           │   ├── AndroidManifest.xml
│           │   ├── java/dev/mirri/client/
│           │   │   ├── MainActivity.kt
│           │   │   ├── model/
│           │   │   ├── session/
│           │   │   ├── protocol/
│           │   │   ├── transport/
│           │   │   ├── display/
│           │   │   ├── video/
│           │   │   ├── input/
│           │   │   └── diagnostics/
│           │   └── res/
│           ├── test/
│           └── androidTest/
└── tools/
    ├── benchmark_transport.py
    ├── summarize_session.py
    └── compare_protocol_fixtures.py
```

The macOS project has three build targets, not a target for every directory:

1. `MirriHost`: application target;
2. `MirriHostCore`: Swift library containing the testable host behavior;
3. `VirtualDisplayShim`: Objective-C library owning private-API interaction.

The Android project initially has one application module. Its package
boundaries establish ownership without paying multi-module Gradle build cost.

## 4. Ownership rules

Each runtime resource has one authoritative owner.

### Host

- `SessionCoordinator` owns the host session state and all transitions.
- `VirtualDisplayManager` owns the `CGVirtualDisplay` object and display ID.
- `CapturePipeline` owns `SCStream`, `VideoEncoder` and their stop order.
- `VideoConnection` owns the video socket and write backpressure.
- `ControlConnection` owns the bidirectional control socket.
- `InputController` owns all synthetic mouse/pen button state and guarantees
  release on disconnect.
- `MetricsCollector` owns counters and interval summaries.

### Client

- `SessionController` owns client state, child jobs and reconnect policy.
- `DisplaySurfaceController` owns the 60 Hz mode request and active `Surface`.
- `DecoderController` is the only owner of `MediaCodec`.
- `VideoReceiver` owns video framing and encoded-buffer pooling.
- `ControlChannel` owns control framing and ordered writes.
- `TouchInterpreter` owns active Android pointer and gesture state.
- `InputSender` owns batching and transmission of immutable input samples.

No object may stop or recreate another component's resource directly. It asks
the owning session controller to perform a state transition.

## 5. Shared domain model and protocol

Swift and Kotlin use matching domain types but do not share generated code.
Golden binary fixtures and tests enforce the wire contract.

### 5.1 Capability objects

```text
ProtocolVersion
  major: UInt16
  minor: UInt16

PixelSize
  width: UInt32
  height: UInt32

DisplayModeCapability
  pixelSize: PixelSize
  refreshMilliHz: UInt32
  modeId: Int32

CodecCapability
  codec: avc | hevc
  profiles: [ProfileLevel]
  exactSizeRateSupported: Bool
  lowLatencySupported: Bool
  hardwareAccelerated: Bool

InputCapabilities
  maxTouchPoints: UInt8
  hasPen: Bool
  hasPressure: Bool
  hasTilt: Bool
  hasHover: Bool
  hasPenAuxiliaryKey: Bool

ClientHello
  protocolVersion
  sessionToken
  deviceName
  nativePixelSize
  densityDpi
  activeDisplayMode
  displayModes
  codecCapabilities
  inputCapabilities
```

`deviceName` is informational and must not contain a serial or other persistent
identifier. `sessionToken` is a random value supplied in the ADB launch intent
and prevents an unrelated local process from joining the listener.

### 5.2 Negotiated configuration

```text
SessionConfig
  sessionId
  codec: avc | hevc
  pixelSize: 2456×1600
  refreshMilliHz: 60000
  bitrateBitsPerSecond
  colorSpace: sRGB
  videoPort
  inputMode: directTouch
  cursorIncluded: Bool

ClientReady
  sessionId
  selectedDisplayMode
  decoderName
  actualSurfaceSize

VideoChannelHello
  sessionId
  sessionToken
```

The host is authoritative for the selected configuration. The client either
accepts it exactly or returns a typed rejection. It must not silently choose a
lower size or refresh rate.

### 5.3 Video objects

```text
CodecConfiguration
  generation
  codec
  parameterSets

VideoFrameHeader
  sequence
  configurationGeneration
  presentationTimeNs
  flags: keyframe | discontinuity
  payloadLength
```

All dimensions and lengths are bounded before allocation. The initial maximum
encoded access-unit size is 16 MiB.

### 5.4 Input objects

```text
PointerTool
  finger | pen | eraser

PointerPhase
  hoverEnter | hoverMove | hoverExit | down | move | up | cancel

PointerSample
  pointerId
  tool
  phase
  normalizedX
  normalizedY
  pressure
  tiltRadians
  orientationRadians
  buttonMask
  eventTimeNs

InputBatch
  batchSequence
  samples

ScrollGesture
  phase: began | changed | ended | cancelled
  normalizedX
  normalizedY
  deltaX
  deltaY
  eventTimeNs

ZoomGesture
  phase
  normalizedX
  normalizedY
  scaleDelta
  eventTimeNs

ContextClickGesture
  normalizedX
  normalizedY
  source: longPress | twoFingerTap | penButton
  eventTimeNs

ShortcutGesture
  action: missionControl | previousSpace | nextSpace | showDesktop | custom
  eventTimeNs

AuxiliaryKey
  androidKeyCode
  scanCode
  phase
  eventTimeNs
```

Coordinates and pressure use finite `Float32` values. Boundary decoding rejects
NaN, infinity and values outside the protocol bounds. Internal code receives
validated values and does not repeat those checks.

### 5.5 Diagnostics objects

```text
Ping / Pong
  sequence and four monotonic timestamps

ClientMetrics
  receivedFps
  receivedBitsPerSecond
  decoderInputFps
  decoderOutputFps
  selectedDisplayMode
  videoQueueDepth
  droppedFrames

ProtocolError
  stable code
  safe message
  fatal: Bool
```

## 6. Framing and channels

Use two independent TCP connections through `adb reverse`:

- port 5560: host-to-client video;
- port 5561: bidirectional control, input and metrics.

Both host listeners bind to `127.0.0.1` only. `TCP_NODELAY` is enabled on the
control connection. Video congestion can therefore never delay touch input.

Each message starts with a fixed-size big-endian header:

```text
magic: 4 bytes
major version: 2 bytes
minor version: 2 bytes
message type: 2 bytes
flags: 2 bytes
sequence: 8 bytes
payload length: 4 bytes
sender monotonic timestamp: 8 bytes
```

The decoder validates magic, supported major version, known or safely
skippable type, payload bound and message-specific structure before producing a
domain value. A major-version mismatch is fatal. An unknown minor-version
message may be skipped only after its bounded payload length is validated.

VideoToolbox length-prefixed NAL units are converted to Annex-B framing by
replacing each four-byte NAL length with a four-byte start code in a reusable
buffer. Codec configuration is sent explicitly before the first frame and
after every encoder recreation.

The first message on the video connection is `VideoChannelHello`. The host
does not send codec configuration or frames until that message matches the
active negotiated session and launch token.

Control messages are directionally explicit:

```text
host -> client
  SessionConfig
  StartStream
  StopSession
  Ping
  ProtocolError

client -> host
  ClientHello
  ClientReady
  InputBatch / semantic gestures / ContextClickGesture / AuxiliaryKey
  ClientMetrics
  DecoderFailure
  RequestKeyframe
  Pong
  ProtocolError
```

Integers are unsigned or signed fixed-width big-endian values as defined by
`protocol.md`. Floating-point values are IEEE-754 binary32 encoded in
big-endian byte order. Strings are length-prefixed UTF-8 with message-specific
bounds. Arrays carry a bounded element count followed by fixed or
length-prefixed elements; a decoder never infers a count from the remaining
payload.

## 7. Host modules, classes and functions

### 7.1 App

#### `AppDelegate`

- constructs application dependencies;
- installs the menu bar item;
- routes termination and wake/sleep notifications to `SessionCoordinator`;
- contains no streaming or protocol logic.

#### `StatusMenuController`

Displays:

- selected ADB device;
- session state;
- requested and actual resolution/refresh;
- codec and bitrate;
- capture, encode, transport and client-render frame rates;
- start, stop, reconnect and open-log actions.

It consumes immutable status snapshots and does not inspect runtime components.

#### `PermissionsController`

Functions:

```swift
func screenRecordingStatus() -> PermissionStatus
func requestScreenRecording()
func accessibilityStatus(prompt: Bool) -> PermissionStatus
```

Starting a session is blocked until both required permissions are granted.

#### `HostSettings`

Persisted through `UserDefaults`:

- preferred codec: automatic, AVC or HEVC;
- bitrate policy;
- Mac logical display size while retaining a 2456×1600 backing surface;
- touch zoom mapping;
- transient-disconnect display grace period.

### 7.2 Device

#### `ADBClient`

All ADB process invocation is centralized here.

```swift
func listDevices() async throws -> [ADBDevice]
func packageVersion(on device: ADBDevice) async throws -> InstalledClient?
func installClient(apk: URL, on device: ADBDevice) async throws
func addReverse(remotePort: UInt16, localPort: UInt16, device: ADBDevice) async throws
func removeReverse(remotePort: UInt16, device: ADBDevice) async
func launchClient(device: ADBDevice, launch: ClientLaunch) async throws
func forceStopClient(device: ADBDevice) async
```

Commands use argument arrays, explicit timeouts and captured stdout/stderr.
The host never silently installs or upgrades the APK; installation is an
explicit action.

#### `DeviceDiscovery`

Polls at a bounded interval only while no usable device is connected. It
emits normalized changes rather than exposing raw ADB output to the session.

#### `AdbReverseManager`

Owns the two reverse mappings and removes only mappings it created.

### 7.3 Session

#### `SessionCoordinator` (`actor`)

The sole host lifecycle authority.

```swift
func start(device: ADBDevice) async
func stop(reason: StopReason) async
func reconnect() async
func handleClientMessage(_ message: ControlMessage) async
func handleTransportClosed(_ reason: TransportCloseReason) async
```

State:

```text
idle
checkingPermissions
preparingTransport
waitingForClient
negotiating
creatingDisplay
preparingClient
streaming
waitingForReconnect
stopping
failed
```

Every transition has one entry function and one cleanup function. A transition
token prevents completion from an old asynchronous operation from mutating a
new session.

#### `SessionNegotiator`

A pure component:

```swift
func negotiate(client: ClientHello, settings: HostSettings) throws -> SessionConfig
```

It requires exact 2456×1600 at 60 Hz. It chooses AVC or HEVC only when both the
client capability report and a host VideoToolbox session probe accept the
configuration. Negotiation failure is explicit and never lowers resolution.

### 7.4 Display

#### `VirtualDisplayController` (Objective-C)

The only code that calls private classes. It creates, applies, exposes and
releases one virtual display. Errors are converted into explicit Objective-C
error values rather than logging and continuing.

The normal virtual display uses stable synthetic vendor, product and serial
values so WindowServer can retain the owner's display arrangement across
sessions. If an already-live display has the same identity, creation uses a
bounded alternate serial rather than destroying an object it does not own.

#### `VirtualDisplayManager` (Swift)

```swift
func create(configuration: DisplayConfiguration) async throws -> ActiveDisplay
func waitUntilPublished(_ display: ActiveDisplay) async throws
func enforceSelectedMode(_ display: ActiveDisplay) async throws
func destroy() async
```

`ActiveDisplay` contains a valid `CGDirectDisplayID`, pixel bounds and selected
mode. It cannot be constructed without successful publication and mode
verification.

The display may remain alive for a short configured grace period after a USB
disconnect so macOS does not move all windows back to the MacBook display.

### 7.5 Streaming

#### `ScreenCapturer`

Owns `SCStream` and its callback queue.

```swift
func start(display: ActiveDisplay, format: CaptureFormat) async throws
func stop() async
var onFrame: (@Sendable (CapturedFrame) -> Void)?
```

Configuration:

- exact 2456×1600 output;
- 1/60 minimum frame interval;
- NV12 video-range pixel buffers where supported;
- cursor included;
- queue depth initially two, raised only with evidence that ScreenCaptureKit
  stalls at two;
- sRGB color space;
- no scaling.

It rejects incomplete or blank ScreenCaptureKit frames and records capture
timestamps before handing an immutable `CapturedFrame` to the encoder.

#### `VideoEncoder`

Owns one `VTCompressionSession`.

```swift
func prepare(configuration: EncoderConfiguration) throws
func encode(_ frame: CapturedFrame) -> EncodeDisposition
func forceKeyframe()
func invalidate()
var onAccessUnit: (@Sendable (EncodedAccessUnit) -> Void)?
```

The encoder is real-time, hardware-backed, has frame reordering disabled and
uses no B-frames. It has a small in-flight limit. If transport pressure means
another encoded access unit cannot be accepted without increasing latency, the
capture frame is skipped **before encoding**. Encoded interdependent P-frames
are not arbitrarily discarded.

#### `VideoSender`

Serializes codec configuration and access units. It owns a bounded write queue
and records write completion times. It never blocks the capture callback.

Backpressure policy:

1. stop admitting new capture frames when the bounded pipeline is full;
2. finish sending every access unit already accepted by the encoder;
3. resume from the newest captured frame when capacity returns;
4. if the socket remains congested beyond a threshold, restart the video
   stream and force an IDR rather than accumulate latency.

#### `CapturePipeline`

Composes `ScreenCapturer`, `VideoEncoder` and `VideoSender`. It exposes one
start/stop boundary to `SessionCoordinator` and enforces stop order:

1. stop accepting capture callbacks;
2. stop `SCStream`;
3. complete or abandon bounded encoder work;
4. invalidate the encoder;
5. close the video stream.

### 7.6 Transport

#### `ControlListener` / `VideoListener`

Bind only to loopback and accept one authenticated connection for the active
session token. Extra connections are rejected.

#### `ControlConnection`

Runs one ordered receive task and one ordered send task. Messages are encoded
before enqueue. The queue is bounded; repetitive metrics can be coalesced, but
input acknowledgements and lifecycle messages cannot be discarded.

#### `MessageCodec`

Pure encode/decode functions over byte buffers. No session behavior.

### 7.7 Input

#### `CoordinateMapper`

Pure transformation from validated normalized client coordinates to the active
virtual display's global CoreGraphics bounds. It owns rotation, clamping and
edge pixel behavior.

#### `PointerInjector`

Owns finger pointer state:

```swift
func handle(_ batch: InputBatch)
func reset()
```

It performs absolute pointer movement, click and drag. `reset()` always emits
the required mouse-up event when a disconnect occurs mid-drag.

It also performs an explicit right click at a validated location when it
receives `ContextClickGesture`; Android decides whether that action came from a
long press, two-finger tap or configured pen button.

#### `ScrollInjector`

Emits continuous pixel scroll events with explicit began, changed, ended and
cancelled phases. It moves the cursor to the gesture location before posting
because macOS routes scrolling to the window under the pointer.

#### `ZoomActionMapper`

Maps client pinch deltas to a configurable strategy. The initial default is
accumulated Command-plus/Command-minus steps because synthetic magnification
events are not reliably delivered by macOS. Strategies remain explicit rather
than pretending to provide native trackpad pinch.

#### `ShortcutInjector`

Maps semantic multi-finger gestures to explicit macOS keyboard shortcuts. It
does not attempt to inject undocumented raw multitouch reports.

#### `PenInjector`

Posts tablet proximity and tablet-point events with pressure and tilt when
available. It synthesizes proximity on the first pen contact because existing
tests did not observe hover. Pen handling is optional to the initial release
but uses the same input channel.

#### `InputController`

Dispatches validated input messages to the focused injector and resets every
injector on disconnect, display destruction or session failure.

### 7.8 Observability

#### `MetricsCollector` (`actor`)

Receives counters and durations without owning any pipeline resources. Once per
second it produces a `SessionMetricsSnapshot` containing:

- selected virtual-display mode;
- ScreenCaptureKit frames received and rejected;
- encoder frames accepted and produced;
- median/p95/worst encode latency;
- encoded bitrate;
- video write queue depth and stalls;
- client receive, decoder input/output and display mode metrics;
- control round-trip time;
- input messages and resets.

#### `SessionLogger`

Writes bounded, rotating local logs under Application Support. It never stores
screen pixels, decoded video, exact drawn paths, device serials or personal
content.

## 8. Android modules, classes and functions

### 8.1 Application surface

#### `MainActivity`

- reads and validates the ADB launch extras;
- enters immersive landscape mode;
- hosts `RemoteDisplayView`;
- forwards surface and lifecycle events to `SessionController`;
- forwards `dispatchKeyEvent` to `TouchInterpreter` for the M-Pencil
  `KEY_F20` path;
- contains no socket or codec loop.

#### `RemoteDisplayView`

A small `FrameLayout` containing a full-size `SurfaceView` and an optional
debug overlay. It captures touch events before they can be interpreted as
normal Android UI gestures.

### 8.2 Model and capabilities

#### `DeviceCapabilitiesCollector`

```kotlin
fun collect(surfaceSize: PixelSize): ClientHello
```

Collects display modes, current mode, density and input capabilities. It uses
the ordinary Android input-device and display APIs; it does not read raw
`/dev/input` nodes.

#### `CodecCapabilityProbe`

Enumerates hardware AVC and HEVC decoders and reports exact
2456×1600@60 support using `VideoCapabilities.areSizeAndRateSupported`. It
records the chosen decoder name for diagnostics.

### 8.3 Session

#### `SessionController`

The sole client lifecycle authority. It owns a `SupervisorJob` and emits
immutable `StateFlow<ClientSessionState>` snapshots to the UI.

```kotlin
fun start(launch: ClientLaunch)
suspend fun stop(reason: StopReason)
fun onSurfaceAvailable(surface: Surface, size: PixelSize)
fun onSurfaceDestroyed()
fun onInput(message: OutboundInput)
```

State:

```text
idle
waitingForSurface
connectingControl
negotiating
configuringDisplay
configuringDecoder
connectingVideo
streaming
reconnecting
stopping
failed
```

The controller starts video only after a valid surface, accepted configuration,
selected 60 Hz mode, configured decoder and both sockets are ready.

#### `ReconnectPolicy`

Provides bounded exponential backoff for a host-not-ready or temporary USB
disconnect. Protocol rejection, incompatible codec and malformed data are not
retried indefinitely.

### 8.4 Display

#### `DisplaySurfaceController`

```kotlin
fun selectMode(pixelSize: PixelSize, refreshMilliHz: Int): SelectedMode
fun attach(surface: Surface, selectedMode: SelectedMode)
fun detach()
```

It selects the exact 1600×2456 60 Hz physical mode, applies its mode ID to the
window, requests 60 fps on the `Surface`, and then reads the active mode back.
Failure to obtain the requested mode is sent to the host; it is not silently
reported as success.

### 8.5 Video

#### `DecoderController`

The only class allowed to create, configure, flush, stop or release
`MediaCodec`.

```kotlin
suspend fun configure(config: VideoConfig, surface: Surface): DecoderReady
fun submit(accessUnit: EncodedAccessUnit): SubmitResult
suspend fun flushForDiscontinuity()
suspend fun stop()
```

It uses a dedicated `HandlerThread` and `MediaCodec.Callback`. Codec input
buffers are filled from pooled direct buffers. Output buffers are released to
the `Surface` immediately or at the supplied presentation timestamp. It never
copies decoded pixels into application memory.

#### `EncodedBufferPool`

Owns a small fixed pool sized from negotiated frame bounds. Network reads do
not allocate a new `ByteArray` per frame. Pool exhaustion applies backpressure
rather than unbounded allocation.

#### `VideoReceiver`

Reads exactly one bounded frame header and payload at a time, validates sequence
and configuration generation, and submits it to `DecoderController`. A sequence
gap is treated as a discontinuity and requests a new keyframe.

### 8.6 Transport

#### `ControlChannel`

One reader and one writer operate on the control socket. Writes use a bounded
channel. High-frequency input batches preserve order; periodic metrics may be
replaced by a newer unsent snapshot.

#### `VideoChannel`

Owns the blocking video `SocketChannel` and receive buffer. It has no input or
gesture responsibility.

#### `ProtocolReader` / `ProtocolWriter`

Pure bounded framing over `ByteBuffer`. They produce validated model objects or
typed protocol failures.

### 8.7 Input

#### `TouchInterpreter`

Runs synchronously from Android input dispatch and immediately copies relevant
data from `MotionEvent`; the framework event object is never retained.

It owns this state:

```text
idle
singleCandidate
singleDragging
multiCandidate
scrolling
pinching
shortcutGesture
penActive
cancelled
```

Rules:

- A finger down enters `singleCandidate` and positions the remote pointer.
- A finger up within movement/time thresholds emits a tap.
- Movement past the drag threshold emits a down at the original position and
  transitions to `singleDragging`.
- A stationary long press emits `ContextClickGesture` and does not also emit a
  left click.
- A second finger cancels any single-finger candidate or releases an active
  drag before beginning a multi-finger gesture.
- A stationary two-finger tap emits `ContextClickGesture`.
- Two-finger translation becomes scroll after crossing a direction/slop
  threshold.
- Two-finger distance change becomes pinch after crossing its threshold.
- Once selected, a gesture does not change category until all involved
  contacts end.
- Three-to-five-finger actions emit semantic shortcuts only after an explicit
  threshold; raw contacts are not sent to macOS as a fake trackpad.
- Pen contact takes precedence. Finger contacts are ignored while the pen is
  active and for a short configurable cooldown after pen-up.
- `ACTION_CANCEL`, surface loss and session loss emit cancellation and clear
  all local state.

Historical motion samples are copied into `InputBatch` so the 60 Hz video
stream does not limit the input sample rate.

#### `PenInterpreter`

Copies normalized position, pressure, tilt, orientation and standard button
state from stylus `MotionEvent`s. Because hover was not observed in existing
tests, contact down is sufficient to begin host proximity.

#### `AuxiliaryKeyInterpreter`

Recognizes `KEYCODE_F20` and its scan code when delivered to the activity and
emits a normal `AuxiliaryKey` message. Failure to receive the key in the
application does not fail the display session.

#### `InputSender`

Encodes immutable batches onto the control writer. Move samples may be batched
within the same Android event, but there is no timer-based delay added merely
to create larger batches. Down, up, cancel and gesture phase changes flush
immediately.

### 8.8 Diagnostics

#### `ClientMetricsCollector`

Counts socket bytes, frame headers, decoder inputs/outputs, input messages,
codec restarts and the currently active display mode. It emits at most one
metrics snapshot per second.

#### `DebugOverlayController`

Optional overlay showing connection, codec, resolution, receive fps, decode
fps, bitrate and selected Android display mode. It is off by default and never
becomes part of the video source because capture occurs on the Mac.

## 9. End-to-end execution flow

### 9.1 Host launch

1. `AppDelegate` creates the menu and `SessionCoordinator`.
2. `PermissionsController` evaluates Screen Recording and Accessibility.
3. `DeviceDiscovery` lists authorized ADB devices.
4. The menu displays the selected TXZ-W09 and whether the client APK has a
   compatible protocol version.

No virtual display or listener is created merely by launching the host.

### 9.2 Start session

1. User selects Start or enabled auto-connect detects the configured physical
   USB tablet.
2. `SessionCoordinator` confirms permissions and one selected authorized
   device.
3. Host creates a random session token.
4. `ControlListener` and `VideoListener` bind to loopback.
5. `AdbReverseManager` creates both reverse mappings.
6. `ADBClient.launchClient` starts the Android activity with token, ports and
   protocol major version.
7. Client waits for its `Surface`, collects capabilities and connects the
   control channel.
8. Client sends `ClientHello` with the token.
9. Host authenticates the token and negotiates exact 2456×1600@60 plus codec
   and bitrate.
10. Host creates and verifies the virtual display.
11. Host sends `SessionConfig`.
12. Client selects and verifies 60 Hz, configures the decoder against the
    current `Surface`, and connects the video channel.
13. Client sends `ClientReady` with actual surface and mode.
14. Host verifies exact values, starts ScreenCaptureKit and VideoToolbox, sends
    codec configuration, forces an IDR and begins video.
15. Client decodes to `SurfaceView`; touch input is active only after the
    streaming state is entered.

### 9.3 Host video loop

1. ScreenCaptureKit publishes the newest complete NV12 frame and timestamp.
2. `CapturePipeline` checks bounded capacity.
3. If capacity exists, `VideoEncoder` submits the frame to VideoToolbox.
4. If capacity is full, the new capture is counted and skipped before
   encoding; no queue grows.
5. VideoToolbox produces an ordered encoded access unit.
6. `VideoSender` frames and sends it on the dedicated socket.
7. Write completion releases pipeline capacity.
8. Metrics are sampled without blocking this path.

### 9.4 Client video loop

1. `VideoReceiver` reads and validates one header.
2. It obtains a pooled encoded buffer and reads the exact payload.
3. It validates sequence/configuration generation.
4. `DecoderController` fills the next MediaCodec input buffer.
5. MediaCodec produces an output buffer associated with the `Surface`.
6. `DecoderController` releases it for rendering.
7. The Android compositor scans it out at the selected 60 Hz panel mode.
8. Buffer ownership returns to the pool.

### 9.5 Input loop

1. Android dispatches a `MotionEvent` to `RemoteDisplayView`.
2. `TouchInterpreter` copies current and historical samples and advances its
   deterministic gesture state.
3. `InputSender` immediately frames the resulting pointer or semantic gesture
   message on the independent control connection.
4. Host `ControlConnection` validates and forwards the message to
   `InputController`.
5. `CoordinateMapper` maps normalized coordinates into the virtual display's
   global bounds.
6. The relevant injector posts CoreGraphics events.
7. On any disconnect or cancellation, both client and host reset their input
   states so no synthetic button remains held.

### 9.6 Normal stop

1. Host transitions to `stopping` and tells the client to stop.
2. Host stops capture and encoding in the defined ownership order.
3. Client stops video receive, MediaCodec and input capture.
4. Connections close.
5. Host destroys the virtual display.
6. Host removes only its own ADB reverse mappings.
7. Both sides return to `idle`.

### 9.7 Temporary disconnect

1. Socket EOF immediately resets synthetic input state.
2. Host stops capture and encoder but retains the virtual display for the
   configured grace period.
3. Client releases MediaCodec and enters bounded reconnect backoff.
4. When control reconnects with the current token, negotiation and decoder
   configuration repeat and a new codec generation plus IDR starts.
5. If the grace period expires, the host destroys the display and returns to
   idle/failed with an explicit reason.

## 10. Error model and recovery

Errors are typed by owner and classified as retryable or terminal.

Host terminal errors:

- required macOS permission denied;
- private virtual-display classes unavailable;
- exact virtual mode refused;
- protocol major mismatch;
- client rejects exact 2456×1600@60;
- no common hardware codec;
- repeated malformed protocol input.

Host/client retryable errors:

- host listener not ready when client first starts;
- USB disconnect;
- activity recreation and surface loss;
- one codec instance failure;
- one transport timeout.

Decoder failure policy:

1. stop accepting video;
2. report the codec error;
3. recreate the same negotiated decoder once;
4. request codec configuration and a forced IDR;
5. terminate the session after repeated failure rather than looping forever.

No catch block converts a failed exact mode into a lower resolution or hides a
codec invariant violation with defaults.

## 11. Security and privacy

- Host listeners bind to loopback only.
- The random launch token authenticates both session connections.
- Frame and message lengths are bounded before allocation.
- The client requests only Internet/local socket permission and normal display
  wake behavior; it needs no storage or Android Accessibility permission.
- The host requires macOS Screen Recording and Accessibility because those are
  intrinsic to its function.
- No video frames or touch paths are written to disk.
- Logs omit ADB serials and personal screen content.
- Wi-Fi discovery, pairing, encryption and remote access are absent from the
  first release rather than shipped incompletely.

## 12. Testing strategy

### 12.1 Protocol contract

Both implementations must load the committed fixture files and prove:

- byte-identical encoding;
- identical decoding;
- partial-read handling;
- invalid magic/version rejection;
- payload bounds;
- finite float validation;
- unknown minor message skipping;
- sequence and codec-generation behavior.

### 12.2 Pure unit tests

Host:

- exact negotiation and rejection paths;
- session transition legality and stale completion tokens;
- coordinate mapping for every edge and display origin;
- pointer reset after disconnect;
- scroll phase mapping;
- zoom accumulation;
- video admission/backpressure behavior.

Client:

- one-finger tap/drag state transitions;
- second-finger cancellation of a pending click or active drag;
- scroll-versus-pinch commitment;
- three-to-five-finger semantic mapping;
- pen precedence and cooldown;
- `ACTION_CANCEL` cleanup;
- reconnection policy;
- buffer-pool bounds.

### 12.3 Platform integration tests

Host:

- virtual-display create, publish, exact mode verification, destroy and
  recreate;
- ScreenCaptureKit captures only that display at 2456×1600;
- VideoToolbox hardware AVC/HEVC session probes;
- loopback control/video partial writes and cancellation;
- permissions produce actionable states.

Client:

- codec capability probe for exact size/rate;
- selected physical display mode reads back as 60 Hz;
- MediaCodec configures against the real `Surface`;
- activity/surface recreation releases and restores the decoder exactly once.

### 12.4 End-to-end acceptance tests

These validate integration and do not repeat the completed hardware input
reconnaissance.

1. The Mac lists one 2456×1600 60 Hz virtual display.
2. A pixel-addressable test image reaches all tablet edges without scaling,
   cropping, stretching or orientation error.
3. A 60 fps motion pattern produces at least 59 fps at capture, encode, receive
   and decoder output during a stable interval, with reported drops.
4. Static desktop text remains legible at the selected bitrate.
5. One-finger taps and drags map to the touched location, including all four
   corners.
6. Two-finger scroll has correct direction, phase and target window.
7. Pinch invokes the configured zoom behavior without runaway repeated keys.
8. A disconnect during drag releases the synthetic button.
9. Cable reconnect restores the stream and preserves the virtual display
   during its grace period.
10. A 30-minute session has bounded memory, stable queue depths and no
    increasing end-to-end delay.

## 13. Performance and observability gates

The status UI and logs distinguish requested settings from actual measurements:

```text
virtual display: 2456×1600 @ 60.00 Hz
capture:         current fps, incomplete frames, admitted frames
encoder:         codec, fps, bitrate, median/p95/worst latency, in-flight count
transport:       Mbit/s, write latency, bounded queue depth, reconnect count
client receive:  fps, Mbit/s, sequence gaps
decoder:         input fps, output fps, restarts
tablet display:  active 1600×2456 @ 60.00 Hz
input:           event rate, control RTT, reset count
```

Success is not inferred from the panel being in 60 Hz mode. Capture, encoding,
transport and decoder output must all independently demonstrate the expected
rate. If a stage falls short, its measurements identify the next optimization.

## 14. Implementation milestones and gates

### Milestone 0 — architecture and protocol

- accept this architecture;
- write the normative wire protocol and committed fixtures;
- create empty host/client projects with format, lint and unit-test commands.

Gate: Swift and Kotlin fixture tests agree before sockets or codecs are added.

### Milestone 1 — lifecycle and control connection

- ADB discovery and explicit APK version check;
- loopback listeners and reverse mappings;
- activity launch token;
- ClientHello, negotiation, ClientReady and typed failure flow;
- state/status UI on both sides.

Gate: repeated start/stop/reconnect leaves no listener, reverse mapping or
client job behind.

### Milestone 2 — exact virtual display

- Objective-C shim;
- create 2456×1600@60 display;
- publish and verify exact mode;
- teardown/recreate and disconnect grace behavior.

Gate: a normal Mac window can be moved onto the display and the display returns
cleanly after teardown.

### Milestone 3 — full-resolution USB video

- ScreenCaptureKit NV12 capture;
- hardware AVC first, HEVC negotiation second;
- framed video socket;
- asynchronous MediaCodec-to-Surface decode;
- complete metrics and bounded queues.

Gate: full-resolution 60 fps motion test and 30-minute bounded-memory soak.

### Milestone 4 — direct touch

- immutable MotionEvent copying including historical samples;
- absolute pointer mapping;
- tap, drag, cancel and disconnect reset;
- two-finger scroll;
- configurable pinch mapping.

Gate: integration behavior passes without repeating the prior contact-count or
pressure reconnaissance.

### Milestone 5 — resilience and packaging

- permission UX;
- explicit install/upgrade action;
- auto-connect for the configured physical USB device;
- activity/surface recreation;
- cable disconnect and Mac wake handling;
- rotating privacy-safe logs.

Gate: normal use requires opening the host app and attaching the authorized
tablet; failures state their owner and recovery action.

### Milestone 6 — optional input completion

- pen precision, pressure and tilt forwarding;
- `KEY_F20` mapping if delivered to the app;
- semantic three-to-five-finger shortcuts;
- user-configurable action mapping.

These do not block the touch-enabled second-display release.

## 15. Decisions intentionally deferred

- Wi-Fi transport: add only after USB measurements demonstrate a transport
  limitation or the owner wants cable-free operation.
- Android Open Accessory bulk transport: consider only if ADB itself is the
  measured wired bottleneck.
- 90/120 Hz: preserve capability fields and timing types, but do not optimize
  these modes before stable full-resolution 60 fps.
- Audio: separate capture/clocking project.
- HDR/wide color: requires end-to-end color metadata and codec validation.
- Smooth native macOS pinch: would require a virtual multitouch HID path and
  private report formats/entitlements; semantic zoom remains the supported
  behavior.
- General device support: only after TXZ-W09 behavior is complete and measured.

These are recorded design options, not permission to implement them during the
first release.
