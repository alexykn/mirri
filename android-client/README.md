# Mirri Android client (runtime preview)

`app` is the single Android module; the debug APK is produced at
`app/build/outputs/apk/debug/app-debug.apk` (`versionCode=3`). It is not a
physically accepted release. **Do not install it on the tablet without an
explicit owner action.** The Mac host launches it with the one-time token,
epoch, protocol version, mode, and either two USB `adb reverse` loopback ports
or a pinned TLS IPv4 endpoint. Network (USB setup) needs an authorized initial
USB launch but reconnects over the selected IP interface without ADB; both
channels verify the pinned, nonexpired ephemeral certificate before any token
is sent. The network control channel obtains the host's current epoch through
the fixed MRNB preface inside TLS; USB framing and direct `SocketChannel`
processing are unchanged. TLS uses bounded reusable 16 KiB input/output scratch
buffers, not frame-sized heap copies. Wrong/expired server identity is terminal.
This is **not** Wi-Fi Direct or a claim of device-verified network streaming.
Desktop-JVM tests connect this production TLS connector to an ephemeral
production macOS loopback server with a small synthetic payload and wrong-pin
rejection; they are not a tablet connectivity or performance measurement.

The AndroidX `ComponentActivity` collects a lifecycle-aware `StateFlow` status.
Its immersive landscape `SurfaceView` selects/readbacks the exact physical
1600×2456@60 mode before `ClientHello` (the current host requires this active
mode), then re-verifies it after negotiation. Only an exact 2456×1600 surface
and a hardware AVC/HEVC decoder supporting 2456×1600@60 are accepted. On the
authorized tablet a transient 90 Hz mode converged through a bounded
own-display change listener to requested/observed 1600×2456@60 before Hello;
the listener unregisters on success, timeout or cancellation. A hardware AVC
decoder reported coded 2464×1600 with visible crop 0,0–2455,1599, BT.709
limited; incorrect visible crop/size/color readback fails closed. Video
uses an asynchronous `MediaCodec` callback; configure, submit, flush and stop
are serialized on the codec's HandlerThread. Cancellable fixed-pool leases
return even after receive/cancellation failures. Codec probe, pool, decoder and
receiver have separate owners; each attempt closes only its own resources;
control and video are separate channels. No Wi-Fi topology provisioning or software decoder exists.
Each reconnect attempt owns its sockets, decoder, frame counters and failure
gate, and finally closes those resources before detaching the Surface. After
USB Stop/retry needs a fresh host `am start -S` activity/controller and epoch;
the host retains only its own reverse mappings/display within reconnect grace.
Source tests cover old-attempt callback rejection and blocked-socket release,
not activity restart or cable unplug/replug. Observed native AVC40 90-second
host sent rates were 59.92/59.90 full-window fps with SCK queue 2, three frame
credits and native 60 Hz capture cadence; the older 30-minute median interval
sent 56.4, an initial new-pacing soak was interrupted, and a subsequently
completed uninterrupted 1801.58 active-second new-pacing soak sent only
**54.341 fps** at host USB write. It **fails** the ≥59 fps sustained gate.
See [`../docs/native-validation.md`](../docs/native-validation.md). The new
numeric-only codec/render stage probe in
[`../docs/timing-calibration.md`](../docs/timing-calibration.md) is
**source-only, not deployed**; framework render notification is not panel
scanout and requires calibration and callback-coverage checks.

From this directory, with JDK 17 and Android SDK 35 configured:

```sh
./gradlew testDebugUnitTest assembleDebug ktlintCheck
```

These checks validate compilation, JVM fixture/gesture/bounds/localhost
transport tests, and formatting; they **do not** verify the physical mode,
decoder/compositor colorimetry (Android has no explicit sRGB transfer enum),
actual key delivery, 59+ fps, 30-minute memory stability or unplug/replug.
The optional hardware `FEATURE_LowLatency` is advertised and enabled only
when supported; absence does not reject an exact hardware decoder. Actual
decoder behavior still requires device measurement. No physical integration
claim should be inferred from a built APK.
