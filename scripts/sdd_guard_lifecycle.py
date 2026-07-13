#!/usr/bin/env python3.14
"""Change/Task/claim/run/archive/release enforcement for ``check_sdd.py``.

The parser phase in :mod:`sdd_guard_core` owns YAML ambiguity checks.  This
module consumes that phase's documents and validates the cross-file and Git
history relationships which cannot be expressed by JSON Schema alone.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import subprocess
from collections import defaultdict
from datetime import timedelta
from pathlib import Path, PurePosixPath
from typing import Any

import sdd_guard_support as support


SHA256 = re.compile(r"[a-f0-9]{64}")
GIT_OID = support.CANONICAL_GIT_OID
TERMINAL_STATUSES = frozenset(("done", "blocked", "interrupted", "superseded"))
HEAVY_RESOURCE_KINDS = frozenset(("hdc-server", "device-binding", "host-volume"))
DESTRUCTIVE_CAPABILITY = "destructiveDeviceMutation"


def _relative(root: Path, path: Path) -> str:
    return path.resolve().relative_to(root.resolve()).as_posix()


def _sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _load_json(path: Path, errors: list[str]) -> dict[str, Any] | None:
    try:
        def reject_duplicate(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
            result: dict[str, Any] = {}
            for key, value in pairs:
                if key in result:
                    raise ValueError(f"duplicate object key: {key}")
                result[key] = value
            return result

        value = json.loads(path.read_bytes(), object_pairs_hook=reject_duplicate)
        if not isinstance(value, dict):
            raise ValueError("top level is not an object")
        return value
    except (OSError, UnicodeDecodeError, json.JSONDecodeError, ValueError) as exc:
        errors.append(f"invalid JSON {_relative(path.parents[3] if False else path.parent, path)}: {exc}")
        return None


def _load_json_relative(root: Path, path: Path, errors: list[str]) -> dict[str, Any] | None:
    try:
        return support.load_json(path)
    except (OSError, UnicodeDecodeError, json.JSONDecodeError, ValueError) as exc:
        errors.append(f"invalid JSON {_relative(root, path)}: {exc}")
        return None


def _parse_time(value: object) -> support.Rfc3339Instant | None:
    try:
        return support.parse_iso8601(str(value))
    except (TypeError, ValueError):
        return None


def _canonical_commit(value: object) -> bool:
    return isinstance(value, str) and GIT_OID.fullmatch(value) is not None


def _repo_path(root: Path, raw: object) -> Path | None:
    if not isinstance(raw, str) or not raw or "\x00" in raw:
        return None
    pure = PurePosixPath(raw)
    if pure.is_absolute() or ".." in pure.parts:
        return None
    candidate = (root / pure).resolve()
    try:
        candidate.relative_to(root.resolve())
    except ValueError:
        return None
    return candidate


def _schema_validate(
    instance: Any,
    schema: Any,
    owner: Any,
    schemas: dict[str, tuple[Path, Any]],
    location: str = "$",
) -> list[str]:
    """Small deterministic Draft-2020-12 subset used by ArkDeck contracts."""

    failures: list[str] = []
    if schema is True:
        return failures
    if schema is False or not isinstance(schema, dict):
        return [f"{location}: invalid/false schema"]
    if "$ref" in schema:
        ref = schema["$ref"]
        try:
            if ref.startswith("#"):
                target_owner = owner
                target = _json_pointer(owner, ref)
            else:
                base, separator, fragment = ref.partition("#")
                target_owner = schemas[base][1]
                target = _json_pointer(target_owner, f"#{fragment}" if separator else "#")
            failures.extend(_schema_validate(instance, target, target_owner, schemas, location))
        except (KeyError, IndexError, TypeError, ValueError):
            failures.append(f"{location}: unresolved $ref {ref}")
    expected = schema.get("type")
    if expected is not None:
        alternatives = [expected] if isinstance(expected, str) else expected
        if not any(_type_matches(instance, name) for name in alternatives):
            return failures + [f"{location}: expected type {alternatives}"]
    if "const" in schema and instance != schema["const"]:
        failures.append(f"{location}: value differs from const")
    if "enum" in schema and instance not in schema["enum"]:
        failures.append(f"{location}: value is not in enum")
    for child in schema.get("allOf", []):
        failures.extend(_schema_validate(instance, child, owner, schemas, location))
    if "anyOf" in schema and not any(
        not _schema_validate(instance, child, owner, schemas, location)
        for child in schema["anyOf"]
    ):
        failures.append(f"{location}: no anyOf branch matched")
    if "oneOf" in schema:
        matches = sum(
            not _schema_validate(instance, child, owner, schemas, location)
            for child in schema["oneOf"]
        )
        if matches != 1:
            failures.append(f"{location}: expected exactly one oneOf match, got {matches}")
    if "if" in schema:
        branch = "then" if not _schema_validate(instance, schema["if"], owner, schemas, location) else "else"
        if branch in schema:
            failures.extend(_schema_validate(instance, schema[branch], owner, schemas, location))
    if isinstance(instance, dict):
        for key in schema.get("required", []):
            if key not in instance:
                failures.append(f"{location}: missing required property {key}")
        properties = schema.get("properties", {})
        for key, value in instance.items():
            if key in properties:
                failures.extend(
                    _schema_validate(value, properties[key], owner, schemas, f"{location}.{key}")
                )
            elif schema.get("additionalProperties") is False:
                failures.append(f"{location}: additional property {key}")
    if isinstance(instance, list):
        if len(instance) < schema.get("minItems", 0):
            failures.append(f"{location}: too few items")
        if schema.get("uniqueItems"):
            encoded = [json.dumps(value, sort_keys=True, separators=(",", ":")) for value in instance]
            if len(encoded) != len(set(encoded)):
                failures.append(f"{location}: duplicate array items")
        if "items" in schema:
            for index, value in enumerate(instance):
                failures.extend(
                    _schema_validate(value, schema["items"], owner, schemas, f"{location}[{index}]")
                )
    if isinstance(instance, str):
        if len(instance) < schema.get("minLength", 0):
            failures.append(f"{location}: string is too short")
        if "pattern" in schema and re.search(schema["pattern"], instance) is None:
            failures.append(f"{location}: string does not match pattern")
        if schema.get("format") == "date-time" and _parse_time(instance) is None:
            failures.append(f"{location}: invalid date-time")
    if isinstance(instance, int) and not isinstance(instance, bool):
        if "minimum" in schema and instance < schema["minimum"]:
            failures.append(f"{location}: below minimum")
    return failures


def _type_matches(value: Any, expected: str) -> bool:
    return {
        "null": value is None,
        "boolean": isinstance(value, bool),
        "object": isinstance(value, dict),
        "array": isinstance(value, list),
        "string": isinstance(value, str),
        "integer": isinstance(value, int) and not isinstance(value, bool),
        "number": isinstance(value, (int, float)) and not isinstance(value, bool),
    }.get(expected, False)


def _json_pointer(document: Any, fragment: str) -> Any:
    if fragment in ("", "#"):
        return document
    if not fragment.startswith("#/"):
        raise KeyError(fragment)
    value = document
    for raw in fragment[2:].split("/"):
        token = raw.replace("~1", "/").replace("~0", "~")
        value = value[int(token)] if isinstance(value, list) else value[token]
    return value


def _load_schemas(root: Path, errors: list[str]) -> dict[str, tuple[Path, Any]]:
    result: dict[str, tuple[Path, Any]] = {}
    for path in sorted((root / "openspec/contracts").glob("*.schema.json")):
        document = _load_json_relative(root, path, errors)
        if not document:
            continue
        schema_id = document.get("$id")
        if isinstance(schema_id, str):
            if schema_id in result:
                errors.append(f"duplicate JSON Schema $id: {schema_id}")
            result[schema_id] = (path, document)
    return result


def _validate_instance(
    root: Path,
    path: Path,
    document: dict[str, Any],
    schema_name: str,
    schemas: dict[str, tuple[Path, Any]],
    errors: list[str],
) -> None:
    schema_path = root / "openspec/contracts" / schema_name
    schema = _load_json_relative(root, schema_path, errors)
    if not schema:
        return
    failures = _schema_validate(document, schema, schema, schemas)
    if failures:
        errors.append(f"invalid {schema_name.removesuffix('.schema.json')} {_relative(root, path)}: {'; '.join(failures)}")


def _report_contract_fields(
    root: Path,
    path: Path,
    document: dict[str, Any],
    schema_name: str,
    label: str,
    errors: list[str],
) -> None:
    schema = _load_json_relative(root, root / "openspec/contracts" / schema_name, []) or {}
    missing = [key for key in schema.get("required", []) if key not in document]
    extra = [key for key in document if key not in schema.get("properties", {})]
    if missing:
        errors.append(f"{label} {_relative(root, path)} missing {', '.join(missing)}")
    if extra:
        errors.append(f"{label} {_relative(root, path)} has unknown fields {', '.join(extra)}")


def _collect_approvals(
    root: Path,
    schemas: dict[str, tuple[Path, Any]],
    errors: list[str],
) -> tuple[dict[str, dict[str, Any]], dict[str, Path]]:
    approvals: dict[str, dict[str, Any]] = {}
    paths: dict[str, Path] = {}
    for path in sorted((root / "openspec/approvals").glob("**/*.json")):
        document = _load_json_relative(root, path, errors)
        if document is None:
            continue
        _validate_instance(root, path, document, "approval.schema.json", schemas, errors)
        schema = _load_json_relative(
            root, root / "openspec/contracts/approval.schema.json", []
        ) or {}
        missing = [key for key in schema.get("required", []) if key not in document]
        extra = [key for key in document if key not in schema.get("properties", {})]
        if missing:
            errors.append(f"approval {_relative(root, path)} missing {', '.join(missing)}")
        if extra:
            errors.append(
                f"approval {_relative(root, path)} has unknown fields {', '.join(extra)}"
            )
        if document.get("mechanism") == "detachedSignature" and not document.get(
            "signature"
        ):
            errors.append(
                f"detached-signature approval {_relative(root, path)} has no signature"
            )
        if document.get("decision") == "approved" and not (
            support.git_commit(document.get("baseRevision"), root=root)
            and support.git_ancestor(
                document.get("baseRevision"), support.git_head_revision(root), root=root
            )
        ):
            errors.append(
                f"approval {_relative(root, path)} baseRevision is not a canonical ancestor commit of the protected result"
            )
        approval_id = document.get("approvalId")
        if not isinstance(approval_id, str):
            continue
        if approval_id in approvals:
            errors.append(f"duplicate approval ID {approval_id}")
        approvals[approval_id] = document
        paths[approval_id] = path
    return approvals, paths


def _trust_context(root: Path, context: dict[str, Any]) -> tuple[dict[str, Any], list[dict[str, Any]], bool]:
    yaml_documents = context.get("yaml_documents", {})
    policy_path = root / "openspec/governance/trust-policy.yaml"
    policy = yaml_documents.get(policy_path.as_posix()) or yaml_documents.get(
        _relative(root, policy_path)
    )
    if not isinstance(policy, dict):
        try:
            policy = support.yaml_safe_load(policy_path.read_text(encoding="utf-8")) or {}
        except (OSError, ValueError):
            policy = {}
    verifiers = policy.get("external_verifiers", []) if isinstance(policy, dict) else []
    open_gate = (
        isinstance(policy, dict)
        and policy.get("status") == "accepted"
        and policy.get("execution_gate") == "open"
        and bool(verifiers)
        and bool(os.environ.get("ARKDECK_TRUST_ROOT_BUNDLE"))
    )
    return policy, verifiers if isinstance(verifiers, list) else [], open_gate


def _change_id(path: Path) -> str:
    return path.name.replace("chg-", "CHG-", 1)


def _proposal_frontmatter(path: Path) -> dict[str, Any]:
    if not path.is_file():
        return {}
    try:
        return support.markdown_frontmatter(path) or {}
    except (OSError, ValueError):
        return {}


def _collect_change_records(
    root: Path,
    approvals: dict[str, dict[str, Any]],
    approval_paths: dict[str, Path],
    verifiers: list[dict[str, Any]],
    errors: list[str],
) -> dict[str, dict[str, Any]]:
    records: dict[str, dict[str, Any]] = {}
    change_root = root / "openspec/changes"
    roots = [path for path in change_root.iterdir() if path.is_dir() and path.name != "archive"]
    archive_root = change_root / "archive"
    if archive_root.is_dir():
        roots.extend(path for path in archive_root.iterdir() if path.is_dir())
    for path in sorted(roots):
        if path.parent == change_root and re.fullmatch(
            r"chg-[0-9]{4}-[0-9]{3}-[a-z0-9]+(?:-[a-z0-9]+)*", path.name
        ) is None:
            errors.append(f"invalid change folder name: {_relative(root, path)}")
        proposal = _proposal_frontmatter(path / "proposal.md")
        if not proposal.get("id"):
            errors.append(f"change proposal {_relative(root, path / 'proposal.md')} has no ID")
        change_id = str(proposal.get("id") or _change_id(path))
        if proposal.get("schema") == "arkdeck-behavior" and proposal.get(
            "core_change_level"
        ) not in ("minor", "major"):
            errors.append(
                f"behavior change {proposal.get('id') or _relative(root, path / 'proposal.md')} must be MINOR or MAJOR in V1; PATCH lacks a machine proof that normative pass/fail semantics are unchanged"
            )
        if change_id in records:
            errors.append(
                f"duplicate Change ID {change_id}: {_relative(root, records[change_id]['root'] / 'proposal.md')}, {_relative(root, path / 'proposal.md')}"
            )
            continue
        lock_path = path / "change-lock.yaml"
        lock: dict[str, Any] | None = None
        if lock_path.is_file():
            try:
                lock = support.yaml_safe_load(lock_path.read_text(encoding="utf-8")) or {}
            except (OSError, ValueError):
                lock = None
        review_path = path / "review.md"
        ready_review_path = path / "ready-review.md"
        review_match = re.search(
            r"^> Status：([^\s]+)\s*$",
            review_path.read_text(encoding="utf-8") if review_path.is_file() else "",
            re.MULTILINE,
        )
        ready_match = re.search(
            r"^> Status：([^\s]+)\s*$",
            ready_review_path.read_text(encoding="utf-8") if ready_review_path.is_file() else "",
            re.MULTILINE,
        )
        approval = approvals.get(lock.get("approval_id")) if isinstance(lock, dict) else None
        approved = bool(
            lock
            and lock.get("status") == "approved"
            and lock.get("change_id") == change_id
            and lock.get("revision") == proposal.get("revision")
            and approval
            and approval.get("decision") == "approved"
            and approval.get("subjectType") == "change"
            and approval.get("subjectId") == change_id
            and approval.get("subjectRevision") == proposal.get("revision")
            and approval.get("subjectSha256") == _sha(lock_path)
            and support.git_commit(approval.get("baseRevision"), root=root)
            and review_match
            and review_match.group(1) == "passed"
            and ready_match
            and ready_match.group(1) == "passed"
            and support.externally_verified(
                approval_paths.get(str(approval.get("approvalId"))),
                lock_path,
                approval,
                verifiers,
                root=root,
            )
        )
        approved_at = _parse_time(approval.get("approvedAt")) if approved and approval else None
        if approved and approved_at is None:
            errors.append(f"approved Change {change_id} has an invalid approval timestamp")
            approved = False
        records[change_id] = {
            "id": change_id,
            "root": path,
            "proposal_path": path / "proposal.md",
            "lock_path": lock_path,
            "proposal": proposal,
            "lock": lock,
            "approved": approved,
            "approval": approval,
            "approved_at": approved_at,
            "archived": path.parent == archive_root,
        }
    return records


def _validate_change_lineage(
    root: Path,
    records: dict[str, dict[str, Any]],
    approvals: dict[str, dict[str, Any]],
    approval_paths: dict[str, Path],
    verifiers: list[dict[str, Any]],
    errors: list[str],
) -> None:
    links: dict[str, str] = {}
    successors: dict[str, list[str]] = defaultdict(list)
    barrier_records: list[dict[str, Any]] = []
    for change_id, record in records.items():
        predecessor = record["proposal"].get("supersedes_change_id")
        barrier_id = record["proposal"].get("supersession_barrier_attestation_id")
        if not predecessor:
            if barrier_id is not None:
                errors.append(
                    f"lineage-root Change {change_id} preallocates an unnecessary supersession barrier"
                )
            continue
        if re.fullmatch(r"CHGSUPAUTH-[A-Z0-9._-]+", str(barrier_id)) is None:
            errors.append(
                f"successor Change {change_id} lacks a preallocated CHGSUPAUTH barrier ID"
            )
        if predecessor not in records:
            errors.append(f"change {change_id} supersedes an unknown/deleted Change {predecessor}")
            continue
        if not records[predecessor].get("approved"):
            errors.append(
                f"change {change_id} supersedes a predecessor that is not externally approved"
            )
        links[change_id] = predecessor
        if record["approved"]:
            successors[predecessor].append(change_id)
    cycles = support.change_supersession_cycles(links)
    for cycle in cycles:
        rendered = ", ".join(cycle if isinstance(cycle, list) else [str(cycle)])
        errors.append(f"Change supersession graph contains a cycle: {rendered}")
    for predecessor, values in successors.items():
        if len(values) > 1:
            errors.append(
                f"approved Change {predecessor} has multiple approved successors: {', '.join(sorted(values))}"
            )
    for change_id, predecessor in links.items():
        record = records[change_id]
        if record["approved"] and not records[predecessor]["approved"]:
            errors.append(
                f"approved successor Change {change_id} does not reference an externally approved predecessor"
            )
        if (
            record.get("approved")
            and records[predecessor].get("approved_at")
            and record.get("approved_at")
            and records[predecessor]["approved_at"] >= record["approved_at"]
        ):
            errors.append(
                f"approved successor Change {change_id} does not postdate predecessor {predecessor}"
            )
        if record["approved"]:
            barrier = support.validate_change_supersession_barrier(
                errors=errors,
                successor_id=change_id,
                successor_record=record,
                predecessor_id=predecessor,
                predecessor_record=records[predecessor],
                verifiers=verifiers,
                root=root,
            )
            if barrier:
                record["barrier"] = barrier
                barrier_records.append(barrier)
    grouped_barriers: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for barrier in barrier_records:
        grouped_barriers[str(support.dig(barrier, "document", "ledger", "ledgerId"))].append(barrier)
    for ledger_id, values in grouped_barriers.items():
        ordered = sorted(
            values,
            key=lambda value: support.dig(
                value, "document", "ledger", "lineageSequence"
            ),
        )
        sequences = [
            support.dig(value, "document", "ledger", "lineageSequence")
            for value in ordered
        ]
        revisions = [
            support.dig(value, "document", "ledger", "revision")
            for value in ordered
        ]
        if len(sequences) != len(set(sequences)):
            errors.append(
                f"supersession barrier ledger {ledger_id} reuses a lineage sequence"
            )
        if len(revisions) != len(set(revisions)):
            errors.append(
                f"supersession barrier ledger {ledger_id} reuses a ledger revision"
            )
        for previous, following in zip(ordered, ordered[1:]):
            if not (
                support.dig(following, "document", "ledger", "revision")
                > support.dig(previous, "document", "ledger", "revision")
                and following["closed_at"] > previous["closed_at"]
            ):
                errors.append(
                    f"supersession barrier ledger {ledger_id} is not monotonic"
                )


def _task_profile_entry(context: dict[str, Any], task: dict[str, Any]) -> dict[str, Any] | None:
    lock = context.get("platform_lock")
    if not isinstance(lock, dict):
        return None
    return next(
        (
            entry
            for entry in lock.get("profiles", [])
            if entry.get("id") == support.dig(task, "platformProfile", "id")
        ),
        None,
    )


def _validate_scope_and_task_union(
    root: Path,
    context: dict[str, Any],
    records: dict[str, dict[str, Any]],
    tasks: dict[str, dict[str, Any]],
    local_cases: dict[str, dict[str, Any]],
    overlays: dict[str, dict[str, Any]],
    errors: list[str],
) -> dict[str, dict[str, Any]]:
    scopes: dict[str, dict[str, Any]] = {}
    for path in sorted((root / "openspec/changes").glob("chg-*/scope.yaml")):
        try:
            scope = support.yaml_safe_load(path.read_text(encoding="utf-8")) or {}
        except (OSError, ValueError):
            continue
        fields = sorted(("acceptance", "change_id", "requirements", "revision", "schema"))
        if sorted(scope) != fields:
            errors.append(f"change scope {_relative(root, path)} has an invalid shape")
        expected = path.parent.name.replace("chg-", "CHG-", 1)
        if scope.get("schema") != "arkdeck-change-scope-1" or str(scope.get("change_id", "")).lower() != expected.lower():
            errors.append(f"change scope {_relative(root, path)} identity mismatch")
        proposal = records.get(str(scope.get("change_id")), {}).get("proposal", {})
        if scope.get("revision") != 1 or proposal.get("revision") != 1:
            errors.append(f"change scope {_relative(root, path)} revision mismatch or unsupported in-place r2")
        requirements = scope.get("requirements", [])
        acceptance = scope.get("acceptance", [])
        if not requirements or not acceptance:
            errors.append(f"change scope {_relative(root, path)} has empty Requirement/AC sets")
        if len(requirements) != len(set(requirements)) or len(acceptance) != len(set(acceptance)):
            errors.append(f"change scope {_relative(root, path)} has duplicate Requirement/AC IDs")
        requirement_known = context.get("requirement_known_for_change")
        acceptance_known = context.get("acceptance_known_for_change")
        for requirement_id in requirements:
            if callable(requirement_known) and not requirement_known(
                scope.get("change_id"), requirement_id
            ):
                errors.append(
                    f"change scope {_relative(root, path)} has unknown Requirement/Port {requirement_id} in its baseline+delta overlay"
                )
        for acceptance_id in acceptance:
            if callable(acceptance_known) and not acceptance_known(
                scope.get("change_id"), acceptance_id
            ):
                errors.append(
                    f"change scope {_relative(root, path)} has unknown Acceptance {acceptance_id} in its baseline+delta overlay"
                )
        if proposal.get("schema") == "arkdeck-behavior":
            overlay = overlays.get(str(scope.get("change_id")))
            if not overlay:
                errors.append(f"behavior change scope {_relative(root, path)} has no valid baseline+delta overlay")
            else:
                if set(overlay.get("touched_requirements", [])) - set(requirements):
                    errors.append(f"behavior change scope {_relative(root, path)} omits a changed Requirement")
                if set(overlay.get("touched_acceptance", [])) - set(acceptance):
                    errors.append(f"behavior change scope {_relative(root, path)} omits a changed Acceptance")
                verification_text = (
                    (path.parent / "verification.md").read_text(encoding="utf-8")
                    if (path.parent / "verification.md").is_file()
                    else ""
                )
                for acceptance_id in acceptance:
                    if re.search(rf"\b{re.escape(acceptance_id)}\b", verification_text) is None:
                        errors.append(
                            f"behavior change verification plan omits scoped Acceptance {acceptance_id}"
                        )
            if not (path.parent / "acceptance-cases.yaml").is_file():
                errors.append(
                    f"behavior change {scope.get('change_id')} requires a change-local canonical acceptance registry"
                )
        elif proposal.get("schema") == "arkdeck-platform":
            impact = path.parent / "spec-impact.md"
            marker = bool(
                impact.is_file()
                and re.search(
                    r"^> Exact affected scope：`scope\.yaml`\s*$",
                    impact.read_text(encoding="utf-8"),
                    re.MULTILINE,
                )
            )
            if not marker:
                errors.append(
                    f"platform change {scope.get('change_id')} spec-impact does not declare scope.yaml as its single exact affected set"
                )
            if not (path.parent / "acceptance-cases.yaml").is_file():
                errors.append(
                    f"platform change {scope.get('change_id')} requires a canonical acceptance registry (empty cases are allowed)"
                )
        local_acceptance = sorted(
            case_id
            for case_id, metadata in local_cases.items()
            if metadata.get("change_id") == scope.get("change_id")
        )
        if set(local_acceptance) - set(acceptance):
            errors.append(f"change scope {_relative(root, path)} omits a change-local Acceptance")
        if str(scope.get("change_id")) in scopes:
            errors.append(f"duplicate change scope {scope.get('change_id')}")
        scopes[str(scope.get("change_id"))] = scope
    grouped: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for task in tasks.values():
        grouped[str(task.get("changeId"))].append(task)
    for change_id, packets in grouped.items():
        scope = scopes.get(change_id)
        if not scope:
            errors.append(f"change {change_id} has Task packets but no immutable scope.yaml")
            continue
        task_requirements = sorted({value for packet in packets for value in packet.get("requirementRefs", [])})
        task_acceptance = sorted({value for packet in packets for value in packet.get("acceptanceRefs", [])})
        if task_requirements != sorted(scope.get("requirements", [])):
            errors.append(f"change {change_id} Task Requirement union differs from approved scope")
        if task_acceptance != sorted(scope.get("acceptance", [])):
            errors.append(f"change {change_id} Task Acceptance union differs from approved scope")
    for path in sorted((root / "openspec/changes").glob("chg-*/tasks.md")):
        indexed = sorted(set(re.findall(r"\b(TASK-[A-Z0-9-]+)\b", path.read_text(encoding="utf-8"))))
        packets = sorted(item.stem for item in (path.parent / "task-packets").glob("*.json"))
        if indexed != packets:
            errors.append(f"Task index {_relative(root, path)} differs from packet files")
    return scopes


def _validate_tasks(
    root: Path,
    context: dict[str, Any],
    records: dict[str, dict[str, Any]],
    approvals: dict[str, dict[str, Any]],
    approval_paths: dict[str, Path],
    verifiers: list[dict[str, Any]],
    trust_open: bool,
    schemas: dict[str, tuple[Path, Any]],
    errors: list[str],
) -> tuple[dict[str, dict[str, Any]], dict[str, Path]]:
    tasks: dict[str, dict[str, Any]] = {}
    paths: dict[str, Path] = {}
    for path in sorted((root / "openspec/changes").glob("**/task-packets/*.json")):
        if "archive" in path.relative_to(root / "openspec/changes").parts:
            continue
        task = _load_json_relative(root, path, errors)
        if task is None:
            continue
        _validate_instance(root, path, task, "task-packet.schema.json", schemas, errors)
        task_schema = _load_json_relative(
            root, root / "openspec/contracts/task-packet.schema.json", []
        ) or {}
        missing_fields = [key for key in task_schema.get("required", []) if key not in task]
        extra_fields = [key for key in task if key not in task_schema.get("properties", {})]
        if missing_fields:
            errors.append(f"task packet {_relative(root, path)} missing {', '.join(missing_fields)}")
        if extra_fields:
            errors.append(
                f"task packet {_relative(root, path)} has unknown fields {', '.join(extra_fields)}"
            )
        task_id = task.get("taskId")
        if not isinstance(task_id, str):
            continue
        if task_id in tasks:
            errors.append(f"duplicate Task packet {task_id}")
        tasks[task_id] = task
        paths[task_id] = path
        if path.stem != task_id:
            errors.append(f"task packet filename/id mismatch: {_relative(root, path)}")
        mutable = sorted(
            set(("claim", "attempt", "owner", "claimedBy", "run", "result", "runtimeStatus"))
            & set(task)
        )
        if mutable:
            errors.append(
                f"immutable Task packet {task_id} contains runtime fields {', '.join(mutable)}"
            )
        if task.get("revision") != 1 or task.get("changeRevision") != 1:
            errors.append(f"Task {task_id} is not immutable V1")
        change = records.get(str(task.get("changeId")))
        if not change:
            errors.append(f"Task {task_id} belongs to unknown Change {task.get('changeId')}")
        elif path.parent.parent != change["root"]:
            errors.append(f"Task {task_id} path does not match its Change")
        platform_entry = _task_profile_entry(context, task)
        if platform_entry is None or platform_entry.get("platform") != task.get("platform"):
            errors.append(f"Task {task_id} platform/profile binding mismatch")
        platform_pin = task.get("platformProfile", {})
        locked_profile = next(
            (
                item
                for item in (context.get("platform_lock") or {}).get("profiles", [])
                if item.get("id") == platform_pin.get("id")
            ),
            None,
        )
        if locked_profile and task.get("platform") != locked_profile.get("platform"):
                errors.append(f"Task {task_id} platform does not match its platform profile")
        profile_metadata = context.get("platform_profiles", {}).get(
            platform_pin.get("id")
        )
        if platform_pin.get("sha256"):
            profile_path = _repo_path(
                root, (profile_metadata or {}).get("profile_path")
            )
            if not (
                profile_path
                and profile_path.is_file()
                and platform_pin.get("version")
                == (profile_metadata or {}).get("version")
                and platform_pin.get("sha256") == _sha(profile_path)
            ):
                errors.append(f"Task {task_id} draft/current platform pin is stale")
        refs = task.get("acceptanceRefs", [])
        verification_ids = [item.get("acceptanceId") for item in task.get("verification", [])]
        if sorted(refs) != sorted(verification_ids):
            errors.append(f"Task {task_id} verification does not exactly cover acceptanceRefs")
        if len(refs) != len(set(refs)):
            errors.append(f"Task {task_id} has duplicate acceptanceRefs")
        test_ids = [item.get("testId") for item in task.get("verification", [])]
        if len(test_ids) != len(set(test_ids)):
            errors.append(f"Task {task_id} has duplicate test IDs")
        case_for_change = context.get("case_definition_for_change")
        case_definitions = context.get("case_definitions", {})
        platform_cases = {
            item.get("id"): item
            for item in context.get("platform_case_definitions", {}).get(task.get("platform"), [])
        }
        for item in task.get("verification", []):
            case_id = item.get("acceptanceId")
            canonical = (
                case_for_change(task.get("changeId"), case_id)
                if callable(case_for_change)
                else case_definitions.get(case_id) or platform_cases.get(case_id)
            )
            if canonical is None:
                errors.append(f"Task {task_id} has no canonical acceptance case for {case_id}")
            elif not (
                item.get("testId") == canonical.get("test_id")
                and item.get("method") == canonical.get("method")
                and item.get("minimumEvidence") == canonical.get("minimum_evidence")
            ):
                errors.append(
                    f"Task {task_id} changes canonical Test ID/method/evidence for {case_id}"
                )
        acceptance_known = context.get("acceptance_known_for_change")
        requirement_known = context.get("requirement_known_for_change")
        for case_id in refs:
            if callable(acceptance_known) and not acceptance_known(task.get("changeId"), case_id):
                errors.append(f"Task {task_id} references unknown acceptance {case_id}")
            platform_case = context.get("platform_acceptance", {}).get(case_id)
            if platform_case and platform_case.get("platform") != task.get("platform"):
                errors.append(f"Task {task_id} uses a platform acceptance case from another platform")
            if platform_case and platform_case.get("change_id") != task.get("changeId"):
                errors.append(f"Task {task_id} uses a platform acceptance case from another change")
        for requirement_id in task.get("requirementRefs", []):
            if callable(requirement_known) and not requirement_known(
                task.get("changeId"), requirement_id
            ):
                errors.append(
                    f"Task {task_id} references unknown requirement/port {requirement_id} in its baseline+delta overlay"
                )
        for field in ("allowedPaths", "forbiddenPaths", "deliverables", "verification", "stopConditions"):
            if not task.get(field):
                errors.append(f"Task {task_id} has empty {field}")
        for field in ("allowedPaths", "forbiddenPaths"):
            for value in task.get(field, []):
                if not isinstance(value, str) or not value or value.startswith("/") or re.search(r"\s", value):
                    errors.append(f"Task {task_id} {field} is not a repository path pattern: {value}")
        if not task.get("integrationProfiles"):
            errors.append(f"Task {task_id} must pin at least one integration profile")
        if task.get("hardwareRequirement") == "required" and not any(
            item.get("minimumEvidence") == "realHardware" for item in task.get("verification", [])
        ):
            errors.append(f"Task {task_id} requires hardware but has no realHardware acceptance case")
        if (
            task.get("risk") == "destructive"
            and task.get("hardwareRequirement") == "required"
            and task.get("executionEnvironment") != "controlledHardwareLab"
        ):
            errors.append(f"Task {task_id} may execute destructive hardware work outside a controlled lab")
        resource_pattern = re.compile(
            r"arkdeck-resource:([a-z-]+):(?:[A-Za-z0-9._~-]|%[0-9A-F]{2})+"
        )
        resource_kinds: list[str] = []
        for resource in task.get("exclusiveResources", []):
            match = resource_pattern.fullmatch(resource) if isinstance(resource, str) else None
            if match:
                resource_kinds.append(match.group(1))
        if len(resource_kinds) != len(task.get("exclusiveResources", [])):
            errors.append(f"Task {task_id} has non-canonical exclusive resource identity")
        capabilities = set(task.get("runtimeCapabilities", []))
        if "deviceNetworkAccess" in capabilities and "hdc-server" not in resource_kinds:
            errors.append(f"Task {task_id} device-network capability lacks an hdc-server resource")
        if capabilities & {"realDeviceRead", "realDeviceMutation", DESTRUCTIVE_CAPABILITY} and "device-binding" not in resource_kinds:
            errors.append(f"Task {task_id} real-device capability lacks a device-binding resource")
        if "externalFilesystemWrite" in capabilities and "host-volume" not in resource_kinds:
            errors.append(f"Task {task_id} external-filesystem capability lacks a host-volume resource")
        if task.get("executionEnvironment") == "standardAgent" and DESTRUCTIVE_CAPABILITY in task.get(
            "runtimeCapabilities", []
        ):
            errors.append(f"Task {task_id} grants a standard Agent destructive-device or host-elevation capability")
        if task.get("executionEnvironment") == "standardAgent" and "hostPrivilegeElevation" in capabilities:
            errors.append(f"Task {task_id} grants a standard Agent destructive-device or host-elevation capability")
        if capabilities & {"realDeviceRead", "realDeviceMutation", DESTRUCTIVE_CAPABILITY} and task.get("hardwareRequirement") == "none":
            errors.append(f"Task {task_id} grants real-device capability without declaring hardware")
        if task.get("executionEnvironment") == "controlledHardwareLab" and not (
            capabilities & {"realDeviceRead", "realDeviceMutation", DESTRUCTIVE_CAPABILITY}
        ):
            errors.append(f"Task {task_id} declares a controlled hardware lab without a real-device capability")
        if DESTRUCTIVE_CAPABILITY in capabilities and not (
            task.get("executionEnvironment") == "controlledHardwareLab"
            and task.get("risk") == "destructive"
            and task.get("hardwareRequirement") == "required"
        ):
            errors.append(
                f"Task {task_id} destructive-device capability lacks controlled-lab/destructive/required-hardware gates"
            )
        if "AC-FLASH-014-01" in refs and task.get("executionEnvironment") != "controlledHardwareLab":
            errors.append(
                f"Task {task_id} cannot produce real Flash support evidence outside a controlled lab"
            )
        if "AC-FLASH-014-01" in refs and not (
            task.get("risk") == "destructive"
            and task.get("hardwareRequirement") == "required"
            and DESTRUCTIVE_CAPABILITY in capabilities
        ):
            errors.append(
                f"Task {task_id} real Flash evidence lacks destructive risk/capability/required-hardware gates"
            )
        conformance_pin = task.get("conformanceSuite", {})
        conformance_path = root / "openspec/verification/core-conformance.yaml"
        if conformance_pin.get("sha256") and not (
            conformance_pin.get("id")
            == (context.get("conformance") or {}).get("suite")
            and conformance_pin.get("sha256") == _sha(conformance_path)
        ):
            errors.append(f"Task {task_id} draft/current conformance pin is stale")
        core_pin = task.get("coreBaseline", {})
        core_path = root / "openspec/baselines" / f"{context.get('configured_core_baseline')}.lock.yaml"
        if core_pin.get("sha256") and core_pin.get("sha256") != _sha(core_path):
            errors.append(f"Task {task_id} draft/current Core baseline pin is stale")
        integration_metadata = context.get("integration_profiles", {})
        for pin in task.get("integrationProfiles", []):
            metadata = integration_metadata.get(pin.get("id"))
            integration_path = _repo_path(root, (metadata or {}).get("path"))
            if pin.get("sha256") and not (
                integration_path
                and integration_path.is_file()
                and pin.get("version") == (metadata or {}).get("version")
                and pin.get("sha256") == _sha(integration_path)
            ):
                errors.append(
                    f"Task {task_id} draft/current integration pin {pin.get('id')} is stale"
                )
        status = task.get("status")
        if status != "ready":
            continue
        if not trust_open:
            errors.append(f"ready Task {task_id} is forbidden while externally rooted trust gate is closed")
        baseline = context.get("baseline") or {}
        integration = context.get("integration_lock") or {}
        conformance = context.get("conformance") or {}
        platform_lock = context.get("platform_lock") or {}
        if baseline.get("status") != "accepted" or support.dig(baseline, "ratification", "execution_gate") != "open":
            errors.append(f"ready Task {task_id} requires accepted/open Core baseline")
        if integration.get("status") != "accepted" or integration.get("execution_gate") != "open":
            errors.append(f"ready Task {task_id} requires accepted/open Integration lock")
        if conformance.get("status") != "accepted" or conformance.get("execution_gate") != "open":
            errors.append(f"ready Task {task_id} requires accepted/open conformance suite")
        if platform_lock.get("status") != "accepted" or platform_lock.get("execution_gate") != "open":
            errors.append(f"ready Task {task_id} requires accepted/open platform lock")
        if not change or not change["approved"]:
            errors.append(f"ready Task {task_id} requires immutable change-lock.yaml")
        change_root = path.parent.parent
        for name in ("proposal.md", "scope.yaml", "design.md", "verification.md", "review.md", "ready-review.md", "tasks.md"):
            if not (change_root / name).is_file():
                errors.append(f"ready Task {task_id} change is missing {name}")
        proposal = _proposal_frontmatter(change_root / "proposal.md")
        if not (
            proposal.get("status") == "proposed"
            and proposal.get("revision") == task.get("changeRevision")
        ):
            errors.append(
                f"ready Task {task_id} proposal source was mutated or revision drifted"
            )
        if not (
            proposal.get("id") == task.get("changeId")
            and proposal.get("core_baseline") == baseline.get("baseline")
        ):
            errors.append(f"ready Task {task_id} proposal identity/Core pin mismatch")
        level = proposal.get("core_change_level")
        if level not in ("none", "patch", "minor", "major"):
            errors.append(f"ready Task {task_id} has invalid core_change_level")
        if proposal.get("schema") == "arkdeck-behavior" and level not in (
            "minor",
            "major",
        ):
            errors.append(f"ready Task {task_id} behavior change must be MINOR or MAJOR in V1")
        if proposal.get("class") == "core" and level == "none":
            errors.append(f"ready Task {task_id} class core cannot declare no Core change")
        delta_files = list((change_root / "specs").glob("**/*.md"))
        if proposal.get("schema") == "arkdeck-platform":
            if not (change_root / "spec-impact.md").is_file():
                errors.append(f"ready Task {task_id} platform change requires spec-impact.md")
            if delta_files:
                errors.append(
                    f"ready Task {task_id} platform change must not carry behavior delta specs"
                )
        elif proposal.get("schema") == "arkdeck-behavior":
            if not delta_files:
                errors.append(
                    f"ready Task {task_id} behavior change requires at least one delta spec"
                )
            if (change_root / "spec-impact.md").is_file():
                errors.append(
                    f"ready Task {task_id} behavior change must not replace delta with spec-impact.md"
                )
        else:
            errors.append(f"ready Task {task_id} proposal has unknown change schema")
        review_text = (change_root / "review.md").read_text(encoding="utf-8") if (change_root / "review.md").is_file() else ""
        if not re.search(r"^> Status：passed\s*$", review_text, re.MULTILINE):
            errors.append(f"ready Task {task_id} requires passed pre-task review")
        ready_text = (change_root / "ready-review.md").read_text(encoding="utf-8") if (change_root / "ready-review.md").is_file() else ""
        if not re.search(r"^> Status：passed\s*$", ready_text, re.MULTILINE):
            errors.append(f"ready Task {task_id} requires passed ready-review")
        change_lock_path = change_root / "change-lock.yaml"
        if change_lock_path.is_file():
            change_lock = support.yaml_safe_load(
                change_lock_path.read_text(encoding="utf-8")
            ) or {}
            if not (
                change_lock.get("status") == "approved"
                and change_lock.get("change_id") == task.get("changeId")
                and change_lock.get("revision") == task.get("changeRevision")
            ):
                errors.append(f"ready Task {task_id} change lock is not approved")
            lock_entries = change_lock.get("files", [])
            lock_paths = [item.get("path") for item in lock_entries]
            if len(lock_paths) != len(set(lock_paths)):
                errors.append(f"ready Task {task_id} change-lock has duplicate paths")
            if sorted(lock_paths) != support.expected_change_input_paths(
                change_root, root=root
            ):
                errors.append(
                    f"ready Task {task_id} change-lock is not the exact change input set"
                )
            for item in lock_entries:
                locked_path = _repo_path(root, item.get("path"))
                if not locked_path or not locked_path.is_file() or _sha(
                    locked_path
                ) != item.get("sha256"):
                    errors.append(
                        f"ready Task {task_id} change-lock input drift: {item.get('path')}"
                    )
            change_approval = approvals.get(change_lock.get("approval_id"))
            if not (
                change_approval
                and change_approval.get("subjectType") == "change"
                and change_approval.get("subjectId") == task.get("changeId")
                and change_approval.get("subjectRevision")
                == task.get("changeRevision")
                and change_approval.get("subjectSha256") == _sha(change_lock_path)
                and change_approval.get("baseRevision") == task.get("baseRevision")
                and change_approval.get("decision") == "approved"
                and support.externally_verified(
                    approval_paths.get(str(change_approval.get("approvalId"))),
                    change_lock_path,
                    change_approval,
                    verifiers,
                    root=root,
                )
            ):
                errors.append(
                    f"ready Task {task_id} change approval is not externally verified"
                )
        hashes = [
            support.dig(task, "coreBaseline", "sha256"),
            support.dig(task, "platformProfile", "sha256"),
            support.dig(task, "conformanceSuite", "sha256"),
            *[item.get("sha256") for item in task.get("integrationProfiles", [])],
        ]
        if not hashes or any(not isinstance(value, str) or SHA256.fullmatch(value) is None for value in hashes):
            errors.append(f"ready Task {task_id} has unresolved hash pins")
        if task.get("baseRevision") is None:
            errors.append(f"ready Task {task_id} has no base revision")
        if not support.git_commit(task.get("baseRevision"), root=root):
            errors.append(f"ready Task {task_id} base revision is not a real Git commit")
        baseline_path = root / "openspec/baselines" / f"{context.get('configured_core_baseline', 'CORE-1.0.0')}.lock.yaml"
        if baseline_path.is_file() and support.dig(task, "coreBaseline", "sha256") != _sha(baseline_path):
            errors.append(f"ready Task {task_id} Core baseline hash drift")
        expected_baseline_id = f"{support.dig(task, 'coreBaseline', 'id')}-{support.dig(task, 'coreBaseline', 'version')}"
        if expected_baseline_id != baseline.get("baseline"):
            errors.append(f"ready Task {task_id} Core baseline identity drift")
        if not locked_profile:
            errors.append(f"ready Task {task_id} references unknown platform profile")
        elif not (
            locked_profile.get("version") == platform_pin.get("version")
            and locked_profile.get("profile_sha256") == platform_pin.get("sha256")
        ):
            errors.append(f"ready Task {task_id} platform profile is not in the accepted lock")
        profile_path = _repo_path(root, (profile_metadata or {}).get("profile_path"))
        if profile_metadata and not (
            profile_path
            and profile_path.is_file()
            and platform_pin.get("version") == profile_metadata.get("version")
            and platform_pin.get("sha256") == _sha(profile_path)
        ):
            errors.append(f"ready Task {task_id} platform profile hash drift")
        locked_integrations = {
            item.get("id"): item
            for item in (context.get("integration_lock") or {}).get("profiles", [])
        }
        for pin in task.get("integrationProfiles", []):
            locked = locked_integrations.get(pin.get("id"))
            if not locked:
                errors.append(
                    f"ready Task {task_id} references unknown integration profile {pin.get('id')}"
                )
            elif not (
                locked.get("version") == pin.get("version")
                and locked.get("sha256") == pin.get("sha256")
            ):
                errors.append(
                    f"ready Task {task_id} integration profile {pin.get('id')} is not in the accepted lock"
                )
            metadata = integration_metadata.get(pin.get("id"))
            integration_path = _repo_path(root, (metadata or {}).get("path"))
            if metadata and not (
                integration_path
                and integration_path.is_file()
                and pin.get("version") == metadata.get("version")
                and pin.get("sha256") == _sha(integration_path)
            ):
                errors.append(f"ready Task {task_id} integration profile hash drift")
        if not (
            conformance_pin.get("id") == conformance.get("suite")
            and conformance_pin.get("sha256") == _sha(conformance_path)
        ):
            errors.append(f"ready Task {task_id} conformance identity/hash drift")
        fixture_ids = set(context.get("conformance_fixture_ids", []))
        for item in task.get("verification", []):
            if item.get("minimumEvidence") != "parserGolden":
                continue
            fixture_refs = item.get("fixtureRefs", [])
            if not fixture_refs:
                errors.append(
                    f"ready Task {task_id} parser case {item.get('acceptanceId')} has no pinned fixture"
                )
            if set(fixture_refs) - fixture_ids:
                errors.append(
                    f"ready Task {task_id} parser case {item.get('acceptanceId')} references an unpinned fixture"
                )
        approval = approvals.get(task.get("approvalId"))
        valid_approval = bool(
            approval
            and approval.get("subjectType") == "taskPacket"
            and approval.get("subjectId") == task_id
            and approval.get("subjectRevision") == 1
            and approval.get("subjectSha256") == _sha(path)
            and approval.get("decision") == "approved"
            and support.externally_verified(
                approval_paths.get(str(approval.get("approvalId"))),
                path,
                approval,
                verifiers,
                root=root,
            )
        )
        if approval is None:
            errors.append(f"ready Task {task_id} has no matching approval attestation")
        else:
            if not (
                approval.get("subjectType") == "taskPacket"
                and approval.get("subjectId") == task_id
                and approval.get("subjectRevision") == task.get("revision")
            ):
                errors.append(f"Task {task_id} approval is not for this packet")
            if approval.get("subjectSha256") != _sha(path):
                errors.append(f"Task {task_id} approval hash mismatch")
            if approval.get("baseRevision") != task.get("baseRevision"):
                errors.append(f"Task {task_id} approval base revision mismatch")
            if approval.get("decision") != "approved":
                errors.append(f"Task {task_id} approval decision is not approved")
            if not support.externally_verified(
                approval_paths.get(str(approval.get("approvalId"))),
                path,
                approval,
                verifiers,
                root=root,
            ):
                errors.append(f"Task {task_id} approval is not externally verified")
    for task_id, task in tasks.items():
        for dependency in task.get("dependsOn", []):
            if dependency not in tasks:
                errors.append(f"Task {task_id} has unknown dependency {dependency}")
    return tasks, paths


def _claim_paths(root: Path) -> list[Path]:
    return sorted(
        path
        for path in (root / "openspec/changes").glob("**/evidence/runs/**/claim.json")
        if "archive" not in path.relative_to(root / "openspec/changes").parts
    )


def _run_paths(root: Path) -> list[Path]:
    return sorted(
        path
        for path in (root / "openspec/changes").glob("**/evidence/runs/**/run.json")
        if "archive" not in path.relative_to(root / "openspec/changes").parts
    )


def _validate_claims_and_runs(
    root: Path,
    context: dict[str, Any],
    tasks: dict[str, dict[str, Any]],
    task_paths: dict[str, Path],
    approvals: dict[str, dict[str, Any]],
    approval_paths: dict[str, Path],
    verifiers: list[dict[str, Any]],
    schemas: dict[str, tuple[Path, Any]],
    errors: list[str],
) -> tuple[dict[str, dict[str, Any]], dict[str, dict[str, Any]]]:
    claims: dict[str, dict[str, Any]] = {}
    claim_paths: dict[str, Path] = {}
    claim_keys: set[tuple[str, int]] = set()
    lab_authorizations: dict[str, dict[str, Any]] = {}
    lab_plans: dict[str, dict[str, Any]] = {}
    sidecar_ids: dict[str, set[str]] = defaultdict(set)
    for path in _claim_paths(root):
        claim = _load_json_relative(root, path, errors)
        if claim is None:
            continue
        _validate_instance(root, path, claim, "task-claim.schema.json", schemas, errors)
        claim_schema = _load_json_relative(
            root, root / "openspec/contracts/task-claim.schema.json", []
        ) or {}
        missing = [key for key in claim_schema.get("required", []) if key not in claim]
        extra = [key for key in claim if key not in claim_schema.get("properties", {})]
        if missing:
            errors.append(f"claim {_relative(root, path)} missing {', '.join(missing)}")
        if extra:
            errors.append(f"claim {_relative(root, path)} has unknown fields {', '.join(extra)}")
        claim_id = str(claim.get("claimId"))
        if claim_id in claims:
            errors.append(f"duplicate claim ID {claim_id}")
        claims[claim_id] = claim
        claim_paths[claim_id] = path
        key = (str(claim.get("taskId")), int(claim.get("attempt", 0)))
        if key in claim_keys:
            errors.append(f"duplicate claim for {key[0]}/{key[1]}")
        claim_keys.add(key)
        task = tasks.get(key[0])
        task_path = task_paths.get(key[0])
        if not task:
            errors.append(f"claim {_relative(root, path)} references unknown Task")
            continue
        if task.get("status") != "ready":
            errors.append(f"claim {_relative(root, path)} targets a Task that is not ready")
        expected = {
            "taskId": task.get("taskId"),
            "taskRevision": task.get("revision"),
            "changeId": task.get("changeId"),
            "changeRevision": task.get("changeRevision"),
            "approvalId": task.get("approvalId"),
            "taskPacketSha256": _sha(task_path),
            "platform": task.get("platform"),
            "baseRevision": task.get("baseRevision"),
            "exclusiveResources": task.get("exclusiveResources"),
        }
        if claim.get("taskPacketSha256") != expected["taskPacketSha256"]:
            errors.append(f"claim {_relative(root, path)} Task packet hash mismatch")
        if claim.get("taskRevision") != expected["taskRevision"]:
            errors.append(f"claim {_relative(root, path)} task revision mismatch")
        if claim.get("approvalId") != expected["approvalId"]:
            errors.append(f"claim {_relative(root, path)} approval mismatch")
        if not (
            claim.get("changeId") == expected["changeId"]
            and claim.get("changeRevision") == expected["changeRevision"]
        ):
            errors.append(f"claim {_relative(root, path)} change mismatch")
        if not (
            claim.get("platform") == expected["platform"]
            and claim.get("baseRevision") == expected["baseRevision"]
        ):
            errors.append(f"claim {_relative(root, path)} platform/base revision mismatch")
        if sorted(claim.get("exclusiveResources", [])) != sorted(
            expected["exclusiveResources"]
        ):
            errors.append(f"claim {_relative(root, path)} exclusive resources mismatch")
        expected_core = f"{support.dig(task, 'coreBaseline', 'id')}-{support.dig(task, 'coreBaseline', 'version')}"
        if not (
            claim.get("coreBaseline") == expected_core
            and claim.get("coreBaselineSha256") == support.dig(task, "coreBaseline", "sha256")
        ):
            errors.append(f"claim {_relative(root, path)} Core baseline mismatch")
        if claim.get("platformProfile") != task.get("platformProfile"):
            errors.append(f"claim {_relative(root, path)} platform profile mismatch")
        if sorted(claim.get("integrationProfiles", []), key=lambda item: item.get("id")) != sorted(
            task.get("integrationProfiles", []), key=lambda item: item.get("id")
        ):
            errors.append(f"claim {_relative(root, path)} integration profiles mismatch")
        if claim.get("conformanceSuite") != task.get("conformanceSuite"):
            errors.append(f"claim {_relative(root, path)} conformance suite mismatch")
        if claim.get("status") != "claimed":
            errors.append(f"claim {_relative(root, path)} is not immutable claimed state")
        claimed = _parse_time(claim.get("claimedAt"))
        expires = _parse_time(claim.get("leaseExpiresAt"))
        if not claimed or not expires:
            errors.append(f"claim {_relative(root, path)} has invalid timestamps")
        else:
            if expires <= claimed:
                errors.append(f"claim {_relative(root, path)} lease is not after claim time")
            if expires - claimed > timedelta(hours=24):
                errors.append(f"claim {_relative(root, path)} lease exceeds the 24-hour V1 bound")
        if claimed:
            change_lock_id = None
            change_lock_path = task_path.parent.parent / "change-lock.yaml" if task_path else None
            if change_lock_path and change_lock_path.is_file():
                change_lock_doc = support.yaml_safe_load(
                    change_lock_path.read_text(encoding="utf-8")
                ) or {}
                change_lock_id = change_lock_doc.get("approval_id")
            prerequisites = {
                "Task packet": task.get("approvalId"),
                "change": change_lock_id,
                "Core baseline": support.dig(context.get("baseline"), "ratification", "approval_ref"),
                "Integration lock": support.dig(context.get("integration_lock"), "ratification", "approval_ref"),
                "Platform lock": support.dig(context.get("platform_lock"), "ratification", "approval_ref"),
                "Core conformance suite": support.dig(context.get("conformance"), "ratification", "approval_ref"),
                "trust policy": support.dig(context.get("trust_policy"), "ratification", "approval_ref"),
            }
            for label, approval_id in prerequisites.items():
                prerequisite = approvals.get(approval_id)
                if prerequisite is None:
                    errors.append(
                        f"claim {_relative(root, path)} lacks its {label} prerequisite approval"
                    )
                    continue
                approved_at = _parse_time(prerequisite.get("approvedAt"))
                if approved_at is None:
                    errors.append(
                        f"claim {_relative(root, path)} has an invalid {label} approval timestamp"
                    )
                elif approved_at > claimed:
                    errors.append(
                        f"claim {_relative(root, path)} predates its {label} approval"
                    )
        owner_path = path.with_name("claim-owner-attestation.json")
        owner = _load_json_relative(root, owner_path, errors) if owner_path.is_file() else None
        if not owner:
            errors.append(f"claim {_relative(root, path)} has no protected owner attestation")
        else:
            _report_contract_fields(
                root,
                owner_path,
                owner,
                "claim-owner-attestation.schema.json",
                "claim owner attestation",
                errors,
            )
            owner_id = str(owner.get("attestationId"))
            if owner_id in sidecar_ids["claim-owner"]:
                errors.append(f"duplicate claim owner attestation ID {owner_id}")
            sidecar_ids["claim-owner"].add(owner_id)
        if owner and (
            owner.get("claimId") != claim_id
            or owner.get("claimSha256") != _sha(path)
            or owner.get("taskId") != claim.get("taskId")
            or owner.get("attempt") != claim.get("attempt")
            or owner.get("claimedBy") != claim.get("claimedBy")
            or owner.get("claimantKind") != claim.get("claimantKind")
            or owner.get("claimedAt") != claim.get("claimedAt")
            or owner.get("leaseExpiresAt") != claim.get("leaseExpiresAt")
            or owner.get("subjectType") != "taskClaim"
        ):
            errors.append(f"claim {claim_id} owner attestation does not bind exact claim/owner")
        elif owner and not support.externally_verified(
            owner_path, path, owner, verifiers, root=root
        ):
            errors.append(
                f"claim {_relative(root, path)} owner attestation is not exact or externally verified"
            )
        heavy = [
            value
            for value in claim.get("exclusiveResources", [])
            if value.split(":", 3)[1:2] and value.split(":", 3)[1] in HEAVY_RESOURCE_KINDS
        ]
        resource_path = path.with_name("resource-identity-attestation.json")
        if not heavy and resource_path.is_file():
            errors.append(f"claim {_relative(root, path)} carries an unnecessary resource identity attestation")
        elif heavy and not resource_path.is_file():
            errors.append(
                f"claim {_relative(root, path)} has no protected canonical resource identity attestation"
            )
        elif heavy:
            resource = _load_json_relative(root, resource_path, errors) or {}
            _validate_instance(
                root,
                resource_path,
                resource,
                "resource-identity-attestation.schema.json",
                schemas,
                errors,
            )
            _report_contract_fields(
                root,
                resource_path,
                resource,
                "resource-identity-attestation.schema.json",
                "resource identity attestation",
                errors,
            )
            resource_id = str(resource.get("attestationId"))
            if resource_id in sidecar_ids["resource"]:
                errors.append(
                    f"duplicate resource identity attestation ID {resource_id}"
                )
            sidecar_ids["resource"].add(resource_id)
            resources = resource.get("resources", [])
            urns = [item.get("resourceUrn") for item in resources]
            canonical = True
            for item in resources:
                kind = item.get("kind")
                if kind == "hdc-server":
                    payload = ["arkdeck-hdc-server-v1", item.get("endpoint"), item.get("generation")]
                elif kind == "device-binding":
                    payload = [
                        "arkdeck-device-binding-v1",
                        item.get("deviceIdentity"),
                        item.get("bindingRevision"),
                    ]
                elif kind == "host-volume":
                    payload = ["arkdeck-host-volume-v1", item.get("volumeIdentity")]
                else:
                    canonical = False
                    continue
                digest = hashlib.sha256("\0".join(str(value) for value in payload).encode()).hexdigest()
                canonical &= item.get("resourceUrn") == f"arkdeck-resource:{kind}:{digest}"
            valid_resource = bool(
                resource.get("subjectType") == "resourceIdentitySet"
                and resource.get("claimId") == claim_id
                and resource.get("claimSha256") == _sha(path)
                and len(urns) == len(set(urns))
                and sorted(urns) == sorted(heavy)
                and canonical
                and support.externally_verified(
                    resource_path,
                    path,
                    resource,
                    verifiers,
                    root=root,
                )
            )
            if not valid_resource:
                errors.append(
                    f"claim {_relative(root, path)} canonical resource set is not exact or externally verified"
                )
        if task.get("executionEnvironment") == "controlledHardwareLab" and claim.get("claimantKind") != "humanOperator":
            errors.append(
                f"claim {_relative(root, path)} controlled hardware-lab Task is not held by a human operator"
            )
        lab_path = path.with_name("lab-execution-authorization.json")
        if task.get("executionEnvironment") != "controlledHardwareLab":
            if lab_path.is_file():
                errors.append(f"standard claim {_relative(root, path)} carries an unauthorized lab execution token")
        elif lab_path.is_file():
            lab = _load_json_relative(root, lab_path, errors) or {}
            _validate_instance(root, lab_path, lab, "lab-execution-authorization.schema.json", schemas, errors)
            _report_contract_fields(
                root,
                lab_path,
                lab,
                "lab-execution-authorization.schema.json",
                "lab authorization",
                errors,
            )
            authorization_id = str(lab.get("authorizationId"))
            if authorization_id in sidecar_ids["lab-authorization"]:
                errors.append(f"duplicate lab authorization ID {authorization_id}")
            sidecar_ids["lab-authorization"].add(authorization_id)
            plan_path = lab_path.parent / str(lab.get("planFile", ""))
            plan_contained = lab.get("planFile") == "lab-execution-plan.json" and plan_path.parent == lab_path.parent
            plan = _load_json_relative(root, plan_path, errors) if plan_contained and plan_path.is_file() else {}
            if not plan_contained or not plan_path.is_file():
                errors.append(f"lab plan beside {_relative(root, lab_path)} is missing or has an invalid filename")
            elif plan:
                _validate_instance(root, plan_path, plan, "lab-execution-plan.schema.json", schemas, errors)
                plan_schema = _load_json_relative(
                    root,
                    root / "openspec/contracts/lab-execution-plan.schema.json",
                    [],
                ) or {}
                plan_missing = [
                    key for key in plan_schema.get("required", []) if key not in plan
                ]
                plan_extra = [
                    key for key in plan if key not in plan_schema.get("properties", {})
                ]
                if plan_missing:
                    errors.append(
                        f"lab plan beside {_relative(root, lab_path)} missing {', '.join(plan_missing)}"
                    )
                if plan_extra:
                    errors.append(
                        f"lab plan beside {_relative(root, lab_path)} has unknown fields {', '.join(plan_extra)}"
                    )
                plan_id = str(plan.get("planId"))
                if plan_id in sidecar_ids["lab-plan"]:
                    errors.append(f"duplicate lab plan ID {plan_id}")
                sidecar_ids["lab-plan"].add(plan_id)
            approval = approvals.get(lab.get("approvalId"))
            approval_path = approval_paths.get(str(approval.get("approvalId"))) if approval else None
            valid_from = _parse_time(lab.get("validFrom"))
            valid_until = _parse_time(lab.get("validUntil"))
            claimed_at = _parse_time(claim.get("claimedAt"))
            confirmed_at = _parse_time(support.dig(lab, "physicalTargetConfirmation", "confirmedAt"))
            approved_at = _parse_time(approval.get("approvedAt")) if approval else None
            owner_file = path.with_name("claim-owner-attestation.json")
            executable = support.plan_executables(plan or {})
            step_ids = [item.get("id") for item in executable]
            if len(step_ids) != len(set(step_ids)):
                errors.append(
                    f"lab plan beside {_relative(root, lab_path)} has duplicate main/compensation Step IDs"
                )
            plan_kinds = sorted(set(item.get("kind") for item in executable))
            task_capabilities = list(task.get("runtimeCapabilities", []))
            required_device_capabilities: list[str] = []
            if any(
                item.get("effect") == "readOnly"
                and item.get("bindingRequirement") == "confirmedDevice"
                for item in executable
            ):
                required_device_capabilities.append("realDeviceRead")
            if any(item.get("effect") == "deviceMutation" for item in executable):
                required_device_capabilities.append("realDeviceMutation")
            if any(item.get("effect") == "destructive" for item in executable):
                required_device_capabilities.append(DESTRUCTIVE_CAPABILITY)
            actual_device_capabilities = [
                value
                for value in task_capabilities
                if value
                in ("realDeviceRead", "realDeviceMutation", DESTRUCTIVE_CAPABILITY)
            ]
            capability_matches = (
                sorted(lab.get("runtimeCapabilities", []))
                == sorted(task_capabilities)
                and sorted(required_device_capabilities)
                == sorted(actual_device_capabilities)
            )
            target = plan.get("target", {}) if isinstance(plan, dict) else {}
            target_resources = (
                target.get("resourceUrns", {})
                if isinstance(target.get("resourceUrns"), dict)
                else {}
            )
            expected_hdc_resource = None
            if "deviceNetworkAccess" in task_capabilities:
                hdc_digest = hashlib.sha256(
                    "\0".join(
                        str(value)
                        for value in (
                            "arkdeck-hdc-server-v1",
                            target.get("hdcServerEndpoint"),
                            target.get("hdcServerGeneration"),
                        )
                    ).encode()
                ).hexdigest()
                expected_hdc_resource = (
                    f"arkdeck-resource:hdc-server:{hdc_digest}"
                )
            expected_device_resource = None
            if actual_device_capabilities:
                device_digest = hashlib.sha256(
                    "\0".join(
                        str(value)
                        for value in (
                            "arkdeck-device-binding-v1",
                            target.get("deviceIdentity"),
                            target.get("bindingRevision"),
                        )
                    ).encode()
                ).hexdigest()
                expected_device_resource = (
                    f"arkdeck-resource:device-binding:{device_digest}"
                )
            expected_volume_resource = None
            if (
                "externalFilesystemWrite" in task_capabilities
                and target.get("hostVolumeIdentity")
            ):
                volume_digest = hashlib.sha256(
                    "\0".join(
                        (
                            "arkdeck-host-volume-v1",
                            str(target.get("hostVolumeIdentity")),
                        )
                    ).encode()
                ).hexdigest()
                expected_volume_resource = (
                    f"arkdeck-resource:host-volume:{volume_digest}"
                )
            volume_identity_valid = (
                "externalFilesystemWrite" not in task_capabilities
                or bool(target.get("hostVolumeIdentity"))
            )
            resource_matches = bool(
                volume_identity_valid
                and target_resources.get("hdcServer") == expected_hdc_resource
                and target_resources.get("deviceBinding")
                == expected_device_resource
                and target_resources.get("hostVolume") == expected_volume_resource
                and all(
                    resource in claim.get("exclusiveResources", [])
                    for resource in (
                        expected_hdc_resource,
                        expected_device_resource,
                        expected_volume_resource,
                    )
                    if resource is not None
                )
            )
            valid_lab = bool(
                approval
                and approval.get("subjectType") == "labExecutionAuthorization"
                and approval.get("subjectId") == lab.get("authorizationId")
                and approval.get("subjectRevision") == claim.get("attempt")
                and approval.get("subjectSha256") == _sha(lab_path)
                and approval.get("baseRevision") == claim.get("baseRevision")
                and approval.get("decision") == "approved"
                and support.externally_verified(
                    approval_path, lab_path, approval, verifiers, root=root
                )
                and all((claimed_at, confirmed_at, approved_at, valid_from, valid_until))
                and claimed_at <= confirmed_at <= approved_at <= valid_from < valid_until
                and len(step_ids) == len(set(step_ids))
                and lab.get("claimId") == claim_id
                and lab.get("claimSha256") == _sha(path)
                and owner_file.is_file()
                and lab.get("claimOwnerAttestationSha256") == _sha(owner_file)
                and lab.get("taskId") == claim.get("taskId")
                and lab.get("taskPacketSha256") == claim.get("taskPacketSha256")
                and lab.get("operatorId") == claim.get("claimedBy")
                and support.dig(lab, "physicalTargetConfirmation", "confirmedBy")
                == claim.get("claimedBy")
                and lab.get("platform") == claim.get("platform")
                and capability_matches
                and plan
                and plan.get("taskId") == claim.get("taskId")
                and plan.get("platform") == claim.get("platform")
                and plan.get("target") == lab.get("target")
                and plan_kinds == sorted(lab.get("authorizedStepKinds", []))
                and resource_matches
                and _sha(plan_path) == lab.get("planSha256")
            )
            if not valid_lab:
                errors.append(
                    f"controlled hardware-lab claim {_relative(root, path)} authorization is stale, mismatched or unapproved"
                )
            else:
                lab_authorizations[claim_id] = lab
                lab_plans[claim_id] = plan

    runs: dict[str, dict[str, Any]] = {}
    run_paths: dict[str, Path] = {}
    runs_by_claim: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for path in _run_paths(root):
        run = _load_json_relative(root, path, errors)
        if run is None:
            continue
        _validate_instance(root, path, run, "task-run.schema.json", schemas, errors)
        run_schema = _load_json_relative(
            root, root / "openspec/contracts/task-run.schema.json", []
        ) or {}
        missing = [key for key in run_schema.get("required", []) if key not in run]
        extra = [key for key in run if key not in run_schema.get("properties", {})]
        if missing:
            errors.append(f"run {_relative(root, path)} missing {', '.join(missing)}")
        if extra:
            errors.append(f"run {_relative(root, path)} has unknown fields {', '.join(extra)}")
        run_id = str(run.get("runId"))
        if run_id in runs:
            errors.append(f"duplicate run ID {run_id}")
        runs[run_id] = run
        run_paths[run_id] = path
        claim = claims.get(str(run.get("claimId")))
        runs_by_claim[str(run.get("claimId"))].append(run)
        if not claim:
            errors.append(f"run {_relative(root, path)} has no matching claim")
            continue
        fields = (
            "taskId",
            "taskRevision",
            "attempt",
            "changeId",
            "changeRevision",
            "platform",
            "baseRevision",
            "taskPacketSha256",
        )
        if run.get("taskId") != claim.get("taskId"):
            errors.append(f"run {_relative(root, path)} Task does not match its claim")
        if not (
            run.get("attempt") == claim.get("attempt")
            and run.get("taskRevision") == claim.get("taskRevision")
        ):
            errors.append(f"run {_relative(root, path)} attempt/revision does not match claim")
        if run.get("taskPacketSha256") != claim.get("taskPacketSha256"):
            errors.append(f"run {_relative(root, path)} packet hash mismatch")
        if not all(
            run.get(field) == claim.get(field)
            for field in ("changeId", "changeRevision", "baseRevision")
        ) or not (
            run.get("coreBaseline") == claim.get("coreBaseline")
            and run.get("coreBaselineSha256") == claim.get("coreBaselineSha256")
        ):
            errors.append(f"run {_relative(root, path)} Core/change/base mismatch")
        if not (
            run.get("platformProfileSha256")
            == support.dig(claim, "platformProfile", "sha256")
            and sorted(run.get("integrationProfileSha256s", []))
            == sorted(
                item.get("sha256") for item in claim.get("integrationProfiles", [])
            )
            and run.get("conformanceSuiteSha256")
            == support.dig(claim, "conformanceSuite", "sha256")
        ):
            errors.append(f"run {_relative(root, path)} profile/conformance mismatch")
        if run.get("platform") != claim.get("platform"):
            errors.append(f"run {_relative(root, path)} platform mismatch")
        task = tasks.get(str(run.get("taskId")))
        if not task:
            errors.append(f"run {_relative(root, path)} has no matching Task")
        elif run.get("executedBy") != claim.get("claimedBy"):
            errors.append(f"run {_relative(root, path)} executedBy differs from claim owner")
        started = _parse_time(run.get("startedAt"))
        ended = _parse_time(run.get("endedAt"))
        claimed = _parse_time(claim.get("claimedAt"))
        expires = _parse_time(claim.get("leaseExpiresAt"))
        if not all((started, claimed, expires)):
            errors.append(f"run {_relative(root, path)} has invalid start/claim timestamps")
        else:
            if not (claimed <= started < expires):
                errors.append(f"run {_relative(root, path)} started outside the claim lease")
            if ended:
                if ended < started:
                    errors.append(f"run {_relative(root, path)} ends before it starts")
                if ended > expires:
                    errors.append(f"run {_relative(root, path)} exceeds its immutable claim lease")
        owner_path = path.with_name("run-owner-attestation.json")
        owner = _load_json_relative(root, owner_path, errors) if owner_path.is_file() else None
        if not owner:
            errors.append(f"run {_relative(root, path)} has no protected owner attestation")
        else:
            _report_contract_fields(
                root,
                owner_path,
                owner,
                "run-owner-attestation.schema.json",
                "run owner attestation",
                errors,
            )
            run_owner_id = str(owner.get("attestationId"))
            if run_owner_id in sidecar_ids["run-owner"]:
                errors.append(f"duplicate run owner attestation ID {run_owner_id}")
            sidecar_ids["run-owner"].add(run_owner_id)
        if owner and (
            owner.get("runId") != run_id
            or owner.get("runSha256") != _sha(path)
            or owner.get("claimId") != run.get("claimId")
            or owner.get("executedBy") != run.get("executedBy")
            or owner.get("taskId") != run.get("taskId")
            or owner.get("attempt") != run.get("attempt")
            or owner.get("subjectType") != "taskRunLease"
        ):
            errors.append(f"run {run_id} owner attestation does not bind exact run/owner")
        elif owner:
            claim_owner_path = claim_paths.get(str(run.get("claimId")), path).with_name(
                "claim-owner-attestation.json"
            )
            claim_owner = (
                _load_json_relative(root, claim_owner_path, errors)
                if claim_owner_path.is_file()
                else {}
            )
            if not (
                owner.get("claimAttestationId") == claim_owner.get("attestationId")
                and owner.get("finalizedAt") == run.get("endedAt")
                and support.externally_verified(
                    owner_path, path, owner, verifiers, root=root
                )
            ):
                errors.append(
                    f"run {_relative(root, path)} owner attestation is not exact or externally verified"
                )
        records = run.get("workflowExecutionRecords", [])
        record_ids = [item.get("id") for item in records]
        if len(record_ids) != len(set(record_ids)):
            errors.append(
                f"run {_relative(root, path)} has duplicate workflow execution-record IDs"
            )
        real_records = [
            item
            for item in records
            if item.get("disposition") == "executed"
            and item.get("bindingRequirement") == "confirmedDevice"
            and item.get("effect") != "hostOnly"
        ]
        dispatch_count = run.get("realDeviceDispatchCount")
        if dispatch_count != len(real_records):
            errors.append(
                f"run {_relative(root, path)} realDeviceDispatchCount differs from typed execution records"
            )
        first_dispatch = _parse_time(run.get("firstRealDeviceDispatchAt"))
        last_dispatch = _parse_time(run.get("lastRealDeviceDispatchAt"))
        if dispatch_count == 0 and (
            run.get("firstRealDeviceDispatchAt") is not None
            or run.get("lastRealDeviceDispatchAt") is not None
        ):
            errors.append(
                f"zero-dispatch run {_relative(root, path)} has dispatch timestamps"
            )
        elif isinstance(dispatch_count, int) and dispatch_count > 0:
            real_capabilities = set((task or {}).get("runtimeCapabilities", [])) & {
                "realDeviceRead",
                "realDeviceMutation",
                DESTRUCTIVE_CAPABILITY,
            }
            if not real_capabilities:
                errors.append(
                    f"run {_relative(root, path)} records real-device dispatch without capability"
                )
            elif not (
                started
                and ended
                and first_dispatch
                and last_dispatch
                and started <= first_dispatch <= last_dispatch <= ended
            ):
                errors.append(
                    f"run {_relative(root, path)} real-device dispatch interval is outside the run"
                )
        if task:
            capabilities = set(task.get("runtimeCapabilities", []))
            for record in records:
                required = support.runtime_capability_for_step(record)
                if required and required not in capabilities:
                    errors.append(
                        f"run {_relative(root, path)} executes {record.get('id')} without {required} capability"
                    )
                if (
                    task.get("executionEnvironment") == "standardAgent"
                    and record.get("disposition") == "executed"
                    and record.get("effect") == "destructive"
                ):
                    errors.append(
                        f"standard Agent run {_relative(root, path)} executes forbidden destructive Step {record.get('id')}"
                    )
            if run.get("status") == "done" and any(
                item.get("disposition") == "executed"
                and (
                    item.get("semanticResult") != "succeeded"
                    or item.get("outcomeCertainty") != "confirmed"
                )
                for item in records
            ):
                errors.append(
                    f"done run {_relative(root, path)} contains an unsuccessful/uncertain executed workflow record"
                )
            lab = lab_authorizations.get(str(run.get("claimId")))
            plan = lab_plans.get(str(run.get("claimId")))
            if task.get("executionEnvironment") == "controlledHardwareLab":
                if dispatch_count and not (
                    lab
                    and run.get("labAuthorizationId") == lab.get("authorizationId")
                    and run.get("executionPlanSha256") == lab.get("planSha256")
                ):
                    errors.append(
                        f"run {_relative(root, path)} does not bind its approved lab plan/authorization"
                    )
                elif dispatch_count == 0 and run.get("labAuthorizationId") is not None and not (
                    lab and run.get("labAuthorizationId") == lab.get("authorizationId")
                ):
                    errors.append(
                        f"zero-dispatch lab run {_relative(root, path)} references an unknown authorization"
                    )
                elif dispatch_count == 0 and not lab and run.get("status") == "done":
                    errors.append(
                        f"unauthorized zero-dispatch lab run {_relative(root, path)} cannot be done"
                    )
                if lab and isinstance(dispatch_count, int) and dispatch_count > 0:
                    lab_from = _parse_time(lab.get("validFrom"))
                    lab_until = _parse_time(lab.get("validUntil"))
                    lab_approval = approvals.get(lab.get("approvalId"))
                    lab_approved = (
                        _parse_time(lab_approval.get("approvedAt"))
                        if lab_approval
                        else None
                    )
                    confirmed = _parse_time(
                        support.dig(
                            lab, "physicalTargetConfirmation", "confirmedAt"
                        )
                    )
                    if not (
                        lab_from
                        and lab_until
                        and lab_approved
                        and confirmed
                        and first_dispatch
                        and last_dispatch
                        and lab_approved <= first_dispatch
                        and confirmed <= first_dispatch
                        and first_dispatch >= lab_from
                        and last_dispatch < lab_until
                    ):
                        errors.append(
                            f"run {_relative(root, path)} real-device dispatch was not fully pre-authorized or exceeded the lab window"
                        )
                if lab and plan:
                    planned: dict[str, dict[str, Any]] = {}
                    for main in plan.get("steps", []):
                        planned[main.get("id")] = {
                            "step": main,
                            "sourceStepId": None,
                            "trigger": None,
                        }
                        for descriptor in main.get("compensationDescriptors", []):
                            planned[descriptor.get("id")] = {
                                "step": descriptor,
                                "sourceStepId": main.get("id"),
                                "trigger": descriptor.get("trigger"),
                            }
                    if sorted(record_ids) != sorted(planned):
                        errors.append(
                            f"lab run {_relative(root, path)} execution-record set differs from the approved plan"
                        )
                    main_ids = [item.get("id") for item in plan.get("steps", [])]
                    if [value for value in record_ids if value in main_ids] != main_ids:
                        errors.append(
                            f"lab run {_relative(root, path)} changes approved top-level Step order"
                        )
                    for record in records:
                        binding = planned.get(record.get("id"))
                        if not binding:
                            continue
                        step = binding["step"]
                        fields_to_compare = [
                            "id",
                            "kind",
                            "effect",
                            "cancellation",
                            "bindingRequirement",
                            "arguments",
                        ]
                        if "argumentsHash" in step:
                            fields_to_compare.append("argumentsHash")
                        if "compensationDescriptors" in step:
                            fields_to_compare.append("compensationDescriptors")
                        exact = (
                            record.get("sourceStepId") == binding["sourceStepId"]
                            and record.get("compensationTrigger") == binding["trigger"]
                            and all(record.get(field) == step.get(field) for field in fields_to_compare)
                        )
                        if not exact:
                            errors.append(
                                f"lab run {_relative(root, path)} execution record {record.get('id')} drifts from plan/source/trigger"
                            )
                    by_id = {item.get("id"): item for item in records}
                    for source_step in plan.get("steps", []):
                        source_id = source_step.get("id")
                        source_index = (
                            record_ids.index(source_id) if source_id in record_ids else None
                        )
                        source_record = by_id.get(source_id)
                        for descriptor in source_step.get(
                            "compensationDescriptors", []
                        ):
                            descriptor_id = descriptor.get("id")
                            descriptor_index = (
                                record_ids.index(descriptor_id)
                                if descriptor_id in record_ids
                                else None
                            )
                            descriptor_record = by_id.get(descriptor_id)
                            if (
                                descriptor_record
                                and descriptor_record.get("disposition") == "executed"
                                and (
                                    source_index is None
                                    or descriptor_index is None
                                    or descriptor_index <= source_index
                                )
                            ):
                                errors.append(
                                    f"lab run {_relative(root, path)} executes compensation {descriptor_id} before its source Step"
                                )
                            if not descriptor_record or descriptor_record.get(
                                "disposition"
                            ) != "executed":
                                continue
                            trigger = descriptor.get("trigger")
                            trigger_satisfied = {
                                "onSuccess": bool(
                                    source_record
                                    and source_record.get("disposition") == "executed"
                                    and source_record.get("semanticResult") == "succeeded"
                                    and source_record.get("outcomeCertainty") == "confirmed"
                                ),
                                "onFailure": bool(
                                    source_record
                                    and source_record.get("disposition") == "executed"
                                    and source_record.get("semanticResult") == "failed"
                                    and source_record.get("outcomeCertainty") == "confirmed"
                                ),
                                "onCancel": run.get("status") == "interrupted",
                                "onAnyTerminal": run.get("status") in TERMINAL_STATUSES,
                            }.get(trigger, False)
                            if not trigger_satisfied:
                                errors.append(
                                    f"lab run {_relative(root, path)} executes compensation {descriptor_id} without satisfying {trigger}"
                                )
                if "AC-FLASH-014-01" in task.get("acceptanceRefs", []):
                    flash_index = next(
                        (
                            index
                            for index, item in enumerate(real_records)
                            if item.get("kind") in ("flashPartition", "updatePackage")
                            and item.get("semanticResult") == "succeeded"
                        ),
                        None,
                    )
                    postflight = next(
                        (
                            index
                            for index, item in enumerate(real_records)
                            if item.get("kind") == "verifyRemoteState"
                            and item.get("semanticResult") == "succeeded"
                        ),
                        None,
                    )
                    if flash_index is None or postflight is None or postflight <= flash_index:
                        errors.append(
                            f"Flash hardware run {_relative(root, path)} lacks an actual successful flash/update followed by semantic postflight"
                        )
            elif run.get("labAuthorizationId") is not None:
                errors.append(f"standard run {_relative(root, path)} claims a lab authorization")

        evidence_ids = [item.get("evidenceId") for item in run.get("evidence", [])]
        if len(evidence_ids) != len(set(evidence_ids)):
            errors.append(f"run {_relative(root, path)} has duplicate evidence IDs")
        for item in run.get("evidence", []):
            if item.get("locationKind") == "repository":
                location = str(item.get("location", "")).removeprefix("repo:")
                evidence_path = _repo_path(root, location)
                if evidence_path is None:
                    errors.append(
                        f"run {_relative(root, path)} repository evidence escapes the repository: {item.get('location')}"
                    )
                elif not evidence_path.is_file():
                    errors.append(
                        f"run {_relative(root, path)} evidence file is missing: {item.get('location')}"
                    )
                elif _sha(evidence_path) != item.get("sha256"):
                    errors.append(
                        f"run {_relative(root, path)} evidence hash mismatch: {item.get('evidenceId')}"
                    )
            elif item.get("locationKind") == "controlledExternal":
                approval = approvals.get(item.get("verificationRef"))
                valid_evidence = bool(
                    approval
                    and approval.get("subjectType") == "evidence"
                    and approval.get("subjectId") == item.get("evidenceId")
                    and approval.get("subjectSha256") == item.get("sha256")
                    and approval.get("decision") == "approved"
                    and support.externally_verified(
                        approval_paths.get(str(approval.get("approvalId"))),
                        item.get("location"),
                        approval,
                        verifiers,
                        root=root,
                    )
                )
                if not valid_evidence:
                    errors.append(
                        f"run {_relative(root, path)} external evidence is not verified: {item.get('evidenceId')}"
                    )
        case_for_change = context.get("case_definition_for_change")
        for result_item in run.get("acceptanceResults", []):
            missing = set(result_item.get("evidenceIds", [])) - set(evidence_ids)
            if missing:
                errors.append(
                    f"run {_relative(root, path)} acceptance {result_item.get('acceptanceId')} has unresolved evidence"
                )
            task_verification = next(
                (
                    item
                    for item in (task or {}).get("verification", [])
                    if item.get("acceptanceId") == result_item.get("acceptanceId")
                ),
                None,
            )
            definition = (
                case_for_change(run.get("changeId"), result_item.get("acceptanceId"))
                if callable(case_for_change)
                else None
            )
            if task_verification is None:
                errors.append(
                    f"run {_relative(root, path)} reports acceptance outside the Task: {result_item.get('acceptanceId')}"
                )
            if not definition or not (
                result_item.get("testId") == definition.get("test_id")
                and result_item.get("method") == definition.get("method")
            ):
                errors.append(
                    f"run {_relative(root, path)} acceptance {result_item.get('acceptanceId')} Test ID/method drift"
                )
            if result_item.get("result") == "passed" and definition:
                linked = [
                    item
                    for item in run.get("evidence", [])
                    if item.get("evidenceId") in result_item.get("evidenceIds", [])
                ]
                minimum = definition.get("minimum_evidence")
                if not any(item.get("classification") == minimum for item in linked):
                    errors.append(
                        f"run {_relative(root, path)} acceptance {result_item.get('acceptanceId')} lacks exact {minimum} evidence"
                    )
                if minimum == "parserGolden":
                    fixture_refs = result_item.get("fixtureRefs", [])
                    if not fixture_refs:
                        errors.append(
                            f"run {_relative(root, path)} parser case has no pinned fixture"
                        )
                    fixture_ids = set(context.get("conformance_fixture_ids", []))
                    if set(fixture_refs) - fixture_ids:
                        errors.append(
                            f"run {_relative(root, path)} parser case references unknown fixture"
                        )
                    required_refs = set((task_verification or {}).get("fixtureRefs", []))
                    if required_refs - set(fixture_refs):
                        errors.append(
                            f"run {_relative(root, path)} parser case omits a Task-pinned fixture"
                        )
                elif minimum == "platform":
                    if not any(
                        item.get("classification") == "platform"
                        and item.get("platform") == run.get("platform")
                        for item in linked
                    ):
                        errors.append(
                            f"run {_relative(root, path)} platform evidence belongs to another platform"
                        )
                elif minimum == "realHardware":
                    references = result_item.get("hardwareMatrixRefs", [])
                    if not references:
                        errors.append(
                            f"run {_relative(root, path)} hardware case has no hardware evidence reference"
                        )
                    hardware_records: dict[str, dict[str, Any]] = {}
                    for hardware_path in (root / "openspec/verification/hardware-evidence").glob(
                        "*.json"
                    ):
                        hardware = _load_json_relative(root, hardware_path, []) or {}
                        hardware_records[str(hardware.get("evidenceId"))] = hardware
                    if any(reference not in hardware_records for reference in references):
                        errors.append(
                            f"run {_relative(root, path)} hardware case references evidence without immutable historical approval"
                        )
                    for reference in references:
                        hardware = hardware_records.get(reference)
                        if not hardware:
                            continue
                        if result_item.get("acceptanceId") not in hardware.get(
                            "acceptanceIds", []
                        ):
                            errors.append(
                                f"run {_relative(root, path)} hardware evidence does not cover {result_item.get('acceptanceId')}"
                            )
                        if hardware.get("platform") != run.get("platform"):
                            errors.append(
                                f"run {_relative(root, path)} hardware evidence belongs to another platform"
                            )
                        run_time = ended or started
                        observed = _parse_time(hardware.get("observedAt"))
                        valid_until = _parse_time(hardware.get("validUntil"))
                        if not run_time or not observed or not valid_until:
                            errors.append(
                                f"run {_relative(root, path)} hardware evidence has invalid timestamps"
                            )
                        elif not observed <= run_time <= valid_until:
                            errors.append(
                                f"run {_relative(root, path)} hardware evidence was outside its validity window"
                            )
                    if not any(
                        item.get("classification") == "realHardware"
                        and item.get("locationKind") == "controlledExternal"
                        and item.get("platform") == run.get("platform")
                        for item in linked
                    ):
                        errors.append(
                            f"run {_relative(root, path)} realHardware result lacks externally verified hardware evidence"
                        )
                elif minimum == "manualReview" and not any(
                    item.get("classification") == "manualReview"
                    and item.get("locationKind") == "controlledExternal"
                    for item in linked
                ):
                    errors.append(
                        f"run {_relative(root, path)} manualReview result lacks externally verified review evidence"
                    )
        result_revision = run.get("resultRevision")
        if not support.git_commit(run.get("baseRevision"), root=root) or not support.git_commit(
            result_revision, root=root
        ):
            errors.append(
                f"run {_relative(root, path)} base/result revision is not a real Git commit"
            )
        elif not support.git_ancestor(run.get("baseRevision"), result_revision, root=root):
            errors.append(
                f"run {_relative(root, path)} result revision is not descended from base"
            )
        else:
            diff = support.git_diff_paths(run.get("baseRevision"), result_revision, root=root)
            if diff is None or sorted(run.get("modifiedFiles", [])) != sorted(diff):
                errors.append(f"run {_relative(root, path)} modifiedFiles differs from Git diff")
            task = tasks.get(str(run.get("taskId")))
            if task:
                for modified in run.get("modifiedFiles", []):
                    allowed = any(support.ruby_path_fnmatch(pattern, modified) for pattern in task.get("allowedPaths", []))
                    forbidden = any(support.ruby_path_fnmatch(pattern, modified) for pattern in task.get("forbiddenPaths", []))
                    if not allowed or forbidden:
                        if not allowed:
                            errors.append(
                                f"run {_relative(root, path)} modified path outside Task scope: {modified}"
                            )
                        if forbidden:
                            errors.append(
                                f"run {_relative(root, path)} modified forbidden path: {modified}"
                            )
        if run.get("status") == "done":
            approval = approvals.get(run.get("approvalId"))
            approval_time = _parse_time(approval.get("approvedAt")) if approval else None
            valid = bool(
                approval
                and approval.get("subjectType") == "taskRun"
                and approval.get("subjectId") == run_id
                and approval.get("subjectRevision") == run.get("attempt")
                and approval.get("subjectSha256") == _sha(path)
                and approval.get("baseRevision") == run.get("baseRevision")
                and approval.get("decision") == "approved"
                and approval_time
                and ended
                and approval_time >= ended
                and support.externally_verified(
                    approval_paths.get(str(approval.get("approvalId"))),
                    path,
                    approval,
                    verifiers,
                    root=root,
                )
            )
            if not valid:
                errors.append(f"done run {_relative(root, path)} lacks externally verified result approval")
            results = run.get("acceptanceResults", [])
            if not task or sorted(item.get("acceptanceId") for item in results) != sorted(
                task.get("acceptanceRefs", [])
            ):
                errors.append(
                    f"done run {_relative(root, path)} does not cover the Task acceptance set"
                )
            if any(
                item.get("result") != "passed" or not item.get("evidenceIds")
                for item in results
            ):
                errors.append(
                    f"done run {_relative(root, path)} contains non-passing acceptance"
                )
            if not run.get("endedAt") or not run.get("resultRevision"):
                errors.append(f"done run {_relative(root, path)} has no end/result revision")
            if not run.get("commands") or not run.get("modifiedFiles") or not evidence_ids:
                errors.append(
                    f"done run {_relative(root, path)} has no commands/files/evidence"
                )
    for claim_id, values in runs_by_claim.items():
        if len(values) != 1:
            errors.append(f"claim {claim_id} has {len(values)} terminal runs; expected exactly one")
    missing_terminal = sorted(set(claims) - set(runs_by_claim))
    if missing_terminal:
        errors.append(f"claims without terminal runs: {', '.join(missing_terminal)}")
    replacement_authorizations: dict[str, dict[str, Any]] = {}
    for run_id, run in runs.items():
        if run.get("status") != "superseded":
            continue
        replacement_id = str(run.get("supersededByTaskId"))
        valid = support.valid_task_supersession(
            run=run,
            run_path=run_paths[run_id],
            original=tasks.get(str(run.get("taskId"))),
            replacement=tasks.get(replacement_id),
            replacement_path=task_paths.get(replacement_id),
            approvals=approvals,
            approval_paths=approval_paths,
            verifiers=verifiers,
            root=root,
        )
        if not valid:
            errors.append(
                f"superseded run {_relative(root, run_paths[run_id])} lacks an exact approved Ready replacement with preserved scope"
            )
            continue
        if replacement_id in replacement_authorizations:
            errors.append(
                f"replacement Task {replacement_id} is authorized by more than one superseded run"
            )
        approval = approvals.get(run.get("supersessionApprovalId"), {})
        replacement_authorizations[replacement_id] = {
            "runId": run_id,
            "approvalId": run.get("supersessionApprovalId"),
            "approvedAt": approval.get("approvedAt"),
        }
    for claim_id, claim in claims.items():
        authorization = replacement_authorizations.get(str(claim.get("taskId")))
        if authorization:
            claimed = _parse_time(claim.get("claimedAt"))
            approved = _parse_time(authorization.get("approvedAt"))
            exact = (
                claim.get("supersededRunId") == authorization.get("runId")
                and claim.get("taskSupersessionApprovalId")
                == authorization.get("approvalId")
            )
            if not exact or not claimed or not approved or approved >= claimed:
                errors.append(
                    f"replacement claim {claim_id} does not bind or strictly postdate its taskSupersession approval"
                )
        elif claim.get("supersededRunId") is not None or claim.get(
            "taskSupersessionApprovalId"
        ) is not None:
            errors.append(
                f"ordinary claim {claim_id} carries an unresolved taskSupersession authorization"
            )
    return claims, runs


def _validate_live_change_lifecycle(
    root: Path,
    context: dict[str, Any],
    records: dict[str, dict[str, Any]],
    tasks: dict[str, dict[str, Any]],
    task_paths: dict[str, Path],
    claims: dict[str, dict[str, Any]],
    runs: dict[str, dict[str, Any]],
    scopes: dict[str, dict[str, Any]],
    approvals: dict[str, dict[str, Any]],
    approval_paths: dict[str, Path],
    verifiers: list[dict[str, Any]],
    errors: list[str],
) -> None:
    case_for_change = context.get("case_definition_for_change")
    for change_id, record in records.items():
        if record.get("archived"):
            continue
        change_root: Path = record["root"]
        proposal = record["proposal"]
        expected_id = change_root.name.replace("chg-", "CHG-", 1)
        if str(change_id).lower() != expected_id.lower():
            errors.append(f"change {_relative(root, change_root)} proposal identity mismatch")
        if proposal.get("revision") != 1:
            errors.append(f"change {change_id} V1 revision must remain 1")
        predecessor = proposal.get("supersedes_change_id")
        barrier = proposal.get("supersession_barrier_attestation_id")
        valid_predecessor = predecessor is None or bool(
            re.fullmatch(r"CHG-[0-9]{4}-[0-9]{3}(?:-[A-Za-z0-9-]+)?", str(predecessor))
            and predecessor != change_id
        )
        if not valid_predecessor:
            errors.append(f"change {change_id} has an invalid supersedes_change_id")
        valid_barrier = barrier is None if predecessor is None else bool(
            re.fullmatch(r"CHGSUPAUTH-[A-Z0-9._-]+", str(barrier))
        )
        if not valid_barrier:
            errors.append(f"change {change_id} has an invalid supersession barrier preallocation")
        if proposal.get("status") != "proposed":
            errors.append(f"change {change_id} proposal source status must remain proposed")
        for artifact in support.required_change_artifact_paths(change_root, proposal):
            if not artifact.is_file():
                errors.append(
                    f"change {change_id} is missing required artifact {artifact.name}"
                )
        deltas = list((change_root / "specs").glob("**/*.md"))
        if proposal.get("schema") == "arkdeck-behavior":
            if not deltas:
                errors.append(f"behavior change {change_id} has no delta spec")
            if (change_root / "spec-impact.md").is_file():
                errors.append(f"behavior change {change_id} must not carry spec-impact.md")
        elif proposal.get("schema") == "arkdeck-platform":
            if deltas:
                errors.append(f"platform change {change_id} must not carry behavior delta specs")
        else:
            errors.append(f"change {change_id} has an unknown schema")

        lock_path = change_root / "change-lock.yaml"
        lock: dict[str, Any] = {}
        if lock_path.is_file():
            lock = support.yaml_safe_load(lock_path.read_text(encoding="utf-8")) or {}
            entries = lock.get("files", [])
            lock_paths = [item.get("path") for item in entries]
            if not (
                lock.get("change_id") == change_id
                and lock.get("revision") == proposal.get("revision")
                and lock.get("hash_algorithm") == "sha256"
            ):
                errors.append(f"change {change_id} lock identity/revision/hash algorithm mismatch")
            if sorted(lock_paths) != support.expected_change_input_paths(change_root, root=root):
                errors.append(f"change {change_id} lock is not the exact input set")
            if len(lock_paths) != len(set(lock_paths)):
                errors.append(f"change {change_id} lock has duplicate paths")
            if lock.get("status") == "review":
                if lock.get("approval_id") is not None:
                    errors.append(f"review change {change_id} lock must be non-authorizing")
                for item in entries:
                    locked_path = _repo_path(root, item.get("path"))
                    if item.get("sha256") != "pending" and not (
                        locked_path
                        and locked_path.is_file()
                        and _sha(locked_path) == item.get("sha256")
                    ):
                        errors.append(
                            f"review change {change_id} lock has an invalid draft hash: {item.get('path')}"
                        )
            elif lock.get("status") == "approved":
                review_text = (
                    (change_root / "review.md").read_text(encoding="utf-8")
                    if (change_root / "review.md").is_file()
                    else ""
                )
                ready_text = (
                    (change_root / "ready-review.md").read_text(encoding="utf-8")
                    if (change_root / "ready-review.md").is_file()
                    else ""
                )
                if not (
                    re.search(r"^> Status：passed\s*$", review_text, re.MULTILINE)
                    and re.search(
                        r"^> Status：passed\s*$", ready_text, re.MULTILINE
                    )
                ):
                    errors.append(
                        f"approved change {change_id} requires passed review and ready-review gates"
                    )
                for item in entries:
                    locked_path = _repo_path(root, item.get("path"))
                    if not locked_path or not locked_path.is_file() or _sha(locked_path) != item.get("sha256"):
                        errors.append(f"approved change {change_id} input drift: {item.get('path')}")
                approval = approvals.get(lock.get("approval_id"))
                valid = bool(
                    approval
                    and approval.get("subjectType") == "change"
                    and approval.get("subjectId") == change_id
                    and approval.get("subjectRevision") == proposal.get("revision")
                    and approval.get("subjectSha256") == _sha(lock_path)
                    and approval.get("decision") == "approved"
                    and support.git_commit(approval.get("baseRevision"), root=root)
                    and support.externally_verified(
                        approval_paths.get(str(approval.get("approvalId"))),
                        lock_path,
                        approval,
                        verifiers,
                        root=root,
                    )
                )
                if not valid:
                    errors.append(f"approved change {change_id} has no externally verified change approval")
            else:
                errors.append(f"change {change_id} lock has an unsupported status")

        verification_result_path = change_root / "verification-result.json"
        if not verification_result_path.is_file():
            continue
        result = _load_json_relative(root, verification_result_path, errors) or {}
        verification_path = change_root / "verification.md"
        change_tasks = {task_id: task for task_id, task in tasks.items() if task.get("changeId") == change_id}
        superseded_tasks = {
            run.get("taskId")
            for run in runs.values()
            if run.get("changeId") == change_id and run.get("status") == "superseded"
        }
        active = sorted(set(change_tasks) - superseded_tasks)
        if not active:
            errors.append(f"verified change {change_id} has no active Task packets")
        valid_done: dict[str, dict[str, Any]] = {}
        run_paths = {
            str(document.get("runId")): path
            for path in _run_paths(root)
            if (document := _load_json_relative(root, path, []))
        }
        for run_id, run in runs.items():
            path = run_paths.get(run_id)
            approval = approvals.get(run.get("approvalId"))
            if (
                path
                and run.get("status") == "done"
                and approval
                and approval.get("subjectSha256") == _sha(path)
                and approval.get("decision") == "approved"
            ):
                valid_done[run_id] = run
        done_task_ids = {run.get("taskId") for run in valid_done.values()}
        if set(active) - done_task_ids:
            errors.append(f"verified change {change_id} has unfinished Task packets")
        scope = scopes.get(change_id, {})
        active_requirements = sorted(
            {value for task_id in active for value in change_tasks[task_id].get("requirementRefs", [])}
        )
        active_acceptance = sorted(
            {value for task_id in active for value in change_tasks[task_id].get("acceptanceRefs", [])}
        )
        if active_requirements != sorted(scope.get("requirements", [])):
            errors.append(
                f"verified change {change_id} active Task Requirement union differs from immutable scope"
            )
        if active_acceptance != sorted(scope.get("acceptance", [])):
            errors.append(
                f"verified change {change_id} active Task Acceptance union differs from immutable scope"
            )
        task_runs = result.get("taskRuns", [])
        task_run_ids = [item.get("taskId") for item in task_runs]
        if sorted(task_run_ids) != active or len(task_run_ids) != len(set(task_run_ids)):
            errors.append(f"verified change {change_id} result does not exactly cover active Tasks")
        bound_runs: dict[str, dict[str, Any]] = {}
        for item in task_runs:
            run = valid_done.get(str(item.get("runId")))
            run_path = run_paths.get(str(item.get("runId")))
            exact = bool(
                run
                and run_path
                and run.get("taskId") == item.get("taskId")
                and run.get("changeId") == change_id
                and item.get("runSha256") == _sha(run_path)
                and item.get("resultRevision") == run.get("resultRevision")
                and support.git_ancestor(
                    run.get("resultRevision"), result.get("resultRevision"), root=root
                )
            )
            if not exact:
                errors.append(
                    f"verified change {change_id} result has an invalid Task run binding for {item.get('taskId')}"
                )
            else:
                bound_runs[str(item.get("runId"))] = run
        change_approval = approvals.get(lock.get("approval_id"))
        aggregate_base = change_approval.get("baseRevision") if change_approval else None
        aggregate_base_exact = bool(aggregate_base) and all(
            change_tasks[task_id].get("baseRevision") == aggregate_base for task_id in active
        )
        if not aggregate_base_exact:
            errors.append(
                f"verified change {change_id} active Tasks do not share the exact change-approval base"
            )
        provenance: dict[str, str] = {}
        for candidate in [change_root / "tasks.md", change_root / "evidence/summary.md"]:
            if candidate.is_file():
                provenance[_relative(root, candidate)] = _sha(candidate)
        for task_id, task_path in task_paths.items():
            if change_tasks.get(task_id):
                provenance[_relative(root, task_path)] = _sha(task_path)
        barrier_record = records.get(change_id, {}).get("barrier")
        barrier_path = (
            Path(barrier_record.get("path")) if barrier_record else None
        )
        if barrier_path and barrier_path.is_file():
            provenance[_relative(root, barrier_path)] = _sha(barrier_path)
        claim_file_by_id = {
            str(document.get("claimId")): claim_path
            for claim_path in _claim_paths(root)
            if (document := _load_json_relative(root, claim_path, []))
        }
        approval_ids: set[str] = {
            str(value)
            for value in (
                lock.get("approval_id"),
                support.dig(context.get("trust_policy"), "ratification", "approval_ref"),
                support.dig(context.get("baseline"), "ratification", "approval_ref"),
                support.dig(
                    context.get("integration_lock"), "ratification", "approval_ref"
                ),
                support.dig(
                    context.get("platform_lock"), "ratification", "approval_ref"
                ),
                support.dig(
                    context.get("conformance"), "ratification", "approval_ref"
                ),
            )
            if value
        }
        for claim_id, claim in claims.items():
            if claim.get("changeId") != change_id:
                continue
            claim_path = claim_file_by_id.get(claim_id)
            if claim_path:
                provenance[_relative(root, claim_path)] = _sha(claim_path)
                for sidecar_name in (
                    "claim-owner-attestation.json",
                    "resource-identity-attestation.json",
                    "lab-execution-plan.json",
                    "lab-execution-authorization.json",
                ):
                    sidecar = claim_path.with_name(sidecar_name)
                    if sidecar.is_file():
                        provenance[_relative(root, sidecar)] = _sha(sidecar)
                        if sidecar_name == "lab-execution-authorization.json":
                            lab_doc = _load_json_relative(root, sidecar, []) or {}
                            if lab_doc.get("approvalId"):
                                approval_ids.add(str(lab_doc["approvalId"]))
            if claim.get("approvalId"):
                approval_ids.add(str(claim["approvalId"]))
        for run_id, run in runs.items():
            if run.get("changeId") != change_id:
                continue
            run_path = run_paths.get(run_id)
            if run_path:
                provenance[_relative(root, run_path)] = _sha(run_path)
                owner_path = run_path.with_name("run-owner-attestation.json")
                if owner_path.is_file():
                    provenance[_relative(root, owner_path)] = _sha(owner_path)
            for approval_id in (
                run.get("approvalId"),
                run.get("supersessionApprovalId"),
            ):
                if approval_id:
                    approval_ids.add(str(approval_id))
            for evidence in run.get("evidence", []):
                if evidence.get("verificationRef"):
                    approval_ids.add(str(evidence["verificationRef"]))
            for hardware_id in {
                hardware_id
                for result_item in run.get("acceptanceResults", [])
                for hardware_id in result_item.get("hardwareMatrixRefs", [])
            }:
                hardware_path = (
                    root
                    / "openspec/verification/hardware-evidence"
                    / f"{hardware_id}.json"
                )
                if hardware_path.is_file():
                    provenance[_relative(root, hardware_path)] = _sha(hardware_path)
                    hardware_doc = _load_json_relative(root, hardware_path, []) or {}
                    if hardware_doc.get("approvalId"):
                        approval_ids.add(str(hardware_doc["approvalId"]))
        for packet in change_tasks.values():
            if packet.get("approvalId"):
                approval_ids.add(str(packet["approvalId"]))
        for approval_id in approval_ids:
            approval_path = approval_paths.get(approval_id)
            if approval_path and approval_path.is_file():
                provenance[_relative(root, approval_path)] = _sha(approval_path)
        aggregate_valid = aggregate_base_exact and support.validate_task_result_aggregate(
            errors=errors,
            subject=f"verified change {change_id}",
            base_revision=aggregate_base,
            result_revision=result.get("resultRevision"),
            runs=list(bound_runs.values()),
            provenance_files=provenance,
            root=root,
        )
        result_acceptance = result.get("acceptanceResults", [])
        result_ids = [item.get("acceptanceId") for item in result_acceptance]
        if sorted(result_ids) != active_acceptance or len(result_ids) != len(set(result_ids)):
            errors.append(f"verified change {change_id} result does not exactly cover active Task ACs")
        for item in result_acceptance:
            run = bound_runs.get(str(item.get("runId")))
            run_result = next(
                (
                    value
                    for value in (run or {}).get("acceptanceResults", [])
                    if value.get("acceptanceId") == item.get("acceptanceId")
                ),
                None,
            )
            definition = (
                case_for_change(change_id, item.get("acceptanceId"))
                if callable(case_for_change)
                else None
            )
            if not (
                run_result
                and run_result.get("result") == "passed"
                and item.get("result") == "passed"
                and definition
                and item.get("testId") == definition.get("test_id")
                and run_result.get("testId") == item.get("testId")
            ):
                errors.append(
                    f"verified change {change_id} result has an invalid AC/run binding for {item.get('acceptanceId')}"
                )
        approval = approvals.get(result.get("approvalId"))
        latest_completion = max(
            (
                ended
                for run in bound_runs.values()
                if (ended := _parse_time(run.get("endedAt")))
            ),
            default=None,
        )
        verified_at = _parse_time(result.get("verifiedAt"))
        verification_approved_at = (
            _parse_time(approval.get("approvedAt")) if approval else None
        )
        valid_times = bool(
            latest_completion
            and verified_at
            and verification_approved_at
            and verified_at >= latest_completion
            and verification_approved_at >= verified_at
        )
        approved_successors = [
            successor
            for successor in records.values()
            if successor.get("approved")
            and support.dig(successor, "proposal", "supersedes_change_id")
            == change_id
            and successor.get("approved_at")
        ]
        effective_successor = (
            min(approved_successors, key=lambda item: item["approved_at"])
            if approved_successors
            else None
        )
        if (
            effective_successor
            and verification_approved_at
            and verification_approved_at >= effective_successor["approved_at"]
        ):
            errors.append(
                f"superseded Change {change_id} was verified after successor {support.dig(effective_successor, 'proposal', 'id')} became effective"
            )
            valid_times = False
        valid = bool(
            lock_path.is_file()
            and verification_path.is_file()
            and result.get("changeId") == change_id
            and result.get("changeRevision") == proposal.get("revision")
            and result.get("status") == "passed"
            and result.get("changeLockSha256") == _sha(lock_path)
            and result.get("verificationPlanSha256") == _sha(verification_path)
            and support.git_commit(result.get("resultRevision"), root=root)
            and support.git_ancestor(
                result.get("resultRevision"), support.git_head_revision(root), root=root
            )
            and aggregate_valid
            and valid_times
            and approval
            and approval.get("subjectType") == "changeVerification"
            and approval.get("subjectId") == result.get("verificationId")
            and approval.get("subjectRevision") == proposal.get("revision")
            and approval.get("subjectSha256") == _sha(verification_result_path)
            and approval.get("baseRevision") == result.get("resultRevision")
            and approval.get("decision") == "approved"
            and support.externally_verified(
                approval_paths.get(str(approval.get("approvalId"))),
                verification_result_path,
                approval,
                verifiers,
                root=root,
            )
        )
        if not valid:
            errors.append(
                f"verified change {change_id} lacks an exact externally verified immutable verification result"
            )


def _validate_claim_schedule(
    tasks: dict[str, dict[str, Any]],
    claims: dict[str, dict[str, Any]],
    runs: dict[str, dict[str, Any]],
    records: dict[str, dict[str, Any]],
    errors: list[str],
) -> None:
    runs_by_claim = {str(run.get("claimId")): run for run in runs.values()}
    terminal_at = {
        claim_id: _parse_time(run.get("endedAt"))
        for claim_id, run in runs_by_claim.items()
        if run.get("status") in TERMINAL_STATUSES
    }
    intervals: list[tuple[str, str, support.Rfc3339Instant, support.Rfc3339Instant, set[str]]] = []
    for claim_id, claim in claims.items():
        start = _parse_time(claim.get("claimedAt"))
        expires = _parse_time(claim.get("leaseExpiresAt"))
        if start and expires:
            intervals.append(
                (
                    claim_id,
                    str(claim.get("taskId")),
                    start,
                    terminal_at.get(claim_id) or expires,
                    set(claim.get("exclusiveResources", [])),
                )
            )
    for index, left in enumerate(intervals):
        for right in intervals[index + 1 :]:
            if left[1] != right[1] and not (left[4] & right[4]):
                continue
            if left[2] < right[3] and right[2] < left[3]:
                errors.append(
                    f"overlapping active claims {left[0]} and {right[0]} target the same Task or resource"
                )
    by_task: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for claim in claims.values():
        by_task[str(claim.get("taskId"))].append(claim)
    for task_id, values in by_task.items():
        ordered = sorted(values, key=lambda item: int(item.get("attempt", 0)))
        if ordered and ordered[0].get("attempt") != 1:
            errors.append(f"Task {task_id} first claim attempt is not 1")
        for previous, following in zip(ordered, ordered[1:]):
            if following.get("attempt") != previous.get("attempt", 0) + 1:
                errors.append(f"Task {task_id} attempts are not consecutive")
            prior_run = runs_by_claim.get(str(previous.get("claimId")))
            if prior_run and prior_run.get("status") == "superseded":
                errors.append(f"claim {following.get('claimId')} follows a superseded Task")
            next_start = _parse_time(following.get("claimedAt"))
            prior_end = terminal_at.get(str(previous.get("claimId")))
            if not prior_end or not next_start or prior_end > next_start:
                errors.append(
                    f"claim {following.get('claimId')} starts before the prior attempt has a terminal run"
                )
    done_times: dict[str, support.Rfc3339Instant] = {}
    for run in runs.values():
        if run.get("status") == "done" and (ended := _parse_time(run.get("endedAt"))):
            task_id = str(run.get("taskId"))
            if task_id not in done_times or ended > done_times[task_id]:
                done_times[task_id] = ended
    for claim in claims.values():
        claimed = _parse_time(claim.get("claimedAt"))
        task = tasks.get(str(claim.get("taskId")))
        if not claimed or not task:
            continue
        for dependency in task.get("dependsOn", []):
            if dependency not in done_times or done_times[dependency] > claimed:
                errors.append(
                    f"claim {claim.get('claimId')} dependency {dependency} was not done before claim"
                )

    approved_successors: dict[str, dict[str, Any]] = {}
    for change_id, record in records.items():
        predecessor = support.dig(record, "proposal", "supersedes_change_id")
        if predecessor and record.get("approved") and record.get("approved_at"):
            current = approved_successors.get(predecessor)
            if current is None or record["approved_at"] < current["approved_at"]:
                approved_successors[predecessor] = record | {"change_id": change_id}
    for predecessor, successor in approved_successors.items():
        for claim in claims.values():
            if claim.get("changeId") != predecessor:
                continue
            claimed = _parse_time(claim.get("claimedAt"))
            terminal = terminal_at.get(str(claim.get("claimId")))
            approved_at = successor.get("approved_at")
            if claimed and approved_at and claimed >= approved_at:
                errors.append(
                    f"claim {claim.get('claimId')} was issued after Change {predecessor} was superseded by {successor.get('change_id')}"
                )
            elif claimed and approved_at and (not terminal or terminal >= approved_at):
                errors.append(
                    f"successor Change {successor.get('change_id')} was approved before predecessor claim {claim.get('claimId')} had an owner-attested terminal run"
                )


def _validate_hardware_evidence(
    root: Path,
    context: dict[str, Any],
    tasks: dict[str, dict[str, Any]],
    runs: dict[str, dict[str, Any]],
    approvals: dict[str, dict[str, Any]],
    approval_paths: dict[str, Path],
    verifiers: list[dict[str, Any]],
    schemas: dict[str, tuple[Path, Any]],
    errors: list[str],
) -> tuple[dict[str, dict[str, Any]], dict[str, dict[str, Any]]]:
    seen: set[str] = set()
    approved_hardware: dict[str, dict[str, Any]] = {}
    verified_hardware: dict[str, dict[str, Any]] = {}
    evaluation_time = None
    evaluation_text = os.environ.get("ARKDECK_EVALUATION_TIME", "")
    if evaluation_text:
        evaluation_time = _parse_time(evaluation_text)
        if evaluation_time is None:
            errors.append("ARKDECK_EVALUATION_TIME is not a valid RFC 3339 timestamp")
    platform_cases = {
        item.get("id"): item
        for values in context.get("platform_case_definitions", {}).values()
        for item in values
    }
    core_cases = context.get("case_definitions", {})
    case_for_change = context.get("case_definition_for_change")
    for path in sorted((root / "openspec/verification/hardware-evidence").glob("*.json")):
        record = _load_json_relative(root, path, errors)
        if not record:
            continue
        _validate_instance(root, path, record, "hardware-evidence.schema.json", schemas, errors)
        evidence_id = str(record.get("evidenceId"))
        if path.stem != evidence_id:
            errors.append(f"hardware evidence filename/id mismatch: {_relative(root, path)}")
        if evidence_id in seen:
            errors.append(f"duplicate hardware evidence ID {evidence_id}")
        seen.add(evidence_id)
        run = runs.get(str(record.get("taskRunId")))
        task = tasks.get(str(run.get("taskId"))) if run else None
        if not run or run.get("status") != "done":
            errors.append(f"hardware evidence {evidence_id} lacks its exact approved done run")
            continue
        if not task or task.get("executionEnvironment") != "controlledHardwareLab":
            errors.append(f"hardware evidence {evidence_id} does not come from controlledHardwareLab")
        passed = sorted(
            item.get("acceptanceId")
            for item in run.get("acceptanceResults", [])
            if item.get("result") == "passed"
            and evidence_id in item.get("hardwareMatrixRefs", [])
        )
        if sorted(record.get("acceptanceIds", [])) != passed:
            errors.append(f"hardware evidence {evidence_id} AC set differs from its exact run")
        if record.get("implementationRevision") != run.get("resultRevision"):
            errors.append(f"hardware evidence {evidence_id} drifts from run Core/implementation")
        approval = approvals.get(record.get("approvalId"))
        if not (
            approval
            and approval.get("subjectType") == "hardwareEvidence"
            and approval.get("subjectId") == evidence_id
            and approval.get("subjectRevision") == 1
            and approval.get("subjectSha256") == _sha(path)
            and approval.get("baseRevision") == record.get("implementationRevision")
            and approval.get("decision") == "approved"
        ):
            errors.append(f"hardware evidence {evidence_id} lacks matching approval")
        approval_valid = bool(
            record.get("status") == "verified"
            and
            approval
            and approval.get("subjectType") == "hardwareEvidence"
            and approval.get("subjectId") == evidence_id
            and approval.get("subjectRevision") == 1
            and approval.get("subjectSha256") == _sha(path)
            and approval.get("baseRevision") == record.get("implementationRevision")
            and approval.get("decision") == "approved"
            and support.externally_verified(
                approval_paths.get(str(approval.get("approvalId"))),
                path,
                approval,
                verifiers,
                root=root,
            )
        )
        observed = _parse_time(record.get("observedAt"))
        valid_until = _parse_time(record.get("validUntil"))
        approved_at = _parse_time(approval.get("approvedAt")) if approval else None
        historical_window_valid = bool(
            observed
            and valid_until
            and approved_at
            and observed <= approved_at <= valid_until
            and observed < valid_until
        )
        if record.get("status") == "verified" and not (
            approval_valid and historical_window_valid
        ):
            errors.append(
                f"verified hardware evidence is not immutably approved or has an invalid observation/approval window: {evidence_id}"
            )
        bindings = record.get("acceptanceCaseBindings", [])
        if sorted(item.get("acceptanceId") for item in bindings) != sorted(record.get("acceptanceIds", [])):
            errors.append(f"hardware evidence {evidence_id} case bindings do not exactly cover acceptanceIds")
        for binding in bindings:
            case_id = binding.get("acceptanceId")
            definition = (
                case_for_change(run.get("changeId"), case_id)
                if callable(case_for_change)
                else core_cases.get(case_id) or platform_cases.get(case_id)
            )
            if not definition or not (
                binding.get("testId") == definition.get("test_id")
                and binding.get("method") == definition.get("method")
                and binding.get("minimumEvidence")
                == definition.get("minimum_evidence")
                and binding.get("hardwareCapability")
                == definition.get("hardware_capability")
                and binding.get("definitionSha256")
                == support.acceptance_case_contract_sha256(case_id, definition)
            ):
                errors.append(f"hardware evidence {evidence_id} has stale case binding {case_id}")
        claim_path = next(
            (
                candidate
                for candidate in _claim_paths(root)
                if (_load_json_relative(root, candidate, []) or {}).get("claimId")
                == run.get("claimId")
            ),
            None,
        )
        lab = (
            _load_json_relative(root, claim_path.with_name("lab-execution-authorization.json"), errors)
            if claim_path and claim_path.with_name("lab-execution-authorization.json").is_file()
            else None
        )
        plan = (
            _load_json_relative(root, claim_path.with_name("lab-execution-plan.json"), errors)
            if claim_path and claim_path.with_name("lab-execution-plan.json").is_file()
            else None
        )
        plan_path = (
            claim_path.with_name("lab-execution-plan.json")
            if claim_path
            else None
        )
        target = (plan or {}).get("target", {})
        real_records = [
            item
            for item in run.get("workflowExecutionRecords", [])
            if item.get("disposition") == "executed"
            and item.get("bindingRequirement") == "confirmedDevice"
            and item.get("effect") != "hostOnly"
        ]
        run_evidence = next(
            (
                item
                for item in run.get("evidence", [])
                if item.get("evidenceId") == record.get("runEvidenceId")
            ),
            None,
        )
        platform_context = support.platform_context_for_task(
            run.get("resultRevision"), task, root=root
        )
        capabilities = sorted(
            {
                definition.get("hardware_capability")
                for case_id in record.get("acceptanceIds", [])
                if (
                    definition := (
                        case_for_change(run.get("changeId"), case_id)
                        if callable(case_for_change)
                        else core_cases.get(case_id)
                        or platform_cases.get(case_id)
                    )
                )
                and definition.get("hardware_capability")
            }
        )
        started_at = _parse_time(run.get("startedAt"))
        ended_at = _parse_time(run.get("endedAt"))
        exact_acceptance_evidence = all(
            result_item.get("result") == "passed"
            and record.get("runEvidenceId")
            in result_item.get("evidenceIds", [])
            and evidence_id in result_item.get("hardwareMatrixRefs", [])
            for result_item in run.get("acceptanceResults", [])
            if result_item.get("acceptanceId")
            in record.get("acceptanceIds", [])
        )
        provenance_valid = bool(
            lab
            and plan
            and plan_path
            and plan_path.is_file()
            and _sha(plan_path) == lab.get("planSha256")
            and record.get("executionAuthority") == "controlledHardwareLab"
            and record.get("labAuthorizationId") == lab.get("authorizationId")
            and record.get("executionPlanSha256") == lab.get("planSha256")
            and record.get("implementationRevision") == run.get("resultRevision")
            and record.get("platform") == run.get("platform")
            and record.get("transport") == target.get("transport")
            and support.dig(record, "device", "identity") == target.get("deviceIdentity")
            and support.dig(record, "device", "bindingRevision")
            == target.get("bindingRevision")
            and support.dig(record, "device", "build") == target.get("firmware")
            and support.dig(record, "toolchain", "hdcSha256")
            == target.get("hdcExecutableSha256")
            and support.dig(record, "toolchain", "clientVersion")
            == target.get("hdcClientVersion")
            and support.dig(record, "toolchain", "serverVersion")
            == target.get("hdcServerVersion")
            and support.dig(record, "toolchain", "daemonVersion")
            == target.get("hdcDaemonVersion")
            and support.dig(record, "toolchain", "serverEndpoint")
            == target.get("hdcServerEndpoint")
            and support.dig(record, "toolchain", "serverGeneration")
            == target.get("hdcServerGeneration")
            and support.dig(record, "provider", "id") == target.get("providerId")
            and support.dig(record, "provider", "version") == target.get("providerVersion")
            and sorted(record.get("stepKinds", []))
            == sorted(set(item.get("kind") for item in real_records))
            and sorted(set(record.get("capabilities", []))) == capabilities
            and run.get("realDeviceDispatchCount", 0) > 0
            and len(real_records) == run.get("realDeviceDispatchCount")
            and observed
            and started_at
            and ended_at
            and started_at <= observed <= ended_at
            and run_evidence
            and run_evidence.get("classification") == "realHardware"
            and run_evidence.get("locationKind") == "controlledExternal"
            and run_evidence.get("sha256") == support.dig(record, "artifact", "sha256")
            and run_evidence.get("location") == support.dig(record, "artifact", "location")
            and platform_context
            and record.get("platformCaseManifestSha256")
            == support.dig(platform_context, "entry", "case_manifest_sha256")
            and record.get("hostSupportCellId")
            in [
                cell.get("id")
                for cell in support.dig(
                    platform_context, "caseDocument", "support_cells"
                )
                or []
            ]
            and exact_acceptance_evidence
        )
        if not provenance_valid:
            errors.append(
                f"verified hardware evidence {evidence_id} is not bound to its approved lab run/plan/target"
            )
        if approval_valid and historical_window_valid and provenance_valid:
            approved_hardware[evidence_id] = record
        if (
            evidence_id in approved_hardware
            and evaluation_time
            and observed
            and valid_until
            and observed <= evaluation_time <= valid_until
        ):
            verified_hardware[evidence_id] = record
    return approved_hardware, verified_hardware


def _validate_archives(
    root: Path,
    schemas: dict[str, tuple[Path, Any]],
    change_records: dict[str, dict[str, Any]],
    approvals: dict[str, dict[str, Any]],
    approval_paths: dict[str, Path],
    verifiers: list[dict[str, Any]],
    errors: list[str],
) -> None:
    for path in sorted((root / "openspec/changes/archive").glob("*/archive-lock.yaml")):
        archive_root = path.parent
        archive_relative = _relative(root, archive_root)
        if re.fullmatch(
            r"[0-9]{4}-[0-9]{2}-[0-9]{2}-chg-[0-9]{4}-[0-9]{3}(?:-[a-z0-9-]+)?",
            archive_root.name,
        ) is None:
            errors.append(f"invalid archive directory name: {archive_relative}")
        proposal_path = archive_root / "proposal.md"
        scope_path = archive_root / "scope.yaml"
        verification_path = archive_root / "verification.md"
        result_path = archive_root / "verification-result.json"
        if not all(item.is_file() for item in (proposal_path, scope_path, verification_path, result_path)):
            errors.append(
                f"archive {archive_relative} lacks proposal/scope, immutable verification plan/result or archive lock"
            )
            continue
        try:
            lock = support.yaml_safe_load(path.read_text(encoding="utf-8")) or {}
        except (OSError, ValueError):
            continue
        proposal = _proposal_frontmatter(proposal_path)
        change_id = str(proposal.get("id"))
        result_record = _load_json_relative(root, result_path, errors) or {}
        if proposal.get("status") != "proposed":
            errors.append(f"archive {archive_relative} proposal source status was mutated")
        if proposal.get("revision") != 1:
            errors.append(f"archive {archive_relative} has an unsupported in-place Change revision")
        archive_predecessor = proposal.get("supersedes_change_id")
        archive_barrier = proposal.get("supersession_barrier_attestation_id")
        if not (
            (archive_predecessor is None and archive_barrier is None)
            or (
                archive_predecessor is not None
                and re.fullmatch(
                    r"CHGSUPAUTH-[A-Z0-9._-]+", str(archive_barrier)
                )
            )
        ):
            errors.append(
                f"archive {archive_relative} has an invalid supersession barrier preallocation"
            )
        regular_files = sorted(
            _relative(root, item)
            for item in archive_root.glob("**/*")
            if item.is_file() and item != path
        )
        entries = lock.get("files", [])
        entry_paths = [entry.get("path") for entry in entries]
        if sorted(entry_paths) != regular_files:
            errors.append(f"archive {archive_relative} lock file set is not exact")
        if len(entry_paths) != len(set(entry_paths)):
            errors.append(f"archive {archive_relative} lock has duplicate paths")
        for entry in entries:
            entry_path = _repo_path(root, entry.get("path"))
            if not entry_path or not entry_path.is_file() or _sha(entry_path) != entry.get("sha256"):
                errors.append(f"archive {archive_relative} file drift: {entry.get('path')}")
        base = lock.get("base_revision")
        verification = lock.get("verification_revision")
        source = lock.get("source_tree_revision")
        result = lock.get("result_revision")
        if not all(_canonical_commit(value) and support.git_commit(value, root=root) for value in (base, verification, source, result)):
            errors.append(f"archive {change_id} has non-canonical/missing B/R/S/T revision")
            continue
        if not (
            support.git_ancestor(base, verification, root=root)
            and support.git_ancestor(verification, source, root=root)
            and support.git_ancestor(source, result, root=root)
        ):
            errors.append(f"archive {change_id} B/R/S/T revisions are not an exact ancestor chain")
        head = support.git_head_revision(root)
        if not head or not support.git_ancestor(result, head, root=root):
            errors.append(f"archive {change_id} staging result is not an ancestor of protected HEAD")
        if support.git_file_content(result, _relative(root, path), root=root) is not None:
            errors.append(f"archive {change_id} archive-lock is inside its staging result_revision")
        staged_paths = support.git_tree_paths(result, archive_relative, root=root) or []
        staged_exact = staged_paths == sorted(entry_paths) and all(
            support.git_file_sha256(result, str(entry.get("path")), root=root) == entry.get("sha256")
            for entry in entries
        )
        if not staged_exact:
            errors.append(
                f"archive {archive_relative} staging tree is not the exact lock-excluded archive subject"
            )

        source_change_dir = re.sub(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}-", "", archive_root.name)
        source_change_root = f"openspec/changes/{source_change_dir}"
        live_result = f"{source_change_root}/verification-result.json"
        verification_approval = approvals.get(result_record.get("approvalId"))
        verification_approval_path = (
            approval_paths.get(str(verification_approval.get("approvalId")))
            if verification_approval
            else None
        )
        expected_rs = [{"status": "A", "path": live_result}]
        if verification_approval_path:
            expected_rs.append({"status": "A", "path": _relative(root, verification_approval_path)})
        expected_rs.sort(key=lambda item: item["path"])
        actual_rs = support.git_diff_entries(verification, source, root=root) or []
        rs_valid = bool(
            verification_approval_path
            and actual_rs == expected_rs
            and support.git_file_sha256(source, live_result, root=root) == _sha(result_path)
            and support.git_file_sha256(
                source, _relative(root, verification_approval_path), root=root
            )
            == _sha(verification_approval_path)
        )
        if not rs_valid:
            errors.append(
                f"archive {archive_relative} verification source tree is not the exact metadata-only finalized result child"
            )

        pre_path = archive_root / "pre-archive-verification.json"
        pre_record = _load_json_relative(root, pre_path, errors) if pre_path.is_file() else {}
        pre_ref = lock.get("pre_archive_verification", {})
        source_files = sorted(
            (
                {
                    "path": item.relative_to(archive_root).as_posix(),
                    "sha256": _sha(item),
                }
                for item in archive_root.glob("**/*")
                if item.is_file() and item not in (path, pre_path)
            ),
            key=lambda item: item["path"],
        )
        pre_approval = approvals.get(pre_record.get("approvalId")) if pre_record else None
        pre_approval_path = (
            approval_paths.get(str(pre_approval.get("approvalId"))) if pre_approval else None
        )
        pre_validated = _parse_time(pre_record.get("validatedAt")) if pre_record else None
        pre_approved = _parse_time(pre_approval.get("approvedAt")) if pre_approval else None
        pre_valid = bool(
            pre_path.is_file()
            and pre_ref.get("path") == "pre-archive-verification.json"
            and pre_ref.get("sha256") == _sha(pre_path)
            and pre_record.get("subjectType") == "archiveSourceVerification"
            and pre_record.get("changeId") == change_id
            and pre_record.get("changeRevision") == proposal.get("revision")
            and pre_record.get("sourceRevision") == source
            and pre_record.get("sourceChangeLockSha256") == lock.get("source_change_lock_sha256")
            and pre_record.get("guardContract") == "ARKDECK-ARCHIVE-SEMANTICS-1"
            and pre_record.get("result") == "passed"
            and sorted(pre_record.get("invariants", []))
            == sorted(support.PRE_ARCHIVE_INVARIANTS)
            and pre_record.get("validatedFiles") == source_files
            and pre_validated
            and pre_approved
            and pre_approved >= pre_validated
            and pre_approval.get("subjectType") == "archiveSourceVerification"
            and pre_approval.get("subjectId") == pre_record.get("verificationId")
            and pre_approval.get("subjectRevision") == proposal.get("revision")
            and pre_approval.get("subjectSha256") == _sha(pre_path)
            and pre_approval.get("baseRevision") == source
            and pre_approval.get("decision") == "approved"
            and support.externally_verified(
                pre_approval_path,
                pre_path,
                pre_approval,
                verifiers,
                root=root,
            )
        )
        if not pre_valid:
            errors.append(
                f"archive {archive_relative} lacks an exact externally verified pre-move semantic guard attestation"
            )

        source_paths = support.git_tree_paths(source, source_change_root, root=root) or []
        destinations = sorted(
            f"{archive_relative}/{item.removeprefix(source_change_root + '/')}"
            for item in source_paths
        )
        expected_archive_paths = sorted(set(destinations + [_relative(root, pre_path)]))
        move_set_valid = bool(
            source_paths
            and sorted(staged_paths) == expected_archive_paths
            and not (support.git_tree_paths(result, source_change_root, root=root) or [])
        )
        move_hashes_valid = all(
            support.git_file_sha256(source, source_path, root=root)
            == support.git_file_sha256(
                result,
                f"{archive_relative}/{source_path.removeprefix(source_change_root + '/')}",
                root=root,
            )
            for source_path in source_paths
        )
        st_entries = support.git_diff_entries(source, result, root=root) or []
        st_by_path = {entry["path"]: entry["status"] for entry in st_entries}
        unique = len(st_by_path) == len(st_entries)
        required: dict[str, str] = {item: "D" for item in source_paths}
        required.update({item: "A" for item in expected_archive_paths})
        allowed = dict(required)
        if pre_approval_path:
            pre_approval_relative = _relative(root, pre_approval_path)
            required[pre_approval_relative] = "A"
            allowed[pre_approval_relative] = "A"
        # Behavior publication may additionally apply only its canonical spec,
        # acceptance, baseline and platform-revalidation products.
        if proposal.get("schema") == "arkdeck-behavior":
            for entry in st_entries:
                candidate = entry["path"]
                if candidate.startswith("openspec/specs/") and candidate.endswith("/spec.md"):
                    allowed[candidate] = "M"
            for candidate, status in {
                "openspec/verification/acceptance-cases.yaml": "M",
                "openspec/verification/acceptance-index.txt": "M",
                "openspec/config.yaml": "M",
                "openspec/verification/core-conformance.yaml": "M",
                "openspec/verification/traceability.md": "M",
                "openspec/platforms/PLATFORM-PROFILES.lock.yaml": "M",
            }.items():
                allowed[candidate] = status
            baseline_ref = lock.get("result_core_baseline", {}).get("path")
            if isinstance(baseline_ref, str):
                allowed[baseline_ref] = "A"
                manifest_ref = baseline_ref.replace(".lock.yaml", ".files.yaml")
                allowed[manifest_ref] = "A"
                required[baseline_ref] = "A"
                required[manifest_ref] = "A"
        history = [
            item
            for item in st_entries
            if re.fullmatch(
                r"openspec/platforms/history/PLATFORM-PROFILES-[A-Za-z0-9._-]+\.lock\.yaml",
                item["path"],
            )
        ]
        history_valid = len(history) <= 1 and all(
            item["status"] == "A"
            and st_by_path.get("openspec/platforms/PLATFORM-PROFILES.lock.yaml") == "M"
            and support.git_file_sha256(result, item["path"], root=root)
            == support.git_file_sha256(
                source, "openspec/platforms/PLATFORM-PROFILES.lock.yaml", root=root
            )
            for item in history
        )
        for item in history:
            allowed[item["path"]] = "A"
        st_valid = bool(
            move_set_valid
            and move_hashes_valid
            and unique
            and history_valid
            and all(allowed.get(item["path"]) == item["status"] for item in st_entries)
            and all(st_by_path.get(candidate) == status for candidate, status in required.items())
        )
        if not st_valid:
            errors.append(
                f"archive {archive_relative} staging diff is not the exact approved sync/move transition"
            )

        baseline_reference = lock.get("result_core_baseline", {})
        baseline_relative = str(baseline_reference.get("path", ""))
        baseline_path = _repo_path(root, baseline_relative)
        baseline_contained = bool(
            re.fullmatch(
                r"openspec/baselines/CORE-[0-9]+\.[0-9]+\.[0-9]+\.lock\.yaml",
                baseline_relative,
            )
            and baseline_path
        )
        baseline_doc: dict[str, Any] = {}
        baseline_integrity = bool(
            baseline_contained
            and baseline_path
            and baseline_path.is_file()
            and support.git_file_sha256(result, baseline_relative, root=root)
            == _sha(baseline_path)
            and baseline_reference.get("sha256") == _sha(baseline_path)
        )
        if baseline_integrity and baseline_path:
            baseline_doc = support.yaml_safe_load(
                baseline_path.read_text(encoding="utf-8")
            ) or {}
            baseline_integrity &= (
                baseline_reference.get("id") == baseline_doc.get("baseline")
                and baseline_doc.get("status") == "accepted"
            )
            for hash_entry in support.iter_hash_entries(baseline_doc):
                pinned = _repo_path(root, hash_entry.get("path"))
                baseline_integrity &= bool(
                    pinned
                    and pinned.is_file()
                    and _sha(pinned) == hash_entry.get("sha256")
                    and support.git_file_sha256(
                        result, str(hash_entry.get("path")), root=root
                    )
                    == hash_entry.get("sha256")
                )
            manifest_relative = support.dig(baseline_doc, "file_manifest", "path")
            manifest_path = _repo_path(root, manifest_relative)
            if manifest_path and manifest_path.is_file():
                manifest = support.yaml_safe_load(
                    manifest_path.read_text(encoding="utf-8")
                ) or {}
                manifest_paths = [item.get("path") for item in manifest.get("files", [])]
                baseline_integrity &= (
                    manifest.get("baseline") == baseline_doc.get("baseline")
                    and manifest_paths == sorted(manifest_paths)
                    and len(manifest_paths) == len(set(manifest_paths))
                    and support.git_file_sha256(result, manifest_relative, root=root)
                    == _sha(manifest_path)
                    and all(
                        support.git_file_sha256(
                            result, str(item.get("path")), root=root
                        )
                        == item.get("sha256")
                        for item in manifest.get("files", [])
                    )
                )
            else:
                baseline_integrity = False
            revalidation_context = baseline_doc.get(
                "platform_revalidation_context", {}
            )
            platform_chain_records: list[dict[str, Any]] = []
            for historical_path in support.git_tree_paths(
                result, "openspec/platforms/history", root=root
            ) or []:
                if re.fullmatch(
                    r"openspec/platforms/history/PLATFORM-PROFILES-[A-Za-z0-9._-]+\.lock\.yaml",
                    historical_path,
                ) is None:
                    continue
                historical_source = support.git_file_content(
                    result, historical_path, root=root
                )
                try:
                    historical_doc = support.yaml_safe_load(
                        historical_source or ""
                    ) or {}
                except ValueError:
                    historical_doc = {}
                    errors.append(
                        f"archive {archive_relative} cannot parse historical Platform lock {historical_path}"
                    )
                platform_chain_records.append(
                    {
                        "path": historical_path,
                        "source": historical_source,
                        "document": historical_doc,
                    }
                )
            current_platform_path = (
                "openspec/platforms/PLATFORM-PROFILES.lock.yaml"
            )
            current_platform_source = support.git_file_content(
                result, current_platform_path, root=root
            )
            try:
                current_platform_doc = support.yaml_safe_load(
                    current_platform_source or ""
                ) or {}
            except ValueError:
                current_platform_doc = {}
            platform_chain_records.append(
                {
                    "path": current_platform_path,
                    "source": current_platform_source,
                    "document": current_platform_doc,
                }
            )
            revalidation_record = next(
                (
                    chain_record
                    for chain_record in platform_chain_records
                    if chain_record["document"].get("lock")
                    == revalidation_context.get("platform_lock")
                    and chain_record["document"].get("revision")
                    == revalidation_context.get("revision")
                    and chain_record.get("source")
                    and hashlib.sha256(
                        chain_record["source"].encode("utf-8")
                    ).hexdigest()
                    == revalidation_context.get("sha256")
                ),
                None,
            )
            revalidation_context_valid = bool(
                revalidation_record
                and sorted(
                    str(value)
                    for value in revalidation_record["document"].get(
                        "current_delivery_platforms", []
                    )
                )
                == sorted(
                    str(value)
                    for value in revalidation_context.get(
                        "current_delivery_platforms", []
                    )
                )
            )
            baseline_integrity &= revalidation_context_valid
        if not baseline_integrity:
            errors.append(f"archive {archive_relative} result baseline integrity is invalid")

        historical_axes: dict[str, dict[str, Any]] = {}
        for axis_path, subject_type, id_field in (
            (
                "openspec/platforms/PLATFORM-PROFILES.lock.yaml",
                "platformLock",
                "lock",
            ),
            (
                "openspec/verification/core-conformance.yaml",
                "conformanceSuite",
                "suite",
            ),
        ):
            axis_source = support.git_file_content(result, axis_path, root=root)
            axis_doc: dict[str, Any] = {}
            try:
                axis_doc = support.yaml_safe_load(axis_source or "") or {}
            except ValueError:
                errors.append(
                    f"archive {archive_relative} result axes cannot be parsed from its fixed staging revision"
                )
            axis_approval = approvals.get(support.dig(axis_doc, "ratification", "approval_ref"))
            changed = support.git_file_sha256(source, axis_path, root=root) != support.git_file_sha256(
                result, axis_path, root=root
            )
            valid_axis = bool(
                axis_doc.get("status") == "accepted"
                and axis_doc.get("execution_gate") == "open"
                and support.valid_historical_approval(
                    source=axis_source,
                    subject_name=Path(axis_path).name,
                    document=axis_doc,
                    approval=axis_approval,
                    approval_path=approval_paths.get(
                        str(axis_approval.get("approvalId"))
                    )
                    if axis_approval
                    else None,
                    subject_type=subject_type,
                    subject_id=str(axis_doc.get(id_field)),
                    result_revision=result,
                    verifiers=verifiers,
                    exact_base=changed,
                    root=root,
                )
            )
            if subject_type == "conformanceSuite":
                valid_axis &= axis_doc.get("core_baseline") == baseline_doc.get("baseline")
            if not valid_axis:
                label = "Platform lock" if subject_type == "platformLock" else "Conformance suite"
                errors.append(
                    f"archive {archive_relative} historical {label} is not exact and accepted"
                )
            historical_axes[axis_path] = axis_doc

        base_snapshot = support.git_normative_spec_snapshot(
            revision=base,
            errors=errors,
            subject=f"archive {archive_relative} predecessor specs",
            root=root,
        )
        result_snapshot = support.git_normative_spec_snapshot(
            revision=result,
            errors=errors,
            subject=f"archive {archive_relative} result specs",
            root=root,
        )
        behavior_transition = bool(base_snapshot and result_snapshot)
        acceptance_transition = bool(base_snapshot and result_snapshot)
        if proposal.get("schema") == "arkdeck-platform" and base_snapshot and result_snapshot:
            behavior_transition = base_snapshot.get("files") == result_snapshot.get("files")
            acceptance_transition = all(
                support.git_file_sha256(base, f"openspec/verification/{name}", root=root)
                == support.git_file_sha256(result, f"openspec/verification/{name}", root=root)
                for name in ("acceptance-cases.yaml", "acceptance-index.txt")
            )
        elif proposal.get("schema") == "arkdeck-behavior" and base_snapshot and result_snapshot:
            delta_sources = [
                {"path": _relative(root, item), "text": item.read_text(encoding="utf-8")}
                for item in sorted((archive_root / "specs").glob("**/*.md"))
            ]
            overlay = support.build_behavior_overlay(
                delta_sources=delta_sources,
                baseline_requirement_acceptance=base_snapshot.get(
                    "requirement_acceptance", {}
                ),
                baseline_acceptance_owner=base_snapshot.get("acceptance_owner", {}),
                baseline_requirement_paths={
                    requirement_id: value.get("path")
                    for requirement_id, value in base_snapshot.get(
                        "requirements", {}
                    ).items()
                },
                errors=errors,
                subject=f"archive {archive_relative} behavior overlay",
                root=root,
            )
            expected = support.apply_behavior_overlay_to_snapshot(base_snapshot, overlay)
            touched_paths = sorted(
                {
                    value.get("target_path")
                    for value in overlay.get("records", {}).values()
                    if value.get("target_path")
                }
            )
            same_file_set = sorted(base_snapshot.get("files", {})) == sorted(
                result_snapshot.get("files", {})
            )
            full_file_transition = same_file_set and all(
                (
                    result_file := result_snapshot.get("files", {}).get(file_path)
                )
                and (
                    base_file.get("non_requirement_sha256")
                    == result_file.get("non_requirement_sha256")
                    if file_path in touched_paths
                    else base_file.get("sha256") == result_file.get("sha256")
                )
                for file_path, base_file in base_snapshot.get("files", {}).items()
            )
            behavior_transition = (
                expected == result_snapshot.get("requirements")
                and full_file_transition
            )

            base_cases_source = support.git_file_content(
                base, "openspec/verification/acceptance-cases.yaml", root=root
            )
            result_cases_source = support.git_file_content(
                result,
                "openspec/verification/acceptance-cases.yaml",
                root=root,
            )
            result_index_source = support.git_file_content(
                result,
                "openspec/verification/acceptance-index.txt",
                root=root,
            )
            local_cases_path = archive_root / "acceptance-cases.yaml"
            acceptance_transition = False
            if (
                base_cases_source
                and result_cases_source
                and result_index_source
                and local_cases_path.is_file()
            ):
                try:
                    base_cases_doc = support.yaml_safe_load(base_cases_source) or {}
                    result_cases_doc = support.yaml_safe_load(result_cases_source) or {}
                    local_cases_doc = support.yaml_safe_load(
                        local_cases_path.read_text(encoding="utf-8")
                    ) or {}
                except ValueError:
                    base_cases_doc = {}
                    result_cases_doc = {}
                    local_cases_doc = {}
                expected_cases = {
                    item.get("acceptance_id"): dict(item)
                    for item in base_cases_doc.get("cases", [])
                }
                acceptance_target_paths: dict[str, str] = {}
                for overlay_record in overlay.get("records", {}).values():
                    for acceptance_id in overlay_record.get("scenarios", []):
                        acceptance_target_paths[acceptance_id] = str(
                            overlay_record.get("target_path")
                        )
                for item in local_cases_doc.get("cases", []):
                    acceptance_id = item.get("acceptance_id")
                    promoted = {
                        field: value
                        for field, value in item.items()
                        if field != "source_sha256"
                    }
                    promoted["expected_source"] = (
                        f"{acceptance_target_paths.get(acceptance_id)}#{acceptance_id}"
                    )
                    expected_cases[acceptance_id] = promoted
                result_cases = {
                    item.get("acceptance_id"): item
                    for item in result_cases_doc.get("cases", [])
                }
                base_metadata = {
                    field: value
                    for field, value in base_cases_doc.items()
                    if field not in ("registry", "status", "cases")
                }
                result_metadata = {
                    field: value
                    for field, value in result_cases_doc.items()
                    if field not in ("registry", "status", "cases")
                }
                result_index = [
                    line
                    for line in result_index_source.splitlines()
                    if line and not line.startswith("#")
                ]
                expected_index = sorted(
                    result_snapshot.get("acceptance_owner", {}).keys()
                )
                local_case_ids = sorted(
                    item.get("acceptance_id")
                    for item in local_cases_doc.get("cases", [])
                )
                acceptance_transition = bool(
                    base_metadata == result_metadata
                    and local_case_ids
                    == sorted(overlay.get("touched_acceptance", []))
                    and expected_cases == result_cases
                    and result_index == expected_index
                )
        if not behavior_transition:
            errors.append(
                f"archive {archive_relative} result current specs are not exactly predecessor baseline + approved transition"
            )
        if not acceptance_transition:
            errors.append(
                f"archive {archive_relative} result Core acceptance registry/index do not equal the approved transition"
            )

        source_lock = archive_root / "change-lock.yaml"
        source_lock_doc = (
            support.yaml_safe_load(source_lock.read_text(encoding="utf-8")) or {}
            if source_lock.is_file()
            else {}
        )
        change_approval = approvals.get(source_lock_doc.get("approval_id"))
        valid_change_approval = bool(
            source_lock.is_file()
            and change_approval
            and source_lock_doc.get("status") == "approved"
            and source_lock_doc.get("change_id") == change_id
            and source_lock_doc.get("revision") == proposal.get("revision")
            and change_approval.get("subjectType") == "change"
            and change_approval.get("subjectId") == change_id
            and change_approval.get("subjectRevision") == proposal.get("revision")
            and change_approval.get("subjectSha256") == _sha(source_lock)
            and change_approval.get("baseRevision") == base
            and change_approval.get("decision") == "approved"
            and support.externally_verified(
                approval_paths.get(str(change_approval.get("approvalId"))),
                source_lock,
                change_approval,
                verifiers,
                root=root,
            )
        )
        if not valid_change_approval:
            errors.append(f"archive {archive_relative} source change approval is invalid")
        valid_verification = bool(
            result_record.get("changeId") == change_id
            and result_record.get("changeRevision") == proposal.get("revision")
            and result_record.get("status") == "passed"
            and result_record.get("changeLockSha256") == (_sha(source_lock) if source_lock.is_file() else None)
            and result_record.get("verificationPlanSha256") == _sha(verification_path)
            and result_record.get("resultRevision") == verification
            and verification_approval
            and verification_approval.get("subjectType") == "changeVerification"
            and verification_approval.get("subjectId") == result_record.get("verificationId")
            and verification_approval.get("subjectRevision") == proposal.get("revision")
            and verification_approval.get("subjectSha256") == _sha(result_path)
            and verification_approval.get("baseRevision") == verification
            and verification_approval.get("decision") == "approved"
            and support.externally_verified(
                verification_approval_path,
                result_path,
                verification_approval,
                verifiers,
                root=root,
            )
        )
        if not valid_verification:
            errors.append(f"archive {archive_relative} source verification approval is invalid")

        archived_tasks: dict[str, dict[str, Any]] = {}
        archived_task_paths: dict[str, Path] = {}
        for packet_path in sorted((archive_root / "task-packets").glob("*.json")):
            packet = _load_json_relative(root, packet_path, errors) or {}
            packet_schema_entry = schemas.get(
                f"https://arkdeck.dev/schemas/task-packet-{packet.get('schemaVersion')}.json"
            )
            if packet_schema_entry:
                packet_schema = packet_schema_entry[1]
                packet_missing = [
                    key for key in packet_schema.get("required", []) if key not in packet
                ]
                packet_extra = [
                    key for key in packet if key not in packet_schema.get("properties", {})
                ]
                if packet_missing:
                    errors.append(
                        f"archived Task packet {_relative(root, packet_path)} missing {', '.join(packet_missing)}"
                    )
                if packet_extra:
                    errors.append(
                        f"archived Task packet {_relative(root, packet_path)} has unknown fields {', '.join(packet_extra)}"
                    )
            else:
                errors.append(
                    f"archived Task packet {_relative(root, packet_path)} references an unavailable versioned schema"
                )
            task_id = str(packet.get("taskId"))
            if packet_path.stem != task_id:
                errors.append(
                    f"archived Task packet filename/id mismatch: {_relative(root, packet_path)}"
                )
            if task_id in archived_tasks:
                errors.append(f"archive {archive_relative} has duplicate Task packet {task_id}")
            archived_tasks[task_id] = packet
            archived_task_paths[task_id] = packet_path
            if packet.get("status") != "ready" or packet.get("revision") != 1:
                errors.append(f"archived Task {task_id} is not a frozen ready packet")
            if packet.get("changeId") != change_id or packet.get("changeRevision") != proposal.get("revision"):
                errors.append(f"archived Task {task_id} belongs to another change")
            packet_approval = approvals.get(packet.get("approvalId"))
            valid_packet = bool(
                packet_approval
                and packet_approval.get("subjectType") == "taskPacket"
                and packet_approval.get("subjectId") == task_id
                and packet_approval.get("subjectRevision") == packet.get("revision")
                and packet_approval.get("subjectSha256") == _sha(packet_path)
                and packet_approval.get("baseRevision") == packet.get("baseRevision")
                and packet_approval.get("decision") == "approved"
                and support.externally_verified(
                    approval_paths.get(str(packet_approval.get("approvalId"))),
                    packet_path,
                    packet_approval,
                    verifiers,
                    root=root,
                )
            )
            if not valid_packet:
                errors.append(f"archived Task {task_id} packet approval is invalid")
        task_index = archive_root / "tasks.md"
        if task_index.is_file():
            indexed = sorted(
                set(re.findall(r"\b(TASK-[A-Z0-9-]+)\b", task_index.read_text(encoding="utf-8")))
            )
            if indexed != sorted(archived_tasks):
                errors.append(f"archive {archive_relative} Task index differs from archived packets")
        else:
            errors.append(f"archive {archive_relative} has no Task index")
        archive_scope = support.yaml_safe_load(scope_path.read_text(encoding="utf-8")) or {}
        if not (
            archive_scope.get("change_id") == change_id
            and archive_scope.get("revision") == proposal.get("revision")
        ):
            errors.append(f"archive {archive_relative} scope identity/revision mismatch")
        all_requirements = sorted(
            {
                value
                for packet in archived_tasks.values()
                for value in packet.get("requirementRefs", [])
            }
        )
        all_acceptance = sorted(
            {
                value
                for packet in archived_tasks.values()
                for value in packet.get("acceptanceRefs", [])
            }
        )
        if all_requirements != sorted(archive_scope.get("requirements", [])):
            errors.append(
                f"archive {archive_relative} Task Requirement union differs from immutable scope"
            )
        if all_acceptance != sorted(archive_scope.get("acceptance", [])):
            errors.append(
                f"archive {archive_relative} Task Acceptance union differs from immutable scope"
            )

        archived_claims: dict[str, dict[str, Any]] = {}
        archived_claim_paths: dict[str, Path] = {}
        archived_claim_keys: set[tuple[str, int]] = set()
        archived_claim_owner_ids: set[str] = set()
        for claim_path in sorted(archive_root.glob("evidence/runs/**/claim.json")):
            claim = _load_json_relative(root, claim_path, errors) or {}
            claim_schema_entry = schemas.get(
                f"https://arkdeck.dev/schemas/task-claim-{claim.get('schemaVersion')}.json"
            )
            if claim_schema_entry:
                claim_schema = claim_schema_entry[1]
                claim_missing = [
                    key for key in claim_schema.get("required", []) if key not in claim
                ]
                claim_extra = [
                    key for key in claim if key not in claim_schema.get("properties", {})
                ]
                if claim_missing:
                    errors.append(
                        f"archived claim {_relative(root, claim_path)} missing {', '.join(claim_missing)}"
                    )
                if claim_extra:
                    errors.append(
                        f"archived claim {_relative(root, claim_path)} has unknown fields {', '.join(claim_extra)}"
                    )
            else:
                errors.append(
                    f"archived claim {_relative(root, claim_path)} references an unavailable versioned schema"
                )
            claim_id = str(claim.get("claimId"))
            if claim_id in archived_claims:
                errors.append(f"archive {archive_relative} has duplicate claim {claim_id}")
            archived_claims[claim_id] = claim
            archived_claim_paths[claim_id] = claim_path
            claim_key = (str(claim.get("taskId")), int(claim.get("attempt", 0)))
            if claim_key in archived_claim_keys:
                errors.append(
                    f"archive {archive_relative} has duplicate claim attempt {claim_key[0]}/{claim_key[1]}"
                )
            archived_claim_keys.add(claim_key)
            packet = archived_tasks.get(str(claim.get("taskId")))
            packet_path = archived_task_paths.get(str(claim.get("taskId")))
            exact_claim = bool(
                packet
                and packet_path
                and claim.get("status") == "claimed"
                and claim.get("taskPacketSha256") == _sha(packet_path)
                and claim.get("taskRevision") == packet.get("revision")
                and claim.get("approvalId") == packet.get("approvalId")
                and claim.get("changeId") == packet.get("changeId")
                and claim.get("changeRevision") == packet.get("changeRevision")
                and claim.get("baseRevision") == packet.get("baseRevision")
                and claim.get("platform") == packet.get("platform")
            )
            if not exact_claim:
                errors.append(
                    f"archived claim {_relative(root, claim_path)} does not exactly bind its Task packet"
                )
            owner_path = claim_path.with_name("claim-owner-attestation.json")
            owner = _load_json_relative(root, owner_path, errors) if owner_path.is_file() else None
            if not owner:
                errors.append(
                    f"archived claim {_relative(root, claim_path)} has no protected owner attestation"
                )
            else:
                _report_contract_fields(
                    root,
                    owner_path,
                    owner,
                    "claim-owner-attestation.schema.json",
                    "archived claim owner",
                    errors,
                )
            if owner and not (
                owner.get("subjectType") == "taskClaim"
                and owner.get("claimId") == claim_id
                and owner.get("claimSha256") == _sha(claim_path)
                and owner.get("taskId") == claim.get("taskId")
                and owner.get("attempt") == claim.get("attempt")
                and owner.get("claimantKind") == claim.get("claimantKind")
                and owner.get("claimedBy") == claim.get("claimedBy")
                and owner.get("claimedAt") == claim.get("claimedAt")
                and owner.get("leaseExpiresAt")
                == claim.get("leaseExpiresAt")
                and support.externally_verified(
                    owner_path, claim_path, owner, verifiers, root=root
                )
            ):
                errors.append(
                    f"archived claim {_relative(root, claim_path)} owner attestation is not exact or externally verified"
                )
            if owner:
                owner_id = str(owner.get("attestationId"))
                if owner_id in archived_claim_owner_ids:
                    errors.append(
                        f"archive {archive_relative} has duplicate claim owner attestation {owner_id}"
                    )
                archived_claim_owner_ids.add(owner_id)

        archived_runs: dict[str, dict[str, Any]] = {}
        archived_run_paths: dict[str, Path] = {}
        run_by_claim: dict[str, dict[str, Any]] = {}
        done_tasks: dict[str, list[str]] = defaultdict(list)
        superseded_tasks: set[str] = set()
        archived_run_owner_ids: set[str] = set()
        archived_replacements: dict[str, dict[str, Any]] = {}
        for run_path in sorted(archive_root.glob("evidence/runs/**/run.json")):
            run = _load_json_relative(root, run_path, errors) or {}
            run_schema_entry = schemas.get(
                f"https://arkdeck.dev/schemas/task-run-{run.get('schemaVersion')}.json"
            )
            if run_schema_entry:
                run_schema = run_schema_entry[1]
                run_missing = [
                    key for key in run_schema.get("required", []) if key not in run
                ]
                run_extra = [
                    key for key in run if key not in run_schema.get("properties", {})
                ]
                if run_missing:
                    errors.append(
                        f"archived run {_relative(root, run_path)} missing {', '.join(run_missing)}"
                    )
                if run_extra:
                    errors.append(
                        f"archived run {_relative(root, run_path)} has unknown fields {', '.join(run_extra)}"
                    )
            else:
                errors.append(
                    f"archived run {_relative(root, run_path)} references an unavailable versioned schema"
                )
            run_id = str(run.get("runId"))
            if run_id in archived_runs:
                errors.append(f"archive {archive_relative} has duplicate run ID {run_id}")
            if str(run.get("claimId")) in run_by_claim:
                errors.append(f"archived claim {run.get('claimId')} has more than one run")
            archived_runs[run_id] = run
            archived_run_paths[run_id] = run_path
            run_by_claim[str(run.get("claimId"))] = run
            claim = archived_claims.get(str(run.get("claimId")))
            packet = archived_tasks.get(str(run.get("taskId")))
            packet_path = archived_task_paths.get(str(run.get("taskId")))
            exact_run = bool(
                claim
                and packet
                and packet_path
                and run.get("taskId") == claim.get("taskId")
                and run.get("taskRevision") == claim.get("taskRevision")
                and run.get("attempt") == claim.get("attempt")
                and run.get("taskPacketSha256") == claim.get("taskPacketSha256")
                and run.get("taskPacketSha256") == _sha(packet_path)
                and run.get("changeId") == change_id
                and run.get("changeRevision") == claim.get("changeRevision")
                and run.get("baseRevision") == claim.get("baseRevision")
                and run.get("platform") == claim.get("platform")
                and run.get("platform") == packet.get("platform")
                and run.get("executedBy") == claim.get("claimedBy")
            )
            if not exact_run:
                errors.append(
                    f"archived run {_relative(root, run_path)} does not exactly bind its claim and Task packet"
                )
            owner_path = run_path.with_name("run-owner-attestation.json")
            owner = _load_json_relative(root, owner_path, errors) if owner_path.is_file() else None
            if not owner:
                errors.append(
                    f"archived run {_relative(root, run_path)} has no protected owner attestation"
                )
            else:
                _report_contract_fields(
                    root,
                    owner_path,
                    owner,
                    "run-owner-attestation.schema.json",
                    "archived run owner",
                    errors,
                )
            claim_owner_path = (
                archived_claim_paths.get(str(run.get("claimId"))).with_name(
                    "claim-owner-attestation.json"
                )
                if archived_claim_paths.get(str(run.get("claimId")))
                else None
            )
            claim_owner = (
                _load_json_relative(root, claim_owner_path, errors)
                if claim_owner_path and claim_owner_path.is_file()
                else {}
            )
            valid_owner = bool(
                owner
                and owner.get("subjectType") == "taskRunLease"
                and owner.get("claimAttestationId") == claim_owner.get("attestationId")
                and owner.get("claimId") == run.get("claimId")
                and owner.get("runId") == run_id
                and owner.get("runSha256") == _sha(run_path)
                and owner.get("taskId") == run.get("taskId")
                and owner.get("attempt") == run.get("attempt")
                and owner.get("executedBy") == run.get("executedBy")
                and owner.get("finalizedAt") == run.get("endedAt")
                and support.externally_verified(
                    owner_path, run_path, owner, verifiers, root=root
                )
            )
            if not valid_owner:
                errors.append(
                    f"archived run {_relative(root, run_path)} owner attestation is not exact or externally verified"
                )
            if owner:
                owner_id = str(owner.get("attestationId"))
                if owner_id in archived_run_owner_ids:
                    errors.append(
                        f"archive {archive_relative} has duplicate run owner attestation {owner_id}"
                    )
                archived_run_owner_ids.add(owner_id)
            if run.get("status") == "done" and valid_owner:
                run_approval = approvals.get(run.get("approvalId"))
                run_ended_at = _parse_time(run.get("endedAt"))
                run_approved_at = (
                    _parse_time(run_approval.get("approvedAt"))
                    if run_approval
                    else None
                )
                valid_run_approval = bool(
                    run_approval
                    and run_approval.get("subjectType") == "taskRun"
                    and run_approval.get("subjectId") == run_id
                    and run_approval.get("subjectRevision") == run.get("attempt")
                    and run_approval.get("subjectSha256") == _sha(run_path)
                    and run_approval.get("baseRevision") == run.get("baseRevision")
                    and run_approval.get("decision") == "approved"
                    and run_ended_at
                    and run_approved_at
                    and run_approved_at >= run_ended_at
                    and support.externally_verified(
                        approval_paths.get(str(run_approval.get("approvalId"))),
                        run_path,
                        run_approval,
                        verifiers,
                        root=root,
                    )
                )
                if not valid_run_approval:
                    errors.append(
                        f"archived done run {_relative(root, run_path)} lacks externally verified result approval"
                    )
                if not support.git_ancestor(
                    run.get("resultRevision"), verification, root=root
                ):
                    errors.append(
                        f"archived done run {_relative(root, run_path)} result is not an ancestor of the archive result"
                    )
                if not support.git_ancestor(
                    run.get("baseRevision"), run.get("resultRevision"), root=root
                ):
                    errors.append(
                        f"archived done run {_relative(root, run_path)} result is not descended from its base"
                    )
                if valid_run_approval:
                    done_tasks[str(run.get("taskId"))].append(run_id)
            elif run.get("status") == "superseded" and valid_owner:
                replacement_id = str(run.get("supersededByTaskId"))
                valid_supersession = support.valid_task_supersession(
                    run=run,
                    run_path=run_path,
                    original=packet,
                    replacement=archived_tasks.get(replacement_id),
                    replacement_path=archived_task_paths.get(replacement_id),
                    approvals=approvals,
                    approval_paths=approval_paths,
                    verifiers=verifiers,
                    root=root,
                )
                if not valid_supersession:
                    errors.append(
                        f"archived superseded run {_relative(root, run_path)} lacks an exact approved Ready replacement with preserved scope"
                    )
                else:
                    superseded_tasks.add(str(run.get("taskId")))
                    if replacement_id in archived_replacements:
                        errors.append(
                            f"archived replacement Task {replacement_id} is authorized by more than one superseded run"
                        )
                    supersession_approval = approvals.get(
                        run.get("supersessionApprovalId"), {}
                    )
                    archived_replacements[replacement_id] = {
                        "runId": run_id,
                        "approvalId": run.get("supersessionApprovalId"),
                        "approvedAt": supersession_approval.get("approvedAt"),
                    }
        for claim_id, claim in archived_claims.items():
            authorization = archived_replacements.get(str(claim.get("taskId")))
            if authorization:
                claimed = _parse_time(claim.get("claimedAt"))
                approved = _parse_time(authorization.get("approvedAt"))
                exact = (
                    claim.get("supersededRunId") == authorization.get("runId")
                    and claim.get("taskSupersessionApprovalId")
                    == authorization.get("approvalId")
                )
                if not exact or not claimed or not approved or approved >= claimed:
                    errors.append(
                        f"archived replacement claim {claim_id} does not bind or strictly postdate its taskSupersession approval"
                    )
            elif claim.get("supersededRunId") is not None or claim.get(
                "taskSupersessionApprovalId"
            ) is not None:
                errors.append(
                    f"archived ordinary claim {claim_id} carries an unresolved taskSupersession authorization"
                )
        missing_claim_runs = sorted(set(archived_claims) - set(run_by_claim))
        if missing_claim_runs:
            errors.append(
                f"archive {archive_relative} has claims without terminal runs: {', '.join(missing_claim_runs)}"
            )
        conflicting = sorted(set(done_tasks) & superseded_tasks)
        if conflicting:
            errors.append(
                f"archive {archive_relative} has Tasks that are both done and superseded: {', '.join(conflicting)}"
            )
        active_tasks = sorted(set(archived_tasks) - superseded_tasks)
        if not active_tasks:
            errors.append(f"archive {archive_relative} has no active Task packets")
        unfinished = sorted(
            task_id for task_id in active_tasks if len(done_tasks.get(task_id, [])) != 1
        )
        if unfinished:
            errors.append(
                f"archive {archive_relative} contains unfinished or multiply-completed Task runs: {', '.join(unfinished)}"
            )
        active_requirements = sorted(
            {
                value
                for task_id in active_tasks
                for value in archived_tasks[task_id].get("requirementRefs", [])
            }
        )
        active_acceptance = sorted(
            {
                value
                for task_id in active_tasks
                for value in archived_tasks[task_id].get("acceptanceRefs", [])
            }
        )
        if active_requirements != sorted(archive_scope.get("requirements", [])):
            errors.append(
                f"archive {archive_relative} active Task Requirement union differs from immutable scope"
            )
        if active_acceptance != sorted(archive_scope.get("acceptance", [])):
            errors.append(
                f"archive {archive_relative} active Task Acceptance union differs from immutable scope"
            )
        task_run_entries = result_record.get("taskRuns", [])
        if sorted(item.get("taskId") for item in task_run_entries) != active_tasks:
            errors.append(
                f"archive {archive_relative} verification result does not exactly cover active Tasks"
            )
        bound_runs: list[dict[str, Any]] = []
        for item in task_run_entries:
            run = archived_runs.get(str(item.get("runId")))
            run_path = archived_run_paths.get(str(item.get("runId")))
            exact = bool(
                run
                and run_path
                and run.get("taskId") == item.get("taskId")
                and item.get("runSha256") == _sha(run_path)
                and item.get("resultRevision") == run.get("resultRevision")
                and support.git_ancestor(
                    run.get("resultRevision"), verification, root=root
                )
            )
            if not exact:
                errors.append(
                    f"archive {archive_relative} verification result has an invalid Task run binding for {item.get('taskId')}"
                )
            else:
                bound_runs.append(run)
        aggregate_base = change_approval.get("baseRevision") if change_approval else None
        aggregate_base_exact = bool(aggregate_base) and all(
            archived_tasks[task_id].get("baseRevision") == aggregate_base
            for task_id in active_tasks
        )
        if not aggregate_base_exact:
            errors.append(
                f"archive {archive_relative} active Tasks do not share the exact change-approval base"
            )
        provenance: dict[str, str] = {}
        archive_summary_path = archive_root / "evidence/summary.md"
        archive_barrier_path = (
            archive_root / "supersession-barrier-attestation.json"
        )
        for archived_file in [
            task_index,
            archive_summary_path,
            archive_barrier_path,
            *archived_task_paths.values(),
        ]:
            if archived_file.is_file():
                suffix = archived_file.relative_to(archive_root).as_posix()
                source_name = f"{source_change_root}/{suffix}"
                provenance[source_name] = _sha(archived_file)
        fixed_barrier = change_records.get(change_id, {}).get("barrier")
        fixed_barrier_path = (
            Path(fixed_barrier.get("path")) if fixed_barrier else None
        )
        if fixed_barrier_path and fixed_barrier_path.is_file():
            provenance[_relative(root, fixed_barrier_path)] = _sha(
                fixed_barrier_path
            )
        archive_approval_ids: set[str] = {
            str(value)
            for value in (
                source_lock_doc.get("approval_id"),
                result_record.get("approvalId"),
            )
            if value
        }
        for claim_id, claim in archived_claims.items():
            claim_path = archived_claim_paths.get(claim_id)
            if claim_path:
                for archived_file in (
                    claim_path,
                    claim_path.with_name("claim-owner-attestation.json"),
                    claim_path.with_name("resource-identity-attestation.json"),
                    claim_path.with_name("lab-execution-plan.json"),
                    claim_path.with_name("lab-execution-authorization.json"),
                ):
                    if archived_file.is_file():
                        suffix = archived_file.relative_to(archive_root).as_posix()
                        provenance[f"{source_change_root}/{suffix}"] = _sha(
                            archived_file
                        )
                        if archived_file.name == "lab-execution-authorization.json":
                            lab_doc = _load_json_relative(root, archived_file, []) or {}
                            if lab_doc.get("approvalId"):
                                archive_approval_ids.add(
                                    str(lab_doc["approvalId"])
                                )
            if claim.get("approvalId"):
                archive_approval_ids.add(str(claim["approvalId"]))
        archived_hardware_runs: set[str] = set()
        archive_case_definitions: dict[str, dict[str, Any]] = {}
        historical_case_source = support.git_file_content(
            verification,
            "openspec/verification/acceptance-cases.yaml",
            root=root,
        )
        try:
            historical_case_doc = support.yaml_safe_load(
                historical_case_source or ""
            ) or {}
            archive_case_definitions.update(
                {
                    item.get("acceptance_id"): item
                    for item in historical_case_doc.get("cases", [])
                }
            )
            archive_local_registry = archive_root / "acceptance-cases.yaml"
            if archive_local_registry.is_file():
                archive_local_doc = support.yaml_safe_load(
                    archive_local_registry.read_text(encoding="utf-8")
                ) or {}
                archive_case_definitions.update(
                    {
                        item.get("acceptance_id"): item
                        for item in archive_local_doc.get("cases", [])
                    }
                )
        except ValueError:
            errors.append(
                f"archive {archive_relative} cannot parse its historical Core acceptance registry"
            )
        for run_id, run in archived_runs.items():
            run_path = archived_run_paths.get(run_id)
            if run_path:
                for archived_file in (
                    run_path,
                    run_path.with_name("run-owner-attestation.json"),
                ):
                    if archived_file.is_file():
                        suffix = archived_file.relative_to(archive_root).as_posix()
                        provenance[f"{source_change_root}/{suffix}"] = _sha(
                            archived_file
                        )
            for approval_id in (
                run.get("approvalId"),
                run.get("supersessionApprovalId"),
            ):
                if approval_id:
                    archive_approval_ids.add(str(approval_id))
            for evidence in run.get("evidence", []):
                if evidence.get("verificationRef"):
                    archive_approval_ids.add(str(evidence["verificationRef"]))
            for hardware_id in {
                hardware_id
                for acceptance_result in run.get("acceptanceResults", [])
                for hardware_id in acceptance_result.get(
                    "hardwareMatrixRefs", []
                )
            }:
                hardware_path = (
                    root
                    / "openspec/verification/hardware-evidence"
                    / f"{hardware_id}.json"
                )
                if hardware_path.is_file():
                    hardware_doc = _load_json_relative(root, hardware_path, []) or {}
                    provenance[_relative(root, hardware_path)] = _sha(hardware_path)
                    if hardware_doc.get("approvalId"):
                        archive_approval_ids.add(
                            str(hardware_doc["approvalId"])
                        )
                    task_run_id = str(hardware_doc.get("taskRunId"))
                    if task_run_id in archived_hardware_runs:
                        errors.append(
                            f"archived hardware provenance reuses run {task_run_id}"
                        )
                    archived_hardware_runs.add(task_run_id)
                    claim = archived_claims.get(str(run.get("claimId")))
                    packet = archived_tasks.get(str(run.get("taskId")))
                    claim_path = archived_claim_paths.get(
                        str(run.get("claimId"))
                    )
                    lab_path = (
                        claim_path.with_name("lab-execution-authorization.json")
                        if claim_path
                        else None
                    )
                    plan_path = (
                        claim_path.with_name("lab-execution-plan.json")
                        if claim_path
                        else None
                    )
                    lab = (
                        _load_json_relative(root, lab_path, [])
                        if lab_path and lab_path.is_file()
                        else None
                    )
                    plan = (
                        _load_json_relative(root, plan_path, [])
                        if plan_path and plan_path.is_file()
                        else None
                    )
                    if not (
                        packet
                        and packet.get("executionEnvironment")
                        == "controlledHardwareLab"
                        and claim
                        and lab
                        and plan
                    ):
                        errors.append(
                            f"archived controlled-lab run {run_id} lacks its immutable plan/authorization provenance bundle"
                        )
                        continue
                    target = plan.get("target", {})
                    real_records = [
                        item
                        for item in run.get("workflowExecutionRecords", [])
                        if item.get("disposition") == "executed"
                        and item.get("bindingRequirement") == "confirmedDevice"
                        and item.get("effect") != "hostOnly"
                    ]
                    run_evidence = next(
                        (
                            item
                            for item in run.get("evidence", [])
                            if item.get("evidenceId")
                            == hardware_doc.get("runEvidenceId")
                        ),
                        None,
                    )
                    hardware_approval = approvals.get(
                        hardware_doc.get("approvalId")
                    )
                    hardware_observed = _parse_time(
                        hardware_doc.get("observedAt")
                    )
                    hardware_valid_until = _parse_time(
                        hardware_doc.get("validUntil")
                    )
                    hardware_approved_at = (
                        _parse_time(hardware_approval.get("approvedAt"))
                        if hardware_approval
                        else None
                    )
                    acceptance_ids = sorted(
                        item.get("acceptanceId")
                        for item in run.get("acceptanceResults", [])
                        if item.get("result") == "passed"
                        and hardware_id in item.get("hardwareMatrixRefs", [])
                    )
                    bindings = hardware_doc.get(
                        "acceptanceCaseBindings", []
                    )
                    bindings_valid = sorted(
                        item.get("acceptanceId") for item in bindings
                    ) == acceptance_ids and all(
                        (
                            definition := archive_case_definitions.get(
                                binding.get("acceptanceId")
                            )
                        )
                        and binding.get("testId")
                        == definition.get("test_id")
                        and binding.get("method") == definition.get("method")
                        and binding.get("minimumEvidence")
                        == definition.get("minimum_evidence")
                        and binding.get("hardwareCapability")
                        == definition.get("hardware_capability")
                        and binding.get("definitionSha256")
                        == support.acceptance_case_contract_sha256(
                            binding.get("acceptanceId"), definition
                        )
                        for binding in bindings
                    )
                    historical_platform_context = (
                        support.platform_context_for_task(
                            run.get("resultRevision"), packet, root=root
                        )
                    )
                    archived_capabilities = sorted(
                        {
                            definition.get("hardware_capability")
                            for acceptance_id in acceptance_ids
                            if (
                                definition := archive_case_definitions.get(
                                    acceptance_id
                                )
                            )
                            and definition.get("hardware_capability")
                        }
                    )
                    archived_run_started = _parse_time(run.get("startedAt"))
                    archived_run_ended = _parse_time(run.get("endedAt"))
                    exact_run_evidence_refs = all(
                        hardware_doc.get("runEvidenceId")
                        in acceptance_result.get("evidenceIds", [])
                        and hardware_id
                        in acceptance_result.get("hardwareMatrixRefs", [])
                        for acceptance_result in run.get(
                            "acceptanceResults", []
                        )
                        if acceptance_result.get("acceptanceId")
                        in acceptance_ids
                    )
                    hardware_valid = bool(
                        hardware_doc.get("status") == "verified"
                        and task_run_id == run_id
                        and run.get("status") == "done"
                        and hardware_doc.get("implementationRevision")
                        == run.get("resultRevision")
                        and hardware_doc.get("labAuthorizationId")
                        == lab.get("authorizationId")
                        and hardware_doc.get("executionPlanSha256")
                        == lab.get("planSha256")
                        and run.get("executionPlanSha256")
                        == lab.get("planSha256")
                        and plan_path
                        and plan_path.is_file()
                        and _sha(plan_path) == lab.get("planSha256")
                        and hardware_doc.get("executionAuthority")
                        == "controlledHardwareLab"
                        and hardware_doc.get("transport")
                        == target.get("transport")
                        and support.dig(hardware_doc, "device", "identity")
                        == target.get("deviceIdentity")
                        and support.dig(
                            hardware_doc, "device", "bindingRevision"
                        )
                        == target.get("bindingRevision")
                        and support.dig(hardware_doc, "device", "build")
                        == target.get("firmware")
                        and support.dig(
                            hardware_doc, "toolchain", "hdcSha256"
                        )
                        == target.get("hdcExecutableSha256")
                        and support.dig(
                            hardware_doc, "toolchain", "clientVersion"
                        )
                        == target.get("hdcClientVersion")
                        and support.dig(
                            hardware_doc, "toolchain", "serverVersion"
                        )
                        == target.get("hdcServerVersion")
                        and support.dig(
                            hardware_doc, "toolchain", "daemonVersion"
                        )
                        == target.get("hdcDaemonVersion")
                        and support.dig(
                            hardware_doc, "toolchain", "serverEndpoint"
                        )
                        == target.get("hdcServerEndpoint")
                        and support.dig(
                            hardware_doc, "toolchain", "serverGeneration"
                        )
                        == target.get("hdcServerGeneration")
                        and support.dig(hardware_doc, "provider", "id")
                        == target.get("providerId")
                        and support.dig(hardware_doc, "provider", "version")
                        == target.get("providerVersion")
                        and sorted(hardware_doc.get("stepKinds", []))
                        == sorted(
                            set(item.get("kind") for item in real_records)
                        )
                        and sorted(
                            set(hardware_doc.get("capabilities", []))
                        )
                        == archived_capabilities
                        and run.get("realDeviceDispatchCount", 0) > 0
                        and len(real_records)
                        == run.get("realDeviceDispatchCount")
                        and run_evidence
                        and run_evidence.get("classification")
                        == "realHardware"
                        and run_evidence.get("locationKind")
                        == "controlledExternal"
                        and run_evidence.get("sha256")
                        == support.dig(hardware_doc, "artifact", "sha256")
                        and run_evidence.get("location")
                        == support.dig(hardware_doc, "artifact", "location")
                        and acceptance_ids
                        == sorted(hardware_doc.get("acceptanceIds", []))
                        and bindings_valid
                        and exact_run_evidence_refs
                        and historical_platform_context
                        and hardware_doc.get(
                            "platformCaseManifestSha256"
                        )
                        == support.dig(
                            historical_platform_context,
                            "entry",
                            "case_manifest_sha256",
                        )
                        and hardware_doc.get("hostSupportCellId")
                        in [
                            cell.get("id")
                            for cell in support.dig(
                                historical_platform_context,
                                "caseDocument",
                                "support_cells",
                            )
                            or []
                        ]
                        and hardware_approval
                        and hardware_approval.get("subjectType")
                        == "hardwareEvidence"
                        and hardware_approval.get("subjectId")
                        == hardware_id
                        and hardware_approval.get("subjectSha256")
                        == _sha(hardware_path)
                        and hardware_approval.get("baseRevision")
                        == run.get("resultRevision")
                        and hardware_approval.get("decision") == "approved"
                        and hardware_observed
                        and hardware_valid_until
                        and hardware_approved_at
                        and archived_run_started
                        and archived_run_ended
                        and archived_run_started
                        <= hardware_observed
                        <= archived_run_ended
                        and hardware_observed
                        <= hardware_approved_at
                        <= hardware_valid_until
                        and support.externally_verified(
                            approval_paths.get(
                                str(hardware_approval.get("approvalId"))
                            ),
                            hardware_path,
                            hardware_approval,
                            verifiers,
                            root=root,
                        )
                    )
                    if not hardware_valid:
                        errors.append(
                            f"verified hardware evidence {hardware_id} is not bound to its approved lab run/plan/target"
                        )
        for packet in archived_tasks.values():
            if packet.get("approvalId"):
                archive_approval_ids.add(str(packet["approvalId"]))
        for approval_id in archive_approval_ids:
            approval_path = approval_paths.get(approval_id)
            if approval_path and approval_path.is_file():
                provenance[_relative(root, approval_path)] = _sha(approval_path)
        aggregate_valid = aggregate_base_exact and support.validate_task_result_aggregate(
            errors=errors,
            subject=f"archive {archive_relative} verification result",
            base_revision=aggregate_base,
            result_revision=verification,
            runs=bound_runs,
            provenance_files=provenance,
            root=root,
        )
        if not aggregate_valid:
            errors.append(
                f"archive {archive_relative} verification aggregate provenance is invalid"
            )
        baseline_versions = sorted(
            {
                support.dig(packet, "coreBaseline", "version")
                for packet in archived_tasks.values()
                if support.dig(packet, "coreBaseline", "version")
            }
        )
        if len(baseline_versions) != 1:
            errors.append(
                f"archive {archive_relative} Tasks do not share one pinned Core baseline version"
            )
        prerequisite_specs = [
            (
                "openspec/governance/trust-policy.yaml",
                "trustPolicy",
                "policy",
            ),
            (
                "openspec/integrations/INTEGRATION-PROFILES.lock.yaml",
                "integrationLock",
                "lock",
            ),
            (
                "openspec/platforms/PLATFORM-PROFILES.lock.yaml",
                "platformLock",
                "lock",
            ),
            (
                "openspec/verification/core-conformance.yaml",
                "conformanceSuite",
                "suite",
            ),
        ]
        if len(baseline_versions) == 1:
            prerequisite_specs.append(
                (
                    f"openspec/baselines/CORE-{baseline_versions[0]}.lock.yaml",
                    "baseline",
                    "baseline",
                )
            )
        historical_prerequisites: dict[str, dict[str, Any]] = {}
        for prerequisite_path, subject_type, id_field in prerequisite_specs:
            prerequisite_source = support.git_file_content(
                verification, prerequisite_path, root=root
            )
            try:
                prerequisite_doc = support.yaml_safe_load(
                    prerequisite_source or ""
                ) or {}
            except ValueError:
                prerequisite_doc = {}
                errors.append(
                    f"archive {archive_relative} cannot parse historical prerequisite {prerequisite_path}"
                )
            prerequisite_approval = approvals.get(
                support.dig(prerequisite_doc, "ratification", "approval_ref")
            )
            accepted = prerequisite_doc.get("status") == "accepted" and (
                prerequisite_doc.get("execution_gate") == "open"
                or support.dig(
                    prerequisite_doc, "ratification", "execution_gate"
                )
                == "open"
            )
            exact = bool(
                prerequisite_source
                and accepted
                and support.valid_historical_approval(
                    source=prerequisite_source,
                    subject_name=Path(prerequisite_path).name,
                    document=prerequisite_doc,
                    approval=prerequisite_approval,
                    approval_path=approval_paths.get(
                        str(prerequisite_approval.get("approvalId"))
                    )
                    if prerequisite_approval
                    else None,
                    subject_type=subject_type,
                    subject_id=str(prerequisite_doc.get(id_field)),
                    result_revision=verification,
                    verifiers=verifiers,
                    root=root,
                )
            )
            if not exact:
                errors.append(
                    f"archive {archive_relative} historical prerequisite {prerequisite_path} is not exact, accepted and externally verified"
                )
            historical_prerequisites[prerequisite_path] = {
                "source": prerequisite_source,
                "document": prerequisite_doc,
                "valid": exact,
            }
        for task_id, packet in archived_tasks.items():
            baseline_key = (
                f"openspec/baselines/CORE-{support.dig(packet, 'coreBaseline', 'version')}.lock.yaml"
            )
            baseline_record = historical_prerequisites.get(baseline_key, {})
            integration_record = historical_prerequisites.get(
                "openspec/integrations/INTEGRATION-PROFILES.lock.yaml", {}
            )
            platform_record = historical_prerequisites.get(
                "openspec/platforms/PLATFORM-PROFILES.lock.yaml", {}
            )
            conformance_record = historical_prerequisites.get(
                "openspec/verification/core-conformance.yaml", {}
            )
            exact_core = bool(
                baseline_record.get("valid")
                and f"{support.dig(packet, 'coreBaseline', 'id')}-{support.dig(packet, 'coreBaseline', 'version')}"
                == support.dig(baseline_record, "document", "baseline")
                and support.dig(packet, "coreBaseline", "sha256")
                == hashlib.sha256(
                    (baseline_record.get("source") or "").encode("utf-8")
                ).hexdigest()
            )
            exact_conformance = bool(
                conformance_record.get("valid")
                and support.dig(packet, "conformanceSuite", "id")
                == support.dig(conformance_record, "document", "suite")
                and support.dig(packet, "conformanceSuite", "sha256")
                == hashlib.sha256(
                    (conformance_record.get("source") or "").encode("utf-8")
                ).hexdigest()
            )
            platform_entry = next(
                (
                    item
                    for item in support.dig(
                        platform_record, "document", "profiles"
                    )
                    or []
                    if item.get("id")
                    == support.dig(packet, "platformProfile", "id")
                    and item.get("version")
                    == support.dig(packet, "platformProfile", "version")
                ),
                None,
            )
            exact_platform = bool(
                platform_entry
                and packet.get("platform") == platform_entry.get("platform")
                and support.dig(packet, "platformProfile", "sha256")
                == platform_entry.get("profile_sha256")
                and support.git_file_sha256(
                    verification,
                    str(platform_entry.get("profile_path")),
                    root=root,
                )
                == platform_entry.get("profile_sha256")
            )
            integration_entries = support.dig(
                integration_record, "document", "profiles"
            ) or []
            exact_integration = all(
                (
                    entry := next(
                        (
                            item
                            for item in integration_entries
                            if item.get("id") == pin.get("id")
                            and item.get("version") == pin.get("version")
                        ),
                        None,
                    )
                )
                and pin.get("sha256") == entry.get("sha256")
                and support.git_file_sha256(
                    verification, str(entry.get("path")), root=root
                )
                == entry.get("sha256")
                for pin in packet.get("integrationProfiles", [])
            )
            if not (exact_core and exact_conformance and exact_platform and exact_integration):
                errors.append(
                    f"archive {archive_relative} Task {task_id} pins do not resolve exactly in verification_revision"
                )

        valid_shape = bool(
            lock.get("status") == "archived"
            and lock.get("change_id") == change_id
            and lock.get("revision") == proposal.get("revision")
            and source_lock.is_file()
            and lock.get("source_change_lock_sha256") == _sha(source_lock)
            and pre_valid
            and baseline_integrity
            and staged_exact
            and rs_valid
            and st_valid
            and behavior_transition
            and acceptance_transition
        )
        if not valid_shape:
            errors.append(
                f"archive {archive_relative} lock does not bind its approved source/result"
            )
        baseline_approval = approvals.get(
            support.dig(baseline_doc, "ratification", "approval_ref")
        )
        baseline_changed = bool(
            baseline_relative
            and support.git_file_sha256(source, baseline_relative, root=root)
            != support.git_file_sha256(result, baseline_relative, root=root)
        )
        baseline_approval_base_valid = bool(
            baseline_approval
            and support.git_commit(
                baseline_approval.get("baseRevision"), root=root
            )
            and support.git_ancestor(
                baseline_approval.get("baseRevision"), result, root=root
            )
            and (
                not baseline_changed
                or baseline_approval.get("baseRevision") == result
            )
        )
        valid_baseline_approval = bool(
            baseline_path
            and baseline_path.is_file()
            and baseline_approval
            and baseline_approval.get("subjectType") == "baseline"
            and baseline_approval.get("subjectId") == baseline_doc.get("baseline")
            and baseline_approval.get("subjectRevision") == baseline_doc.get("revision")
            and baseline_approval.get("subjectSha256") == _sha(baseline_path)
            and baseline_approval_base_valid
            and baseline_approval.get("decision") == "approved"
            and support.externally_verified(
                approval_paths.get(str(baseline_approval.get("approvalId"))),
                baseline_path,
                baseline_approval,
                verifiers,
                root=root,
            )
        )
        if not valid_baseline_approval:
            errors.append(f"archive {archive_relative} result baseline is not externally ratified")
        terminal_times = [
            value
            for run in archived_runs.values()
            if (value := _parse_time(run.get("endedAt")))
        ]
        verification_approved_at = (
            _parse_time(verification_approval.get("approvedAt"))
            if verification_approval
            else None
        )
        if terminal_times and (
            not pre_validated or pre_validated < max(terminal_times)
        ):
            errors.append(
                f"archive {archive_relative} pre-move semantic attestation predates a terminal run"
            )
        if verification_approved_at and (
            not pre_validated or pre_validated < verification_approved_at
        ):
            errors.append(
                f"archive {archive_relative} pre-move semantic attestation predates change verification approval"
            )

        archive_approval = approvals.get(lock.get("approval_id"))
        archive_approved_at = (
            _parse_time(archive_approval.get("approvedAt"))
            if archive_approval
            else None
        )
        baseline_approved_at = (
            _parse_time(baseline_approval.get("approvedAt"))
            if baseline_approval
            else None
        )
        change_approved_at = (
            _parse_time(change_approval.get("approvedAt"))
            if change_approval
            else None
        )
        prerequisite_times = [
            pre_validated,
            pre_approved,
            verification_approved_at,
            baseline_approved_at,
            change_approved_at,
        ]
        valid_archive_chronology = bool(
            archive_approved_at
            and all(prerequisite_times)
            and archive_approved_at >= max(prerequisite_times)
        )
        archive_successors = [
            successor
            for successor in change_records.values()
            if successor.get("approved")
            and support.dig(successor, "proposal", "supersedes_change_id")
            == change_id
            and successor.get("approved_at")
        ]
        effective_archive_successor = (
            min(archive_successors, key=lambda item: item["approved_at"])
            if archive_successors
            else None
        )
        if (
            effective_archive_successor
            and archive_approved_at
            and archive_approved_at
            >= effective_archive_successor["approved_at"]
        ):
            errors.append(
                f"superseded Change {change_id} was archived after successor {support.dig(effective_archive_successor, 'proposal', 'id')} became effective"
            )
            valid_archive_chronology = False
        valid_archive_approval = bool(
            archive_approval
            and archive_approval.get("subjectType") == "archive"
            and archive_approval.get("subjectId") == change_id
            and archive_approval.get("subjectRevision") == proposal.get("revision")
            and archive_approval.get("subjectSha256") == _sha(path)
            and archive_approval.get("baseRevision") == result
            and archive_approval.get("decision") == "approved"
            and valid_archive_chronology
            and support.externally_verified(
                approval_paths.get(str(archive_approval.get("approvalId"))),
                path,
                archive_approval,
                verifiers,
                root=root,
            )
        )
        if not valid_archive_approval:
            errors.append(f"archive {archive_relative} has no externally verified archive approval")

        additions = support.git_path_add_commits(result, head, _relative(root, path), root=root) or []
        publication = additions[0] if len(additions) == 1 else None
        publication_ids = [lock.get("approval_id")]
        baseline_path = _repo_path(root, lock.get("result_core_baseline", {}).get("path"))
        baseline_doc = {}
        if baseline_path and baseline_path.is_file():
            baseline_doc = support.yaml_safe_load(baseline_path.read_text(encoding="utf-8")) or {}
            publication_ids.append(support.dig(baseline_doc, "ratification", "approval_ref"))
        for axis in (
            root / "openspec/platforms/PLATFORM-PROFILES.lock.yaml",
            root / "openspec/verification/core-conformance.yaml",
        ):
            axis_source = support.git_file_content(result, _relative(root, axis), root=root)
            if axis_source:
                try:
                    axis_doc = support.yaml_safe_load(axis_source) or {}
                    publication_ids.append(support.dig(axis_doc, "ratification", "approval_ref"))
                except ValueError:
                    publication = None
        publication_paths = [_relative(root, path)]
        for approval_id in set(value for value in publication_ids if value):
            approval_path = approval_paths.get(str(approval_id))
            if approval_path and support.git_file_content(
                result, _relative(root, approval_path), root=root
            ) is None:
                publication_paths.append(_relative(root, approval_path))
        expected_tp = sorted(
            ({"status": "A", "path": item} for item in set(publication_paths)),
            key=lambda item: item["path"],
        )
        actual_tp = support.git_diff_entries(result, publication, root=root) if publication else None
        files_exact = bool(
            publication
            and all(
                (root / item).is_file()
                and support.git_file_sha256(publication, item, root=root) == _sha(root / item)
                for item in publication_paths
            )
        )
        if not (
            publication
            and support.git_commit(publication, root=root)
            and support.git_ancestor(result, publication, root=root)
            and support.git_ancestor(publication, head, root=root)
            and actual_tp == expected_tp
            and files_exact
        ):
            errors.append(
                f"archive {archive_relative} publication commit is missing, ambiguous or contains non-metadata changes"
            )


def run_lifecycle_guard(
    root: Path, errors: list[str], context: dict[str, Any]
) -> dict[str, Any]:
    """Validate immutable execution and publication state after Core parsing."""

    root = root.resolve()
    support.run_helper_self_tests(errors)
    schemas = _load_schemas(root, errors)
    approvals, approval_paths = _collect_approvals(root, schemas, errors)
    _policy, verifiers, trust_open = _trust_context(root, context)
    records = _collect_change_records(root, approvals, approval_paths, verifiers, errors)
    _validate_change_lineage(
        root, records, approvals, approval_paths, verifiers, errors
    )
    overlays = context.get("behavior_overlays", {})
    local_cases = context.get("platform_acceptance", {})
    tasks, task_paths = _validate_tasks(
        root,
        context,
        records,
        approvals,
        approval_paths,
        verifiers,
        trust_open,
        schemas,
        errors,
    )
    scopes = _validate_scope_and_task_union(
        root, context, records, tasks, local_cases, overlays, errors
    )
    claims, runs = _validate_claims_and_runs(
        root,
        context,
        tasks,
        task_paths,
        approvals,
        approval_paths,
        verifiers,
        schemas,
        errors,
    )
    _validate_live_change_lifecycle(
        root,
        context,
        records,
        tasks,
        task_paths,
        claims,
        runs,
        scopes,
        approvals,
        approval_paths,
        verifiers,
        errors,
    )
    _validate_claim_schedule(tasks, claims, runs, records, errors)
    approved_hardware, verified_hardware = _validate_hardware_evidence(
        root,
        context,
        tasks,
        runs,
        approvals,
        approval_paths,
        verifiers,
        schemas,
        errors,
    )
    _validate_archives(
        root,
        schemas,
        records,
        approvals,
        approval_paths,
        verifiers,
        errors,
    )
    return {
        "approvals": approvals,
        "approval_paths": approval_paths,
        "versioned_schemas": {schema_id: value[1] for schema_id, value in schemas.items()},
        "trust_policy": _policy,
        "trust_policy_path": root / "openspec/governance/trust-policy.yaml",
        "external_trust_root": context.get("external_trust_root"),
        "external_trust_root_valid": context.get("external_trust_root_valid", False),
        "trusted_verifiers": verifiers,
        "tasks": tasks,
        "task_paths": task_paths,
        "claims": claims,
        "runs": runs,
        "change_records": records,
        "change_scopes": scopes,
        "behavior_overlays": overlays,
        "local_case_definitions": local_cases,
        "schemas": schemas,
        "hardware_evaluation_time": _parse_time(os.environ.get("ARKDECK_EVALUATION_TIME"))
        if os.environ.get("ARKDECK_EVALUATION_TIME")
        else None,
        "approved_hardware": approved_hardware,
        "verified_hardware": verified_hardware,
    }


__all__ = ["run_lifecycle_guard"]
