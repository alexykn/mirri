#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
./tools/check_source_boundaries.sh

scratch="$(mktemp -d "${TMPDIR:-/tmp}/mirri-boundaries.XXXXXXXX")"
trap 'rm -rf -- "$scratch"' EXIT
mkdir -p "$scratch/macos-host/Core/Transport" "$scratch/macos-host/Core/Streaming" "$scratch/macos-host/Core/Session"
for owner in transport video protocol session; do
  mkdir -p "$scratch/android-client/app/src/main/java/dev/mirri/client/$owner"
done
printf 'public protocol ByteStream {}\n' > "$scratch/macos-host/Core/Transport/Bytes.swift"
printf 'class Encoder {}\n' > "$scratch/macos-host/Core/Streaming/Encoder.swift"
printf 'actor SessionCoordinator {}\n' > "$scratch/macos-host/Core/Session/SessionCoordinator.swift"
printf 'package dev.mirri.client.transport\n' > "$scratch/android-client/app/src/main/java/dev/mirri/client/transport/Bytes.kt"
printf 'package dev.mirri.client.video\n' > "$scratch/android-client/app/src/main/java/dev/mirri/client/video/Decoder.kt"
printf 'package dev.mirri.client.protocol\n' > "$scratch/android-client/app/src/main/java/dev/mirri/client/protocol/Mirri.kt"
printf 'package dev.mirri.client.session\n' > "$scratch/android-client/app/src/main/java/dev/mirri/client/session/SessionController.kt"
./tools/check_source_boundaries.sh "$scratch"

assert_rejected() {
  local file="$1" line="$2"
  printf '%s\n' "$line" >> "$scratch/$file"
  if ./tools/check_source_boundaries.sh "$scratch" > /dev/null 2>&1; then
    echo "Boundary check accepted forbidden source: $file: $line" >&2
    exit 1
  fi
  sed -i '' '$d' "$scratch/$file"
}
assert_rejected macos-host/Core/Transport/Bytes.swift 'let codec = WireCodec.self'
assert_rejected macos-host/Core/Streaming/Encoder.swift 'let session: NegotiatedConfig? = nil'
assert_rejected macos-host/Core/Session/SessionCoordinator.swift 'let device: ADBDevice? = nil'
assert_rejected macos-host/Core/Session/SessionCoordinator.swift 'import Network'
assert_rejected android-client/app/src/main/java/dev/mirri/client/transport/Bytes.kt 'import dev.mirri.client.protocol.WireCodec'
assert_rejected android-client/app/src/main/java/dev/mirri/client/video/Decoder.kt 'import dev.mirri.client.protocol.VideoCodecId'
assert_rejected android-client/app/src/main/java/dev/mirri/client/protocol/Mirri.kt 'import dev.mirri.client.session.ClientAttempt'
assert_rejected android-client/app/src/main/java/dev/mirri/client/session/SessionController.kt 'val socket: SocketChannel? = null'
echo 'Source boundaries and eight forbidden-direction probes passed'
