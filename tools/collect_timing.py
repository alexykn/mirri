"""Bounded *read-only* Mirri numeric record collector, pending parent approval.

Does not launch/stop the host, install an APK, animate windows, alter ADB
reverse mappings, request permissions or clear logcat. A separately approved
owner-gated controller must operate those resources. Never print log contents.
"""

import argparse
from contextlib import ExitStack, contextmanager
import json
import os
from pathlib import Path
import re
import subprocess
import time
from typing import BinaryIO, Callable, Iterator

from aggregate_timing import IncompleteCalibration, Record, aggregate, load_config, parse, validate_timing_line

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
    paths = [host_log.with_name(host_log.stem + suffix)
             for suffix in (".2.log", ".1.log", ".log")]
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
            if identities == observed and len({key for key, _ in opened}) == len(opened):
                yield opened
                return
    raise IncompleteCalibration("host rotation did not stabilize")


def collect(host_log: Path, output: Path, seconds: int, adb: str,
            *, on_ready: Callable[[], None] | None = None) -> int:
    config = load_config()
    if seconds not in config["allowedActiveSeconds"]:
        raise IncompleteCalibration("unconfigured duration")
    output.mkdir(mode=0o700, parents=False, exist_ok=False)
    host_path = output / "host-timing.log"
    client_path = output / "client-timing.log"
    # -d selects an attached USB device and refuses multiple USB devices;
    # network transports cannot be selected. No serial, -c, or package action.
    # -T 1 may replay one old tag line, handled by bounded epoch/record sync.
    process = subprocess.Popen(
        [adb, "-d", "logcat", "-T", "1", "-v", "epoch", "-s", "MirriTiming:I", "*:S"],
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, bufsize=0,
    )
    if process.stdout is None:
        raise IncompleteCalibration("logcat unavailable")
    os.set_blocking(process.stdout.fileno(), False)
    begin = time.monotonic()
    deadline = begin + seconds + config["startupSeconds"] + 30
    startup_deadline = begin + config["startupSeconds"]
    offsets: dict[tuple[int, int], tuple[int, bytes]] = {}
    client_partial = b""
    host_finished = False
    client_finished = False
    host_started = False
    host_records = 0
    client_records = 0
    host_epoch: int | None = None
    host_started_at = begin
    client_owner: int | None = None
    pending_client: list[tuple[bytes, Record]] = []
    stale_schema_skipped = False
    last_host = begin
    last_client = begin
    empty_host = 0
    empty_client = 0

    def accept_client(line: bytes, record: Record, out: BinaryIO) -> bool:
        nonlocal client_owner, client_records, client_finished, last_client, empty_client, stale_schema_skipped
        if host_epoch is None:
            raise IncompleteCalibration("client selected before host epoch")
        row = record.numbers
        if client_owner is None:
            if row["v"] != config["schema"]:
                if stale_schema_skipped:
                    raise IncompleteCalibration("client production schema changed")
                stale_schema_skipped = True  # One historical -T 1 record from the prior installed version.
                return False
            if row["epoch"] != host_epoch or row["record"] != 0:
                return False  # at most one historical tag line may precede record zero
            client_owner = row["owner"]
        elif row["v"] != config["schema"] or row["epoch"] != host_epoch or row["owner"] != client_owner:
            raise IncompleteCalibration("client owner/epoch changed")
        if row["record"] != client_records:
            raise IncompleteCalibration("client record skipped or duplicated")
        out.write(line + b"\n")
        if on_ready is not None:
            out.flush()  # Fake disconnect waits for an accepted client record.
        client_records += 1
        if client_records > config["maxRecords"]:
            raise IncompleteCalibration("client record bound exceeded")
        last_client = time.monotonic()
        empty_client = empty_client + 1 if row["received"] == 0 else 0
        if empty_client >= 3:
            raise IncompleteCalibration("client receive stalled")
        if row["final"] == 1:
            client_finished = True
        return True
    try:
        with host_path.open("wb") as host_out, client_path.open("wb") as client_out:
            with host_snapshot(host_log) as files:
                for key, stream in files:
                    stat = os.fstat(stream.fileno())
                    offsets[(stat.st_dev, stat.st_ino)] = (stat.st_size, b"")
            # Test-only readiness hook after the initial log offsets are fixed.
            # Production never supplies a hook or alters observation timing.
            if on_ready is not None:
                on_ready()
            while time.monotonic() < deadline:
                seen: set[tuple[int, int]] = set()
                with host_snapshot(host_log) as files:
                    for key, stream in files:
                        stat = os.fstat(stream.fileno())
                        seen.add(key)
                        offset, partial = offsets.get(key, (0, b""))
                        if stat.st_size < offset:
                            raise IncompleteCalibration("host log truncated")
                        stream.seek(offset)
                        data = stream.read(512 * 1024)
                        if stat.st_size - offset > len(data):
                            raise IncompleteCalibration("host log overrun")
                        offsets[key] = (offset + len(data), b"")
                        lines = (partial + data).split(b"\n")
                        offsets[key] = (offset + len(data), lines.pop())
                        if len(offsets[key][1]) > config["maxLineBytes"]:
                            raise IncompleteCalibration("partial host line exceeds bound")
                        for line in lines:
                            if HOST_TIMING.match(line):
                                if len(line) > config["maxLineBytes"]:
                                    raise IncompleteCalibration("host timing record too long")
                                decoded = validate_timing_line((line + b"\n").decode("ascii"), "host")
                                if decoded.numbers["v"] != config["schema"]:
                                    raise IncompleteCalibration("host production schema changed")
                                if host_epoch is None:
                                    if decoded.numbers["record"] != 0:
                                        raise IncompleteCalibration("missing first host record")
                                    host_epoch = decoded.numbers["epoch"]
                                    host_started_at = time.monotonic()
                                    for old_line, old_record in pending_client:
                                        accept_client(old_line, old_record, client_out)
                                    pending_client.clear()
                                elif decoded.numbers["epoch"] != host_epoch or decoded.numbers["record"] != host_records:
                                    raise IncompleteCalibration("host epoch or record changed")
                                host_started = True
                                host_out.write(line + b"\n")
                                if on_ready is not None:
                                    host_out.flush()  # Expose host-record readiness to the fake producer.
                                host_records += 1
                                if host_records > config["maxRecords"]:
                                    raise IncompleteCalibration("host record bound exceeded")
                                last_host = time.monotonic()
                                empty_host = empty_host + 1 if decoded.numbers["complete"] == 0 else 0
                                if empty_host >= 3:
                                    raise IncompleteCalibration("host capture stalled")
                                if decoded.numbers["final"] == 1:
                                    host_finished = True
                            elif host_started and HOST_STATE.match(line):
                                # State/error text can be nonnumeric; only a fixed
                                # state word or an error sentinel enters the file.
                                fields = line.split(b" ")
                                if b" error " in line:
                                    raise IncompleteCalibration("host failure during observation")
                                elif len(fields) >= 3 and fields[1] == b"state":
                                    name = fields[2] if fields[2] in (
                                        b"streaming", b"stopping", b"idle", b"failed",
                                        b"waitingForReconnect", b"waitingForClient",
                                    ) else b"unknown"
                                    if name not in (b"streaming", b"stopping", b"idle") or (name == b"idle" and not host_finished):
                                        raise IncompleteCalibration("host left active stream")
                                    host_out.write(b"2026-01-01T00:00:00Z state " + name + b"\n")
                    for key in tuple(offsets):
                        if key not in seen:
                            if offsets[key][1]:
                                raise IncompleteCalibration("rotated partial host line")
                            del offsets[key]
                    if len(offsets) > 3:
                        raise IncompleteCalibration("host inode bound exceeded")
                blocks = 0
                while blocks < 100:
                    try:
                        block = os.read(process.stdout.fileno(), 64 * 1024)
                    except BlockingIOError:
                        break
                    if not block:
                        if process.poll() is not None and not client_finished:
                            raise IncompleteCalibration(
                                "client record zero missing" if host_started and client_owner is None else "logcat exited"
                            )
                        break
                    blocks += 1
                    lines = (client_partial + block).split(b"\n")
                    client_partial = lines.pop()
                    if len(client_partial) > int(config["maxLineBytes"]):
                        raise IncompleteCalibration("logcat record truncated")
                    for line in lines:
                        if CLIENT_TIMING.search(line):
                            if len(line) > config["maxLineBytes"]:
                                raise IncompleteCalibration("client timing record too long")
                            record = validate_timing_line((line + b"\n").decode("ascii"), "client")
                            if host_epoch is None:
                                pending_client.append((line, record))
                                if len(pending_client) > 16:
                                    raise IncompleteCalibration("client startup buffer bound exceeded")
                            else:
                                accept_client(line, record, client_out)
                if blocks == 100:
                    raise IncompleteCalibration("logcat output flood")
                if host_finished and client_finished:
                    break
                now = time.monotonic()
                if not host_started and now > startup_deadline:
                    raise IncompleteCalibration("host start timeout")
                if host_started and not host_finished and now - last_host > config["maxIntervalSeconds"] + 0.5:
                    raise IncompleteCalibration("host heartbeat missing")
                if host_started and client_owner is None and now - host_started_at > 10:
                    raise IncompleteCalibration("client record zero missing")
                if host_finished and client_owner is None and process.poll() is not None:
                    raise IncompleteCalibration("client record zero missing")
                if client_owner is not None and not client_finished and now - last_client > config["maxIntervalSeconds"] + 0.5:
                    raise IncompleteCalibration("client heartbeat missing")
                time.sleep(0.1)
        if not (host_finished and client_finished):
            raise IncompleteCalibration("timeout before both final records")
        results = [aggregate(parse(path, source, int(config["maxLineBytes"])), source,
                             seconds, config)
                   for path, source in ((host_path, "host"), (client_path, "client"))]
        if results[0]["epoch"] != results[1]["epoch"]:
            raise IncompleteCalibration("host/client epoch mismatch")
        print(json.dumps({"completeWindow": True, "rendererStatus": results[1]["renderStatus"],
                          "acceptance": "not-assessed", "results": results}, sort_keys=True))
        return 0
    finally:
        process.terminate()
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=2)
        process.stdout.close()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--active-seconds", type=int, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--host-log", type=Path, default=Path.home() / "Library/Application Support/Mirri/Logs/host.log")
    parser.add_argument("--adb", default="/opt/homebrew/bin/adb")
    args = parser.parse_args()
    try:
        return collect(args.host_log, args.output_dir, args.active_seconds, args.adb)
    except (IncompleteCalibration, OSError, UnicodeError) as error:
        print(f"incomplete calibration: {error.__class__.__name__}: {error}")
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
