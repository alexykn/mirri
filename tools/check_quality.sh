#!/usr/bin/env bash
# Run from anywhere; record each independent gate even when another gate fails.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
mkdir -p logs/quality
failed=0
timing_dir="$(mktemp -d "${TMPDIR:-/tmp}/mirri-quality-timing.XXXXXXXX")" || exit 2
trap 'rm -rf -- "$timing_dir"' EXIT
check() {
  local name="$1"
  shift
  printf '\n== %s ==\n' "$name"
  "$@" >"logs/quality/$name.log" 2>&1
  local rc=$?
  cat "logs/quality/$name.log"
  printf '%s: exit %s (logs/quality/%s.log)\n' "$name" "$rc" "$name"
  if (( rc != 0 )); then failed=1; fi
}
python_timing_tests() {
  MIRRI_TIMING_EMITTER_DIR="$timing_dir" uv run --locked python - <<'PY'
import os
import pathlib
import sys
import unittest

source = pathlib.Path(os.environ["MIRRI_TIMING_EMITTER_DIR"])
for name in ("host-full", "host-partial", "client-full", "client-partial", "client-no-render"):
    path = source / f"{name}.log"
    if not path.is_file() or not path.stat().st_size:
        sys.exit(f"missing or empty production emitter output: {path}")

suite = unittest.defaultTestLoader.discover("tools", pattern="test_*.py")

def tests(group):
    for entry in group:
        if isinstance(entry, unittest.TestSuite):
            yield from tests(entry)
        else:
            yield entry

names = [test.id() for test in tests(suite)]
if not names or not any("ProductionTimingIntegrationTest" in name for name in names):
    sys.exit("Python production timing integration tests were not discovered")
result = unittest.TextTestRunner(verbosity=1).run(suite)
if not result.wasSuccessful() or result.skipped:
    sys.exit("Python timing tests failed or were skipped")
PY
}

if [[ "$(swiftlint version)" != "0.65.1" ]]; then
  echo 'SwiftLint 0.65.1 required (see README.md)' >&2
  exit 2
fi
check python-sync uv sync --locked
check python-format uv run --locked ruff format --check protocol/generate_fixtures.py tools
check python-lint uv run --locked ruff check protocol/generate_fixtures.py tools
check python-types uv run --locked ty check protocol/generate_fixtures.py tools
check protocol-fixtures uv run --locked python tools/compare_protocol_fixtures.py
check source-boundaries bash tools/test_source_boundaries.sh
check python-complexity uv run --locked xenon --max-absolute B protocol/generate_fixtures.py tools
check python-complexity-detail uv run --locked radon cc -s -n C protocol/generate_fixtures.py tools
check swift-format swift format lint -r --strict macos-host/Core macos-host/Tests macos-host/App macos-host/Tools
check swift-lint swiftlint lint --config .swiftlint.yml --strict --quiet
check swift-tests env MIRRI_TIMING_EMITTER_DIR="$timing_dir" bash -c 'cd macos-host && swift test -Xswiftc -warnings-as-errors'
# Xcode tests also execute package tests; do not emit the same host fixtures twice.
# First-party Xcode targets enable warnings-as-errors in project.yml; do not
# force this on package dependencies that intentionally compile with -suppress-warnings.
check swift-xcode-tests env -u MIRRI_TIMING_EMITTER_DIR xcodebuild -project macos-host/MirriHost.xcodeproj -scheme MirriHost -destination platform=macOS -derivedDataPath /tmp/mirri-host-derived CODE_SIGNING_ALLOWED=NO test
# Gradle does not track this ephemeral environment variable as a test task input.
# Re-run the existing aggregate invocation so UP-TO-DATE cannot omit client emitters.
check android env MIRRI_TIMING_EMITTER_DIR="$timing_dir" MIRRI_NETWORK_INTEROP=1 bash -c 'cd android-client && ./gradlew --rerun-tasks --continue --console=plain ktlintCheck detekt lintDebug testDebugUnitTest assembleDebug'
check python-tests python_timing_tests
exit "$failed"
