# Mirri

Mirri is a planned native USB second-display bridge for a Huawei MatePad 11.5
(2025), model TXZ-W09, and an Apple Silicon Mac. The name is derived from
“mirror,” but the primary goal is a real **extended macOS display**, not simple
screen mirroring.

## Status

**Architecture and implementation planning only.** No host or Android
application has been implemented yet.

The complete design, module ownership, protocol, state machines, execution
flow, error handling, verification strategy and delivery milestones are in
[`IMPLEMENTATION_PLAN.md`](IMPLEMENTATION_PLAN.md).

## First-release target

- macOS extended display with a 2456×1600 native backing surface;
- 60 Hz virtual-display mode and 60 fps stream target;
- USB transport through two localhost TCP channels carried by `adb reverse`;
- hardware AVC initially, with negotiated hardware HEVC support;
- direct one-finger pointing, tapping and dragging;
- long-press and two-finger-tap context click;
- two-finger scrolling and configurable pinch-to-zoom behavior;
- optional M-Pencil position, pressure, tilt and auxiliary-button forwarding;
- bounded latency, explicit backpressure and per-stage performance metrics;
- automatic recovery from an Android activity restart or temporary USB
  disconnect.

Wi-Fi, audio, HDR, portrait operation, Bluetooth tablet mode and general
support for unrelated Android devices are not part of the first release.

## Planned implementation

### macOS host

- Swift 6
- Objective-C shim for `CGVirtualDisplay`
- ScreenCaptureKit
- VideoToolbox
- CoreMedia / CoreVideo
- CoreGraphics / Quartz Event Services
- Network.framework
- AppKit
- Metal only if a capture-to-encoder pixel conversion is required

### Android client

- Kotlin
- Android API 30+; known target is API 31
- `SurfaceView`
- asynchronous `MediaCodec`
- `MediaCodecList` capability negotiation
- `DisplayManager` and `Surface.setFrameRate`
- `MotionEvent` with historical sample preservation
- `SocketChannel` and direct `ByteBuffer`s

## Existing device evidence

The input hardware has already been physically tested. Mirri will not repeat
that reconnaissance. The implementation plan contains an exact capture-path
index. The main curated references in the parent repository are:

- [`../txz-recon/reports/input-map.md`](../txz-recon/reports/input-map.md)
- [`../txz-recon/sanitized/touch-trials-20260924.md`](../txz-recon/sanitized/touch-trials-20260924.md)
- [`../txz-recon/sanitized/pen-trials-20260924.md`](../txz-recon/sanitized/pen-trials-20260924.md)
- [`../txz-recon/reports/TXZ-W09-hardware-map.md`](../txz-recon/reports/TXZ-W09-hardware-map.md)

Those records establish five simultaneous touch contacts, a live two-finger
pinch/spread, pen position, pressure, both tilt axes and the M-Pencil side
double-tap as `KEY_F20` with scan code `0007006f`.

The raw records under `../txz-recon/raw/` are private. They are local
engineering evidence and must not be copied into this repository, committed,
published or uploaded.

## Planned repository layout

```text
mirri/
├── README.md
├── LICENSE
├── IMPLEMENTATION_PLAN.md
├── protocol/
│   ├── protocol.md
│   └── fixtures/
├── macos-host/
│   ├── MirriHost.xcodeproj
│   ├── App/
│   ├── Core/
│   ├── VirtualDisplayShim/
│   └── Tests/
├── android-client/
│   ├── settings.gradle.kts
│   ├── build.gradle.kts
│   └── app/
└── tools/
```

Directories not yet needed are intentionally not created as empty scaffolding.
They will be added at the milestone that owns their first real artifact.

## Development prerequisites

Expected host tools once implementation begins:

- macOS 26 on Apple Silicon;
- current Xcode and command-line tools;
- Android platform tools (`adb`);
- JDK 17 for the Android build;
- Android SDK command-line tools / platform SDK;
- `uv` only for offline Python benchmark and log-analysis utilities.

Exact setup and verification commands will be added when the corresponding
projects exist. The implementation plan requires protocol fixtures and matching
Swift/Kotlin protocol tests before display or codec work begins.

## Privacy and permissions

The macOS host will require Screen Recording and Accessibility permission.
The Android client will not require storage or Android Accessibility access.
For USB operation, host listeners will bind to loopback only and will be
reachable from the tablet through session-specific `adb reverse` mappings.

Mirri will not persist video frames or precise input paths. Logs will contain
bounded operational metrics and errors, not screen content or device serials.

## License

Mirri is licensed under the [MIT License](LICENSE).
