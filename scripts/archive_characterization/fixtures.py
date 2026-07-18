"""Deterministic synthetic fixtures for the DAYU200 characterization scanner.

Every fixture is built in memory from fixed bytes (gzip mtime=0), so the suite
needs no binary blobs in the repository and no disk writes at scan time. These
are negative/positive *test* vectors only: they never describe, contain or
approximate real vendor archive bytes, and a hazard fixture passing proves a
rejection branch, nothing about the fixed input.

Identity note (design.md "Fixed input gate"): each case carries its own
expected size/SHA-256 computed from its synthetic bytes so that the inner
hazard — not ARC001 — fires; the identity-mismatch case deliberately carries a
wrong expectation. This test-only mechanism lives outside the production CLI.
"""

from __future__ import annotations

import gzip
import hashlib
from typing import List, NamedTuple, Optional

TAR_BLOCK = 512

POSIX_MAGIC = b"ustar\x00" + b"00"
GNU_MAGIC = b"ustar " + b" \x00"


class FixtureCase(NamedTuple):
    name: str
    archive_bytes: bytes
    expected_size: int
    expected_sha256: str
    expected_code: Optional[str]


def _octal(value: int, width: int) -> bytes:
    return ("%0*o" % (width - 1, value)).encode("ascii") + b"\x00"


def tar_header(
    name: bytes,
    size: int,
    typeflag: bytes = b"0",
    linkname: bytes = b"",
    magic_version: bytes = POSIX_MAGIC,
    prefix: bytes = b"",
    corrupt_checksum: bool = False,
) -> bytes:
    header = bytearray(TAR_BLOCK)
    header[0 : len(name)] = name
    header[100:108] = _octal(0o644, 8)
    header[108:116] = _octal(0, 8)
    header[116:124] = _octal(0, 8)
    header[124:136] = _octal(size, 12)
    header[136:148] = _octal(0, 12)
    header[148:156] = b" " * 8
    header[156 : 156 + 1] = typeflag
    header[157 : 157 + len(linkname)] = linkname
    header[257 : 257 + len(magic_version)] = magic_version
    header[345 : 345 + len(prefix)] = prefix
    checksum = sum(header)
    header[148:156] = ("%06o" % checksum).encode("ascii") + b"\x00 "
    if corrupt_checksum:
        header[0] = (header[0] + 1) % 256
    return bytes(header)


def tar_member(name: bytes, data: bytes = b"", **header_kwargs) -> bytes:
    block = tar_header(name, len(data), **header_kwargs)
    padding = (TAR_BLOCK - len(data) % TAR_BLOCK) % TAR_BLOCK
    return block + data + b"\x00" * padding


def end_of_archive() -> bytes:
    return b"\x00" * (2 * TAR_BLOCK)


def targz(*chunks: bytes) -> bytes:
    return gzip.compress(b"".join(chunks), mtime=0)


def _identity(data: bytes) -> tuple[int, str]:
    return len(data), hashlib.sha256(data).hexdigest()


def case(name: str, data: bytes, expected_code: Optional[str]) -> FixtureCase:
    size, sha = _identity(data)
    return FixtureCase(name, data, size, sha, expected_code)


# --- Positive / classification fixtures ---------------------------------------

POSITIVE_MEMBERS = (
    (b"parameter.txt", b"P" * 64),
    (b"MiniLoaderAll.bin", b"L" * 96),
    (b"uboot.img", b"U" * 128),
    (b"boot_linux.img", b"B" * 160),
    (b"system.img", b"S" * 192),
    (b"config.cfg", b"C" * 32),
    (b"daily_build.log", b"D" * 32),
    (b"manifest_tag.xml", b"M" * 32),
    (b"updater_binary", b"X" * 48),
)


def positive_archive(
    omit: tuple = (),
    extra: tuple = (),
    zero_size: tuple = (),
) -> bytes:
    chunks = []
    for name, data in POSITIVE_MEMBERS:
        if name.decode("ascii") in omit:
            continue
        if name.decode("ascii") in zero_size:
            data = b""
        chunks.append(tar_member(name, data))
    for name, data in extra:
        chunks.append(tar_member(name, data))
    chunks.append(end_of_archive())
    return targz(*chunks)


def positive_case() -> FixtureCase:
    return case("positive-rockchip-raw-image-set", positive_archive(), None)


def empty_archive_case() -> FixtureCase:
    return case("empty-archive", targz(end_of_archive()), None)


def large_member_archive(size: int = 3 * 1048576 + 123) -> FixtureCase:
    body = (b"\x5a\xa5" * (size // 2 + 1))[:size]
    data = targz(tar_member(b"big.img", body), end_of_archive())
    return case("large-member", data, None)


def gnu_magic_case() -> FixtureCase:
    data = targz(
        tar_member(b"parameter.txt", b"P" * 8, magic_version=GNU_MAGIC),
        end_of_archive(),
    )
    return case("gnu-magic-accepted", data, None)


# --- Hazard fixtures (one per fixed code + precedence vectors) ----------------


def hazard_cases() -> List[FixtureCase]:
    ok = positive_archive()
    ok_size, _ = _identity(ok)
    cases = [
        # ARC001: valid bytes, deliberately wrong expected identity.
        FixtureCase(
            "arc001-identity-mismatch",
            ok,
            ok_size,
            "0" * 64,
            "ARC001_IDENTITY_MISMATCH",
        ),
        case("arc002-not-gzip", b"this is not a gzip stream", "ARC002_ARCHIVE_INVALID"),
        case(
            "arc002-header-checksum",
            targz(
                tar_member(b"parameter.txt", b"P" * 8, corrupt_checksum=True),
                end_of_archive(),
            ),
            "ARC002_ARCHIVE_INVALID",
        ),
        case(
            "arc002-missing-end-marker",
            targz(tar_member(b"parameter.txt", b"P" * 8)),
            "ARC002_ARCHIVE_INVALID",
        ),
        case(
            "arc002-trailer-garbage",
            targz(tar_member(b"parameter.txt", b"P" * 8), end_of_archive(), b"GARBAGE"),
            "ARC002_ARCHIVE_INVALID",
        ),
        case(
            "arc002-raw-trailing-garbage",
            targz(tar_member(b"parameter.txt", b"P" * 8), end_of_archive()) + b"XX",
            "ARC002_ARCHIVE_INVALID",
        ),
        case(
            "arc003-absolute-path",
            targz(tar_member(b"/abs.img", b"A" * 8), end_of_archive()),
            "ARC003_PATH_ABSOLUTE",
        ),
        case(
            "arc004-traversal",
            targz(tar_member(b"a/../evil.img", b"E" * 8), end_of_archive()),
            "ARC004_PATH_TRAVERSAL",
        ),
        case(
            "arc005-backslash",
            targz(tar_member(b"a\\b.img", b"I" * 8), end_of_archive()),
            "ARC005_PATH_INVALID",
        ),
        case(
            "arc006-duplicate",
            targz(
                tar_member(b"dup.img", b"1" * 8),
                tar_member(b"dup.img", b"2" * 8),
                end_of_archive(),
            ),
            "ARC006_PATH_DUPLICATE",
        ),
        case(
            "arc007-symlink",
            targz(
                tar_member(b"s.img", b"", typeflag=b"2", linkname=b"target"),
                end_of_archive(),
            ),
            "ARC007_LINK_UNSUPPORTED",
        ),
        case(
            "arc008-directory",
            targz(tar_member(b"d", b"", typeflag=b"5"), end_of_archive()),
            "ARC008_MEMBER_TYPE_UNSUPPORTED",
        ),
        case(
            "arc009-short-body",
            targz(tar_header(b"big.img", 100) + b"0123456789"),
            "ARC009_MEMBER_SIZE_MISMATCH",
        ),
        # Precedence: first failing member in physical order wins.
        case(
            "precedence-member-order",
            targz(
                tar_member(b"a/../evil.img", b"E" * 8),
                tar_member(b"/abs.img", b"A" * 8),
                end_of_archive(),
            ),
            "ARC004_PATH_TRAVERSAL",
        ),
        # Precedence: within one member, numeric code order wins (004 < 007).
        case(
            "precedence-numeric-within-member",
            targz(
                tar_member(b"a\\..\\s", b"", typeflag=b"2", linkname=b"target"),
                end_of_archive(),
            ),
            "ARC004_PATH_TRAVERSAL",
        ),
        # Precedence: framing failure after all members passed is ARC002.
        case(
            "precedence-framing-after-members",
            targz(
                tar_member(b"parameter.txt", b"P" * 8),
                b"\x00" * TAR_BLOCK,
                b"NOTZERO" + b"\x00" * (TAR_BLOCK - 7),
            ),
            "ARC002_ARCHIVE_INVALID",
        ),
    ]
    return cases


# --- Extra unit vectors used directly by test_scan.py ------------------------


def absolute_variant_cases() -> List[FixtureCase]:
    return [
        case(
            "arc003-unc-like",
            targz(tar_member(b"\\\\server\\share.img", b"A" * 8), end_of_archive()),
            "ARC003_PATH_ABSOLUTE",
        ),
        case(
            "arc003-drive-prefixed",
            targz(tar_member(b"C:\\x.img", b"A" * 8), end_of_archive()),
            "ARC003_PATH_ABSOLUTE",
        ),
    ]


def invalid_path_variant_cases() -> List[FixtureCase]:
    return [
        case(
            "arc005-dot-segment",
            targz(tar_member(b"./x.img", b"I" * 8), end_of_archive()),
            "ARC005_PATH_INVALID",
        ),
        case(
            "arc005-control-character",
            targz(tar_member(b"a\x01b.img", b"I" * 8), end_of_archive()),
            "ARC005_PATH_INVALID",
        ),
        case(
            "arc005-trailing-slash",
            targz(tar_member(b"x.img/", b"I" * 8), end_of_archive()),
            "ARC005_PATH_INVALID",
        ),
    ]
