# Sampled cross-device latency measurement

This is **observability**, not a change to video admission, encoder, transport,
decoder or input policy. Building this source does not start a device run.
Existing schema-v4 FPS/histogram records, ownership, coverage gates and Python
aggregation remain authoritative. Both endpoints **always emit** their separate
compact numeric trace while streaming; collection/analysis of these lines is
opt-in and does not alter v4 parsing. Never record pixels, input content,
addresses, hardware IDs, bearer tokens or the raw session ID.

## Ownership, identity and clocks

Host samples exactly ordinal `sequence % 6 == 0`, batches at most ten frames
per report and retains at most 20 ready metadata entries; sampling never holds
a video buffer. A new
trace ID is SHA-256(`mirri-latency-v1` || random 16-byte session ID), truncated
to 128 bits, independently computed at both endpoints. It is a noncredential
label (the secret authentication token is unrelated), scoped with the epoch,
generation, sequence and decoder PTS (the latter truncates ns to µs). A new
session gets a new session ID; a reconnect retains the trace ID but increments
epoch. Both endpoints record `route=network|usb`; collection requires the
expected route, preventing the old hardcoded “USB” UI label from identifying
the wrong path. Host immutable `EncodedUnit` stamps already carry capture **callback**,
VT submit, VT callback and conversion times; a packetizer hook stamps frame
send entry and existing sender completion stamps `.contentProcessed`. Android
uses its existing `VideoTimingOwner` frame and pending-render joins to stamp
packet completion, codec queue, output availability, release request **and**
return, and reported render time. Framework render may precede release return
but not release request. It never adds a second AU queue or per-frame coroutine.
The trace is unavailable after an ambiguous same-codec generation flush.

All host stamps are `DispatchTime.uptimeNanoseconds`; all tablet stamps are
`System.nanoTime`. SCK media PTS remains an **unverified different clock**:
capture PTS→callback age is unavailable. No raw cross-device subtraction and
no sum of independent stage p95 values. Existing Pong fields already echo the
host Ping's monotonic request stamp and carry client receive/reply stamps;
decode all four timestamps and the sequence, and reject mismatched, duplicate,
unordered or invalid exchanges. For offset `client − host`, one exchange
gives the causal interval `[clientSend − hostReceive,
clientReceive − hostSend]`. This does **not** assume symmetric path latency.
Intersect fresh intervals if possible; an empty intersection indicates
inconsistent clocks/scheduling and makes calibration unavailable, never a
forced point estimate. Offline bounds for matched frame ages use the entire
offset interval, not its midpoint. A conservative configured oscillator
drift allowance (100 ppm relative, explicitly a measurement assumption rather
than guaranteed hardware bound) expands each interval to include **both**
request and reply endpoints in each clock domain, even if a sample coincides
with reply. After 15 s, a reporting gap >2.5 s, retry/reconnect or impossible
ordering it is stale and **affected** ages become unavailable; unrelated
continuous segments remain diagnostic. A short unobserved sleep
cannot be excluded without an external clock; no finite unconditional
accuracy claim.
Render timestamps are Android framework reports, **not panel scanout**;
input-to-photon and capture presentation-to-display are not measured.

## Records and coverage

One compact host trace line and one tablet trace line per second, each at most
3900 ASCII bytes including log prefixes, with a bounded ten-sample batch and
explicit selected, missing-invalid/unwritten, dropped-at-capacity, ambiguous
and render-censored counters. Ready capacity 20 and 10-record batches prevent
unbounded growth, but an unusually delayed report can drop samples; the
counter must accompany any coverage claim. Existing v4 records
retain complete/admitted/written/received, expired and render-coverage counts;
do not conflate one-second trace batch count with frames selected in that
same interval when a callback straddles a report. Ping/Pong calibrations are
separately batched in the host line. Frames
are joined only by trace ID, epoch, generation, frame sequence and exact
decoder PTS; duplicates and incompatible identities fail closed. Missing
render notifications do not become zero-latency frames. Report valid sample
coverage, age lower/upper p50/p95/p99 and exact max, plus calibration width
and stale/unavailable counts. Keep legacy v4 stage histogram and render
coverage conclusions separate. Gap/stall bursts describe measured motion
windows; an SCK `.idle` status is not a network stall.
The trace retains unresolved selected render joins through the authoritative
metadata lifetime (normally 30-second TTL, earlier capacity eviction), and
only censors on actual expiry, eviction, generation flush or final cleanup.
This is not the existing v4 two-second final-window right censor or a proof of
a permanently missing render notification. An old client
without the trace tag makes an opt-in latency collection incomplete, while
existing FPS/v4 collection remains available.

## Verification and use

Unit tests cover asymmetric clocks, duplicate/mismatched exchanges, timestamp
inversion, stale/drift and reconnect, sampled sequence joins, slow renders,
and worst-case bounded record length. Cross-language production emitter
fixtures feed the optional Python aggregator. For a repeatable baseline, use
the same signed host
identity/TCC grant, exact APK/build, mode, display resolution, codec/bitrate,
power/thermal conditions and owned independent display-link motion. Run a
complete Wi-Fi window first, then route-confirmed matched USB. Preserve
numeric-only logs before rotation and both v4 **and** trace finals. Without
`--latency`, the collector keeps strict v4 behavior (including abort after
three consecutive empty capture/receive intervals). With `--latency`, it
retains freeze/heartbeat records until the bounded deadline, reports numeric
gap facts and partial per-segment age/coverage diagnostics, and returns an
incomplete, non-acceptance result if a complete v4 + trace window cannot be
validated. Never calibrate across a gap or reconnect.

## Repeatable baseline commands

Build the **source-only** `MirriOwnedMotion` SwiftPM executable separately;
its only runtime action, after an explicit arm flag, is drawing an alternating
checkerboard in one borderless window on exactly one online non-main display
whose Mirri virtual-display vendor/model and 2456×1600 backing size match.
`NSScreen.displayLink` animates the helper's own view; it never captures
screens, accesses tablet APIs or starts/stops Mirri. It exits after the
configured duration and prints only stimulus tick counts, **not** captured
frames or input-to-photon timing. Verify the intended display and stable signed
host bundle/Screen Recording grant before a trial; an unsigned rebuilt host may
lose its grant. Callback-to-framework-render age is **not** input-to-photon.

For an otherwise idle session, record locally the host source
revision, signed app identity/path, APK version/hash, power/thermal mode, fixed
2456×1600 backing/1600×2456 tablet mode @60 Hz and AVC40 settings, then:

```sh
cd macos-host && swift build --product MirriOwnedMotion && cd ..
# Use a fresh private output directory; start the read-only observer BEFORE
# connecting with the control script. This attaches filtered ADB logcat
# through the USB *debug cable* only; media still must prove route=network.
# This does not establish unplugged Wi-Fi behavior and does not alter reverse
# mappings, the client or the host.
python3 -u tools/collect_timing.py --active-seconds 90 --latency \
  --expected-route network --output-dir /tmp/mirri-latency-wifi-90
# In a second terminal, use the `mirri` command. It waits for streaming;
# the helper then verifies the owned display, including native/Retina backing:
mirri connect --address en0
"$(cd macos-host && swift build --show-bin-path)/MirriOwnedMotion" \
  --arm-owned-display --active-seconds 90
# Stop through the same production owner promptly after helper completion; retain
# both v4/trace finals. An incomplete diagnostic is useful but not accepted.
mirri disconnect
# Analyze the exact same files offline only if both finals are present:
python3 tools/aggregate_timing.py --active-seconds 90 \
  --host /tmp/mirri-latency-wifi-90/host-timing.log \
  --client /tmp/mirri-latency-wifi-90/client-timing.log \
  --host-latency /tmp/mirri-latency-wifi-90/host-latency.log \
  --client-latency /tmp/mirri-latency-wifi-90/client-latency.log \
  --expected-route network
```

Only after the Wi-Fi motion window and its stage/age/stall results are stable,
repeat a **matched route-proven `usb`** run with the identical signed host,
APK, helper duration, display settings, motion and thermal conditions,
changing `--expected-route` and the private output directory. Do **not**
silently treat idle SCK callbacks as a transport outage or report a partial
diagnostic as a full-window latency acceptance. Using a USB ADB debugging
cable during network media collection cannot establish unplugged Wi-Fi
behavior.

## AVC low-latency experiment — 2026-09-27

**Provisional decision: retain AVC hardware low-latency rate control.** This is
a separate encoder change, not part of the observability design above. Apple
requires High AutoLevel and an infinite GOP in this mode: it removes lookahead
and periodic IDRs, not just a queue setting. The first frame of every codec
generation remains an IDR with parameter sets. Decoder resynchronization already
recreates the generation; it does not rely on the next periodic IDR. HEVC,
40 Mbit/s AVC target, four admission credits, capture cadence/queue depth and
Android decoder settings are unchanged. Hardware availability probing uses the
same encoder settings as the stream and does not silently fall back to the old
AVC mode.

An opt-in test of the production encoder verifies AVC and HEVC emit the final
frame without future input or an explicit flush, start with parameter sets and
an IDR, and keep AVC High AutoLevel within the negotiated Level 5.1 capability:

```sh
MIRRI_HARDWARE_ENCODER_TEST=1 swift test --package-path macos-host \
  --filter HostRuntimeTests/testHardwareEncoderEmitsFinalFrameWithoutFutureInput
```

The original encoder also passes the final-frame test; indefinitely held final
frames were **not** demonstrated. `MaxFrameDelayCount=0` and `=1` both prevented
hardware encoder preparation on this Mac and were removed. Black-frame encode
timing did not predict the benefit seen with the owned-display motion workload.

Each physical run used the same 90-second checkerboard stimulus, Retina logical
1228×800 / encoded 2456×1600 @60 Hz, tablet 1600×2456 @60 Hz, unchanged APK and
USB debug cable. No Mac thermal warning was reported; tablet was USB-powered,
100% battery, 26 °C. Trials were sequential, not randomized or simultaneous;
background activity and Wi-Fi conditions remain uncontrolled.

| Metric | Wi-Fi baseline | Wi-Fi candidate | USB baseline | USB candidate |
| --- | ---: | ---: | ---: | ---: |
| Encoder callback p50 histogram bound, ms | 42 | 14 | 42 | 14 |
| Encoder callback p95 histogram bound, ms | 46 | 16 | 44 | 16 |
| Sampled callback→render p50 bounds, ms | 102.8–115.0 | 72.2–85.1 | 96.5–105.7 | 61.4–68.9 |
| Sampled callback→render p95 bounds, ms | 184.3–204.3 | 137.3–151.1 | 119.3–127.6 | 71.2–78.7 |
| Sampled callback→render maximum bounds, ms | 471.4–480.5 | 530.7–542.9 | 146.5–154.4 | 240.3–249.8 |
| Sent frames/s over complete window | 57.60 | 56.29 | 54.33 | 57.93 |
| Render-report coverage | 73.55% | 69.61% | 92.91% | 93.12% |
| Encoded AU throughput, Mbit/s | 7.51 | 7.95 | 6.68 | 8.29 |

All four have complete collection windows but **incomplete renderer evidence**;
none is a full smoothness acceptance. These are sampled, censored framework
render ages, not physical scanout or input-to-photon. The fixed every-sixth-frame
sampling is phase-coupled to baseline GOP60, whereas the candidate removes that
periodic GOP. Do not treat the sampled percentile changes as unbiased population
estimates. Full-frame host histograms independently show the encoder improvement.
Wi-Fi tails remain substantial, render coverage is lower in its candidate run,
and both candidate sampled maxima are worse. No startup/scene-change outliers
were trimmed. The candidate does not demonstrate lower bandwidth or sustained
60 rendered frames/s, and visual quality under complex content remains untested.

Ignored local evidence is preserved under
`artifacts/latency-baseline-2026-09-27/` and
`artifacts/latency-lowlatency-2026-09-27/`: filtered numeric logs, original reports,
stimulus logs and build identities. Candidate Wi-Fi/USB reports are
`mirri-latency-lowlatency-{wifi,usb}-90-v1.json`. The installed development app
retains the candidate; its persistent certificate-backed designated requirement
survived the real binary update and both connections without a TCC reset or
reapproval. The previous signed bundle remains available locally for rollback.
