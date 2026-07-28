#!/usr/bin/env python3
"""Read-only, non-content root-cause diagnosis for one pinned UI Dump raw.

TASK-UD-R2-DIAG-001 (readiness r1). The tool measures why the fixed
`uidump-derived-redaction-v1` transform rejected the pinned R2 raw origin, by
running two independent censuses over the same byte stream:

1. byte-level UTF-8 structure (would a strict decode fail: `INVALID_UTF8` /
   exit 26 in the redactor), and
2. codepoint-level policy after a successful strict decode, mirroring the
   redactor's `_validate_unicode(text, allow_line_endings=True)` conditions
   (`INVALID_UNICODE` / exit 27).

The report is one deterministic canonical-JSON line on stdout under the closed
schema `arkdeck-ud-raw-diagnosis-1.0.0`. Every value is an integer, boolean,
null, fixed enum literal, or 64-hex digest. No raw byte subsequence, decoded
text, content window, page text, or window/component literal is ever emitted;
a fail-closed output-side final check walks the whole report tree before
printing and refuses any key or value-law violation as `SENSITIVE_OUTPUT`.

The input is opened read-only with a no-follow descriptor, must be a regular
file outside this repository, is read once into memory without copying,
caching, or writing any path, and is diagnosed only after its measured length
and SHA-256 exactly equal the caller-pinned pair. Any mismatch is
`INPUT_HASH_MISMATCH` with zero diagnostic output. The tool is stdlib-only and
performs zero shell, subprocess, socket, network, exec/eval, or disk-write
operations. Stable errors are a single stderr line `diagnose: <ERROR_NAME>`.
"""

import argparse
import hashlib
import json
import os
import re
import stat
import sys
import unicodedata

SCHEMA_ID = "arkdeck-ud-raw-diagnosis-1.0.0"
TOOL_NAME = "arkdeck-ud-raw-diagnosis"

# Pinned policy references (readiness r1; audit base d17d303). The tests
# assert these embedded constants equal the measured hashes of the fixed
# redactor files in this repository.
REDACT_PY_SHA256 = (
    "938cc117da97304b5ede66ff55c84dd9ce0a987600d4a1ecec2c3e01351f53e1"
)
ALGORITHM_MANIFEST_SHA256 = (
    "a75778fdf525050c4c0bcf11579e5f09f99a6fa70697bcf79026656a71f20185"
)

# Error codes reuse the redactor numeric namespace; argparse usage errors are
# exit 2 and a completed diagnosis (violating raw or not) is exit 0.
ERROR_CODES = {
    "INPUT_HASH_MISMATCH": 24,
    "INPUT_TOO_LARGE": 25,
    "SENSITIVE_OUTPUT": 31,
    "IO_ERROR": 32,
}

INPUT_BYTES_LIMIT = 16_777_216
SELF_BYTES_LIMIT = 2_097_152
RUNS_KEPT_EACH_SIDE = 32

UTF8_RUN_CLASSES = (
    "STRAY_CONTINUATION",
    "INVALID_LEAD",
    "OVERLONG",
    "SURROGATE_ENCODING",
    "OUT_OF_RANGE",
    "TRUNCATED_SEQUENCE_MID",
    "TRUNCATED_SEQUENCE_EOF",
)

POLICY_VIOLATION_CLASSES = (
    "DEL_7F",
    "CONTROL_C0",
    "CATEGORY_CC",
    "CATEGORY_CF",
    "CATEGORY_CS",
    "CATEGORY_CO",
    "CATEGORY_CN",
    "CONFUSABLE_NAME_PREFIX",
)

BYTE_HISTOGRAM_KEYS = (
    "nul",
    "tab",
    "lf",
    "cr",
    "otherC0",
    "asciiPrintable",
    "del",
    "lead2",
    "lead3",
    "lead4",
    "continuation",
    "invalidByte",
)

REDACTOR_ERROR_NAMES = ("NONE", "INVALID_UTF8", "INVALID_UNICODE")

# Mirrors the fixed redactor's confusable name-prefix rejection list.
_CONFUSABLE_NAME_PREFIXES = (
    "ARMENIAN ",
    "CHEROKEE ",
    "CYRILLIC ",
    "FULLWIDTH ",
    "GREEK ",
    "MATHEMATICAL ",
    "SMALL ",
)

_SHA256_RE = re.compile(r"[0-9a-f]{64}")

_SCRIPT_DIR = os.path.dirname(os.path.realpath(__file__))
_REPOSITORY_ROOT = os.path.realpath(
    os.path.join(_SCRIPT_DIR, os.pardir, os.pardir)
)

_FIXED_STRING_VALUES = frozenset(
    {SCHEMA_ID, TOOL_NAME}
    | set(UTF8_RUN_CLASSES)
    | set(POLICY_VIOLATION_CLASSES)
    | set(REDACTOR_ERROR_NAMES)
)


class DiagnosisError(Exception):
    """A stable, non-sensitive diagnosis failure."""

    def __init__(self, name):
        if name not in ERROR_CODES:
            raise ValueError("unknown diagnosis error name")
        super().__init__(name)
        self.name = name
        self.exit_code = ERROR_CODES[name]


def _sha256(data):
    return hashlib.sha256(data).hexdigest()


def _assert_outside_repository(path):
    """The controlled raw must never live inside this repository."""
    if not isinstance(path, str) or not path or "\x00" in path:
        raise DiagnosisError("IO_ERROR")
    try:
        resolved = os.path.realpath(path)
    except (OSError, ValueError) as exc:
        raise DiagnosisError("IO_ERROR") from exc
    if resolved == _REPOSITORY_ROOT or resolved.startswith(
        _REPOSITORY_ROOT + os.sep
    ):
        raise DiagnosisError("IO_ERROR")


def _read_bounded(path, maximum, oversize_error):
    """Single-pass bounded read through a read-only no-follow descriptor."""
    flags = os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_NONBLOCK
    descriptor = -1
    try:
        descriptor = os.open(path, flags)
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode):
            raise DiagnosisError("IO_ERROR")
        if before.st_size > maximum:
            raise DiagnosisError(oversize_error)
        chunks = []
        remaining = maximum + 1
        while remaining:
            chunk = os.read(descriptor, min(1_048_576, remaining))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        data = b"".join(chunks)
        if len(data) > maximum:
            raise DiagnosisError(oversize_error)
        after = os.fstat(descriptor)
        if len(data) != before.st_size or (
            before.st_dev,
            before.st_ino,
            before.st_size,
            before.st_mtime_ns,
        ) != (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns):
            raise DiagnosisError("IO_ERROR")
        return data
    except DiagnosisError:
        raise
    except OSError as exc:
        raise DiagnosisError("IO_ERROR") from exc
    finally:
        if descriptor >= 0:
            os.close(descriptor)


def _read_input(path):
    return _read_bounded(path, INPUT_BYTES_LIMIT, "INPUT_TOO_LARGE")


def _read_self():
    return _read_bounded(__file__, SELF_BYTES_LIMIT, "IO_ERROR")


def _byte_histogram(data):
    """Classify every byte by value alone; the counts sum to len(data)."""
    histogram = {key: 0 for key in BYTE_HISTOGRAM_KEYS}
    for byte in data:
        if byte == 0x00:
            histogram["nul"] += 1
        elif byte == 0x09:
            histogram["tab"] += 1
        elif byte == 0x0A:
            histogram["lf"] += 1
        elif byte == 0x0D:
            histogram["cr"] += 1
        elif byte < 0x20:
            histogram["otherC0"] += 1
        elif byte < 0x7F:
            histogram["asciiPrintable"] += 1
        elif byte == 0x7F:
            histogram["del"] += 1
        elif byte < 0xC0:
            histogram["continuation"] += 1
        elif byte < 0xE0:
            histogram["lead2"] += 1
        elif byte < 0xF0:
            histogram["lead3"] += 1
        elif byte < 0xF8:
            histogram["lead4"] += 1
        else:
            histogram["invalidByte"] += 1
    return histogram


def _count_continuations(data, start, maximum):
    end = min(len(data), start + maximum)
    index = start
    while index < end and 0x80 <= data[index] <= 0xBF:
        index += 1
    return index - start


def _scan_utf8(data):
    """RFC 3629 well-formedness scan classifying every malformed sequence.

    The scan accepts exactly the byte strings a strict Python UTF-8 decode
    accepts (surrogate encodings rejected), so `sequences == []` is
    equivalent to decodability. A malformed sequence consumes its maximal
    subpart: the lead byte plus any immediately following continuation
    bytes that could still have belonged to it, never a byte that restarts
    a new sequence. Offsets and lengths are byte-based.
    """
    sequences = []
    length = len(data)
    index = 0
    while index < length:
        lead = data[index]
        if lead <= 0x7F:
            index += 1
            continue
        if lead <= 0xBF:
            sequences.append((index, 1, "STRAY_CONTINUATION"))
            index += 1
            continue
        if lead <= 0xC1:
            consumed = 1 + _count_continuations(data, index + 1, 1)
            sequences.append((index, consumed, "OVERLONG"))
            index += consumed
            continue
        if lead <= 0xDF:
            if _count_continuations(data, index + 1, 1) == 1:
                index += 2
                continue
            truncation = (
                "TRUNCATED_SEQUENCE_EOF"
                if index + 1 >= length
                else "TRUNCATED_SEQUENCE_MID"
            )
            sequences.append((index, 1, truncation))
            index += 1
            continue
        if lead <= 0xEF:
            if index + 1 >= length:
                sequences.append((index, 1, "TRUNCATED_SEQUENCE_EOF"))
                index += 1
                continue
            second = data[index + 1]
            if not 0x80 <= second <= 0xBF:
                sequences.append((index, 1, "TRUNCATED_SEQUENCE_MID"))
                index += 1
                continue
            if lead == 0xE0 and second <= 0x9F:
                consumed = 2 + _count_continuations(data, index + 2, 1)
                sequences.append((index, consumed, "OVERLONG"))
                index += consumed
                continue
            if lead == 0xED and second >= 0xA0:
                consumed = 2 + _count_continuations(data, index + 2, 1)
                sequences.append((index, consumed, "SURROGATE_ENCODING"))
                index += consumed
                continue
            if _count_continuations(data, index + 2, 1) == 1:
                index += 3
                continue
            truncation = (
                "TRUNCATED_SEQUENCE_EOF"
                if index + 2 >= length
                else "TRUNCATED_SEQUENCE_MID"
            )
            sequences.append((index, 2, truncation))
            index += 2
            continue
        if lead <= 0xF4:
            if index + 1 >= length:
                sequences.append((index, 1, "TRUNCATED_SEQUENCE_EOF"))
                index += 1
                continue
            second = data[index + 1]
            if not 0x80 <= second <= 0xBF:
                sequences.append((index, 1, "TRUNCATED_SEQUENCE_MID"))
                index += 1
                continue
            if lead == 0xF0 and second <= 0x8F:
                consumed = 2 + _count_continuations(data, index + 2, 2)
                sequences.append((index, consumed, "OVERLONG"))
                index += consumed
                continue
            if lead == 0xF4 and second >= 0x90:
                consumed = 2 + _count_continuations(data, index + 2, 2)
                sequences.append((index, consumed, "OUT_OF_RANGE"))
                index += consumed
                continue
            trailing = _count_continuations(data, index + 2, 2)
            if trailing == 2:
                index += 4
                continue
            consumed = 2 + trailing
            truncation = (
                "TRUNCATED_SEQUENCE_EOF"
                if index + consumed >= length
                else "TRUNCATED_SEQUENCE_MID"
            )
            sequences.append((index, consumed, truncation))
            index += consumed
            continue
        if lead <= 0xF7:
            consumed = 1 + _count_continuations(data, index + 1, 3)
            sequences.append((index, consumed, "OUT_OF_RANGE"))
            index += consumed
            continue
        sequences.append((index, 1, "INVALID_LEAD"))
        index += 1
    invalid_byte_count = sum(entry[1] for entry in sequences)
    return sequences, invalid_byte_count


def _classify_codepoint(character):
    """First matching redactor condition, or None for an accepted codepoint.

    Mirrors `_validate_unicode(text, allow_line_endings=True)` in the fixed
    redactor: LF and CR are exempt; then DEL, the remaining C0 controls,
    the Cc/Cf/Cs/Co/Cn categories, and the confusable name prefixes reject,
    in that order.
    """
    if character in "\n\r":
        return None
    codepoint = ord(character)
    if codepoint == 0x7F:
        return "DEL_7F"
    if codepoint < 0x20:
        return "CONTROL_C0"
    category = unicodedata.category(character)
    if category == "Cc":
        return "CATEGORY_CC"
    if category == "Cf":
        return "CATEGORY_CF"
    if category == "Cs":
        return "CATEGORY_CS"
    if category == "Co":
        return "CATEGORY_CO"
    if category == "Cn":
        return "CATEGORY_CN"
    if unicodedata.name(character, "").startswith(_CONFUSABLE_NAME_PREFIXES):
        return "CONFUSABLE_NAME_PREFIX"
    return None


def _scan_codepoints(text):
    """Per-codepoint policy census; offsets are UTF-8 byte offsets."""
    violations = []
    combining_count = 0
    offset = 0
    for character in text:
        encoded_length = len(character.encode("utf-8"))
        if unicodedata.combining(character):
            combining_count += 1
        violation_class = _classify_codepoint(character)
        if violation_class is not None:
            violations.append((offset, encoded_length, violation_class))
        offset += encoded_length
    return violations, combining_count


def _face_fields(entries, total_length, classes, first_key, last_key):
    """Shared non-content projection of one census face.

    `decileCounts` buckets each entry's start byte offset into ten equal
    byte-offset slices of the input; the counts sum to the number of
    entries. `tailConcentrated` is `2 * decileCounts[9] >= total` (false
    for zero entries). `runs` keeps the first and last 32 entries when
    there are more than 64, with `runsTruncated` set; every count stays
    exact.
    """
    class_counts = {name: 0 for name in classes}
    decile_counts = [0] * 10
    for offset, _, entry_class in entries:
        class_counts[entry_class] += 1
        if total_length > 0:
            decile_counts[min(offset * 10 // total_length, 9)] += 1
    count = len(entries)
    if count > 2 * RUNS_KEPT_EACH_SIDE:
        kept = entries[:RUNS_KEPT_EACH_SIDE] + entries[-RUNS_KEPT_EACH_SIDE:]
        truncated = True
    else:
        kept = list(entries)
        truncated = False
    return {
        first_key: entries[0][0] if entries else None,
        last_key: entries[-1][0] if entries else None,
        "classCounts": class_counts,
        "runs": [
            {"offset": offset, "length": length, "class": entry_class}
            for offset, length, entry_class in kept
        ],
        "runsTruncated": truncated,
        "decileCounts": decile_counts,
        "tailConcentrated": count > 0 and 2 * decile_counts[9] >= count,
    }


def diagnose_bytes(data, *, expected_sha256, expected_length, tool_sha256):
    """Build the full closed-schema report for already-gated input bytes."""
    sequences, invalid_byte_count = _scan_utf8(data)
    decodable = not sequences
    utf8_structure = {
        "decodable": decodable,
        "invalidSequenceCount": len(sequences),
        "invalidByteCount": invalid_byte_count,
    }
    utf8_structure.update(
        _face_fields(
            sequences,
            len(data),
            UTF8_RUN_CLASSES,
            "firstInvalidOffset",
            "lastInvalidOffset",
        )
    )
    if decodable:
        text = data.decode("utf-8")
        nfc = unicodedata.normalize("NFC", text) == text
        violations, combining_count = _scan_codepoints(text)
        codepoint_policy = {
            "evaluated": True,
            "nfc": nfc,
            "combiningMarkCount": combining_count,
            "violationCount": len(violations),
        }
    else:
        nfc = None
        violations = []
        codepoint_policy = {
            "evaluated": False,
            "nfc": None,
            "combiningMarkCount": 0,
            "violationCount": 0,
        }
    codepoint_policy.update(
        _face_fields(
            violations,
            len(data),
            POLICY_VIOLATION_CLASSES,
            "firstViolationByteOffset",
            "lastViolationByteOffset",
        )
    )
    if not decodable:
        error_name, error_code = "INVALID_UTF8", 26
    elif nfc is False or violations:
        error_name, error_code = "INVALID_UNICODE", 27
    else:
        error_name, error_code = "NONE", None
    return {
        "schema": SCHEMA_ID,
        "tool": {"name": TOOL_NAME, "sha256": tool_sha256},
        "policyRefs": {
            "redactPySha256": REDACT_PY_SHA256,
            "algorithmManifestSha256": ALGORITHM_MANIFEST_SHA256,
        },
        "input": {
            "expectedSha256": expected_sha256,
            "measuredSha256": _sha256(data),
            "expectedLength": expected_length,
            "measuredLength": len(data),
        },
        "byteHistogram": _byte_histogram(data),
        "utf8Structure": utf8_structure,
        "codepointPolicy": codepoint_policy,
        "redactorEquivalent": {
            "errorName": error_name,
            "errorCode": error_code,
        },
    }


def _require(condition):
    if not condition:
        raise DiagnosisError("SENSITIVE_OUTPUT")


def _is_hex64(value):
    return isinstance(value, str) and _SHA256_RE.fullmatch(value) is not None


def _is_count(value):
    return type(value) is int and value >= 0


def _check_keys(value, keys):
    _require(type(value) is dict)
    _require(set(value) == set(keys))


def _check_face(face, classes, first_key, last_key, count, measured_length):
    first = face[first_key]
    last = face[last_key]
    if count == 0:
        _require(first is None and last is None)
    else:
        _require(_is_count(first) and _is_count(last))
        _require(first <= last and last < measured_length)
    class_counts = face["classCounts"]
    _check_keys(class_counts, classes)
    _require(all(_is_count(class_counts[name]) for name in classes))
    _require(sum(class_counts[name] for name in classes) == count)
    runs = face["runs"]
    _require(type(runs) is list)
    _require(len(runs) == min(count, 2 * RUNS_KEPT_EACH_SIDE))
    for entry in runs:
        _check_keys(entry, ("offset", "length", "class"))
        _require(_is_count(entry["offset"]))
        _require(_is_count(entry["length"]) and entry["length"] >= 1)
        _require(entry["class"] in classes)
    _require(type(face["runsTruncated"]) is bool)
    _require(face["runsTruncated"] == (count > 2 * RUNS_KEPT_EACH_SIDE))
    deciles = face["decileCounts"]
    _require(type(deciles) is list and len(deciles) == 10)
    _require(all(_is_count(value) for value in deciles))
    _require(sum(deciles) == count)
    _require(type(face["tailConcentrated"]) is bool)
    _require(
        face["tailConcentrated"] == (count > 0 and 2 * deciles[9] >= count)
    )


def _walk_value_law(value):
    """Whole-tree value-type law: no float and no free-form string survives."""
    if type(value) is dict:
        for key, item in value.items():
            _require(type(key) is str)
            _walk_value_law(item)
    elif type(value) is list:
        for item in value:
            _walk_value_law(item)
    elif type(value) is str:
        _require(value in _FIXED_STRING_VALUES or _is_hex64(value))
    else:
        _require(value is None or type(value) is bool or type(value) is int)


def validate_report(report):
    """Fail-closed output-side final check over the whole report tree."""
    _check_keys(
        report,
        (
            "schema",
            "tool",
            "policyRefs",
            "input",
            "byteHistogram",
            "utf8Structure",
            "codepointPolicy",
            "redactorEquivalent",
        ),
    )
    _require(report["schema"] == SCHEMA_ID)
    tool = report["tool"]
    _check_keys(tool, ("name", "sha256"))
    _require(tool["name"] == TOOL_NAME)
    _require(_is_hex64(tool["sha256"]))
    policy_refs = report["policyRefs"]
    _check_keys(policy_refs, ("redactPySha256", "algorithmManifestSha256"))
    _require(policy_refs["redactPySha256"] == REDACT_PY_SHA256)
    _require(
        policy_refs["algorithmManifestSha256"] == ALGORITHM_MANIFEST_SHA256
    )
    input_block = report["input"]
    _check_keys(
        input_block,
        ("expectedSha256", "measuredSha256", "expectedLength", "measuredLength"),
    )
    _require(_is_hex64(input_block["expectedSha256"]))
    _require(_is_hex64(input_block["measuredSha256"]))
    _require(input_block["expectedSha256"] == input_block["measuredSha256"])
    _require(_is_count(input_block["expectedLength"]))
    _require(_is_count(input_block["measuredLength"]))
    _require(input_block["expectedLength"] == input_block["measuredLength"])
    measured_length = input_block["measuredLength"]
    histogram = report["byteHistogram"]
    _check_keys(histogram, BYTE_HISTOGRAM_KEYS)
    _require(all(_is_count(histogram[key]) for key in BYTE_HISTOGRAM_KEYS))
    _require(
        sum(histogram[key] for key in BYTE_HISTOGRAM_KEYS) == measured_length
    )
    utf8_structure = report["utf8Structure"]
    _check_keys(
        utf8_structure,
        (
            "decodable",
            "invalidSequenceCount",
            "invalidByteCount",
            "firstInvalidOffset",
            "lastInvalidOffset",
            "classCounts",
            "runs",
            "runsTruncated",
            "decileCounts",
            "tailConcentrated",
        ),
    )
    _require(type(utf8_structure["decodable"]) is bool)
    sequence_count = utf8_structure["invalidSequenceCount"]
    _require(_is_count(sequence_count))
    _require(_is_count(utf8_structure["invalidByteCount"]))
    _require(utf8_structure["decodable"] == (sequence_count == 0))
    _require(utf8_structure["invalidByteCount"] >= sequence_count)
    _require((utf8_structure["invalidByteCount"] == 0) == (sequence_count == 0))
    _check_face(
        utf8_structure,
        UTF8_RUN_CLASSES,
        "firstInvalidOffset",
        "lastInvalidOffset",
        sequence_count,
        measured_length,
    )
    codepoint_policy = report["codepointPolicy"]
    _check_keys(
        codepoint_policy,
        (
            "evaluated",
            "nfc",
            "combiningMarkCount",
            "violationCount",
            "firstViolationByteOffset",
            "lastViolationByteOffset",
            "classCounts",
            "runs",
            "runsTruncated",
            "decileCounts",
            "tailConcentrated",
        ),
    )
    _require(type(codepoint_policy["evaluated"]) is bool)
    _require(codepoint_policy["evaluated"] == utf8_structure["decodable"])
    violation_count = codepoint_policy["violationCount"]
    _require(_is_count(violation_count))
    _require(_is_count(codepoint_policy["combiningMarkCount"]))
    if codepoint_policy["evaluated"]:
        _require(type(codepoint_policy["nfc"]) is bool)
    else:
        _require(codepoint_policy["nfc"] is None)
        _require(codepoint_policy["combiningMarkCount"] == 0)
        _require(violation_count == 0)
    _check_face(
        codepoint_policy,
        POLICY_VIOLATION_CLASSES,
        "firstViolationByteOffset",
        "lastViolationByteOffset",
        violation_count,
        measured_length,
    )
    equivalent = report["redactorEquivalent"]
    _check_keys(equivalent, ("errorName", "errorCode"))
    if not utf8_structure["decodable"]:
        expected_pair = ("INVALID_UTF8", 26)
    elif codepoint_policy["nfc"] is False or violation_count > 0:
        expected_pair = ("INVALID_UNICODE", 27)
    else:
        expected_pair = ("NONE", None)
    _require(
        (equivalent["errorName"], equivalent["errorCode"]) == expected_pair
    )
    _walk_value_law(report)


def emit_report(report):
    """Validate fail-closed, then print the single canonical JSON line."""
    validate_report(report)
    line = json.dumps(
        report, ensure_ascii=True, separators=(",", ":"), sort_keys=True
    )
    sys.stdout.write(line + "\n")


def run(args):
    _assert_outside_repository(args.input)
    if not _SHA256_RE.fullmatch(args.expected_input_sha256):
        raise DiagnosisError("INPUT_HASH_MISMATCH")
    data = _read_input(args.input)
    if len(data) != args.expected_length:
        raise DiagnosisError("INPUT_HASH_MISMATCH")
    if _sha256(data) != args.expected_input_sha256:
        raise DiagnosisError("INPUT_HASH_MISMATCH")
    tool_sha256 = _sha256(_read_self())
    report = diagnose_bytes(
        data,
        expected_sha256=args.expected_input_sha256,
        expected_length=args.expected_length,
        tool_sha256=tool_sha256,
    )
    emit_report(report)


def _positive_length(text):
    if not re.fullmatch(r"[0-9]+", text) or int(text) <= 0:
        raise argparse.ArgumentTypeError(
            "expected-length must be a positive decimal integer"
        )
    return int(text)


def build_arg_parser():
    parser = argparse.ArgumentParser(
        description=(
            "Read-only, non-content UTF-8 structure and codepoint-policy "
            "diagnosis of one pinned raw file."
        ),
        allow_abbrev=False,
    )
    parser.add_argument("--input", required=True)
    parser.add_argument("--expected-input-sha256", required=True)
    parser.add_argument("--expected-length", required=True, type=_positive_length)
    return parser


def main(argv=None):
    args = build_arg_parser().parse_args(argv)
    try:
        run(args)
    except DiagnosisError as exc:
        print(f"diagnose: {exc.name}", file=sys.stderr)
        return exc.exit_code
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
