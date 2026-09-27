# Secure IP streaming: implementation decision

## Supported topology

Implement an opt-in **Network (USB setup)** mode alongside USB. The Mac and tablet
must already share reachable IP connectivity, such as a Wi-Fi LAN or a tablet
hotspot. Mirri does not configure Wi-Fi, router rules, macOS Internet Sharing or
ADB-over-TCP. The USB cable is used once to launch the selected client with the
session credentials and pinned server identity. Streaming and reconnect must
work without USB after that launch. Starting a new session requires USB setup
again; persistent pairing and QR-code setup are not part of this first version.

This is not Wi-Fi Direct or Wi-Fi Aware support. Apple DTS states that macOS does
not currently support Wi-Fi Aware even though framework availability can appear
in Catalyst documentation: <https://developer.apple.com/forums/thread/827887>.
Do not assume Apple's peer-to-peer networking interoperates with Android P2P.

## Security and endpoint selection

* The application exposes a separate network-start action with explicit selection
  of a currently assigned local unicast IPv4 address/interface. Bind only that
  address, not `0.0.0.0`. Exclude loopback, unspecified and multicast addresses.
  Validate the address again when starting; interface changes are legitimate
  failures, not permission to bind a different interface. IPv6 and discovery are
  deferred. USB listeners remain strictly loopback-only.
* Use Network.framework TLS on macOS and the platform `SSLSocket` on Android,
  with TLS 1.2 minimum. No plaintext fallback, TOFU or permissive trust manager.
* Generate a fresh P-256 self-signed server certificate and key for each network
  session. Use Apple's `swift-certificates`/Crypto/SwiftASN1 libraries for X.509
  creation, then public Security APIs (`SecKeyCreateWithData`,
  `SecCertificateCreateWithData`, `SecIdentityCreate`, `sec_identity_create`) for
  an in-memory TLS identity. Do not write private keys, import into the user's
  keychain, invoke OpenSSL, or invent a DER encoder. Declare reproducible package
  dependencies in both SwiftPM and XcodeGen builds.
* The certificate is valid for 24 hours (allow a small not-before clock margin)
  and identifies the selected address. A new session is required after expiry.
  Launch passes the exact SHA-256 certificate pin, random 32-byte session token,
  selected IPv4 address, ports, protocol and network-mode discriminator through
  the existing selected-device ADB path. Do not persist or log credentials.
* The client accepts only the pinned certificate, checks certificate validity,
  and relies on TLS proof of possession. Exact pin verification is the identity
  policy, not acceptance based on public CA trust or an arbitrary hostname. Wrong
  pins and expired certificates are terminal authentication failures. Both
  control and video connections verify the pin before sending any token.
* Mirri's token authenticates the client to the host inside TLS. Authenticate
  before creating a virtual display or allowing input. Video retains the normal
  session-ID/token/epoch validation. Keep bounded connection occupancy, handshake
  deadlines, cancellation and reconnect grace; do not add unbounded accept tasks.

## Integration with the existing boundaries

Add a network route implementing `HostConnectionRoute`, using the same bounded
byte-listener/Network adapter as USB with explicitly supplied endpoint/TLS
parameters. Do not copy the socket implementation or change USB security by
adding a wildcard default. The device service exclusively owns the one selected
bootstrap route, whether USB or network; device installation and reverse cleanup
remain excluded during a session. Factor genuinely shared USB bootstrap work
without a generic route framework or duplicate lifecycle owner.

Network route preparation checks the installed client version, prepares the
ephemeral identity and listeners, and joins every pending bootstrap operation
before closing. Its first bootstrap launches the tablet over ADB. Retry updates
the host-authoritative epoch and replaces interrupted listeners, **without ADB**.
Keep endpoint ports stable for the session. No reverse mappings are created or
removed by the network route. Route labels/messages must let the shared session
coordinator report the actual mode without knowing ADB, IP or TLS internals.

On Android, launch decoding validates all fields once and constructs the chosen
connector and bootstrap policy. Unknown modes and incomplete/mixed network
credentials are rejected rather than treated as USB. Raw TCP/TLS adapters remain
unaware of Mirri messages and epochs. The session layer selects a Mirri bootstrap
operation above the byte connection to obtain this attempt's epoch.

## Network control bootstrap, version 1

The USB stream is unchanged. On a pinned TLS **control** connection only, exchange
this bounded preface before the existing Mirri ClientHello. Integers are unsigned
big-endian; lengths are fixed, not peer-controlled.

| Direction | Bytes | Meaning |
| --- | --- | --- |
| Client request | 4 | ASCII `MRNB` |
| | 2 | bootstrap version, `1` |
| | 2 | role, `1` (control) |
| | 32 | session token |
| Host response | 4 | ASCII `MRNB` |
| | 2 | bootstrap version, `1` |
| | 2 | status, `0` (accepted) or `1` (complete request, bad token) |
| | 4 | current nonzero host epoch on success; **zero** on rejection |

The host validates the shape and compares the token in constant time. A complete
well-formed request with a wrong token receives exactly twelve bytes with status
`1` and zero epoch, then the host closes it. This is a terminal authentication
rejection; neither the host epoch nor detailed rejection reasons are disclosed.
Malformed or incomplete requests may close without a response. EOF during the
client's response read is a retryable interrupted transport, **not** proof of a
bad token. The client sends ClientHello with the returned nonzero
epoch and creates the regular WireOrder for that epoch. SessionConfig must match
it. The host still validates ClientHello normally. Video starts directly with
the ordinary VideoHello inside pinned TLS; it has no extra preface.

Put these codecs/authentication operations in the Mirri protocol layer, not in
raw transport. Handle fragmented and coalesced input without dropping bytes
following a preface. No second stream buffer with unbounded retention. Apply the
existing overall handshake budget on the host, plus bounded client TCP/TLS and
preface-read deadlines. A stopped/obsolete attempt must never publish its epoch
or connections into a later attempt.

## Media and performance

Reuse the exact Mirri packetizer, capture/encode pipeline, direct-buffer receiver,
decoder, queue limits and timing instrumentation. The USB adapter remains direct
`SocketChannel` I/O. For TLS use small reusable per-connection input/output scratch
buffers to bridge `SSLSocket` streams and `ByteBuffer`; never allocate a frame-sized
heap array or per-frame scratch buffer. Separate read/write buffers permit full
duplex control traffic. This explicitly adds bounded TLS bridging copies on the
network path; do not claim zero-copy TLS or equivalent performance without
measurement. Prefer this standard TLS implementation over a custom SSLEngine
handshake/concurrency implementation in the initial version.

Register the raw socket with the attempt before connect/handshake can block, and
ensure closing it interrupts both TLS and regular reads/writes. Handshake/read
timeouts used for setup must not become a steady-state video idle timeout.

## Verification and delivery

Test actual TLS adapters with matching and mismatched pins, authenticated epoch
bootstrap including fragmentation, pending-connect/handshake closure, route retry
without ADB, and existing media/USB regressions. Use a small synthetic payload for
cross-platform TLS interoperability; no desktop capture is needed for this check.
Tests for certificate generation must exercise the production identity generator.
Do not commit private keys or real session credentials as test fixtures.

Run focused checks while implementing, then the aggregate quality gate after
parent review. Document the exact user steps, local-network permission/firewall
requirements, bootstrap limitation and validation performed. Hardware streaming,
unplug/reconnect and sustained performance remain unverified until actually run.

## Status

Decision approved after architecture commit `e6f6bf5`. Opt-in Network (USB
setup) is implemented in source: menu enumerates current non-loopback local
IPv4/interface pairs, the selected-device bootstrap uses ADB once and rejects
installed client versions below 3, then the route owns fixed-port TLS listeners
and ADB-free retry. USB remains loopback and accepts installed runtime version
2+. Host X.509 uses pinned `swift-certificates 1.21.0`, `swift-crypto 5.0.0`,
`swift-asn1 1.7.3`, with exact resolutions checked for SwiftPM and Xcode.
An in-memory P-256 key and certificate are never written to disk. Android uses
platform `SSLSocket`, exact DER SHA-256 pin and validity check; 16 KiB reusable
input/output buffers add bounded network-only copies. Network mode has no USB
reverse mappings or per-retry ADB launch.

Verification on source: Swift warnings-as-errors focused tests exercise the real
generated SecIdentity with a Network.framework loopback TLS listener (matching
and mismatching pins), fragmented/coalesced MRNB, and fake-ADB no-relaunch retry.
Android focused JVM tests check typed launch rejection, fixed MRNB bytes,
pin/trust/expiration behavior and transient handshake interruption. The
`NetworkInteropTest` JVM fixture requires `MIRRI_NETWORK_INTEROP=1` on macOS;
otherwise its two tests explicitly skip (standard Android JVM suites can run
without Swift). `tools/check_quality.sh` sets this flag so macOS aggregate
validation never silently skips interoperability.
The narrow `MirriNetworkInteropServer` SwiftPM test executable uses the same
production identity/listener/MRNB code on 127.0.0.1; a desktop-JVM test connects
through the actual Android `PinnedTlsConnector`, exchanges a 16-byte synthetic
payload and rejects a changed pin. Its private key is generated in memory per
test and is never committed or persisted. Synthetic post-setup reads have an
interrupting deadline; the helper assembles its exact payload across fragments.
This does not establish tablet TLS,
IP routing or hardware-media behavior.
After parent review, `tools/check_quality.sh` passed with the documented JDK 17
and Android SDK environment: strict Swift format/lint, SwiftPM and unsigned
Xcode app/test builds (58 tests each, two hardware-only skips), Android
format/lint/detekt/build and 53 JVM tests with no skips (including both TLS
interoperability tests), protocol fixtures, nine source-boundary probes, Python
format/lint/types/complexity checks and 14 timing/tool tests. First-party Xcode
targets opt into warnings-as-errors individually because Apple packages
intentionally pass `-suppress-warnings` (a global override conflicts). An initial
aggregate invocation without the documented Java environment failed before
Android tests under the ambient JDK; the corrected invocation passed all gates.
Actual Mac↔tablet TLS/streaming,
unplug/reconnect and sustained throughput are **unverified**; these source
checks are not evidence of physical connectivity, frame-rate or panel scanout.
