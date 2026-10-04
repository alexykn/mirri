"""Bounded *read-only* Mirri numeric record collector, pending parent approval.

Does not launch/stop the host, install an APK, animate windows, alter ADB
reverse mappings, request permissions or clear logcat. A separately approved
owner-gated controller must operate those resources. Never print log contents.
"""

import argparse
import json
import os
import re
import subprocess
import time
from collections.abc import Callable, Iterator
from contextlib import ExitStack, contextmanager
from pathlib import Path
from typing import BinaryIO

from aggregate_timing import (
    IncompleteCalibration,
    Record,
    RunnerConfig,
    aggregate,
    load_config,
    parse,
    validate_timing_line,
)
from latency_trace import (
    Record as TraceRecord,
)
from latency_trace import (
    aggregate_paths,
    diagnose_paths,
    parse_line,
    require_matching_window,
)

HOST_TIMING = re.compile(rb"^\d{4}-\d\d-\d\dT[^ ]+ metrics videoTiming ")
HOST_STATE = re.compile(rb"^\d{4}-\d\d-\d\dT[^ ]+ (state|error) ")
CLIENT_TIMING = re.compile(rb"\bI\s+MirriTiming:")
HOST_LATENCY = re.compile(rb"^\d{4}-\d\d-\d\dT[^ ]+ metrics latencyTrace ")
CLIENT_LATENCY = re.compile(rb"\bI\s+MirriLatencyTrace:")


@contextmanager
def host_snapshot(host_log: Path) -> Iterator[list[tuple[tuple[int, int], BinaryIO]]]:
    """Open a bounded, ordered set of log inodes, not a mixture of rotations.

    SessionLogger removes .2, moves .1 to .2 and host.log to .1 before
    creating a new host.log. If that happens while opening the three paths,
    recheck their identities before consuming bytes or pruning offsets.
    Open descriptors keep the validated inodes readable across a later move.
    """
    paths = [
        host_log.with_name(host_log.stem + suffix)
        for suffix in (".2.log", ".1.log", ".log")
    ]
    for _ in range(3):
        with ExitStack() as stack:
            opened: list[tuple[tuple[int, int], BinaryIO]] = []
            identities: list[tuple[int, int] | None] = []
            for path in paths:
                try:
                    stream = stack.enter_context(path.open("rb"))
                except FileNotFoundError:
                    identities.append(None)
                    continue
                stat = os.fstat(stream.fileno())
                key = (stat.st_dev, stat.st_ino)
                opened.append((key, stream))
                identities.append(key)
            observed: list[tuple[int, int] | None] = []
            for path in paths:
                try:
                    stat = path.stat()
                    observed.append((stat.st_dev, stat.st_ino))
                except FileNotFoundError:
                    observed.append(None)
            if identities == observed and len({key for key, _ in opened}) == len(
                opened
            ):
                yield opened
                return
    raise IncompleteCalibration("host rotation did not stabilize")


class Observation:
    """Per-run state: inode cursors, ownership, and fail-closed heartbeat checks."""

    def __init__(
        self,
        config: RunnerConfig,
        begin: float,
        on_ready: Callable[[], None] | None,
        diagnostic: bool = False,
    ):
        self.config = config
        self.on_ready = on_ready
        self.diagnostic = diagnostic
        self.gap_facts: list[str] = []
        self.host_breaks: set[int] = set()
        self.client_breaks: set[int] = set()
        self.host_heartbeat_gap = False
        self.client_heartbeat_gap = False
        self.host_start_ns: int | None = None
        self.client_start_ns: int | None = None
        self.trace_id: str | None = None
        self.trace_route: str | None = None
        self.host_latency_records = 0
        self.client_latency_records = 0
        self.host_latency_final = False
        self.client_latency_final = False
        self.pending_latency: list[bytes] = []
        self.offsets: dict[tuple[int, int], tuple[int, bytes]] = {}
        self.client_partial = b""
        self.host_finished = False
        self.client_finished = False
        self.host_records = 0
        self.client_records = 0
        self.host_epoch: int | None = None
        self.host_started_at = begin
        self.client_owner: int | None = None
        self.pending_client: list[tuple[bytes, Record]] = []
        self.stale_schema_skipped = False
        self.last_host = begin
        self.last_client = begin
        self.empty_host = 0
        self.empty_client = 0

    def seed_host(self, host_log: Path) -> None:
        with host_snapshot(host_log) as files:
            for key, stream in files:
                self.offsets[key] = (os.fstat(stream.fileno()).st_size, b"")

    def accept_client(self, line: bytes, record: Record, out: BinaryIO) -> None:
        if self.host_epoch is None:
            raise IncompleteCalibration("client selected before host epoch")
        row = record.numbers
        if self.client_owner is None and not self.select_client(row):
            return
        self.check_client_identity(row)
        out.write(line + b"\n")
        if self.on_ready is not None:
            out.flush()  # Fake disconnect waits for an accepted client record.
        self.client_records += 1
        if self.client_records > self.config["maxRecords"]:
            raise IncompleteCalibration("client record bound exceeded")
        self.last_client = time.monotonic()
        if row["record"] == 0:
            self.client_start_ns = row["startNs"]
        if self.client_heartbeat_gap:
            self.client_breaks.add(row["record"])
            self.client_heartbeat_gap = False
        self.empty_client = self.record_empty(
            "client",
            row["record"],
            row["received"],
            self.empty_client,
            self.client_breaks,
        )
        if row["final"] == 1:
            self.client_finished = True

    def check_client_identity(self, row: dict[str, int]) -> None:
        if (
            row["v"] != self.config["schema"]
            or row["epoch"] != self.host_epoch
            or row["owner"] != self.client_owner
        ):
            raise IncompleteCalibration("client owner/epoch changed")
        if row["record"] != self.client_records:
            raise IncompleteCalibration("client record skipped or duplicated")

    def select_client(self, row: dict[str, int]) -> bool:
        if row["v"] != self.config["schema"]:
            if self.stale_schema_skipped:
                raise IncompleteCalibration("client production schema changed")
            self.stale_schema_skipped = True  # One historical -T 1 record.
            return False
        if row["epoch"] != self.host_epoch or row["record"] != 0:
            return False  # A historical tag line may precede record zero.
        self.client_owner = row["owner"]
        return True

    def accept_host(
        self, line: bytes, host_out: BinaryIO, client_out: BinaryIO
    ) -> None:
        if len(line) > self.config["maxLineBytes"]:
            raise IncompleteCalibration("host timing record too long")
        decoded = validate_timing_line((line + b"\n").decode("ascii"), "host")
        row = decoded.numbers
        if row["v"] != self.config["schema"]:
            raise IncompleteCalibration("host production schema changed")
        if self.host_epoch is None:
            self.start_host(row, client_out)
        self.check_host_identity(row)
        host_out.write(line + b"\n")
        if self.on_ready is not None:
            host_out.flush()  # Expose readiness to the fake producer.
        self.host_records += 1
        if self.host_records > self.config["maxRecords"]:
            raise IncompleteCalibration("host record bound exceeded")
        self.last_host = time.monotonic()
        if self.host_heartbeat_gap:
            self.host_breaks.add(row["record"])
            self.host_heartbeat_gap = False
        self.empty_host = self.record_empty(
            "host",
            row["record"],
            row["complete"],
            self.empty_host,
            self.host_breaks,
        )
        if row["final"] == 1:
            self.host_finished = True

    def check_host_identity(self, row: dict[str, int]) -> None:
        if row["epoch"] != self.host_epoch or row["record"] != self.host_records:
            raise IncompleteCalibration("host epoch or record changed")

    def record_empty(
        self, side: str, record: int, count: int, prior: int, breaks: set[int]
    ) -> int:
        consecutive = prior + 1 if count == 0 else 0
        if consecutive == 3:
            breaks.add(record - 2)
            self.gap_facts.append(
                f"{side} {'complete' if side == 'host' else 'receive'} zero from record {record - 2}"
            )
        if consecutive >= 3 and not self.diagnostic:
            raise IncompleteCalibration(
                "host capture stalled" if side == "host" else "client receive stalled"
            )
        if prior >= 3 and consecutive == 0:
            breaks.add(record)
        return consecutive

    def start_host(self, row: dict[str, int], client_out: BinaryIO) -> None:
        if row["record"] != 0:
            raise IncompleteCalibration("missing first host record")
        self.host_epoch = row["epoch"]
        self.host_start_ns = row["startNs"]
        self.host_started_at = time.monotonic()
        for old_line, old_record in self.pending_client:
            self.accept_client(old_line, old_record, client_out)
        self.pending_client.clear()

    def accept_state(self, line: bytes, host_out: BinaryIO) -> None:
        # Persist only normalized state words, never unfiltered host text.
        if b" error " in line:
            raise IncompleteCalibration("host failure during observation")
        fields = line.split(b" ")
        if len(fields) < 3 or fields[1] != b"state":
            return
        name = (
            fields[2]
            if fields[2]
            in (
                b"streaming",
                b"stopping",
                b"idle",
                b"failed",
                b"waitingForReconnect",
                b"waitingForClient",
            )
            else b"unknown"
        )
        if name not in (b"streaming", b"stopping", b"idle") or (
            name == b"idle" and not self.host_finished
        ):
            raise IncompleteCalibration("host left active stream")
        host_out.write(b"2026-01-01T00:00:00Z state " + name + b"\n")

    def accept_host_latency(self, line: bytes, out: BinaryIO) -> None:
        if len(line) > self.config["maxLineBytes"]:
            raise IncompleteCalibration("invalid host latency record")
        record = parse_line(line.decode("ascii"), "host")
        if record is None:
            raise IncompleteCalibration("invalid host latency record")
        if self.trace_id is None:
            if not self.select_host_trace(record):
                return  # An old pre-selection line is never part of this run.
        elif not self.trace_matches(record):
            raise IncompleteCalibration("host latency identity changed")
        if record.record != self.host_latency_records:
            raise IncompleteCalibration("host latency record skipped")
        out.write(line + b"\n")
        self.host_latency_records += 1
        self.host_latency_final = record.final

    def select_host_trace(self, record: TraceRecord) -> bool:
        if self.host_start_ns is None or (record.epoch, record.record) != (
            self.host_epoch,
            0,
        ):
            return False
        if abs(record.start - self.host_start_ns) > 250_000_000:
            return False
        self.trace_id, self.trace_route = record.trace, record.route
        return True

    def trace_matches(self, record: TraceRecord) -> bool:
        return (record.epoch, record.trace, record.route) == (
            self.host_epoch,
            self.trace_id,
            self.trace_route,
        )

    def accept_client_latency(self, line: bytes, out: BinaryIO) -> None:
        if len(line) > self.config["maxLineBytes"]:
            raise IncompleteCalibration("invalid client latency record")
        record = parse_line(line.decode("ascii"), "client")
        if record is None:
            raise IncompleteCalibration("invalid client latency record")
        if self.trace_id is None or self.client_start_ns is None:
            self.buffer_latency(line)
            return
        if not self.trace_matches(record):
            if self.client_latency_records == 0:
                return  # Old -T 1 replay; must match the chosen host trace.
            raise IncompleteCalibration("client latency identity changed")
        if self.client_latency_records == 0 and not self.client_trace_starts_here(
            record
        ):
            return
        if record.record != self.client_latency_records:
            raise IncompleteCalibration("client latency record skipped")
        out.write(line + b"\n")
        self.client_latency_records += 1
        self.client_latency_final = record.final

    def client_trace_starts_here(self, record: TraceRecord) -> bool:
        return (
            record.record == 0
            and self.client_start_ns is not None
            and abs(record.start - self.client_start_ns) <= 250_000_000
        )

    def buffer_latency(self, line: bytes) -> None:
        if len(self.pending_latency) >= 16:
            raise IncompleteCalibration("client latency startup buffer bound exceeded")
        self.pending_latency.append(line)

    def flush_pending_latency(self, out: BinaryIO) -> None:
        if self.trace_id is not None and self.client_start_ns is not None:
            for line in self.pending_latency:
                self.accept_client_latency(line, out)
            self.pending_latency.clear()

    def read_host_inode(
        self,
        key: tuple[int, int],
        stream: BinaryIO,
        host_out: BinaryIO,
        client_out: BinaryIO,
        latency_out: BinaryIO | None = None,
    ) -> None:
        stat = os.fstat(stream.fileno())
        offset, partial = self.offsets.get(key, (0, b""))
        if stat.st_size < offset:
            raise IncompleteCalibration("host log truncated")
        stream.seek(offset)
        data = stream.read(512 * 1024)
        if stat.st_size - offset > len(data):
            raise IncompleteCalibration("host log overrun")
        lines = (partial + data).split(b"\n")
        self.offsets[key] = (offset + len(data), lines.pop())
        if len(self.offsets[key][1]) > self.config["maxLineBytes"]:
            raise IncompleteCalibration("partial host line exceeds bound")
        for line in lines:
            if HOST_TIMING.match(line):
                self.accept_host(line, host_out, client_out)
            elif latency_out is not None and HOST_LATENCY.match(line):
                self.accept_host_latency(line, latency_out)
            elif self.host_records and HOST_STATE.match(line):
                self.accept_state(line, host_out)

    def scan_host(
        self,
        host_log: Path,
        host_out: BinaryIO,
        client_out: BinaryIO,
        latency_out: BinaryIO | None = None,
    ) -> None:
        seen: set[tuple[int, int]] = set()
        with host_snapshot(host_log) as files:
            for key, stream in files:
                seen.add(key)
                self.read_host_inode(key, stream, host_out, client_out, latency_out)
            for key in tuple(self.offsets):
                if key not in seen:
                    if self.offsets[key][1]:
                        raise IncompleteCalibration("rotated partial host line")
                    del self.offsets[key]
            if len(self.offsets) > 3:
                raise IncompleteCalibration("host inode bound exceeded")

    def accept_client_line(
        self, line: bytes, out: BinaryIO, latency_out: BinaryIO | None = None
    ) -> None:
        if latency_out is not None and CLIENT_LATENCY.search(line):
            self.accept_client_latency(line, latency_out)
            return
        if not CLIENT_TIMING.search(line):
            return
        if len(line) > self.config["maxLineBytes"]:
            raise IncompleteCalibration("client timing record too long")
        record = validate_timing_line((line + b"\n").decode("ascii"), "client")
        if self.host_epoch is None:
            self.pending_client.append((line, record))
            if len(self.pending_client) > 16:
                raise IncompleteCalibration("client startup buffer bound exceeded")
        else:
            self.accept_client(line, record, out)
            if latency_out is not None:
                self.flush_pending_latency(latency_out)

    def scan_client(
        self,
        process: subprocess.Popen[bytes],
        out: BinaryIO,
        latency_out: BinaryIO | None = None,
    ) -> None:
        if process.stdout is None:
            raise IncompleteCalibration("logcat unavailable")
        blocks = 0
        while blocks < 100:
            try:
                block = os.read(process.stdout.fileno(), 64 * 1024)
            except BlockingIOError:
                break
            if not block:
                self.check_logcat_exit(process)
                break
            blocks += 1
            self.accept_client_block(block, out, latency_out)
        if blocks == 100:
            raise IncompleteCalibration("logcat output flood")

    def check_logcat_exit(self, process: subprocess.Popen[bytes]) -> None:
        if process.poll() is not None and not self.client_finished:
            reason = (
                "client record zero missing"
                if self.host_records and self.client_owner is None
                else "logcat exited"
            )
            raise IncompleteCalibration(reason)

    def accept_client_block(
        self, block: bytes, out: BinaryIO, latency_out: BinaryIO | None = None
    ) -> None:
        lines = (self.client_partial + block).split(b"\n")
        self.client_partial = lines.pop()
        if len(self.client_partial) > self.config["maxLineBytes"]:
            raise IncompleteCalibration("logcat record truncated")
        for line in lines:
            self.accept_client_line(line, out, latency_out)

    def check_heartbeats(
        self, now: float, startup_deadline: float, process: subprocess.Popen[bytes]
    ) -> None:
        if not self.host_records and now > startup_deadline:
            raise IncompleteCalibration("host start timeout")
        if (
            self.host_records
            and not self.host_finished
            and now - self.last_host > self.config["maxIntervalSeconds"] + 0.5
        ):
            if not self.diagnostic:
                raise IncompleteCalibration("host heartbeat missing")
            if not self.host_heartbeat_gap:
                self.host_heartbeat_gap = True
                self.gap_facts.append(
                    f"host heartbeat after record {self.host_records - 1}"
                )
        self.check_client_heartbeat(now, process)

    def check_client_heartbeat(
        self, now: float, process: subprocess.Popen[bytes]
    ) -> None:
        if (
            self.host_records
            and self.client_owner is None
            and now - self.host_started_at > 10
        ):
            raise IncompleteCalibration("client record zero missing")
        if (
            self.host_finished
            and self.client_owner is None
            and process.poll() is not None
        ):
            raise IncompleteCalibration("client record zero missing")
        if (
            self.client_owner is not None
            and not self.client_finished
            and now - self.last_client > self.config["maxIntervalSeconds"] + 0.5
        ):
            self.note_client_heartbeat()

    def note_client_heartbeat(self) -> None:
        if not self.diagnostic:
            raise IncompleteCalibration("client heartbeat missing")
        if not self.client_heartbeat_gap:
            self.client_heartbeat_gap = True
            self.gap_facts.append(
                f"client heartbeat after record {self.client_records - 1}"
            )


def collect(
    host_log: Path,
    output: Path,
    seconds: int,
    adb: str,
    *,
    on_ready: Callable[[], None] | None = None,
    latency: bool = False,
    expected_route: str | None = None,
) -> int:
    config = load_config()
    if latency and expected_route not in ("usb", "network"):
        raise IncompleteCalibration("expected route required for latency baseline")
    if seconds not in config["allowedActiveSeconds"]:
        raise IncompleteCalibration("unconfigured duration")
    output.mkdir(mode=0o700, parents=False, exist_ok=False)
    host_path = output / "host-timing.log"
    client_path = output / "client-timing.log"
    # -d selects attached USB only; -T 1 may replay one old tag line.
    process = subprocess.Popen(
        [
            adb,
            "-d",
            "logcat",
            "-T",
            "1",
            "-v",
            "epoch",
            "-s",
            "MirriTiming:I",
            *(["MirriLatencyTrace:I"] if latency else []),
            "*:S",
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        bufsize=0,
    )
    try:
        if process.stdout is None:
            raise IncompleteCalibration("logcat unavailable")
        os.set_blocking(process.stdout.fileno(), False)
        begin = time.monotonic()
        observation = Observation(config, begin, on_ready, diagnostic=latency)
        deadline = begin + seconds + config["startupSeconds"] + 30
        return collect_results(
            host_log,
            host_path,
            client_path,
            output,
            seconds,
            config,
            observation,
            process,
            deadline,
            begin + config["startupSeconds"],
            latency,
            expected_route,
        )
    finally:
        process.terminate()
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=2)
        if process.stdout is not None:
            process.stdout.close()


def collect_results(
    host_log: Path,
    host_path: Path,
    client_path: Path,
    output: Path,
    seconds: int,
    config: RunnerConfig,
    observation: Observation,
    process: subprocess.Popen[bytes],
    deadline: float,
    startup_deadline: float,
    latency: bool,
    expected_route: str | None,
) -> int:
    try:
        observe_until_final(
            host_log,
            host_path,
            client_path,
            observation,
            process,
            deadline,
            startup_deadline,
            latency,
        )
        if latency and observation.gap_facts:
            raise IncompleteCalibration(
                "diagnostic gaps or freezes prevent full-window acceptance"
            )
        report_results(
            host_path,
            client_path,
            seconds,
            config,
            output if latency else None,
            expected_route,
        )
    except (IncompleteCalibration, OSError, UnicodeError) as error:
        if not latency:
            raise
        report_diagnostic(
            host_path, client_path, output, observation, str(error), config
        )
        return 2
    return 0


def _open_record_files(
    stack: ExitStack,
    host_path: Path,
    client_path: Path,
    latency: bool,
) -> tuple[BinaryIO, BinaryIO, BinaryIO | None, BinaryIO | None]:
    host_out = stack.enter_context(host_path.open("wb"))
    client_out = stack.enter_context(client_path.open("wb"))
    host_latency = (
        stack.enter_context((host_path.parent / "host-latency.log").open("wb"))
        if latency
        else None
    )
    client_latency = (
        stack.enter_context((client_path.parent / "client-latency.log").open("wb"))
        if latency
        else None
    )
    return host_out, client_out, host_latency, client_latency


def _all_final(observation: Observation, latency: bool) -> bool:
    return (
        observation.host_finished
        and observation.client_finished
        and (
            not latency
            or (observation.host_latency_final and observation.client_latency_final)
        )
    )


def observe_until_final(
    host_log: Path,
    host_path: Path,
    client_path: Path,
    observation: Observation,
    process: subprocess.Popen[bytes],
    deadline: float,
    startup_deadline: float,
    latency: bool = False,
) -> None:
    with ExitStack() as stack:
        host_out, client_out, host_latency, client_latency = _open_record_files(
            stack,
            host_path,
            client_path,
            latency,
        )
        observation.seed_host(host_log)
        # Test-only readiness hook after initial log offsets are fixed.
        if observation.on_ready is not None:
            observation.on_ready()
        while time.monotonic() < deadline:
            observation.scan_host(host_log, host_out, client_out, host_latency)
            observation.scan_client(process, client_out, client_latency)
            if client_latency is not None:
                observation.flush_pending_latency(client_latency)
            if _all_final(observation, latency):
                break
            observation.check_heartbeats(time.monotonic(), startup_deadline, process)
            time.sleep(0.1)
    if not (observation.host_finished and observation.client_finished):
        raise IncompleteCalibration("timeout before both v4 final records")
    if latency and not (
        observation.host_latency_final and observation.client_latency_final
    ):
        raise IncompleteCalibration("timeout before both latency final records")


def _zero_runs(rows: list[Record], field: str) -> dict[str, object]:
    runs: list[dict[str, int | bool]] = []
    current: dict[str, int | bool] | None = None
    for item in rows:
        row = item.numbers
        if row[field] == 0:
            if current is None:
                current = {
                    "firstRecord": row["record"],
                    "intervals": 0,
                    "startNs": row["startNs"],
                }
            current["intervals"] = int(current["intervals"]) + 1
            current["lastRecord"] = row["record"]
            current["endNs"] = row["endNs"]
        elif current is not None:
            current["recovered"] = True
            runs.append(current)
            current = None
    if current is not None:
        current["recovered"] = False
        runs.append(current)
    return {
        "count": len(runs),
        "windows": runs[:32],
        "omittedWindows": max(0, len(runs) - 32),
    }


def report_diagnostic(
    host_path: Path,
    client_path: Path,
    output: Path,
    observation: Observation,
    reason: str,
    config: RunnerConfig,
) -> None:
    v4: dict[str, object] = {}
    for side, path, fields in (
        ("host", host_path, ("complete", "written")),
        (
            "client",
            client_path,
            ("received", "output", "released", "missingRender", "overflow", "expired"),
        ),
    ):
        try:
            rows = parse(path, side, config["maxLineBytes"])
            v4[side] = {
                "records": len(rows),
                "epochs": sorted({row.numbers["epoch"] for row in rows}),
                "final": bool(rows[-1].numbers["final"]),
                "counts": {
                    field: sum(row.numbers[field] for row in rows) for field in fields
                },
                "zeroActivity": _zero_runs(
                    rows, "complete" if side == "host" else "received"
                ),
                **(
                    {
                        "renderCoverageSnapshot": {
                            key: rows[-1].numbers[key]
                            for key in (
                                "validRenderedTotal",
                                "rightCensored",
                                "interiorPending",
                            )
                        }
                    }
                    if side == "client"
                    else {}
                ),
            }
        except (IncompleteCalibration, OSError, UnicodeError) as error:
            v4[side] = {"unavailable": str(error)}
    try:
        diagnostic = diagnose_paths(
            output / "host-latency.log",
            output / "client-latency.log",
            observation.host_breaks,
            observation.client_breaks,
        )
    except (IncompleteCalibration, OSError, UnicodeError) as error:
        diagnostic = {"unavailable": str(error)}
    print(
        json.dumps(
            {
                "completeWindow": False,
                "acceptance": "incomplete",
                "incompleteReason": reason,
                "gapFacts": observation.gap_facts,
                "v4Partial": v4,
                "latencyDiagnostic": diagnostic,
            },
            sort_keys=True,
        )
    )


def report_results(
    host_path: Path,
    client_path: Path,
    seconds: int,
    config: RunnerConfig,
    latency_dir: Path | None = None,
    expected_route: str | None = None,
) -> None:
    results = [
        aggregate(parse(path, source, config["maxLineBytes"]), source, seconds, config)
        for path, source in ((host_path, "host"), (client_path, "client"))
    ]
    if results[0]["epoch"] != results[1]["epoch"]:
        raise IncompleteCalibration("host/client epoch mismatch")
    latency_summary = (
        aggregate_paths(
            latency_dir / "host-latency.log", latency_dir / "client-latency.log"
        )
        if latency_dir is not None
        else None
    )
    if latency_summary is not None:
        if latency_summary["route"] != expected_route:
            raise IncompleteCalibration("requested route differs from traced route")
        if latency_summary["epoch"] != results[0]["epoch"]:
            raise IncompleteCalibration("latency/v4 epoch differs")
    if latency_summary is not None:
        require_matching_window(
            latency_summary,
            int(str(results[0]["startNs"])),
            int(str(results[0]["endNs"])),
            int(str(results[1]["startNs"])),
            int(str(results[1]["endNs"])),
        )
    print(
        json.dumps(
            {
                "completeWindow": True,
                "rendererStatus": results[1]["renderStatus"],
                "acceptance": "not-assessed",
                "results": results,
                **({"latency": latency_summary} if latency_summary is not None else {}),
            },
            sort_keys=True,
        )
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--active-seconds", type=int, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument(
        "--host-log",
        type=Path,
        default=Path.home() / "Library/Application Support/Mirri/Logs/host.log",
    )
    parser.add_argument("--adb", default="/opt/homebrew/bin/adb")
    parser.add_argument(
        "--latency",
        action="store_true",
        help="capture optional numeric sampled latency records",
    )
    parser.add_argument("--expected-route", choices=("usb", "network"))
    args = parser.parse_args()
    try:
        return collect(
            args.host_log,
            args.output_dir,
            args.active_seconds,
            args.adb,
            latency=args.latency,
            expected_route=args.expected_route,
        )
    except (IncompleteCalibration, OSError, UnicodeError) as error:
        print(f"incomplete calibration: {error.__class__.__name__}: {error}")
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
