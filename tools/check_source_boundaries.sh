#!/usr/bin/env bash
# Source dependency guard for boundaries within single Swift/Android build targets.
set -euo pipefail
root="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$root"

paths=(
  macos-host/Core/Transport macos-host/Core/Streaming macos-host/Core/Session
  android-client/app/src/main/java/dev/mirri/client/transport
  android-client/app/src/main/java/dev/mirri/client/video
  android-client/app/src/main/java/dev/mirri/client/protocol
  android-client/app/src/main/java/dev/mirri/client/session
)
for path in "${paths[@]}"; do
  [[ -d "$path" ]] || { echo "Missing source boundary: $path" >&2; exit 2; }
done
[[ -f macos-host/Core/Session/SessionCoordinator.swift ]] || {
  echo 'Missing host session boundary: SessionCoordinator.swift' >&2
  exit 2
}

failed=0
reject() {
  local owner="$1" source="$2" pattern="$3"
  if rg -n --glob '*.{swift,kt}' "$pattern" "$source"; then
    echo "Forbidden dependency in $owner" >&2
    failed=1
  fi
}
reject 'host byte transport' macos-host/Core/Transport \
  '\b(WireCodec|WireFramer|WireConnection|HostCommand|ClientEvent|NegotiatedConfig|Authenticator|ADBClient|AdbReverseManager)\b'
reject 'host capture/encode' macos-host/Core/Streaming \
  '\b(NegotiatedConfig|WireConnection|WireMessage|HostCommand|ClientEvent|LoopbackByteListener|NetworkByteConnection|ADBClient|sessionId)\b'
reject 'host session route isolation' macos-host/Core/Session/SessionCoordinator.swift \
  '\b(ADBDevice|ADBClient|AdbReverseManager|LoopbackByteListener|NetworkByteConnection)\b|^[[:space:]]*import[[:space:]]+Network\b'
reject 'Android byte transport' android-client/app/src/main/java/dev/mirri/client/transport \
  '^import dev\.mirri\.client\.(protocol|session|video)\b|\b(WireCodec|WireException|WireMessage|SessionMessages)\b'
reject 'Android media services' android-client/app/src/main/java/dev/mirri/client/video \
  '^import dev\.mirri\.client\.(protocol|transport|session)\b|\b(WireCodec|WireException|SessionConfiguration|ControlChannel|VideoChannel)\b'
reject 'Android Mirri protocol' android-client/app/src/main/java/dev/mirri/client/protocol \
  '^import dev\.mirri\.client\.session\b|\b(SocketChannel|android\.content\.Intent)\b'
reject 'Android session owner' android-client/app/src/main/java/dev/mirri/client/session/SessionController.kt \
  '\bSocketChannel\b|^import android\.content\.Intent\b|\bget(String|Int)Extra\('
exit "$failed"
