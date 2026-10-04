"""Read bounded Mirri host metrics lines locally; output numeric aggregates only.

The host log has ISO8601-prefixed 'metrics capture ...' text lines, not JSON.
Never upload a host log or echo its unrecognized content.
"""

import argparse
import re
import statistics
from pathlib import Path

PATTERN = re.compile(
    r"\bmetrics capture ([\d.]+) fps .*?encode ([\d.]+) fps .*?"
    r"(?:USB|sent) ([\d.]+) fps ([\d.]+) Mbit/s \(depth (\d+)\) / .*?"
    r"decode ([\d.]+) → ([\d.]+) fps"
)


def summarize(path: Path) -> None:
    rates: list[tuple[float, ...]] = []
    with path.open(encoding="utf-8", errors="replace") as source:
        for line in source:
            if match := PATTERN.search(line):
                rates.append(tuple(map(float, match.groups())))
    if not rates:
        print(
            "0 complete capture/encode/sent/decode intervals; no fps acceptance evidence"
        )
        return
    print(
        f"{len(rates)} complete reported intervals (not proof of scanout or 30-minute soak)"
    )
    for index, label in enumerate(
        (
            "capture callback fps (includes idle)",
            "encode fps",
            "transport write fps",
            "transport Mbit/s",
            "write depth",
            "decoder input fps",
            "decoder output fps",
        )
    ):
        values = [item[index] for item in rates]
        print(
            f"{label}: min={min(values):.1f} median={statistics.median(values):.1f} max={max(values):.1f}"
        )


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", type=Path, help="local host.log; never publish logs")
    summarize(parser.parse_args().log)
