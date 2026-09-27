"""Bounded localhost-only synthetic TCP throughput probe (not ADB or video)."""

import argparse
import socket
import threading
import time


def run(megabytes: int, chunk_kib: int) -> None:
    size = megabytes * 1024 * 1024
    payload = b"\x5a" * (chunk_kib * 1024)
    with socket.socket() as server:
        server.bind(("127.0.0.1", 0))
        server.listen(1)
        port = server.getsockname()[1]
        result: list[int] = []

        def receive() -> None:
            with server.accept()[0] as connection:
                count = 0
                while count < size:
                    block = connection.recv(min(len(payload), size - count))
                    if not block:
                        break
                    count += len(block)
                result.append(count)

        worker = threading.Thread(target=receive)
        worker.start()
        start = time.monotonic()
        with socket.create_connection(("127.0.0.1", port), timeout=10) as client:
            client.settimeout(10)
            for offset in range(0, size, len(payload)):
                client.sendall(payload[: min(len(payload), size - offset)])
        worker.join(timeout=10)
        if worker.is_alive() or result != [size]:
            raise RuntimeError("synthetic loopback transfer incomplete")
        seconds = time.monotonic() - start
        print(
            f"localhost synthetic only: {megabytes} MiB in {seconds:.3f}s; "
            f"{size * 8 / seconds / 1e6:.1f} Mbit/s (not USB/ADB/video fps)"
        )


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--mebibytes", type=int, default=16, choices=range(1, 257), metavar="1..256"
    )
    parser.add_argument(
        "--chunk-kib", type=int, default=64, choices=range(1, 1025), metavar="1..1024"
    )
    options = parser.parse_args()
    run(options.mebibytes, options.chunk_kib)
