# Mirri

Use an Android tablet as a touch-enabled second display for a Mac, over Wi-Fi.

macOS sees a real extended display. Mirri captures it, encodes it with the
Mac's hardware H.264 encoder, sends it to the tablet with WebRTC over UDP, and
sends your touches and pencil input back.

> **This is a personal project.** I built it for my own Mac and my own tablet.
> It is not a product, it will not be published to the Google Play Store or the
> Mac App Store, and there are no prebuilt downloads. You build and install it
> yourself from this repository. See [Installing](#installing).

## Will it work for you?

Mirri is written for one specific tablet and refuses anything else:

- **Tablet:** Huawei model `TXZ-W09`, with its 1600 × 2456 panel and its
  hardware H.264 decoder. The app checks the exact resolution and decoder and
  rejects a different device rather than scaling.
- **Mac:** Apple Silicon, macOS 14 or later (developed on macOS 27).
- **Network:** both devices on the same Wi-Fi network or hotspot.

Making it work on another tablet means changing the fixed sizes in the host and
the client. That is doable but it is not a setting.

## What it does

- A 2456 × 1600 virtual display, as sharp HiDPI (1228 × 800 points) or with
  more space (2456 × 1600 points).
- 60 fps hardware-encoded video over WebRTC, with a bitrate that adapts to the
  network (or stays fixed if you prefer).
- Touch: tap, drag, long-press or two-finger tap for right click, two-finger
  scroll, pinch to zoom. Pencil position and the pencil's side button.
- **Pair once with the cable, then no cable.** After the first connection,
  opening Mirri on the tablet is enough: it finds the Mac and the display
  appears in a few seconds.
- Recovers by itself from a Wi-Fi dropout and keeps your windows in place for
  short ones.
- A small menu-bar panel, and a `mirri` terminal command that does everything
  the panel does.

Measured on my setup: about 59 to 60 frames per second presented on the tablet,
with more than 99% of frames shown for exactly one refresh. How that was
measured is in [`docs/architecture.md`](docs/architecture.md).

## Installing

The way I recommend, and the way I do it myself:

1. **Clone this repository** on the Mac.
2. **Turn on USB debugging** on the tablet (Settings → About tablet → tap
   *Build number* seven times, then Developer options → *USB debugging*),
   plug it in, and accept the "Allow USB debugging?" prompt.
3. **Let a coding agent do the setup.** Open the repository in an agent such
   as Claude Code and give it this:

   > Set up Mirri on this Mac and the attached tablet by following
   > `docs/setup.md`. Stop and tell me whenever a step needs me.

The agent builds both apps, installs them, and connects once over the cable to
pair the tablet. Three steps need a person and the guide tells the agent to ask
for them: creating a local code-signing certificate, granting the Mac app
Screen Recording and Accessibility, and accepting prompts on the tablet.

Prefer to do it by hand? [`docs/setup.md`](docs/setup.md) is written so a
person can follow it too.

## Using it

Day to day there is nothing to do: **open Mirri on the tablet** and the display
appears. The menu-bar panel (▣ Mirri) shows the tablet, the live frame rate,
bitrate and ping, and a Disconnect button. Settings are behind the gear icon.

From a terminal:

```sh
mirri status                 # state, display modes, live numbers
mirri connect                # connect to the available tablet
mirri disconnect
mirri reconnect
mirri set --size retina      # sharper text; --size native for more space
mirri set --avc-bitrate 40   # quality ceiling in Mbit/s (20 to 80)
mirri set --adaptive-bitrate off
mirri set --auto-connect off # do not start when the tablet opens Mirri
mirri paired                 # tablets that can connect without a cable
mirri unpair
mirri install app-debug.apk  # install or update the tablet app (needs the cable)
mirri watch                  # one status line per second
mirri show | hide | logs | quit
```

Run `mirri` with no arguments for every option.

## Known limits

- **One tablet model only**, as above.
- **The first pairing needs the USB cable.** Every later connection does not.
- **Touching the tablet makes its panel switch to 90 Hz** for a few seconds
  (the tablet's own power policy), which makes motion a little less even while
  you touch. The app cannot turn that off.
- **No audio, HDR or portrait mode.**
- **There is noticeable delay.** On the older TLS video path I measured about
  70 to 90 ms from capture on the Mac to presentation on the tablet. The WebRTC
  path has not been measured the same way. Fine for windows, documents and
  terminals; not for fast games.
- **Security is reasonable for a home network, not hardened.** Video and
  control are encrypted and the tablet only talks to the Mac it was paired
  with. The details and the gaps are in
  [`protocol/pairing.md`](protocol/pairing.md).
- **It uses a private macOS API** to create the virtual display, so a future
  macOS update can break it.

## How it is put together

```
macos-host/       Swift menu-bar app, core framework, `mirri` command
android-client/   Kotlin tablet app
protocol/         wire formats: control, WebRTC signalling, pairing
tools/            install scripts and measurement tooling
docs/             setup guide, architecture notes, measurements, history
```

| On the Mac | On the tablet |
| --- | --- |
| Private CoreGraphics virtual display at 120 Hz | Finds the Mac over Bonjour, pinned TLS |
| ScreenCaptureKit capture, limited to 60 fps | WebRTC receive, hardware `MediaCodec` decode |
| VideoToolbox low-latency H.264 | Frames paced one per screen refresh |
| WebRTC (UDP), control over pinned TLS | Touch and pencil sent back over the control link |

More detail: [`docs/architecture.md`](docs/architecture.md) for the design and
the measurements behind it, [`macos-host/README.md`](macos-host/README.md) and
[`android-client/README.md`](android-client/README.md) for each side, and
[`docs/project-log.md`](docs/project-log.md) for how the project got here.

## Contributing

This is my own tool and I change it to suit my setup. You are welcome to fork
it and to open issues, but I may not act on them, and I am not looking to
support other devices.

## License

MIT. See [`LICENSE`](LICENSE).
