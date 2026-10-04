# Setting up Mirri

A step-by-step guide for a coding agent (or a patient person). Run commands
from the repository root on the Mac. Steps marked **Needs a person** cannot be
done from a terminal: stop there and ask.

Nothing here publishes anything or changes system-wide settings. The host app
goes to `~/Applications`, the `mirri` command to `~/.local/bin`, and the tablet
gets one sideloaded debug app.

## 0. What you need

| Requirement | Check |
| --- | --- |
| Apple Silicon Mac, macOS 14 or later | `sw_vers; uname -m` |
| Xcode (full, not just command-line tools) | `xcodebuild -version` |
| Android platform tools at `/opt/homebrew/bin/adb` | `brew install android-platform-tools` |
| JDK 17 | `brew install openjdk@17` |
| Android SDK with platform 35 | `brew install --cask android-commandlinetools`, then `sdkmanager "platforms;android-35"` and accept the licences; Gradle fetches the rest |
| The tablet: Huawei `TXZ-W09` | Mirri rejects other models |
| Mac and tablet on the same Wi-Fi | |

The host looks for `adb` at exactly `/opt/homebrew/bin/adb`.

## 1. Tablet: USB debugging — **Needs a person**

On the tablet: Settings → About tablet → tap *Build number* seven times.
Then open *Developer options* (under System on most tablets) and turn on
*USB debugging*.
Connect the cable and accept *Allow USB debugging?* on the tablet.

Check:

```sh
adb devices -l      # expect one line ending in "device", with model:TXZ_W09
```

`unauthorized` means the prompt on the tablet has not been accepted.

## 2. Mac: a code-signing certificate — **Needs a person**, once

macOS ties the Screen Recording and Accessibility permissions to how the app is
signed. Signing every build with the same local certificate keeps those
permissions across updates.

In **Keychain Access**: menu Keychain Access → Certificate Assistant → *Create
a Certificate…*

- Name: `Mirri Local Development`
- Identity Type: *Self-Signed Root*
- Certificate Type: *Code Signing*

Check:

```sh
security find-identity -p codesigning | grep "Mirri Local Development"
```

To use a different identity, set `MIRRI_SIGN_IDENTITY` for the next step.

## 3. Mac: build and install the host

```sh
bash tools/install_host.sh     # builds, signs, installs to ~/Applications, starts it
bash tools/install_cli.sh      # builds `mirri` and links it into ~/.local/bin
mirri status                   # should print a state, not "Mirri is not running"
```

If `mirri` is not found, add `~/.local/bin` to `PATH` or set `MIRRI_CLI_DIR`.

The first time `codesign` uses the new certificate, macOS may ask to allow
access to the key. Choose *Always Allow*. **Needs a person.**

## 4. Mac: permissions — **Needs a person**, once

Mirri asks for its permissions when you first try to connect, one at a time.
Run `mirri connect`; it stops with "Grant Screen Recording and Accessibility"
and macOS shows a prompt. Grant it, then run `mirri connect` again for the
second one. You can also enable both directly in System Settings → Privacy &
Security:

- *Screen & System Audio Recording* → enable **Mirri Development**
- *Accessibility* → enable **Mirri Development**

After granting Screen Recording, quit and reopen Mirri (`mirri quit`, then
`mirri launch`). macOS may also ask to let Mirri find devices on the local
network: allow it.

This step can only be finished once the tablet app is installed (step 5), so
come back to it if the first `mirri connect` complains about the tablet
instead.

## 5. Tablet: build and install the client

```sh
cd android-client
export JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home
export ANDROID_HOME=/opt/homebrew/share/android-commandlinetools
./gradlew assembleDebug
cd ..
mirri install android-client/app/build/outputs/apk/debug/app-debug.apk
```

The tablet may show an install confirmation. **Needs a person** if it does.

## 6. Connect once over the cable to pair

```sh
mirri connect       # waits until streaming, or prints why it could not
mirri status
```

The Mac now has an extra display and the tablet shows it. This first
connection also pairs the tablet. Confirm:

```sh
mirri paired        # prints the tablet's model
```

## 7. Cable-free check

```sh
mirri disconnect
```

Unplug the cable, then open **Mirri** on the tablet. Within a few seconds the
display should come back by itself. `mirri status` shows
`Network … (paired)` as the tablet.

## If something goes wrong

| Symptom | Likely cause |
| --- | --- |
| `Mirri is not running` | `mirri launch`. If it still fails, rerun `tools/install_host.sh`. |
| Stuck at "Checking permissions" or fails at once | Step 4 not done, or done for an older build signed differently. Run `tccutil reset ScreenCapture dev.mirri.host`, reopen Mirri and grant again. |
| `ADB is unavailable or the USB tablet is not authorized` | Step 1, or `adb` is not at `/opt/homebrew/bin/adb`. |
| `Client rejected the fixed resolution, refresh or hardware codec` | The tablet is not a `TXZ-W09`, or its app is older than the host: redo step 5. |
| Connects with the cable but never without | Mac and tablet on different networks, or the network blocks device-to-device traffic. Reconnect once over the cable on the new network. |
| Works, then stops after a host update | Rebuild and reinstall both sides (steps 3 and 5) and connect once over the cable. |

Logs: `mirri logs` prints the host log folder. On the tablet:
`adb logcat -s MirriLifecycle MirriRendezvous MirriDisplay MirriDecoder`.

## Updating later

```sh
git pull
bash tools/install_host.sh && bash tools/install_cli.sh
(cd android-client && ./gradlew assembleDebug)   # with JAVA_HOME and ANDROID_HOME set as above
mirri install android-client/app/build/outputs/apk/debug/app-debug.apk
mirri connect
```

Installing the tablet app needs the cable; everything else does not.

## Removing it

```sh
mirri quit
rm -rf ~/Applications/"Mirri Development.app" ~/.local/bin/mirri
rm -rf ~/Library/"Application Support"/Mirri
adb uninstall dev.mirri.client
```

Then remove Mirri from the two Privacy & Security lists and delete the
certificate in Keychain Access if you no longer want it.
