"""Deterministic in-memory fixtures for the partition decoder tests."""

from __future__ import annotations

import gzip
import hashlib
from typing import NamedTuple, Optional


TAR_BLOCK = 512
POSIX_MAGIC = b"ustar\x00" + b"00"


class FixtureCase(NamedTuple):
    archive_bytes: bytes
    expected_size: int
    expected_sha256: str
    parameter_size: int
    parameter_sha256: str


def _octal(value: int, width: int) -> bytes:
    return ("%0*o" % (width - 1, value)).encode("ascii") + b"\x00"


def tar_header(name: bytes, size: int, typeflag: bytes = b"0", corrupt=False) -> bytes:
    header = bytearray(TAR_BLOCK)
    header[0 : len(name)] = name
    header[100:108] = _octal(0o644, 8)
    header[108:116] = _octal(0, 8)
    header[116:124] = _octal(0, 8)
    header[124:136] = _octal(size, 12)
    header[136:148] = _octal(0, 12)
    header[148:156] = b" " * 8
    header[156:157] = typeflag
    header[257:265] = POSIX_MAGIC
    checksum = sum(header)
    header[148:156] = ("%06o" % checksum).encode("ascii") + b"\x00 "
    if corrupt:
        header[0] = (header[0] + 1) % 256
    return bytes(header)


def tar_member(name: bytes, body: bytes, typeflag: bytes = b"0") -> bytes:
    padding = (TAR_BLOCK - len(body) % TAR_BLOCK) % TAR_BLOCK
    return tar_header(name, len(body), typeflag=typeflag) + body + b"\x00" * padding


def parameter_text(cmdline: Optional[str] = None, extra: str = "") -> bytes:
    cmdline = cmdline or (
        "mtdparts=rk29xxnand:0x10@0x20(boot),"
        "0x30@0x40(system:bootable),-@0x70(userdata:grow)"
    )
    return (
        "FIRMWARE_VER:1.0\n"
        "PRIVATE_NOTE:TOP_SECRET_PARAMETER_RAW_VALUE\n"
        f"CMDLINE:{cmdline}\n"
        f"{extra}"
    ).encode("utf-8")


def archive(parameter: Optional[bytes] = None, include_parameter=True) -> FixtureCase:
    parameter = parameter if parameter is not None else parameter_text()
    chunks = [tar_member(b"before.img", b"NON_PARAMETER_MEMBER_SECRET" * 8)]
    if include_parameter:
        chunks.append(tar_member(b"parameter.txt", parameter))
    chunks.append(tar_member(b"after.img", b"AFTER_PARAMETER_SECRET" * 8))
    chunks.append(b"\x00" * (2 * TAR_BLOCK))
    raw = gzip.compress(b"".join(chunks), mtime=0)
    return FixtureCase(
        raw,
        len(raw),
        hashlib.sha256(raw).hexdigest(),
        len(parameter),
        hashlib.sha256(parameter).hexdigest(),
    )


def inventory() -> dict:
    paths = (
        "parameter.txt",
        "MiniLoaderAll.bin",
        "boot.img",
        "system.img",
        "user-data.img",
        "config.cfg",
    )
    return {
        "archiveSha256": (
            "fc7637f34a8394847b1b6c7e7ff2750863d18c6dc05e184abaf5aed70ec75280"
        ),
        "memberCount": len(paths),
        "members": [
            {
                "index": index,
                "path": path,
                "sha256": hashlib.sha256(path.encode("utf-8")).hexdigest(),
            }
            for index, path in enumerate(paths)
        ],
    }
