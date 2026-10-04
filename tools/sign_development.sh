#!/usr/bin/env bash
# Reuse one certificate-backed identity across local app updates. Never fall back
# to ad-hoc signing: its cdhash requirement invalidates macOS privacy grants.
set -euo pipefail

if [[ $# != 1 || ! -d "$1/Contents/MacOS" ]]; then
  echo 'Usage: bash tools/sign_development.sh /path/to/MirriHost.app' >&2
  exit 2
fi

identity="${MIRRI_SIGN_IDENTITY:-Mirri Local Development}"
if [[ "$identity" == '-' ]]; then
  echo 'A persistent certificate-backed identity is required, not ad-hoc signing.' >&2
  exit 2
fi

codesign --force --deep --sign "$identity" --identifier dev.mirri.host \
  --timestamp=none "$1"
codesign --verify --deep --strict --verbose=2 "$1"
codesign --display --requirements - "$1"
