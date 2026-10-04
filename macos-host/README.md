# Mirri host (macOS)

A menu-bar app that creates a virtual display, streams it to the tablet and
turns the tablet's touches into pointer input. For what Mirri is and how to
install it, start at the [main README](../README.md).

## Layout

```
App/                 menu-bar app: panel, settings, control socket for `mirri`
Core/Session/        session lifecycle: handshake, reconnect grace, stop
Core/Streaming/      ScreenCaptureKit capture, VideoToolbox encoders, WebRTC peer
Core/Display/        virtual display (via VirtualDisplayShim)
Core/Device/         ADB, pairing store, TLS identities, connection routes
Core/Transport/      byte connections, Bonjour rendezvous listener
Core/Input/          touch and pencil to Quartz events
Core/Model/          wire codec and message types
Tools/MirriCLI/      the `mirri` command
Tools/OwnedMotion/   test pattern used for measurements
VirtualDisplayShim/  Objective-C wrapper around the private display API
Tests/               unit and loopback tests
```

`MirriHost.xcodeproj` is generated from `project.yml`. After adding or removing
a source file, run `xcodegen generate`.

## Build, install, test

```sh
bash ../tools/install_host.sh     # build, sign, install to ~/Applications, start
bash ../tools/install_cli.sh      # build and link the `mirri` command
swift test                        # run from macos-host/
```

`install_host.sh` signs with the `Mirri Local Development` identity so macOS
keeps the Screen Recording and Accessibility grants across updates. Creating
that identity is a one-time manual step, described in
[`docs/setup.md`](../docs/setup.md). Set `MIRRI_STAGE_ONLY=1` to build and
verify the signature without installing.

Two tests bind the same ports a live session uses (5560 and 5561), so run the
suite while Mirri is not streaming.

Opt-in tests that use real hardware on this Mac:

```sh
MIRRI_HARDWARE_ENCODER_TEST=1 swift test --filter HardwareEncoder
MIRRI_RTC_HARDWARE_PROBE=1 swift test --filter RtcContractTests
MIRRI_PHYSICAL_DISPLAY_TEST=1 swift test --filter Physical
```

## How a session runs

1. **Find the tablet.** Over the cable with ADB, or a paired tablet that
   reached the host's rendezvous listener (TCP 5562, advertised as
   `_mirri._tcp`). See [`protocol/pairing.md`](../protocol/pairing.md).
2. **Hand over credentials.** A per-session token, the session certificate's
   pin and the Mac's address go to the tablet, by ADB launch or over the
   rendezvous connection.
3. **Control link.** The tablet connects to TCP 5561 with pinned TLS and
   presents the token.
4. **Display.** A 2456 × 1600 virtual display at 120 Hz is created and
   verified.
5. **Video.** WebRTC over UDP by default: ScreenCaptureKit frames, limited to
   60 per second, go through a low-latency hardware H.264 encoder. A TLS/TCP
   video path on port 5560 remains for comparison (`mirri connect --media tcp`).
6. **Input.** Touch and pencil events arrive on the control link and are
   posted as Quartz events on the virtual display.

If the path or the control link is lost, the host keeps the display for the
reconnect grace (15 s by default) and renegotiates. After that the session
ends, and a paired tablet asks for a new one.

## Control socket

The app listens on a Unix socket at
`~/Library/Application Support/Mirri/control.sock` (owner-only). One JSON
object per line, one request per connection. `mirri status --json` shows the
reply shape. The socket reaches the same actions as the panel and carries no
credentials.

## Things that will surprise you

- **The virtual display uses a private CoreGraphics API** through
  `VirtualDisplayShim`. It can break with a macOS update.
- **Sizes are fixed.** 2456 × 1600 appears as a literal in capture, encoder and
  protocol validation. This is deliberate: the host fails rather than scale.
- **The display runs at 120 Hz while the stream is 60 fps.** At 60 Hz the
  desktop skipped a refresh often enough to stutter; see
  [`docs/architecture.md`](../docs/architecture.md).
- **`adb` is expected at `/opt/homebrew/bin/adb`.**
- **`swift format lint --strict` and `tools/check_source_boundaries.sh` do not
  pass** on the WebRTC sources yet.
