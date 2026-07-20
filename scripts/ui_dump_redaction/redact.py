#!/usr/bin/env python3
"""Deterministic, fail-closed UI Dump derived-golden redaction.

This tool is intentionally offline and stdlib-only. It reads one bounded raw
file through a read-only descriptor, verifies the caller-provided whole-stream
SHA-256, transforms every non-allowlisted token to a typed ordinal placeholder,
performs an independent output-shape/sensitive-literal check, and only then
creates a derived file and closed-schema receipt with exclusive writes.

The raw input is never logged, returned, modified, or used as a path source.
Exit status is the stable error code declared by algorithm-v1.json.
"""

from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import os
import pathlib
import re
import stat
import sys
import unicodedata
from dataclasses import dataclass, field
from typing import Any


_SCRIPT_DIR = pathlib.Path(__file__).resolve().parent
_REPOSITORY_ROOT = _SCRIPT_DIR.parent.parent.resolve()
_RECEIPT_SCHEMA_PATH = _SCRIPT_DIR / "redaction-receipt.schema.json"
_SHA256_RE = re.compile(r"[0-9a-f]{64}")
_SAFE_LITERAL_RE = re.compile(r"[A-Za-z][A-Za-z0-9_-]{0,63}")
_PLACEHOLDER_RE = re.compile(r"@R-(?:ID|NU|PA|PK|QU|TX)-[0-9]{6}@")
_PACKAGE_RE = re.compile(
    r"(?:[A-Za-z_][A-Za-z0-9_]*\.){2,}[A-Za-z_][A-Za-z0-9_]*"
)
_NUMBER_RE = re.compile(
    r"[-+]?(?:0[xX][0-9A-Fa-f]+|[0-9]+(?:\.[0-9]+)?(?:[eE][-+]?[0-9]+)?)(?:[xX][0-9]+)?"
)
_IDENTIFIER_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_.-]*")
_USER_PATH_RE = re.compile(rb"/(?:Users|home)/[^/\s\x00:]+|/var/root")
_KEY_MARKERS = (
    b"-----BEGIN",
    b"PRIVATE KEY",
    b"ssh-rsa ",
    b"ssh-ed25519 ",
    b"PuTTY-User-Key",
)
_PUNCTUATION = frozenset("(),:<=>[{}]")
_TYPE_CODES = ("ID", "NU", "PA", "PK", "QU", "TX")
_APPROVED_SAFE_LITERALS: tuple[str, ...] = ()
_CONFUSABLE_NAME_PREFIXES = (
    "ARMENIAN ",
    "CHEROKEE ",
    "CYRILLIC ",
    "FULLWIDTH ",
    "GREEK ",
    "MATHEMATICAL ",
    "SMALL ",
)


ERROR_CODES = {
    "MANIFEST_INVALID": 20,
    "ALLOWLIST_INVALID": 21,
    "PATH_CONFLICT": 22,
    "OUTPUT_EXISTS": 23,
    "INPUT_HASH_MISMATCH": 24,
    "INPUT_TOO_LARGE": 25,
    "INVALID_UTF8": 26,
    "INVALID_UNICODE": 27,
    "INVALID_LINE": 28,
    "INVALID_TOKEN": 29,
    "RESOURCE_LIMIT": 30,
    "SENSITIVE_OUTPUT": 31,
    "IO_ERROR": 32,
}


_EXPECTED_MANIFEST = {
    "schema": "arkdeck-ui-dump-redaction-algorithm-1.0.0",
    "algorithmId": "uidump-derived-redaction-v1",
    "version": 1,
    "encoding": {
        "input": "UTF-8",
        "invalidInput": "reject",
        "output": "ASCII",
    },
    "pathPolicy": {
        "repositoryRoot": "resolved-redactor-source-two-level-ancestor",
        "input": "regular-read-only-no-follow-nonblocking-outside-repository",
        "output": "exclusive-create-outside-repository",
        "receipt": "exclusive-create-outside-repository",
        "conflicts": "resolved-input-output-receipt-paths-must-be-distinct",
    },
    "normalization": {
        "unicode": "require-NFC",
        "acceptedLineEndings": ["LF", "CRLF", "CR"],
        "outputLineEnding": "LF",
        "terminalLineEnding": "exactly-one-LF",
        "rejectedUnicodeCategories": ["Cc", "Cf", "Cn", "Co", "Cs"],
        "rejectedConfusableNamePrefixes": [
            "ARMENIAN ",
            "CHEROKEE ",
            "CYRILLIC ",
            "FULLWIDTH ",
            "GREEK ",
            "MATHEMATICAL ",
            "SMALL ",
        ],
        "bidiControls": "reject-via-Unicode-category-Cf",
    },
    "grammar": {
        "whitespace": "ASCII-space-runs-collapse-to-one;tabs-and-other-controls-reject",
        "blankLines": "preserve-order-and-count",
        "punctuation": ["(", ")", ",", ":", "<", "=", ">", "[", "]", "{", "}"],
        "quotedStrings": (
            "JSON-double-quoted;validate-escapes;reject-all-decoded-Cc;"
            "redact-decoded-value;preserve-quotes"
        ),
        "safeLiteralMatch": "v1-allowlist-empty;no-input-token-retained",
        "tokenClassesOrdered": ["PA", "PK", "NU", "ID", "TX"],
        "tokenClassRules": {
            "PA": "contains-forward-or-backslash-or-leading-tilde",
            "PK": "three-or-more-dot-separated-ASCII-identifiers",
            "NU": "signed-decimal-float-exponent-hex-or-dimension-number",
            "ID": "ASCII-identifier-with-dot-dash-underscore-tail",
            "TX": "remaining-valid-nonempty-Unicode-token",
            "QU": "decoded-valid-JSON-double-quoted-token",
        },
        "unknownTokenOrLine": "reject",
    },
    "placeholders": {
        "format": "@R-{TYPE}-{ORDINAL_6_DECIMAL}@",
        "types": ["ID", "NU", "PA", "PK", "QU", "TX"],
        "ordinalScope": "per-type-first-occurrence",
        "duplicates": (
            "reuse-first-placeholder-for-identical-type-and-decoded-token"
        ),
        "ordering": "preserve-input-line-and-token-order",
    },
    "limits": {
        "inputBytes": 8_388_608,
        "derivedBytes": 16_777_216,
        "safeLiteralBytes": 65_536,
        "lines": 100_000,
        "tokens": 1_000_000,
        "tokenBytes": 4_096,
        "tokensPerLine": 16_384,
    },
    "errorCodes": ERROR_CODES,
    "hashPins": {
        "safeLiteralsSha256": "<sha256>",
        "receiptSchemaSha256": "<sha256>",
    },
}


class RedactionError(Exception):
    """A stable, non-sensitive redaction failure."""

    def __init__(self, name: str):
        if name not in ERROR_CODES:
            raise ValueError("unknown redaction error name")
        super().__init__(name)
        self.name = name
        self.exit_code = ERROR_CODES[name]


class SchemaValidationError(Exception):
    """The generated receipt does not satisfy its closed local schema."""


@dataclass
class TransformResult:
    derived: bytes
    replacement_total: int
    replacement_unique: int
    replacements_by_type: dict[str, int]
    unique_by_type: dict[str, int]
    line_endings: dict[str, int]
    line_count: int
    token_count: int
    checked_sensitive_literals: int


@dataclass
class _TransformState:
    safe_literals: frozenset[str]
    limits: dict[str, int]
    placeholders: dict[tuple[str, str], str] = field(default_factory=dict)
    next_ordinals: dict[str, int] = field(
        default_factory=lambda: {code: 1 for code in _TYPE_CODES}
    )
    replacements_by_type: dict[str, int] = field(
        default_factory=lambda: {code: 0 for code in _TYPE_CODES}
    )
    unique_by_type: dict[str, int] = field(
        default_factory=lambda: {code: 0 for code in _TYPE_CODES}
    )
    sensitive_literals: set[str] = field(default_factory=set)
    token_count: int = 0

    def placeholder(self, type_code: str, semantic: str) -> str:
        key = (type_code, semantic)
        self.replacements_by_type[type_code] += 1
        self.sensitive_literals.add(semantic)
        existing = self.placeholders.get(key)
        if existing is not None:
            return existing
        ordinal = self.next_ordinals[type_code]
        if ordinal > 999_999:
            raise RedactionError("RESOURCE_LIMIT")
        value = f"@R-{type_code}-{ordinal:06d}@"
        self.next_ordinals[type_code] = ordinal + 1
        self.placeholders[key] = value
        self.unique_by_type[type_code] += 1
        return value


def _sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _read_small_file(path: os.PathLike[str] | str, maximum: int, error: str) -> bytes:
    flags = os.O_RDONLY
    flags |= getattr(os, "O_CLOEXEC", 0)
    flags |= getattr(os, "O_NOFOLLOW", 0)
    flags |= getattr(os, "O_NONBLOCK", 0)
    descriptor = -1
    try:
        descriptor = os.open(path, flags)
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode) or before.st_size > maximum:
            raise RedactionError(error)
        chunks: list[bytes] = []
        remaining = maximum + 1
        while remaining:
            chunk = os.read(descriptor, min(262_144, remaining))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        data = b"".join(chunks)
        after = os.fstat(descriptor)
        if (
            len(data) != before.st_size
            or (
                before.st_dev,
                before.st_ino,
                before.st_size,
                before.st_mtime_ns,
            )
            != (
                after.st_dev,
                after.st_ino,
                after.st_size,
                after.st_mtime_ns,
            )
        ):
            raise RedactionError(error)
    except RedactionError:
        raise
    except (OSError, ValueError) as exc:
        raise RedactionError(error) from exc
    finally:
        if descriptor >= 0:
            os.close(descriptor)
    if len(data) > maximum:
        raise RedactionError(error)
    return data


def _reject_json_constant(_value: str) -> None:
    raise ValueError("non-finite JSON number")


def _reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate JSON key")
        result[key] = value
    return result


def _load_json(data: bytes, error: str) -> dict[str, Any]:
    try:
        text = data.decode("utf-8", errors="strict")
        value = json.loads(
            text,
            object_pairs_hook=_reject_duplicate_keys,
            parse_constant=_reject_json_constant,
        )
    except (UnicodeDecodeError, json.JSONDecodeError, ValueError) as exc:
        raise RedactionError(error) from exc
    if not isinstance(value, dict):
        raise RedactionError(error)
    return value


def load_manifest(path: os.PathLike[str] | str) -> tuple[dict[str, Any], bytes]:
    data = _read_small_file(path, 262_144, "MANIFEST_INVALID")
    manifest = _load_json(data, "MANIFEST_INVALID")
    normalized = dict(manifest)
    pins = manifest.get("hashPins")
    if not isinstance(pins, dict) or set(pins) != {
        "safeLiteralsSha256",
        "receiptSchemaSha256",
    }:
        raise RedactionError("MANIFEST_INVALID")
    if not all(
        isinstance(value, str) and _SHA256_RE.fullmatch(value)
        for value in pins.values()
    ):
        raise RedactionError("MANIFEST_INVALID")
    normalized["hashPins"] = {
        "safeLiteralsSha256": "<sha256>",
        "receiptSchemaSha256": "<sha256>",
    }
    if normalized != _EXPECTED_MANIFEST:
        raise RedactionError("MANIFEST_INVALID")
    return manifest, data


def load_safe_literals(
    path: os.PathLike[str] | str, manifest: dict[str, Any]
) -> tuple[frozenset[str], bytes]:
    maximum = manifest["limits"]["safeLiteralBytes"]
    data = _read_small_file(path, maximum, "ALLOWLIST_INVALID")
    if _sha256(data) != manifest["hashPins"]["safeLiteralsSha256"]:
        raise RedactionError("ALLOWLIST_INVALID")
    if data:
        if (
            not data.endswith(b"\n")
            or b"\r" in data
            or data.startswith(b"\xef\xbb\xbf")
        ):
            raise RedactionError("ALLOWLIST_INVALID")
        try:
            text = data.decode("ascii", errors="strict")
        except UnicodeDecodeError as exc:
            raise RedactionError("ALLOWLIST_INVALID") from exc
        values = text[:-1].split("\n")
    else:
        values = []
    if (
        any(not value or not _SAFE_LITERAL_RE.fullmatch(value) for value in values)
        or values != sorted(values)
        or len(values) != len(set(values))
        or tuple(values) != _APPROVED_SAFE_LITERALS
    ):
        raise RedactionError("ALLOWLIST_INVALID")
    return frozenset(values), data


def load_receipt_schema(manifest: dict[str, Any]) -> tuple[dict[str, Any], bytes]:
    data = _read_small_file(_RECEIPT_SCHEMA_PATH, 262_144, "MANIFEST_INVALID")
    if _sha256(data) != manifest["hashPins"]["receiptSchemaSha256"]:
        raise RedactionError("MANIFEST_INVALID")
    schema = _load_json(data, "MANIFEST_INVALID")
    if (
        schema.get("$id")
        != "https://arkdeck.local/schemas/ui-dump-redaction-receipt-1.0.0.json"
        or schema.get("type") != "object"
        or schema.get("additionalProperties") is not False
    ):
        raise RedactionError("MANIFEST_INVALID")
    return schema, data


def _canonical_path(value: str) -> pathlib.Path:
    if not value or value == "-" or "\x00" in value:
        raise RedactionError("PATH_CONFLICT")
    try:
        return pathlib.Path(value).resolve(strict=False)
    except (OSError, RuntimeError, ValueError) as exc:
        raise RedactionError("PATH_CONFLICT") from exc


def validate_paths(input_path: str, output_path: str, receipt_path: str) -> None:
    canonical_paths = tuple(
        _canonical_path(value) for value in (input_path, output_path, receipt_path)
    )
    if len(set(canonical_paths)) != 3:
        raise RedactionError("PATH_CONFLICT")
    if any(
        path == _REPOSITORY_ROOT or _REPOSITORY_ROOT in path.parents
        for path in canonical_paths
    ):
        raise RedactionError("PATH_CONFLICT")
    for target in (output_path, receipt_path):
        try:
            if os.path.lexists(target):
                raise RedactionError("OUTPUT_EXISTS")
        except OSError as exc:
            raise RedactionError("IO_ERROR") from exc


def read_raw_input(path: str, maximum_bytes: int) -> bytes:
    flags = os.O_RDONLY
    flags |= getattr(os, "O_CLOEXEC", 0)
    flags |= getattr(os, "O_NOFOLLOW", 0)
    flags |= getattr(os, "O_NONBLOCK", 0)
    descriptor = -1
    try:
        descriptor = os.open(path, flags)
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode):
            raise RedactionError("IO_ERROR")
        if before.st_size > maximum_bytes:
            raise RedactionError("INPUT_TOO_LARGE")
        chunks: list[bytes] = []
        remaining = maximum_bytes + 1
        while remaining:
            chunk = os.read(descriptor, min(1_048_576, remaining))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        data = b"".join(chunks)
        if len(data) > maximum_bytes:
            raise RedactionError("INPUT_TOO_LARGE")
        after = os.fstat(descriptor)
        if (
            len(data) != before.st_size
            or (
                before.st_dev,
                before.st_ino,
                before.st_size,
                before.st_mtime_ns,
            )
            != (
                after.st_dev,
                after.st_ino,
                after.st_size,
                after.st_mtime_ns,
            )
        ):
            raise RedactionError("IO_ERROR")
        return data
    except RedactionError:
        raise
    except OSError as exc:
        raise RedactionError("IO_ERROR") from exc
    finally:
        if descriptor >= 0:
            os.close(descriptor)


def _validate_unicode(value: str, *, allow_line_endings: bool = False) -> None:
    if unicodedata.normalize("NFC", value) != value:
        raise RedactionError("INVALID_UNICODE")
    for character in value:
        if allow_line_endings and character in "\n\r":
            continue
        codepoint = ord(character)
        category = unicodedata.category(character)
        if (
            codepoint == 0x7F
            or (codepoint < 0x20 and character != " ")
            or category in {"Cc", "Cf", "Cs", "Co", "Cn"}
        ):
            raise RedactionError("INVALID_UNICODE")
        name = unicodedata.name(character, "")
        if name.startswith(_CONFUSABLE_NAME_PREFIXES):
            raise RedactionError("INVALID_UNICODE")


def _classify_atom(atom: str) -> str:
    if _PLACEHOLDER_RE.fullmatch(atom):
        raise RedactionError("INVALID_TOKEN")
    if "/" in atom or "\\" in atom or atom.startswith("~"):
        return "PA"
    if _PACKAGE_RE.fullmatch(atom):
        return "PK"
    if _NUMBER_RE.fullmatch(atom):
        return "NU"
    if _IDENTIFIER_RE.fullmatch(atom):
        return "ID"
    if atom:
        return "TX"
    raise RedactionError("INVALID_TOKEN")


def _parse_quoted(line: str, start: int) -> tuple[str, int]:
    position = start + 1
    escaped = False
    while position < len(line):
        character = line[position]
        if escaped:
            escaped = False
        elif character == "\\":
            escaped = True
        elif character == '"':
            fragment = line[start : position + 1]
            try:
                decoded = json.loads(fragment)
            except (json.JSONDecodeError, ValueError) as exc:
                raise RedactionError("INVALID_TOKEN") from exc
            if not isinstance(decoded, str):
                raise RedactionError("INVALID_TOKEN")
            _validate_unicode(decoded)
            return decoded, position + 1
        position += 1
    raise RedactionError("INVALID_LINE")


def _transform_line(line: str, state: _TransformState) -> str:
    output: list[str] = []
    position = 0
    line_tokens = 0
    while position < len(line):
        character = line[position]
        if character == " ":
            position += 1
            continue
        if character in _PUNCTUATION:
            output.append(character)
            position += 1
        elif character == '"':
            semantic, position = _parse_quoted(line, position)
            if len(semantic.encode("utf-8")) > state.limits["tokenBytes"]:
                raise RedactionError("RESOURCE_LIMIT")
            output.append('"' + state.placeholder("QU", semantic) + '"')
        else:
            end = position
            while (
                end < len(line)
                and line[end] != " "
                and line[end] not in _PUNCTUATION
                and line[end] != '"'
            ):
                end += 1
            atom = line[position:end]
            if len(atom.encode("utf-8")) > state.limits["tokenBytes"]:
                raise RedactionError("RESOURCE_LIMIT")
            if atom in state.safe_literals:
                output.append(atom)
            else:
                output.append(state.placeholder(_classify_atom(atom), atom))
            position = end
        line_tokens += 1
        state.token_count += 1
        if line_tokens > state.limits["tokensPerLine"]:
            raise RedactionError("INVALID_LINE")
        if state.token_count > state.limits["tokens"]:
            raise RedactionError("RESOURCE_LIMIT")
    return " ".join(output)


def _line_ending_counts(text: str) -> dict[str, int]:
    crlf = text.count("\r\n")
    without_crlf = text.replace("\r\n", "")
    return {
        "lf": without_crlf.count("\n"),
        "crlf": crlf,
        "cr": without_crlf.count("\r"),
    }


def transform(
    raw: bytes, safe_literals: frozenset[str], manifest: dict[str, Any]
) -> TransformResult:
    try:
        text = raw.decode("utf-8", errors="strict")
    except UnicodeDecodeError as exc:
        raise RedactionError("INVALID_UTF8") from exc
    _validate_unicode(text, allow_line_endings=True)
    endings = _line_ending_counts(text)
    normalized = text.replace("\r\n", "\n").replace("\r", "\n")
    lines = normalized.split("\n")
    if normalized.endswith("\n"):
        lines.pop()
    if not lines:
        lines = [""]
    if len(lines) > manifest["limits"]["lines"]:
        raise RedactionError("RESOURCE_LIMIT")
    state = _TransformState(safe_literals=safe_literals, limits=manifest["limits"])
    output_lines = [_transform_line(line, state) for line in lines]
    replacement_total = sum(state.replacements_by_type.values())
    if state.token_count == 0 or replacement_total == 0:
        raise RedactionError("INVALID_LINE")
    derived = ("\n".join(output_lines) + "\n").encode("ascii", errors="strict")
    if len(derived) > manifest["limits"]["derivedBytes"]:
        raise RedactionError("RESOURCE_LIMIT")
    checked = assert_output_clean(derived, safe_literals, state.sensitive_literals)
    return TransformResult(
        derived=derived,
        replacement_total=replacement_total,
        replacement_unique=len(state.placeholders),
        replacements_by_type=dict(state.replacements_by_type),
        unique_by_type=dict(state.unique_by_type),
        line_endings=endings,
        line_count=len(lines),
        token_count=state.token_count,
        checked_sensitive_literals=checked,
    )


def _derived_atoms(derived_text: str, safe_literals: frozenset[str]) -> list[str]:
    atoms: list[str] = []
    for line in derived_text[:-1].split("\n"):
        position = 0
        while position < len(line):
            character = line[position]
            if character == " ":
                position += 1
                continue
            if character in _PUNCTUATION:
                position += 1
                continue
            if character == '"':
                end = line.find('"', position + 1)
                if end < 0:
                    raise RedactionError("SENSITIVE_OUTPUT")
                atom = line[position + 1 : end]
                if not _PLACEHOLDER_RE.fullmatch(atom):
                    raise RedactionError("SENSITIVE_OUTPUT")
                atoms.append(atom)
                position = end + 1
                continue
            end = position
            while (
                end < len(line)
                and line[end] != " "
                and line[end] not in _PUNCTUATION
                and line[end] != '"'
            ):
                end += 1
            atom = line[position:end]
            if atom not in safe_literals and not _PLACEHOLDER_RE.fullmatch(atom):
                raise RedactionError("SENSITIVE_OUTPUT")
            atoms.append(atom)
            position = end
    return atoms


def assert_output_clean(
    derived: bytes, safe_literals: frozenset[str], sensitive_literals: set[str]
) -> int:
    """Independent final gate: only reviewed literals, syntax, and placeholders survive."""
    try:
        text = derived.decode("ascii", errors="strict")
    except UnicodeDecodeError as exc:
        raise RedactionError("SENSITIVE_OUTPUT") from exc
    if not text.endswith("\n") or "\r" in text or "\t" in text:
        raise RedactionError("SENSITIVE_OUTPUT")
    if _USER_PATH_RE.search(derived) or any(marker in derived for marker in _KEY_MARKERS):
        raise RedactionError("SENSITIVE_OUTPUT")
    atoms = _derived_atoms(text, safe_literals)
    if not any(_PLACEHOLDER_RE.fullmatch(atom) for atom in atoms):
        raise RedactionError("SENSITIVE_OUTPUT")
    atom_set = set(atoms)
    for literal in sensitive_literals:
        if literal and literal in atom_set:
            raise RedactionError("SENSITIVE_OUTPUT")
    return len(sensitive_literals)


def _resolve_json_pointer(root: dict[str, Any], reference: str) -> dict[str, Any]:
    if not reference.startswith("#/"):
        raise SchemaValidationError("external schema references are forbidden")
    value: Any = root
    for raw_part in reference[2:].split("/"):
        part = raw_part.replace("~1", "/").replace("~0", "~")
        if not isinstance(value, dict) or part not in value:
            raise SchemaValidationError("unresolved local schema reference")
        value = value[part]
    if not isinstance(value, dict):
        raise SchemaValidationError("schema reference is not an object")
    return value


def _schema_type_matches(value: Any, expected: str) -> bool:
    if expected == "object":
        return isinstance(value, dict)
    if expected == "array":
        return isinstance(value, list)
    if expected == "string":
        return isinstance(value, str)
    if expected == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    if expected == "boolean":
        return isinstance(value, bool)
    raise SchemaValidationError("unsupported local schema type")


def validate_schema(
    instance: Any, schema: dict[str, Any], root: dict[str, Any], path: str = "$"
) -> None:
    if "$ref" in schema:
        validate_schema(instance, _resolve_json_pointer(root, schema["$ref"]), root, path)
        return
    if "const" in schema and not (
        type(instance) is type(schema["const"]) and instance == schema["const"]
    ):
        raise SchemaValidationError(f"{path}: const mismatch")
    expected_type = schema.get("type")
    if expected_type is not None and not _schema_type_matches(instance, expected_type):
        raise SchemaValidationError(f"{path}: type mismatch")
    if isinstance(instance, str):
        pattern = schema.get("pattern")
        if pattern is not None and re.search(pattern, instance) is None:
            raise SchemaValidationError(f"{path}: pattern mismatch")
        if len(instance) < schema.get("minLength", 0):
            raise SchemaValidationError(f"{path}: string too short")
    if isinstance(instance, int) and not isinstance(instance, bool):
        if instance < schema.get("minimum", instance):
            raise SchemaValidationError(f"{path}: below minimum")
    if isinstance(instance, list):
        if len(instance) < schema.get("minItems", 0) or len(instance) > schema.get(
            "maxItems", len(instance)
        ):
            raise SchemaValidationError(f"{path}: array length mismatch")
        if "items" in schema:
            for index, value in enumerate(instance):
                validate_schema(value, schema["items"], root, f"{path}[{index}]")
    if isinstance(instance, dict):
        properties = schema.get("properties", {})
        for required in schema.get("required", []):
            if required not in instance:
                raise SchemaValidationError(f"{path}: missing property")
        if schema.get("additionalProperties") is False and not set(instance) <= set(properties):
            raise SchemaValidationError(f"{path}: unexpected property")
        for key, subschema in properties.items():
            if key in instance:
                validate_schema(instance[key], subschema, root, f"{path}.{key}")


def _replay_argv(raw_sha256: str) -> list[str]:
    return [
        "<ARKDECK_PYTHON>",
        "scripts/ui_dump_redaction/redact.py",
        "--algorithm-manifest",
        "scripts/ui_dump_redaction/algorithm-v1.json",
        "--safe-literals",
        "scripts/ui_dump_redaction/safe-literals-v1.txt",
        "--input",
        "<CONTROLLED_RAW_PATH>",
        "--expected-input-sha256",
        raw_sha256,
        "--output",
        "<DERIVED_PATH>",
        "--receipt",
        "<RECEIPT_PATH>",
    ]


def build_receipt(
    *,
    raw: bytes,
    result: TransformResult,
    manifest: dict[str, Any],
    manifest_bytes: bytes,
    safe_literal_bytes: bytes,
    schema_bytes: bytes,
    completed_at: str | None = None,
) -> dict[str, Any]:
    raw_sha256 = _sha256(raw)
    if completed_at is None:
        completed_at = datetime.datetime.now(datetime.timezone.utc).replace(
            microsecond=0
        ).strftime("%Y-%m-%dT%H:%M:%SZ")
    source_bytes = _read_small_file(__file__, 2_097_152, "IO_ERROR")
    receipt = {
        "schema": "arkdeck-ui-dump-redaction-receipt-1.0.0",
        "algorithm": {
            "id": manifest["algorithmId"],
            "version": manifest["version"],
            "sourceSha256": _sha256(source_bytes),
            "manifestSha256": _sha256(manifest_bytes),
            "safeLiteralsSha256": _sha256(safe_literal_bytes),
            "receiptSchemaSha256": _sha256(schema_bytes),
        },
        "raw": {"sha256": raw_sha256, "size": len(raw)},
        "derived": {"sha256": _sha256(result.derived), "size": len(result.derived)},
        "replacements": {
            "total": result.replacement_total,
            "unique": result.replacement_unique,
            "byType": dict(result.replacements_by_type),
            "uniqueByType": dict(result.unique_by_type),
        },
        "normalization": {
            "lineEndings": dict(result.line_endings),
            "lineCount": result.line_count,
            "tokenCount": result.token_count,
        },
        "outputSideCheck": {
            "passed": True,
            "checkedSensitiveLiterals": result.checked_sensitive_literals,
        },
        "replay": {"argv": _replay_argv(raw_sha256)},
        "completedAt": completed_at,
    }
    return receipt


def validate_receipt(
    receipt: dict[str, Any],
    schema: dict[str, Any],
    *,
    raw: bytes,
    result: TransformResult,
    manifest: dict[str, Any],
    manifest_bytes: bytes,
    safe_literal_bytes: bytes,
    schema_bytes: bytes,
) -> None:
    try:
        validate_schema(receipt, schema, schema)
    except SchemaValidationError as exc:
        raise RedactionError("MANIFEST_INVALID") from exc
    if (
        set(result.replacements_by_type) != set(_TYPE_CODES)
        or set(result.unique_by_type) != set(_TYPE_CODES)
        or set(result.line_endings) != {"lf", "crlf", "cr"}
        or any(
            type(value) is not int or value < 0
            for value in (
                *result.replacements_by_type.values(),
                *result.unique_by_type.values(),
                *result.line_endings.values(),
                result.replacement_total,
                result.replacement_unique,
                result.line_count,
                result.token_count,
                result.checked_sensitive_literals,
            )
        )
        or result.replacement_total != sum(result.replacements_by_type.values())
        or result.replacement_unique != sum(result.unique_by_type.values())
        or result.replacement_total < 1
        or not 1 <= result.replacement_unique <= result.replacement_total
        or not 1 <= result.checked_sensitive_literals <= result.replacement_unique
        or result.line_count < 1
        or result.token_count < result.replacement_total
        or any(
            result.unique_by_type[type_code]
            > result.replacements_by_type[type_code]
            for type_code in _TYPE_CODES
        )
    ):
        raise RedactionError("MANIFEST_INVALID")
    expected_algorithm = {
        "id": manifest["algorithmId"],
        "version": manifest["version"],
        "sourceSha256": _sha256(_read_small_file(__file__, 2_097_152, "IO_ERROR")),
        "manifestSha256": _sha256(manifest_bytes),
        "safeLiteralsSha256": _sha256(safe_literal_bytes),
        "receiptSchemaSha256": _sha256(schema_bytes),
    }
    raw_hash = _sha256(raw)
    expected_replacements = {
        "total": result.replacement_total,
        "unique": result.replacement_unique,
        "byType": result.replacements_by_type,
        "uniqueByType": result.unique_by_type,
    }
    expected_normalization = {
        "lineEndings": result.line_endings,
        "lineCount": result.line_count,
        "tokenCount": result.token_count,
    }
    expected_output_check = {
        "passed": True,
        "checkedSensitiveLiterals": result.checked_sensitive_literals,
    }
    if (
        receipt["algorithm"] != expected_algorithm
        or receipt["raw"] != {"sha256": raw_hash, "size": len(raw)}
        or receipt["derived"]
        != {"sha256": _sha256(result.derived), "size": len(result.derived)}
        or receipt["replacements"] != expected_replacements
        or receipt["normalization"] != expected_normalization
        or receipt["outputSideCheck"] != expected_output_check
        or receipt["replay"] != {"argv": _replay_argv(raw_hash)}
    ):
        raise RedactionError("MANIFEST_INVALID")


def serialize_receipt(receipt: dict[str, Any]) -> bytes:
    return (
        json.dumps(receipt, ensure_ascii=True, indent=2, sort_keys=True) + "\n"
    ).encode("ascii")


def _exclusive_write(path: str, payload: bytes) -> None:
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    flags |= getattr(os, "O_CLOEXEC", 0)
    flags |= getattr(os, "O_NOFOLLOW", 0)
    descriptor = -1
    created = False
    try:
        descriptor = os.open(path, flags, 0o600)
        created = True
        view = memoryview(payload)
        while view:
            written = os.write(descriptor, view)
            if written <= 0:
                raise OSError("short write")
            view = view[written:]
        os.fsync(descriptor)
    except OSError as exc:
        if descriptor >= 0:
            os.close(descriptor)
            descriptor = -1
        if created:
            try:
                os.unlink(path)
            except OSError:
                pass
        raise RedactionError("IO_ERROR") from exc
    finally:
        if descriptor >= 0:
            os.close(descriptor)


def run(args: argparse.Namespace) -> None:
    manifest, manifest_bytes = load_manifest(args.algorithm_manifest)
    safe_literals, safe_literal_bytes = load_safe_literals(args.safe_literals, manifest)
    schema, schema_bytes = load_receipt_schema(manifest)
    validate_paths(args.input, args.output, args.receipt)
    if not _SHA256_RE.fullmatch(args.expected_input_sha256):
        raise RedactionError("INPUT_HASH_MISMATCH")
    raw = read_raw_input(args.input, manifest["limits"]["inputBytes"])
    if _sha256(raw) != args.expected_input_sha256:
        raise RedactionError("INPUT_HASH_MISMATCH")
    result = transform(raw, safe_literals, manifest)
    receipt = build_receipt(
        raw=raw,
        result=result,
        manifest=manifest,
        manifest_bytes=manifest_bytes,
        safe_literal_bytes=safe_literal_bytes,
        schema_bytes=schema_bytes,
    )
    validate_receipt(
        receipt,
        schema,
        raw=raw,
        result=result,
        manifest=manifest,
        manifest_bytes=manifest_bytes,
        safe_literal_bytes=safe_literal_bytes,
        schema_bytes=schema_bytes,
    )
    receipt_bytes = serialize_receipt(receipt)
    _exclusive_write(args.output, result.derived)
    try:
        _exclusive_write(args.receipt, receipt_bytes)
    except RedactionError:
        try:
            os.unlink(args.output)
        except OSError:
            pass
        raise


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Create a deterministic, redacted UI Dump derived artifact and receipt.",
        allow_abbrev=False,
    )
    parser.add_argument("--algorithm-manifest", required=True)
    parser.add_argument("--safe-literals", required=True)
    parser.add_argument("--input", required=True)
    parser.add_argument("--expected-input-sha256", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--receipt", required=True)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_arg_parser().parse_args(argv)
    try:
        run(args)
    except RedactionError as exc:
        print(f"redact: {exc.name}", file=sys.stderr)
        return exc.exit_code
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
