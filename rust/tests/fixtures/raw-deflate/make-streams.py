#!/usr/bin/env python3
"""Writes the raw DEFLATE streams in `streams/` and `streams.json`.

The Windows raw DEFLATE decoder (`arkdeck-platform`, TASK-XPA-010) replays
them: each stream must decode to exactly the plaintext recorded for it. Every
stream is zlib's own raw DEFLATE (`wbits = -15`) of one plaintext, with the
compression level and strategy that give it fixed-code and dynamic-code
blocks, long and overlapping (run-length) matches, and more than one
1 MiB output window.

The plaintext is made here, not checked in: a deterministic mix of repeated
text, a byte run and pseudo-random bytes (a 64-bit LCG), recorded by its
length and SHA-256. The streams are checked in. This script records how they
were made; the bytes, not the script, are the replay's input.
"""
import hashlib
import json
import os
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "streams")


def plaintext() -> bytes:
    parts = []
    parts.append(b"hello, flash bundle\n" * 20000)
    parts.append(b"\x00" * 300000)
    state = 0x243F6A8885A308D3
    noise = bytearray()
    for _ in range(20000):
        state = (state * 6364136223846793005 + 1442695040888963407) % (1 << 64)
        noise.append(state >> 56)
    parts.append(bytes(noise))
    parts.append(b"".join(b"line %06d of the partition table\n" % i for i in range(12000)))
    return b"".join(parts)


STREAMS = [
    ("level1.deflate", 1, zlib.Z_DEFAULT_STRATEGY),
    ("level9.deflate", 9, zlib.Z_DEFAULT_STRATEGY),
    ("fixed.deflate", 6, zlib.Z_FIXED),
    ("rle.deflate", 6, zlib.Z_RLE),
]


def main() -> None:
    data = plaintext()
    os.makedirs(OUT, exist_ok=True)
    for name, level, strategy in STREAMS:
        encoder = zlib.compressobj(level, zlib.DEFLATED, -15, 9, strategy)
        stream = encoder.compress(data) + encoder.flush()
        with open(os.path.join(OUT, name), "wb") as file:
            file.write(stream)
    with open(os.path.join(HERE, "streams.json"), "w", encoding="utf-8", newline="\n") as file:
        json.dump(
            {
                "plaintextBytes": len(data),
                "plaintextSha256": hashlib.sha256(data).hexdigest(),
                "streams": [name for name, _, _ in STREAMS],
                "zlib": zlib.ZLIB_VERSION,
            },
            file,
            indent=2,
        )
        file.write("\n")


if __name__ == "__main__":
    main()
