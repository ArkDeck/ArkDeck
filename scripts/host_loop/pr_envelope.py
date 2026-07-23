#!/usr/bin/env python3
"""Pure renderer, parser, and validator for ArkDeck PR envelope v1."""

from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Iterable


OPEN_MARKER = "<!-- arkdeck-pr-envelope:v1 -->"
CLOSE_MARKER = "<!-- /arkdeck-pr-envelope -->"
RUNTIME_ID = "host-loop/1"

TASK_BOUND_TYPES = frozenset(
    {"implementation", "status", "verification", "archive"}
)
CHANGE_BOUND_TYPES = frozenset({"proposal", "approval", "readiness"})
PR_TYPES = TASK_BOUND_TYPES | CHANGE_BOUND_TYPES
DECISION_GRADES = frozenset({"D0", "D1", "D2"})

FULL_OID_RE = re.compile(r"^[0-9a-f]{40}$")
CHANGE_RE = re.compile(r"^CHG-[A-Za-z0-9][A-Za-z0-9-]*$")
TASK_RE = re.compile(r"^TASK-[A-Z0-9]+-[0-9]{3}$")
TASK_HEADER_RE = re.compile(
    r"^##\s+(TASK-[A-Z0-9]+(?:-[A-Z0-9]+)*-[0-9]{3}[A-Z]?)(?:\s|$)",
    re.MULTILINE,
)
DEPENDENCY_RE = re.compile(r"^#[1-9][0-9]*$")
PRODUCER_RE = re.compile(r"^[a-z0-9][a-z0-9._/-]*$")
FIELD_HEADER_RE = re.compile(r"^([A-Za-z][A-Za-z-]*):(?: |$)")


class EnvelopeError(ValueError):
    """A named, fail-closed envelope contract violation."""


@dataclass(frozen=True)
class FieldDefinition:
    name: str
    kind: str


# Renderer and parser intentionally share this single ordered definition.
FIELD_DEFINITIONS = (
    FieldDefinition("Envelope-Version", "scalar"),
    FieldDefinition("PR-Type", "scalar"),
    FieldDefinition("Change", "scalar"),
    FieldDefinition("Task", "scalar"),
    FieldDefinition("Base-OID", "scalar"),
    FieldDefinition("Head-OID", "scalar"),
    FieldDefinition("Decision-Grade", "scalar"),
    FieldDefinition("Depends-On", "scalar"),
    FieldDefinition("Evidence", "list"),
    FieldDefinition("Attribution", "list"),
)


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


def _single_line(value: str, field: str) -> str:
    if not isinstance(value, str):
        raise EnvelopeError(f"{field} must be a string")
    if not value or value != value.strip() or "\n" in value or "\r" in value:
        raise EnvelopeError(f"{field} must be a non-empty, trimmed single line")
    return value


def _validate_evidence(items: Iterable[str]) -> tuple[str, ...]:
    evidence = tuple(items)
    if not evidence:
        raise EnvelopeError("Evidence must contain at least one item")

    none_items = [item for item in evidence if item.startswith("none:")]
    if none_items:
        if len(evidence) != 1:
            raise EnvelopeError("Evidence none reason cannot be mixed with paths")
        item = _single_line(evidence[0], "Evidence")
        prefix = "none: "
        if not item.startswith(prefix) or not item[len(prefix) :].strip():
            raise EnvelopeError("Evidence none item requires a non-empty reason")
        return evidence

    for item in evidence:
        path_text = _single_line(item, "Evidence path")
        if "\\" in path_text or "://" in path_text:
            raise EnvelopeError(f"Evidence path must be repository-relative: {path_text}")
        path = PurePosixPath(path_text)
        if path.is_absolute() or any(part in {"", ".", ".."} for part in path.parts):
            raise EnvelopeError(f"Evidence path must be repository-relative: {path_text}")
    return evidence


def validate_envelope(envelope: Envelope) -> Envelope:
    """Validate field-level envelope v1 invariants without external I/O."""

    if envelope.pr_type not in PR_TYPES:
        raise EnvelopeError(f"PR-Type is unknown: {envelope.pr_type}")
    if not CHANGE_RE.fullmatch(envelope.change):
        raise EnvelopeError(f"Change is invalid: {envelope.change}")

    if envelope.pr_type in TASK_BOUND_TYPES:
        if not TASK_RE.fullmatch(envelope.task):
            raise EnvelopeError(
                f"PR-Type {envelope.pr_type} requires Task: TASK-*"
            )
    elif envelope.task != "none":
        raise EnvelopeError(f"PR-Type {envelope.pr_type} requires Task: none")

    for value, field in (
        (envelope.base_oid, "Base-OID"),
        (envelope.head_oid, "Head-OID"),
    ):
        if not FULL_OID_RE.fullmatch(value):
            raise EnvelopeError(f"{field} must be a lowercase full 40-hex OID")
    if envelope.base_oid == envelope.head_oid:
        raise EnvelopeError("Base-OID and Head-OID must differ")

    if envelope.decision_grade not in DECISION_GRADES:
        raise EnvelopeError(
            f"Decision-Grade is unknown: {envelope.decision_grade}"
        )
    if envelope.depends_on != "none" and not DEPENDENCY_RE.fullmatch(
        envelope.depends_on
    ):
        raise EnvelopeError("Depends-On must be none or #<positive decimal PR number>")

    _validate_evidence(envelope.evidence)
    producer = _single_line(envelope.producer, "Attribution producer")
    if not PRODUCER_RE.fullmatch(producer):
        raise EnvelopeError(
            "Attribution producer must be an explicitly configured stable host identity"
        )
    _single_line(envelope.run, "Attribution run")
    return envelope


def render_envelope(envelope: Envelope, human_notes: str = "") -> str:
    """Render canonical UTF-8/LF-compatible Markdown for envelope v1."""

    validate_envelope(envelope)
    if not isinstance(human_notes, str):
        raise EnvelopeError("human notes must be a string")
    if "\r" in human_notes:
        raise EnvelopeError("human notes must use LF line endings")
    if OPEN_MARKER in human_notes or CLOSE_MARKER in human_notes:
        raise EnvelopeError("human notes must not contain envelope markers")

    scalar_values = {
        "Envelope-Version": "1",
        "PR-Type": envelope.pr_type,
        "Change": envelope.change,
        "Task": envelope.task,
        "Base-OID": envelope.base_oid,
        "Head-OID": envelope.head_oid,
        "Decision-Grade": envelope.decision_grade,
        "Depends-On": envelope.depends_on,
    }
    list_values = {
        "Evidence": envelope.evidence,
        "Attribution": (
            f"producer: {envelope.producer}",
            f"runtime: {RUNTIME_ID}",
            f"run: {envelope.run}",
        ),
    }

    lines = [OPEN_MARKER]
    for definition in FIELD_DEFINITIONS:
        if definition.kind == "scalar":
            lines.append(f"{definition.name}: {scalar_values[definition.name]}")
        else:
            lines.append(f"{definition.name}:")
            lines.extend(f"  - {item}" for item in list_values[definition.name])
    lines.append(CLOSE_MARKER)

    rendered = "\n".join(lines) + "\n"
    if human_notes:
        rendered += "\n" + human_notes.rstrip("\n") + "\n"
    return rendered


def _decode_body(body: str | bytes) -> str:
    if isinstance(body, bytes):
        try:
            text = body.decode("utf-8")
        except UnicodeDecodeError as error:
            raise EnvelopeError(f"PR body is not UTF-8: {error}") from error
    elif isinstance(body, str):
        text = body
    else:
        raise EnvelopeError("PR body must be str or bytes")
    if "\r" in text:
        raise EnvelopeError("PR body must use LF line endings")
    if "\x00" in text:
        raise EnvelopeError("PR body contains a NUL byte")
    return text


def _machine_lines(text: str) -> list[str]:
    if text.count(OPEN_MARKER) != 1 or text.count(CLOSE_MARKER) != 1:
        raise EnvelopeError("envelope markers must each appear exactly once")

    lines = text.splitlines()
    non_empty = next((line for line in lines if line), None)
    if non_empty != OPEN_MARKER:
        raise EnvelopeError(f"first non-empty line must be {OPEN_MARKER}")
    try:
        open_index = lines.index(OPEN_MARKER)
        close_index = lines.index(CLOSE_MARKER)
    except ValueError as error:
        raise EnvelopeError("envelope markers must be standalone lines") from error
    if close_index <= open_index:
        raise EnvelopeError("envelope markers are reversed")
    return lines[open_index + 1 : close_index]


def _check_field_surface(lines: list[str]) -> None:
    known = {definition.name for definition in FIELD_DEFINITIONS}
    counts = {name: 0 for name in known}
    for line in lines:
        match = FIELD_HEADER_RE.match(line)
        if not match:
            continue
        name = match.group(1)
        if name not in known:
            raise EnvelopeError(f"unknown envelope field: {name}")
        counts[name] += 1
    for definition in FIELD_DEFINITIONS:
        count = counts[definition.name]
        if count == 0:
            raise EnvelopeError(f"missing envelope field: {definition.name}")
        if count > 1:
            raise EnvelopeError(f"duplicate envelope field: {definition.name}")


def _parse_fields(lines: list[str]) -> dict[str, str | tuple[str, ...]]:
    _check_field_surface(lines)
    parsed: dict[str, str | tuple[str, ...]] = {}
    index = 0
    for field_index, definition in enumerate(FIELD_DEFINITIONS):
        if index >= len(lines):
            raise EnvelopeError(f"missing envelope field: {definition.name}")
        if definition.kind == "scalar":
            prefix = f"{definition.name}: "
            line = lines[index]
            if not line.startswith(prefix):
                raise EnvelopeError(
                    f"envelope field order error: expected {definition.name}"
                )
            parsed[definition.name] = _single_line(
                line[len(prefix) :], definition.name
            )
            index += 1
            continue

        if lines[index] != f"{definition.name}:":
            raise EnvelopeError(
                f"envelope field order error: expected {definition.name}"
            )
        index += 1
        next_name = (
            FIELD_DEFINITIONS[field_index + 1].name
            if field_index + 1 < len(FIELD_DEFINITIONS)
            else None
        )
        items: list[str] = []
        while index < len(lines):
            if next_name is not None and lines[index].startswith(f"{next_name}:"):
                break
            line = lines[index]
            if not line.startswith("  - "):
                raise EnvelopeError(
                    f"{definition.name} list item must start with two spaces and '- '"
                )
            items.append(_single_line(line[4:], f"{definition.name} item"))
            index += 1
        if not items:
            raise EnvelopeError(f"{definition.name} must contain at least one item")
        parsed[definition.name] = tuple(items)

    if index != len(lines):
        raise EnvelopeError("machine block contains text outside defined fields")
    return parsed


def parse_envelope(body: str | bytes) -> Envelope:
    """Parse and validate a PR body, ignoring human notes after the marker."""

    text = _decode_body(body)
    fields = _parse_fields(_machine_lines(text))
    if fields["Envelope-Version"] != "1":
        raise EnvelopeError("Envelope-Version must be 1")

    attribution = fields["Attribution"]
    assert isinstance(attribution, tuple)
    expected_prefixes = ("producer: ", "runtime: ", "run: ")
    if len(attribution) != len(expected_prefixes):
        raise EnvelopeError(
            "Attribution must contain producer, runtime, and run exactly once"
        )
    values: list[str] = []
    for item, prefix in zip(attribution, expected_prefixes):
        if not item.startswith(prefix):
            raise EnvelopeError(
                "Attribution must be ordered producer, runtime, and run"
            )
        values.append(_single_line(item[len(prefix) :], f"Attribution {prefix[:-2]}"))
    producer, runtime, run = values
    if runtime != RUNTIME_ID:
        raise EnvelopeError(f"Attribution runtime must be {RUNTIME_ID}")

    evidence = fields["Evidence"]
    assert isinstance(evidence, tuple)
    envelope = Envelope(
        pr_type=str(fields["PR-Type"]),
        change=str(fields["Change"]),
        task=str(fields["Task"]),
        base_oid=str(fields["Base-OID"]),
        head_oid=str(fields["Head-OID"]),
        decision_grade=str(fields["Decision-Grade"]),
        depends_on=str(fields["Depends-On"]),
        evidence=evidence,
        producer=producer,
        run=run,
    )
    return validate_envelope(envelope)


def _read_utf8(path: Path, description: str) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        raise EnvelopeError(f"cannot read {description} {path}: {error}") from error


def _proposal_id(path: Path) -> str:
    text = _read_utf8(path, "proposal")
    lines = text.splitlines()
    if not lines or lines[0] != "---":
        raise EnvelopeError(f"proposal has no canonical frontmatter: {path}")
    try:
        end = lines.index("---", 1)
    except ValueError as error:
        raise EnvelopeError(f"proposal frontmatter is not closed: {path}") from error
    ids = [
        line[len("id:") :].strip()
        for line in lines[1:end]
        if line.startswith("id:")
    ]
    if len(ids) != 1 or not CHANGE_RE.fullmatch(ids[0]):
        raise EnvelopeError(f"proposal must contain one canonical CHG-* id: {path}")
    return ids[0]


def validate_repository_scope(envelope: Envelope, repo_root: Path) -> Envelope:
    """Validate Change/Task against the unique active repository definitions."""

    validate_envelope(envelope)
    changes_root = repo_root / "openspec" / "changes"
    proposals = sorted(changes_root.glob("chg-*/proposal.md"))
    change_matches = [
        proposal.parent
        for proposal in proposals
        if _proposal_id(proposal) == envelope.change
    ]
    if len(change_matches) != 1:
        raise EnvelopeError(
            f"Change must match exactly one active proposal: {envelope.change}"
        )

    if envelope.pr_type in TASK_BOUND_TYPES:
        task_matches: list[Path] = []
        for tasks_file in sorted(changes_root.glob("chg-*/tasks.md")):
            text = _read_utf8(tasks_file, "tasks")
            for match in TASK_HEADER_RE.finditer(text):
                if match.group(1) == envelope.task:
                    task_matches.append(tasks_file)
        if len(task_matches) != 1:
            raise EnvelopeError(
                f"Task must match exactly one active task: {envelope.task}"
            )
        if task_matches[0].parent != change_matches[0]:
            raise EnvelopeError(
                f"Task {envelope.task} does not belong to Change {envelope.change}"
            )
    return envelope
