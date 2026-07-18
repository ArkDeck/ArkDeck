"""Read-only streaming characterization scanner for the DAYU200 vendor archive.

CHG-2026-003 / TASK-DAYU200-CHAR-001. Python stdlib only. The scanner:

1. pins the raw archive identity (byte size + SHA-256) before anything else;
2. produces the physical-header-order member inventory (path, kind, size,
   per-member SHA-256) by streaming, never extracting to disk;
3. rejects hazards with the fixed ARC001..ARC009 codes before any
   classification runs; and
4. classifies ``imagePackageFamily`` with the closed six-condition rule over
   the verified ``{path, kind, size}`` projection only.

No shell, no subprocess, no network, no HDC/vendor tool, no device access and
no member execution exist anywhere in this module; ``test_scan.py`` asserts
that statically. Member bytes are hashed in bounded chunks and never decoded,
interpreted, retained or written to disk. The archive locator is never written
to evidence. The production CLI exposes no identity bypass; tests reach hazard
branches by calling the scanner core with fixture-specific expected identities.
"""

from __future__ import annotations

import argparse
import dataclasses
import gzip
import hashlib
import io
import json
import os
import posixpath
import re
import sys
from typing import BinaryIO, Iterable, List, NamedTuple, Optional, Sequence, Union

# --- Fixed production input gate (design.md "Fixed input gate") ---------------

EXPECTED_RAW_SIZE = 732948803
EXPECTED_RAW_SHA256 = "fc7637f34a8394847b1b6c7e7ff2750863d18c6dc05e184abaf5aed70ec75280"

MAX_READ_CHUNK = 1048576
TAR_BLOCK = 512

# --- Fixed hazard codes (design.md "Fixed hazard results and precedence") -----

ARC001_IDENTITY_MISMATCH = "ARC001_IDENTITY_MISMATCH"
ARC002_ARCHIVE_INVALID = "ARC002_ARCHIVE_INVALID"
ARC003_PATH_ABSOLUTE = "ARC003_PATH_ABSOLUTE"
ARC004_PATH_TRAVERSAL = "ARC004_PATH_TRAVERSAL"
ARC005_PATH_INVALID = "ARC005_PATH_INVALID"
ARC006_PATH_DUPLICATE = "ARC006_PATH_DUPLICATE"
ARC007_LINK_UNSUPPORTED = "ARC007_LINK_UNSUPPORTED"
ARC008_MEMBER_TYPE_UNSUPPORTED = "ARC008_MEMBER_TYPE_UNSUPPORTED"
ARC009_MEMBER_SIZE_MISMATCH = "ARC009_MEMBER_SIZE_MISMATCH"

HAZARD_CODES = (
    ARC001_IDENTITY_MISMATCH,
    ARC002_ARCHIVE_INVALID,
    ARC003_PATH_ABSOLUTE,
    ARC004_PATH_TRAVERSAL,
    ARC005_PATH_INVALID,
    ARC006_PATH_DUPLICATE,
    ARC007_LINK_UNSUPPORTED,
    ARC008_MEMBER_TYPE_UNSUPPORTED,
    ARC009_MEMBER_SIZE_MISMATCH,
)

# --- Closed classification rule (design.md "Closed classification rule") ------

CONDITION_IDS = (
    "PKG-RK-ROOT-REGULAR-NONEMPTY",
    "PKG-RK-PARAMETER",
    "PKG-RK-MINILOADER",
    "PKG-RK-UBOOT",
    "PKG-RK-EXTRA-IMAGES",
    "PKG-RK-ALLOWLIST",
)

_ANCHOR_PARAMETER = "parameter.txt"
_ANCHOR_MINILOADER = "MiniLoaderAll.bin"
_ANCHOR_UBOOT = "uboot.img"
_EXTRA_ALLOWLIST = frozenset(
    {"config.cfg", "daily_build.log", "manifest_tag.xml", "updater_binary"}
)

EVIDENCE_OUTPUTS = (
    "archive-identity.json",
    "member-inventory.json",
    "package-classification.json",
    "process-audit.json",
    "summary.md",
)

_SCHEMA_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "schemas")
_SCHEMA_FILES = {
    "archive-identity.json": "archive-identity.schema.json",
    "member-inventory.json": "member-inventory.schema.json",
    "package-classification.json": "package-classification.schema.json",
    "process-audit.json": "process-audit.schema.json",
}


class ScanFailure(Exception):
    """A terminal hazard result. ``code`` is one of the fixed ARC codes."""

    def __init__(self, code: str, member_index: Optional[int] = None, context: str = ""):
        self.code = code
        self.member_index = member_index
        self.context = context
        super().__init__(f"{code} (member_index={member_index}) {context}".strip())


class ScanToolError(Exception):
    """A tool/usage failure that is not an archive hazard (e.g. overwrite refusal)."""


class SchemaValidationError(Exception):
    """An evidence document does not satisfy its closed schema."""


@dataclasses.dataclass
class ScanAudit:
    """Instrumented observations of one scanner run (M1-010 principle: these
    counters are measured at the single I/O choke points, not branch constants)."""

    raw_bytes_read: int = 0
    uncompressed_bytes_read: int = 0
    max_observed_read_chunk: int = 0
    archive_open_modes: List[str] = dataclasses.field(default_factory=list)
    evidence_files_written: List[str] = dataclasses.field(default_factory=list)
    writes_outside_allowed_outputs: int = 0
    classify_calls: int = 0
    hazard_vectors_executed: int = 0


class MemberRow(NamedTuple):
    index: int
    path: str
    kind: str
    size: int
    sha256: str


class ClassificationRow(NamedTuple):
    """The complete classifier input projection. Exactly path/kind/size; the
    classifier rejects any other row shape (archive identity, hashes, raw
    bytes, locators and marketing text are structurally unrepresentable)."""

    path: str
    kind: str
    size: int


Source = Union[str, os.PathLike, io.BytesIO]


def _open_source(src: Source, audit: ScanAudit) -> BinaryIO:
    if isinstance(src, io.BytesIO):
        audit.archive_open_modes.append("memory-ro")
        src.seek(0)
        return src
    handle = open(os.fspath(src), "rb")
    audit.archive_open_modes.append("rb")
    return handle


# --- Pass 1: raw archive identity --------------------------------------------


def _hash_raw(stream: BinaryIO, audit: ScanAudit) -> tuple[int, str]:
    digest = hashlib.sha256()
    total = 0
    while True:
        chunk = stream.read(MAX_READ_CHUNK)
        if not chunk:
            break
        audit.max_observed_read_chunk = max(audit.max_observed_read_chunk, len(chunk))
        total += len(chunk)
        digest.update(chunk)
    audit.raw_bytes_read += total
    return total, digest.hexdigest()


# --- Pass 2: strict streaming tar inventory ----------------------------------


def _read_decompressed(gz: gzip.GzipFile, n: int, audit: ScanAudit) -> bytes:
    """Read exactly up to ``n`` decompressed bytes in bounded chunks. Returns
    fewer bytes only at a clean end of the decompressed stream. Gzip framing
    errors surface as ARC002 at the call site via ``_GzipFraming``."""
    parts = []
    remaining = n
    while remaining > 0:
        chunk = gz.read(min(remaining, MAX_READ_CHUNK))
        if not chunk:
            break
        audit.max_observed_read_chunk = max(audit.max_observed_read_chunk, len(chunk))
        audit.uncompressed_bytes_read += len(chunk)
        remaining -= len(chunk)
        parts.append(chunk)
    return b"".join(parts)


_GZIP_ERRORS = (OSError, EOFError, gzip.BadGzipFile)


def _parse_octal(field: bytes, code_on_error: str, member_index: Optional[int]) -> int:
    if field and field[0] & 0x80:
        # GNU base-256 numeric encoding is outside the closed scanner contract.
        raise ScanFailure(code_on_error, member_index, "base-256 numeric field")
    text = field.strip(b" \x00")
    if not text:
        raise ScanFailure(code_on_error, member_index, "empty numeric field")
    try:
        value = int(text, 8)
    except ValueError:
        raise ScanFailure(code_on_error, member_index, "malformed numeric field") from None
    if value < 0:
        raise ScanFailure(code_on_error, member_index, "negative numeric field")
    return value


def _extract_name_bytes(field: bytes, member_index: int) -> bytes:
    nul = field.find(b"\x00")
    if nul < 0:
        return field
    if field[nul:].strip(b"\x00"):
        raise ScanFailure(ARC005_PATH_INVALID, member_index, "ambiguous NUL-embedded name")
    return field[:nul]


_DRIVE_PREFIX = re.compile(r"^[A-Za-z]:")


def _validate_member_path(name: str, member_index: int, accepted: set) -> None:
    """Design.md path validation, raising in fixed numeric code order."""
    # ARC003: POSIX absolute, UNC-like, drive-prefixed.
    if name.startswith("/") or name.startswith("\\\\") or _DRIVE_PREFIX.match(name):
        raise ScanFailure(ARC003_PATH_ABSOLUTE, member_index, "absolute path")
    # ARC004: both separators count for traversal detection.
    if any(segment == ".." for segment in re.split(r"[/\\]", name)):
        raise ScanFailure(ARC004_PATH_TRAVERSAL, member_index, "'..' segment")
    # ARC005: prohibited characters, empty/'.' segments, non-canonical form.
    if not name:
        raise ScanFailure(ARC005_PATH_INVALID, member_index, "empty name")
    if "\\" in name:
        raise ScanFailure(ARC005_PATH_INVALID, member_index, "backslash in name")
    for ch in name:
        point = ord(ch)
        if point < 0x20 or point == 0x7F or 0xD800 <= point <= 0xDFFF:
            raise ScanFailure(ARC005_PATH_INVALID, member_index, "prohibited character")
    segments = name.split("/")
    if any(segment in ("", ".") for segment in segments):
        raise ScanFailure(ARC005_PATH_INVALID, member_index, "empty or '.' segment")
    if posixpath.normpath(name) != name:
        raise ScanFailure(ARC005_PATH_INVALID, member_index, "non-canonical form")
    # ARC006: uniqueness of the accepted path.
    if name in accepted:
        raise ScanFailure(ARC006_PATH_DUPLICATE, member_index, "duplicate path")


def _scan_members(gz: gzip.GzipFile, audit: ScanAudit) -> List[MemberRow]:
    members: List[MemberRow] = []
    accepted: set = set()
    index = 0
    while True:
        try:
            header = _read_decompressed(gz, TAR_BLOCK, audit)
        except _GZIP_ERRORS:
            raise ScanFailure(ARC002_ARCHIVE_INVALID, None, "gzip framing in header") from None
        if len(header) == 0:
            raise ScanFailure(ARC002_ARCHIVE_INVALID, None, "missing end-of-archive marker")
        if len(header) < TAR_BLOCK:
            raise ScanFailure(ARC002_ARCHIVE_INVALID, None, "short header block")
        if header == b"\x00" * TAR_BLOCK:
            _consume_end_of_archive(gz, audit)
            return members

        # Header framing (ARC002): checksum, magic, size encoding.
        stored_checksum = _parse_octal(header[148:156], ARC002_ARCHIVE_INVALID, index)
        computed_checksum = sum(header[:148]) + sum(b" " * 8) + sum(header[156:])
        if stored_checksum != computed_checksum:
            raise ScanFailure(ARC002_ARCHIVE_INVALID, index, "header checksum mismatch")
        magic_version = header[257:265]
        if magic_version == b"ustar\x0000":
            posix_ustar = True
        elif magic_version == b"ustar  \x00":
            posix_ustar = False
        else:
            raise ScanFailure(ARC002_ARCHIVE_INVALID, index, "unsupported tar magic")
        size = _parse_octal(header[124:136], ARC002_ARCHIVE_INVALID, index)

        name_bytes = _extract_name_bytes(header[0:100], index)
        if posix_ustar:
            prefix_bytes = _extract_name_bytes(header[345:500], index)
            if prefix_bytes:
                name_bytes = prefix_bytes + b"/" + name_bytes
        try:
            name = name_bytes.decode("utf-8", errors="strict")
        except UnicodeDecodeError:
            raise ScanFailure(ARC005_PATH_INVALID, index, "undecodable name bytes") from None

        # Per-member validation in fixed numeric code order (ARC003..ARC008).
        _validate_member_path(name, index, accepted)
        typeflag = header[156:157]
        if typeflag in (b"1", b"2"):
            raise ScanFailure(ARC007_LINK_UNSUPPORTED, index, "link member")
        if typeflag not in (b"0", b"\x00"):
            raise ScanFailure(ARC008_MEMBER_TYPE_UNSUPPORTED, index, "non-regular member")

        # Member body: bounded streaming hash; short clean read is ARC009.
        digest = hashlib.sha256()
        remaining = size
        while remaining > 0:
            try:
                chunk = _read_decompressed(gz, min(remaining, MAX_READ_CHUNK), audit)
            except _GZIP_ERRORS:
                raise ScanFailure(ARC002_ARCHIVE_INVALID, index, "gzip framing in body") from None
            if not chunk:
                raise ScanFailure(ARC009_MEMBER_SIZE_MISMATCH, index, "short member body")
            digest.update(chunk)
            remaining -= len(chunk)
        padding = (TAR_BLOCK - size % TAR_BLOCK) % TAR_BLOCK
        if padding:
            try:
                pad = _read_decompressed(gz, padding, audit)
            except _GZIP_ERRORS:
                raise ScanFailure(ARC002_ARCHIVE_INVALID, index, "gzip framing in padding") from None
            if len(pad) < padding:
                raise ScanFailure(ARC002_ARCHIVE_INVALID, index, "short member padding")

        accepted.add(name)
        members.append(MemberRow(index, name, "regular", size, digest.hexdigest()))
        index += 1


def _consume_end_of_archive(gz: gzip.GzipFile, audit: ScanAudit) -> None:
    try:
        second = _read_decompressed(gz, TAR_BLOCK, audit)
        if len(second) < TAR_BLOCK or second != b"\x00" * TAR_BLOCK:
            raise ScanFailure(ARC002_ARCHIVE_INVALID, None, "invalid end-of-archive marker")
        while True:
            trailer = _read_decompressed(gz, MAX_READ_CHUNK, audit)
            if not trailer:
                return
            if trailer.strip(b"\x00"):
                raise ScanFailure(ARC002_ARCHIVE_INVALID, None, "non-zero trailer bytes")
    except _GZIP_ERRORS:
        raise ScanFailure(ARC002_ARCHIVE_INVALID, None, "gzip framing in trailer") from None


def scan_archive(
    src: Source,
    expected_size: int,
    expected_sha256: str,
    audit: Optional[ScanAudit] = None,
) -> tuple[dict, List[MemberRow], ScanAudit]:
    """Identity gate, then strict streaming inventory. Raises ScanFailure."""
    audit = audit if audit is not None else ScanAudit()
    stream = _open_source(src, audit)
    try:
        observed_size, observed_sha256 = _hash_raw(stream, audit)
        if observed_size != expected_size or observed_sha256 != expected_sha256:
            raise ScanFailure(ARC001_IDENTITY_MISMATCH, None, "raw identity mismatch")
        stream.seek(0)
        try:
            gz = gzip.GzipFile(fileobj=stream, mode="rb")
        except _GZIP_ERRORS:
            raise ScanFailure(ARC002_ARCHIVE_INVALID, None, "gzip open failure") from None
        with gz:
            try:
                members = _scan_members(gz, audit)
            except ScanFailure:
                raise
    finally:
        if not isinstance(src, io.BytesIO):
            stream.close()
    identity = {
        "expected": {"sizeBytes": expected_size, "sha256": expected_sha256},
        "observed": {"sizeBytes": observed_size, "sha256": observed_sha256},
        "identityMatch": True,
    }
    return identity, members, audit


# --- Closed classification ----------------------------------------------------


def classify(rows: Iterable[ClassificationRow], audit: Optional[ScanAudit] = None) -> dict:
    """The closed six-condition rule. Consumes only ClassificationRow values."""
    if audit is not None:
        audit.classify_calls += 1
    materialized = list(rows)
    for row in materialized:
        if not isinstance(row, ClassificationRow):
            raise TypeError(
                "classify accepts only ClassificationRow(path, kind, size) values"
            )

    paths = [row.path for row in materialized]
    root_regular_nonempty = all(
        row.kind == "regular" and row.size > 0 and "/" not in row.path
        for row in materialized
    )
    parameter_once = paths.count(_ANCHOR_PARAMETER) == 1
    miniloader_once = paths.count(_ANCHOR_MINILOADER) == 1
    uboot_once = paths.count(_ANCHOR_UBOOT) == 1
    extra_images = (
        sum(1 for p in paths if p.endswith(".img") and p != _ANCHOR_UBOOT) >= 2
    )
    allowlist = all(
        p in (_ANCHOR_PARAMETER, _ANCHOR_MINILOADER, _ANCHOR_UBOOT)
        or p.endswith(".img")
        or p in _EXTRA_ALLOWLIST
        for p in paths
    )

    outcomes = (
        root_regular_nonempty,
        parameter_once,
        miniloader_once,
        uboot_once,
        extra_images,
        allowlist,
    )
    conditions = [
        {"id": cid, "passed": passed} for cid, passed in zip(CONDITION_IDS, outcomes)
    ]
    failed = [cid for cid, passed in zip(CONDITION_IDS, outcomes) if not passed]
    family = "rockchipRawImageSet" if all(outcomes) else "unknown"
    return {
        "conditions": conditions,
        "failedConditionIds": failed,
        "imagePackageFamily": family,
        "classificationScope": "fixedArchiveOnly",
        "authoritative": False,
        "deviceFlashProvider": "unknown",
        "targetCompatibility": "unknown",
        "imageProfileReadiness": "candidateNonExecutable",
        "executableProfile": False,
        "hardwareSupportClaim": False,
    }


# --- Measured hazard suite (recorded into member-inventory.json) --------------


def run_hazard_suite(audit: ScanAudit) -> List[dict]:
    """Execute every synthetic hazard vector in memory and record the measured
    rejection code plus the measured classifier call count (zero)."""
    import fixtures  # test-only synthetic bytes; imported lazily, never disk-backed

    results = []
    for case in fixtures.hazard_cases():
        vector_audit = ScanAudit()
        observed = None
        try:
            scan_archive(
                io.BytesIO(case.archive_bytes),
                case.expected_size,
                case.expected_sha256,
                vector_audit,
            )
        except ScanFailure as failure:
            observed = failure.code
        audit.hazard_vectors_executed += 1
        results.append(
            {
                "vector": case.name,
                "expectedCode": case.expected_code,
                "observedCode": observed,
                "classifierCalls": vector_audit.classify_calls,
                "rejectedBeforeClassification": (
                    observed is not None and vector_audit.classify_calls == 0
                ),
                "passed": observed == case.expected_code
                and vector_audit.classify_calls == 0,
            }
        )
    return results


# --- Minimal closed-schema validator ------------------------------------------


def _type_matches(value, type_name: str) -> bool:
    if type_name == "object":
        return isinstance(value, dict)
    if type_name == "array":
        return isinstance(value, list)
    if type_name == "string":
        return isinstance(value, str)
    if type_name == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    if type_name == "boolean":
        return isinstance(value, bool)
    if type_name == "null":
        return value is None
    raise SchemaValidationError(f"unsupported schema type: {type_name}")


def _const_equal(value, const) -> bool:
    if isinstance(const, bool) or isinstance(value, bool):
        return type(value) is type(const) and value == const
    return value == const


def validate_schema(instance, schema: dict, path: str = "$") -> None:
    if "const" in schema:
        if not _const_equal(instance, schema["const"]):
            raise SchemaValidationError(f"{path}: expected const {schema['const']!r}")
    if "enum" in schema:
        if not any(_const_equal(instance, option) for option in schema["enum"]):
            raise SchemaValidationError(f"{path}: value not in enum")
    if "type" in schema and not _type_matches(instance, schema["type"]):
        raise SchemaValidationError(f"{path}: expected type {schema['type']}")
    if "pattern" in schema:
        if not isinstance(instance, str) or not re.search(schema["pattern"], instance):
            raise SchemaValidationError(f"{path}: pattern mismatch")
    if "minimum" in schema:
        if not isinstance(instance, int) or isinstance(instance, bool):
            raise SchemaValidationError(f"{path}: minimum requires integer")
        if instance < schema["minimum"]:
            raise SchemaValidationError(f"{path}: below minimum")
    if isinstance(instance, dict):
        properties = schema.get("properties", {})
        for key in schema.get("required", []):
            if key not in instance:
                raise SchemaValidationError(f"{path}: missing required {key}")
        if schema.get("additionalProperties") is False:
            for key in instance:
                if key not in properties:
                    raise SchemaValidationError(f"{path}: unexpected property {key}")
        for key, subschema in properties.items():
            if key in instance:
                validate_schema(instance[key], subschema, f"{path}.{key}")
    if isinstance(instance, list) and "items" in schema:
        for position, element in enumerate(instance):
            validate_schema(element, schema["items"], f"{path}[{position}]")


def _load_schema(evidence_name: str) -> dict:
    with open(os.path.join(_SCHEMA_DIR, _SCHEMA_FILES[evidence_name]), "rb") as handle:
        return json.loads(handle.read().decode("utf-8"))


# --- Evidence pipeline --------------------------------------------------------


def _serialize(document: dict) -> bytes:
    return (
        json.dumps(document, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    ).encode("utf-8")


def _write_evidence(out_dir: str, name: str, payload: bytes, audit: ScanAudit) -> None:
    """Single evidence write choke point: allowlisted names, never overwrite."""
    if name not in EVIDENCE_OUTPUTS:
        audit.writes_outside_allowed_outputs += 1
        raise ScanToolError(f"refusing non-allowlisted evidence output: {name}")
    target = os.path.join(out_dir, name)
    try:
        with open(target, "xb") as handle:
            handle.write(payload)
    except FileExistsError:
        raise ScanToolError(f"refusing to overwrite existing evidence: {name}") from None
    audit.evidence_files_written.append(name)


_GAPS = [
    {
        "id": "GAP-DAYU200-PARTITION-SEMANTICS",
        "area": "partition semantics",
        "status": "unknown",
        "note": "parameter.txt partition table semantics are not interpreted; "
        "member bytes are hashed but never decoded.",
    },
    {
        "id": "GAP-DAYU200-FLASH-ADDRESSES",
        "area": "flash addresses",
        "status": "unknown",
        "note": "no flash offset/address mapping is derived from any member.",
    },
    {
        "id": "GAP-DAYU200-FLASH-PROTOCOL",
        "area": "flash protocol",
        "status": "unknown",
        "note": "no flashd/rockusb/USB/UART/TCP protocol fact is established.",
    },
    {
        "id": "GAP-DAYU200-RECOVERY-PATH",
        "area": "recovery path",
        "status": "unknown",
        "note": "no recovery/rescue path for an interrupted flash is established.",
    },
]


def build_evidence(
    src: Source,
    out_dir: str,
    expected_size: int = EXPECTED_RAW_SIZE,
    expected_sha256: str = EXPECTED_RAW_SHA256,
) -> ScanAudit:
    """Scan, classify and write the five allowed evidence outputs."""
    audit = ScanAudit()
    identity, members, _ = scan_archive(src, expected_size, expected_sha256, audit)
    hazard_suite = run_hazard_suite(audit)
    classification = classify(
        (ClassificationRow(m.path, m.kind, m.size) for m in members), audit
    )

    identity_doc = {"schema": "arkdeck-char-archive-identity-1.0.0", **identity}
    inventory_doc = {
        "schema": "arkdeck-char-member-inventory-1.0.0",
        "archiveSha256": identity["observed"]["sha256"],
        "memberCount": len(members),
        "members": [
            {
                "index": m.index,
                "path": m.path,
                "kind": m.kind,
                "sizeBytes": m.size,
                "sha256": m.sha256,
            }
            for m in members
        ],
        "hazardSuite": hazard_suite,
    }
    classification_doc = {
        "schema": "arkdeck-char-package-classification-1.0.0",
        "classifierInput": {
            "memberCount": len(members),
            "projectionFields": ["path", "kind", "size"],
        },
        **classification,
        "gaps": _GAPS,
    }
    audit_doc = {
        "schema": "arkdeck-char-process-audit-1.0.0",
        "pythonVersion": "%d.%d.%d" % sys.version_info[:3],
        "configuredMaxReadChunkBytes": MAX_READ_CHUNK,
        "maxObservedReadChunkBytes": audit.max_observed_read_chunk,
        "rawBytesRead": audit.raw_bytes_read,
        "uncompressedBytesRead": audit.uncompressed_bytes_read,
        "archiveOpenModes": sorted(set(audit.archive_open_modes)),
        "hazardVectorsExecuted": audit.hazard_vectors_executed,
        "allowedEvidenceOutputs": list(EVIDENCE_OUTPUTS),
        "writesOutsideAllowedOutputs": audit.writes_outside_allowed_outputs,
        "memberExtractionToDiskCount": 0,
        "memberExecutionCount": 0,
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
            "readMetrics": "instrumented at the scanner I/O choke points",
            "writeMetrics": "instrumented at the single evidence write choke point",
            "dispatchCounters": "structural-zero: no such code path exists in this "
            "tool; asserted by the static import/AST audit in test_scan.py",
        },
    }

    documents = {
        "archive-identity.json": identity_doc,
        "member-inventory.json": inventory_doc,
        "package-classification.json": classification_doc,
        "process-audit.json": audit_doc,
    }
    payloads = {}
    for name, document in documents.items():
        validate_schema(document, _load_schema(name), f"$({name})")
        payloads[name] = _serialize(document)

    os.makedirs(out_dir, exist_ok=True)
    for name in documents:
        _write_evidence(out_dir, name, payloads[name], audit)

    summary_lines = [
        "# DAYU200 archive characterization summary",
        "",
        "Non-authoritative, fixed-archive-only characterization evidence",
        "(CHG-2026-003 / TASK-DAYU200-CHAR-001). `unknown` axes are expected",
        "outputs, not defects. This summary derives from the four JSON results:",
        "",
        "| Evidence file | SHA-256 |",
        "| --- | --- |",
    ]
    for name in documents:
        summary_lines.append(f"| `{name}` | `{hashlib.sha256(payloads[name]).hexdigest()}` |")
    summary_lines += [
        "",
        f"- imagePackageFamily: `{classification['imagePackageFamily']}`",
        "- deviceFlashProvider: `unknown`; targetCompatibility: `unknown`;",
        "  imageProfileReadiness: `candidateNonExecutable`;",
        "  executableProfile: `false`; hardwareSupportClaim: `false`.",
        "",
        "## Gaps feeding DEC-002 and the Route-B CLI plan-only work",
        "",
    ]
    for gap in _GAPS:
        summary_lines.append(f"- `{gap['id']}` ({gap['area']}): {gap['note']}")
    summary_lines += [
        "",
        "## Non-authoritative follow-up recommendations",
        "",
        "- Resolve the four gaps above via the later Integration change before",
        "  any Flash Provider decision (DEC-002); this evidence cannot satisfy it.",
        "- Keep the raw archive outside the repository; only size/SHA-256 and",
        "  member hashes are recorded here.",
        "- Any executable-profile or hardware claim requires separate M0B work;",
        "  nothing in this run supports one.",
        "",
    ]
    _write_evidence(out_dir, "summary.md", "\n".join(summary_lines).encode("utf-8"), audit)
    return audit


# --- Production CLI (no identity bypass) --------------------------------------


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="scan.py",
        description="Read-only DAYU200 archive characterization (fixed identity gate).",
    )
    parser.add_argument("--archive", required=True, help="path to the raw .tar.gz")
    parser.add_argument("--out-dir", required=True, help="evidence output directory")
    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    arguments = build_arg_parser().parse_args(argv)
    try:
        audit = build_evidence(arguments.archive, arguments.out_dir)
    except ScanFailure as failure:
        print(f"scan failed: {failure.code}", file=sys.stderr)
        return 1
    except ScanToolError as error:
        print(f"tool error: {error}", file=sys.stderr)
        return 2
    print("scan ok: evidence written:", ", ".join(audit.evidence_files_written))
    return 0


if __name__ == "__main__":
    sys.exit(main())
