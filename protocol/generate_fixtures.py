"""Offline, deterministic independent fixture author; never used by either application."""

import struct
from pathlib import Path

NAMES = [
    "client-hello",
    "session-config",
    "client-ready",
    "video-channel-hello",
    "codec-configuration",
    "video-frame",
    "start-stream",
    "stop-session",
    "input-batch",
    "scroll-gesture",
    "zoom-gesture",
    "context-click",
    "shortcut-gesture",
    "auxiliary-key",
    "ping",
    "pong",
    "client-metrics",
    "protocol-error",
    "decoder-failure",
    "request-keyframe",
    "session-rejected",
    "stop-acknowledged",
]
SCHEMAS = [
    "epoch bytes32 str64 size u32 mode list16mode list2cap inputs",
    "codec profile level size u32 u32 color port inputMode bool",
    "mode str96 size",
    "epoch bytes16 bytes32",
    "generation codec profile level color list3param",
    "generation u64 u64 frameFlags au",
    "generation",
    "stopReason",
    "u64 list64sample",
    "gesturePhase point delta delta u64",
    "gesturePhase point scale u64",
    "point contextSource u64",
    "shortcut u64",
    "u32 u32 keyPhase u64",
    "u64 u64 u64 u64",
    "u64 u64 u64 u64",
    "fps u32 fps fps mode u8 u64",
    "errorCode str128 bool",
    "errorCode",
    "generation",
    "rejectReason str128",
    "",
]
COMPOSITES = {
    "size": "dimension dimension",
    "mode": "size refresh i32",
    "profileLevel": "profile level",
    "cap": "codec list16profileLevel bool bool bool",
    "inputs": "touchCount bool bool bool bool bool",
    "point": "unit unit",
    "sample": "u32 tool pointerPhase point unit tilt orientation buttons u64",
}


def value(kind):
    if kind in COMPOSITES:
        if kind == "size":
            return struct.pack(">II", 2456, 1600)
        if kind == "mode":
            return struct.pack(">IIII", 1600, 2456, 60000, 7)
        return b"".join(value(t) for t in COMPOSITES[kind].split())
    collection = list_value(kind)
    if collection is not None:
        return collection
    special = special_value(kind)
    if special is not None:
        return special
    return scalar_value(kind)


def list_value(kind):
    for prefix in ("list16", "list2", "list3", "list64"):
        if kind.startswith(prefix):
            subtype = kind[len(prefix) :]
            count = 2 if subtype == "param" else 1
            if subtype == "param":
                return (
                    bytes([2])
                    + struct.pack(">H", 4)
                    + b"\x67\x64\x00\x33"
                    + struct.pack(">H", 3)
                    + b"\x68\xce\x00"
                )
            return bytes([count]) + value(subtype) * count
    return None


def special_value(kind):
    if kind == "bytes16":
        return bytes(range(16))
    if kind == "bytes32":
        return bytes(range(32))
    if kind == "param":
        return struct.pack(">H", 4) + b"\x67\x64\x00\x33"
    if kind == "au":
        return struct.pack(">I", 6) + b"\x00\x00\x00\x01\x65\x88"
    if kind.startswith("str"):
        raw = b"synthetic"
        return struct.pack(">H", len(raw)) + raw
    if kind in ("unit", "tilt", "orientation", "delta", "fps"):
        return struct.pack(">f", 0.5)
    if kind == "scale":
        return struct.pack(">f", 1.25)
    return None


def scalar_value(kind):
    vals = {
        "dimension": 2456,
        "refresh": 60000,
        "epoch": 1,
        "generation": 1,
        "port": 5560,
        "codec": 1,
        "profile": 1,
        "color": 1,
        "inputMode": 1,
        "touchCount": 5,
        "frameFlags": 3,
        "tool": 1,
        "pointerPhase": 4,
        "gesturePhase": 1,
        "contextSource": 1,
        "shortcut": 1,
        "keyPhase": 1,
        "stopReason": 1,
        "errorCode": 1,
        "rejectReason": 1,
        "bool": 1,
        "level": 51,
        "u32": 40_000_000,
        "u64": 0,
        "i32": 7,
    }
    size = {
        "u64": 8,
        "u32": 4,
        "epoch": 4,
        "generation": 4,
        "dimension": 4,
        "refresh": 4,
        "i32": 4,
        "port": 2,
        "level": 2,
        "buttons": 2,
    }.get(kind, 1)
    return vals.get(kind, 0).to_bytes(size, "big")


def fixture_value(index, position, part):
    if index == 1 and part == "str64":
        name = "Écran 💠".encode()
        return struct.pack(">H", len(name)) + name
    if index == 1 and part == "size":
        return struct.pack(">II", 1600, 2456)
    if index == 1 and part == "u32":
        return struct.pack(">I", 320)
    if index == 2 and position == 6:
        return struct.pack(">I", 60000)
    return value(part)


def main(destination=None):
    destination = destination or Path(__file__).parent / "fixtures"
    destination.mkdir(exist_ok=True)

    def frame(kind, payload):
        return (
            struct.pack(">4sHHHHQIQ", b"MRRI", 1, 0, kind, 0, 0, len(payload), 0)
            + payload
        )

    for index, (name, schema) in enumerate(zip(NAMES, SCHEMAS, strict=True), 1):
        if index not in (1, 4):
            schema = "bytes16 epoch " + schema
        payload = b"".join(
            fixture_value(index, position, part)
            for position, part in enumerate(schema.split())
        )
        (destination / f"{index:02d}-{name}-v1.bin").write_bytes(frame(index, payload))
    # Alternate real wire enum values, not extra message IDs.
    hevc = bytearray((destination / "02-session-config-v1.bin").read_bytes()[32:])
    hevc[20:22] = b"\x02\x02"  # codec/profile Main
    hevc[22:24] = struct.pack(">H", 153)  # HEVC Level 5.1
    hevc[36:40] = struct.pack(">I", 25_000_000)
    (destination / "23-session-config-hevc-v1.bin").write_bytes(frame(2, hevc))
    sets = [b"\x40\x01", b"\x42\x01", b"\x44\x01"]
    hevc_config = (
        value("bytes16")
        + value("epoch")
        + value("generation")
        + b"\x02\x02"
        + struct.pack(">H", 153)
        + b"\x01"
        + bytes([len(sets)])
        + b"".join(struct.pack(">H", len(s)) + s for s in sets)
    )
    (destination / "24-codec-configuration-hevc-v1.bin").write_bytes(
        frame(5, hevc_config)
    )


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description="Generate synthetic wire fixtures")
    parser.add_argument(
        "--output",
        type=Path,
        help="alternate output directory (does not alter committed fixtures)",
    )
    main(parser.parse_args().output)
