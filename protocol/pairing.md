# Pairing and cable-free rendezvous (MRRV v1)

A tablet is paired the first time the host launches it over the cable. After
that, opening Mirri on the tablet is enough: it finds the host on the LAN,
proves it is paired, and receives a session exactly as an ADB launch would
deliver one.

## Pairing

Every ADB launch adds three Intent extras (lowercase hex):

| Extra | Bytes | Meaning |
| --- | ---: | --- |
| `mirri_pair_id` | 16 | Random pairing ID |
| `mirri_pair_key` | 32 | Random secret for this tablet |
| `mirri_pair_pin` | 32 | SHA-256 of the host's persistent rendezvous certificate (DER) |

The tablet stores them in app-private preferences together with the host's
address, and only when the same Intent is a valid network launch. The host
stores its persistent P-256 key and certificate, and per tablet only the ID,
a label and SHA-256 of the secret, in owner-only files under
`~/Library/Application Support/Mirri/Pairing/`. The eight most recent grants
are kept; pairing again simply replaces the secret the tablet holds.

## Rendezvous

The host listens on TCP 5562 (IPv4, all interfaces) with TLS 1.2+ using the
persistent certificate and advertises `_mirri._tcp` over Bonjour. The tablet
resolves that service with NSD and also tries the last host address that
worked, so a network that blocks multicast still connects. It accepts only the
pinned certificate.

All integers are big-endian. Every message starts with `MRRV`, version `0001`
and a 16-bit kind.

| Kind | Direction | Body |
| ---: | --- | --- |
| 1 hello | tablet → host | pairing ID (16), secret (32), reason (1) |
| 2 wait | host → tablet | none; repeated every 2 s while the host is alive |
| 3 launch | host → tablet | token (32), epoch (u32), host IPv4 (4), session certificate pin (32), media (1: 0 TLS/TCP, 1 WebRTC), session ID (16) |
| 4 rejected | host → tablet | none; the tablet forgets its pairing |

Reason is 0 idle (the host stopped the last session), 1 opened (a person
opened or returned to the app) or 2 recovering (the last session failed). The
host starts a session by itself only for 1 and 2, at most three times a minute,
and only when automatic connection is enabled.

An unauthenticated connection is dropped after five seconds; at most eight may
be pending. The tablet treats eight seconds without a wait frame as a lost
host and looks for it again.

## What this does and does not protect

- The tablet authenticates the host by an exact certificate pin; the host
  authenticates the tablet by a 256-bit secret sent only inside that TLS
  channel. This is the same model as a session's pinned TLS plus bearer token,
  with long-lived values.
- The first pairing still needs the cable. There is no cable-free first
  pairing.
- The host key is protected by file permissions, not the Keychain. The tablet
  secret is in app-private storage, not hardware-backed.
- Any app on the tablet that can start Mirri's exported activity can supply a
  launch, including pairing extras, and so re-point the tablet at another
  host. That exposure already existed for launches.
