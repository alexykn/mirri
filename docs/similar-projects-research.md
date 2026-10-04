# Android realtime decoder priority: research and trial result

**Result: tested and rejected; rate-60 baseline restored.** A completed
post-update baseline/candidate comparison found no material benefit from
priority 0. The candidate configured and streamed, but was not retained.

## Ranked ideas for this exact target

1. **Tested and rejected: standard `MediaFormat.KEY_PRIORITY=0`, with
   `KEY_OPERATING_RATE=60` unchanged.** This was a bounded test of the realtime
   resource-priority hint at the actual planned rate, not Moonlight's very high
   operating-rate request. The only qualified target is the hardware AVC
   decoder `OMX.hisi.video.decoder.avc` at 2456×1600/60, High 5.1; it does not
   advertise standard low-latency support. The candidate changed exactly one
   MediaFormat assignment, without a configure fallback or codec switch.
2. **Do not add a second speculative key in this trial.** The standard
   `FEATURE_LowLatency`/`KEY_LOW_LATENCY` path is not advertised by the only
   qualified decoder. The API is optional and vendor implementation-dependent;
   setting it anyway would be a different experiment and would confound the
   priority comparison.
3. **Do not guess Huawei/Hisi vendor parameters.** The one bounded vendor
   parameter inventory returned no relevant keys. This is an observation for
   the probed path/API/UID, not universal proof that the implementation cannot
   accept private keys; it is not grounds to invent a key.
4. **Do not use max operating rate or switch to software.** The only qualified
   hardware AVC path is Hisi, not Qualcomm. Moonlight's `Short.MAX_VALUE`
   operating-rate optimization is explicitly Qualcomm-gated and excludes
   Adreno 620. The two other inventory entries are software decoders (one is an
   alias), not candidates for this hardware trial. Keep the known rate 60.

## Similar-project evidence (primary sources)

- [Moonlight Android `MediaCodecHelper.java`, pinned commit
  `b48494cb96bff23d8886c4775cc4f39a1075495d`](https://github.com/moonlight-stream/moonlight-android/blob/b48494cb96bff23d8886c4775cc4f39a1075495d/app/src/main/java/com/limelight/binding/video/MediaCodecHelper.java)
  ([raw file](https://raw.githubusercontent.com/moonlight-stream/moonlight-android/b48494cb96bff23d8886c4775cc4f39a1075495d/app/src/main/java/com/limelight/binding/video/MediaCodecHelper.java)):
  the strongest analogous real-time Android decoder implementation. Its
  low-latency option code first sets standard low-latency and returns early
  when the codec advertises `FEATURE_LowLatency`. In its later fallback, the
  very high `KEY_OPERATING_RATE` is gated to Qualcomm decoder prefixes and
  excludes Adreno 620; other eligible Android M+ codecs get
  `KEY_PRIORITY=0`. This is precedent for *testing the standard priority hint*,
  not a guarantee for this Hisi decoder. Its crash comment concerns
  `KEY_PRIORITY=0` in the context of the “ludicrous” high operating-rate
  requirement; it does not establish that priority 0 combined with rate 60 is
  unsafe or safe. The proposed trial intentionally leaves rate 60 unchanged.
- [Android `MediaFormat.KEY_PRIORITY` API](https://developer.android.com/reference/android/media/MediaFormat#KEY_PRIORITY):
  0 means realtime priority; 1 means non-realtime/best effort. Android describes
  this as a resource-planning hint and explicitly does not guarantee performance.
  Its `KEY_FRAME_RATE` is only a desired operating rate when
  `KEY_OPERATING_RATE` is absent and priority is 0; this candidate leaves
  `KEY_OPERATING_RATE=60` set and does not add `KEY_FRAME_RATE`. Priority 0
  still expresses the realtime class, but is not a promised latency mode.
- [AOSP low-latency decoding feature](https://source.android.com/docs/core/media/low-latency-media):
  separate standard feature requiring SoC/decoder support. It is not equivalent
  to setting priority and should not be inferred from this trial.
- [Genymobile scrcpy PR #6670](https://github.com/Genymobile/scrcpy/pull/6670):
  a second project using the public priority hint, merged as part of low-latency
  **encoder** configuration. This supports API plausibility but is not decoder
  evidence and is not a basis for changing Mirri's host encoder.
- [AOSP CTS resource-manager test](https://android.googlesource.com/platform/cts/+/82db1ffa5191f193ee0b6729aae7a3607c8b3651/tests/tests/media/misc/src/android/media/misc/cts/ResourceManagerTestActivityBase.java):
  contains explicit realtime/non-realtime codec-priority test setup; it is API
  semantics context, not an application performance result.

## Exact inventory and selection

Source: the earlier bounded codec metadata and vendor-parameter inventory.
Its original `/private/tmp/mirri-codec-inventory-prep-20260927/` artifacts did
not survive the Mac restart; this recorded inventory was not rerun afterward.

| Rank | Reported name → canonical name | Hardware / alias | 2456×1600 @ 60; AVC High 5.1 | Standard low-latency feature | Decision |
|---|---|---|---|---|---|
| 1 | `OMX.hisi.video.decoder.avc` → same | Hardware; not alias | Qualified | No | Sole trial target |
| — | `c2.android.avc.decoder` → same | Software; not alias | Capabilities report match, but not hardware | No | Exclude |
| — | `OMX.google.h264.decoder` → `c2.android.avc.decoder` | Software alias | Capabilities report match, but not hardware | No | Exclude alias/software |

The vendor query for `OMX.hisi.video.decoder.avc` completed with status `ok`
and no relevant returned keys. Its shell UID was not configured, so this is
not a universal “unsupported” result. Do not assume arbitrary vendor keys are
valid. There was no qualified alternate hardware AVC decoder and no Qualcomm
decoder on which to test the maximum-rate branch.

## Completed comparison and decision

Both runs used macOS 27.0 (26A428), the installed cap4 host, AVC 40 Mbit/s,
2456×1600 at 60 Hz, and the same display-link motion stimulus. The candidate
added only `KEY_PRIORITY=0` beside `KEY_OPERATING_RATE=60`. Host capture,
codec selection, geometry, GOP and quality settings were unchanged. The
undeployed host lifecycle fix was not part of either installed build.

| Metric | Fresh baseline | Priority 0 |
|---|---:|---:|
| Host / client active seconds | 93.183 / 93.386 | 93.074 / 93.169 |
| Capture complete fps | 59.4103 | 59.1572 |
| Encoded / written fps | 59.0132 / 59.0132 | 58.9638 / 58.9530 |
| Decoder output fps | 58.8738 | 58.9145 |
| Input→output p95 / p99 bounds, ms | 62 / 125 | 62 / 125 |
| Input→output maximum, ms | 124.440 | 126.579 |
| Output gap p95 / p99 bounds, ms | 26 / 100 | 24 / 98 |
| Output gap maximum, ms | 122.034 | 123.164 |
| Key input→output p95 / p99 bounds, ms | 58 / 82 | 56 / 92 |
| Key output gap p95 / p99 bounds, ms | 36 / 38 | 36 / 38 |
| Key packet gap p95 / p99 bounds, ms | 96 / 98 | 94 / 125 |
| Key encoder callback p95 / p99 bounds, ms | 68 / 74 | 68 / 78 |
| Host credit high-water | 4 | 4 |

Both independent timing windows completed with final records and normal
Stop. The parent independently reaggregated both runs' raw logs and matched
their receipts. Percentiles above are histogram bounds, not exact quantiles.

**Decision: reject.** The decoder-rate difference is only +0.0407 fps;
decode-latency percentiles did not improve and key-frame tails were mixed.
This does not meet the required material tail improvement. One sequential
pair cannot establish statistical significance or prove the hint never helps.
There is no basis here to retain it or begin a long soak.

Renderer callback coverage was incomplete in both runs (0.8311 / 0.8477).
Neither the decoder rates nor incomplete render telemetry establish panel
FPS. Client join-telemetry high-water 256 is not the host's transport credit
limit of 4.

Evidence persists outside the repository under
`~/Library/Application Support/Mirri/experiment-recovery/priority0-post-restart/`:

- Baseline: `harness/runs/fd59c55b-9ef5-43d4-9475-9065556fa979/baseline90/`.
- Candidate: `harness/runs/8849b474-17a2-4328-8bbc-2d50aa6ef652/candidate90/`,
  including `parent-verdict.json` recording rejection and verified restoration.
- Restored APK SHA-256:
  `dd8f2c6170a87201d68186060b6ab0b1520b727fc31ca1cc43077cad4e42b05a`.

The Android repository source remains the rate-60 baseline without priority 0.
No qualified alternate hardware decoder or exposed vendor low-latency control
was found in this research; do not turn the excluded ideas above into blind
parameter trials.

Interpret existing telemetry carefully: `bufferIndexWait` is
framework-input-index **available→acquired idle time**, not packet-to-decoder
queue wait or starvation. Prior no-delay / GOP120 explorations are already
rejected as new ideas here; do not repeat them or attribute this decoder
priority test to them.

## Follow-up: Wi-Fi policy and Surface presentation (2026-09-27)

With the AVC low-latency host retained, the largest sampled Wi-Fi stall spent
16.72 ms from capture callback to host write completion, then a causally bounded
470.72–482.88 ms before the tablet completed that frame's packet. Following
frames had decreasing post-write delays. This locates a backlog after local
write completion; it does **not** distinguish radio power saving, AP/kernel
queues, TCP loss/retransmission, or a stalled receiver. Local write completion
does not mean remote delivery.

[Moonlight's pinned `Game.java`](https://github.com/moonlight-stream/moonlight-android/blob/b48494cb96bff23d8886c4775cc4f39a1075495d/app/src/main/java/com/limelight/Game.java)
acquires both a high-performance Wi-Fi lock and, on API 29+, a low-latency lock.
It catches vendor `SecurityException` even with `WAKE_LOCK` declared.
[Android's low-latency Wi-Fi mode](https://developer.android.com/reference/android/net/wifi/WifiManager#WIFI_MODE_FULL_LOW_LATENCY)
is a foreground, screen-on policy with power/throughput/roaming tradeoffs, not
a guarantee against network stalls.

**Tested and rejected on this tablet:** one attempt-scoped
`WIFI_MODE_FULL_LOW_LATENCY` lock, with release in `finally`, no USB lock and
no other media changes. Android API 31 reported the lock held, released, and
96,075 ms of low-latency active time after the first candidate run. Four
90-second runs were ordered baseline → candidate → candidate → baseline:

| Run | Sampled callback→packet p95 bounds, ms | Sampled callback→render p95 bounds, ms |
| --- | ---: | ---: |
| Baseline 1 | 37.3–50.0 | 92.5–104.3 |
| Candidate 1 | 51.5–64.0 | 105.1–117.8 |
| Candidate 2 | 80.2–94.6 | 133.8–150.3 |
| Baseline 2 | 65.4–81.6 | 125.1–141.9 |

All collection windows completed; render evidence remained incomplete.
Background load and network conditions were uncontrolled, so these results
do not prove the hint causes regressions. They show no benefit sufficient to
retain its power-policy change. The source was removed and the original APK
restored before the presentation experiment. Numeric evidence, both APKs and
the candidate source are in ignored `artifacts/wifi-latency-lock-2026-09-27/`.

For presentation, [Moonlight's pinned decoder renderer](https://github.com/moonlight-stream/moonlight-android/blob/b48494cb96bff23d8886c4775cc4f39a1075495d/app/src/main/java/com/limelight/binding/video/MediaCodecDecoderRenderer.java)
distinguishes immediate low-latency release with `System.nanoTime()` from
timestamp-zero no-drop behavior and a separately bounded Choreographer pacing
mode. Mirri's boolean `releaseOutputBuffer(index, true)` instead inherits
session-relative media PTS, which is not an Android clock. The
[MediaCodec API](https://developer.android.com/reference/android/media/MediaCodec#releaseOutputBuffer(int,long))
documents different SurfaceView scheduling/drop behavior for near-current and
far-away timestamps. An explicit local timestamp is therefore a distinct,
testable presentation change—not another decoder-priority hint or an excuse
to add an unbounded output queue.

Scrcpy's separate sockets and default immediate display are useful architectural
comparisons, but its desktop decoder is not Android Surface evidence. Sunshine
uses UDP video, so its advice about burst traffic and network jitter is not a
drop-in recipe for Mirri's reliable ordered TCP stream. Arbitrarily dropping
encoded P frames would violate reference dependencies.
