# Mirri client (Android)

The tablet side: it shows the Mac's display full screen and sends touch and
pencil input back. For what Mirri is and how to install it, start at the
[main README](../README.md).

This app is sideloaded as a debug build. It is not on the Google Play Store
and is not going to be.

## Layout

```
app/src/main/java/dev/mirri/client/
  MainActivity.kt   full-screen surface, waits for the paired Mac
  session/          one session: connect, negotiate, retry
  pairing/          stored pairing, Bonjour discovery, rendezvous
  video/            hardware decoder, presentation pacing, WebRTC receiver
  display/          panel mode selection and readback
  input/            touch and pencil gestures
  protocol/         wire codec, control channel, WebRTC signalling
  transport/        pinned TLS connection
```

## Build, install, test

```sh
export JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home
export ANDROID_HOME=/opt/homebrew/share/android-commandlinetools
./gradlew assembleDebug                # app/build/outputs/apk/debug/app-debug.apk
./gradlew testDebugUnitTest ktlintCheck
./gradlew ktlintFormat                 # fix formatting
```

Install with the host, over the cable:

```sh
mirri install app/build/outputs/apk/debug/app-debug.apk
```

Warnings are errors in this build, and ktlint is strict.

## How it starts

- **From the Mac over the cable:** the host starts the activity with the
  session's credentials as Intent extras. The same launch stores the pairing.
- **By itself, once paired:** opened with no launch, the app looks for the Mac
  with network service discovery (`_mirri._tcp`), falls back to the address
  that worked last time, connects with TLS pinned to the Mac's certificate and
  waits to be handed a session.

When a session ends the app goes back to waiting. A session that failed asks
the Mac to start again; one the Mac stopped does not.

## Things that will surprise you

- **One tablet model.** The client requires a 1600 × 2456 panel and a hardware
  H.264 decoder that reports 2456 × 1600 at 60 fps. Anything else is rejected,
  not scaled.
- **Panel refresh.** It asks for the 120 Hz mode and falls back to 60 Hz when
  the tablet's own policy refuses, which this model does (it caps the app at
  90 Hz, and switches to 90 Hz for a few seconds after a touch).
- **Frames are held briefly on purpose.** Each decoded frame is stamped 24 ms
  ahead and one refresh after the previous one. Without that, about one frame
  in ten was replaced before it was ever shown.
- **A low-latency Wi-Fi lock is held while streaming** to keep the radio out
  of power save.
- **The activity is exported** so the host can launch it. Any app on the
  tablet can therefore send it a launch. See the limits in
  [`protocol/pairing.md`](../protocol/pairing.md).
- **Target SDK is 31** to keep the immersive landscape behaviour this tablet
  was tested with.
