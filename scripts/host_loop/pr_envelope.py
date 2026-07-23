#!/usr/bin/env python3
"""Render, parse, and validate the ArkDeck pull-request envelope v1.

This module is deliberately pure and standard-library-only.  It reads active
change metadata supplied by the caller and does not invoke commands, access the
network, mutate GitHub state, or interpret an envelope as approval.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Literal, Sequence


OPEN_MARKER = "<!-- arkdeck-pr-envelope:v1 -->"
CLOSE_MARKER = "<!-- /arkdeck-pr-envelope -->"
RUNTIME_ID = "host-loop/1"

TASK_BOUND_TYPES = (
    "implementation",
    "status",
    "verification",
    "archive",
)
CHANGE_BOUND_TYPES = (
    "proposal",
    "approval",
    "readiness",
)
PR_TYPES = TASK_BOUND_TYPES + CHANGE_BOUND_TYPES
DECISION_GRADES = frozenset(("D0", "D1", "D2"))

TASK_RE = re.compile(r"^TASK-[A-Z0-9]+-[0-9]{3}$")
TASK_HEADER_RE = re.compile(
    r"^##\s+(TASK-[A-Z0-9]+-[0-9]{3})(?:\s|$)",
    re.MULTILINE,
)
CHANGE_RE = re.compile(r"^CHG-[A-Za-z0-9]+(?:-[A-Za-z0-9]+)*$")
LOWER_OID_RE = re.compile(r"^[0-9a-f]{40}$")
DEPENDENCY_RE = re.compile(r"^#[1-9][0-9]*$")
IDENTITY_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._/@:-]{0,127}$")
FRONTMATTER_ID_RE = re.compile(r"^id:\s*(CHG-[A-Za-z0-9-]+)\s*$", re.MULTILINE)
WINDOWS_ABSOLUTE_RE = re.compile(r"^[A-Za-z]:/")


class EnvelopeError(ValueError):
    """A deterministic, user-correctable envelope contract failure."""


@dataclass(frozen=True)
class FieldSpec:
    name: str
    kind: Literal["scalar", "list"]


# Renderer and parser share this single ordered definition.
FIELD_SPECS = (
    FieldSpec("Envelope-Version", "scalar"),
    FieldSpec("PR-Type", "scalar"),
    FieldSpec("Change", "scalar"),
    FieldSpec("Task", "scalar"),
    FieldSpec("Base-OID", "scalar"),
    FieldSpec("Head-OID", "scalar"),
    FieldSpec("Decision-Grade", "scalar"),
    FieldSpec("Depends-On", "scalar"),
    FieldSpec("Evidence", "list"),
    FieldSpec("Attribution", "list"),
)
FIELD_NAMES = tuple(spec.name for spec in FIELD_SPECS)


@dataclass(frozen=True)
class Envelope:
    pr_type: str
    change: str
    task: str
    base_oid: str
    head_oid: str
    decision_grade: str
    depends_on: str
    evidence: tuple[str, ...]
    producer: str
    run: str


@dataclass(frozen=True)
class ParsedEnvelope:
    envelope: Envelope
    human_text: str


def _decode(payload: bytes | str) -> str:
    if isinstance(payload, bytes):
        try:
            text = payload.decode("utf-8", errors="strict")
        except UnicodeDecodeError as error:
            raise EnvelopeError("envelope must be valid UTF-8") from error
    elif isinstance(payload, str):
        text = payload
    else:
        raise EnvelopeError("envelope payload must be bytes or str")
    if "\r" in text:
        raise EnvelopeError("envelope must use LF line endings; CR is forbidden")
    if "\x00" in text:
        raise EnvelopeError("envelope must not contain NUL")
    return text


def _split_machine_block(text: str) -> tuple[list[str], str]:
    lines = text.split("\n")
    if lines and lines[-1] == "":
        lines.pop()

    if sum(line == OPEN_MARKER for line in lines) != 1:
        raise EnvelopeError("opening marker must appear exactly once")
    if sum(line == CLOSE_MARKER for line in lines) != 1:
        raise EnvelopeError("closing marker must appear exactly once")

    opening = lines.index(OPEN_MARKER)
    closing = lines.index(CLOSE_MARKER)
    if closing <= opening:
        raise EnvelopeError("envelope markers are reversed")
    if any(line for line in lines[:opening]):
        raise EnvelopeError("opening marker must be the first non-empty line")
    if any(line != "" for line in lines[:opening]):
        raise EnvelopeError("text before opening marker is forbidden")

    machine_lines = lines[opening + 1 : closing]
    if not machine_lines:
        raise EnvelopeError("machine block is empty")
    human_lines = lines[closing + 1 :]
    human_text = "\n".join(human_lines)
    return machine_lines, human_text


def _parse_fields(machine_lines: Sequence[str]) -> dict[str, str | tuple[str, ...]]:
    parsed: dict[str, str | tuple[str, ...]] = {}
    cursor = 0
    for spec in FIELD_SPECS:
        if cursor >= len(machine_lines):
            raise EnvelopeError(f"missing field {spec.name}")
        expected_prefix = f"{spec.name}:"
        line = machine_lines[cursor]
        if spec.kind == "scalar":
            if not line.startswith(expected_prefix):
                _raise_field_order_error(line, spec.name, parsed)
            expected_value_prefix = f"{expected_prefix} "
            if not line.startswith(expected_value_prefix):
                raise EnvelopeError(f"{spec.name} must contain one scalar value")
            value = line[len(expected_value_prefix) :]
            if not value or value != value.strip():
                raise EnvelopeError(f"{spec.name} has empty or ambiguous whitespace")
            parsed[spec.name] = value
            cursor += 1
            continue

        if line != expected_prefix:
            _raise_field_order_error(line, spec.name, parsed)
        cursor += 1
        values: list[str] = []
        while cursor < len(machine_lines) and machine_lines[cursor].startswith("  - "):
            value = machine_lines[cursor][4:]
            if not value or value != value.strip():
                raise EnvelopeError(f"{spec.name} contains an empty or ambiguous list item")
            values.append(value)
            cursor += 1
        if not values:
            raise EnvelopeError(f"{spec.name} list must not be empty")
        parsed[spec.name] = tuple(values)

    if cursor != len(machine_lines):
        line = machine_lines[cursor]
        label = line.split(":", 1)[0]
        if label in parsed:
            raise EnvelopeError(f"duplicate field {label}")
        if label not in FIELD_NAMES:
            raise EnvelopeError(f"unknown field or free text in machine block: {line!r}")
        raise EnvelopeError(f"field {label} is out of order")
    return parsed


def _raise_field_order_error(
    line: str,
    expected: str,
    parsed: dict[str, str | tuple[str, ...]],
) -> None:
    label = line.split(":", 1)[0]
    if label in parsed:
        raise EnvelopeError(f"duplicate field {label}")
    if label in FIELD_NAMES:
        raise EnvelopeError(f"expected field {expected}, found out-of-order {label}")
    raise EnvelopeError(f"expected field {expected}, found unknown content {line!r}")


def _parse_attribution(items: tuple[str, ...]) -> tuple[str, str]:
    if len(items) != 3:
        raise EnvelopeError("Attribution must contain producer, runtime, and run exactly once")
    prefixes = ("producer: ", "runtime: ", "run: ")
    values: list[str] = []
    for item, prefix in zip(items, prefixes, strict=True):
        if not item.startswith(prefix):
            raise EnvelopeError(f"Attribution item must be ordered as {prefix.strip()}")
        value = item[len(prefix) :]
        if not value or value != value.strip():
            raise EnvelopeError(f"Attribution {prefix.strip(': ')} must be non-empty")
        values.append(value)
    producer, runtime, run = values
    if runtime != RUNTIME_ID:
        raise EnvelopeError(f"Attribution runtime must be {RUNTIME_ID}")
    return producer, run


def parse_envelope(payload: bytes | str) -> ParsedEnvelope:
    """Parse and field-validate one envelope without reading repository state."""

    text = _decode(payload)
    machine_lines, human_text = _split_machine_block(text)
    fields = _parse_fields(machine_lines)
    version = fields["Envelope-Version"]
    if version != "1":
        raise EnvelopeError("Envelope-Version must be 1")
    producer, run = _parse_attribution(_tuple_field(fields, "Attribution"))
    envelope = Envelope(
        pr_type=_scalar_field(fields, "PR-Type"),
        change=_scalar_field(fields, "Change"),
        task=_scalar_field(fields, "Task"),
        base_oid=_scalar_field(fields, "Base-OID"),
        head_oid=_scalar_field(fields, "Head-OID"),
        decision_grade=_scalar_field(fields, "Decision-Grade"),
        depends_on=_scalar_field(fields, "Depends-On"),
        evidence=_tuple_field(fields, "Evidence"),
        producer=producer,
        run=run,
    )
    _validate_fields(envelope)
    return ParsedEnvelope(envelope=envelope, human_text=human_text)


def _scalar_field(fields: dict[str, str | tuple[str, ...]], name: str) -> str:
    value = fields[name]
    if not isinstance(value, str):
        raise EnvelopeError(f"{name} must be scalar")
    return value


def _tuple_field(
    fields: dict[str, str | tuple[str, ...]],
    name: str,
) -> tuple[str, ...]:
    value = fields[name]
    if not isinstance(value, tuple):
        raise EnvelopeError(f"{name} must be a list")
    return value


def _validate_fields(envelope: Envelope) -> None:
    if envelope.pr_type not in PR_TYPES:
        raise EnvelopeError(f"unknown PR-Type {envelope.pr_type!r}")
    if not CHANGE_RE.fullmatch(envelope.change):
        raise EnvelopeError("Change must be a canonical CHG-* identifier")

    if envelope.pr_type in TASK_BOUND_TYPES:
        if not TASK_RE.fullmatch(envelope.task):
            raise EnvelopeError(f"{envelope.pr_type} requires Task: TASK-*")
    elif envelope.pr_type in CHANGE_BOUND_TYPES:
        if envelope.task != "none":
            raise EnvelopeError(f"{envelope.pr_type} requires Task: none")

    if not LOWER_OID_RE.fullmatch(envelope.base_oid):
        raise EnvelopeError("Base-OID must be lowercase full 40-hex")
    if not LOWER_OID_RE.fullmatch(envelope.head_oid):
        raise EnvelopeError("Head-OID must be lowercase full 40-hex")
    if envelope.base_oid == envelope.head_oid:
        raise EnvelopeError("Base-OID and Head-OID must differ")
    if envelope.decision_grade not in DECISION_GRADES:
        raise EnvelopeError("Decision-Grade must be D0, D1, or D2")
    if envelope.depends_on != "none" and not DEPENDENCY_RE.fullmatch(envelope.depends_on):
        raise EnvelopeError("Depends-On must be none or #<positive decimal PR number>")

    _validate_evidence(envelope.evidence)
    _validate_identity("producer", envelope.producer)
    _validate_identity("run", envelope.run)
    lowered_producer = envelope.producer.lower()
    if lowered_producer.startswith(("provider:", "model:")):
        raise EnvelopeError("producer attribution must identify the configured host, not a provider")


def _validate_evidence(items: tuple[str, ...]) -> None:
    if not items:
        raise EnvelopeError("Evidence list must not be empty")
    none_items = [item for item in items if item.startswith("none:")]
    if none_items:
        if len(items) != 1 or len(none_items) != 1:
            raise EnvelopeError("none evidence must be the only Evidence item")
        reason = none_items[0][len("none:") :]
        if not reason.startswith(" ") or not reason.strip():
            raise EnvelopeError("none evidence requires a non-empty reason")
        if reason != f" {reason.strip()}":
            raise EnvelopeError("none evidence reason has ambiguous whitespace")
        return

    for item in items:
        if item != item.strip() or not item:
            raise EnvelopeError("Evidence path has ambiguous whitespace")
        if (
            "\\" in item
            or "://" in item
            or WINDOWS_ABSOLUTE_RE.match(item)
            or item.startswith(("/", "./"))
        ):
            raise EnvelopeError(f"Evidence must be a repository-relative path: {item!r}")
        path = PurePosixPath(item)
        if path.is_absolute() or any(part in ("", ".", "..") for part in path.parts):
            raise EnvelopeError(f"Evidence must not be absolute or traverse: {item!r}")


def _validate_identity(name: str, value: str) -> None:
    if not IDENTITY_RE.fullmatch(value):
        raise EnvelopeError(
            f"Attribution {name} must be a non-empty stable identifier without whitespace"
        )


def _active_change_directories(repo_root: Path, change_id: str) -> tuple[Path, ...]:
    changes_root = repo_root / "openspec" / "changes"
    matches: list[Path] = []
    for proposal in sorted(changes_root.glob("chg-*/proposal.md")):
        try:
            text = proposal.read_text(encoding="utf-8")
        except (OSError, UnicodeError) as error:
            raise EnvelopeError(f"cannot read active proposal {proposal}: {error}") from error
        identifier = _frontmatter_change_id(text, proposal)
        if identifier == change_id:
            matches.append(proposal.parent)
    return tuple(matches)


def _frontmatter_change_id(text: str, proposal: Path) -> str:
    lines = text.splitlines()
    if not lines or lines[0] != "---":
        raise EnvelopeError(f"active proposal must start with YAML front matter: {proposal}")
    try:
        closing = lines.index("---", 1)
    except ValueError as error:
        raise EnvelopeError(f"active proposal front matter is not closed: {proposal}") from error
    frontmatter = "\n".join(lines[1:closing])
    identifiers = FRONTMATTER_ID_RE.findall(frontmatter)
    if len(identifiers) != 1:
        raise EnvelopeError(f"active proposal must contain exactly one front-matter id: {proposal}")
    return identifiers[0]


def validate_envelope(envelope: Envelope, repo_root: Path) -> None:
    """Validate field semantics and active change/task identity."""

    _validate_fields(envelope)
    change_directories = _active_change_directories(repo_root, envelope.change)
    if len(change_directories) != 1:
        raise EnvelopeError(
            f"Change {envelope.change} must resolve to exactly one active change; "
            f"found {len(change_directories)}"
        )
    if envelope.pr_type not in TASK_BOUND_TYPES:
        return

    tasks_file = change_directories[0] / "tasks.md"
    try:
        tasks_text = tasks_file.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        raise EnvelopeError(f"cannot read active tasks file {tasks_file}: {error}") from error
    matches = [task for task in TASK_HEADER_RE.findall(tasks_text) if task == envelope.task]
    if len(matches) != 1:
        raise EnvelopeError(
            f"Task {envelope.task} must appear exactly once in {tasks_file}; "
            f"found {len(matches)}"
        )


def _field_values(envelope: Envelope) -> dict[str, str | tuple[str, ...]]:
    return {
        "Envelope-Version": "1",
        "PR-Type": envelope.pr_type,
        "Change": envelope.change,
        "Task": envelope.task,
        "Base-OID": envelope.base_oid,
        "Head-OID": envelope.head_oid,
        "Decision-Grade": envelope.decision_grade,
        "Depends-On": envelope.depends_on,
        "Evidence": envelope.evidence,
        "Attribution": (
            f"producer: {envelope.producer}",
            f"runtime: {RUNTIME_ID}",
            f"run: {envelope.run}",
        ),
    }


def _validate_human_text(human_text: str) -> str:
    if not human_text:
        return ""
    text = _decode(human_text)
    if text != text.strip():
        raise EnvelopeError("human text must not have leading or trailing blank space")
    forbidden_prefixes = tuple(f"{name}:" for name in FIELD_NAMES)
    for line in text.split("\n"):
        if line in (OPEN_MARKER, CLOSE_MARKER) or line.startswith(forbidden_prefixes):
            raise EnvelopeError("human text must not contain envelope markers or field-like lines")
    return text


def render_envelope(
    envelope: Envelope,
    repo_root: Path,
    *,
    human_text: str = "",
) -> str:
    """Render canonical UTF-8/LF envelope text after full validation."""

    validate_envelope(envelope, repo_root)
    normalized_human_text = _validate_human_text(human_text)
    values = _field_values(envelope)
    lines = [OPEN_MARKER]
    for spec in FIELD_SPECS:
        value = values[spec.name]
        if spec.kind == "scalar":
            if not isinstance(value, str):
                raise EnvelopeError(f"internal field definition mismatch for {spec.name}")
            lines.append(f"{spec.name}: {value}")
        else:
            if not isinstance(value, tuple):
                raise EnvelopeError(f"internal field definition mismatch for {spec.name}")
            lines.append(f"{spec.name}:")
            lines.extend(f"  - {item}" for item in value)
    lines.append(CLOSE_MARKER)
    if normalized_human_text:
        lines.extend(("", normalized_human_text))
    return "\n".join(lines) + "\n"


def parse_and_validate(payload: bytes | str, repo_root: Path) -> ParsedEnvelope:
    """Parse one envelope and bind it to the active repository state."""

    parsed = parse_envelope(payload)
    validate_envelope(parsed.envelope, repo_root)
    return parsed
