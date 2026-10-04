#!/usr/bin/env bash
# Build the `mirri` terminal command and link it into a directory on PATH.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
target="${MIRRI_CLI_DIR:-$HOME/.local/bin}"
swift build --package-path "$root/macos-host" -c release --product mirri
binary="$(swift build --package-path "$root/macos-host" -c release --show-bin-path)/mirri"
mkdir -p "$target"
ln -sf "$binary" "$target/mirri"
echo "mirri -> $binary"
