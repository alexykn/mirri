"""Offline, fail-closed schema-4 timing aggregation with read-only v3 decoding.

Inputs are numeric-only filtered host.log and `adb logcat -v epoch -s
MirriTiming:I '*:S'` captured by an owner-approved, separately reviewed runner.
No device access, app launch, screen capture or benchmark occurs here.
"""

import argparse
from dataclasses import dataclass
import json
import math
from pathlib import Path
import re
from typing import TypedDict, cast

ROOT = Path(__file__).resolve().parent
BOUNDS_MS = tuple(range(2, 101, 2)) + (125, 150, 200, 250, 500, 1000, 5000, 10000)
HOST_STAGES_V3 = (
    "mediaPtsGap", "completeCallbackGap", "vtCall", "vtCallback", "conversion",
    "callbackToWrite", "outputToWrite", "conversionToWrite", "sendGap", "sentPtsGap",
)
CLIENT_STAGES_V3 = (
    "packetInput", "inputOutput", "outputRelease", "releaseCall", "releaseRender",
    "packetRender", "renderNotify", "bufferIndexWait", "packetGap", "mediaPtsGap",
    "outputGap", "renderGap", "packetRelease",
)
HOST_STAGES = HOST_STAGES_V3 + ("keyVtCallback",)
CLIENT_STAGES = CLIENT_STAGES_V3 + ("keyPacketGap", "keyInputOutput", "keyOutputGap")
HOST_GAPS = frozenset(("mediaPtsGap", "completeCallbackGap", "sendGap", "sentPtsGap"))
CLIENT_GAPS = frozenset(("packetGap", "mediaPtsGap", "outputGap", "renderGap"))
HOST_NUMERIC_V3 = frozenset(("v", "epoch", "generation", "record", "startNs", "endNs", "final", "complete",
                          "encoded", "written", "missingPTS", "invalidClock", "sequenceMismatch",
                          "truncatedDecoderPTS", "creditHigh", "encodedQueueHigh"))
CLIENT_NUMERIC_V3 = frozenset(("v", "owner", "epoch", "record", "startNs", "endNs", "final", "generation",
                            "rightCensored", "interiorPending",
                            "joinAvailable", "outstanding", "highWater", "releasedTotal",
                            "renderedTotal", "validRenderedTotal", "renderInstalled", "renderSeen",
                            "received", "queued", "output", "released", "rendered", "truncatedPts",
                            "duplicate", "unmatched", "late", "overflow", "expired", "missingRender",
                            "invalidClock", "renderInvalid", "ambiguousGeneration", "ambiguousFrame",
                            "renderListenerUnavailable", "missingOutputSeq", "reorderedOutput",
                            "ambiguousOutputGap", "missingRenderSeq", "reorderedRender",
                            "ambiguousRenderGap"))
HOST_NUMERIC = HOST_NUMERIC_V3 | {"keyEncoded", "keyWritten", "keyBytes", "keyMaxBytes",
                                 "otherBytes", "otherMaxBytes"}
CLIENT_NUMERIC = CLIENT_NUMERIC_V3 | {"keyReceived", "keyOutput", "keyBytes", "keyMaxBytes",
                                     "otherBytes", "otherMaxBytes"}
HOST_PREFIX = re.compile(r"^\d{4}-\d\d-\d\dT[^ ]+ metrics videoTiming ")
HOST_STATE = re.compile(r"^\d{4}-\d\d-\d\dT[^ ]+ state ([A-Za-z]+)")
CLIENT_PREFIX = re.compile(r"\bI\s+MirriTiming:\s+")
TOKEN = re.compile(r"^([A-Za-z][A-Za-z0-9]*)=([^ ]+)$")


class RunnerConfig(TypedDict):
    schema: int
    allowedActiveSeconds: list[int]
    maxRecords: int
    maxLineBytes: int
    maxIntervalSeconds: float
    minimumValidRenderCoverage: float
    startupSeconds: int


def load_config() -> RunnerConfig:
    # Fixed reviewed source constants, not an unvalidated runtime JSON override.
    return {"schema": 4, "allowedActiveSeconds": [90, 300, 1800],
            "maxRecords": 7200, "maxLineBytes": 3900,
            "maxIntervalSeconds": 2.5, "minimumValidRenderCoverage": 0.98,
            "startupSeconds": 120}


class IncompleteCalibration(ValueError):
    """An incomplete or ambiguous record set is never an acceptance pass."""


@dataclass(frozen=True)
class Histogram:
    bins: tuple[int, ...]
    maximum_ms: float
    gaps: tuple[int, ...] | None

    @property
    def count(self) -> int:
        return sum(self.bins)

    def bound_ms(self, fraction: float) -> float | None:
        if not self.count:
            return None
        rank = math.ceil(self.count * fraction)
        n = 0
        for i, count in enumerate(self.bins):
            n += count
            if n >= rank:
                return float(BOUNDS_MS[i]) if i < len(BOUNDS_MS) else None
        raise IncompleteCalibration("histogram rank")


def _number(text: str) -> int:
    if not text.isdecimal():
        raise IncompleteCalibration("non-numeric counter")
    return int(text)


def _float(text: str) -> float:
    try:
        value = float(text)
    except ValueError as error:
        raise IncompleteCalibration("invalid histogram float") from error
    if not math.isfinite(value):
        raise IncompleteCalibration("non-finite histogram float")
    return value


def _histogram(value: str, gap_stage: bool) -> Histogram:
    fields = value.split(":")
    if len(fields) != 7:
        raise IncompleteCalibration("histogram schema")
    n = _number(fields[0])
    bins = tuple(_number(v) for v in fields[5].split("."))
    if len(bins) != len(BOUNDS_MS) + 1 or n != sum(bins):
        raise IncompleteCalibration("histogram bucket count")
    maximum = _float(fields[4])
    if n == 0 and maximum != -1 or n > 0 and maximum < 0:
        raise IncompleteCalibration("histogram maximum")
    gaps = None
    if gap_stage:
        gaps = tuple(_number(v) for v in fields[6].split("."))
        if len(gaps) != 10 or gaps[0] > n or gaps[1] > gaps[0] or gaps[2] > gaps[1]:
            raise IncompleteCalibration("gap schema/count")
    elif fields[6] != "na":
        raise IncompleteCalibration("unexpected gap fields")
    result = Histogram(bins, maximum, gaps)
    for index, fraction in enumerate((0.5, 0.95, 0.99), start=1):
        reported = _float(fields[index])
        expected = result.bound_ms(fraction)
        if not math.isclose(reported, expected if expected is not None else -1.0, abs_tol=0.001):
            raise IncompleteCalibration("incorrect interval quantile")
    if n:
        highest = max(i for i, count in enumerate(bins) if count)
        floor = 0 if highest == 0 else BOUNDS_MS[highest - 1]
        ceiling = BOUNDS_MS[highest] if highest < len(BOUNDS_MS) else math.inf
        # A zero-duration observation is valid in the first (0..2 ms) bin.
        # Every later bin has an exclusive, strictly positive lower edge.
        if (highest > 0 and maximum <= floor) or maximum > ceiling + 0.000001:
            raise IncompleteCalibration("maximum inconsistent with occupied bin")
    return result


@dataclass(frozen=True)
class Record:
    numbers: dict[str, int]
    stages: dict[str, Histogram]


def validate_timing_line(line: str, source: str) -> Record:
    """Validate the *whole* record before the live collector persists it."""
    prefix = HOST_PREFIX if source == "host" else CLIENT_PREFIX
    gap_stages = HOST_GAPS if source == "host" else CLIENT_GAPS
    found = prefix.search(line)
    if found is None:
        raise IncompleteCalibration("malformed timing prefix")
    fields: dict[str, str] = {}
    for word in line[found.end():].strip().split():
        match = TOKEN.fullmatch(word)
        if match is None or match[1] in fields:
            raise IncompleteCalibration("malformed/duplicate timing token")
        fields[match[1]] = match[2]
    if "v" not in fields:
        raise IncompleteCalibration("missing timing schema")
    version = _number(fields["v"])
    if version not in (3, 4):
        raise IncompleteCalibration("unsupported schema")
    stages = (HOST_STAGES if source == "host" else CLIENT_STAGES) if version == 4 else (
        HOST_STAGES_V3 if source == "host" else CLIENT_STAGES_V3)
    fixed = {"capturePtsToCallback": "unavailable-unverified-clock"} if source == "host" else {}
    numeric_names = (HOST_NUMERIC if source == "host" else CLIENT_NUMERIC) if version == 4 else (
        HOST_NUMERIC_V3 if source == "host" else CLIENT_NUMERIC_V3)
    if fields.keys() != numeric_names | set(stages) | fixed.keys():
        raise IncompleteCalibration("missing/unknown timing field")
    if any(fields[key] != value for key, value in fixed.items()):
        raise IncompleteCalibration("unverified clock claim")
    histograms = {stage: _histogram(fields[stage], stage in gap_stages) for stage in stages}
    numeric = {key: _number(fields[key]) for key in numeric_names}
    if version == 4:
        total = numeric["encoded" if source == "host" else "received"]
        keys = numeric["keyEncoded" if source == "host" else "keyReceived"]
        if keys > total or numeric["keyMaxBytes"] > numeric["keyBytes"] or numeric["otherMaxBytes"] > numeric["otherBytes"]:
            raise IncompleteCalibration("key AU counters inconsistent")
        if source == "host":
            if numeric["keyWritten"] > numeric["written"] or histograms["keyVtCallback"].count > histograms["vtCallback"].count:
                raise IncompleteCalibration("key host stages inconsistent")
        elif numeric["keyOutput"] > numeric["output"] or any(
            histograms[key].count > histograms[all_frames].count
            for key, all_frames in (("keyPacketGap", "packetGap"), ("keyInputOutput", "inputOutput"),
                                    ("keyOutputGap", "outputGap"))
        ):
            raise IncompleteCalibration("key client stages inconsistent")
    return Record(numeric, histograms)


def parse(path: Path, source: str, max_line_bytes: int) -> list[Record]:
    marker = "metrics videoTiming " if source == "host" else "MirriTiming:"
    records: list[Record] = []
    with path.open(encoding="utf-8", errors="strict") as stream:
        for line in stream:
            if source == "host" and records:
                state = HOST_STATE.match(line)
                if state and state[1] not in ("streaming", "stopping", "idle"):
                    raise IncompleteCalibration("host left stream or reconnected")
                if re.match(r"^\d{4}-\d\d-\d\dT[^ ]+ error ", line):
                    raise IncompleteCalibration("host failure during observation")
            if marker not in line:
                continue
            if len(line.encode("utf-8")) > max_line_bytes:
                raise IncompleteCalibration("timing record too long/truncated")
            records.append(validate_timing_line(line, source))
    if not records:
        raise IncompleteCalibration("no timing records")
    return records


def aggregate(records: list[Record], source: str, seconds: int, config: RunnerConfig) -> dict[str, object]:
    if len(records) > config["maxRecords"]:
        raise IncompleteCalibration("record bound exceeded")
    version = records[0].numbers["v"]
    if version not in (3, config["schema"]):
        raise IncompleteCalibration("unsupported aggregate schema")
    keys = ("v", "epoch", "generation") if source == "host" else ("v", "owner", "epoch", "generation")
    identity = tuple(records[0].numbers[key] for key in keys)
    first = records[0].numbers["startNs"]
    previous = first
    max_gap = int(config["maxIntervalSeconds"] * 1e9)
    for index, record in enumerate(records):
        row = record.numbers
        if tuple(row[key] for key in keys) != identity or row["record"] != index:
            raise IncompleteCalibration("owner/generation boundary or missing/duplicate interval")
        if row["final"] != int(index == len(records) - 1):
            raise IncompleteCalibration("missing, early or duplicate final flush")
        if row["startNs"] != previous or row["endNs"] < row["startNs"]:
            raise IncompleteCalibration("overlapping or missing interval")
        if row["endNs"] - row["startNs"] > max_gap:
            raise IncompleteCalibration("long reporting gap")
        previous = row["endNs"]
    active = sum(row.numbers["endNs"] - row.numbers["startNs"] for row in records) / 1e9
    if active != (previous - first) / 1e9:
        raise IncompleteCalibration("inconsistent interval duration")
    if active < seconds:
        raise IncompleteCalibration("insufficient full-window active seconds")
    stages = (HOST_STAGES if source == "host" else CLIENT_STAGES) if version == 4 else (
        HOST_STAGES_V3 if source == "host" else CLIENT_STAGES_V3)
    combined: dict[str, dict[str, object]] = {}
    for stage in stages:
        frames = [record.stages[stage] for record in records]
        bins = tuple(sum(hist.bins[index] for hist in frames) for index in range(len(BOUNDS_MS) + 1))
        last_gaps = frames[-1].gaps
        gaps = (tuple(sum(hist.gaps[index] for hist in frames if hist.gaps is not None)
                      for index in range(8))
                + (max(hist.gaps[8] for hist in frames if hist.gaps is not None), last_gaps[9])
                if last_gaps is not None else None)
        if gaps is not None and gaps[-1] != 0:
            raise IncompleteCalibration("unclosed frame-gap burst")
        hist = Histogram(bins, max(h.maximum_ms for h in frames), gaps)
        combined[stage] = {"count": hist.count, "p50BoundMs": hist.bound_ms(0.5),
                           "p95BoundMs": hist.bound_ms(0.95), "p99BoundMs": hist.bound_ms(0.99),
                           "maxMs": hist.maximum_ms, "bins": bins, "gapCounters": gaps}
    result: dict[str, object] = {"source": source, "schema": version, "intervals": len(records),
                                 "activeSeconds": active, "epoch": records[0].numbers["epoch"],
                                 "stages": combined, "completeWindow": True}
    if version == 4:
        key_name = "keyEncoded" if source == "host" else "keyReceived"
        total_name = "encoded" if source == "host" else "received"
        total_units = sum(row.numbers[total_name] for row in records)
        key_units = sum(row.numbers[key_name] for row in records)
        classified = {}
        pairs = (("vtCallback", "keyVtCallback"),) if source == "host" else (
            ("packetGap", "keyPacketGap"), ("inputOutput", "keyInputOutput"),
            ("outputGap", "keyOutputGap"))
        for total_stage, key_stage in pairs:
            total_bins = combined[total_stage]["bins"]
            key_bins = combined[key_stage]["bins"]
            if not isinstance(total_bins, tuple) or not isinstance(key_bins, tuple):
                raise IncompleteCalibration("key histogram bins missing")
            total_bins = cast(tuple[int, ...], total_bins)
            key_bins = cast(tuple[int, ...], key_bins)
            if any(key > total for key, total in zip(key_bins, total_bins)):
                raise IncompleteCalibration("key histogram exceeds total")
            nonkey = Histogram(tuple(total - key for key, total in zip(key_bins, total_bins)), 0, None)
            classified[total_stage] = {"key": combined[key_stage], "nonkey": {
                "count": nonkey.count, "p50BoundMs": nonkey.bound_ms(0.5),
                "p95BoundMs": nonkey.bound_ms(0.95), "p99BoundMs": nonkey.bound_ms(0.99),
                "maxMs": None, "bins": nonkey.bins}}
        result["keyClasses"] = {
            "key": {"count": key_units, "bytes": sum(r.numbers["keyBytes"] for r in records),
                    "maxBytes": max(r.numbers["keyMaxBytes"] for r in records)},
            "nonkey": {"count": total_units - key_units,
                       "bytes": sum(r.numbers["otherBytes"] for r in records),
                       "maxBytes": max(r.numbers["otherMaxBytes"] for r in records)},
            "stages": classified}
    if source == "host":
        totals = {key: sum(record.numbers[key] for record in records)
                  for key in ("complete", "encoded", "written")}
        if not (totals["complete"] >= totals["encoded"] >= totals["written"]):
            raise IncompleteCalibration("host capture/encode/write totals inconsistent")
        rates = {key: totals[key] / active for key in totals}
        result["fps"] = rates
        if any(record.numbers[name] for record in records
               for name in ("invalidClock", "sequenceMismatch", "missingPTS")):
            raise IncompleteCalibration("invalid host clock, sequence or capture PTS")
    else:
        final = records[-1].numbers
        if any(record.numbers["joinAvailable"] != 1 for record in records):
            raise IncompleteCalibration("ambiguous codec generation")
        rates = {key: sum(record.numbers[key] for record in records) / active
                 for key in ("received", "queued", "output", "released", "rendered")}
        totals = {key: sum(record.numbers[key] for record in records)
                  for key in ("received", "queued", "output", "released", "rendered")}
        if not (totals["received"] >= totals["queued"] >= totals["output"]
                >= totals["released"] >= totals["rendered"]):
            raise IncompleteCalibration("codec stage totals inconsistent")
        released, rendered, valid = (final[key] for key in
                                     ("releasedTotal", "renderedTotal", "validRenderedTotal"))
        right, interior = final["rightCensored"], final["interiorPending"]
        if (released != totals["released"] or rendered != totals["rendered"]
                or right + interior > released - rendered or valid > rendered):
            raise IncompleteCalibration("cumulative release/render or tail inconsistent")
        measured = released - right
        coverage = valid / measured if measured else None
        rates["validRendered"] = valid / active
        result.update({"fps": rates, "rightCensored": right, "interiorPending": interior,
                       "renderCoverage": coverage})
        issues = ("renderInvalid", "ambiguousGeneration", "ambiguousOutputGap", "ambiguousRenderGap",
                  "expired", "invalidClock", "missingRender", "late", "duplicate", "overflow",
                  "unmatched", "missingOutputSeq", "missingRenderSeq")
        invalid = any(record.numbers[name] for record in records for name in issues)
        if final["renderInstalled"] != 1 or final["renderSeen"] != 1:
            status = "unavailable"
        elif (not invalid and interior == 0 and coverage is not None
              and coverage >= config["minimumValidRenderCoverage"]):
            status = "valid"
        else:
            status = "incomplete"
        result["renderStatus"] = status
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", required=True, type=Path, help="numeric-only host log")
    parser.add_argument("--client", required=True, type=Path, help="filtered numeric-only logcat")
    parser.add_argument("--active-seconds", type=int, required=True)
    args = parser.parse_args()
    try:
        config = load_config()
        if args.active_seconds not in config["allowedActiveSeconds"]:
            raise IncompleteCalibration("duration not approved by bounded configuration")
        results = [aggregate(parse(path, source, int(config["maxLineBytes"])), source,
                             args.active_seconds, config)
                   for path, source in ((args.host, "host"), (args.client, "client"))]
        if results[0]["epoch"] != results[1]["epoch"]:
            raise IncompleteCalibration("host/client epoch mismatch")
    except (IncompleteCalibration, OSError, UnicodeError) as error:
        print(f"incomplete calibration: {error.__class__.__name__}: {error}")
        return 2
    print(json.dumps({"sourceOnlyAnalysis": True, "acceptance": "not-assessed", "records": results}, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
