# Project log (historical)

This was the repository's front page until October 2026. It records the
original USB-first plan, the evidence gathered along the way and the gates the
project set itself. Much of it no longer describes how Mirri works: USB
streaming was removed and WebRTC over Wi-Fi is the default. For the current
state start at the [README](../README.md).

---

# Mirri

Mirri is a native second-display bridge in development for a Huawei MatePad 11.5
(2025), model TXZ-W09, and an Apple Silicon Mac. The name is derived from
“mirror,” but the primary goal is a real **extended macOS display**, not simple
screen mirroring.

## Status

**Runtime source implemented; 60 fps physical acceptance pending.** The macOS bundle
and Android APK contain session, USB loopback, exact display, hardware video
and input owners. On the authorized TXZ-W09, a full-native AVC 40 Mbit/s target
stream ran for 30 minutes with zero reported frame drops/reconnects, but the
median interval send rate was 56.4 fps, below the 59 fps motion gate. A matched
90-second owned-motion capture pacing trial subsequently improved exact
full-window send rate from 56.64 to **59.92 fps**, with a second independent
synthetic motion run at **59.90 fps**. The new-pacing 30-minute soak was
interrupted after about 200 seconds of active capture; it **does not pass** the
duration gate. See [privacy-safe physical evidence](native-validation.md).
An experimental lower-resolution trial streamed slower and was removed at
the owner's direction; the retained path remains full-native quality.
Source builds and pure/localhost tests are separate from physical acceptance.
An opt-in **Network (USB setup)** path now has source/localhost validation: it
uses a selected local IPv4 address and pinned TLS after an initial USB launch.
Neither network streaming nor unplug/reconnect or network performance has been
validated on a tablet; see [network setup and limits](network-streaming.md).
The debug APK is not a release package; never install or upgrade it on a
tablet without the owner's explicit decision.

An opt-in WebRTC test route (`--rtc-test-route`, USB credential bootstrap and
pinned TLS control) has separately established selected UDP, hardware H.264
High 5.2 at 2456×1600 and exact-size hardware decoding on the authorized
TXZ-W09. The Android timed-control-receive cancellation race that dropped
authenticated Pings was corrected with an atomic receive/timeout selection.
A same-tablet 300-second owned-display synthetic trial then stayed Connected
through 18,017 stimulus ticks and 12,682 hardware-encoded frames; explicit
Stop and reconnect also passed. This proves that bounded physical reliability
trial, **not** 60 fps (roughly 42 fps achieved), latency or visual-quality
parity, 30-minute endurance, or unplugged Wi-Fi behavior. The existing USB
and TCP routes remain intact.
See [WebRTC architecture and observed gates](webrtc-architecture.md).

[`protocol/protocol.md`](../protocol/protocol.md) is the normative wire contract;
`protocol/fixtures/` contains 24 deterministic complete framed messages: all
22 registered message types plus hardware-HEVC enum/configuration examples.
Independent production-source Swift and Kotlin
models/codecs decode and re-encode every fixture byte-for-byte. Header bounds,
malformed values, fragmented/coalesced input, sequence, epoch and video
generation have focused unit tests. Fixtures are synthetic, not hardware
bitstreams or real device data.

The complete design, module ownership, protocol, state machines, execution
flow, error handling, verification strategy and delivery milestones are in
[`IMPLEMENTATION_PLAN.md`](../IMPLEMENTATION_PLAN.md).

## First-release target

- macOS extended display with a 2456×1600 native backing surface;
- persisted native 2456×1600 or 1228×800 logical HiDPI preference, both
  strictly read back at 2456×1600 backing/60 Hz before streaming;
- 60 Hz virtual-display mode and 60 fps stream target;
- network transport over pinned TLS on a selected local IPv4 address; USB/ADB is
  setup tooling only (install, first launch, logcat) and carries no media;
- hardware AVC initially, with negotiated hardware HEVC support;
- direct one-finger pointing, tapping and dragging;
- long-press and two-finger-tap context click;
- two-finger scrolling and configurable pinch-to-zoom behavior;
- optional M-Pencil position, pressure, tilt and auxiliary-button forwarding;
- bounded latency, explicit backpressure and per-stage performance metrics;
- automatic recovery from an Android activity restart or temporary network
  interruption.

USB streaming (`adb reverse` loopback route) was removed on 2026-10-04; sections
below that describe USB video or reverse mappings are historical. Network
transport is USB-bootstrapped, not Wi-Fi Direct. Audio, HDR, portrait operation,
Bluetooth tablet mode and general support for unrelated Android devices are
not part of the first release.

## Runtime implementation

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

## Repository layout

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

The host Xcode project has the three planned targets. The Objective-C
`VirtualDisplayShim` owns private virtual-display calls; the runtime is not
physically accepted. `tools/` contains offline-only Python utilities.

## Build and repeatable checks

macOS 26/Xcode 26.5/Swift 6.3.2 were used for verification. Install XcodeGen
2.46.0 to regenerate `macos-host/MirriHost.xcodeproj` after editing
`macos-host/project.yml`. The project itself is checked in and does not
require XcodeGen just to build. Android checks use JDK 17 (tested 17.0.20.1),
the checked-in Gradle 8.14.3 wrapper, Android SDK platform 35 and build-tools
35.0.0. `sdkmanager` from Android command-line tools provisions the SDK; set
the paths for your installation. The exact local setup used here was:

```sh
brew install xcodegen openjdk@17 android-commandlinetools
export JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home
export ANDROID_HOME=/opt/homebrew/share/android-commandlinetools
yes | "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" \
  --sdk_root="$ANDROID_HOME" 'platforms;android-35' 'build-tools;35.0.0'
```

With `JAVA_HOME` and `ANDROID_HOME` exported, from the repository root:

```sh
uv sync --offline
uv run --offline python tools/compare_protocol_fixtures.py
# Only regenerate committed fixtures intentionally:
python3 protocol/generate_fixtures.py
(cd macos-host && swift test)
xcodebuild -project macos-host/MirriHost.xcodeproj -scheme MirriHost \
  -destination 'platform=macOS' -derivedDataPath /tmp/mirri-host-derived \
  CODE_SIGNING_ALLOWED=NO test
(cd android-client && ./gradlew testDebugUnitTest assembleDebug)

# Quality gate (all stages log even if an earlier stage reports source findings):
brew install swiftlint # require SwiftLint 0.65.1; script rejects version drift
./tools/check_quality.sh
# Detailed cyclomatic offenders: logs/quality/python-complexity-detail.log

swift format lint -r --strict macos-host/Core macos-host/Tests macos-host/App macos-host/Tools
(cd android-client && ./gradlew ktlintCheck)
# Optional explicit formatting (run check separately after formatting):
swift format format -i -r macos-host/Core macos-host/Tests macos-host/App macos-host/Tools
(cd android-client && ./gradlew ktlintFormat)
uv run --offline python tools/benchmark_transport.py --mebibytes 16
uv run --offline python tools/summarize_session.py /path/to/local/host.log
uv tool run --offline --from ruff==0.15.14 ruff check protocol/generate_fixtures.py tools
uv tool run --offline --from ty==0.0.39 ty check protocol/generate_fixtures.py tools
uv tool run --offline --from radon==6.0.1 radon cc -s -a protocol/generate_fixtures.py tools
```

`tools/check_quality.sh` is the aggregate source-quality AND compiler/test gate;
run with the JDK 17 `JAVA_HOME` and Android SDK `ANDROID_HOME` from above.
It writes independent stage logs under ignored `logs/quality/`, returning nonzero
if any gated stage fails. `uv sync --locked` installs pinned development tools
from `uv.lock` (Python 3.11+): Ruff 0.15.14 formatting and E/F/I/B/UP/SIM/RUF
checks, ty 0.0.39 types, and Xenon 0.9.3 using Radon 6.0.1 to **fail**
functions/methods above Radon grade B (complexity >10); the separate Radon
stage lists the exact rank/score for C+ blocks. All Python production and test
modules under `tools/`, plus the protocol fixture generator, are included.
The gate also creates one unique temporary `MIRRI_TIMING_EMITTER_DIR`, runs the
existing Swift package and Android unit suites to write production host/client
timing logs into it, then runs Python `unittest` discovery against those logs.
It fails for missing/empty emitter output, undiscovered integration tests, or
skipped/failed Python tests, and removes the temporary directory on exit.
The existing unsigned Xcode test stage runs without emitter output so it cannot
overwrite the Swift package fixtures. Gradle's unit test task is forced to
rerun inside its existing aggregate invocation because Gradle does not track
the temporary environment variable as a test input; this is not a second
Android test run. Check `logs/quality/python-tests.log` for integration results.
SwiftLint 0.65.1 runs strict against `Core`, `App`, and `Tests` with a
cyclomatic limit of 12 (excluding simple switch cases); `swift format` owns
layout, and noisy file/type/line/body-length metrics are not enforced. The
SwiftLint version is checked before any stage so a newer Homebrew formula
cannot silently alter the rules; install the 0.65.1 tagged release if Homebrew
has moved forward. Android keeps ktlint 13.1.0 and pins detekt 2.0.0-alpha.0
(Kotlin 2.2-era parser) for complexity 12 and correctness checks in production
and tests; Android `lintDebug` treats warnings as errors. No baselines or
generated-output exemptions masking handwritten source are used.
Android lint ignores version-refresh advisories (`AndroidGradlePluginVersion`,
`GradleDependency`, `NewerVersionAvailable`) because this project deliberately
pins the verified toolchain/dependencies. It also excludes `ExpiredTargetSdkVersion`
for the sideloaded client's intentionally retained target SDK 31, and scopes
`DiscouragedApi` to the activity's required landscape orientation. Runtime
exact-mode validation still rejects incompatible surfaces; Android 16 may ignore
the orientation request. Other API, accessibility, and runtime diagnostics still
fail the gate. The Gradle invocation uses `--continue` so
lint/detekt failures do not prevent compiler, formatting, and unit test checks.

The APK produced by `assembleDebug` is a runtime debug build (`versionCode=2`),
not an accepted release. The host explicitly refuses the inert milestone-0
APK (`versionCode=1`) and installs/upgrades only through a user-selected menu
action. Builds/fixtures do not establish virtual display, USB, codec, mode,
color or input readiness. Unsigned Xcode test builds do not have a persistent
permission identity: build/sign a stable unsandboxed bundle before owner-run
hardware acceptance. See [host](../macos-host/README.md) and
[client](../android-client/README.md) build/launch caveats.

The owner-authorized native `.zero`-pacing 30-minute baseline completed
**1801.58 active seconds** without reported host state transition, drop or
reconnect, but host complete **56.069 fps** and framed write **54.341 fps**
fail the ≥59 fps sustained requirement (earlier 90-second 59.92/59.90 fps
runs are not sustained proof). [Numeric evidence](native-validation.md)
and the [reviewed timing calibration plan](timing-calibration.md)
document the next review gate. Two separately approved 90-second schema-3
attempts were incomplete: the first collector stopped on a static screen
before moving stimulus, and the second prearmed watcher never attached its
owned-only window before streaming, so the controller promptly stopped.
There is no complete-window timing result or physical optimization; any
further display test/calibration needs separate approval.

## Development prerequisites

Expected host tools for building and acceptance:

- macOS 26 on Apple Silicon;
- current Xcode and command-line tools;
- Android platform tools (`adb`);
- JDK 17 for the Android build;
- Android SDK command-line tools / platform SDK;
- `uv` for offline Python benchmark and log-analysis utilities (`pyproject.toml`,
  committed `uv.lock`; no third-party Python runtime dependencies). Pin and
  provision the separate ruff/ty/radon analysis tools once before using the
  `--offline` quality commands above. The loopback
  benchmark is synthetic TCP, **not** USB/ADB/video performance evidence.

The checks above verify builds, fixtures and selected pure/localhost behaviors.
Platform integration and end-to-end acceptance remain future gates.

## Requirement-to-evidence matrix

| Milestone / requirement | Implemented source | Current evidence | Still required |
| --- | --- | --- | --- |
| 0 protocol | `protocol/protocol.md`, 24 synthetic fixtures, Swift/Kotlin production codecs | Byte-identical fixture unit tests in each language; offline regeneration comparison | No physical proof implied |
| 1 control lifecycle | Typed host/client session boundaries, host attempt epochs and owned client attempt contexts, cancellable raw socket acquisition/read, ADB/reverse/listeners and bounded stop acknowledgement | Host concurrent-stop/stale callback and ID-binding tests, client pre-stream decoder failure and blocked-socket cancellation tests; physical Mirri-only Stop→Start and Reconnect resumed streaming | Repeated owner-run activity/surface recreation, USB unplug/replug and bounded cleanup under faults |
| 2 virtual display | Private API shim, persisted native/1228×800 HiDPI logical setting, strict logical/backing/60 Hz readback and grace | Owned HiDPI display physically read back 1228×800 logical / 2456×1600 pixels @60; strict owned mode selection used | Owner-run native logical selection, four-corner mapping and repeated teardown/recreate |
| 3 USB video | Native 2456×1600 NV12 ScreenCaptureKit → hardware VideoToolbox AVC40 → framed USB; hardware MediaCodec → SurfaceView; three frame credits, SCK queue depth 2 and native-refresh capture cadence (`minimumFrameInterval = .zero`) | Hardware decoder coded 2464×1600 cropped to exact visible 2456×1600 BT.709 limited; two 90-second motion windows sent 59.92 and 59.90 full-window fps, zero reported drops/reconnect | Uninterrupted new-pacing ≥59 fps at capture/encode/receive/decode over 30 minutes, owner color/edge/scanout/quality check |
| 4 touch | Copied MotionEvent samples, direct pointer, scroll, pinch, cancellation/reset | Gesture/host pointer state tests | Tap/drag corners, scroll direction/target, pinch, drag-disconnect; do not repeat input reconnaissance |
| 5 resilience/package | Permission menu, explicit install action, remembered USB device, bounded host logs | Compilation/pure tests | Stable signed identity, owner-authorized APK install, surface/activity restart and cable/wake recovery |
| 6 optional | Pen/pressure/tilt and F20 path, semantic shortcuts | Source/tests for selected gestures | Application key delivery and pen injection remain device-unverified; custom mapping not implemented |

The client uses AndroidX ComponentActivity/Lifecycle with StateFlow status;
AppCompat is not required for its single immersive SurfaceView. Color transfer/
Android compositor output are not physically verified. The HiDPI mode was
read back on the authorized Mac; native logical mode and both pointer mappings
are not yet physically accepted. A mismatch fails startup rather than silently
using another mode. The host waits at most
500 ms for StopAcknowledged after sending StopSession before cleanup;
automatic reverse mapping cleanup after ADB becomes unavailable across host
process exit is intentionally prohibited: ownership cannot be proven after a
restart. On next launch Mirri reports conflicting ports rather than deleting
them; the menu offers a separately confirmed cleanup of only tcp:5560/5561
pointing to their matching local ports. Live-process ownership survives
temporary USB loss and cleanup is retried on authorized-device rediscovery.
These are explicit ownership constraints,
not release-ready claims. Short-window ≥59 fps is measured, but the earlier
30-minute soak was below target and the new-pacing soak was interrupted.

## Remaining owner-run hardware acceptance (partially performed)

1. Ask the device owner before any further device interaction. A stable-path
   unsigned development bundle with owner-granted Screen Recording and
   Accessibility and the explicitly authorized debug `versionCode=2` APK were
   used for measurements; **signed release identity remains unverified**. Do not
   install unsolicited builds, clear data, or change Android permissions.
2. In separate sessions select native 2456×1600 logical and 1228×800 HiDPI
   logical in Settings. Inspect Mac Displays for one real extended display,
   verify both report exactly 2456×1600 pixel backing at 60 Hz and expected
   global logical bounds; move a normal window onto each and verify pointer
   mapping at all four logical corners. No logical selection may scale the
   encoded 2456×1600 frame in software. Read the
   tablet's actual 1600×2456@60 mode and verify a 2456×1600 Surface and
   hardware encoder/decoder identities; fail if anything falls back.
3. Move a numbered, pixel-addressable corner/edge grid across the virtual
   display. Verify all four tablet edges, orientation, cropping, color bars,
   text clarity and absence of scaling; check SDR limited-range and sRGB
   visually or with owner-approved instrumentation. No screen/frame capture
   is persisted by Mirri.
4. Show a 60 fps motion pattern. For a stable, explicitly timed interval,
   record host capture/admitted/encode/send fps and write depth/latency,
   client receive/decoder-input/decoder-output fps, gaps/drops, bitrate,
   active display mode and RTT. Require ≥59 fps independently at capture,
   encode, receive and decoder output; 60 Hz panel mode alone is insufficient.
5. Verify one-finger tap/drag at the four corners, two-finger scroll direction,
   phases/target window and configured pinch. Disconnect mid-drag and confirm
   mouse-up. This checks *delivery*, not prior raw contact-count/pressure/tilt
   reconnaissance. Check optional pen/F20 only if owner wants those paths.
6. Recreate client activity/surface and unplug/replug USB within grace; check
   fresh epoch/generation/IDR, restored stream and no stuck input. Repeated
   start/stop must leave no owned reverse/listener/decoder/display resources.
7. Run a 30-minute session with resource and queue-depth samples and a moving
   pattern; require bounded memory and no increasing end-to-end delay. Preserve
   only privacy-safe aggregate measurements, not serials, tokens, pixels or
   precise touch paths. Mark each gate pass/fail with actual values; if a gate
   is not measured, report **unverified**, not passed.

## Terminal control (macOS)

`mirri` drives the running host app over a user-only Unix socket in
`~/Library/Application Support/Mirri/`; the app stays the only session owner.
Install it once with `bash tools/install_cli.sh` (links into `~/.local/bin`,
override with `MIRRI_CLI_DIR`).

```sh
mirri status                      # state, modes and metrics (--json for raw)
mirri devices                     # attached tablets
mirri addresses                   # Mac IPv4 addresses
mirri connect --address en0       # WebRTC video over UDP; waits until streaming
mirri connect --address en0 --media tcp   # TLS/TCP comparison path
mirri disconnect
mirri reconnect
mirri set --codec avc --avc-bitrate 20 --size retina
mirri set --adaptive-bitrate off  # WebRTC: pin the bitrate to --avc-bitrate
mirri install path/to/app-debug.apk
mirri paired                      # tablets that can connect without the cable
mirri unpair                      # forget them
mirri set --auto-connect off      # do not start when a paired tablet opens Mirri
mirri watch                       # one state/metrics line per second
mirri logs | launch | show | quit
```

Connecting once with the USB cable pairs the tablet. After that no cable is
needed: open Mirri on the tablet and the Mac starts streaming, and a session
lost to a network outage comes back by itself. See
[`protocol/pairing.md`](../protocol/pairing.md) for the protocol and its limits.

`connect` launches the app if needed (`MIRRI_HOST_APP` overrides
`~/Applications/Mirri Development.app`). It needs either one authorized USB
debugging device or a paired tablet with Mirri open. `--address` and `--device` may be omitted only when there is
exactly one choice. Failures and timeouts exit nonzero; usage errors exit 2.

## Privacy and permissions

The macOS host requires Screen Recording and Accessibility permission.
The Android client does not require storage or Android Accessibility access.

### Local development signing

Before installing an updated host, sign the **complete staged app bundle** with
the same certificate-backed identity used by the previous installation:

```sh
bash tools/sign_development.sh /path/to/staged/MirriHost.app
```

The default identity is `Mirri Local Development` in the current user's keychain.
Set `MIRRI_SIGN_IDENTITY` to use another existing code-signing identity. The helper
fails if that identity is missing; it never falls back to ad-hoc signing. On a new
development machine, create a local Code Signing identity in Keychain Access
before using it. Retain that identity across builds; do not generate a new one
for each update. A local self-signed identity does not make the app notarized or
suitable for distribution, and does not need to be installed as a trusted system
root for local signing.

After signing, the displayed designated requirement must bind the bundle
identifier to the certificate, not to a build-specific `cdhash`. Install that
verified bundle at the same path and do not modify it afterward. Unsigned Xcode
test products and `codesign --sign -` builds are not stable permission identities.
Changing from an old ad-hoc identity to the certificate-backed identity requires
one new Screen Recording and Accessibility approval. If macOS retains stale
entries, quit Mirri and reset **only** its affected services:

```sh
tccutil reset ScreenCapture dev.mirri.host
tccutil reset Accessibility dev.mirri.host
```

Then open the same signed app, grant the requested permissions, and restart it
if macOS asks. Do not repeatedly toggle settings or rebuild between approval
and restart. Matching code-signing requirements support permission continuity;
physical update verification is still required before claiming it works.

USB is used only to install and launch the client with its ephemeral token and
TLS pin; host listeners bind to the selected IPv4 address with pinned TLS.

Mirri does not persist video frames or precise input paths. Logs contain
bounded operational metrics and errors, not screen content or device serials.

## License

Mirri is licensed under the [MIT License](../LICENSE).
