# Native video validation checkpoint (2026-09-26)

**Development measurements, not release acceptance.** The owner authorized
Mirri-only tests on the TXZ-W09 and an Apple Silicon Mac. This file contains
only numeric aggregate observations; it contains no screen images, frame
contents, input traces, USB identifiers, session tokens or private video.
Do not repeat device interaction without owner approval.

## Reproduce the comparison safely

1. With the owner's approval, use the same stable-path Mirri host and matching
   client, select the authorized USB device, and choose HiDPI. Verify the Mac
   owned display is **1228×800 logical / 2456×1600 backing @60 Hz**, the tablet
   owning display is **1600×2456 @60 Hz**, the Surface is 2456×1600 and AVC
   hardware reports exact visible 2456×1600 (on this tablet coded 2464×1600,
   crop 0,0–2455,1599, BT.709 limited). Reject mismatches; do not change the
   tablet's global display policy. AVC High 5.1 is configured with 40 Mbit/s
   target; actual transmitted bits vary with content.
2. Use only an owner-approved synthetic moving window covering the **owned
   Mirri virtual display**, not private desktop content. In these trials one
   window's full-view color tiles and position changed at a 120 Hz timer; an
   independent checkerboard/window motion source used a 60 Hz timer. Timers
   are stimulus, **not** evidence of captured/displayed frames. Keep the same
   three-slot capture→socket-write admission, SCK queue depth 2, exact native
   dimensions, codec/bitrate, display, and ~90 s active observation for an A/B.
3. Filter host interval metrics to numeric capture complete/admitted/encoded/
   sent, SCK statuses, PTS gaps, dropped/credit failures and cumulative totals;
   obtain only numeric Android receive/decode/age counters. Use *full active
   elapsed seconds* and cumulative frame deltas for the primary throughput
   calculation, not the median of per-second fps or wall time after idle. Keep
   host submit→wire-write and tablet packet→decoder-release on their **own**
   clocks; never subtract timestamps across devices or call output release
   panel scanout. Stop the synthetic window before Mirri Stop, then confirm
   owned display and reverse mappings are released. Discard transient logs.

## Observations and limits

| Identical native AVC40 path, 90 s owned motion | SCK complete / active seconds | Sent / active seconds | Other numeric observations |
| --- | --- | --- | --- |
| Explicit `minimumFrameInterval = 1/60` | 5131/90.43 = 56.74 fps | 5122/90.43 = **56.64 fps** | SCK idle 29, PTS gaps >25 ms 292, credit skips 9; zero reported drops/reconnect |
| `minimumFrameInterval = .zero`, native 60 Hz display cadence | 5370/89.50 = 60.00 fps | 5363/89.50 = **59.92 fps** | SCK idle 0, PTS gaps >25 ms 1, credit skips 7; zero reported drops/reconnect |
| `.zero`, independent 60 Hz checkerboard/window motion | 5430/90.53 = 59.98 fps | 5423/90.53 = **59.90 fps** | SCK idle 0, PTS gaps >25 ms 2, credit skips 7; zero reported drops/reconnect |

The verified virtual display already refreshes at 60 Hz. The retained
`.zero` setting removes an extra ScreenCaptureKit throttle; it is **not** an
instruction to claim an unlimited stream. The newer 90 s host callback and
sent-frame results exceed 59 fps. Tablet interval decoder counters were near
60 fps, but full-window independent tablet scanout and end-to-end display
latency were not measured. No frame content was persisted.

An older **1800.3 s uninterrupted** owned-motion run with `1/60` had median
interval capture **56.8** and sent **56.4 fps**, zero reported drops/errors/
reconnect, host RSS first/peak/final **61680/62400/62336 KiB**, client PSS
first/peak/final **67782/75925/75741 KiB**. It proves neither the throughput
gate nor stability of the *changed* capture pacing. A new `.zero` run reached
197 positive-capture intervals (~199.4 s): complete 11947 (~59.91 fps), sent
11914 (~59.75 fps); then 14 intervals without capture and a normal host
Stop/idle transition. The cause is **unknown**; elapsed idle time is excluded.
This attempt **did not complete a 30-minute soak**. The numeric collector now
terminates on Stop/idle, prolonged no-metrics/capture, reconnect or error.

### Completed 30-minute `.zero` baseline — 2026-09-26, **throughput fail**

With the final-source-tested host framework (including the ADB reverse
lost-lease fix), same-signature v2 client, exact modes above, AVC40, cap 3,
SCK queue 2 and `.zero`, the owner-authorized continuous owned checkerboard/
window-motion timer ran at p50 **60.00 ticks/s** (not a capture count).
The collector started **13:25:30 UTC** and ended **13:55:34 UTC**. It required
**1801.58 actual actively captured stream seconds**, not merely 1803.9 wall
seconds; 1771 continuous host metric intervals had **zero** host state
transitions/errors/reconnects and zero client-reported dropped frames or
decoder-age evictions. The motion/logcat/process-scoped sleep assertion were
stopped, then Mirri's own Stop released both reverse mappings and the owned
display. No permission, persistent power setting, private pixels or device
identifiers were changed/stored.

| Whole window (first to last active metric, no selected high-rate subset) | Count / denominator | Rate or limit |
| --- | ---: | ---: |
| SCK complete frame cumulative delta | 101013 / 1801.58 s | **56.069 fps** (fails ≥59) |
| Host framed USB write cumulative delta | 97900 / 1801.58 s | **54.341 fps** (fails ≥59) |
| Host admission/encode (integral of reported interval rates; *estimate*, not lifetime counters) | ~97902 each / 1801.58 s | ~54.34 fps |
| Tablet receive/input/output (sum of latest relayed one-second count-like metrics; **not** unique lifetime counters) | ~96479 / ~96479 / ~96469 | ~54–56/s interval medians; relayed metrics can repeat/omit |
| Tablet packet-complete→decoder-release unique age samples | 98028 across 1800 tablet intervals | p50 of interval medians **26.35 ms**; p50 of interval p95 **110.01 ms**, worst interval p95 **135.48 ms** |

First/middle/last ten-minute host send cumulative-delta rates were
**54.084/54.346/54.573 fps**; capture complete **55.773/56.223/56.191**.
Host submit→wire-write interval median p50 **43.4 ms**, median of interval
p95 **67.4 ms**, worst interval p95 **87.4 ms**. Per-interval complete-frame
PTS median p50 **16.7 ms**, interval p95 either 16.7 or 33.3 ms (p95 of
interval p95 **33.3 ms**); **7111 of 101065** bounded PTS-gap samples
(~7.0%) exceeded 25 ms, in 1391 intervals, longest consecutive interval
run 78. SCK emitted **6495 idle statuses** (~3.6/s), admission rejected
**3115** at full credits (~1.7/s), with zero format/encode-submission errors.
Among 1771 ~one-second intervals, host USB send was <55 fps in **155 runs / 761
intervals**, longest run **60 intervals**; this is a declared threshold, not
an individual frame-gap histogram. No exact individual worst PTS gap is logged
by the bounded metric owner. Host queue depth p50/p95 **3/3**, client encoded
buffer queue p50/p95 **0/1**. First/peak/last host RSS
**73856/81296/68512 KiB**, client PSS **75316/80568/80268 KiB**;
ten-minute host age p95 median **67.7/67.9/66.7 ms**, client packet→release
interval median **27.98/25.84/25.77 ms**, client interval p95 median
**112.49/108.52/109.67 ms**: no monotonic delay or memory growth in these
samples. Age stages use separate same-host/same-tablet monotonic clocks; they
cannot be added to infer panel presentation or end-to-end latency.

**Verdict:** duration, no-drop/reconnect and sampled memory bounds pass for
this *unchanged baseline*, but **≥59 fps throughput fails at every measured
host stage** and stutter/latency tails are material. Short 90 s ≥59 runs above
remain valid observations, not proof of sustained acceptance. This baseline
does not validate a future runtime optimization: any change needs fresh
controlled A/B and a new soak for sustained acceptance.

**Remaining gates:** a quality-preserving, controlled improvement followed by
an uninterrupted 30-minute run **≥59 fps** at host complete/encode and tablet
receive/decoder, bounded queues/memory and no increasing delay; physical native
logical mode/four-corner input and activity/surface/USB fault recovery;
owner inspection of image/color, a particularly complex video's artifacts,
heat/battery and latency; actual panel presentation and release signing/
permission identity. No lower-resolution mode is retained, and neither
short-window success nor the interrupted attempt passes these gates.

### Schema-3 observability calibration, first approved 90 s attempt — incomplete

After parent source approval, the reviewed host framework was copied to the
same stable `~/Applications/Mirri Development.app` bundle and the same-signature
debug v2 APK updated in place; permissions and app data were retained. One
authorized USB tablet was present. Existing settings remained HiDPI, automatic
AVC preference/configured 40 Mbit/s, three frame credits, SCK queue depth 2
and `.zero` capture cadence. The host entered streaming and verified its owned
display at **1228×800 logical / 2456×1600 backing @60 Hz**; no private frames
were recorded. The canonical read-only schema-3 collector started **before**
Mirri Start and exited early with **`incomplete calibration: ...: host capture
stalled`**. It accepted seven contiguous per-second host records (7.484 actual
host-active seconds, 54 complete/encoded/written frames) and seven client
records (7.121 client-active seconds, 54 received/queued, 53 released), all
without a final record. Host complete counts by record were **50, 2, 0, 2, 0,
0, 0**: records 4–6 met the collector's deliberate three-zero fail-fast gate.
The continuous-motion owned window was launched only after that gate had
already failed; subsequent host metrics showed >50 complete frames/s but
cannot repair or be appended to the incomplete captured window. **No 90-second
rates, summed histograms, valid renderer coverage, latency-tail, queue/memory
trend or performance acceptance can be inferred.** The earlier **54.341 fps**
1801.58-second baseline above remains unchanged and below the ≥59 target.

The owned synthetic process ended before Mirri's normal menu Stop; the host
returned to idle, both Mirri reverse ports were absent and the owned virtual
display count was zero. The process-scoped sleep assertion and filtered logcat
collector were gone. Numeric-only partial records and the collector's failure
code remain under `/tmp/mirri-timing-approved-90/` and
`/tmp/mirri-schema3-collector-status.log`; neither contains frame pixels or
touch paths. **Do not repeat automatically.** A separately approved next
attempt should start the *same owned motion stimulus* immediately when the
exact Mirri virtual display becomes available, before the first streaming
interval, and then require both host/client actual active windows ≥90 seconds
before a normal Stop. The collector must still start first and fail on any
schema, heartbeat, mode, error, state, or capture/receive-stall condition.

### Second separately approved 90 s attempt — prearmed watcher did not attach

The **unchanged reviewed host/APK binaries and native HiDPI/AVC40/cap3/SCK2/
`.zero` configuration** were retained; no rebuild or reinstall. A compiled
version of the same owned-only 60 Hz continuous-motion window had an in-process
20 ms watcher. Its idle preflight emitted `watcher_ready` with no window or
orphan. The one-shot controller prearmed this watcher, a fresh canonical
collector, filtered Mirri mode/decoder diagnostic and bounded process-scoped
sleep assertion **before** Mirri's own Start. Every child had an external
watchdog and owned cleanup. Numeric UTC nanosecond ordering from
`/tmp/mirri-cal2-ordering.ndjson` and the stimulus log:

| Event | UTC ns |
| --- | ---: |
| Watcher ready, no window | 1790439568842942976 |
| All watcher/collector/diagnostic/assertion processes prearmed | 1790439568967647000 |
| Own-menu Start invoked / returned | 1790439568968071000 / 1790439571417339000 |
| Host streaming state observed by controller | 1790439576701871000 |
| No `stimulus_attached` within bounded 0.25 s streaming check; abort | 1790439577036327000 |
| Normal own-menu Stop invoked / returned | 1790439577036843000 / 1790439579145586000 |

The host again verified **1228×800 logical / 2456×1600 pixels @60 Hz** and
briefly entered streaming. Fresh filtered tablet records confirmed pre-hello
and post-config **requested/observed mode ID1 1600×2456@60000**, Surface
**2456×1600**, and decoder output **coded 2464×1600, crop
0,0–2455,1599, BT.709 limited, visibleExact=true/colorExact=true**. The
watcher logged *only* `watcher_ready`, not an exact-screen candidate or
attachment; the cause (NSScreen propagation versus watcher predicate) is
**unproven**. Controller refused to keep a static stream running and stopped
Mirri normally. Canonical numeric files in
`/tmp/mirri-timing-approved-90-corrected/` contain only **two** incomplete
records per device: host intervals 1.076/1.075 s with complete 50/2 and
written 49/2; tablet intervals 1.009/1.020 s with received 49/2 and output
48/2. No final records, 90-second rates, histograms or renderer coverage.
One early memory snapshot (host RSS **65376 KiB**, client PSS **62454 KiB**)
cannot show bounded growth. The original **54.341 fps** long-run baseline
above remains separate and unchanged.

After Stop: host idle, Mirri reverse ports **0**, owned display **0**,
watcher/collector/diagnostic/sleep processes **0**. No window was ever placed
on another display, and no screen pixels or input paths were stored. The
preflight controller first hit a `/tmp`-only Path type error **before any
Mirri Start or children**; it was corrected and statically checked before
this single approved device attempt. **No further run is authorized.** The
next candidate is a separately approved *display-only*, bounded watcher
diagnostic that logs only numeric candidate count, CGDisplay pixel/logical
readback and exact attachment latency on a Mirri-owned virtual display,
without a video/USB calibration; only after reliable pre-stream attachment
should a new 90-second schema-3 attempt be proposed. No codec/transport/
tablet performance bottleneck can be inferred from this aborted window.

### Separately approved display-only watcher diagnostic — exact predicate identified

One bounded, prearmed watcher and a small probe using the **already built,
unchanged production `MirriHostCore.framework`** created only its uniquely
owned virtual display; Mirri remained idle, with **no Start, USB stream,
ScreenCaptureKit capture, video frames or input**. The watcher placed the same
continuous-motion checkerboard window only on the owned `NSScreen`, after
the exact 1228×800 logical / 2456×1600 backing @60 Hz mode and 1228×800
bounds appeared. Its 20 ms snapshots showed initial
`CGDisplayMode.pixelWidth/Height=1228×800`, then **2456×1600** and
`NSScreen.backingScaleFactor=2.000`; throughout, **`CGDisplayPixelsWide/High`
returned 1228×800**. Thus the old watcher's additional 2456×1600
`CGDisplayPixelsWide/High` gate remained false **even when the production
mode and Cocoa screen were exact**. The old gate, not missing `NSScreen`
propagation, explains this isolated display-only nonattachment condition;
it does not retroactively prove every state of the preceding USB attempt.

Numeric ordering from `/tmp/mirri-displaydiag-ordering.ndjson`, watcher and
owner logs: watcher ready at UTC ns **1790440407959483136**, production
display creation began **1790440408395927040**, exact screen candidate
and window attached **1790440409163104000 / 1790440409199603968**;
production owner verification completed **1790440409448480256**. The
animation yielded one **59.896 timer ticks/s** sample over approximately
10 s, then was ordered out on a controlled stop before display destruction.
These are **window timer ticks, not captured/sent/displayed video fps**.
After its detach acknowledgment, the probe called production `destroy()`:
`CGGetOnlineDisplayList` still showed owned count **1** at destroy return and
after its bounded 2-second wait, so the probe exited nonzero **4** and the
one-shot controller reported an **incomplete diagnostic**. A subsequent
read-only check **after probe process exit** found owned count **0** (online
total 1); no watcher/owner group remained and Mirri's last host state was
idle. Teardown convergence while the owner remains alive is **unproven**,
and this cleanup delay must not be hidden or treated as a passing teardown
assertion. No display or device diagnostic was retried.

This test establishes a corrected **candidate predicate** for a separately
approved future pre-stream calibration watcher: compare
`CGDisplayMode.width/height/pixelWidth/pixelHeight/refreshRate`, bounds and
owned screen identity, not `CGDisplayPixelsWide/High` to backing pixels.
It does **not** prove attachment before Mirri's first captured frame or
validate any 90-second performance, renderer coverage or stability gate;
the separate 54.341-fps long-run baseline remains unchanged.

### One approved corrected-watcher 90-second attempt — controller aborted during normal startup

The **unchanged reviewed production host/APK**, native 2456×1600 HiDPI
configuration and same moving checkerboard were retained. A compiled
temporary watcher removed the earlier display-only stop/ACK sentinel and
would have continued animation through own-menu Stop; it compared the exact
owned `CGDisplayMode` logical/pixel mode instead of the incorrect
`CGDisplayPixelsWide/High` backing-size test. A fresh canonical schema-3
collector, independently parsed live host/client timing observer (to avoid
assuming the collector's file buffers flush each second), narrow mode logcat
and scoped sleep assertion were prearmed before the one authorized Start.

The attempt **did not reach display creation or streaming**. The one-shot
controller incorrectly classified the ordinary pre-stream
`state waitingForClient` transition as a failure at UTC ns
**1790440910490556000**, about 0.23 s after own-menu Start returned. It
called Mirri's normal own-menu Stop; the host went through `stopping` to
`idle`. The watcher logged only `watcher_ready`, never an owned
candidate/attachment. The collector's host/client timing files each have
**zero records** and no final flush; the controller allowed a bounded
post-Stop wait before cleaning it (interrupted exit -2). Read-only cleanup
found **owned display 0**, Mirri reverse5560/5561 **0**, all owned helpers
gone, and one idle host process. The error is in the temporary controller's
premature startup guard, **not evidence of a host/client video bottleneck**.
No retry, 90-second result, full-window rates, stage tails, renderer
coverage, memory/queue trend, overhead comparison or performance acceptance
exists. The prior standalone display-probe `destroy()` convergence caveat
remains separate from this successful real-app normal Stop. This approval
was consumed; **STOP** pending a new decision, with no 300-/1800-second run.
Read-only follow-up found **no host error** in the attempt's five host
state lines. Narrow tablet lifecycle logs showed repeated
`CONFIGURING_DISPLAY → CONNECTING_CONTROL → RECONNECTING` after host
Stop and an eventual `FAILED` (retry-window expiry); the source retains
the tablet's launch until its bounded reconnect loop ends. This is
consistent with the controller-initiated teardown of the waiting handshake,
not independent evidence of a USB device/cable fault. The temporary
controller's pre-stream guard was corrected **offline only** to accept
`waitingForClient`; synthetic real-state-sequence and terminal/timeout
tests passed, but **no corrected device attempt has been run**.

### Separately approved corrected-watcher calibration — complete 90-second schema-3 window

After an executable-permission error on a *fresh temporary watcher copy*
failed **before any Start**, a new fresh-path, hash-identical executable
passed bounded idle readiness; no window or device session was started by
that preparation failure. The subsequent **single authorized Start**
completed normal handshake, exact owned **1228×800 logical /
2456×1600 pixels @60 Hz** and tablet **1600×2456@60 / Surface2456×1600**
with exact decoder crop and color. The same continuously moving checkerboard
attached **0.453 s before host capture timing activation** and remained
alive through own-menu Stop. Independent validated live host/client windows
reached **90.780 / 90.046 active seconds** before this **expected**, not
failure-triggered, Stop. Canonical final flush produced contiguous
**92 intervals each**, host **92.934530292 s**, client **93.039105 s**,
`completeWindow=true`, collector exit **0**; offline aggregation matched.

Summed full-window rates in fps: host complete **53.037**, encoded/written
**51.746/51.746**; client received **51.699**, output/released
**51.613/51.613**, render callbacks **44.315**. Thus sustained ≥59 fps
fails even at host capture, and the separate earlier **54.341 fps**
1801.58-second baseline is **not a controlled instrumentation-overhead
comparison**. Host VT-callback p95 bound **56 ms** and callback-to-write
p95 **60 ms**; complete-callback gap >25 ms **655/4928**, longest
consecutive burst **4**. Client output-gap p99 bound **125 ms**; metadata
outstanding grew **15 → 256**, high-water **256** (capacity), with
**186 overflows**, **245 expirations**, **431 missing-render** events.
Render notification coverage was **4123/(4802−23)=86.27%** with **225
older interior pending** and **23 right-censored**: the collector marks
`rendererStatus=incomplete` (<98%), not a full-coverage renderer
latency/presentation result. Four memory samples rose from host RSS
**53504 → 75776 KiB** and client PSS **67418 → 77508 KiB**, insufficient
to establish long-run leak or stable bound. These data prioritize
investigation of sub-59 host complete/VT callback cadence and client render
callback/metadata saturation; neither proves a unique root cause or
physical panel presentation. No tuning or additional run was performed.
Host returned idle after normal Stop, owned display and Mirri reverse
5560/5561 count **0**, all owned helpers gone. Detailed complete-window
histogram/tail/gap and numeric artifacts are preserved in
`/tmp/mirri-timing-approved-90-cal5/` and `/tmp/mirri-cal5-*.log`;
no screenshots, private pixels, touch paths, serials or tokens were saved.

### Matched complete windows: timer, display link, and metadata ownership

Three separately approved, normally stopped ~90-second full-native HiDPI AVC40
owned-checkerboard windows used the same host binary, SCK `.zero`/queue 2,
three credits, exact 2456×1600 pixels and 1600×2456 tablet mode. Timer→
`NSScreen.displayLink` changed only stimulus scheduling; the final run kept
the display link and installed a reviewed same-signature Android timing-owner
metadata fix, without changing the host. All three had contiguous schema-3
final records, independent host/client active windows ≥90 s, exact decoder
visible crop/color, normal Stop and owned display/reverse count zero.

| Stimulus / Android owner | Host complete / written fps | Client output fps | SCK idle / >25-ms PTS gaps | Render coverage |
| --- | ---: | ---: | ---: | ---: |
| Timer / original | 53.037 / 51.746 | 51.613 | 626 / 646 | 86.27% |
| Display link / original | 58.837 / 57.367 | 57.308 | 104 / 105 | 84.89% |
| Display link / split owner | 58.544 / 56.786 | 56.723 | 131 / 135 | 83.46% |

These are measured full-window rates, **not** a ≥59-fps product or renderer
acceptance claim. Both display-link windows reduce SCK idle/PTS gaps versus
the timer, supporting stimulus/compositor scheduling as a possible cause;
60-ish stimulus ticks do not establish presented or captured updates. The
split owner preserved decoder-stage accounting (5300 received, 5299 queued,
5297 output/released; no unmatched/late/missing-output-sequence), combined
capacity/high-water ≤256, and diagnostics: 632 overflows + 13 expirations
= 645 missing-render, and 645 missing + 227 older pending + 26 censored
= 5297 released − 4399 rendered. It did **not** restore missing framework
callbacks; valid-render coverage remains below the unchanged 98% gate.
The split-owner packet→release p95 bound rose from 96 to 125 ms in this
separate run; do not infer a latency improvement or a proven code regression
from one pair. Complete numeric evidence:
`/tmp/mirri-timing-approved-90-{cal5,dlink,asplit}/` and matching
`/tmp/mirri-{cal5,dlink90,asplit90}-*.log`; source-only aggregation summaries
are `/tmp/mirri-{cal5,dlink90,asplit90}-offline-summary.json`.
