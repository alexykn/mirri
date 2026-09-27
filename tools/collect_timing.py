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

HOST_TIMING = re.compile(rb"^\d{4}-\d\d-\d\dT[^ ]+ metrics videoTiming ")
HOST_STATE = re.compile(rb"^\d{4}-\d\d-\d\dT[^ ]+ (state|error) ")
CLIENT_TIMING = re.compile(rb"\bI\s+MirriTiming:")


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
        self, config: RunnerConfig, begin: float, on_ready: Callable[[], None] | None
    ):
        self.config = config
        self.on_ready = on_ready
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
        self.empty_client = self.empty_client + 1 if row["received"] == 0 else 0
        if self.empty_client >= 3:
            raise IncompleteCalibration("client receive stalled")
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
        self.empty_host = self.empty_host + 1 if row["complete"] == 0 else 0
        if self.empty_host >= 3:
            raise IncompleteCalibration("host capture stalled")
        if row["final"] == 1:
            self.host_finished = True

    def check_host_identity(self, row: dict[str, int]) -> None:
        if row["epoch"] != self.host_epoch or row["record"] != self.host_records:
            raise IncompleteCalibration("host epoch or record changed")

    def start_host(self, row: dict[str, int], client_out: BinaryIO) -> None:
        if row["record"] != 0:
            raise IncompleteCalibration("missing first host record")
        self.host_epoch = row["epoch"]
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

    def read_host_inode(
        self,
        key: tuple[int, int],
        stream: BinaryIO,
        host_out: BinaryIO,
        client_out: BinaryIO,
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
            elif self.host_records and HOST_STATE.match(line):
                self.accept_state(line, host_out)

    def scan_host(
        self, host_log: Path, host_out: BinaryIO, client_out: BinaryIO
    ) -> None:
        seen: set[tuple[int, int]] = set()
        with host_snapshot(host_log) as files:
            for key, stream in files:
                seen.add(key)
                self.read_host_inode(key, stream, host_out, client_out)
            for key in tuple(self.offsets):
                if key not in seen:
                    if self.offsets[key][1]:
                        raise IncompleteCalibration("rotated partial host line")
                    del self.offsets[key]
            if len(self.offsets) > 3:
                raise IncompleteCalibration("host inode bound exceeded")

    def accept_client_line(self, line: bytes, out: BinaryIO) -> None:
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

    def scan_client(self, process: subprocess.Popen[bytes], out: BinaryIO) -> None:
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
            self.accept_client_block(block, out)
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

    def accept_client_block(self, block: bytes, out: BinaryIO) -> None:
        lines = (self.client_partial + block).split(b"\n")
        self.client_partial = lines.pop()
        if len(self.client_partial) > self.config["maxLineBytes"]:
            raise IncompleteCalibration("logcat record truncated")
        for line in lines:
            self.accept_client_line(line, out)

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
            raise IncompleteCalibration("host heartbeat missing")
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
            raise IncompleteCalibration("client heartbeat missing")


def collect(
    host_log: Path,
    output: Path,
    seconds: int,
    adb: str,
    *,
    on_ready: Callable[[], None] | None = None,
) -> int:
    config = load_config()
    if seconds not in config["allowedActiveSeconds"]:
        raise IncompleteCalibration("unconfigured duration")
    output.mkdir(mode=0o700, parents=False, exist_ok=False)
    host_path = output / "host-timing.log"
    client_path = output / "client-timing.log"
    # -d selects attached USB only; -T 1 may replay one old tag line.
    process = subprocess.Popen(
        [adb, "-d", "logcat", "-T", "1", "-v", "epoch", "-s", "MirriTiming:I", "*:S"],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        bufsize=0,
    )
    try:
        if process.stdout is None:
            raise IncompleteCalibration("logcat unavailable")
        os.set_blocking(process.stdout.fileno(), False)
        begin = time.monotonic()
        observation = Observation(config, begin, on_ready)
        deadline = begin + seconds + config["startupSeconds"] + 30
        observe_until_final(
            host_log,
            host_path,
            client_path,
            observation,
            process,
            deadline,
            begin + config["startupSeconds"],
        )
        report_results(host_path, client_path, seconds, config)
        return 0
    finally:
        process.terminate()
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=2)
        if process.stdout is not None:
            process.stdout.close()


def observe_until_final(
    host_log: Path,
    host_path: Path,
    client_path: Path,
    observation: Observation,
    process: subprocess.Popen[bytes],
    deadline: float,
    startup_deadline: float,
) -> None:
    with host_path.open("wb") as host_out, client_path.open("wb") as client_out:
        observation.seed_host(host_log)
        # Test-only readiness hook after initial log offsets are fixed.
        if observation.on_ready is not None:
            observation.on_ready()
        while time.monotonic() < deadline:
            observation.scan_host(host_log, host_out, client_out)
            observation.scan_client(process, client_out)
            if observation.host_finished and observation.client_finished:
                break
            observation.check_heartbeats(time.monotonic(), startup_deadline, process)
            time.sleep(0.1)
    if not (observation.host_finished and observation.client_finished):
        raise IncompleteCalibration("timeout before both final records")


def report_results(
    host_path: Path, client_path: Path, seconds: int, config: RunnerConfig
) -> None:
    results = [
        aggregate(parse(path, source, config["maxLineBytes"]), source, seconds, config)
        for path, source in ((host_path, "host"), (client_path, "client"))
    ]
    if results[0]["epoch"] != results[1]["epoch"]:
        raise IncompleteCalibration("host/client epoch mismatch")
    print(
        json.dumps(
            {
                "completeWindow": True,
                "rendererStatus": results[1]["renderStatus"],
                "acceptance": "not-assessed",
                "results": results,
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
    args = parser.parse_args()
    try:
        return collect(args.host_log, args.output_dir, args.active_seconds, args.adb)
    except (IncompleteCalibration, OSError, UnicodeError) as error:
        print(f"incomplete calibration: {error.__class__.__name__}: {error}")
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
