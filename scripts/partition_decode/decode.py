"""Read-only DAYU200 ``parameter.txt`` partition decoder.

CHG-2026-009 / TASK-PD-001. Python standard library only. The production
entry point accepts exactly the archive identity characterized by archived
CHG-2026-003, streams to ``parameter.txt`` without extracting any member,
checks that member's archived size/hash, parses a closed CMDLINE/mtdparts
grammar, and reconciles decoded partition names with the archived 17-member
inventory.

The decoder has no process, network, HDC, vendor-tool or transport code path.
Its path-based archive open cannot prove absolute zero device access across an
adversarial lstat/open replacement race; that accepted boundary remains
blocked. Non-parameter member spans needed to reach the target tar header are
stream-discarded without being returned to the text decoder or retained. The
archive locator and the original parameter text never enter evidence.
"""

from __future__ import annotations

import argparse
import dataclasses
import gzip
import hashlib
import io
import json
import os
import re
import stat
import sys
from typing import BinaryIO, List, NamedTuple, Optional, Sequence, Union


EXPECTED_RAW_SIZE = 732948803
EXPECTED_RAW_SHA256 = "fc7637f34a8394847b1b6c7e7ff2750863d18c6dc05e184abaf5aed70ec75280"
EXPECTED_PARAMETER_SIZE = 788
EXPECTED_PARAMETER_SHA256 = (
    "35464e3f0b883a8a043dd45ae7ab2342c86b7aa27f24aa1e5a0ccfb6f442d048"
)
EXPECTED_INVENTORY_SHA256 = (
    "429763e6fabcaaa2f7323eab862fdb8c65d63ecc88afb441a36073ee5c35818c"
)

MAX_READ_CHUNK = 1048576
TAR_BLOCK = 512
PARAMETER_MEMBER = "parameter.txt"
SOURCE_OPEN_FLAGS = os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW | os.O_CLOEXEC
EXPECTED_PYTHON_VERSION = "3.14.6"
EXPECTED_DECOMPRESSED_BYTES_TO_PARAMETER = 178174740
EXPECTED_TAR_HEADERS_INSPECTED = 8
EXPECTED_NON_PARAMETER_SPANS_DISCARDED = 7
EXPECTED_NON_PARAMETER_CONTENT_BYTES_READ = 178168731
EXPECTED_GZIP_PASS_RAW_BYTES_READ = 17956874
EXPECTED_REGULAR_FILE_GATE_CHECKS = 4

PD001_IDENTITY_MISMATCH = "PD001_IDENTITY_MISMATCH"
PD002_ARCHIVE_INVALID = "PD002_ARCHIVE_INVALID"
PD003_PARAMETER_MISSING = "PD003_PARAMETER_MISSING"
PD004_PARAMETER_MEMBER_INVALID = "PD004_PARAMETER_MEMBER_INVALID"
PD005_PARAMETER_TEXT_INVALID = "PD005_PARAMETER_TEXT_INVALID"
PD006_CMDLINE_MISSING = "PD006_CMDLINE_MISSING"
PD007_CMDLINE_DUPLICATE = "PD007_CMDLINE_DUPLICATE"
PD008_CMDLINE_INVALID = "PD008_CMDLINE_INVALID"
PD009_PARTITION_INVALID = "PD009_PARTITION_INVALID"
PD010_PARTITION_DUPLICATE = "PD010_PARTITION_DUPLICATE"
PD011_INVENTORY_INVALID = "PD011_INVENTORY_INVALID"
PD012_SOURCE_NOT_STABLE_REGULAR_FILE = "PD012_SOURCE_NOT_STABLE_REGULAR_FILE"

FAILURE_CODES = (
    PD001_IDENTITY_MISMATCH,
    PD002_ARCHIVE_INVALID,
    PD003_PARAMETER_MISSING,
    PD004_PARAMETER_MEMBER_INVALID,
    PD005_PARAMETER_TEXT_INVALID,
    PD006_CMDLINE_MISSING,
    PD007_CMDLINE_DUPLICATE,
    PD008_CMDLINE_INVALID,
    PD009_PARTITION_INVALID,
    PD010_PARTITION_DUPLICATE,
    PD011_INVENTORY_INVALID,
    PD012_SOURCE_NOT_STABLE_REGULAR_FILE,
)

EVIDENCE_OUTPUTS = (
    "partition-mapping.json",
    "member-reconciliation.json",
    "process-audit.json",
    "summary.md",
)

_REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
_INVENTORY_RELATIVE = (
    "openspec/changes/archive/2026-07-18-chg-2026-003-dayu200-image-"
    "characterization/evidence/member-inventory.json"
)
_INVENTORY_PATH = os.path.join(_REPO_ROOT, _INVENTORY_RELATIVE)
_ROUTE_PLAN_REFERENCE = (
    "openspec/changes/chg-2026-007-dayu200-flash-route-planning/evidence/"
    "route-b-plan.md#gap-dayu200-partition-semantics分区表语义"
)

S2_SOURCE_CITATIONS = (
    {
        "id": "S2-LINUX-CMDLINEPART",
        "title": "Linux kernel command-line partition parser",
        "url": (
            "https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/"
            "tree/drivers/mtd/parsers/cmdlinepart.c"
        ),
        "scope": "mtdparts size/offset/name grammar background",
    },
    {
        "id": "S2-ROCKCHIP-RKBIN",
        "title": "Rockchip official rkbin repository",
        "url": "https://github.com/rockchip-linux/rkbin",
        "scope": "Rockchip image-package and parameter context",
    },
    {
        "id": "S2-ROCKCHIP-RKDEVELOPTOOL",
        "title": "Rockchip official rkdeveloptool repository",
        "url": "https://github.com/rockchip-linux/rkdeveloptool",
        "scope": "Rockchip partition/tooling context; no write behavior inferred",
    },
    {
        "id": "S2-OPENHARMONY-DOCS",
        "title": "OpenHarmony official device-development documentation repository",
        "url": "https://gitcode.com/openharmony/docs",
        "scope": "DAYU200/OpenHarmony device-porting context",
    },
)

# Closed facts for the single pinned parameter member. These are intentionally
# duplicated as validation constants: evidence claiming the pinned identity is
# rejected unless its complete decoded partition set matches the observed run.
EXPECTED_PARTITION_FACTS = (
    ("uboot", "0x00002000", "0x00002000", None),
    ("misc", "0x00002000", "0x00004000", None),
    ("bootctrl", "0x00001000", "0x00006000", None),
    ("resource", "0x00003000", "0x00007000", None),
    ("boot_linux", "0x00030000", "0x0000A000", "bootable"),
    ("ramdisk", "0x00002000", "0x0003A000", None),
    ("system", "0x00400000", "0x0003C000", None),
    ("vendor", "0x00200000", "0x0043C000", None),
    ("sys-prod", "0x00019000", "0x0063C000", None),
    ("chip-prod", "0x00019000", "0x00655000", None),
    ("updater", "0x00010000", "0x0066E000", None),
    ("eng_system", "0x00008000", "0x0067E000", None),
    ("eng_chipset", "0x00008000", "0x00686000", None),
    ("chip_ckm", "0x00020000", "0x0069E000", None),
    ("userdata", "-", "0x01308000", "grow"),
)

_FIELD_KEY = re.compile(r"[A-Za-z][A-Za-z0-9_]*")
_CMDLINE = re.compile(
    r"mtdparts=(?P<device>[A-Za-z0-9][A-Za-z0-9._-]*):(?P<entries>\S+)"
)
_PARTITION = re.compile(
    r"(?P<size>-|0x[0-9A-Fa-f]+)@"
    r"(?P<offset>0x[0-9A-Fa-f]+)"
    r"\((?P<name>[A-Za-z0-9][A-Za-z0-9._-]*)"
    r"(?::(?P<attribute>[A-Za-z][A-Za-z0-9._-]*))?\)"
)
_ALLOWED_ATTRIBUTES = frozenset({"bootable", "grow"})
_GZIP_ERRORS = (OSError, EOFError, gzip.BadGzipFile)


class DecodeFailure(Exception):
    """Terminal, fail-closed input rejection with a stable code."""

    def __init__(self, code: str, context: str = ""):
        if code not in FAILURE_CODES:
            raise ValueError(f"unknown failure code: {code}")
        self.code = code
        self.context = context
        super().__init__(f"{code}: {context}" if context else code)


class DecodeToolError(Exception):
    """Usage/evidence-write error outside the decoded input contract."""


class EvidenceValidationError(Exception):
    """A generated evidence document violates its closed invariants."""


@dataclasses.dataclass
class DecodeAudit:
    raw_bytes_read: int = 0
    identity_pass_raw_bytes_read: int = 0
    gzip_pass_raw_bytes_read: int = 0
    decompressed_bytes_streamed: int = 0
    parameter_bytes_returned_to_decoder: int = 0
    max_observed_read_chunk: int = 0
    tar_headers_inspected: int = 0
    non_parameter_member_spans_stream_discarded: int = 0
    non_parameter_member_contents_read: int = 0
    non_parameter_member_content_bytes_read: int = 0
    archive_open_modes: List[str] = dataclasses.field(default_factory=list)
    archive_source_kind: Optional[str] = None
    source_stat_snapshot: Optional[tuple] = None
    regular_file_gate_checks: int = 0
    evidence_files_written: List[str] = dataclasses.field(default_factory=list)
    writes_outside_allowed_outputs: int = 0


class PartitionRow(NamedTuple):
    index: int
    name: str
    size_encoded: str
    size_value: Optional[int]
    offset_encoded: str
    offset_value: int
    attribute: Optional[str]
    grammar_branch: str


Source = Union[str, os.PathLike, io.BytesIO]


class _AuditedRawStream:
    """Count every compressed byte returned by one named archive pass."""

    def __init__(self, stream: BinaryIO, audit: DecodeAudit, pass_name: str):
        if pass_name not in ("identity", "gzip"):
            raise ValueError("unknown raw-read pass")
        self._stream = stream
        self._audit = audit
        self._pass_name = pass_name

    def _record(self, amount: int) -> None:
        self._audit.raw_bytes_read += amount
        if self._pass_name == "identity":
            self._audit.identity_pass_raw_bytes_read += amount
        else:
            self._audit.gzip_pass_raw_bytes_read += amount
        self._audit.max_observed_read_chunk = max(
            self._audit.max_observed_read_chunk, amount
        )

    def read(self, amount: int = -1) -> bytes:
        if amount < 0 or amount > MAX_READ_CHUNK:
            raise DecodeFailure(PD002_ARCHIVE_INVALID, "unbounded raw read")
        payload = self._stream.read(amount)
        self._record(len(payload))
        return payload

    def readinto(self, buffer) -> int:
        if len(buffer) > MAX_READ_CHUNK:
            raise DecodeFailure(PD002_ARCHIVE_INVALID, "unbounded raw readinto")
        amount = self._stream.readinto(buffer)
        amount = 0 if amount is None else amount
        self._record(amount)
        return amount

    def seek(self, offset: int, whence: int = io.SEEK_SET) -> int:
        return self._stream.seek(offset, whence)

    def tell(self) -> int:
        return self._stream.tell()

    def fileno(self) -> int:
        return self._stream.fileno()


def _is_regular_file_mode(mode: int) -> bool:
    return stat.S_ISREG(mode)


def _stat_snapshot(file_stat) -> tuple:
    return (
        file_stat.st_dev,
        file_stat.st_ino,
        file_stat.st_mode,
        file_stat.st_size,
        file_stat.st_mtime_ns,
        file_stat.st_ctime_ns,
    )


def _open_source(src: Source, audit: DecodeAudit) -> BinaryIO:
    if isinstance(src, io.BytesIO):
        src.seek(0)
        audit.archive_open_modes.append("memory-ro")
        audit.archive_source_kind = "memoryFixture"
        return src

    locator = os.fspath(src)
    try:
        before_open = os.lstat(locator)
    except OSError:
        raise DecodeFailure(PD012_SOURCE_NOT_STABLE_REGULAR_FILE) from None
    audit.regular_file_gate_checks += 1
    if not _is_regular_file_mode(before_open.st_mode):
        raise DecodeFailure(PD012_SOURCE_NOT_STABLE_REGULAR_FILE)

    descriptor = None
    try:
        descriptor = os.open(locator, SOURCE_OPEN_FLAGS)
        after_open = os.fstat(descriptor)
        audit.regular_file_gate_checks += 1
        if (
            not _is_regular_file_mode(after_open.st_mode)
            or _stat_snapshot(after_open) != _stat_snapshot(before_open)
        ):
            raise DecodeFailure(PD012_SOURCE_NOT_STABLE_REGULAR_FILE)
        handle = os.fdopen(descriptor, "rb", closefd=True)
        descriptor = None
    except DecodeFailure:
        if descriptor is not None:
            os.close(descriptor)
        raise
    except OSError:
        if descriptor is not None:
            os.close(descriptor)
        raise DecodeFailure(PD012_SOURCE_NOT_STABLE_REGULAR_FILE) from None
    audit.archive_open_modes.append("rb")
    audit.archive_source_kind = "regularFile"
    audit.source_stat_snapshot = _stat_snapshot(after_open)
    return handle


def _assert_source_stable(stream: BinaryIO, audit: DecodeAudit) -> None:
    if audit.archive_source_kind == "memoryFixture":
        return
    try:
        current = os.fstat(stream.fileno())
    except OSError:
        raise DecodeFailure(PD012_SOURCE_NOT_STABLE_REGULAR_FILE) from None
    audit.regular_file_gate_checks += 1
    if (
        not _is_regular_file_mode(current.st_mode)
        or _stat_snapshot(current) != audit.source_stat_snapshot
    ):
        raise DecodeFailure(PD012_SOURCE_NOT_STABLE_REGULAR_FILE)


def _read_bounded(stream: BinaryIO, amount: int, audit: DecodeAudit) -> bytes:
    parts = []
    remaining = amount
    while remaining > 0:
        chunk = stream.read(min(remaining, MAX_READ_CHUNK))
        if not chunk:
            break
        audit.max_observed_read_chunk = max(audit.max_observed_read_chunk, len(chunk))
        remaining -= len(chunk)
        parts.append(chunk)
    return b"".join(parts)


def _hash_raw(stream: BinaryIO, audit: DecodeAudit) -> tuple[int, str]:
    digest = hashlib.sha256()
    total = 0
    while True:
        chunk = stream.read(MAX_READ_CHUNK)
        if not chunk:
            break
        audit.max_observed_read_chunk = max(audit.max_observed_read_chunk, len(chunk))
        total += len(chunk)
        digest.update(chunk)
    return total, digest.hexdigest()


def _read_gzip_exact(gz: gzip.GzipFile, amount: int, audit: DecodeAudit) -> bytes:
    try:
        payload = _read_bounded(gz, amount, audit)
    except _GZIP_ERRORS:
        raise DecodeFailure(PD002_ARCHIVE_INVALID, "gzip framing") from None
    audit.decompressed_bytes_streamed += len(payload)
    if len(payload) != amount:
        raise DecodeFailure(PD002_ARCHIVE_INVALID, "short tar span")
    return payload


def _discard_gzip_exact(gz: gzip.GzipFile, amount: int, audit: DecodeAudit) -> None:
    remaining = amount
    while remaining > 0:
        chunk = _read_gzip_exact(gz, min(remaining, MAX_READ_CHUNK), audit)
        remaining -= len(chunk)


def _parse_tar_octal(field: bytes) -> int:
    if field and field[0] & 0x80:
        raise DecodeFailure(PD002_ARCHIVE_INVALID, "base-256 tar numeric field")
    text = field.strip(b" \x00")
    if not text:
        raise DecodeFailure(PD002_ARCHIVE_INVALID, "empty tar numeric field")
    try:
        return int(text, 8)
    except ValueError:
        raise DecodeFailure(PD002_ARCHIVE_INVALID, "malformed tar numeric field") from None


def _tar_name(header: bytes) -> str:
    def terminated(field: bytes) -> bytes:
        return field.split(b"\x00", 1)[0]

    name = terminated(header[0:100])
    magic = header[257:265]
    if magic == b"ustar\x0000":
        prefix = terminated(header[345:500])
        if prefix:
            name = prefix + b"/" + name
    elif magic != b"ustar  \x00":
        raise DecodeFailure(PD002_ARCHIVE_INVALID, "unsupported tar magic")
    try:
        return name.decode("utf-8", errors="strict")
    except UnicodeDecodeError:
        raise DecodeFailure(PD002_ARCHIVE_INVALID, "non-UTF-8 tar member name") from None


def _read_parameter_member(gz: gzip.GzipFile, audit: DecodeAudit) -> bytes:
    while True:
        header = _read_gzip_exact(gz, TAR_BLOCK, audit)
        if header == b"\x00" * TAR_BLOCK:
            raise DecodeFailure(PD003_PARAMETER_MISSING)
        audit.tar_headers_inspected += 1

        stored_checksum = _parse_tar_octal(header[148:156])
        computed_checksum = sum(header[:148]) + sum(b" " * 8) + sum(header[156:])
        if stored_checksum != computed_checksum:
            raise DecodeFailure(PD002_ARCHIVE_INVALID, "tar header checksum")
        size = _parse_tar_octal(header[124:136])
        name = _tar_name(header)
        typeflag = header[156:157]

        if name == PARAMETER_MEMBER:
            if typeflag not in (b"0", b"\x00"):
                raise DecodeFailure(PD004_PARAMETER_MEMBER_INVALID, "not regular")
            payload = _read_gzip_exact(gz, size, audit)
            audit.parameter_bytes_returned_to_decoder += len(payload)
            if size != EXPECTED_PARAMETER_SIZE:
                raise DecodeFailure(PD004_PARAMETER_MEMBER_INVALID, "size mismatch")
            if hashlib.sha256(payload).hexdigest() != EXPECTED_PARAMETER_SHA256:
                raise DecodeFailure(PD004_PARAMETER_MEMBER_INVALID, "hash mismatch")
            return payload

        span = size + ((TAR_BLOCK - size % TAR_BLOCK) % TAR_BLOCK)
        _discard_gzip_exact(gz, span, audit)
        audit.non_parameter_member_spans_stream_discarded += 1
        audit.non_parameter_member_contents_read += 1
        audit.non_parameter_member_content_bytes_read += size


def _decode_parameter_text(payload: bytes) -> str:
    try:
        text = payload.decode("utf-8", errors="strict")
    except UnicodeDecodeError:
        raise DecodeFailure(PD005_PARAMETER_TEXT_INVALID, "not UTF-8") from None
    if "\x00" in text or text.startswith("\ufeff"):
        raise DecodeFailure(PD005_PARAMETER_TEXT_INVALID, "NUL/BOM prohibited")
    for character in text:
        point = ord(character)
        if point < 0x20 and character not in "\r\n\t":
            raise DecodeFailure(PD005_PARAMETER_TEXT_INVALID, "control character")
    return text


def parse_parameter(payload: bytes) -> tuple[str, List[PartitionRow]]:
    """Parse only structured fields; the source text is never returned."""
    text = _decode_parameter_text(payload)
    cmdlines = []
    for line in text.splitlines():
        if not line:
            continue
        key, separator, value = line.partition(":")
        if not separator or not _FIELD_KEY.fullmatch(key) or not value:
            raise DecodeFailure(PD005_PARAMETER_TEXT_INVALID, "invalid field line")
        if key == "CMDLINE":
            cmdlines.append(value)
    if not cmdlines:
        raise DecodeFailure(PD006_CMDLINE_MISSING)
    if len(cmdlines) != 1:
        raise DecodeFailure(PD007_CMDLINE_DUPLICATE)

    match = _CMDLINE.fullmatch(cmdlines[0])
    if not match:
        raise DecodeFailure(PD008_CMDLINE_INVALID)
    tokens = match.group("entries").split(",")
    if not tokens or any(not token for token in tokens):
        raise DecodeFailure(PD009_PARTITION_INVALID, "empty partition token")

    seen = set()
    rows = []
    for index, token in enumerate(tokens):
        entry = _PARTITION.fullmatch(token)
        if not entry:
            raise DecodeFailure(PD009_PARTITION_INVALID, f"token {index} shape")
        size_encoded = entry.group("size")
        offset_encoded = entry.group("offset")
        name = entry.group("name")
        attribute = entry.group("attribute")
        if name in seen:
            raise DecodeFailure(PD010_PARTITION_DUPLICATE, name)
        if attribute is not None and attribute not in _ALLOWED_ATTRIBUTES:
            raise DecodeFailure(PD009_PARTITION_INVALID, f"token {index} attribute")

        if size_encoded == "-":
            if attribute != "grow":
                raise DecodeFailure(PD009_PARTITION_INVALID, f"token {index} remainder")
            if index != len(tokens) - 1:
                raise DecodeFailure(
                    PD009_PARTITION_INVALID, f"token {index} remainder not last"
                )
            size_value = None
            branch = "remainderGrow"
        else:
            size_value = int(size_encoded, 16)
            if size_value <= 0:
                raise DecodeFailure(PD009_PARTITION_INVALID, f"token {index} zero size")
            if attribute == "grow":
                raise DecodeFailure(PD009_PARTITION_INVALID, f"token {index} fixed grow")
            branch = "fixedBootable" if attribute == "bootable" else "fixed"
        offset_value = int(offset_encoded, 16)

        seen.add(name)
        rows.append(
            PartitionRow(
                index,
                name,
                size_encoded,
                size_value,
                offset_encoded,
                offset_value,
                attribute,
                branch,
            )
        )
    return match.group("device"), rows


def decode_archive(
    src: Source, audit: Optional[DecodeAudit] = None
) -> tuple[dict, str, List[PartitionRow], DecodeAudit]:
    """Decode only the single production-pinned archive identity."""
    audit = audit if audit is not None else DecodeAudit()
    source_stream = _open_source(src, audit)
    close_stream = not isinstance(src, io.BytesIO)
    try:
        identity_stream = _AuditedRawStream(source_stream, audit, "identity")
        observed_size, observed_sha256 = _hash_raw(identity_stream, audit)
        _assert_source_stable(identity_stream, audit)
        if (
            observed_size != EXPECTED_RAW_SIZE
            or observed_sha256 != EXPECTED_RAW_SHA256
        ):
            raise DecodeFailure(PD001_IDENTITY_MISMATCH)
        identity_stream.seek(0)
        try:
            gzip_stream = _AuditedRawStream(source_stream, audit, "gzip")
            gz = gzip.GzipFile(fileobj=gzip_stream, mode="rb")
            with gz:
                payload = _read_parameter_member(gz, audit)
            _assert_source_stable(gzip_stream, audit)
        except DecodeFailure:
            raise
        except _GZIP_ERRORS:
            raise DecodeFailure(PD002_ARCHIVE_INVALID, "gzip open/read") from None
    finally:
        if close_stream:
            source_stream.close()
    device, partitions = parse_parameter(payload)
    identity = {
        "sizeBytes": observed_size,
        "sha256": observed_sha256,
        "identityMatch": True,
    }
    return identity, device, partitions, audit


def _serialize(document: dict) -> bytes:
    return (
        json.dumps(document, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    ).encode("utf-8")


def load_archived_inventory() -> tuple[dict, str]:
    with open(_INVENTORY_PATH, "rb") as handle:
        payload = handle.read()
    digest = hashlib.sha256(payload).hexdigest()
    if digest != EXPECTED_INVENTORY_SHA256:
        raise DecodeFailure(PD011_INVENTORY_INVALID, "evidence hash mismatch")
    try:
        document = json.loads(payload.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        raise DecodeFailure(PD011_INVENTORY_INVALID, "evidence JSON invalid") from None
    _validate_inventory(document, require_pinned_count=True)
    return document, digest


def _validate_inventory(document: dict, require_pinned_count: bool = False) -> None:
    try:
        members = document["members"]
        valid = (
            document["archiveSha256"] == EXPECTED_RAW_SHA256
            and document["memberCount"] == len(members)
            and all(
                isinstance(row["path"], str)
                and isinstance(row["sha256"], str)
                and len(row["sha256"]) == 64
                for row in members
            )
            and len({row["path"] for row in members}) == len(members)
        )
    except (KeyError, TypeError):
        valid = False
    if require_pinned_count:
        valid = valid and document.get("memberCount") == 17
    if not valid:
        raise DecodeFailure(PD011_INVENTORY_INVALID, "inventory shape/identity")


def reconcile_members(partitions: List[PartitionRow], inventory: dict) -> dict:
    """Exact-name reconciliation; no punctuation normalization or guessing."""
    _validate_inventory(inventory)
    by_partition = {row.name: row for row in partitions}
    member_rows = []
    matched = {}
    orphan_images = []
    for member in inventory["members"]:
        path = member["path"]
        if path.endswith(".img"):
            stem = path[:-4]
            partition = stem if stem in by_partition else None
            status = "mapped" if partition is not None else "orphan"
            if partition is None:
                orphan_images.append(path)
            else:
                matched[partition] = path
            role = "partitionImage"
            reason = (
                "exact case-sensitive filename stem match"
                if partition is not None
                else "no exact partition-name match; alias inference is forbidden"
            )
        else:
            partition = None
            status = "notApplicable"
            if path == PARAMETER_MEMBER:
                role = "partitionMetadata"
            elif path == "MiniLoaderAll.bin":
                role = "loaderBinary"
            elif path == "updater_binary":
                role = "updateHelper"
            else:
                role = "packageMetadata"
            reason = "not an .img partition member"
        member_rows.append(
            {
                "index": member["index"],
                "path": path,
                "sha256Reference": member["sha256"],
                "role": role,
                "status": status,
                "partition": partition,
                "reason": reason,
            }
        )

    partition_rows = []
    orphan_partitions = []
    for row in partitions:
        image = matched.get(row.name)
        status = "mapped" if image is not None else "orphan"
        if image is None:
            orphan_partitions.append(row.name)
        partition_rows.append(
            {"index": row.index, "partition": row.name, "status": status, "imageMember": image}
        )

    image_count = sum(1 for row in member_rows if row["role"] == "partitionImage")
    return {
        "mappingRule": (
            "case-sensitive filename stem == decoded partition name; no alias, "
            "punctuation normalization, similarity matching or address inference"
        ),
        "inventoryMemberCount": len(member_rows),
        "imageMemberCount": image_count,
        "mappedImageCount": image_count - len(orphan_images),
        "orphanImageCount": len(orphan_images),
        "orphanPartitionCount": len(orphan_partitions),
        "members": member_rows,
        "partitions": partition_rows,
        "orphanImageMembers": orphan_images,
        "orphanPartitions": orphan_partitions,
    }


def _scope() -> dict:
    return {
        "validOnlyForPinnedArchive": True,
        "authoritative": False,
        "nonAuthoritative": True,
        "parameterRawTextIncluded": False,
        "archiveLocatorIncluded": False,
        "flashAddressDerived": False,
        "flashProtocolClaim": False,
        "compatibilityClaim": False,
        "hardwareSupportClaim": False,
    }


def _expected_partition_rows() -> List[PartitionRow]:
    rows = []
    for index, (name, size_encoded, offset_encoded, attribute) in enumerate(
        EXPECTED_PARTITION_FACTS
    ):
        if size_encoded == "-":
            size_value = None
            branch = "remainderGrow"
        else:
            size_value = int(size_encoded, 16)
            branch = "fixedBootable" if attribute == "bootable" else "fixed"
        rows.append(
            PartitionRow(
                index,
                name,
                size_encoded,
                size_value,
                offset_encoded,
                int(offset_encoded, 16),
                attribute,
                branch,
            )
        )
    return rows


def _partition_document(identity: dict, device: str, rows: List[PartitionRow]) -> dict:
    return {
        "schema": "arkdeck-dayu200-partition-mapping-1.0.0",
        "scope": _scope(),
        "archiveIdentity": identity,
        "parameterMemberReference": {
            "path": PARAMETER_MEMBER,
            "sizeBytes": EXPECTED_PARAMETER_SIZE,
            "sha256": EXPECTED_PARAMETER_SHA256,
            "sourceInventory": _INVENTORY_RELATIVE,
        },
        "sourcePolicyReference": _ROUTE_PLAN_REFERENCE,
        "s2SourceCitations": list(S2_SOURCE_CITATIONS),
        "citationBoundary": (
            "S2 citations document grammar/tooling context only; every value below "
            "is a read-only observation of the pinned parameter member."
        ),
        "grammar": {
            "envelope": "CMDLINE:mtdparts=<device>:<partition>[,<partition>...]",
            "partition": "(<hex-size>|-)@<hex-offset>(<name>[:<attribute>])",
            "remainderConstraint": "remainderGrow must be the final partition",
            "allowedAttributes": sorted(_ALLOWED_ATTRIBUTES),
            "grammarBranches": ["fixed", "fixedBootable", "remainderGrow"],
            "numericUnit": "sourceEncodedUnitUnconverted",
        },
        "device": device,
        "partitionCount": len(rows),
        "partitions": [
            {
                "index": row.index,
                "name": row.name,
                "size": {
                    "kind": "remainder" if row.size_value is None else "fixed",
                    "encoded": row.size_encoded,
                    "value": row.size_value,
                },
                "offset": {"encoded": row.offset_encoded, "value": row.offset_value},
                "attribute": row.attribute,
                "grammarBranch": row.grammar_branch,
            }
            for row in rows
        ],
    }


def _reconciliation_document(reconciliation: dict, inventory_sha256: str) -> dict:
    return {
        "schema": "arkdeck-dayu200-member-reconciliation-1.0.0",
        "scope": _scope(),
        "inventoryReference": {
            "path": _INVENTORY_RELATIVE,
            "sha256": inventory_sha256,
            "archiveSha256": EXPECTED_RAW_SHA256,
            "memberCount": reconciliation["inventoryMemberCount"],
        },
        **reconciliation,
    }


def _audit_document(audit: DecodeAudit) -> dict:
    return {
        "schema": "arkdeck-dayu200-partition-decode-audit-1.0.0",
        "scope": _scope(),
        "pythonVersion": "%d.%d.%d" % sys.version_info[:3],
        "configuredMaxReadChunkBytes": MAX_READ_CHUNK,
        "maxObservedReadChunkBytes": audit.max_observed_read_chunk,
        "rawBytesRead": audit.raw_bytes_read,
        "identityPassRawBytesRead": audit.identity_pass_raw_bytes_read,
        "gzipPassRawBytesRead": audit.gzip_pass_raw_bytes_read,
        "decompressedBytesStreamedThroughLocator": audit.decompressed_bytes_streamed,
        "parameterBytesReturnedToDecoder": audit.parameter_bytes_returned_to_decoder,
        "tarHeadersInspected": audit.tar_headers_inspected,
        "nonParameterMemberSpansStreamDiscarded": (
            audit.non_parameter_member_spans_stream_discarded
        ),
        "nonParameterMemberContentsRead": audit.non_parameter_member_contents_read,
        "nonParameterMemberContentBytesReadAndDiscarded": (
            audit.non_parameter_member_content_bytes_read
        ),
        "nonParameterMemberContentReturnedToDecoderCount": 0,
        "nonParameterMemberContentRetainedBytes": 0,
        "partitionAcceptanceSatisfied": False,
        "partitionAcceptanceBlockingReasons": [
            (
                "gzip stream positioning consumed non-target member contents; current "
                "AC requires zero reads of other member contents"
            ),
            (
                "path-based os.open has an lstat/open replacement race; absolute zero "
                "device access is not statically proven"
            ),
        ],
        "archiveSourceKind": audit.archive_source_kind,
        "regularFileGatePassed": audit.archive_source_kind == "regularFile",
        "regularFileGateChecks": audit.regular_file_gate_checks,
        "archiveOpenModes": sorted(set(audit.archive_open_modes)),
        "archivePassCount": 2,
        "potentialDeviceOpenPathCount": 1,
        "pathReplacementDeviceOpenRaceExcluded": False,
        "zeroDeviceAccessStaticProofSatisfied": False,
        "memberExtractionToDiskCount": 0,
        "allowedEvidenceOutputs": list(EVIDENCE_OUTPUTS),
        "writesOutsideAllowedOutputs": audit.writes_outside_allowed_outputs,
        "dispatchCounters": {
            "childProcess": 0,
            "network": 0,
            "hdc": 0,
            "flashd": 0,
            "vendorTool": 0,
            "usb": 0,
            "uart": 0,
            "tcp": 0,
            "deviceMutation": 0,
        },
        "counterProvenance": {
            "readMetrics": (
                "identity hash and gzip receive _AuditedRawStream wrappers; every "
                "compressed byte returned by read/readinto is assigned to one pass"
            ),
            "sourceType": (
                "lstat rejects known non-regular paths before open; path-based os.open "
                "uses O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC and fstat rejects replacement "
                "before read, but a device may already have been opened in that race"
            ),
            "nonParameterContent": (
                "non-target member contents are read to position the single gzip/tar "
                "stream, then discarded without parsing, retaining or writing"
            ),
            "dispatchCounters": (
                "subprocess/network/transport/device-mutation structural zeros are "
                "asserted by strict import and call-target allowlists; absolute device "
                "open exclusion is explicitly not claimed"
            ),
        },
    }


def _expected_audit_document() -> dict:
    audit = DecodeAudit(
        raw_bytes_read=EXPECTED_RAW_SIZE + EXPECTED_GZIP_PASS_RAW_BYTES_READ,
        identity_pass_raw_bytes_read=EXPECTED_RAW_SIZE,
        gzip_pass_raw_bytes_read=EXPECTED_GZIP_PASS_RAW_BYTES_READ,
        decompressed_bytes_streamed=EXPECTED_DECOMPRESSED_BYTES_TO_PARAMETER,
        parameter_bytes_returned_to_decoder=EXPECTED_PARAMETER_SIZE,
        max_observed_read_chunk=MAX_READ_CHUNK,
        tar_headers_inspected=EXPECTED_TAR_HEADERS_INSPECTED,
        non_parameter_member_spans_stream_discarded=(
            EXPECTED_NON_PARAMETER_SPANS_DISCARDED
        ),
        non_parameter_member_contents_read=EXPECTED_NON_PARAMETER_SPANS_DISCARDED,
        non_parameter_member_content_bytes_read=(
            EXPECTED_NON_PARAMETER_CONTENT_BYTES_READ
        ),
        archive_open_modes=["rb"],
        archive_source_kind="regularFile",
        regular_file_gate_checks=EXPECTED_REGULAR_FILE_GATE_CHECKS,
    )
    document = _audit_document(audit)
    document["pythonVersion"] = EXPECTED_PYTHON_VERSION
    return document


def validate_evidence(name: str, document: dict) -> None:
    try:
        scope = document["scope"]
        scope_valid = scope == _scope()
        if name == "partition-mapping.json":
            expected = _partition_document(
                {
                    "sizeBytes": EXPECTED_RAW_SIZE,
                    "sha256": EXPECTED_RAW_SHA256,
                    "identityMatch": True,
                },
                "rk29xxnand",
                _expected_partition_rows(),
            )
            valid = document == expected
        elif name == "member-reconciliation.json":
            inventory, inventory_sha256 = load_archived_inventory()
            expected = _reconciliation_document(
                reconcile_members(_expected_partition_rows(), inventory),
                inventory_sha256,
            )
            valid = document == expected
        elif name == "process-audit.json":
            valid = document == _expected_audit_document()
        else:
            raise EvidenceValidationError(f"unknown evidence document: {name}")
    except (KeyError, TypeError):
        valid = False
        scope_valid = False
    if not scope_valid or not valid:
        raise EvidenceValidationError(f"closed evidence validation failed: {name}")


def validate_evidence_bundle(documents: dict) -> None:
    expected_names = {
        "partition-mapping.json",
        "member-reconciliation.json",
        "process-audit.json",
    }
    if set(documents) != expected_names:
        raise EvidenceValidationError("evidence bundle has missing/unexpected documents")
    for name in sorted(documents):
        validate_evidence(name, documents[name])

    mapping_rows = documents["partition-mapping.json"]["partitions"]
    reconciliation = documents["member-reconciliation.json"]
    reconciliation_rows = reconciliation["partitions"]
    if [
        (row["index"], row["name"]) for row in mapping_rows
    ] != [
        (row["index"], row["partition"]) for row in reconciliation_rows
    ]:
        raise EvidenceValidationError("mapping/reconciliation partition sets differ")

    mapped_members = {
        row["partition"]: row["path"]
        for row in reconciliation["members"]
        if row["status"] == "mapped"
    }
    mapped_partitions = {
        row["partition"]: row["imageMember"]
        for row in reconciliation_rows
        if row["status"] == "mapped"
    }
    if mapped_members != mapped_partitions:
        raise EvidenceValidationError("member/partition mappings are not symmetric")


def _write_evidence(out_dir: str, name: str, payload: bytes, audit: DecodeAudit) -> None:
    if name not in EVIDENCE_OUTPUTS:
        audit.writes_outside_allowed_outputs += 1
        raise DecodeToolError(f"refusing non-allowlisted output: {name}")
    target = os.path.join(out_dir, name)
    try:
        with open(target, "xb") as handle:
            handle.write(payload)
    except FileExistsError:
        raise DecodeToolError(f"refusing to overwrite evidence: {name}") from None
    audit.evidence_files_written.append(name)


def _write_evidence_set(
    out_dir: str, payloads: dict, audit: DecodeAudit
) -> None:
    """Preflight the complete create-only set before writing the first byte."""
    if tuple(payloads) != EVIDENCE_OUTPUTS:
        audit.writes_outside_allowed_outputs += 1
        raise DecodeToolError("evidence payload set/order does not match allowlist")
    os.makedirs(out_dir, exist_ok=True)
    conflicts = [
        name for name in EVIDENCE_OUTPUTS if os.path.lexists(os.path.join(out_dir, name))
    ]
    if conflicts:
        raise DecodeToolError(
            "refusing mixed/partial evidence write; existing output: "
            + ", ".join(conflicts)
        )
    for name, payload in payloads.items():
        _write_evidence(out_dir, name, payload, audit)


def _summary(mapping: dict, reconciliation: dict, payloads: dict) -> bytes:
    lines = [
        "# DAYU200 pinned-image partition decode summary",
        "",
        "**Verification status: BLOCKED / partition acceptance not satisfied.**",
        "Reaching `parameter.txt` in the single gzip/tar stream consumed seven",
        "non-target member bodies. The accepted AC requires zero reads of other member",
        "contents. In addition, path-based `lstat` then `open` cannot exclude a device",
        "replacement race before `fstat`; absolute zero device access is not statically",
        "proven. Changing either boundary requires separately approved governance. The",
        "mapping below is failure evidence, not a passing acceptance claim.",
        "",
        "Non-authoritative evidence valid only for the pinned archive identity",
        f"`{EXPECTED_RAW_SHA256}`. The original `parameter.txt` text and archive",
        "locator are omitted. Encoded offsets are decoded table fields only: no flash",
        "address, protocol, compatibility, executable profile or hardware support is",
        "derived or claimed.",
        "",
        "| Evidence file | SHA-256 |",
        "| --- | --- |",
    ]
    for name in ("partition-mapping.json", "member-reconciliation.json", "process-audit.json"):
        lines.append(f"| `{name}` | `{hashlib.sha256(payloads[name]).hexdigest()}` |")
    lines += [
        "",
        "## Decoded mapping",
        "",
        "| Partition | Size token | Offset token | Attribute |",
        "| --- | ---: | ---: | --- |",
    ]
    for row in mapping["partitions"]:
        attribute = row["attribute"] if row["attribute"] is not None else "none"
        lines.append(
            f"| `{row['name']}` | `{row['size']['encoded']}` | "
            f"`{row['offset']['encoded']}` | `{attribute}` |"
        )
    lines += [
        "",
        "## Image-member reconciliation",
        "",
        f"- Inventory members reviewed: {reconciliation['inventoryMemberCount']}.",
        f"- `.img` members: {reconciliation['imageMemberCount']}; mapped by exact stem: "
        f"{reconciliation['mappedImageCount']}; explicit image orphans: "
        f"{reconciliation['orphanImageCount']}.",
        f"- Explicit partitions without an exact image member: "
        f"{reconciliation['orphanPartitionCount']}.",
        "- Match rule is deliberately exact and case-sensitive; punctuation aliases and",
        "  similarity guesses are not promoted to facts.",
        "",
        "| Image member | Result | Partition |",
        "| --- | --- | --- |",
    ]
    for row in reconciliation["members"]:
        if row["role"] != "partitionImage":
            continue
        partition = row["partition"] if row["partition"] is not None else "—"
        lines.append(f"| `{row['path']}` | `{row['status']}` | `{partition}` |")
    lines += [
        "",
        "## S2 citations",
        "",
        f"Source-selection policy: `{_ROUTE_PLAN_REFERENCE}`.",
        "",
    ]
    for source in S2_SOURCE_CITATIONS:
        lines.append(f"- [{source['title']}]({source['url']}) — {source['scope']}.")
    lines += ["", "All S2 citations are contextual; decoded values come only from the pinned member.", ""]
    return "\n".join(lines).encode("utf-8")


def build_evidence(src: Source, out_dir: str) -> DecodeAudit:
    """Production evidence path: pinned identities/inventory have no overrides."""
    identity, device, partitions, audit = decode_archive(src)
    inventory_document, inventory_sha256 = load_archived_inventory()
    reconciliation = reconcile_members(partitions, inventory_document)
    documents = {
        "partition-mapping.json": _partition_document(identity, device, partitions),
        "member-reconciliation.json": _reconciliation_document(
            reconciliation, inventory_sha256
        ),
        "process-audit.json": _audit_document(audit),
    }
    validate_evidence_bundle(documents)
    payloads = {}
    for name, document in documents.items():
        payloads[name] = _serialize(document)
    payloads["summary.md"] = _summary(
        documents["partition-mapping.json"], reconciliation, payloads
    )
    _write_evidence_set(out_dir, payloads, audit)
    return audit


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="decode.py",
        description="Decode DAYU200 parameter.txt for the single pinned archive.",
    )
    parser.add_argument("--archive", required=True, help="external pinned archive path")
    parser.add_argument("--out-dir", required=True, help="governed evidence directory")
    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    arguments = build_arg_parser().parse_args(argv)
    try:
        audit = build_evidence(arguments.archive, arguments.out_dir)
    except DecodeFailure as failure:
        print(f"decode failed: {failure.code}", file=sys.stderr)
        return 1
    except (DecodeToolError, EvidenceValidationError) as error:
        print(f"tool error: {error}", file=sys.stderr)
        return 2
    print(
        "decode blocked: evidence written; current AC forbids the observed non-target "
        "member reads and absolute zero device access is not statically proven:",
        ", ".join(audit.evidence_files_written),
        file=sys.stderr,
    )
    return 3


if __name__ == "__main__":
    sys.exit(main())
