"""Clock-causality and production Swift/Kotlin sampled-emitter integration, offline only."""

import io
import os
import tempfile
import time
import unittest
from dataclasses import replace
from pathlib import Path
from typing import cast

from aggregate_timing import IncompleteCalibration, load_config
from collect_timing import Observation
from latency_trace import (
    MAX_AGE_NS,
    _stall_windows,
    aggregate_paths,
    diagnose_paths,
    parse_file,
    parse_line,
    require_matching_window,
    summarize,
)


class LatencyTraceTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        root = os.environ.get("MIRRI_TIMING_EMITTER_DIR")
        if root is None:
            raise AssertionError(
                "emit production Swift and Kotlin latency fixtures first"
            )
        cls.host_path = Path(root, "host-latency.log")
        cls.client_path = Path(root, "client-latency.log")
        if not cls.host_path.is_file() or not cls.client_path.is_file():
            raise AssertionError("missing production sampled latency emitter fixture")

    def test_production_emitter_pair_and_asymmetric_clock_bounds(self) -> None:
        report = aggregate_paths(self.host_path, self.client_path)
        self.assertEqual(report["selectedHost"], 20)
        self.assertEqual(report["selectedClient"], 20)
        self.assertEqual(report["matched"], 20)
        self.assertEqual(report["calibrationUnavailable"], 0)
        ages = cast(dict[str, dict[str, object]], report["ages"])
        self.assertEqual(ages["render"]["count"], 20)
        lo, hi = cast(list[float], ages["packet"]["p95Ms"])
        self.assertTrue(0 <= lo < 60 < hi <= 100)
        self.assertGreater(cast(float, report["maxClockWidthMs"]), 60)
        require_matching_window(
            report, 1_000_000_000, 3_000_000_000, 1_500_000_000, 3_550_000_000
        )
        with self.assertRaisesRegex(IncompleteCalibration, "active windows"):
            require_matching_window(
                report, 11_000_000_000, 13_000_000_000, 1_500_000_000, 3_550_000_000
            )

    def test_stale_outlier_replay_and_invalid_timestamp_fail_closed(self) -> None:
        host = parse_file(self.host_path, "host")
        client = parse_file(self.client_path, "client")
        calibration = host[0].clocks[0]
        self.assertEqual(
            calibration.interval(calibration.t4), (469_993_900, 530_006_100)
        )
        self.assertIsNone(calibration.interval(calibration.t4 + MAX_AGE_NS + 1))
        self.assertIsNone(
            replace(calibration, t3=calibration.t2 - 1).interval(calibration.t4)
        )
        self.assertIsNone(
            replace(calibration, t2=calibration.t1 + 2_000_000_000).interval(
                calibration.t4
            )
        )
        host_replay = [replace(host[0], clocks=(calibration, calibration)), *host[1:]]
        with self.assertRaisesRegex(IncompleteCalibration, "replayed Pong"):
            summarize(host_replay, client)
        host_invalid = [replace(host[0], clocks=()), *host[1:]]
        self.assertEqual(summarize(host_invalid, client)["calibrationUnavailable"], 20)
        inconsistent = replace(
            calibration,
            sequence=1,
            t2=calibration.t2 + 200_000_000,
            t3=calibration.t3 + 200_000_000,
        )
        with_bad_clock = [
            replace(host[0], clocks=(calibration, inconsistent)),
            *host[1:],
        ]
        self.assertEqual(
            summarize(with_bad_clock, client)["calibrationUnavailable"], 20
        )
        bad_client = [replace(client[0], trace="1" * 32), *client[1:]]
        with self.assertRaisesRegex(IncompleteCalibration, "cross-session"):
            summarize(host, bad_client)
        bad_route = [replace(client[0], route="network"), *client[1:]]
        with self.assertRaisesRegex(IncompleteCalibration, "cross-session"):
            summarize(host, bad_route)
        frame = client[0].frames[0]
        reversed_frame = replace(
            frame,
            stamps=(
                frame.stamps[0],
                frame.stamps[2],
                frame.stamps[1],
                *frame.stamps[3:],
            ),
        )
        client_bad_order = [
            replace(client[0], frames=(reversed_frame, *client[0].frames[1:])),
            *client[1:],
        ]
        with self.assertRaisesRegex(IncompleteCalibration, "clock order"):
            summarize(host, client_bad_order)

    def test_generation_pts_and_bounds_reject_duplicate_mismatch_and_oversized_line(
        self,
    ) -> None:
        host = parse_file(self.host_path, "host")
        client = parse_file(self.client_path, "client")
        duplicate = [
            replace(client[0], frames=(*client[0].frames, client[0].frames[0])),
            *client[1:],
        ]
        with self.assertRaisesRegex(IncompleteCalibration, "duplicate"):
            summarize(host, duplicate)
        mismatched_pts = replace(client[0].frames[0], pts_us=1)
        client_bad_pts = [
            replace(client[0], frames=(mismatched_pts, *client[0].frames[1:])),
            *client[1:],
        ]
        result = summarize(host, client_bad_pts)
        self.assertEqual(result["unmatchedClient"], 1)
        self.assertEqual(result["unmatchedHost"], 1)
        line = self.host_path.read_text().splitlines()[0]
        with self.assertRaisesRegex(IncompleteCalibration, "line length"):
            parse_line(line + " " * 3_900, "host")

    def test_framework_render_between_release_request_and_return(self) -> None:
        host = parse_file(self.host_path, "host")
        client = parse_file(self.client_path, "client")
        sample = client[0].frames[0]
        early = replace(
            sample,
            stamps=(*sample.stamps[:5], sample.stamps[3] + 500_000),
        )
        revised = [
            replace(client[0], frames=(early, *client[0].frames[1:])),
            *client[1:],
        ]
        ages = cast(dict[str, dict[str, object]], summarize(host, revised)["ages"])
        self.assertEqual(ages["render"]["count"], 20)

    def test_diagnostic_local_gap_retains_pre_gap_ages(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            files = []
            for side, original_path in (
                ("host", self.host_path),
                ("client", self.client_path),
            ):
                first, second = original_path.read_text().splitlines()
                old_end = 3_000_000_000 if side == "host" else 3_550_000_000
                second = second.replace(
                    f" endNs={old_end} ", f" endNs={old_end + 3_000_000_000} "
                )
                path = Path(temp, f"{side}.log")
                path.write_text(first + "\n" + second + "\n")
                files.append(path)
            diagnostic = diagnose_paths(files[0], files[1])
            self.assertTrue(diagnostic["gapFacts"])
            segment = cast(list[dict[str, object]], diagnostic["segments"])[0]
            self.assertEqual(segment["matched"], 10)
            partial_ages = cast(dict[str, dict[str, object]], segment["ages"])
            self.assertEqual(partial_ages["render"]["count"], 10)
            with self.assertRaisesRegex(IncompleteCalibration, "heartbeat gap"):
                parse_file(files[0], "host")

    def test_record_boundaries_and_reconnect_identity(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp, "host.log")
            lines = self.host_path.read_text().splitlines()
            path.write_text("\n".join([lines[0], lines[0], lines[1]]) + "\n")
            with self.assertRaisesRegex(IncompleteCalibration, "skipped"):
                parse_file(path, "host")
            path.write_text("\n".join(lines).replace(" epoch=9 ", " epoch=10 ") + "\n")
            with self.assertRaisesRegex(IncompleteCalibration, "cross-session"):
                summarize(
                    parse_file(path, "host"), parse_file(self.client_path, "client")
                )

    def test_optional_collector_filters_only_valid_numeric_trace_lines(self) -> None:
        observation = Observation(load_config(), time.monotonic(), None)
        observation.host_epoch = 9
        observation.host_start_ns = 1_000_000_000
        observation.client_start_ns = 1_500_000_000
        host_out, client_out = io.BytesIO(), io.BytesIO()
        host_line = self.host_path.read_bytes().splitlines()[0]
        client_line = self.client_path.read_bytes().splitlines()[0]
        observation.accept_host_latency(host_line, host_out)
        observation.accept_client_line(client_line, io.BytesIO(), client_out)
        self.assertEqual(host_out.getvalue(), host_line + b"\n")
        self.assertEqual(client_out.getvalue(), client_line + b"\n")
        self.assertEqual(observation.client_records, 0)
        with self.assertRaisesRegex(IncompleteCalibration, "host latency record"):
            observation.accept_host_latency(host_line + b" " * 3_900, host_out)
        self.assertEqual(host_out.getvalue(), host_line + b"\n")


class AgeWindowCoverageTest(unittest.TestCase):
    def test_bounded_details_do_not_truncate_window_or_sample_counts(self) -> None:
        samples = [
            (i * 100_000_000, i * 12, 120_000_000, 130_000_000) for i in range(40)
        ]
        samples.append((3_950_000_000, 39 * 12 + 6, 120_000_000, 130_000_000))
        for result in _stall_windows(samples, 100_000_000).values():
            self.assertEqual(result["count"], 40)
            self.assertEqual(result["sampleCount"], 41)
            self.assertEqual(result["omittedWindows"], 8)
            self.assertEqual(len(cast(list[object], result["windows"])), 32)


if __name__ == "__main__":
    unittest.main()
