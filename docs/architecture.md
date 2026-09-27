# Streaming architecture

## Decision and scope

Mirri has three independent concerns: acquiring a connection, speaking a streaming
protocol, and processing media. USB reverse forwarding and a secured IP connection
can carry the same Mirri protocol. Miracast and Chromecast are different protocols
and session models; they are not additional socket implementations.

The first restructuring preserves the existing USB wire format and observable
behavior. Network connectivity follows in a separate, verified change. This
document describes the ownership boundaries; implementation status is recorded below.

## Ownership and dependencies

```
Host application / composition
  USB device service -> ADB discovery, installation and reverse-map ownership
  Mirri session coordinator
    connection route -> bounded control/video listeners + client bootstrap
    Mirri protocol -> framing, authentication, negotiation, sequence/epoch checks
    display + input services
    capture/encode pipeline -> bounded encoded writer -> encoded-media sink
                                                        |
                                         Mirri packetizer -> byte connection

Android application / launch boundary
  validated launch -> connection connector
  Mirri session controller -> attempt owner
    Mirri control channel -> byte connection
    Mirri video receiver  -> byte connection
                          -> encoded-video consumer -> hardware decoder/surface
```

Dependency direction is from composition and session orchestration toward owning
services and contracts. Byte transport must not import the Mirri wire codec or
session message types. Capture and encoding must not know session IDs, epochs,
wire messages, ADB, or sockets. Mirri packetization and parsing own those details.
The platform decoder must not depend on socket or Mirri framing implementations.
Do not introduce a generic session framework or speculative protocol plugins.

### Host connection route

The coordinator starts with a route, not an ADB device. A route owns transport
preparation, client bootstrap for an attempt, listener replacement on retry, and
final route cleanup. It exposes a display label and accepts typed attempt
credentials (token, session identity where needed, epoch). The USB implementation
owns the ADB device, reverse mappings, required installed-client version checks,
loopback endpoints and launch intent. Discovery and APK installation belong to a
USB device service composed by the application, not the streaming coordinator.

The coordinator remains the sole owner of streaming state, handshake deadlines,
incarnation/epoch validity, media resources, input release, display grace, and
stop completion. Moving route mechanics must not move these lifecycle decisions
into competing owners. All newly created resources must join their route/attempt
before an asynchronous suspension can orphan them. Closing a route must interrupt
pending accepts; stale preparation/bootstrap completions must not recreate it.
Stop joins cleanup, including preparation still in progress. Retry never races
the old attempt's capture or decoder teardown.

### Byte transport versus Mirri channels

On macOS, the Network-framework adapter owns connection start, byte reads,
writes, and physical close. The Mirri connection owns framing and outbound wire
sequence. Keep bounded write admission and the two-second write deadline; a
timeout closes the connection and wakes pending operations. A byte-listener
contract permits USB and a later authenticated network route to provide the same
kind of byte connection without session knowledge.

On Android, a byte connection reads and writes caller-supplied `ByteBuffer`s and
closes synchronously to interrupt blocking I/O. The TCP connector registers the
raw resource with the attempt before connect or dispatcher handoff. The attempt
resource owner is transport-neutral: cancellation must close pending connects
and authenticated connections alike. Mirri control framing and video hello move
out of the raw-transport package. No consumer obtains a raw `SocketChannel`.
The launch boundary validates endpoint and credential fields once, producing a
typed launch/connector input; the session controller does not parse Intent extras.

### Encoded-media boundary

The host pipeline owns capture, hardware encode, admission and the FIFO encoded
writer. A small encoded-media sink contract accepts an `EncodedUnit` and its
stream-local ordinal asynchronously. Completion means the sink has finished
using the unit and its bounded downstream write has completed, not merely that
the unit entered another queue. The Mirri sink emits codec configuration before
the first frame and owns session identity, epoch, generation and wire flags.
It must not own a second admission queue. The pipeline retains send metrics and
recycles the encoded storage only after sink completion.

The Android Mirri receiver owns wire validation and reads access units directly
into pooled direct buffers. It submits through a narrow media-consumer contract
(configuration submission, access-unit submission and discontinuity flush).
The hardware decoder implements that contract. Buffer ownership remains with
the lease until submission returns. Do not allocate an intermediate per-frame
array or copy into a generic message object to make the boundary look uniform.
Codec discovery and Surface lifecycle remain explicit platform services.

The protocol models may use neutral media types such as codec and parameter sets;
media code must not depend on negotiated Mirri session configuration. Extract a
small media configuration value rather than passing the entire session contract.

## Preservation requirements

* Four host admission credits, held from capture admission through completed
  downstream write; no unbounded task creation or implicit buffering.
* ScreenCaptureKit queue depth two, native cadence (`minimumFrameInterval = .zero`),
  exact 2456×1600 NV12 capture, existing hardware encoder/GOP/latency settings.
* Existing Android decoder operating rate and low-latency configuration, bounded
  direct-buffer pool, reusable video metadata, freshness and discontinuity rules.
* Independent control/video channels, ordered control writes and the finite
  128-entry Android control queue. Input/lifecycle congestion is not silent loss.
* Authenticate before display/input activation; validate both channel identities;
  enforce monotonic sequences, host-authoritative epochs and codec generations.
* One first-failure transition per attempt, immediate interruption of pending I/O,
  old callbacks isolated to their attempt, bounded reconnect grace and joined stop.
* Existing timing windows and stage meanings. Refactoring is not evidence of
  improved frame rate or panel presentation; hardware performance remains a
  separate measurement.

## Network phase

IP streaming must reuse the route, Mirri protocol, media pipeline and decoder
above. It is opt-in; USB must remain loopback-only. Do not expose the current
cleartext bearer token on a LAN or silently bind all interfaces. Network mode
needs authenticated encryption, explicit endpoint selection and secure bootstrap
of peer identity. Reconnect needs host-authoritative epoch discovery over that
authenticated path rather than depending on an ADB relaunch after cable removal.
Authentication and connection deadlines apply before expensive media setup.
No certificate bypass, plaintext fallback or credential logging is acceptable.

A shared Wi-Fi network or hotspot is IP connectivity, not proof of Wi-Fi Direct.
Standard Wi-Fi Direct interoperability between this macOS host and Android must
be established before advertising that mode. Apple peer-to-peer networking is
not automatically compatible with Android Wi-Fi P2P. Initial secure IP support
must state its actual topology and any USB-bootstrap requirement clearly.

## Future protocol adapters

Miracast requires its own discovery, negotiation, media packetization and control
path; Chromecast may use receiver applications and different buffering/display
semantics. Reuse neutral media capabilities and platform services where their
contracts match. Neither future adapter should inherit Mirri's exact-tablet
handshake, input protocol, session IDs or frame encoding by accident. Add such an
adapter only with concrete requirements, not empty implementations now.

## Enforcement and verification

Use a small source-dependency check in the quality entry point to enforce the
boundaries that a single platform build target cannot express. Enumerate the
allowed directions rather than maintaining a broad exception list. Keep normal
compiler, lint, complexity and test gates strict.

Tests belong at the owner: in-memory byte fragmentation/close exercises actual
Mirri framing; fake route operations exercise lifecycle interruption and cleanup;
a delayed/failing encoded sink exercises admission lifetime and bounded teardown;
Android connector cancellation exercises ownership before connection delivery.
Retain the existing wire fixtures and direct-buffer tests. Do not duplicate the
production implementation in a test harness.

## Implementation status

* Source quality and complexity gates: implemented and verified in `a518fd2`.
* Host route/device split: `USBDeviceService` owns discovery, installation,
  explicit reverse cleanup and one active route at a time. `USBConnectionRoute`
  owns the installed-version preflight, ADB reverse leases, loopback listeners,
  attempt bootstrap and interruption; `SessionCoordinator.start(route:)` owns
  permission, handshake, display, media, retries and joined stop. The route is
  installed in the coordinator before the first suspension. `close()` marks it
  closed before awaiting every in-flight ADB preflight, reverse install or client
  launch, then removes owned reverse mappings; concurrent close calls join it.
  A pending command cannot publish resources after Stop. AppDelegate checks
  idle/failed state for maintenance, and the service excludes simultaneous
  maintenance and route creation. AppDelegate retains one pending start until
  its task exits; cancelled starts are rejected by the coordinator before
  claiming state, even if Stop ran while still idle. Late accepted control and
  video byte connections are validated against their incarnation/epoch before
  publication and closed if stale. Handshake expiry snapshots old resources
  before interrupting their route; retry teardown is registered before awaiting
  route interruption so Stop joins it.
* Host byte/media split: `ByteConnection`/`BoundedByteListener` and
  `NetworkByteConnection` own only ordered bytes, raw socket cancellation and
  the two-second write deadline. The byte adapter delivers final nonempty data
  once before reporting EOF on the next read, and its listener rejects a
  concurrent accept rather than replacing the waiting reader. `WireConnection`, `WireFramer` and
  `MirriVideoSink` own Mirri framing, sequences, configuration and flags.
  `CapturePipeline` receives `EncodingSettings` and an `EncodedVideoSink`;
  `VideoSender` retains the four-credit FIFO until the sink write completes,
  recycles storage afterward and joins its in-flight writer on stop. No
  additional per-frame admission queue was added.
* Android split: `ClientLaunchBoundary` validates Intent credentials/ports once
  into `ClientLaunch`/`ClientEndpoint` and the loopback connector.
  `AttemptConnections` owns `ByteConnection` resources before TCP connect or
  dispatcher delivery. `LoopbackTcpConnector` alone holds `SocketChannel`;
  `ControlChannel`/`VideoChannel` and `VideoReceiver` live in the Mirri protocol
  package. `VideoReceiver` still reads directly into `EncodedBufferPool`'s
  direct buffers; `EncodedVideoConsumer` is implemented by `DecoderController`
  without media services importing Mirri wire/config types.
* Source direction checks: `tools/check_source_boundaries.sh` and nine targeted
  forbidden-dependency probes in `tools/test_source_boundaries.sh` run in the
  aggregate quality gate. The guard prevents `SessionCoordinator` from importing
  Network or naming ADB/raw-loopback implementations. In-memory byte-fragment
  tests, real loopback final-byte/EOF and concurrent-accept tests, fake route/ADB
  stop and late-delivery tests, delayed/failing sink tests, TCP cancellation
  tests and direct-buffer consumer tests exercise boundaries without a device.
* USB performance and physical panel behavior after restructuring have **not**
  been measured; original capture/encoder/decoder settings remain unchanged.
* Opt-in Network (USB setup) source implementation: `NetworkConnectionRoute`
  shares bounded listener/byte transport, while `NetworkIdentity` supplies an
  ephemeral pinned TLS identity; `NetworkBootstrap` handles authenticated
  control epoch discovery above transport. Android's validated launch selects
  the pinned `SSLSocket` connector or unchanged USB connector. See
  [network decision, setup and verification](network-streaming.md). Source and
  loopback checks do not establish actual tablet/network performance.
* Wi-Fi Direct, Miracast and Chromecast: not claimed as supported.
