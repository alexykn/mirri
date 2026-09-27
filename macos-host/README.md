# macOS host runtime (USB and opt-in Network with USB setup)

`MirriHost.xcodeproj` builds an unsandboxed menu-bar application, a Swift core
framework and the Objective-C virtual-display shim. Run `xcodegen generate`
after changing `project.yml`. Development checks:

```sh
cd macos-host
swift test
swift format lint -r --strict Core Tests App Tools
xcodebuild -project MirriHost.xcodeproj -scheme MirriHost \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test
```

Start only after Screen Recording and Accessibility permissions have been
granted to the **same stable app bundle identity** (a release build must be
signed consistently). Select an authorized physical USB device.
For USB, choose **Start USB**; it binds only 127.0.0.1 and requires installed
client `versionCode >= 2`. For **Network (USB setup)**, first put Mac and tablet
on an already reachable IP network (ordinary shared Wi-Fi LAN or tablet hotspot),
keep the authorized USB cable attached for the initial launch, install the
debug client `versionCode >= 3` **only with explicit owner approval**, and select
the device. In the menu choose **Start Network (USB setup) · <interface> <IPv4>**
for the exact current Mac address that the tablet can reach. Mirri rechecks that
interface/address before binding only it at TCP 5560/5561; a change fails rather
than binding another address. Allow macOS Local Network permission and inbound
traffic to those ports for the app in the firewall. The tablet must reach the
selected Mac address; Mirri does not configure Wi-Fi, hotspot, router rules,
Internet Sharing or ADB-over-TCP. After the first USB launch, reconnect epochs
use pinned TLS and require no ADB/cable; Stop or a fresh session needs USB setup
again. The certificate/key are ephemeral in memory and expire after 24 hours.
No cleartext fallback, persistent pairing, automatic discovery, Wi-Fi Direct,
Wi-Fi Aware, IPv6, or physical-network performance claim is provided. The
USB-only diagnostics below do not establish network-mode hardware behavior.
The source-level synthetic cross-platform test runs an ephemeral SwiftPM TLS
server against the desktop-JVM Android connector; it does **not** open tablet
connections or prove shared-LAN reachability. In **Settings (next session)**,
choose native 2456×1600 logical points or
1228×800 logical HiDPI (2× backing). Selection persists, applies only on the
next Start, and fails closed unless macOS reports the requested logical mode,
2456×1600 pixel backing, logical global bounds and 60 Hz. The owned HiDPI
display physically read back 1228×800 logical / 2456×1600 pixel backing @60;
native logical selection and four-corner pointer mapping still need owner
acceptance.
An installed runtime client with `versionCode >= 2` is required for USB: the inert milestone-0
client (`versionCode=1`) is deliberately refused. APK installation is an
explicit menu action, never automatic. `adb` defaults to
`/opt/homebrew/bin/adb`. The host accepts only entries with `usb:` in
`adb devices -l`, binds 127.0.0.1:5560/5561, and removes only reverse mappings
that it created.
If the host exits while ADB is offline, a later process cannot prove ownership
of an identical fixed-port mapping. On restart a conflict blocks Start with an
actionable status; while stopped, **Clean up Mirri USB reverse ports…** asks
for explicit confirmation and removes only tcp:5560/5561 mappings whose local
targets match those same ports. Inspect `adb -s <your-authorized-USB-device>
reverse --list` before confirming. A running process retains its in-memory
owned mapping record through a temporary USB loss and retries cleanup when the
same USB device becomes available again. Serial values are never logged.

USB launch intent extras: `mirri_token` (32 random bytes as 64 lowercase hex
characters), `mirri_epoch` (integer), `mirri_control_port=5561`,
`mirri_video_port=5560`, `mirri_protocol_major=1`, `mirri_mode=usb`.
Network adds `mirri_mode=network`, `mirri_host` (selected IPv4) and `mirri_pin`
(exact SHA-256 of its per-session DER certificate); missing/mixed extras fail
closed. Android sends ClientHello,
receives SessionConfig, connects video and sends VideoChannelHello, then sends
ClientReady only after its exact mode and hardware decoder are verified. The
host sends StartStream, codec configuration and IDR after readiness.
In USB mode every fresh host epoch, including a reconnect within grace, uses
`adb shell am start -S -n dev.mirri.client/.MainActivity` after releasing the
previous stream's sockets/capture. `-S` stops **only Mirri's process** and
starts a new activity/controller for the new epoch; it does not uninstall,
clear app data or touch other packages. Without that fresh activity, an old
foreground controller was observed to miss the next intent. The host retains
its verified display and owned reverse ports during temporary reconnect grace;
a full Stop releases them. A fake-adb two-epoch test checks the exact `-S`
component and epoch argument; physical Stop→Start and menu Reconnect resumed
streaming, but activity restart and cable-loss fault coverage remain pending.

Native video remains 2456×1600 AVC High 5.1 at a 40 Mbit/s configured target,
three capture→socket-write frame credits, and ScreenCaptureKit queue depth 2.
`minimumFrameInterval = .zero` deliberately requests the already verified
60 Hz virtual display's native capture cadence; `1/60` imposed an additional
throttle on the measured Mac. Matched 90-second owned-motion runs sent 56.64
versus 59.92 full-window fps; a separate 90-second owned-motion run sent 59.90.
The 30-minute run with old pacing sent a median interval 56.4 fps; a first
new-pacing soak stopped after about 200 seconds and is **not** accepted. A
later uninterrupted **1801.58 active-second** new-pacing baseline completed
without host state transitions, drops or reconnects, but SCK complete sent
**56.069 fps** and host USB write sent **54.341 fps**, failing the ≥59 fps
throughput gate. See [`../docs/native-validation.md`](../docs/native-validation.md)
for privacy-safe numeric evidence. Observation-only stage histogram source is
documented in [`../docs/timing-calibration.md`](../docs/timing-calibration.md):
it has not been deployed or physically calibrated and is pending parent review.
Neither host-submit→wire-write age nor USB RTT nor tablet framework render
notification measures actual tablet panel scanout.

Status menu includes requested/verified mode, per-stage interval metrics,
settings for hardware codec/bitrate, pinch mapping, USB disconnect grace,
explicit reconnect and access to bounded rotating local logs in Application
Support (`Mirri/Logs`, up to three 256 KiB files) and Console's `dev.mirri.host`
category. The log
contains only static state/errors; input coordinates, device serial, frames,
and authentication tokens are never logged. Selection of a remembered USB
device for auto-connect is opt-in; its serial is stored only in user defaults
and never emitted as diagnostics.

Builds and pure tests alone **do not validate** private CoreGraphics behavior,
real ScreenCaptureKit output, hardware codecs, sustained fps, permission
identity, USB unplug/replug or pen delivery. The owner-authorized HiDPI/AVC
observations above are physical evidence, **not** a release claim. Complete
remaining gates in `../IMPLEMENTATION_PLAN.md`; no physical input
reconnaissance or automatic APK installation is part of host tests.
