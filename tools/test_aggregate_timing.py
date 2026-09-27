"""Software-only integration against Swift/Kotlin production emitter output.

Run the focused emitter tests with MIRRI_TIMING_EMITTER_DIR set first; these
tests never invent a parallel happy-path schema or contact an actual device.
"""

from concurrent.futures import ThreadPoolExecutor
from contextlib import redirect_stdout
import io
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
from typing import Any, cast
import unittest
from unittest.mock import patch

from aggregate_timing import IncompleteCalibration, aggregate, load_config, parse, validate_timing_line
from collect_timing import collect, host_snapshot

CONFIG = load_config()


class ProductionTimingIntegrationTest(unittest.TestCase):
    @staticmethod
    def wait_nonempty(path: Path) -> None:
        deadline = time.monotonic() + 5
        while not path.is_file() or not path.stat().st_size:
            if time.monotonic() >= deadline:
                raise AssertionError("fake producer readiness timeout")
            time.sleep(0.005)

    def fake_adb(self, client: Path, output: Path, *, old: bytes = b"", linger: bool = False) -> Path:
        """Do not emit current records until the collector has processed host record zero."""
        old_path = Path(self.directory.name) / "old-client.log"
        old_path.write_bytes(old)
        fake_adb = Path(self.directory.name) / "fake-adb"
        fake_adb.write_text(
            "#!/bin/sh\n[ \"$1\" = '-d' ] || exit 2\n"
            + (f"cat '{old_path}'\n" if old else "")
            + "n=0\n"
            + f"while [ ! -s '{output / 'host-timing.log'}' ]; do\n"
            + "  n=$((n+1)); [ \"$n\" -lt 500 ] || exit 3; sleep 0.01\n"
            + "done\n"
            + f"cat '{client}'\n"
            + ("exec sleep 10\n" if linger else "")
        )
        fake_adb.chmod(0o700)
        return fake_adb

    def setUp(self) -> None:
        source = os.environ.get("MIRRI_TIMING_EMITTER_DIR")
        if not source:
            self.fail("run Swift/Kotlin production emitter tests with MIRRI_TIMING_EMITTER_DIR first")
        self.emitted = Path(source)
        for name in ("host-full", "host-partial", "client-full", "client-partial", "client-no-render"):
            if not (self.emitted / f"{name}.log").is_file():
                self.fail(f"missing production emitter fixture {name}")
        self.directory = tempfile.TemporaryDirectory(prefix="mirri-timing-sourceonly-")
        self.addCleanup(self.directory.cleanup)
        self.host = Path(self.directory.name) / "host.log"
        self.client = Path(self.directory.name) / "client.log"

    def copy(self, name: str = "full") -> None:
        self.host.write_bytes((self.emitted / f"host-{name}.log").read_bytes())
        self.client.write_bytes((self.emitted / f"client-{name}.log").read_bytes())

    def test_real_normal_and_final_envelopes_and_exact_60fps(self) -> None:
        self.copy()
        host_lines, client_lines = self.host.read_text().splitlines(), self.client.read_text().splitlines()
        self.assertTrue(host_lines[0].startswith("2026-09-26T16:00:00Z metrics videoTiming v=4 "))
        self.assertTrue(client_lines[0].startswith("1727366400.000 123 456 I MirriTiming: v=4 "))
        for line in (host_lines[0], host_lines[-1]):
            validate_timing_line(line, "host")
        for line in (client_lines[0], client_lines[-1]):
            validate_timing_line(line, "client")
        self.assertIn(" final=1 ", host_lines[-1])
        self.assertIn(" final=1 ", client_lines[-1])
        self.assertLess(max(map(lambda line: len(line.encode()), client_lines)), CONFIG["maxLineBytes"])
        with self.assertRaises(IncompleteCalibration):
            validate_timing_line(client_lines[-1].replace("MirriTiming: ", "MirriTiming: final ", 1), "client")
        h = aggregate(parse(self.host, "host", CONFIG["maxLineBytes"]), "host", 90, CONFIG)
        c = aggregate(parse(self.client, "client", CONFIG["maxLineBytes"]), "client", 90, CONFIG)
        self.assertEqual(h["activeSeconds"], 90)
        self.assertEqual(c["activeSeconds"], 90)
        self.assertEqual(cast(dict[str, float], h["fps"]), {"complete": 60, "encoded": 60, "written": 60})
        self.assertEqual(cast(dict[str, float], c["fps"])["received"], 60)
        self.assertEqual(cast(dict[str, float], c["fps"])["output"], 60)
        host_classes = cast(dict[str, object], h["keyClasses"])
        client_classes = cast(dict[str, object], c["keyClasses"])
        self.assertEqual(cast(dict[str, int], host_classes["key"])["count"], 90)
        self.assertEqual(cast(dict[str, int], client_classes["key"])["count"], 90)
        keyed = cast(dict[str, dict[str, dict[str, object]]], client_classes["stages"])
        self.assertEqual(keyed["outputGap"]["key"]["count"], 89)
        self.assertEqual(keyed["inputOutput"]["nonkey"]["count"], 5310)
        self.assertEqual(cast(dict[str, float], c["fps"])["validRendered"], 60)
        self.assertEqual(c["renderStatus"], "valid")
        # These zero durations were generated through the actual Swift and
        # Kotlin histogram owners and production log-formatting call sites.
        self.assertEqual(cast(dict[str, dict[str, object]], h["stages"])["vtCall"]["maxMs"], 0.0)
        self.assertEqual(cast(dict[str, dict[str, object]], c["stages"])["packetInput"]["maxMs"], 0.0)
        self.assertEqual(cast(dict[str, dict[str, object]], h["stages"])["vtCall"]["count"], 5400)
        self.assertEqual(cast(dict[str, dict[str, object]], c["stages"])["packetInput"]["count"], 5400)

    def test_legacy_v3_remains_readable_offline_but_not_a_production_v4_emitter(self) -> None:
        self.copy()
        # A decoder compatibility test only: remove v4-only diagnostic tokens
        # from actual Swift/Kotlin v4 emitters. No parallel v3 production owner.
        extra = {"keyEncoded", "keyWritten", "keyReceived", "keyOutput", "keyBytes",
                 "keyMaxBytes", "otherBytes", "otherMaxBytes", "keyVtCallback",
                 "keyPacketGap", "keyInputOutput", "keyOutputGap"}
        for path, source in ((self.host, "host"), (self.client, "client")):
            legacy = []
            for line in path.read_text().splitlines():
                tokens = ["v=3" if token == "v=4" else token for token in line.split()
                          if token.split("=", 1)[0] not in extra]
                legacy.append(" ".join(tokens))
            path.write_text("\n".join(legacy) + "\n")
            rows = parse(path, source, CONFIG["maxLineBytes"])
            summary = aggregate(rows, source, 90, CONFIG)
            self.assertEqual(summary["schema"], 3)
            self.assertNotIn("keyClasses", summary)

    def test_partial_first_and_last_records_cover_same_90_second_window(self) -> None:
        self.copy("partial")
        host = parse(self.host, "host", CONFIG["maxLineBytes"])
        client = parse(self.client, "client", CONFIG["maxLineBytes"])
        self.assertEqual((host[0].numbers["complete"], host[-1].numbers["complete"]), (45, 15))
        self.assertEqual((client[0].numbers["received"], client[-1].numbers["received"]), (45, 15))
        h = aggregate(host, "host", 90, CONFIG)
        c = aggregate(client, "client", 90, CONFIG)
        self.assertEqual(h["activeSeconds"], 90)
        self.assertEqual(c["activeSeconds"], 90)
        self.assertEqual(cast(dict[str, float], h["fps"])["written"], 60)
        self.assertEqual(cast(dict[str, float], c["fps"])["released"], 60)
        # Advancing the first denominator start by one second cannot borrow
        # the original first numerator; it creates a gap and is incomplete.
        self.host.write_text(self.host.read_text().replace("startNs=1250000000", "startNs=2250000000", 1))
        with self.assertRaises(IncompleteCalibration):
            aggregate(parse(self.host, "host", CONFIG["maxLineBytes"]), "host", 90, CONFIG)

    def test_stop_tail_and_missing_optional_callback_are_not_false_pass(self) -> None:
        self.copy()
        self.client.write_bytes((self.emitted / "client-no-render.log").read_bytes())
        data = aggregate(parse(self.client, "client", CONFIG["maxLineBytes"]), "client", 90, CONFIG)
        self.assertEqual(data["renderStatus"], "unavailable")
        self.assertEqual(cast(dict[str, float], data["fps"])["output"], 60)
        self.assertEqual(cast(dict[str, float], data["fps"])["validRendered"], 0)
        self.assertGreater(cast(int, data["rightCensored"]), 0)
        self.assertGreater(cast(int, data["interiorPending"]), 0)
        self.assertIsNotNone(data["renderCoverage"])

    def test_corrupt_bins_max_unknown_field_missing_final_and_generation_fail(self) -> None:
        self.copy()
        lines = self.host.read_text().splitlines(keepends=True)
        for modified in (lines[:-1], lines[:3] + lines[4:], lines[:2] + [lines[1]] + lines[2:],
                         [line.replace("generation=1", "generation=2", 1) if i == 12 else line
                          for i, line in enumerate(lines)]):
            self.host.write_text("".join(modified))
            with self.assertRaises(IncompleteCalibration):
                aggregate(parse(self.host, "host", CONFIG["maxLineBytes"]), "host", 90, CONFIG)
        with self.assertRaises(IncompleteCalibration):
            validate_timing_line(lines[0].strip() + " private=123", "host")
        self.copy()
        self.host.write_text(self.host.read_text().replace("complete=60", "complete=0", 1))
        with self.assertRaisesRegex(IncompleteCalibration, "host capture/encode/write totals inconsistent"):
            aggregate(parse(self.host, "host", CONFIG["maxLineBytes"]), "host", 90, CONFIG)
        self.copy()
        fields = lines[0].split()
        i = next(i for i, item in enumerate(fields) if item.startswith("mediaPtsGap="))
        parts = fields[i].split(":")
        parts[4] = "10000.0"  # occupied bin below 20 ms cannot claim 10 seconds maximum
        fields[i] = ":".join(parts)
        with self.assertRaises(IncompleteCalibration):
            validate_timing_line(" ".join(fields), "host")
        fields = lines[0].split()
        i = next(i for i, item in enumerate(fields) if item.startswith("mediaPtsGap="))
        parts = fields[i].split(":")
        parts[4] = "0.0"  # Zero cannot be the maximum of a later occupied bin.
        fields[i] = ":".join(parts)
        with self.assertRaisesRegex(IncompleteCalibration, "maximum inconsistent"):
            validate_timing_line(" ".join(fields), "host")
        parts[4] = "16.0"  # Occupied (16,18] bin excludes its lower boundary.
        fields[i] = ":".join(parts)
        with self.assertRaisesRegex(IncompleteCalibration, "maximum inconsistent"):
            validate_timing_line(" ".join(fields), "host")

    def test_fake_usb_collector_skips_one_old_tag_and_owns_cleanup(self) -> None:
        self.copy()
        host_bytes = self.host.read_bytes()
        self.host.write_bytes(b"2026-09-26T15:00:00Z state idle\n")
        output = Path(self.directory.name) / "output"
        old_line = self.client.read_bytes().splitlines(keepends=True)[-1]
        fake_adb = self.fake_adb(self.client, output, old=old_line)
        ready = threading.Event()

        def append_host() -> None:
            if not ready.wait(5):
                raise AssertionError("collector did not seed host offsets")
            with self.host.open("ab") as target:
                target.write(host_bytes)

        with ThreadPoolExecutor(max_workers=1) as executor:
            writer = executor.submit(append_host)
            with redirect_stdout(io.StringIO()):
                result = collect(self.host, output, 90, str(fake_adb), on_ready=ready.set)
            writer.result(timeout=6)
            self.assertEqual(result, 0)

    def test_collector_reconciles_rotation_between_opening_oldest_and_previous(self) -> None:
        self.copy()
        host_lines = self.host.read_bytes().splitlines(keepends=True)
        self.host.write_bytes(b"")
        oldest = self.host.with_name("host.2.log")
        previous = self.host.with_name("host.1.log")
        oldest.write_bytes(b"2026-09-26T15:00:00Z state idle\n")
        # This older log has a valid-looking record 84 and a forbidden state.
        # Replaying it at byte zero must never contaminate the current window.
        previous.write_bytes(b"2026-09-26T15:00:00Z state waitingForClient\n" + host_lines[84])
        output = Path(self.directory.name) / "out-rotating"
        fake_adb = self.fake_adb(self.client, output)
        ready, armed, rotated = threading.Event(), threading.Event(), threading.Event()
        original_open = Path.open

        def rotating_open(path: Path, *args: Any, **kwargs: Any):
            if path == previous and armed.is_set() and not rotated.is_set():
                rotated.set()
                # Actual SessionLogger ordering under its writer lock.
                oldest.unlink()
                previous.rename(oldest)
                self.host.rename(previous)
                self.host.write_bytes(b"")
            return original_open(path, *args, **kwargs)

        def produce() -> None:
            if not ready.wait(5):
                raise AssertionError("collector did not seed host offsets")
            self.host.write_bytes(b"".join(host_lines[:84]))
            armed.set()
            self.wait_nonempty(output / "host-timing.log")
            if not rotated.wait(5):
                raise AssertionError("rotation did not occur during collector scan")
            # Allow the old scanner's next poll to replay .1 at .2 before the
            # remaining current records arrive. The reconciled scanner does not.
            time.sleep(0.3)
            with self.host.open("ab") as target:
                target.write(b"".join(host_lines[84:]))

        with ThreadPoolExecutor(max_workers=1) as executor:
            writer = executor.submit(produce)
            with patch.object(Path, "open", rotating_open), redirect_stdout(io.StringIO()):
                result = collect(self.host, output, 90, str(fake_adb), on_ready=ready.set)
            writer.result(timeout=6)
        self.assertEqual(result, 0)
        self.assertTrue(rotated.is_set())
        self.assertEqual((output / "host-timing.log").read_bytes(), b"".join(host_lines))
        self.assertEqual((output / "client-timing.log").read_bytes(), self.client.read_bytes())

    def test_unstable_host_snapshot_refuses_after_three_bounded_attempts(self) -> None:
        self.host.write_bytes(b"old\n")
        original_stat = Path.stat
        opens = 0
        opened_streams: list[Any] = []
        original_open = Path.open

        def inconsistent_stat(path: Path, *args: Any, **kwargs: Any):
            result = original_stat(path, *args, **kwargs)
            if path != self.host:
                return result
            fields = list(result)
            fields[1] += 1  # stat inode differs from the held descriptor's fstat
            return os.stat_result(fields)

        def counted_open(path: Path, *args: Any, **kwargs: Any):
            nonlocal opens
            if path == self.host:
                opens += 1
            stream = original_open(path, *args, **kwargs)
            opened_streams.append(stream)
            return stream

        with patch.object(Path, "open", counted_open), patch.object(Path, "stat", inconsistent_stat):
            with self.assertRaisesRegex(IncompleteCalibration, "host rotation did not stabilize"):
                with host_snapshot(self.host):
                    pass
        self.assertEqual(opens, 3)  # no unbounded retries or open inode cache
        self.assertTrue(all(stream.closed for stream in opened_streams))

    def test_cli_rejects_epoch_mismatch(self) -> None:
        self.copy()
        self.client.write_text(self.client.read_text().replace("epoch=7", "epoch=8"))
        command = [sys.executable, str(Path(__file__).parent / "aggregate_timing.py"),
                   "--active-seconds", "90", "--host", str(self.host), "--client", str(self.client)]
        result = subprocess.run(command, capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 2)
        self.assertIn("epoch mismatch", result.stdout)

    def test_fake_collector_fails_promptly_on_host_disconnect_and_cleans_process(self) -> None:
        self.copy()
        first = self.host.read_bytes().splitlines(keepends=True)[0]
        self.host.write_bytes(b"")
        output = Path(self.directory.name) / "out-failed"
        fake_adb = self.fake_adb(self.client, output, linger=True)
        ready = threading.Event()

        def disconnect() -> None:
            if not ready.wait(5):
                raise AssertionError("collector did not seed host offsets")
            with self.host.open("ab") as target:
                target.write(first)
            self.wait_nonempty(output / "client-timing.log")
            with self.host.open("ab") as target:
                target.write(b"2026-09-26T16:00:01Z state waitingForReconnect\n")

        begin = time.monotonic()
        with ThreadPoolExecutor(max_workers=1) as executor:
            writer = executor.submit(disconnect)
            with self.assertRaisesRegex(IncompleteCalibration, "host left active stream"):
                collect(self.host, output, 90, str(fake_adb), on_ready=ready.set)
            writer.result(timeout=6)
        self.assertLess(time.monotonic() - begin, 3.0)

    def test_collector_still_refuses_missing_host_record(self) -> None:
        self.copy()
        lines = self.host.read_bytes().splitlines(keepends=True)
        self.host.write_bytes(b"")
        output = Path(self.directory.name) / "out-host-gap"
        fake_adb = self.fake_adb(self.client, output, linger=True)
        ready = threading.Event()

        def missing_record() -> None:
            if not ready.wait(5):
                raise AssertionError("collector did not seed host offsets")
            self.host.write_bytes(lines[0] + b"".join(lines[2:]))

        with ThreadPoolExecutor(max_workers=1) as executor:
            writer = executor.submit(missing_record)
            with self.assertRaisesRegex(IncompleteCalibration, "host epoch or record changed"):
                collect(self.host, output, 90, str(fake_adb), on_ready=ready.set)
            writer.result(timeout=6)

    def test_collector_still_refuses_truncated_host_inode(self) -> None:
        self.copy()
        first = self.host.read_bytes().splitlines(keepends=True)[0]
        self.host.write_bytes(b"")
        output = Path(self.directory.name) / "out-host-truncated"
        fake_adb = self.fake_adb(self.client, output, linger=True)
        ready = threading.Event()

        def truncate() -> None:
            if not ready.wait(5):
                raise AssertionError("collector did not seed host offsets")
            self.host.write_bytes(first)
            self.wait_nonempty(output / "host-timing.log")
            self.host.write_bytes(b"")  # same inode, smaller than recorded offset

        with ThreadPoolExecutor(max_workers=1) as executor:
            writer = executor.submit(truncate)
            with self.assertRaisesRegex(IncompleteCalibration, "host log truncated"):
                collect(self.host, output, 90, str(fake_adb), on_ready=ready.set)
            writer.result(timeout=6)

    def test_old_logcat_line_does_not_mask_missing_new_record_zero(self) -> None:
        self.copy()
        host_bytes = self.host.read_bytes()
        self.host.write_bytes(b"")
        lines = self.client.read_bytes().splitlines(keepends=True)
        fake_client = Path(self.directory.name) / "missing-zero.log"
        fake_client.write_bytes(b"".join(lines[1:]))
        output = Path(self.directory.name) / "out-no-zero"
        fake_adb = self.fake_adb(fake_client, output, old=lines[-1])
        ready = threading.Event()

        def append_host() -> None:
            if not ready.wait(5):
                raise AssertionError("collector did not seed host offsets")
            self.host.write_bytes(host_bytes)

        with ThreadPoolExecutor(max_workers=1) as executor:
            writer = executor.submit(append_host)
            with self.assertRaisesRegex(IncompleteCalibration, "client record zero missing"):
                collect(self.host, output, 90, str(fake_adb), on_ready=ready.set)
            writer.result(timeout=6)


if __name__ == "__main__":
    unittest.main()
