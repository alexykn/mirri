#!/usr/bin/env bash
# Build, sign and install the macOS host app, then start it.
#
# The bundle is signed with one persistent identity so macOS keeps the Screen
# Recording and Accessibility grants across updates (see sign_development.sh).
#
#   MIRRI_HOST_APP       install location (default ~/Applications/Mirri Development.app)
#   MIRRI_SIGN_IDENTITY  code-signing identity (default "Mirri Local Development")
#   MIRRI_STAGE_ONLY=1   build and sign into a temporary folder, install nothing
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
installed="${MIRRI_HOST_APP:-$HOME/Applications/Mirri Development.app}"
derived="$root/macos-host/.build/xcode"
stage="$(mktemp -d "${TMPDIR:-/tmp}/mirri-host.XXXXXX")"
trap 'rm -rf "$stage"' EXIT

xcodebuild -project "$root/macos-host/MirriHost.xcodeproj" -scheme MirriHost \
  -destination 'platform=macOS' -derivedDataPath "$derived" \
  CODE_SIGNING_ALLOWED=NO build | grep -E 'error:|warning: unre|BUILD' || true
built="$derived/Build/Products/Debug/MirriHost.app"
[[ -d "$built" ]] || { echo 'Build did not produce MirriHost.app.' >&2; exit 1; }

# Sign a clean copy; never merge a new build over an old bundle.
ditto "$built" "$stage/$(basename "$installed")"
bash "$root/tools/sign_development.sh" "$stage/$(basename "$installed")" | tail -1

if [[ "${MIRRI_STAGE_ONLY:-}" == 1 ]]; then
  echo "Signed build verified; nothing installed."
  exit 0
fi

# Let a running copy stop its session and remove its virtual display first.
if pgrep -x MirriHost >/dev/null; then
  if command -v mirri >/dev/null; then mirri quit >/dev/null 2>&1 || true; fi
  for _ in $(seq 50); do pgrep -x MirriHost >/dev/null || break; sleep 0.2; done
  pgrep -x MirriHost >/dev/null && { echo 'Quit Mirri, then run this again.' >&2; exit 1; }
fi
mkdir -p "$(dirname "$installed")"
rm -rf "$installed"
ditto "$stage/$(basename "$installed")" "$installed"
codesign --verify --deep --strict "$installed"
open -g "$installed"
echo "Installed and started: $installed"
