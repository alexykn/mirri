# Native timing probe: source reviewed; one corrected 90-second window complete

This is **observation-only instrumentation**, not a performance optimization or
general permission for more testing. The first two approved calibrations were
incomplete (static-stimulus capture stall, then incorrect owned-watcher pixel
gate). A third Start was stopped prematurely by a temporary controller
misclassifying normal `waitingForClient`. A subsequent separately approved
corrected-watcher run produced **one complete ~93-second local timing window**
per device: host complete/USB-write **53.037/51.746 fps**, tablet
receive/output **51.699/51.613 fps**, renderer valid-callback coverage
**86.27%**, below the required **98%**. Full histogram/gap and cleanup
details are in [`native-validation.md`](native-validation.md). This result
fails ≥59 fps and renderer coverage; it is not a 30-minute soak or a
controlled overhead comparison. Any further device run needs separate
approval. The unchanged native path is 2456×1600 AVC High
5.1 / configured 40 Mbit/s, 3 capture-to-socket credits, SCK queue depth 2,
`minimumFrameInterval = .zero`, Mac HiDPI 1228×800 logical / 2456×1600
backing @60 Hz and tablet 1600×2456 physical / 2456×1600 Surface @60 Hz.
The completed 1801.58-second baseline sent **54.341 fps**, below 59; see
[`native-validation.md`](native-validation.md). The probe does not optimize
or change admission, codec or capture configuration. No screen contents, touch paths, device identifiers,
tokens or private pixel samples belong in its logs.

## Clock domains, joins and limitations

- Host `SCStream` complete sample presentation timestamps (`CMSampleBuffer`
  PTS/`CMTime`) have an **unverified clock domain and epoch**, not an assumed
  zero-based relative timestamp. Consecutive PTS deltas *within that stream*
  yield cadence only. VT output/wire PTS is derived from the encoder's
  presentation timestamp converted to unsigned ns (negative values are
  clamped by the existing encoder); it is media identity, not host uptime.
  `DispatchTime.now().uptimeNanoseconds` stamps host complete
  callback entry, VT submit, VT callback, conversion and framed NWConnection
  `.contentProcessed` return. Subtract only host monotonic stamps; wire-write
  completion **is not remote arrival**. Host PTS→callback age is explicitly
  `unavailable-unverified-clock`. Apple's
  [`SCStream.synchronizationClock`](https://developer.apple.com/documentation/screencapturekit/scstream/synchronizationclock)
  describes the capture stream clock, while
  [`CMClockGetHostTimeClock`](https://developer.apple.com/documentation/coremedia/cmclockgethosttimeclock%28%29)
  uses `mach_absolute_time`; no identity with `DispatchTime` is established
  here. Wire frame PTS is ns; the client truncates to codec PTS µs.
- Tablet `System.nanoTime()` stamps fully received AU, input index
  availability/acquisition, post-queue, output availability, release request,
  release-call return and frame-render callback arrival. Android
  [`MediaCodec.OnFrameRenderedListener`](https://developer.android.com/reference/android/media/MediaCodec.OnFrameRenderedListener)
  supplies a render `nanoTime` in the same **tablet** monotonic domain, but
  notification can be late, batched or absent; it is a framework render
  notification, **not physical panel scanout**. The listener is registered
  after configure and before start, per
  [`setOnFrameRenderedListener`](https://developer.android.com/reference/android/media/MediaCodec#setOnFrameRenderedListener(android.media.MediaCodec.OnFrameRenderedListener,%20android.os.Handler)).
  Report **both** observed `renderedTotal/releasedTotal` and *valid-timed*
  `validRenderedTotal/(releasedTotal−rightCensored)`, missing/expired callbacks,
  unknown older interior pending frames, and
  callback-delay histogram. Negative clock deltas invalidate timing despite
  observed callback. No cross-device timestamp subtraction, panel-scanout or
  end-to-end latency claim.
- Host one epoch/generation owner associates encoded callback and written
  unit using its captured immutable stamp; detects output sequence mismatch
  and PTS-us truncation. Android one attempt/generation owner associates wire
  sequence and `wirePtsNs / 1000` with codec output and render callback PTS.
  After a **same-MediaCodec flush** the framework supplies only PTS, not a
  generation token for output/render callbacks. No bounded old-PTS quarantine
  is sufficient. Therefore frame joins for that attempt are explicitly
  **unavailable from its second codec generation onwards**, including
  legitimate new frames; packet/media cadence remains separately reported.
  A fresh host reconnect creates a new Android attempt **and new decoder**,
  so its first generation is eligible. Codec callbacks are checked against
  their captured codec instance and active attempt; a shared-codec flush
  remains unjoinable. Duplicate µs PTS within an eligible generation count
  as ambiguity. Reordered output/render callbacks enter separate 64-entry
  sequence buffers; unknown predecessors expire after 1 s or 64 pending, and
  *all* pending records are consumed at generation/stop before closing runs.
  A gap over known missing predecessors increments distinct
  `ambiguousOutputGap`/`ambiguousRenderGap` and is **not measured as physical
  stutter**; no synthetic frame is emitted. Active frame metadata expires at
  30 s (or capacity 256); expired released frames count missing render and
  late callback cannot create apparent coverage. Capture PTS is never
  subtracted from tablet nanoTime.

## Histogram interpretation

Schemas **v=3/v=4** share **59 fixed bins**: upper bounds **2,4,…,100 ms (2 ms
steps)**, then **125,150,200,250,500,1000,5000,10000 ms**, then unbounded
**>10 s overflow**. Positive long stalls are retained with exact observed
max; an overflow percentile has **no finite bound** (`-1` in interval line,
`null` in offline aggregate). Only negative/nonfinite clock deltas count
`invalidClock`, and extraordinarily large media durations saturate UInt64 max
into explicit overflow. A measured **zero** duration belongs to the first
0–2 ms bin and may be its maximum; subsequent bins exclude their strictly
positive lower boundary. The production Swift/Kotlin emitter fixtures
exercise zero VT-call and packet-to-input durations respectively, including
rejection of impossible later-bin maxima. Every numeric `videoTiming` and
`MirriTiming` line
prints its explicit `v=3` or `v=4` and owner identity, monotonic `record`, same-device
`startNs`/`endNs` for that record's active interval, `final`, matching numeric
host/client epoch (not a session token), generation,
and each stage as
`count:p50BoundMs:p95BoundMs:p99BoundMs:exactMaxMs:59.dot.separated.bins`
plus `:na` for non-gap stages or
`:over25.over50.over100.closedRunLengthBuckets1,2,3to5,6to15,16plus.longestClosed.openLength`
for gap stages. Threshold is strictly `>`, not `>=`, milliseconds; open runs
survive one-second drains and generation/stop **closes** trailing runs. A
snapshot gives bucket upper-bound quantiles, never exact percentile latency.
For the full observation window, **sum bin counts first**, then recompute
p50/p95/p99 rank as `ceil(fraction × total count)` in cumulative ascending
bins; use maximum of exact per-interval maxima, sum closed-run buckets, and
include final stop line to close any remaining open run. Do **not** sum
per-line open-run lengths or longest closed run, take a median of interval
medians, or count an open run twice. Host activation follows successful SCK
start; client activation follows StartStream. Periodic and final intervals
are contiguous. Measurement freezes **before** normal socket/codec teardown:
pre-stream setup, omitted first intervals and stop idle time cannot inflate
the fps denominator. The full-window duration is the sum of each platform's
own `endNs−startNs`, never a cross-device subtraction. Production Swift/Kotlin
emitters generate synthetic **5400 frames / 90 s = 60 fps** and partial
first/last windows **45 + 89×60 + 15 = 5400 / 90 s**. Android final logcat
messages start directly with `v=4 ... final=1`, not a free-text `final` token.

Production **v=4** adds keyframe-classified AU counts, bytes and largest AU
(nonkey bytes/max are separate), host `keyVtCallback`, and Android
`keyPacketGap`, `keyInputOutput` and ordered `keyOutputGap` histograms.
The client uses validated wire flag bit0, carried only in its existing
generation/codec-PTS Frame metadata. Packet/output gaps belong to the
**following** AU (key or nonkey); a missing predecessor never fabricates a
gap. Key histogram bins are subsets of existing total bins, not another
per-frame logger. The offline analyzer subtracts **summed** key bins from
total bins to obtain nonkey full-window quantiles, not quantiles by
subtracting percentiles; nonkey exact maximum is unavailable from subtraction.
The live collector requires v4, while the offline parser explicitly decodes
prior v3 complete-window files for comparison. No wire protocol version or
codec, GOP, admission, resolution or render callback policy changes.
To check whether the one-second reporting itself coincides with stalls,
each side also logs one compact `videoTimingReport`/`MirriTimingReport`
line per ten reports: maxima in microseconds for owner lock/copy, formatting,
and the synchronous timing-log call. These separate lines are not frame
records or parser inputs; they do not include time spent in other metrics,
the cadence scheduler, or the auxiliary ten-report log call itself.

One approved AVC40/HiDPI display-link v4 observation (90 s minimum; actual
client active 93.28 s) found 89 key AUs among 5,332 received. All 53 ordered
output gaps strictly >100 ms belonged to *following nonkey* AUs; zero to the
88 key outputs with measurable predecessor gaps. Key AU mean size was 1.294 MB
versus 63.85 kB nonkey, and key packet gaps were often longer, so a later
nonkey stall caused by a preceding key burst remains possible. Maximum
ten-report host lock/format/log costs were 0.242/7.166/11.453 ms; client
6.407/22.473/1.824 ms. These exclude other work and do not establish a
causal explanation for stalls. Render coverage was only 83.46% (incomplete);
decode output counts remain independently interpretable. Keep GOP60 and
codec policy unchanged pending a targeted follow-key attribution check.

One approved, immediately reversed AVC40 GOP120 diagnostic yielded 45 key AUs
of 5,398 received versus GOP60's 89/5,332. Ordered output gaps >100 ms were
42/93.11 s versus 53/93.28 s, all following nonkey AUs in both runs. GOP120's
largest gap **worsened** to 178 ms from 119 ms, and input→output samples
>100 ms increased to 184 from 106; its mean key AU grew to 1.467 MB from
1.294 MB. Early/middle/late 30-second gap counts were 13/13/15 versus
12/18/21, so the frequency reduction was not uniform. Render coverage was
incomplete in both runs. GOP60 source, installed host and preferences were
verified restored. This is not quality/recovery equivalence or a product fix;
the owner also observed Dock return after Stop, without a verified display
layout mechanism. Do not make a permanent GOP change on this evidence.

### AVC40 operating-rate60: provisional retention

One separately approved 90-second display-link/GOP60 AVC40 trial changed only
the Android decoder's `MediaFormat.KEY_OPERATING_RATE` to 60. Independent host
and client active windows exceeded 90 seconds; normal Stop and final logs were
verified. The parent **retains this candidate provisionally**, without claiming
causal effect, 60-fps/product acceptance or permission for another run. The
wrapper's terminal `candidate_awaiting_evaluation` records successful trial
retention, **not the later parent decision**: see
[the durable decision and guarded recovery path](rate60-provisional-decision.md).
Host complete/write fps were **58.881/57.322 → 58.251/56.855**; client
output fps **57.149 → 56.684**. Ordered output gaps >100 ms fell **53/93.282 s
(0.568/s) → 35/93.431 s (0.375/s)**, and input→output >100 ms **106 → 57**;
output-gap maximum **119.035 → 114.143 ms**. Lower output rate followed
lower upstream complete/write rate, so a decoder throughput regression is
**not established**. Both runs had invalid render coverage (**83.46% →
85.18%**, below 98%); no rendered-latency conclusion follows. One sequential
pair cannot distinguish operating-rate effect from run variance.

Upstream accounting from complete-window schema-4 logs: reference/current
host active **93.0185/93.1490 s**, complete **5477/5426**, written
**5332/5296**. At nominal 60 Hz, complete deficit is approximately
**104.1/162.9 frame-equivalents** (not counted dropped frames); capture PTS
gaps >25 ms rise **106 → 163**, with maxima **33.334/33.336 ms** and no
>50-ms capture PTS gaps. Complete→written retention **97.35% → 97.60%**;
same-window count differences **145 → 130** include admission/in-flight and
report-boundary effects, not measured individual drops. On the current run,
91 approximately overlapping one-second operational host reports (SC complete
5420 versus timing-owner 5426) recorded **162 SCK idle statuses, 163 >25-ms
PTS gaps, 128 credit skips**, zero format/submit skips. The idle/PTS counts
matched in 90/91 reports. These show association, not that idle caused every
missing complete or that rate60 caused the upstream change; comparable
reference per-status operational reports were not preserved. Both runs hit
`creditHigh=3` in 90 intervals, encoded queue high-water ≤1, VT callback
p50/p95 **42/56 ms** and callback→write p95 **58 ms**; an admission effect
remains plausible but *worsened* credit loss is unsupported. Production
`CapturePipeline.swift` reserves three credits **after** complete/format
checks and releases after socket write; idle is rejected **before** reserve.
`VideoEncoder.swift` stamps submit→VT callback, with configured 60-fps GOP60
hardware VT, so no decoder knob can directly increase emitted SCK completes.

Source-only host diagnostic (not installed or physically validated): the
existing operational metrics owner also emits one numeric
`metrics pendingVTCallbacks idle=a,b,c complete=d,e,f completeGap25=g,h,i creditFull=j,k,l`
row per interval. Each triplet buckets the pending encode-to-output-callback
count at the SCK event (0 / 1 / ≥2). `complete` is the reference population of
**all** complete callbacks, even if format/admission later rejects the frame;
`completeGap25` is its subset, sampled with the **same count once per complete
callback**, for valid >25-ms and <1000-ms PTS gaps. Such a gap belongs to the
**following complete** callback, not the missed frame. Compare idle/complete
mix **within each pending bucket**; a concentration of idle at ≥2 is not
informative if almost all normal completes also occur at ≥2. These are event
counts, not time spent at each depth, and do not measure causality.
The count is registered **before** VTEncodeFrame (the callback may precede its
return); an inline or async callback consumes its matching opaque token once;
failed submission or synchronous dropped-frame flag cancels it once; invalidate
completes outstanding frames then clears any remaining tokens. Tokens never
reuse IDs within the encoder, so late callbacks after cancel/invalidate cannot
join later frames. Installed macOS SDK `VTCompressionSession.h` specifies that
`infoFlagsOut` **may** set `kVTEncodeInfo_FrameDropped` if dropped synchronously;
its output callback also reports dropped frames with a null sample. It does
**not** promise a callback cannot follow a synchronous dropped flag. Therefore
the canceled opaque token safely ignores such a later callback. The synchronous
drop now triggers the existing encoder-failure transition and returns false,
releasing the capture credit rather than silently stranding it: this is a
**lifecycle behavior change**, not just observability, pending parent review.
Callbacks do not acquire the encoder's submission lock. These counters are pending VT
**callbacks**, NOT independently verified SCK/VT retained input surfaces.
Per-event metric sampling and interval snapshot may straddle a reporting
boundary; association does not prove causation or establish panel presentation.
The separate row is not schema-v4 `videoTiming` input and does not change
capture policy, GOP, codec, packet format, Android decoder or bounded queues.
The production pipeline creates a **new encoder per capture pipeline** and
calls prepare once, then stop/invalidate for that incarnation; reconnect
creates a new pipeline/encoder. Hence no later prepare on the same encoder can
race with its invalidate/clear in this owner path. The installed SDK says
CompleteFrames emits outstanding frames before returning, and Invalidate is
orderly teardown; the tracker clears stragglers afterward. The existing
three-credit gate bounds stamps to at most three in the production path even
if VT omits a callback without the synchronous-drop flag (then the count can
remain stale until stop/invalidate). Source-only tests
simulate callback-before-return, error/drop, late/canceled callback, teardown,
and concurrent one-time consumption; a small local timed loop does not prove
physical callback overhead. The parent must review code/tests and callback
overhead before any deployment;
no new hardware observation or improvement claim follows from source-only tests.

**Smallest next step:** preserve this configuration and audit existing host
operational/timing interval alignment and any recoverable GOP60 reference
per-status logs, prioritizing the display-link/compositor→SCK idle/complete
cadence before changing credits or encoder settings. The present current-run
alignment is already strong; missing reference status is the limiting evidence.
Any later *authorized* confirmation of the decoder-tail signal must use
repeated controlled same-GOP60/host/stimulus/mode 90+s windows with the
Android hint alternated against exact baseline, compare independent output
gap rates/max and input→output tails alongside upstream complete/admission/
write, and treat render results as invalid unless coverage reaches ≥98%.
This describes discrimination, **not** a prepared run matrix or permission to
stream. Source-only aggregates: `/tmp/mirri-rate60-{reference-gop60,dlink90}-analysis.json`;
canonical timing: `/tmp/mirri-{keyv4,rate60}-timing-90-dlink/`.

One later authorized **flush-helper** directional attempt is **not** another
complete window or rate60 acceptance. During host-log rotation the collector
replayed historical record 84 after current record 83 and exited before own
90-second completion; the owner then stopped its own stream and restored
preferences without changing the retained rate60 APK/source. Independently
recovered current host records cover only **89.12 s**, while the client has no
final record. A matched 84-record partial prefix showed slightly more host
completes but worse credit retention and ordered >100-ms decoder-output gaps
(34 → 73). The parent **dropped the experimental flush helper from future
tests**; keep the original helper and rate60 provisionally retained. These
partial numbers are not a rendered-latency or causal result. Raw failed-run
artifacts remain in `/tmp/mirri-flush90-*`; the offline collector rotation
regression is in `tools/test_aggregate_timing.py`.

Host stages: media PTS gap, complete callback-to-callback gap, synchronous VT
submission call, async VT callback, conversion, complete callback→wire write,
VT output→write, conversion→write, write-to-write gap and written PTS gap;
credit and encoded queue high-water per interval. Tablet: packet→input queue,
input queue→output available, output→release request, release call duration,
release request→reported render, packet→reported render, render callback
delay, input index wait, packet gap, media PTS gap, output gap, reported
render gap and packet→release request. `bufferIndexWait` means framework
input-buffer available→acquired idle time, **not** packet→decoder queue wait.
Android bounds 256 active frame metadata with 30 s expiry, 64 recent rendered
PTS and two 64-entry reorder buffers plus 32 input-index stamps. The older
`DecoderFrameAges` and host `MetricsCollector` ages remain *temporary*
baseline-compatible cross-checks; delete duplicate owners only after a
physically calibrated schema-3 run establishes valid coverage/comparable
counts and parent approval. Both log only per-second/final numeric data, no
per-frame log, coroutine or pixels. Kotlin copies bounded arrays/maps while
synchronized and formats after release; Swift drains bounded histograms under
the capture lock and formats strings afterward. Physical overhead remains
**unmeasured**; a changed loss profile or callback coverage is a limitation,
not a performance improvement. Android's final measurement before decoder
teardown right-censors releases still pending from the past **2 s** without
calling them drops; older outstanding releases remain unknown interior
coverage. Regular Stop introduces no artificial delay or codec-policy change.
Missing optional render notifications yield `renderStatus=unavailable` while
independent packet/input/output/release rates remain interpretable;
partial/ambiguous render coverage is `incomplete`, not a valid render claim.
Android log line size must remain below
3,900 bytes; schema changes require version bump and parser test.

## Source-verified commands and separately approved future calibration

Parent source review passed before the single, incomplete first attempt.
Do **not** repeat the deployment or 90-second run without a new parent decision.
For any authorized follow-up, retain app data, owner-granted permissions and
the authorized single USB device. Do not change
unrelated packages/reverse mappings, global display policy or persistent power
settings. Source verification command reference (do not rerun automatically):

```sh
(cd macos-host && swift format lint -r --strict Core Tests App && swift test && \
  xcodebuild -project MirriHost.xcodeproj -scheme MirriHost -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test)
(cd android-client && export JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home \
  ANDROID_HOME=/opt/homebrew/share/android-commandlinetools && \
  ./gradlew testDebugUnitTest assembleDebug ktlintCheck)
uv run --offline python tools/compare_protocol_fixtures.py
uv tool run --offline --from ruff==0.15.14 ruff check tools
uv tool run --offline --from ty==0.0.39 ty check tools
uv tool run --offline --from radon==6.0.1 radon cc -s -a tools
```

Python integration tests require **production-emitted numeric fixtures**
from the focused Swift/Kotlin tests, not separately handwritten happy-path
records. Exact software-only chain (no app launch or device access):

```sh
mkdir -p /tmp/mirri-timing-source-fixtures
(cd macos-host && MIRRI_TIMING_EMITTER_DIR=/tmp/mirri-timing-source-fixtures \
  swift test --filter HostRuntimeTests.testProductionHostTimingEmitter)
(cd android-client && export JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home \
  ANDROID_HOME=/opt/homebrew/share/android-commandlinetools \
  MIRRI_TIMING_EMITTER_DIR=/tmp/mirri-timing-source-fixtures && \
  ./gradlew testDebugUnitTest --tests dev.mirri.client.VideoTimingOwnerTest.productionPayloadEmitterFullAndPartialWindows)
MIRRI_TIMING_EMITTER_DIR=/tmp/mirri-timing-source-fixtures \
  python3 -m unittest discover -s tools -p 'test_aggregate_timing.py' -v
```

After explicit **separate** benchmark approval and a confirmed exact host and
tablet mode, run a fresh 90-second numeric-only calibration with an
owner-approved synthetic window on the *Mirri-owned display alone*. Capture
filtered host `videoTiming` and Android `MirriTiming` one-second/final lines,
process only counts/histograms, check actual active duration, codec/crop,
listener coverage, zero drops/reconnect, bounded queue/memory and basic
agreement of release/render/sent counts. Compare to *same-stimulus*
uninstrumented baseline rather than reusing a different-content trial.

The **canonical, reviewed-before-use** `tools/collect_timing.py` is
read-only: it observes rotated host logs and starts only a process-owned
filtered USB-specific `adb -d logcat -T 1 -v epoch -s MirriTiming:I '*:S'`
(multiple USB devices cause ADB refusal); it does not Start,
Stop, install, select USB serial, clear logcat, create a display, run an
animation or touch reverse mappings. Fixed reviewed source constants, not
unvalidated runtime JSON, allow only 90/300/1800 active seconds, 7,200
records, ≤3,900 bytes/line, ≤2.5 s reporting gaps and ≥98% valid-timed
callback coverage for a status of `valid`. It rejects
unknown fields *before persisting*, enforces both final flushes, record
continuity, owner/generation identity, histogram bin sums/maxima/schema and
matching host/client numeric epoch. It exits promptly on host error/state,
capture/receive stall, missing heartbeat or log truncation/rotation loss.
Start it **before** the separately approved Mirri Start, otherwise missing
`record=0` fails. A bounded startup buffer tolerates one old `-T 1` tag line
and then pairs current host/client epoch and client owner from `record=0`;
missing current record zero still fails. Output
directory must not exist. The first run used `/tmp/mirri-timing-approved-90`
and failed with `host capture stalled` before the moving window started.
The separately approved second attempt used
`/tmp/mirri-timing-approved-90-corrected`, but its exact-display watcher
never attached before streaming. Its fail-closed controller normally stopped
Mirri after two partial numeric records. Later separately approved
controller-fix and corrected-watcher attempts include one **complete**
90-second window in `/tmp/mirri-timing-approved-90-cal5/`; see
[`native-validation.md`](native-validation.md) for exact ordering and
rates. That full window fails throughput and renderer-coverage gates.
The following uses a **new** directory and is only an example for a
*separately approved* retry, not an authorization:

```sh
python3 -u tools/collect_timing.py --active-seconds 90 \
  --output-dir /tmp/mirri-timing-approved-90-next
# In a separate owner-approved controller: verify exact modes and codec,
# Start Mirri using its own UI, animate only its owned synthetic window,
# stop that window, Stop Mirri via its own UI, verify owned resource cleanup.
# Collector exits after both final records or prompt failure;
# stderr/serial are never echoed; output says acceptance=not-assessed.
python3 tools/aggregate_timing.py --active-seconds 90 \
  --host /tmp/mirri-timing-approved-90-next/host-timing.log \
  --client /tmp/mirri-timing-approved-90-next/client-timing.log
```

If overhead is tolerable and timing data credible, separately approve a
**five-minute** calibration using the same source command with
`--active-seconds 300 --output-dir /tmp/mirri-timing-approved-300`, **not**
a full soak. Analyze full-window summed histograms and longest >25 ms burst
at each stage, distinguish missing callback coverage from known consecutive
stalls, and explicitly label each clock domain's bounds. Only after a
reviewed quality-preserving behavior change passes ≥59 fps for a controlled
whole window at host capture/encode/write and independent tablet
receive/decode, no drop/reconnect, bounded stage tails and queue/memory
growth, request approval for a new uninterrupted 1800 **actual active**-
second soak (`--active-seconds 1800 --output-dir /tmp/mirri-timing-approved-1800`).
The old 54.341 fps
baseline **fails** throughput; probes, short runs, the interrupted prior soak
and the completed old-behavior soak cannot establish new-source acceptance.
