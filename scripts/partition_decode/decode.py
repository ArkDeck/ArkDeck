"""FD-only DAYU200 ``parameter.txt`` partition decoder.

CHG-2026-009 / TASK-PD-001. Python standard library only. The production
entry point accepts exactly the archive identity characterized by archived
CHG-2026-003, streams to ``parameter.txt`` without extracting any member,
checks that member's archived size/hash, parses a closed CMDLINE/mtdparts
grammar, and reconciles decoded partition names with the archived 17-member
inventory.

The production entry point accepts only a pre-opened read-only regular-file
descriptor. It performs ``fstat`` and ``F_GETFL`` gates before the first read,
duplicates the descriptor without resolving a path, and never accepts or opens
an archive pathname. Descriptor acquisition is owned by the separately signed
macOS sandbox broker in ``macos_input_broker``.

The decoder has no process, network, HDC, vendor-tool, transport, archive-path
open or device-dispatch code path. Non-parameter member spans needed to reach
the target tar header are consumed in bounded chunks and immediately discarded
without parsing, hashing, returning, logging or persistence. Application chunk
references are released before the next read; mandatory opaque DEFLATE history
inside zlib is reported separately and leaves literal cross-chunk retention
acceptance blocked. The archive locator and original parameter text never enter
evidence.
"""

from __future__ import annotations

import dataclasses
import fcntl
import hashlib
import io
import os
import re
import stat
import sys
import zlib
from typing import BinaryIO, List, NamedTuple, Optional


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
EXPECTED_PYTHON_VERSION = "3.14.6"
EXPECTED_DECOMPRESSED_BYTES_TO_PARAMETER = 178174740
EXPECTED_TAR_HEADERS_INSPECTED = 8
EXPECTED_NON_PARAMETER_SPANS_DISCARDED = 7
EXPECTED_NON_PARAMETER_CONTENT_BYTES_READ = 178168731
EXPECTED_GZIP_PASS_RAW_BYTES_READ = 17956864
EXPECTED_REGULAR_FILE_GATE_CHECKS = 4
COMPRESSED_READ_CHUNK = 65536
EXPECTED_GZIP_COMPRESSED_BYTES_BUFFERED_AT_STOP = 39869

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
PD013_DESCRIPTOR_NOT_READ_ONLY = "PD013_DESCRIPTOR_NOT_READ_ONLY"

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
    PD013_DESCRIPTOR_NOT_READ_ONLY,
)

_INVENTORY_RELATIVE = (
    "openspec/changes/archive/2026-07-18-chg-2026-003-dayu200-image-"
    "characterization/evidence/member-inventory.json"
)
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
_GZIP_ERRORS = (OSError, EOFError, zlib.error)


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
    read_only_descriptor_gate_checks: int = 0
    pre_read_fstat_passed: bool = False
    pre_read_read_only_gate_passed: bool = False
    first_read_after_descriptor_gates: bool = False
    gzip_compressed_bytes_buffered_at_stop: int = 0


class PartitionRow(NamedTuple):
    index: int
    name: str
    size_encoded: str
    size_value: Optional[int]
    offset_encoded: str
    offset_value: int
    attribute: Optional[str]
    grammar_branch: str


class _AuditedRawStream:
    """Count every compressed byte returned by one named archive pass."""

    def __init__(self, stream: BinaryIO, audit: DecodeAudit, pass_name: str):
        if pass_name not in ("identity", "gzip"):
            raise ValueError("unknown raw-read pass")
        self._stream = stream
        self._audit = audit
        self._pass_name = pass_name

    def _record(self, amount: int) -> None:
        if amount and not (
            self._audit.pre_read_fstat_passed
            and self._audit.pre_read_read_only_gate_passed
        ):
            raise DecodeFailure(
                PD012_SOURCE_NOT_STABLE_REGULAR_FILE,
                "read attempted before descriptor gates",
            )
        if amount:
            self._audit.first_read_after_descriptor_gates = True
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


class _BoundedGzipStream:
    """Gzip decoder that never produces bytes beyond the caller's exact request.

    ``zlib.decompressobj.decompress(..., max_length)`` prevents the hidden
    post-target decompressed buffering performed by higher-level buffered gzip
    readers. Unconsumed input remains compressed and is dropped with this object
    immediately after the target body is returned.
    """

    def __init__(self, raw_stream: _AuditedRawStream):
        self._raw_stream = raw_stream
        self._decompressor = zlib.decompressobj(16 + zlib.MAX_WBITS)
        self._compressed_pending = b""

    @property
    def compressed_pending_bytes(self) -> int:
        return len(self._compressed_pending)

    def read_exact(self, amount: int, audit: DecodeAudit) -> bytes:
        if amount < 0 or amount > MAX_READ_CHUNK:
            raise DecodeFailure(PD002_ARCHIVE_INVALID, "unbounded gzip read")
        parts = []
        remaining = amount
        while remaining > 0:
            if not self._compressed_pending:
                self._compressed_pending = self._raw_stream.read(COMPRESSED_READ_CHUNK)
                if not self._compressed_pending:
                    raise DecodeFailure(PD002_ARCHIVE_INVALID, "short gzip stream")
            before = len(self._compressed_pending)
            try:
                produced = self._decompressor.decompress(
                    self._compressed_pending, remaining
                )
            except zlib.error:
                raise DecodeFailure(PD002_ARCHIVE_INVALID, "gzip framing") from None
            self._compressed_pending = self._decompressor.unconsumed_tail
            consumed = before - len(self._compressed_pending)
            if produced:
                parts.append(produced)
                remaining -= len(produced)
            if self._decompressor.eof and remaining:
                raise DecodeFailure(PD002_ARCHIVE_INVALID, "short gzip stream")
            if not produced and consumed == 0:
                raise DecodeFailure(PD002_ARCHIVE_INVALID, "gzip made no progress")
        payload = b"".join(parts)
        audit.decompressed_bytes_streamed += len(payload)
        audit.max_observed_read_chunk = max(
            audit.max_observed_read_chunk, len(payload)
        )
        return payload


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


def _descriptor_flags(descriptor: int, audit: DecodeAudit) -> int:
    try:
        flags = fcntl.fcntl(descriptor, fcntl.F_GETFL)
    except OSError:
        raise DecodeFailure(PD013_DESCRIPTOR_NOT_READ_ONLY) from None
    audit.read_only_descriptor_gate_checks += 1
    return flags


def _validate_read_only(flags: int) -> None:
    if flags & os.O_ACCMODE != os.O_RDONLY:
        raise DecodeFailure(PD013_DESCRIPTOR_NOT_READ_ONLY)


def _open_descriptor_stream(descriptor: int, audit: DecodeAudit) -> BinaryIO:
    """Duplicate a caller-owned fd after pre-read regular/read-only gates."""
    if isinstance(descriptor, bool) or not isinstance(descriptor, int) or descriptor < 0:
        raise DecodeFailure(PD012_SOURCE_NOT_STABLE_REGULAR_FILE)
    try:
        initial = os.fstat(descriptor)
    except OSError:
        raise DecodeFailure(PD012_SOURCE_NOT_STABLE_REGULAR_FILE) from None
    audit.regular_file_gate_checks += 1
    if not _is_regular_file_mode(initial.st_mode):
        raise DecodeFailure(PD012_SOURCE_NOT_STABLE_REGULAR_FILE)
    audit.pre_read_fstat_passed = True
    flags = _descriptor_flags(descriptor, audit)
    _validate_read_only(flags)
    audit.pre_read_read_only_gate_passed = True
    snapshot = _stat_snapshot(initial)

    duplicate = None
    try:
        duplicate = os.dup(descriptor)
        duplicate_stat = os.fstat(duplicate)
        audit.regular_file_gate_checks += 1
        if not _is_regular_file_mode(duplicate_stat.st_mode):
            raise DecodeFailure(PD012_SOURCE_NOT_STABLE_REGULAR_FILE)
        if _stat_snapshot(duplicate_stat) != snapshot:
            raise DecodeFailure(PD012_SOURCE_NOT_STABLE_REGULAR_FILE)
        _validate_read_only(_descriptor_flags(duplicate, audit))
        handle = os.fdopen(duplicate, "rb", closefd=True)
        duplicate = None
    except DecodeFailure:
        if duplicate is not None:
            os.close(duplicate)
        raise
    except OSError:
        if duplicate is not None:
            os.close(duplicate)
        raise DecodeFailure(PD012_SOURCE_NOT_STABLE_REGULAR_FILE) from None
    audit.archive_open_modes.append("preopened-read-only-fd")
    audit.archive_source_kind = "preopenedReadOnlyRegularFileDescriptor"
    audit.source_stat_snapshot = snapshot
    return handle


def _assert_source_stable(stream: BinaryIO, audit: DecodeAudit) -> None:
    try:
        current = os.fstat(stream.fileno())
    except OSError:
        raise DecodeFailure(PD012_SOURCE_NOT_STABLE_REGULAR_FILE) from None
    audit.regular_file_gate_checks += 1
    flags = _descriptor_flags(stream.fileno(), audit)
    if (
        not _is_regular_file_mode(current.st_mode)
        or _stat_snapshot(current) != audit.source_stat_snapshot
    ):
        raise DecodeFailure(PD012_SOURCE_NOT_STABLE_REGULAR_FILE)
    _validate_read_only(flags)


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


def _read_gzip_exact(
    gz: _BoundedGzipStream, amount: int, audit: DecodeAudit
) -> bytes:
    return gz.read_exact(amount, audit)


def _discard_gzip_exact(
    gz: _BoundedGzipStream, amount: int, audit: DecodeAudit
) -> None:
    remaining = amount
    while remaining > 0:
        discard_size = min(remaining, MAX_READ_CHUNK)
        _read_gzip_exact(gz, discard_size, audit)
        remaining -= discard_size


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


def _read_parameter_member(gz: _BoundedGzipStream, audit: DecodeAudit) -> bytes:
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
            audit.gzip_compressed_bytes_buffered_at_stop = (
                gz.compressed_pending_bytes
            )
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
    descriptor: int, audit: Optional[DecodeAudit] = None
) -> tuple[dict, str, List[PartitionRow], DecodeAudit]:
    """Decode the pinned archive from a caller-owned read-only descriptor only."""
    audit = audit if audit is not None else DecodeAudit()
    source_stream = _open_descriptor_stream(descriptor, audit)
    with source_stream:
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
            gz = _BoundedGzipStream(gzip_stream)
            payload = _read_parameter_member(gz, audit)
            _assert_source_stable(gzip_stream, audit)
        except DecodeFailure:
            raise
        except _GZIP_ERRORS:
            raise DecodeFailure(PD002_ARCHIVE_INVALID, "gzip open/read") from None
    device, partitions = parse_parameter(payload)
    identity = {
        "sizeBytes": observed_size,
        "sha256": observed_sha256,
        "identityMatch": True,
    }
    return identity, device, partitions, audit


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
        "schema": "arkdeck-dayu200-partition-decode-audit-2.0.0",
        "scope": _scope(),
        "pythonVersion": "%d.%d.%d" % sys.version_info[:3],
        "configuredMaxReadChunkBytes": MAX_READ_CHUNK,
        "configuredCompressedInputChunkBytes": COMPRESSED_READ_CHUNK,
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
        "applicationChunkReferenceRetainedAcrossNextReadBytes": 0,
        "deflateInternalHistoryRetention": (
            "required by DEFLATE; opaque zlib state may retain prior body bytes"
        ),
        "deflateWindowUpperBoundBytes": 32768,
        "crossChunkRetentionAcceptanceSatisfied": False,
        "gzipCompressedBytesBufferedAtStop": (
            audit.gzip_compressed_bytes_buffered_at_stop
        ),
        "postTargetDecompressedBytesProduced": 0,
        "highLevelGzipPrefetchUsed": False,
        "nonParameterBodyLifecycle": (
            "application-visible output chunks are counted and discarded before the "
            "next read; zlib necessarily retains DEFLATE sliding history internally"
        ),
        "stoppedImmediatelyAfterParameterBody": True,
        "partitionAcceptanceSatisfied": False,
        "partitionAcceptanceBlockingReasons": [
            (
                "r2 forbids non-target body retention across chunks but does not state "
                "whether the mandatory DEFLATE sliding history is exempt; the decoder "
                "therefore cannot prove the literal zero-retention boundary"
            )
        ],
        "archiveSourceKind": audit.archive_source_kind,
        "regularFileGatePassed": (
            audit.archive_source_kind == "preopenedReadOnlyRegularFileDescriptor"
        ),
        "regularFileGateChecks": audit.regular_file_gate_checks,
        "readOnlyDescriptorGatePassed": audit.pre_read_read_only_gate_passed,
        "readOnlyDescriptorGateChecks": audit.read_only_descriptor_gate_checks,
        "fstatCompletedBeforeFirstRead": audit.pre_read_fstat_passed,
        "firstReadOccurredOnlyAfterDescriptorGates": (
            audit.first_read_after_descriptor_gates
        ),
        "archiveOpenModes": sorted(set(audit.archive_open_modes)),
        "archivePassCount": 2,
        "archivePathAcceptedByDecoder": False,
        "archivePathOpenCallCount": 0,
        "potentialDeviceOpenPathCount": 0,
        "pathReplacementRaceOutsideDecoderBoundary": True,
        "decoderDescriptorBoundarySatisfied": True,
        "workflowZeroDeviceClaimRequiresBrokerEvidence": True,
        "memberExtractionToDiskCount": 0,
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
                "production API accepts only an integer descriptor; fstat and F_GETFL "
                "prove regular/read-only state before the first read; os.dup preserves "
                "the capability without resolving an archive path"
            ),
            "nonParameterContent": (
                "application-visible non-target chunks are consumed only to position "
                "the single gzip/tar stream and are dropped before the next call; zlib "
                "max_length prevents post-target output but its required DEFLATE sliding "
                "history makes literal zero cross-chunk retention unproven"
            ),
            "dispatchCounters": (
                "subprocess/network/transport/device-mutation structural zeros are "
                "asserted by strict production-source import and call-target allowlists; "
                "workflow device exclusion is separately proved by broker policy"
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
        archive_open_modes=["preopened-read-only-fd"],
        archive_source_kind="preopenedReadOnlyRegularFileDescriptor",
        regular_file_gate_checks=EXPECTED_REGULAR_FILE_GATE_CHECKS,
        read_only_descriptor_gate_checks=EXPECTED_REGULAR_FILE_GATE_CHECKS,
        pre_read_fstat_passed=True,
        pre_read_read_only_gate_passed=True,
        first_read_after_descriptor_gates=True,
        gzip_compressed_bytes_buffered_at_stop=(
            EXPECTED_GZIP_COMPRESSED_BYTES_BUFFERED_AT_STOP
        ),
    )
    document = _audit_document(audit)
    document["pythonVersion"] = EXPECTED_PYTHON_VERSION
    return document


def validate_evidence(
    name: str, document: dict, inventory_document: dict, inventory_sha256: str
) -> None:
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
            expected = _reconciliation_document(
                reconcile_members(_expected_partition_rows(), inventory_document),
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


def validate_evidence_bundle(
    documents: dict, inventory_document: dict, inventory_sha256: str
) -> None:
    expected_names = {
        "partition-mapping.json",
        "member-reconciliation.json",
        "process-audit.json",
    }
    if set(documents) != expected_names:
        raise EvidenceValidationError("evidence bundle has missing/unexpected documents")
    for name in sorted(documents):
        validate_evidence(
            name, documents[name], inventory_document, inventory_sha256
        )

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
