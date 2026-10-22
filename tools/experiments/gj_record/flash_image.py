"""GJ-4's version witness from the consumed, fully read imported image.

No local source file, filename, caller expectation or device answer is used.
Only already captured Runtime replies are read; nothing is extracted or run.
"""
from __future__ import annotations

import base64
import binascii
import gzip
import hashlib
import io
import re

from .run import Run, Step

# The published CLI's flash-bundle import limit, not the small document limit.
MAX_ARCHIVE_BYTES = 8 * 1024**3
MAX_CHUNK_BYTES = 4 * 1024**2
MAX_EXPANDED_BYTES = 64 * 1024**3
MAX_MEMBERS = 1024
_DIGEST = re.compile(r"[0-9a-f]{64}\Z")
_POSITIVE = re.compile(r"[1-9][0-9]*\Z")
_KEY = b"const.ohos.fullname="
_VALUE = frozenset(b"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")


class ImageProofError(ValueError):
    """A bounded reason, never an account path or a raw image value."""


class MissingImageProof(ImageProofError):
    pass


def _require(holds: bool, reason: str) -> None:
    if not holds:
        raise ImageProofError(reason)


def _digest(value) -> bool:
    return isinstance(value, str) and _DIGEST.fullmatch(value) is not None


def _positive(value) -> bool:
    return isinstance(value, str) and len(value) <= 20 and _POSITIVE.fullmatch(value) is not None


def _object(value, reason: str) -> dict:
    _require(isinstance(value, dict), reason)
    return value


def _import_id(step: Step):
    imported = step.result.get("import")
    return imported.get("importId") if isinstance(imported, dict) else None


class _CapturedArchive(io.RawIOBase):
    """Decode at most one bounded CLI chunk at a time, with whole SHA proof."""

    def __init__(self, steps: list[Step], import_id: str, artifact: str, digest: str, total: int):
        super().__init__()
        self.steps = iter(steps)
        self.import_id, self.artifact, self.digest, self.total = import_id, artifact, digest, total
        self.piece = b""
        self.position = self.count = 0
        self.finished = False
        self.hash = hashlib.sha256()

    def readable(self) -> bool:
        return True

    def _next(self) -> bool:
        if self.finished:
            return False
        step = next(self.steps, None)
        if step is None:
            raise ImageProofError("imported archive read is incomplete")
        r = step.result
        _require(step.ok and step.exit_code == 0, "imported archive read was refused")
        _require(step.option("--import") == self.import_id and not step.has_flag("--job")
                 and step.option("--job") is None
                 and step.option("--artifact") == self.artifact
                 and r.get("artifactId") == self.artifact, "imported archive read owner differs")
        _require(r.get("artifactDigest") == self.digest
                 and type(r.get("totalByteCount")) is int and r["totalByteCount"] == self.total,
                 "imported archive read digest or length differs")
        _require(type(r.get("offset")) is int and r["offset"] == self.count
                 and (step.option("--offset") == str(self.count)
                      or (self.count == 0 and step.option("--offset") is None)),
                 "imported archive read is not contiguous")
        size = r.get("byteCount")
        _require(type(size) is int and 0 < size <= MAX_CHUNK_BYTES
                 and self.count + size <= self.total, "imported archive chunk size is invalid")
        encoded = r.get("base64")
        _require(isinstance(encoded, str) and len(encoded) <= ((MAX_CHUNK_BYTES + 2) // 3) * 4,
                 "imported archive chunk encoding is unbounded")
        try:
            piece = base64.b64decode(encoded, validate=True)
        except (ValueError, binascii.Error) as error:
            raise ImageProofError("imported archive chunk encoding is invalid") from error
        _require(len(piece) == size and type(r.get("nextOffset")) is int
                 and r["nextOffset"] == self.count + size and type(r.get("eof")) is bool
                 and r["eof"] == (self.count + size == self.total),
                 "imported archive chunk count or EOF differs")
        self.count += size
        self.hash.update(piece)
        self.piece, self.position = piece, 0
        if r["eof"]:
            _require(next(self.steps, None) is None, "imported archive has additional read chunks")
            _require(self.hash.hexdigest() == self.digest, "imported archive whole SHA differs")
            self.finished = True
        return True

    def readinto(self, buffer) -> int:
        if self.position == len(self.piece) and not self._next():
            return 0
        size = min(len(buffer), len(self.piece) - self.position)
        buffer[:size] = self.piece[self.position:self.position + size]
        self.position += size
        return size


class _VersionScanner:
    def __init__(self):
        self.tail = b""
        self.versions: set[str] = set()

    def consume(self, piece: bytes) -> None:
        data = self.tail + piece
        cursor = 0
        while (start := data.find(_KEY, cursor)) >= 0:
            start += len(_KEY)
            end = start
            while end < len(data) and data[end] in _VALUE:
                end += 1
                _require(end - start <= 256, "system-image version is too long")
            if end < len(data):
                _require(end > start, "system-image version is empty")
                self.versions.add(data[start:end].decode("ascii"))
            cursor = end + 1
        self.tail = data[-(len(_KEY) + 257):]

    def finish(self) -> str:
        start = self.tail.rfind(_KEY)
        if start >= 0:
            value = self.tail[start + len(_KEY):]
            _require(any(byte not in _VALUE for byte in value), "system-image version is unterminated")
        _require(len(self.versions) == 1, "system-image version is absent or conflicting")
        return next(iter(self.versions))


def _number(field: bytes) -> int:
    if field[0] & 0x80:
        value = int.from_bytes(bytes([field[0] & 0x7f]) + field[1:], "big")
    else:
        text = field.strip(b" \x00")
        _require(bool(text) and all(byte in b"01234567" for byte in text), "invalid tar number")
        value = int(text, 8)
    _require(value <= MAX_EXPANDED_BYTES, "tar member exceeds bounded image size")
    return value


def _image_version(source: io.RawIOBase) -> str:
    """Strict ordinary gzip/tar; bounded streaming, no tar extraction API."""
    expanded = 0
    names: set[bytes] = set()
    scanner = None
    with gzip.GzipFile(fileobj=source, mode="rb") as image:
        def exact(size: int) -> bytes:
            nonlocal expanded
            data = image.read(size)
            expanded += len(data)
            _require(expanded <= MAX_EXPANDED_BYTES, "archive expansion exceeds bounded image size")
            _require(len(data) == size, "image tar is truncated")
            return data

        while True:
            header = exact(512)
            if header == bytes(512):
                _require(exact(512) == bytes(512), "image tar terminator is invalid")
                while data := image.read(1024 * 1024):
                    expanded += len(data)
                    _require(expanded <= MAX_EXPANDED_BYTES and not any(data), "image tar has trailing payload")
                break
            _require(len(names) < MAX_MEMBERS, "image tar has too many members")
            checksum = sum(header[:148]) + 8 * 32 + sum(header[156:])
            _require(_number(header[148:156]) == checksum, "image tar header checksum differs")
            name = header[:100].split(b"\0", 1)[0]
            prefix = header[345:500].split(b"\0", 1)[0]
            _require(not prefix and name and name.isascii() and b"/" not in name
                     and b"\\" not in name and name not in (b".", b"..") and name not in names,
                     "image tar member name is unsafe or duplicated")
            names.add(name)
            _require(header[156:157] in (b"0", b"\0") and not any(header[157:257]),
                     "image tar member is not a plain regular file")
            size = _number(header[124:136])
            member_scanner = _VersionScanner() if name == b"system.img" else None
            remaining = size
            while remaining:
                piece = exact(min(remaining, 1024 * 1024))
                if member_scanner is not None:
                    member_scanner.consume(piece)
                remaining -= len(piece)
            exact((-size) % 512)
            if member_scanner is not None:
                scanner = member_scanner
        _require(scanner is not None, "system image is missing from imported archive")
        return scanner.finish()


def consumed_image_version(run: Run, flash: Step) -> tuple[dict, list[Step]]:
    """Bind the actual Job's original consumed lease to an enriched inspection
    and contiguous whole Runtime byte reads, then derive the system version."""
    evidence = _object(flash.result.get("evidence"), "flash evidence is absent or malformed")
    parameters = _object(evidence.get("parameters"), "flash consumed inputs are absent or malformed")
    authority = _object(evidence.get("authority"), "flash consumed authority is absent or malformed")
    _require(evidence.get("operationReference") == "flash.full-restore@1"
             and evidence.get("actualEffect") == "destructive" and evidence.get("providerId") == "arkforge"
             and isinstance(evidence.get("observation"), dict)
             and evidence["observation"].get("providerId") == "arkforge", "flash consumed operation or provider differs")
    lease = parameters.get("artifactLease")
    _require(isinstance(lease, str) and len(parts := lease.split(":")) == 3
             and parts[0] == "lease-v1" and parts[1] and parts[2], "flash consumed image lease is absent")
    import_id, artifact = parts[1:]
    _require(parameters.get("deviceProfileRef") == "dayu200" and parameters.get("intent") == "fullRestore"
             and parameters.get("verification") == "full"
             and set(parameters) == {"artifactLease", "deviceProfileRef", "intent", "verification"},
             "flash consumed image profile or inputs differ")
    candidates = run.of("artifact.import.inspect", lambda s: s.ok and _import_id(s) == import_id)
    if not candidates:
        raise MissingImageProof("consumed image import inspection was not captured")
    request = candidates[-1].result["import"].get("importRequestId")
    inspect = run.last("artifact.import.inspect", lambda s: s.option("--import") == import_id
                       or (isinstance(request, str) and s.option("--import-request-id") == request)
                       or _import_id(s) == import_id)
    _require(inspect is not None and inspect.ok and inspect.exit_code == 0,
             "consumed image import inspection was refused")
    _require((inspect.option("--import") == import_id and inspect.option("--import-request-id") is None)
             or (inspect.option("--import") is None and inspect.option("--import-request-id") == request),
             "consumed image inspection request owner differs")
    imported = _object(inspect.result.get("import"), "consumed image inspection is malformed")
    metadata = _object(imported.get("metadata"), "consumed image metadata is malformed")
    receipt = _object(imported.get("receipt"), "consumed image receipt is malformed")
    _require(inspect.result.get("schemaVersion") == "arkdeck.import-inspection/1"
             and imported.get("schemaVersion") == "arkdeck.import/1"
             and metadata.get("schemaVersion") == "arkdeck.import-intent/1"
             and receipt.get("schemaVersion") == "arkdeck.import-receipt/1"
             and imported.get("state") in ("committed", "released")
             and imported.get("importId") == receipt.get("importId") == import_id
             and isinstance(request, str) and bool(request)
             and imported.get("importRequestId") == metadata.get("importRequestId")
             == receipt.get("importRequestId") == request
             and receipt.get("owner") == {"kind": "import", "id": import_id}
             and receipt.get("artifactId") == artifact and receipt.get("lease") == lease,
             "consumed image import receipt identity differs")
    digest = metadata.get("sha256")
    _require(_digest(digest) and receipt.get("artifactDigest") == digest
             and _positive(metadata.get("byteCount")) and metadata["byteCount"] == receipt.get("byteCount")
             and 0 < int(metadata["byteCount"]) <= MAX_ARCHIVE_BYTES
             and metadata.get("kind") == "flash-bundle" and metadata.get("deviceProfile") == "dayu200"
             and receipt.get("validation") == {"kind": "flash-bundle", "deviceProfile": "dayu200"}
             and all(metadata.get(k) == receipt.get(k) for k in ("targetId", "bindingRevision", "name"))
             and all(isinstance(metadata.get(k), str) and bool(metadata[k]) for k in ("targetId", "name"))
             and metadata.get("targetId") == evidence.get("targetId")
             and _positive(metadata.get("bindingRevision"))
             and type(evidence.get("bindingRevision")) is int
             and metadata["bindingRevision"] == str(evidence["bindingRevision"]),
             "consumed image receipt content or original target binding differs")
    _require(authority.get("kind") == "runtimeCapability" and authority.get("artifactDigest") == digest
             and all(_digest(authority.get(k)) for k in
                     ("planDigest", "stepSetDigest", "consumptionFingerprintSha256", "targetBindingDigest"))
             and type(authority.get("useOrdinal")) is int and authority["useOrdinal"] > 0
             and all(isinstance(authority.get(k), str) and bool(authority[k]) for k in
                     ("reference", "reservationId", "admittedAtUtc", "validUntilUtc")),
             "flash original consumed authority does not bind the image")
    reads = run.of("artifact.read", lambda s: s.option("--import") == import_id
                   and s.option("--artifact") == artifact)
    if not reads:
        raise MissingImageProof("consumed image whole Artifact bytes were not captured")
    # A later refusal is never hidden by choosing the last successful reply.
    _require(all(s.ok and s.exit_code == 0 for s in reads), "consumed image byte read was refused")
    # Repeated immutable reads are allowed only when they repeat the same full
    # wire reply. An inconsistent earlier reply cannot be hidden by a refresh.
    by_offset: dict[int, Step] = {}
    for read in reads:
        offset = read.result.get("offset")
        _require(type(offset) is int and offset >= 0, "imported archive read offset is invalid")
        _require(not read.has_flag("--job") and read.option("--job") is None
                 and (read.option("--offset") == str(offset)
                 or (offset == 0 and read.option("--offset") is None)),
                 "imported archive read owner or offset differs")
        previous = by_offset.get(offset)
        _require(previous is None or previous.result == read.result,
                 "imported archive repeated read differs")
        by_offset[offset] = read
    total = int(metadata["byteCount"])
    source = _CapturedArchive([by_offset[k] for k in sorted(by_offset)], import_id, artifact, digest, total)
    try:
        version = _image_version(source)
        _require(source.finished and source.count == total and source.position == len(source.piece),
                 "consumed image archive bytes are incomplete")
    except (OSError, EOFError, ValueError) as error:
        if isinstance(error, ImageProofError):
            raise
        raise ImageProofError("consumed image gzip or tar is malformed") from error
    return {"deviceProfileRef": "dayu200", "archiveSha256": digest,
            "byteCount": total, "runtimeBuildVersion": version}, [inspect, *reads]
