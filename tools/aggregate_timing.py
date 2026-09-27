"""Offline, fail-closed schema-4 timing aggregation with read-only v3 decoding.

Inputs are numeric-only filtered host.log and `adb logcat -v epoch -s
MirriTiming:I '*:S'` captured by an owner-approved, separately reviewed runner.
No device access, app launch, screen capture or benchmark occurs here.
"""

import argparse
import json
import math
import re
from dataclasses import dataclass
from pathlib import Path
from typing import TypedDict, cast

ROOT = Path(__file__).resolve().parent
BOUNDS_MS = (*range(2, 101, 2), 125, 150, 200, 250, 500, 1000, 5000, 10000)
HOST_STAGES_V3 = (
    "mediaPtsGap",
    "completeCallbackGap",
    "vtCall",
    "vtCallback",
    "conversion",
    "callbackToWrite",
    "outputToWrite",
    "conversionToWrite",
    "sendGap",
    "sentPtsGap",
)
CLIENT_STAGES_V3 = (
    "packetInput",
    "inputOutput",
    "outputRelease",
    "releaseCall",
    "releaseRender",
    "packetRender",
    "renderNotify",
    "bufferIndexWait",
    "packetGap",
    "mediaPtsGap",
    "outputGap",
    "renderGap",
    "packetRelease",
)
HOST_STAGES = (*HOST_STAGES_V3, "keyVtCallback")
CLIENT_STAGES = (*CLIENT_STAGES_V3, "keyPacketGap", "keyInputOutput", "keyOutputGap")
HOST_GAPS = frozenset(("mediaPtsGap", "completeCallbackGap", "sendGap", "sentPtsGap"))
CLIENT_GAPS = frozenset(("packetGap", "mediaPtsGap", "outputGap", "renderGap"))
HOST_NUMERIC_V3 = frozenset(
    (
        "v",
        "epoch",
        "generation",
        "record",
        "startNs",
        "endNs",
        "final",
        "complete",
        "encoded",
        "written",
        "missingPTS",
        "invalidClock",
        "sequenceMismatch",
        "truncatedDecoderPTS",
        "creditHigh",
        "encodedQueueHigh",
    )
)
CLIENT_NUMERIC_V3 = frozenset(
    (
        "v",
        "owner",
        "epoch",
        "record",
        "startNs",
        "endNs",
        "final",
        "generation",
        "rightCensored",
        "interiorPending",
        "joinAvailable",
        "outstanding",
        "highWater",
        "releasedTotal",
        "renderedTotal",
        "validRenderedTotal",
        "renderInstalled",
        "renderSeen",
        "received",
        "queued",
        "output",
        "released",
        "rendered",
        "truncatedPts",
        "duplicate",
        "unmatched",
        "late",
        "overflow",
        "expired",
        "missingRender",
        "invalidClock",
        "renderInvalid",
        "ambiguousGeneration",
        "ambiguousFrame",
        "renderListenerUnavailable",
        "missingOutputSeq",
        "reorderedOutput",
        "ambiguousOutputGap",
        "missingRenderSeq",
        "reorderedRender",
        "ambiguousRenderGap",
    )
)
HOST_NUMERIC = HOST_NUMERIC_V3 | {
    "keyEncoded",
    "keyWritten",
    "keyBytes",
    "keyMaxBytes",
    "otherBytes",
    "otherMaxBytes",
}
CLIENT_NUMERIC = CLIENT_NUMERIC_V3 | {
    "keyReceived",
    "keyOutput",
    "keyBytes",
    "keyMaxBytes",
    "otherBytes",
    "otherMaxBytes",
}
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
    return {
        "schema": 4,
        "allowedActiveSeconds": [90, 300, 1800],
        "maxRecords": 7200,
        "maxLineBytes": 3900,
        "maxIntervalSeconds": 2.5,
        "minimumValidRenderCoverage": 0.98,
        "startupSeconds": 120,
    }


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
    if (n == 0 and maximum != -1) or (n > 0 and maximum < 0):
        raise IncompleteCalibration("histogram maximum")
    gaps = _histogram_gaps(fields[6], n, gap_stage)
    result = Histogram(bins, maximum, gaps)
    _check_histogram_bounds(fields, result)
    return result


def _histogram_gaps(text: str, n: int, gap_stage: bool) -> tuple[int, ...] | None:
    if not gap_stage:
        if text != "na":
            raise IncompleteCalibration("unexpected gap fields")
        return None
    gaps = tuple(_number(v) for v in text.split("."))
    if len(gaps) != 10 or gaps[0] > n or gaps[1] > gaps[0] or gaps[2] > gaps[1]:
        raise IncompleteCalibration("gap schema/count")
    return gaps


def _check_histogram_bounds(fields: list[str], result: Histogram) -> None:
    for index, fraction in enumerate((0.5, 0.95, 0.99), start=1):
        reported = _float(fields[index])
        expected = result.bound_ms(fraction)
        if not math.isclose(
            reported, expected if expected is not None else -1.0, abs_tol=0.001
        ):
            raise IncompleteCalibration("incorrect interval quantile")
    _check_maximum_bin(result)


def _check_maximum_bin(result: Histogram) -> None:
    if not result.count:
        return
    highest = max(i for i, count in enumerate(result.bins) if count)
    floor = 0 if highest == 0 else BOUNDS_MS[highest - 1]
    ceiling = BOUNDS_MS[highest] if highest < len(BOUNDS_MS) else math.inf
    # Zero belongs in the first bin; subsequent bins exclude their lower edge.
    if (
        highest > 0 and result.maximum_ms <= floor
    ) or result.maximum_ms > ceiling + 0.000001:
        raise IncompleteCalibration("maximum inconsistent with occupied bin")


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
    fields = _tokens(line[found.end() :])
    if "v" not in fields:
        raise IncompleteCalibration("missing timing schema")
    version = _number(fields["v"])
    if version not in (3, 4):
        raise IncompleteCalibration("unsupported schema")
    stages, numeric_names = _schema_fields(source, version)
    fixed = (
        {"capturePtsToCallback": "unavailable-unverified-clock"}
        if source == "host"
        else {}
    )
    _check_fields(fields, numeric_names | set(stages) | fixed.keys(), fixed)
    histograms = {
        stage: _histogram(fields[stage], stage in gap_stages) for stage in stages
    }
    numeric = {key: _number(fields[key]) for key in numeric_names}
    if version == 4:
        _validate_key_counters(source, numeric, histograms)
    return Record(numeric, histograms)


def _tokens(payload: str) -> dict[str, str]:
    fields: dict[str, str] = {}
    for word in payload.strip().split():
        match = TOKEN.fullmatch(word)
        if match is None or match[1] in fields:
            raise IncompleteCalibration("malformed/duplicate timing token")
        fields[match[1]] = match[2]
    return fields


def _check_fields(
    fields: dict[str, str], expected: set[str] | frozenset[str], fixed: dict[str, str]
) -> None:
    if fields.keys() != expected:
        raise IncompleteCalibration("missing/unknown timing field")
    if any(fields[key] != value for key, value in fixed.items()):
        raise IncompleteCalibration("unverified clock claim")


def _schema_fields(
    source: str, version: int
) -> tuple[tuple[str, ...], frozenset[str] | set[str]]:
    if source == "host":
        return (
            (HOST_STAGES, HOST_NUMERIC)
            if version == 4
            else (HOST_STAGES_V3, HOST_NUMERIC_V3)
        )
    return (
        (CLIENT_STAGES, CLIENT_NUMERIC)
        if version == 4
        else (CLIENT_STAGES_V3, CLIENT_NUMERIC_V3)
    )


def _validate_key_counters(
    source: str, numeric: dict[str, int], histograms: dict[str, Histogram]
) -> None:
    total = numeric["encoded" if source == "host" else "received"]
    keys = numeric["keyEncoded" if source == "host" else "keyReceived"]
    if (
        keys > total
        or numeric["keyMaxBytes"] > numeric["keyBytes"]
        or numeric["otherMaxBytes"] > numeric["otherBytes"]
    ):
        raise IncompleteCalibration("key AU counters inconsistent")
    if source == "host" and (
        numeric["keyWritten"] > numeric["written"]
        or histograms["keyVtCallback"].count > histograms["vtCallback"].count
    ):
        raise IncompleteCalibration("key host stages inconsistent")
    if source == "client":
        _validate_client_key_counters(numeric, histograms)


def _validate_client_key_counters(
    numeric: dict[str, int], histograms: dict[str, Histogram]
) -> None:
    if numeric["keyOutput"] > numeric["output"] or any(
        histograms[key].count > histograms[all_frames].count
        for key, all_frames in (
            ("keyPacketGap", "packetGap"),
            ("keyInputOutput", "inputOutput"),
            ("keyOutputGap", "outputGap"),
        )
    ):
        raise IncompleteCalibration("key client stages inconsistent")


def parse(path: Path, source: str, max_line_bytes: int) -> list[Record]:
    marker = "metrics videoTiming " if source == "host" else "MirriTiming:"
    records: list[Record] = []
    with path.open(encoding="utf-8", errors="strict") as stream:
        for line in stream:
            if source == "host" and records:
                _check_host_state(line)
            if marker not in line:
                continue
            if len(line.encode("utf-8")) > max_line_bytes:
                raise IncompleteCalibration("timing record too long/truncated")
            records.append(validate_timing_line(line, source))
    if not records:
        raise IncompleteCalibration("no timing records")
    return records


def _check_host_state(line: str) -> None:
    state = HOST_STATE.match(line)
    if state and state[1] not in ("streaming", "stopping", "idle"):
        raise IncompleteCalibration("host left stream or reconnected")
    if re.match(r"^\d{4}-\d\d-\d\dT[^ ]+ error ", line):
        raise IncompleteCalibration("host failure during observation")


def aggregate(
    records: list[Record], source: str, seconds: int, config: RunnerConfig
) -> dict[str, object]:
    version, active = _validate_window(records, source, seconds, config)
    stages, _ = _schema_fields(source, version)
    combined = {stage: _combine_stage(records, stage) for stage in stages}
    result: dict[str, object] = {
        "source": source,
        "schema": version,
        "intervals": len(records),
        "activeSeconds": active,
        "epoch": records[0].numbers["epoch"],
        "stages": combined,
        "completeWindow": True,
    }
    if version == 4:
        result["keyClasses"] = _key_classes(records, source, combined)
    if source == "host":
        _host_summary(records, active, result)
    else:
        _client_summary(records, active, config, result)
    return result


def _validate_window(
    records: list[Record], source: str, seconds: int, config: RunnerConfig
) -> tuple[int, float]:
    if len(records) > config["maxRecords"]:
        raise IncompleteCalibration("record bound exceeded")
    version = records[0].numbers["v"]
    if version not in (3, config["schema"]):
        raise IncompleteCalibration("unsupported aggregate schema")
    keys = (
        ("v", "epoch", "generation")
        if source == "host"
        else ("v", "owner", "epoch", "generation")
    )
    identity = tuple(records[0].numbers[key] for key in keys)
    first = records[0].numbers["startNs"]
    previous = first
    max_gap = int(config["maxIntervalSeconds"] * 1e9)
    for index, record in enumerate(records):
        row = record.numbers
        _validate_interval(row, keys, identity, index, len(records), previous, max_gap)
        previous = row["endNs"]
    active = sum(row.numbers["endNs"] - row.numbers["startNs"] for row in records) / 1e9
    if active != (previous - first) / 1e9:
        raise IncompleteCalibration("inconsistent interval duration")
    if active < seconds:
        raise IncompleteCalibration("insufficient full-window active seconds")
    return version, active


def _validate_interval(
    row: dict[str, int],
    keys: tuple[str, ...],
    identity: tuple[int, ...],
    index: int,
    count: int,
    previous: int,
    max_gap: int,
) -> None:
    if tuple(row[key] for key in keys) != identity or row["record"] != index:
        raise IncompleteCalibration(
            "owner/generation boundary or missing/duplicate interval"
        )
    if row["final"] != int(index == count - 1):
        raise IncompleteCalibration("missing, early or duplicate final flush")
    if row["startNs"] != previous or row["endNs"] < row["startNs"]:
        raise IncompleteCalibration("overlapping or missing interval")
    if row["endNs"] - row["startNs"] > max_gap:
        raise IncompleteCalibration("long reporting gap")


def _combine_stage(records: list[Record], stage: str) -> dict[str, object]:
    frames = [record.stages[stage] for record in records]
    bins = tuple(
        sum(hist.bins[index] for hist in frames) for index in range(len(BOUNDS_MS) + 1)
    )
    gaps = _combine_gaps(frames)
    hist = Histogram(bins, max(h.maximum_ms for h in frames), gaps)
    return {
        "count": hist.count,
        "p50BoundMs": hist.bound_ms(0.5),
        "p95BoundMs": hist.bound_ms(0.95),
        "p99BoundMs": hist.bound_ms(0.99),
        "maxMs": hist.maximum_ms,
        "bins": bins,
        "gapCounters": gaps,
    }


def _combine_gaps(frames: list[Histogram]) -> tuple[int, ...] | None:
    last_gaps = frames[-1].gaps
    gaps = (
        (
            *(
                sum(hist.gaps[index] for hist in frames if hist.gaps is not None)
                for index in range(8)
            ),
            max(hist.gaps[8] for hist in frames if hist.gaps is not None),
            last_gaps[9],
        )
        if last_gaps is not None
        else None
    )
    if gaps is not None and gaps[-1] != 0:
        raise IncompleteCalibration("unclosed frame-gap burst")
    return gaps


def _key_classes(
    records: list[Record], source: str, combined: dict[str, dict[str, object]]
) -> dict[str, object]:
    key_name = "keyEncoded" if source == "host" else "keyReceived"
    total_name = "encoded" if source == "host" else "received"
    total_units = sum(row.numbers[total_name] for row in records)
    key_units = sum(row.numbers[key_name] for row in records)
    classified = {}
    pairs = {
        "host": (("vtCallback", "keyVtCallback"),),
        "client": (
            ("packetGap", "keyPacketGap"),
            ("inputOutput", "keyInputOutput"),
            ("outputGap", "keyOutputGap"),
        ),
    }[source]
    for total_stage, key_stage in pairs:
        classified[total_stage] = _classify_stage(combined, total_stage, key_stage)
    return {
        "key": {
            "count": key_units,
            "bytes": sum(r.numbers["keyBytes"] for r in records),
            "maxBytes": max(r.numbers["keyMaxBytes"] for r in records),
        },
        "nonkey": {
            "count": total_units - key_units,
            "bytes": sum(r.numbers["otherBytes"] for r in records),
            "maxBytes": max(r.numbers["otherMaxBytes"] for r in records),
        },
        "stages": classified,
    }


def _classify_stage(
    combined: dict[str, dict[str, object]], total_stage: str, key_stage: str
) -> dict[str, object]:
    total_bins = combined[total_stage]["bins"]
    key_bins = combined[key_stage]["bins"]
    if not isinstance(total_bins, tuple) or not isinstance(key_bins, tuple):
        raise IncompleteCalibration("key histogram bins missing")
    total_bins = cast(tuple[int, ...], total_bins)
    key_bins = cast(tuple[int, ...], key_bins)
    if any(key > total for key, total in zip(key_bins, total_bins, strict=True)):
        raise IncompleteCalibration("key histogram exceeds total")
    nonkey = Histogram(
        tuple(total - key for key, total in zip(key_bins, total_bins, strict=True)),
        0,
        None,
    )
    return {
        "key": combined[key_stage],
        "nonkey": {
            "count": nonkey.count,
            "p50BoundMs": nonkey.bound_ms(0.5),
            "p95BoundMs": nonkey.bound_ms(0.95),
            "p99BoundMs": nonkey.bound_ms(0.99),
            "maxMs": None,
            "bins": nonkey.bins,
        },
    }


def _host_summary(
    records: list[Record], active: float, result: dict[str, object]
) -> None:
    totals = {
        key: sum(record.numbers[key] for record in records)
        for key in ("complete", "encoded", "written")
    }
    if not (totals["complete"] >= totals["encoded"] >= totals["written"]):
        raise IncompleteCalibration("host capture/encode/write totals inconsistent")
    result["fps"] = {key: totals[key] / active for key in totals}
    if any(
        record.numbers[name]
        for record in records
        for name in ("invalidClock", "sequenceMismatch", "missingPTS")
    ):
        raise IncompleteCalibration("invalid host clock, sequence or capture PTS")


def _client_summary(
    records: list[Record],
    active: float,
    config: RunnerConfig,
    result: dict[str, object],
) -> None:
    final = records[-1].numbers
    if any(record.numbers["joinAvailable"] != 1 for record in records):
        raise IncompleteCalibration("ambiguous codec generation")
    totals = {
        key: sum(record.numbers[key] for record in records)
        for key in ("received", "queued", "output", "released", "rendered")
    }
    if not (
        totals["received"]
        >= totals["queued"]
        >= totals["output"]
        >= totals["released"]
        >= totals["rendered"]
    ):
        raise IncompleteCalibration("codec stage totals inconsistent")
    released, valid, right, interior = _validate_render_totals(final, totals)
    measured = released - right
    coverage = valid / measured if measured else None
    rates = {key: count / active for key, count in totals.items()}
    rates["validRendered"] = valid / active
    result.update(
        {
            "fps": rates,
            "rightCensored": right,
            "interiorPending": interior,
            "renderCoverage": coverage,
        }
    )
    result["renderStatus"] = _render_status(records, final, interior, coverage, config)


def _validate_render_totals(
    final: dict[str, int], totals: dict[str, int]
) -> tuple[int, int, int, int]:
    released, rendered, valid = (
        final[key] for key in ("releasedTotal", "renderedTotal", "validRenderedTotal")
    )
    right, interior = final["rightCensored"], final["interiorPending"]
    if (
        released != totals["released"]
        or rendered != totals["rendered"]
        or right + interior > released - rendered
        or valid > rendered
    ):
        raise IncompleteCalibration("cumulative release/render or tail inconsistent")
    return released, valid, right, interior


def _render_status(
    records: list[Record],
    final: dict[str, int],
    interior: int,
    coverage: float | None,
    config: RunnerConfig,
) -> str:
    issues = (
        "renderInvalid",
        "ambiguousGeneration",
        "ambiguousOutputGap",
        "ambiguousRenderGap",
        "expired",
        "invalidClock",
        "missingRender",
        "late",
        "duplicate",
        "overflow",
        "unmatched",
        "missingOutputSeq",
        "missingRenderSeq",
    )
    invalid = any(record.numbers[name] for record in records for name in issues)
    if final["renderInstalled"] != 1 or final["renderSeen"] != 1:
        return "unavailable"
    if (
        not invalid
        and interior == 0
        and coverage is not None
        and coverage >= config["minimumValidRenderCoverage"]
    ):
        return "valid"
    return "incomplete"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--host", required=True, type=Path, help="numeric-only host log"
    )
    parser.add_argument(
        "--client", required=True, type=Path, help="filtered numeric-only logcat"
    )
    parser.add_argument("--active-seconds", type=int, required=True)
    args = parser.parse_args()
    try:
        config = load_config()
        if args.active_seconds not in config["allowedActiveSeconds"]:
            raise IncompleteCalibration(
                "duration not approved by bounded configuration"
            )
        results = [
            aggregate(
                parse(path, source, int(config["maxLineBytes"])),
                source,
                args.active_seconds,
                config,
            )
            for path, source in ((args.host, "host"), (args.client, "client"))
        ]
        if results[0]["epoch"] != results[1]["epoch"]:
            raise IncompleteCalibration("host/client epoch mismatch")
    except (IncompleteCalibration, OSError, UnicodeError) as error:
        print(f"incomplete calibration: {error.__class__.__name__}: {error}")
        return 2
    print(
        json.dumps(
            {
                "sourceOnlyAnalysis": True,
                "acceptance": "not-assessed",
                "records": results,
            },
            sort_keys=True,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
