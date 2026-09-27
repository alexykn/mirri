"""Check committed synthetic fixtures against their independent wire author.

Swift and Kotlin production-code tests must additionally run to prove their
decoders/encoders agree; this command does not execute either language.
"""

import hashlib
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
COMMITTED = ROOT / "protocol" / "fixtures"


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="mirri-fixtures-") as directory:
        generated = Path(directory)
        subprocess.run(
            [
                sys.executable,
                str(ROOT / "protocol" / "generate_fixtures.py"),
                "--output",
                str(generated),
            ],
            check=True,
        )
        expected = {path.name: path for path in generated.glob("*.bin")}
        actual = {path.name: path for path in COMMITTED.glob("*.bin")}
        if expected.keys() != actual.keys() or len(expected) != 24:
            print(
                "fixture inventory mismatch (expected 24 committed files)",
                file=sys.stderr,
            )
            return 1
        for name in sorted(expected):
            if expected[name].read_bytes() != actual[name].read_bytes():
                print(f"fixture differs: {name}", file=sys.stderr)
                return 1
        digest = hashlib.sha256()
        for name in sorted(actual):
            digest.update(name.encode("ascii") + b"\0" + actual[name].read_bytes())
        print(
            f"24 synthetic fixtures byte-identical; inventory SHA-256 {digest.hexdigest()}"
        )
        return 0


if __name__ == "__main__":
    sys.exit(main())
