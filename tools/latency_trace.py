"""Optional numeric sampled-frame analysis alongside schema-v4 timing aggregation.

No device access. Causal clock-offset *intervals*, never symmetric RTT estimates.
Finite intervals assume relative monotonic oscillator drift <=100 ppm for <=15 s;
they are not unconditional hardware guarantees or physical presentation timing.
"""

from __future__ import annotations

import math
import re
from dataclasses import dataclass, field, replace
from itertools import pairwise
from pathlib import Path

from aggregate_timing import IncompleteCalibration

HOST = re.compile(r"^\d{4}-\d\d-\d\dT[^ ]+ metrics latencyTrace (.+)$")
CLIENT = re.compile(r"\bI\s+MirriLatencyTrace:\s+(.+)$")
TRACE = re.compile(r"[0-9a-f]{32}\Z")
FIELDS = re.compile(r"([A-Za-z][A-Za-z0-9]*)=([^ ]+)")
MAX_LINE = 3900
MAX_AGE_NS = 15_000_000_000
MAX_CALIBRATION_WIDTH_NS = 250_000_000
DRIFT_PPM = 100  # Explicit relative oscillator assumption, NOT measured hardware bound.


@dataclass(frozen=True)
class Frame:
    generation: int
    sequence: int
    pts_us: int
    stamps: tuple[int, ...]


@dataclass(frozen=True)
class Calibration:
    sequence: int
    t1: int
    t2: int
    t3: int
    t4: int

    def ordered(self) -> bool:
        return (
            self.t1 > 0
            and self.t2 > 0
            and self.t3 >= self.t2
            and self.t4 >= self.t1
            and self.t4 - self.t1 <= 5_000_000_000
        )

    def interval(
        self,
        host_ns: int,
        client_ns: int | None = None,
    ) -> tuple[int, int] | None:
        distance = max(
            abs(host_ns - self.t1),
            abs(host_ns - self.t4),
            abs(client_ns - self.t2) if client_ns is not None else 0,
            abs(client_ns - self.t3) if client_ns is not None else 0,
        )
        if not self.ordered() or distance > MAX_AGE_NS:
            return None
        lower, upper = self.t3 - self.t4, self.t2 - self.t1
        if lower > upper or upper - lower > MAX_CALIBRATION_WIDTH_NS:
            return None
        drift = math.ceil(distance * DRIFT_PPM / 1_000_000)
        return lower - drift, upper + drift


@dataclass(frozen=True)
class Record:
    side: str
    trace: str
    route: str
    epoch: int
    generation: int
    record: int
    start: int
    end: int
    final: bool
    selected: int
    missing: int
    dropped: int
    ambiguous: int
    censored: int
    frames: tuple[Frame, ...]
    clocks: tuple[Calibration, ...]


def _unsigned(raw: str) -> int:
    if not raw.isascii() or not raw.isdecimal():
        raise IncompleteCalibration("latency non-numeric field")
    return int(raw)


def _rows(raw: str, width: int) -> tuple[tuple[int, ...], ...]:
    if raw == "-":
        return ()
    entries = tuple(
        tuple(_unsigned(v) for v in row.split(",")) for row in raw.split(";")
    )
    if len(entries) > 10 or any(len(row) != width for row in entries):
        raise IncompleteCalibration("latency batch bound")
    return entries


def _validate_window(num: dict[str, int]) -> None:
    if (
        num["epoch"] == 0
        or num["generation"] == 0
        or num["startNs"] == 0
        or num["endNs"] < num["startNs"]
        or num["final"] > 1
    ):
        raise IncompleteCalibration("latency window")


def _decode_fields(text: str, side: str) -> tuple[dict[str, str], dict[str, int]]:
    fields = FIELDS.findall(text)
    values = dict(fields)
    required = {
        "v",
        "side",
        "trace",
        "route",
        "epoch",
        "generation",
        "record",
        "startNs",
        "endNs",
        "final",
        "selected",
        "missing",
        "dropped",
        "frames",
    }
    if side == "host":
        required |= {"rejectedClock", "clocks"}
    else:
        required |= {"ambiguous", "censored"}
    if len(values) != len(fields) or values.keys() != required:
        raise IncompleteCalibration("latency fields")
    if (
        values["v"] != "1"
        or values["side"] != side
        or values["route"] not in ("usb", "network")
        or not TRACE.fullmatch(values["trace"])
    ):
        raise IncompleteCalibration("latency identity")
    num = {
        key: _unsigned(values[key])
        for key in required - {"v", "side", "trace", "route", "frames", "clocks"}
    }
    _validate_window(num)
    return values, num


def _frames(raw: str, side: str, generation: int) -> tuple[Frame, ...]:
    samples = _rows(raw, 7 if side == "host" else 9)
    frames = tuple(
        Frame(
            generation if side == "host" else row[0],
            row[0] if side == "host" else row[1],
            row[1] if side == "host" else row[2],
            row[2:] if side == "host" else row[3:],
        )
        for row in samples
    )
    if any(frame.generation == 0 or frame.stamps[0] == 0 for frame in frames):
        raise IncompleteCalibration("latency frame identity")
    return frames


def parse_line(line: str, side: str) -> Record | None:
    if side not in ("host", "client"):
        raise ValueError("unknown trace side")
    match = (HOST if side == "host" else CLIENT).search(line.rstrip("\n"))
    if match is None:
        return None
    if len(line.encode("ascii")) > MAX_LINE:
        raise IncompleteCalibration("latency line length")
    values, num = _decode_fields(match.group(1), side)
    frames = _frames(values["frames"], side, num["generation"])
    clocks = (
        tuple(Calibration(*row) for row in _rows(values["clocks"], 5))
        if side == "host"
        else ()
    )
    return Record(
        side,
        values["trace"],
        values["route"],
        num["epoch"],
        num["generation"],
        num["record"],
        num["startNs"],
        num["endNs"],
        bool(num["final"]),
        num["selected"],
        num["missing"],
        num["dropped"],
        num.get("ambiguous", 0),
        num.get("censored", 0),
        frames,
        clocks,
    )


def _continuous(prior: Record, current: Record) -> bool:
    return (
        current.record == prior.record + 1
        and current.start == prior.end
        and not prior.final
    )


def parse_file(path: Path, side: str) -> list[Record]:
    records = [
        r
        for line in path.read_text(encoding="ascii").splitlines(keepends=True)
        if (r := parse_line(line, side))
    ]
    if not records or records[0].record != 0 or not records[-1].final:
        raise IncompleteCalibration("latency final or first record missing")
    if any(row.end - row.start > 2_500_000_000 for row in records):
        raise IncompleteCalibration(
            "latency heartbeat gap; sleep or unavailable interval"
        )
    if any(not _continuous(prior, current) for prior, current in pairwise(records)):
        raise IncompleteCalibration("latency records skipped or mixed")
    return records


def _percentiles(ranges: list[tuple[int, int]]) -> dict[str, object]:
    if not ranges:
        return {"count": 0, "p50Ms": None, "p95Ms": None, "p99Ms": None, "maxMs": None}
    lows, highs = (sorted(part[i] for part in ranges) for i in (0, 1))

    def bound(fraction: float) -> list[float]:
        index = math.ceil(len(ranges) * fraction) - 1
        return [round(lows[index] / 1e6, 3), round(highs[index] / 1e6, 3)]

    return {
        "count": len(ranges),
        "p50Ms": bound(0.5),
        "p95Ms": bound(0.95),
        "p99Ms": bound(0.99),
        "maxMs": [round(lows[-1] / 1e6, 3), round(highs[-1] / 1e6, 3)],
    }


def _stall_windows(
    samples: list[tuple[int, int, int, int]],
    threshold_ns: int,
) -> dict[str, dict[str, object]]:
    """Distinct *possible* and *confirmed* age tails, never an idle-SCK diagnosis."""
    result: dict[str, dict[str, object]] = {}
    for label, upper in (("confirmedAbove100Ms", False), ("possibleAbove100Ms", True)):
        selected = sorted(
            (callback, seq)
            for callback, seq, lo, hi in samples
            if (hi if upper else lo) > threshold_ns
        )
        windows: list[dict[str, int]] = []
        current: dict[str, int] | None = None
        count = 0
        for callback, seq in selected:
            if (
                current is not None
                and seq == current["lastSequence"] + 6
                and callback - current["endHostNs"] <= 250_000_000
            ):
                current["lastSequence"] = seq
                current["endHostNs"] = callback
                continue
            count += 1
            current = {
                "firstSequence": seq,
                "lastSequence": seq,
                "startHostNs": callback,
                "endHostNs": callback,
            }
            if len(windows) < 32:
                windows.append(current)
        result[label] = {
            "count": count,
            "sampleCount": len(selected),
            "windows": windows,
            "omittedWindows": count - len(windows),
        }
    return result


def _check_identity(host: list[Record], client: list[Record]) -> list[Calibration]:
    if any(
        (row.trace, row.epoch, row.route)
        != (host[0].trace, host[0].epoch, host[0].route)
        for row in host + client
    ):
        raise IncompleteCalibration("latency cross-session/epoch mix")
    clocks = [clock for record in host for clock in record.clocks]
    if len({clock.sequence for clock in clocks}) != len(clocks):
        raise IncompleteCalibration("latency replayed Pong")
    return clocks


def _index_frames(records: list[Record]) -> dict[tuple[int, int, int], Frame]:
    result: dict[tuple[int, int, int], Frame] = {}
    for record in records:
        for frame in record.frames:
            key = (frame.generation, frame.sequence, frame.pts_us)
            if frame.sequence % 6 or key in result:
                raise IncompleteCalibration("latency duplicate or unselected frame")
            result[key] = frame
    return result


def _valid_client_order(c: Frame) -> bool:
    packet, queued, output, release_request, release_return, rendered = c.stamps
    queued_at = queued or packet
    output_at = output or queued_at
    return all(
        (
            packet <= queued_at <= output_at,
            not release_request or release_request >= output_at,
            not release_return or release_request <= release_return,
            not rendered or (release_request > 0 and rendered >= release_request),
        )
    )


def _check_frame_order(h: Frame, c: Frame) -> None:
    callback, submit, encoded, prewrite, written = h.stamps
    if (
        not callback <= submit <= encoded <= prewrite <= written
        or not _valid_client_order(c)
    ):
        raise IncompleteCalibration("latency invalid frame clock order")


def _clock_range(
    clocks: list[Calibration],
    callback: int,
    client_stage: int,
) -> tuple[int, int] | None:
    # Select by time BEFORE validating intervals: never silently replace a
    # nearby inconsistent exchange with a convenient farther one.
    nearest = _nearest_clocks(clocks, callback)
    if not nearest:
        return None
    intervals = [clock.interval(callback, client_stage) for clock in nearest]
    if any(interval is None for interval in intervals):
        return None
    bounds = [interval for interval in intervals if interval is not None]
    lower, upper = max(v[0] for v in bounds), min(v[1] for v in bounds)
    return (lower, upper) if lower <= upper else None


def _nearest_clocks(clocks: list[Calibration], callback: int) -> list[Calibration]:
    candidates = [clock for clock in clocks if abs(clock.t4 - callback) <= MAX_AGE_NS]
    return sorted(candidates, key=lambda clock: abs(clock.t4 - callback))[:3]


@dataclass
class Measurements:
    ranges: dict[str, list[tuple[int, int]]] = field(
        default_factory=lambda: {stage: [] for stage in ("packet", "release", "render")}
    )
    render_windows: list[tuple[int, int, int, int]] = field(default_factory=list)
    clock_widths: list[int] = field(default_factory=list)
    unavailable: int = 0
    unavailable_stages: int = 0
    unwritten: int = 0
    matched: int = 0

    def max_clock_width_ms(self) -> float | None:
        if not self.clock_widths:
            return None
        return round(max(self.clock_widths) / 1e6, 3)

    def coverage(self, selected: int) -> float | None:
        return round(self.matched / selected, 4) if selected else None


def _measure(
    h: Frame, c: Frame, clocks: list[Calibration], summary: Measurements
) -> None:
    summary.matched += 1
    if h.stamps[-1] == 0:
        summary.unwritten += 1
        return
    _check_frame_order(h, c)
    callback = h.stamps[0]
    measured_stages = 0
    for stage, at_ns in zip(
        ("packet", "release", "render"),
        (c.stamps[0], c.stamps[4], c.stamps[5]),
        strict=True,
    ):
        if not at_ns:
            continue
        offset = _clock_range(clocks, callback, at_ns)
        if offset is None:
            summary.unavailable_stages += 1
            continue
        lower, upper = offset
        earliest, latest = at_ns - callback - upper, at_ns - callback - lower
        if latest < 0 or latest > MAX_AGE_NS:
            summary.unavailable_stages += 1
            continue
        measured_stages += 1
        summary.clock_widths.append(upper - lower)
        interval = (max(0, earliest), latest)
        summary.ranges[stage].append(interval)
        if stage == "render":
            summary.render_windows.append((callback, h.sequence, *interval))
    if not measured_stages:
        summary.unavailable += 1


def _report(
    host: list[Record],
    client: list[Record],
    host_frames: dict[tuple[int, int, int], Frame],
    client_frames: dict[tuple[int, int, int], Frame],
    measured: Measurements,
) -> dict[str, object]:
    selected_host = sum(row.selected for row in host)
    ages = {stage: _percentiles(values) for stage, values in measured.ranges.items()}
    return {
        "trace": host[0].trace,
        "epoch": host[0].epoch,
        "route": host[0].route,
        "hostActiveSeconds": (host[-1].end - host[0].start) / 1e9,
        "clientActiveSeconds": (client[-1].end - client[0].start) / 1e9,
        "hostStartNs": host[0].start,
        "hostEndNs": host[-1].end,
        "clientStartNs": client[0].start,
        "clientEndNs": client[-1].end,
        "selectedHost": selected_host,
        "selectedClient": sum(row.selected for row in client),
        "samplingInterval": 6,
        "hostMissing": sum(row.missing for row in host),
        "clientMissing": sum(row.missing for row in client),
        "hostDropped": sum(row.dropped for row in host),
        "clientDropped": sum(row.dropped for row in client),
        "ambiguous": sum(row.ambiguous for row in client),
        "censored": sum(row.censored for row in client),
        "matched": measured.matched,
        "unmatchedHost": len(host_frames) - measured.matched,
        "unmatchedClient": len(client_frames) - measured.matched,
        "sampledCoverage": measured.coverage(selected_host),
        "calibrationUnavailable": measured.unavailable,
        "unavailableStages": measured.unavailable_stages,
        "unwrittenHost": measured.unwritten,
        "maxClockWidthMs": measured.max_clock_width_ms(),
        "ages": ages,
        "renderAgeWindows": _stall_windows(measured.render_windows, 100_000_000),
        "interpretation": "capture callback to Android stage; render is a framework report, not physical scanout",
    }


def summarize(host: list[Record], client: list[Record]) -> dict[str, object]:
    clocks = _check_identity(host, client)
    host_frames = _index_frames(host)
    client_frames = _index_frames(client)
    measured = Measurements()
    for key, h in host_frames.items():
        if (c := client_frames.get(key)) is not None:
            _measure(h, c, clocks, measured)
    return _report(host, client, host_frames, client_frames, measured)


def aggregate_paths(host_path: Path, client_path: Path) -> dict[str, object]:
    return summarize(parse_file(host_path, "host"), parse_file(client_path, "client"))


def _segment_boundary(previous: Record, current: Record, breaks: set[int]) -> bool:
    return (
        not _continuous(previous, current)
        or (current.trace, current.epoch, current.route)
        != (previous.trace, previous.epoch, previous.route)
        or current.record in breaks
    )


def _diagnostic_segments(
    path: Path, side: str, breaks: set[int]
) -> tuple[list[list[Record]], list[str]]:
    segments: list[list[Record]] = []
    facts: list[str] = []
    current: list[Record] = []
    for line in path.read_text(encoding="ascii").splitlines(keepends=True):
        record = parse_line(line, side)
        if record is None:
            continue
        if record.end - record.start > 2_500_000_000:
            facts.append(f"{side} record {record.record}: heartbeat gap")
            if current:
                segments.append(current)
                current = []
            continue
        if current and _segment_boundary(current[-1], record, breaks):
            facts.append(f"{side} before record {record.record}: discontinuity")
            segments.append(current)
            current = []
        current.append(record)
    if current:
        segments.append(current)
    if _missing_edge(segments):
        facts.append(f"{side}: first or final trace record missing")
    return segments, facts


def _missing_edge(segments: list[list[Record]]) -> bool:
    return not segments or segments[0][0].record != 0 or not segments[-1][-1].final


def _local_records(
    host: list[Record], client: list[Record]
) -> tuple[list[Record], list[Record]]:
    h_begin, h_end = host[0].start, host[-1].end
    c_begin, c_end = client[0].start, client[-1].end
    local_host = [
        replace(
            row,
            frames=tuple(f for f in row.frames if h_begin <= f.stamps[0] <= h_end),
            clocks=tuple(
                clock
                for clock in row.clocks
                if h_begin <= clock.t1 <= clock.t4 <= h_end
                and c_begin <= clock.t2 <= clock.t3 <= c_end
            ),
        )
        for row in host
    ]
    local_client = [
        replace(
            row,
            frames=tuple(f for f in row.frames if c_begin <= f.stamps[0] <= c_end),
        )
        for row in client
    ]
    return local_host, local_client


def _diagnostic_pair(
    host: list[Record], client: list[Record]
) -> dict[str, object] | None:
    if (host[0].trace, host[0].epoch, host[0].route) != (
        client[0].trace,
        client[0].epoch,
        client[0].route,
    ):
        return None
    local_host, local_client = _local_records(host, client)
    if not any(row.frames for row in local_host) or not any(
        row.frames for row in local_client
    ):
        return None
    result = summarize(local_host, local_client)
    if not result["matched"]:
        return None
    keys = (
        "epoch",
        "route",
        "matched",
        "selectedHost",
        "selectedClient",
        "hostMissing",
        "clientMissing",
        "hostDropped",
        "clientDropped",
        "censored",
        "ambiguous",
        "unmatchedHost",
        "unmatchedClient",
        "sampledCoverage",
        "unavailableStages",
        "ages",
        "renderAgeWindows",
    )
    return {
        **{key: result[key] for key in keys},
        "hostRecords": [host[0].record, host[-1].record],
        "clientRecords": [client[0].record, client[-1].record],
    }


def diagnose_paths(
    host_path: Path,
    client_path: Path,
    host_breaks: set[int] | None = None,
    client_breaks: set[int] | None = None,
) -> dict[str, object]:
    """Partial diagnostics only. Segment local clocks; NEVER a full-window verdict."""
    hosts, host_facts = _diagnostic_segments(host_path, "host", host_breaks or set())
    clients, client_facts = _diagnostic_segments(
        client_path, "client", client_breaks or set()
    )
    # If only one logger observed a gap, split the opposite side at the same
    # record boundary too. A delayed frame spanning that boundary is retained
    # in raw files, but is not given a cross-gap clock calibration.
    shared_breaks = {segment[0].record for segment in hosts[1:] + clients[1:]}
    if shared_breaks:
        hosts, host_facts = _diagnostic_segments(
            host_path, "host", (host_breaks or set()) | shared_breaks
        )
        clients, client_facts = _diagnostic_segments(
            client_path, "client", (client_breaks or set()) | shared_breaks
        )
    excerpts = [
        excerpt
        for host in hosts
        for client in clients
        if (excerpt := _diagnostic_pair(host, client)) is not None
    ]
    return {
        "completeWindow": False,
        "calibration": "partial segments only; not an acceptance result",
        "gapFacts": host_facts + client_facts,
        "segments": excerpts,
    }


def require_matching_window(
    latency: dict[str, object],
    host_start: int,
    host_end: int,
    client_start: int,
    client_end: int,
) -> None:
    if (
        abs(int(str(latency["hostStartNs"])) - host_start) > 250_000_000
        or abs(int(str(latency["clientStartNs"])) - client_start) > 250_000_000
        or abs(int(str(latency["hostEndNs"])) - host_end) > 1_000_000_000
        or abs(int(str(latency["clientEndNs"])) - client_end) > 1_000_000_000
    ):
        raise IncompleteCalibration("latency/v4 active windows differ")
