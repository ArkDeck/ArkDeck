#!/usr/bin/env python3.14
"""Direct-Python Core SDD guard for ArkDeck.

This module contains the parser-independent, repository-tree portion of the
SDD guard.  It deliberately does not invoke Ruby.  ``run_core_guard`` mutates
the supplied error list and returns the parsed Core context used by the deeper
Task/claim/run checks in ``check_sdd.py``.
"""

from __future__ import annotations

from collections import defaultdict
from collections.abc import Iterable, Mapping, MutableSequence
from hashlib import sha256
from pathlib import Path
import json
import os
import re
from typing import Any

import yaml
from yaml.nodes import MappingNode, Node, ScalarNode, SequenceNode
from yaml.tokens import AliasToken, AnchorToken

from sdd_guard_support import (
    ACCEPTANCE_EVIDENCE_CLASSES,
    CORE_ACCEPTANCE_ID,
    PLATFORM_ACCEPTANCE_ID,
    acceptance_case_contract_sha256,
    build_behavior_overlay,
    markdown_frontmatter,
    require_runtime,
)
from sdd_protected_set import sdd_protected_files


REQUIREMENT_RE = re.compile(r"^### Requirement: (REQ-[A-Z0-9-]+)\b", re.MULTILINE)
ACCEPTANCE_RE = re.compile(r"^#### Scenario: (AC-[A-Z0-9-]+)\b", re.MULTILINE)
POLICY_RE = re.compile(r"^## (POL-[A-Z0-9-]+)\b", re.MULTILINE)
PORT_ID_RE = re.compile(r"`(PORT-[A-Z0-9-]+)`")
PORT_ROW_RE = re.compile(
    r"^\| `(PORT-[A-Z0-9-]+)` \| `([A-Za-z][A-Za-z0-9]+)` \| (.+) \|\s*$"
)
HEX_SHA256_RE = re.compile(r"^[a-f0-9]{64}$")
PLATFORM_CASE_ID_RE = re.compile(r"^[A-Z][A-Z0-9-]+$")
TEST_ID_RE = re.compile(r"^TEST-[A-Z0-9-]+$")
HARDWARE_CAPABILITIES = {"hdcConnectivity", "uiDump", "trace", "debug", "flash"}
CONFORMANCE_STATES = {"notStarted", "verified", "needsReverification", "nonConformant"}
REVALIDATION_DISPOSITIONS = {"reverifyRequired", "nonConformant", "deferred"}
LAST_VERIFIED_FIELDS = {
    "approval_id",
    "case_manifest_sha256",
    "conformance_suite_sha256",
    "core_baseline",
    "core_baseline_sha256",
    "evidence_path",
    "evidence_sha256",
    "integration_lock_sha256",
    "profile_sha256",
    "release_subject_approval_id",
    "release_subject_path",
    "release_subject_sha256",
    "support_matrix_sha256",
    "valid_until",
    "verification_sha256",
}


def _mapping(value: Any) -> dict[str, Any]:
    return dict(value) if isinstance(value, Mapping) else {}


def _sequence(value: Any) -> list[Any]:
    return list(value) if isinstance(value, list) else []


def _all_unique(values: Iterable[Any]) -> bool:
    """Ruby-compatible uniqueness for possibly malformed collection values."""

    unique: list[Any] = []
    for value in values:
        if value in unique:
            return False
        unique.append(value)
    return True


def _relative(root: Path, path: Path) -> str:
    try:
        return path.resolve().relative_to(root).as_posix()
    except ValueError:
        return str(path)


def _sha256_file(path: Path) -> str:
    digest = sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _repo_path(root: Path, relative_path: Any) -> Path | None:
    value = str(relative_path or "")
    if not value or Path(value).is_absolute():
        return None
    candidate = (root / value).resolve()
    try:
        candidate.relative_to(root)
    except ValueError:
        return None
    return candidate


def _node_location(node: Node, fallback: str) -> str:
    mark = getattr(node, "start_mark", None)
    if mark is None:
        return fallback
    return f"{fallback}@{mark.line + 1}:{mark.column + 1}"


def yaml_ambiguities(source: str) -> list[str]:
    """Return constructs that can give approved YAML bytes multiple meanings."""

    findings: list[str] = []
    try:
        for token in yaml.scan(source):
            if isinstance(token, AliasToken):
                findings.append(
                    f"$yaml@{token.start_mark.line + 1}:{token.start_mark.column + 1}: "
                    "YAML aliases are forbidden"
                )
            elif isinstance(token, AnchorToken):
                findings.append(
                    f"$yaml@{token.start_mark.line + 1}:{token.start_mark.column + 1}: "
                    "YAML anchors are forbidden"
                )
        documents = list(yaml.compose_all(source, Loader=yaml.BaseLoader))
    except yaml.YAMLError:
        # Syntax is reported by the semantic loader with its filename.  Do not
        # duplicate a less useful parser error here.
        return findings

    if len(documents) != 1:
        findings.append("$yaml: exactly one YAML document is required")

    def visit(node: Node | None, location: str) -> None:
        if node is None:
            return
        if isinstance(node, MappingNode):
            seen: set[str] = set()
            for index, (key, value) in enumerate(node.value):
                key_location = f"{location}/key[{index}]"
                if not isinstance(key, ScalarNode):
                    findings.append(
                        f"{_node_location(key, key_location)}: mapping keys must be scalars"
                    )
                else:
                    key_name = str(key.value)
                    named_location = f"{location}/{key_name}"
                    if key_name in seen:
                        findings.append(
                            f"{_node_location(key, named_location)}: duplicate YAML mapping key"
                        )
                    if key_name == "<<":
                        findings.append(
                            f"{_node_location(key, named_location)}: YAML merge keys are forbidden"
                        )
                    seen.add(key_name)
                visit(key, key_location)
                visit(value, f"{location}/value[{index}]")
        elif isinstance(node, SequenceNode):
            for index, child in enumerate(node.value):
                visit(child, f"{location}[{index}]")

    for index, document in enumerate(documents):
        visit(document, f"$yaml/document[{index}]/root")
    return findings


def _load_yaml(
    root: Path,
    path: Path,
    errors: MutableSequence[str],
    documents: dict[str, Any],
    *,
    required: bool = True,
) -> Any:
    relative = _relative(root, path)
    if not path.is_file():
        if required:
            errors.append(f"YAML file is missing: {relative}")
        return {}
    try:
        source = path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as exc:
        errors.append(f"cannot read YAML {relative}: {exc}")
        return {}
    findings = yaml_ambiguities(source)
    if findings:
        # The preflight normally already emitted these.  Avoid duplicate errors.
        if not any(str(item).startswith(f"ambiguous YAML {relative}:") for item in errors):
            errors.extend(f"ambiguous YAML {relative}: {item}" for item in findings)
        return {}
    try:
        value = yaml.safe_load(source)
    except yaml.YAMLError as exc:
        errors.append(f"invalid YAML {relative}: {exc}")
        return {}
    documents[relative] = value
    return value if value is not None else {}


def _frontmatter(source: str) -> str | None:
    match = re.match(r"\A---\s*\n(.*?)\n---\s*\n", source, re.DOTALL)
    return match.group(1) if match else None


def _scan_serialized_inputs(root: Path, errors: MutableSequence[str]) -> None:
    """Run ambiguity checks before any Core lock is semantically constructed."""

    for path in sorted((root / "openspec").rglob("*")):
        if not path.is_file():
            continue
        relative = _relative(root, path)
        if path.suffix.lower() in {".yaml", ".yml"}:
            try:
                source = path.read_text(encoding="utf-8")
                findings = yaml_ambiguities(source)
                errors.extend(f"ambiguous YAML {relative}: {item}" for item in findings)
                if not findings:
                    yaml.safe_load(source)
            except yaml.YAMLError as exc:
                errors.append(f"invalid YAML {relative}: {exc}")
            except (OSError, UnicodeError) as exc:
                errors.append(f"cannot read YAML {relative}: {exc}")
        elif path.suffix.lower() == ".json":
            try:
                json.loads(path.read_text(encoding="utf-8"))
            except (json.JSONDecodeError, OSError, UnicodeError) as exc:
                errors.append(f"invalid JSON {relative}: {exc}")

    markdown_paths = [root / "AGENTS.md"]
    markdown_paths.extend(sorted((root / "docs").rglob("*.md")) if (root / "docs").is_dir() else [])
    markdown_paths.extend(sorted((root / "openspec").rglob("*.md")))
    for path in markdown_paths:
        if not path.is_file():
            continue
        relative = _relative(root, path)
        try:
            source = path.read_text(encoding="utf-8")
        except (OSError, UnicodeError) as exc:
            errors.append(f"cannot read Markdown {relative}: {exc}")
            continue
        frontmatter = _frontmatter(source)
        if frontmatter is not None:
            findings = yaml_ambiguities(frontmatter)
            errors.extend(f"ambiguous front matter {relative}: {item}" for item in findings)
            if not findings:
                try:
                    yaml.safe_load(frontmatter)
                except yaml.YAMLError as exc:
                    errors.append(f"invalid front matter {relative}: {exc}")
        fence_count = sum(1 for line in source.splitlines() if line.startswith("```"))
        if fence_count % 2:
            errors.append(f"unbalanced Markdown fence {relative}")


def _validate_trust_policy(
    root: Path,
    errors: MutableSequence[str],
    documents: dict[str, Any],
) -> dict[str, Any]:
    policy_path = root / "openspec/governance/trust-policy.yaml"
    trust_policy = _mapping(_load_yaml(root, policy_path, errors, documents))
    trusted_verifiers: list[Any] = []
    external_trust_root: dict[str, Any] | None = None
    external_trust_root_valid = False
    location = os.environ.get("ARKDECK_TRUST_ROOT_BUNDLE", "")
    if location:
        raw_path = Path(location)
        outside_repository = False
        if raw_path.is_absolute():
            try:
                raw_path.resolve().relative_to(root)
            except ValueError:
                outside_repository = True
        if not outside_repository or not raw_path.is_file():
            errors.append(
                "external trust-root bundle must be an existing absolute path "
                "outside the repository"
            )
        else:
            try:
                source = raw_path.read_text(encoding="utf-8")
                findings = yaml_ambiguities(source)
                errors.extend(
                    f"ambiguous external trust-root YAML: {finding}"
                    for finding in findings
                )
                external_trust_root = (
                    _mapping(yaml.safe_load(source)) if not findings else {}
                )
                declared = _sequence(trust_policy.get("external_verifiers"))
                rooted = _sequence(external_trust_root.get("external_verifiers"))
                policy_hash_matches = (
                    policy_path.is_file()
                    and external_trust_root.get("trust_policy_sha256")
                    == _sha256_file(policy_path)
                )
                root_id_matches = bool(
                    str(external_trust_root.get("root_id") or "")
                    and trust_policy.get("bootstrap_root_id")
                    == external_trust_root.get("root_id")
                )
                repository_id_present = bool(
                    str(external_trust_root.get("repository_id") or "")
                )
                verifier_set_matches = declared == rooted and bool(rooted)
                external_trust_root_valid = bool(
                    policy_hash_matches
                    and root_id_matches
                    and repository_id_present
                    and verifier_set_matches
                )
                if not external_trust_root_valid:
                    errors.append(
                        "external trust-root bundle does not bind this policy and "
                        "verifier set"
                    )
                if external_trust_root_valid:
                    trusted_verifiers = rooted
            except (yaml.YAMLError, OSError, UnicodeError) as exc:
                errors.append(f"invalid external trust-root bundle: {exc}")

    if trust_policy.get("status") == "accepted":
        if trust_policy.get("execution_gate") != "open":
            errors.append("accepted trust policy gate must be open")
    elif trust_policy.get("execution_gate") != "closed":
        errors.append("unaccepted trust policy gate must be closed")
    return {
        "trust_policy": trust_policy,
        "trusted_verifiers": trusted_verifiers,
        "external_trust_root": external_trust_root,
        "external_trust_root_valid": external_trust_root_valid,
    }


def canonical_markdown_block(
    text: str, heading_pattern: re.Pattern[str], following_heading_pattern: re.Pattern[str]
) -> str | None:
    start = heading_pattern.search(text)
    if not start:
        return None
    tail = text[start.start() :]
    following = following_heading_pattern.search(tail, len(start.group(0)))
    block = tail[: following.start()] if following else tail
    return block.rstrip() + "\n"


def _extract_specs(root: Path, errors: MutableSequence[str]) -> dict[str, Any]:
    requirements: defaultdict[str, list[str]] = defaultdict(list)
    acceptance: defaultdict[str, list[str]] = defaultdict(list)
    requirement_acceptance: dict[str, list[str]] = {}
    acceptance_owner: dict[str, str] = {}
    requirement_paths: dict[str, str] = {}
    requirement_records: dict[str, dict[str, Any]] = {}

    for path in sorted((root / "openspec/specs").glob("**/spec.md")):
        relative = _relative(root, path)
        text = path.read_text(encoding="utf-8")
        requirement_matches = list(REQUIREMENT_RE.finditer(text))
        for match in requirement_matches:
            requirements[match.group(1)].append(relative)
        for match in ACCEPTANCE_RE.finditer(text):
            acceptance[match.group(1)].append(relative)

        for index, match in enumerate(requirement_matches):
            requirement_id = match.group(1)
            end = len(text)
            following = re.search(r"^#{1,3} ", text[match.end() :], re.MULTILINE)
            if following:
                end = match.end() + following.start()
            block = text[match.start() : end].rstrip() + "\n"
            scenario_ids = ACCEPTANCE_RE.findall(block)
            if requirement_id not in requirement_acceptance:
                requirement_acceptance[requirement_id] = scenario_ids
                requirement_paths[requirement_id] = relative
                requirement_records[requirement_id] = {
                    "path": relative,
                    "block_sha256": sha256(block.encode("utf-8")).hexdigest(),
                    "acceptance": scenario_ids,
                }
            if not scenario_ids:
                errors.append(f"{requirement_id} has no Scenario in {relative}")
            for acceptance_id in scenario_ids:
                prior = acceptance_owner.get(acceptance_id)
                if prior and prior != requirement_id:
                    errors.append(
                        f"Acceptance {acceptance_id} belongs to both {prior} and {requirement_id}"
                    )
                else:
                    acceptance_owner[acceptance_id] = requirement_id

    for requirement_id, paths in requirements.items():
        if len(paths) > 1:
            errors.append(f"duplicate Requirement {requirement_id}: {', '.join(paths)}")
    for acceptance_id, paths in acceptance.items():
        if len(paths) > 1:
            errors.append(f"duplicate Acceptance {acceptance_id}: {', '.join(paths)}")

    return {
        "requirements": dict(requirements),
        "acceptance": dict(acceptance),
        "requirement_acceptance": requirement_acceptance,
        "acceptance_owner": acceptance_owner,
        "requirement_paths": requirement_paths,
        "requirement_records": requirement_records,
    }


def _walk_hash_entries(value: Any) -> Iterable[dict[str, Any]]:
    if isinstance(value, Mapping):
        if "path" in value and "sha256" in value:
            yield dict(value)
        for child in value.values():
            yield from _walk_hash_entries(child)
    elif isinstance(value, list):
        for child in value:
            yield from _walk_hash_entries(child)


def _validate_hash_entry(
    root: Path,
    entry: Mapping[str, Any],
    errors: MutableSequence[str],
    subject: str,
    *,
    validate_hash_format: bool = False,
) -> bool:
    relative = str(entry.get("path") or "")
    path = _repo_path(root, relative)
    if path is None or not path.is_file():
        errors.append(f"{subject} path missing: {relative}")
        return False
    expected = entry.get("sha256")
    if validate_hash_format and (
        not isinstance(expected, str) or not HEX_SHA256_RE.fullmatch(expected)
    ):
        errors.append(f"{subject} path has invalid hash: {relative}")
        return False
    if _sha256_file(path) != expected:
        errors.append(f"{subject} hash mismatch: {relative}")
        return False
    return True


def _validate_acceptance_index(
    root: Path, acceptance: Mapping[str, Any], errors: MutableSequence[str]
) -> list[str]:
    path = root / "openspec/verification/acceptance-index.txt"
    if not path.is_file():
        errors.append("acceptance-index.txt is missing")
        return []
    indexed = [
        line
        for line in path.read_text(encoding="utf-8").splitlines()
        if line and not line.startswith("#")
    ]
    if indexed != sorted(indexed):
        errors.append("acceptance-index.txt is not sorted")
    actual = sorted(acceptance)
    missing = sorted(set(actual) - set(indexed))
    extra = sorted(set(indexed) - set(actual))
    if missing:
        errors.append(f"acceptance index missing: {', '.join(missing)}")
    if extra:
        errors.append(f"acceptance index has unknown IDs: {', '.join(extra)}")
    return indexed


def _validate_conformance(
    root: Path,
    errors: MutableSequence[str],
    documents: dict[str, Any],
    acceptance: Mapping[str, Any],
    requirements: Mapping[str, Any],
    policies: Mapping[str, Any],
    acceptance_index: list[str],
) -> tuple[dict[str, Any], dict[str, Any], dict[str, str], list[str]]:
    path = root / "openspec/verification/core-conformance.yaml"
    conformance = _mapping(_load_yaml(root, path, errors, documents))
    case_definitions: dict[str, Any] = {}
    case_minimum_evidence: dict[str, str] = {}
    fixture_ids: list[str] = []
    if not conformance:
        errors.append("Core conformance suite is missing or invalid")
        return conformance, case_definitions, case_minimum_evidence, fixture_ids

    index_entry = _mapping(conformance.get("acceptance_index"))
    index_path = root / "openspec/verification/acceptance-index.txt"
    if index_path.is_file():
        if index_entry.get("sha256") != _sha256_file(index_path):
            errors.append("conformance acceptance-index hash mismatch")
        if index_entry.get("count") != len(acceptance_index):
            errors.append("conformance acceptance-index count mismatch")

    cases_entry = _mapping(conformance.get("acceptance_cases"))
    cases_path = _repo_path(root, cases_entry.get("path"))
    cases_document: dict[str, Any] = {}
    if cases_path is None or not cases_path.is_file():
        errors.append("conformance acceptance cases file is missing")
    else:
        if cases_entry.get("sha256") != _sha256_file(cases_path):
            errors.append("conformance acceptance-cases hash mismatch")
        cases_document = _mapping(_load_yaml(root, cases_path, errors, documents))
        cases = [_mapping(item) for item in _sequence(cases_document.get("cases"))]
        case_ids = [item.get("acceptance_id") for item in cases]
        test_ids = [item.get("test_id") for item in cases]
        if cases_entry.get("count") != len(cases):
            errors.append("acceptance cases count mismatch")
        if sorted(str(item) for item in case_ids) != sorted(acceptance):
            errors.append("acceptance cases do not exactly cover current AC IDs")
        if not _all_unique(case_ids):
            errors.append("acceptance cases contain duplicate AC IDs")
        if not _all_unique(test_ids):
            errors.append("acceptance cases contain duplicate Test IDs")
        allowed_evidence = set(_mapping(cases_document.get("evidence_classes")))
        for item in cases:
            acceptance_id = str(item.get("acceptance_id") or "?")
            case_minimum_evidence[acceptance_id] = str(item.get("minimum_evidence") or "")
            for field in ("acceptance_id", "test_id", "method", "expected_source", "minimum_evidence"):
                if not str(item.get(field) or ""):
                    errors.append(f"acceptance case {acceptance_id} missing {field}")
            evidence = item.get("minimum_evidence")
            if evidence not in allowed_evidence:
                errors.append(f"acceptance case {acceptance_id} has unknown evidence class")
            if evidence == "realHardware":
                if item.get("hardware_capability") not in HARDWARE_CAPABILITIES:
                    errors.append(
                        f"acceptance case {acceptance_id} lacks a closed hardware capability"
                    )
            elif "hardware_capability" in item:
                errors.append(
                    f"non-hardware acceptance case {acceptance_id} declares a hardware capability"
                )

            source_reference = str(item.get("expected_source") or "")
            source_name, separator, anchor = source_reference.partition("#")
            source_path = _repo_path(root, source_name)
            scenario_block = None
            if source_path is None or not source_path.is_file():
                errors.append(f"acceptance case {acceptance_id} source file missing")
            else:
                source_text = source_path.read_text(encoding="utf-8")
                scenario_block = canonical_markdown_block(
                    source_text,
                    re.compile(
                        rf"^#### Scenario: {re.escape(acceptance_id)}\b.*$", re.MULTILINE
                    ),
                    re.compile(r"^#{1,4} ", re.MULTILINE),
                )
            if source_path is not None and source_path.is_file() and (
                not separator or anchor != acceptance_id or scenario_block is None
            ):
                errors.append(f"acceptance case {acceptance_id} expected_source does not resolve")
            definition = dict(item)
            if scenario_block is not None:
                definition["source_sha256"] = sha256(
                    scenario_block.encode("utf-8")
                ).hexdigest()
            case_definitions[acceptance_id] = definition

    for entry in _walk_hash_entries(_mapping(conformance.get("shared_inputs"))):
        input_name = str(entry.get("path") or "")
        input_path = _repo_path(root, input_name)
        if input_path is None or not input_path.is_file():
            errors.append(f"conformance input missing: {input_name}")
        elif _sha256_file(input_path) != entry.get("sha256"):
            errors.append(f"conformance input hash mismatch: {input_name}")
    shared_inputs = _mapping(conformance.get("shared_inputs"))
    fixture_ids = [
        str(_mapping(entry).get("id"))
        for entry in _sequence(shared_inputs.get("fixtures"))
        if _mapping(entry).get("id") is not None
    ]

    for raw_group in _sequence(conformance.get("safety_coverage")):
        group = _mapping(raw_group)
        invariants = _sequence(group.get("invariants"))
        if not invariants:
            errors.append("conformance safety coverage group has no invariant")
        for policy_id in invariants:
            if str(policy_id) not in policies:
                errors.append(f"conformance safety coverage has unknown Policy {policy_id}")
        for requirement_id in _sequence(group.get("requirements")):
            if str(requirement_id) not in requirements:
                errors.append(
                    f"conformance safety coverage has unknown Requirement {requirement_id}"
                )
        for category in ("normal", "refusal_or_failure", "recovery_or_restart"):
            value = group.get(category)
            if isinstance(value, Mapping):
                value_map = _mapping(value)
                if set(value_map) != {"not_applicable_reason"} or not str(
                    value_map.get("not_applicable_reason") or ""
                ):
                    errors.append(
                        f"{invariants} {category} has invalid Core not-applicable rationale"
                    )
            elif isinstance(value, list) and value:
                for acceptance_id in value:
                    if str(acceptance_id) not in acceptance:
                        errors.append(
                            f"conformance safety coverage has unknown Acceptance {acceptance_id}"
                        )
            else:
                errors.append(f"{invariants} {category} must have AC IDs or a Core rationale")

    if conformance.get("status") == "review" and conformance.get("execution_gate") != "closed":
        errors.append("review conformance gate must be closed")
    elif conformance.get("status") == "accepted":
        if conformance.get("execution_gate") != "open":
            errors.append("accepted conformance gate must be open")
        if not str(_mapping(conformance.get("ratification")).get("approval_ref") or ""):
            errors.append("accepted conformance needs approval_ref")
    return conformance, case_definitions, case_minimum_evidence, fixture_ids


def _validate_change_acceptance(
    root: Path,
    errors: MutableSequence[str],
    documents: dict[str, Any],
    configured_baseline: str,
    requirement_acceptance: Mapping[str, list[str]],
    acceptance_owner: Mapping[str, str],
    requirement_paths: Mapping[str, str],
    requirements: Mapping[str, Any],
    acceptance: Mapping[str, Any],
    policies: Mapping[str, Any],
    ports: Mapping[str, Any],
    case_definitions: dict[str, Any],
    case_minimum_evidence: dict[str, str],
) -> dict[str, Any]:
    """Validate live change overlays and live/history Acceptance identity."""

    core_case_definitions = {
        acceptance_id: dict(_mapping(definition))
        for acceptance_id, definition in case_definitions.items()
    }
    live_change_proposals: dict[str, dict[str, Any]] = {}
    change_schemas: dict[str, Any] = {}
    behavior_overlays: dict[str, dict[str, Any]] = {}
    changes_root = root / "openspec/changes"

    for proposal_path in sorted(changes_root.glob("chg-*/proposal.md")):
        proposal = _mapping(markdown_frontmatter(proposal_path))
        change_id = str(proposal.get("id") or "")
        if not change_id:
            continue
        live_change_proposals[change_id] = proposal
        change_schemas[change_id] = proposal.get("schema")
        if proposal.get("schema") != "arkdeck-behavior":
            continue
        if proposal.get("core_baseline") != configured_baseline:
            errors.append(
                f"behavior change {change_id} does not pin the configured Core baseline"
            )
        delta_paths = sorted(
            path for path in proposal_path.parent.glob("specs/**/*.md") if path.is_file()
        )
        if not delta_paths:
            errors.append(f"behavior change {change_id} has no delta spec")
            continue
        delta_sources = [
            {"path": _relative(root, path), "text": path.read_text(encoding="utf-8")}
            for path in delta_paths
        ]
        behavior_overlays[change_id] = build_behavior_overlay(
            delta_sources=delta_sources,
            baseline_requirement_acceptance=requirement_acceptance,
            baseline_acceptance_owner=acceptance_owner,
            baseline_requirement_paths=requirement_paths,
            errors=errors,  # type: ignore[arg-type]
            subject=f"behavior change {change_id}",
        )

    behavior_case_definitions: defaultdict[str, dict[str, Any]] = defaultdict(dict)
    platform_acceptance: dict[str, dict[str, Any]] = {}
    registry_documents: dict[str, dict[str, Any]] = {}
    live_registry_paths = [
        path
        for path in sorted(changes_root.glob("**/acceptance-cases.yaml"))
        if "/archive/" not in f"/{_relative(root, path)}"
    ]
    for path in live_registry_paths:
        relative = _relative(root, path)
        document = _mapping(_load_yaml(root, path, errors, documents))
        registry_documents[relative] = document
        change_root = path.parent
        expected_change_id = re.sub(r"^chg-", "CHG-", change_root.name)
        proposal_path = change_root / "proposal.md"
        registry_proposal = (
            _mapping(markdown_frontmatter(proposal_path)) if proposal_path.is_file() else {}
        )
        change_id = str(document.get("change_id") or "")
        if not (
            change_id.lower() == expected_change_id.lower()
            and registry_proposal.get("id") == document.get("change_id")
        ):
            errors.append(f"acceptance registry change ID mismatch: {relative}")
        if not (
            document.get("change_revision") == 1
            and registry_proposal.get("revision") == 1
        ):
            errors.append(f"acceptance registry revision is not immutable V1: {relative}")
        if document.get("schema_version") != "1.0.0":
            errors.append(f"acceptance registry {relative} has an unsupported schema_version")

        allowed_evidence = _sequence(document.get("evidence_classes"))
        if not (
            _all_unique(allowed_evidence)
            and not [
                item
                for item in allowed_evidence
                if item not in ACCEPTANCE_EVIDENCE_CLASSES
            ]
        ):
            errors.append(
                f"acceptance registry {relative} has duplicate/unknown evidence classes"
            )
        cases = [_mapping(item) for item in _sequence(document.get("cases"))]
        case_ids = [item.get("acceptance_id") for item in cases]
        test_ids = [item.get("test_id") for item in cases]
        if not _all_unique(case_ids):
            errors.append(f"acceptance registry {relative} has duplicate Acceptance IDs")
        if not _all_unique(test_ids):
            errors.append(f"acceptance registry {relative} has duplicate Test IDs")

        if registry_proposal.get("schema") == "arkdeck-behavior":
            expected_fields = {
                "cases",
                "change_id",
                "change_revision",
                "core_baseline",
                "evidence_classes",
                "schema_version",
            }
            if set(str(item) for item in document) != expected_fields:
                errors.append(f"behavior acceptance registry {relative} has an invalid shape")
            if not (
                document.get("core_baseline") == registry_proposal.get("core_baseline")
                and document.get("core_baseline") == configured_baseline
            ):
                errors.append(f"behavior acceptance registry {relative} baseline mismatch")
            overlay = behavior_overlays.get(change_id)
            if overlay is None:
                errors.append(
                    f"behavior acceptance registry {relative} has no parsed baseline+delta overlay"
                )
                continue
            if sorted(str(item) for item in case_ids) != overlay.get("touched_acceptance"):
                errors.append(
                    f"behavior acceptance registry {relative} does not exactly cover changed ACs"
                )
            for item in cases:
                acceptance_id_value = item.get("acceptance_id")
                acceptance_id = str(acceptance_id_value or "")
                if CORE_ACCEPTANCE_ID.fullmatch(acceptance_id) is None:
                    errors.append(
                        f"invalid behavior acceptance ID {acceptance_id_value or '?'} in {relative}"
                    )
                    continue
                for field in (
                    "test_id",
                    "method",
                    "expected_source",
                    "source_sha256",
                    "minimum_evidence",
                ):
                    if not str(item.get(field) or ""):
                        errors.append(f"behavior acceptance {acceptance_id} missing {field}")
                allowed_item_fields = {
                    "acceptance_id",
                    "expected_source",
                    "hardware_capability",
                    "method",
                    "minimum_evidence",
                    "source_sha256",
                    "test_id",
                }
                if set(str(key) for key in item) - allowed_item_fields:
                    errors.append(f"behavior acceptance {acceptance_id} has unknown fields")
                if re.fullmatch(r"[A-Z][A-Z0-9-]+", str(item.get("test_id") or "")) is None:
                    errors.append(f"behavior acceptance {acceptance_id} has an invalid Test ID")
                if HEX_SHA256_RE.fullmatch(str(item.get("source_sha256") or "")) is None:
                    errors.append(
                        f"behavior acceptance {acceptance_id} has an invalid Scenario block hash"
                    )
                if item.get("minimum_evidence") not in allowed_evidence:
                    errors.append(
                        f"behavior acceptance {acceptance_id} has unknown evidence class"
                    )
                if item.get("minimum_evidence") == "realHardware":
                    if item.get("hardware_capability") not in HARDWARE_CAPABILITIES:
                        errors.append(
                            f"behavior acceptance {acceptance_id} lacks a closed hardware capability"
                        )
                elif "hardware_capability" in item:
                    errors.append(
                        f"non-hardware behavior acceptance {acceptance_id} declares a hardware capability"
                    )

                source_name, separator, source_anchor = str(
                    item.get("expected_source") or ""
                ).partition("#")
                source_path = _repo_path(root, source_name)
                metadata = _mapping(_mapping(overlay.get("scenario_sources")).get(acceptance_id))
                source_contained = False
                if source_path is not None:
                    try:
                        source_path.relative_to(change_root.resolve())
                        source_contained = source_path != change_root.resolve()
                    except ValueError:
                        source_contained = False
                valid_source = bool(
                    source_contained
                    and source_path
                    and source_path.is_file()
                    and separator
                    and source_anchor == acceptance_id
                    and source_name == metadata.get("path")
                    and source_anchor == metadata.get("anchor")
                    and item.get("source_sha256") == metadata.get("block_sha256")
                    and f"#### Scenario: {acceptance_id}"
                    in source_path.read_text(encoding="utf-8")
                )
                if not valid_source:
                    errors.append(
                        f"behavior acceptance {acceptance_id} expected_source/hash does not "
                        "resolve to its exact delta Scenario"
                    )
                behavior_case_definitions[change_id][acceptance_id] = {
                    **item,
                    "change_id": change_id,
                    "kind": "behaviorOverlay",
                }

        elif registry_proposal.get("schema") == "arkdeck-platform":
            expected_fields = {
                "cases",
                "change_id",
                "change_revision",
                "evidence_classes",
                "platform",
                "schema_version",
            }
            if set(str(item) for item in document) != expected_fields:
                errors.append(f"platform acceptance registry {relative} has an invalid shape")
            registry_platform = str(document.get("platform") or "")
            if registry_platform not in {"macos", "windows", "linux"}:
                errors.append(f"platform acceptance registry has invalid platform: {relative}")
            for item in cases:
                acceptance_id = str(item.get("acceptance_id") or "")
                if PLATFORM_ACCEPTANCE_ID.fullmatch(acceptance_id) is None:
                    errors.append(f"invalid platform acceptance ID in {relative}")
                    continue
                if acceptance_id in case_definitions or acceptance_id in platform_acceptance:
                    errors.append(f"duplicate platform/Core acceptance {acceptance_id}")
                for field in (
                    "test_id",
                    "method",
                    "expected_result",
                    "expected_source",
                    "minimum_evidence",
                ):
                    if not str(item.get(field) or ""):
                        errors.append(f"platform acceptance {acceptance_id} missing {field}")
                allowed_item_fields = {
                    "acceptance_id",
                    "expected_result",
                    "expected_source",
                    "hardware_capability",
                    "method",
                    "minimum_evidence",
                    "test_id",
                }
                if set(str(key) for key in item) - allowed_item_fields:
                    errors.append(f"platform acceptance {acceptance_id} has unknown fields")
                if re.fullmatch(r"[A-Z][A-Z0-9-]+", str(item.get("test_id") or "")) is None:
                    errors.append(f"platform acceptance {acceptance_id} has an invalid Test ID")
                if item.get("minimum_evidence") not in allowed_evidence:
                    errors.append(
                        f"platform acceptance {acceptance_id} has unknown evidence class"
                    )
                if item.get("minimum_evidence") == "realHardware":
                    if item.get("hardware_capability") not in HARDWARE_CAPABILITIES:
                        errors.append(
                            f"platform acceptance {acceptance_id} lacks a closed hardware capability"
                        )
                elif "hardware_capability" in item:
                    errors.append(
                        f"non-hardware platform acceptance {acceptance_id} declares a hardware capability"
                    )
                source_name, separator, source_anchor = str(
                    item.get("expected_source") or ""
                ).partition("#")
                source_path = _repo_path(root, source_name)
                if not (
                    source_path
                    and source_path.is_file()
                    and separator
                    and source_anchor == acceptance_id
                    and acceptance_id in source_path.read_text(encoding="utf-8")
                ):
                    errors.append(
                        f"platform acceptance {acceptance_id} expected_source does not resolve"
                    )
                platform_acceptance[acceptance_id] = {
                    "path": relative,
                    "change_id": change_id,
                    "platform": registry_platform,
                }
                case_minimum_evidence[acceptance_id] = str(
                    item.get("minimum_evidence") or ""
                )
                case_definitions[acceptance_id] = {
                    **item,
                    "platform": registry_platform,
                    "change_id": change_id,
                }
        else:
            errors.append(f"acceptance registry {relative} belongs to an unknown change schema")

    platform_identity_locations: defaultdict[str, list[str]] = defaultdict(list)
    platform_change_case_records: list[dict[str, Any]] = []
    for path in sorted(changes_root.glob("**/acceptance-cases.yaml")):
        proposal_path = path.parent / "proposal.md"
        if not proposal_path.is_file():
            continue
        proposal = _mapping(markdown_frontmatter(proposal_path))
        if proposal.get("schema") != "arkdeck-platform":
            continue
        relative = _relative(root, path)
        registry = _mapping(_load_yaml(root, path, errors, documents))
        platform = str(registry.get("platform") or "")
        for item in [_mapping(value) for value in _sequence(registry.get("cases"))]:
            acceptance_id = str(item.get("acceptance_id") or "")
            platform_identity_locations[acceptance_id].append(relative)
            platform_change_case_records.append(
                {"id": acceptance_id, "platform": platform, "definition": item}
            )
    for acceptance_id, locations in platform_identity_locations.items():
        if len(locations) > 1:
            errors.append(
                f"platform acceptance identity {acceptance_id} is reused across Change history: "
                f"{', '.join(sorted(locations))}"
            )

    def case_definition_for_change(change_id: str, acceptance_id: str) -> Any:
        behavior_definition = behavior_case_definitions.get(change_id, {}).get(
            acceptance_id
        )
        if behavior_definition is not None:
            return behavior_definition
        platform_record = platform_acceptance.get(acceptance_id)
        if platform_record and platform_record.get("change_id") == change_id:
            return case_definitions.get(acceptance_id)
        return core_case_definitions.get(acceptance_id)

    def acceptance_known_for_change(change_id: str, acceptance_id: str) -> bool:
        overlay = behavior_overlays.get(change_id)
        if overlay is not None:
            return acceptance_id in _sequence(overlay.get("reference_acceptance"))
        platform_record = platform_acceptance.get(acceptance_id)
        return acceptance_id in acceptance or bool(
            platform_record and platform_record.get("change_id") == change_id
        )

    def requirement_known_for_change(change_id: str, requirement_id: str) -> bool:
        overlay = behavior_overlays.get(change_id)
        if requirement_id.startswith("REQ-"):
            return (
                requirement_id in _sequence(overlay.get("reference_requirements"))
                if overlay is not None
                else requirement_id in requirements
            )
        if requirement_id.startswith("POL-"):
            return requirement_id in policies
        if requirement_id.startswith("PORT-"):
            return requirement_id in ports
        return requirement_id.startswith("PLATFORM-")

    return {
        "core_case_definitions": core_case_definitions,
        "live_change_proposals": live_change_proposals,
        "change_schemas": change_schemas,
        "behavior_overlays": behavior_overlays,
        "behavior_case_definitions": dict(behavior_case_definitions),
        "platform_acceptance": platform_acceptance,
        "change_acceptance_registries": registry_documents,
        "platform_case_identity_locations": dict(platform_identity_locations),
        "platform_change_case_records": platform_change_case_records,
        "case_definition_for_change": case_definition_for_change,
        "acceptance_known_for_change": acceptance_known_for_change,
        "requirement_known_for_change": requirement_known_for_change,
    }


def _validate_platform_change_contracts(
    errors: MutableSequence[str],
    records: list[dict[str, Any]],
    platform_case_definitions: Mapping[str, Any],
) -> None:
    for record in records:
        release_definition = next(
            (
                _mapping(definition)
                for definition in _sequence(
                    platform_case_definitions.get(str(record.get("platform")))
                )
                if _mapping(definition).get("id") == record.get("id")
            ),
            None,
        )
        if release_definition is None:
            continue
        local_hash = acceptance_case_contract_sha256(
            str(record.get("id") or ""), _mapping(record.get("definition"))
        )
        release_hash = acceptance_case_contract_sha256(
            str(record.get("id") or ""), release_definition
        )
        if local_hash != release_hash:
            errors.append(
                f"platform acceptance {record.get('id')} differs from its "
                f"{record.get('platform')} release-case contract"
            )


def _validate_integration_lock(
    root: Path,
    errors: MutableSequence[str],
    documents: dict[str, Any],
    conformance: Mapping[str, Any],
) -> tuple[dict[str, Any], dict[str, Any]]:
    path = root / "openspec/integrations/INTEGRATION-PROFILES.lock.yaml"
    if not path.is_file():
        errors.append("integration lock is missing")
        return {}, {}
    lock = _mapping(_load_yaml(root, path, errors, documents))
    profiles = [_mapping(item) for item in _sequence(lock.get("profiles"))]
    catalogs = [_mapping(item) for item in _sequence(lock.get("catalogs"))]
    fixtures = [_mapping(item) for item in _sequence(lock.get("fixtures"))]
    entries = profiles + catalogs + fixtures
    paths = [entry.get("path") for entry in entries]
    if not _all_unique(paths):
        errors.append("integration lock has duplicate paths")
    for entry in entries:
        _validate_hash_entry(root, entry, errors, "integration lock")

    expected_profiles = sorted(
        _relative(root, item) for item in (root / "openspec/integrations").glob("**/profile.md")
    )
    expected_catalogs = sorted(
        value
        for value in (
            "openspec/contracts/catalogs/debug-parameters.yaml",
            "openspec/contracts/catalogs/dump-recipes.yaml",
            "openspec/contracts/catalogs/trace-presets.yaml",
        )
        if (root / value).is_file()
    )
    fixtures_root = root / "openspec/integrations/fixtures"
    expected_fixtures = sorted(
        _relative(root, item)
        for item in fixtures_root.glob("**/*")
        if item.is_file()
    ) if fixtures_root.is_dir() else []
    if sorted(str(entry.get("path")) for entry in profiles) != expected_profiles:
        errors.append("integration lock profile set is incomplete")
    if sorted(str(entry.get("path")) for entry in catalogs) != expected_catalogs:
        errors.append("integration lock catalog set is incomplete")
    if sorted(str(entry.get("path")) for entry in fixtures) != expected_fixtures:
        errors.append("integration lock fixture set is incomplete")

    locked_profiles: dict[str, Any] = {}
    for entry in profiles:
        profile_id = str(entry.get("id") or "")
        if profile_id in locked_profiles:
            errors.append(f"integration lock has duplicate profile ID {profile_id}")
        else:
            locked_profiles[profile_id] = entry
        profile_path = _repo_path(root, entry.get("path"))
        if profile_path is None or not profile_path.is_file():
            continue
        text = profile_path.read_text(encoding="utf-8")
        id_match = re.search(r"^> ID：([^\s]+)\s*$", text, re.MULTILINE)
        version_match = re.search(r"^> Version：([^\s]+)\s*$", text, re.MULTILINE)
        if (
            (id_match.group(1) if id_match else None) != entry.get("id")
            or (version_match.group(1) if version_match else None) != entry.get("version")
        ):
            errors.append(f"integration lock profile metadata mismatch: {entry.get('path')}")

    for entry in catalogs:
        catalog_path = _repo_path(root, entry.get("path"))
        if catalog_path is None or not catalog_path.is_file():
            continue
        catalog = _mapping(_load_yaml(root, catalog_path, errors, documents))
        version = catalog.get("version", catalog.get("schema_version"))
        if catalog.get("catalog") != entry.get("id") or version != entry.get("version"):
            errors.append(f"integration lock catalog metadata mismatch: {entry.get('path')}")

    if lock.get("status") == "review":
        if lock.get("execution_gate") != "closed":
            errors.append("review integration lock gate must be closed")
        if lock.get("accepted_at") is not None:
            errors.append("review integration lock must not have accepted_at")
    elif lock.get("status") == "accepted":
        if lock.get("execution_gate") != "open":
            errors.append("accepted integration lock gate must be open")
        if not str(_mapping(lock.get("ratification")).get("approval_ref") or ""):
            errors.append("accepted integration lock needs approval_ref")

    if conformance:
        shared = _mapping(conformance.get("shared_inputs"))
        lock_ref = _mapping(shared.get("integration_lock"))
        if not (
            lock_ref.get("id") == lock.get("lock")
            and lock_ref.get("path") == _relative(root, path)
            and lock_ref.get("sha256") == _sha256_file(path)
        ):
            errors.append("conformance suite does not pin the current Integration lock")
        locked_by_path = {str(entry.get("path")): entry for entry in entries}
        conformance_entries = _sequence(shared.get("integration_profiles")) + [
            item
            for item in _sequence(shared.get("catalogs"))
            if _mapping(item).get("path")
            != "openspec/contracts/catalogs/remote-operations.yaml"
        ] + _sequence(shared.get("fixtures"))
        for raw_entry in conformance_entries:
            entry = _mapping(raw_entry)
            locked = locked_by_path.get(str(entry.get("path")))
            if not locked or locked.get("sha256") != entry.get("sha256"):
                errors.append(
                    "conformance integration input is not in the Integration lock: "
                    f"{entry.get('path')}"
                )
    return lock, locked_profiles


def _validate_platform_revalidation(
    errors: MutableSequence[str],
    subject: str,
    matrix: Any,
    declared_platforms: list[str],
    current_delivery_platforms: list[str],
) -> None:
    matrix_map = _mapping(matrix)
    if sorted(str(item) for item in matrix_map) != declared_platforms:
        errors.append(f"{subject} lacks an exact target-platform revalidation matrix")
    for platform, raw_disposition in matrix_map.items():
        disposition = _mapping(raw_disposition)
        valid = (
            disposition.get("disposition") in REVALIDATION_DISPOSITIONS
            and bool(str(disposition.get("owner") or ""))
            and bool(str(disposition.get("milestone") or ""))
        )
        if not valid:
            errors.append(f"{subject} has invalid revalidation disposition for {platform}")
        if str(platform) in current_delivery_platforms and disposition.get("disposition") == "deferred":
            errors.append(f"{subject} defers current delivery platform {platform}")


def _validate_platform_lifecycle(
    errors: MutableSequence[str], subject: str, lock: Mapping[str, Any], declared: list[str]
) -> None:
    current = [str(item) for item in _sequence(lock.get("current_delivery_platforms"))]
    not_started = [str(item) for item in _sequence(lock.get("not_started_platforms"))]
    if len(set(current)) != len(current):
        errors.append(f"{subject} has duplicate current-delivery platforms")
    if len(set(not_started)) != len(not_started):
        errors.append(f"{subject} has duplicate not-started platforms")
    if set(current) & set(not_started):
        errors.append(f"{subject} platform lifecycle sets overlap")
    if sorted(current + not_started) != declared:
        errors.append(f"{subject} platform lifecycle does not exactly cover declared targets")
    profiles = [_mapping(item) for item in _sequence(lock.get("profiles"))]
    if sorted(str(item.get("platform")) for item in profiles) != declared:
        errors.append(f"{subject} profile set differs from declared targets")
    for platform in not_started:
        entry = next((item for item in profiles if str(item.get("platform")) == platform), None)
        if entry is None or entry.get("conformance_status") != "notStarted":
            errors.append(
                f"{subject} not-started platform {platform} is not in notStarted conformance state"
            )


def _validate_platform_transition(
    errors: MutableSequence[str], subject: str, prior: Mapping[str, Any], current: Mapping[str, Any]
) -> None:
    previous_by_platform = {
        str(_mapping(item).get("platform")): _mapping(item)
        for item in _sequence(prior.get("profiles"))
    }
    for raw_entry in _sequence(current.get("profiles")):
        entry = _mapping(raw_entry)
        platform = str(entry.get("platform"))
        previous = previous_by_platform.get(platform)
        if not previous:
            continue
        if previous.get("conformance_status") in {"verified", "needsReverification"} and entry.get(
            "conformance_status"
        ) == "notStarted":
            errors.append(
                f"{subject} illegally resets {platform} conformance history to notStarted"
            )
        if (
            entry.get("conformance_status") in {"needsReverification", "nonConformant"}
            and previous.get("conformance_status") in {"verified", "needsReverification"}
            and entry.get("last_verified") != previous.get("last_verified")
        ):
            errors.append(
                f"{subject} {platform} {entry.get('conformance_status')} erases or rewrites "
                "prior verified pins/evidence"
            )


def _validate_platform_lock(
    root: Path,
    errors: MutableSequence[str],
    documents: dict[str, Any],
    declared_platforms: list[str],
    port_names: list[str],
) -> tuple[dict[str, Any], dict[str, Any], list[dict[str, Any]], dict[str, Any], dict[str, Any]]:
    path = root / "openspec/platforms/PLATFORM-PROFILES.lock.yaml"
    if not path.is_file():
        errors.append("platform lock is missing")
        return {}, {}, [], {}, {}
    lock = _mapping(_load_yaml(root, path, errors, documents))
    history_records: list[dict[str, Any]] = []
    history_root = root / "openspec/platforms/history"
    if history_root.is_dir():
        for history_path in sorted(history_root.glob("*.lock.yaml")):
            history_records.append(
                {
                    "path": history_path,
                    "document": _mapping(_load_yaml(root, history_path, errors, documents)),
                }
            )
    current_revision = lock.get("revision")
    history_revisions = [record["document"].get("revision") for record in history_records]
    if not isinstance(current_revision, int) or isinstance(current_revision, bool) or current_revision < 1:
        errors.append("platform lock has an invalid revision")
    elif not all(isinstance(item, int) and not isinstance(item, bool) and item >= 1 for item in history_revisions):
        errors.append("platform lock history has an invalid revision")
    elif sorted(history_revisions) != list(range(1, current_revision)):
        errors.append("platform lock history does not exactly cover prior revisions")
    if not _all_unique(history_revisions):
        errors.append("platform lock history has duplicate revisions")

    chain = sorted(history_records, key=lambda item: int(item["document"].get("revision") or 0))
    chain.append({"path": path, "document": lock})
    for index, record in enumerate(chain):
        document = _mapping(record["document"])
        record_path = Path(record["path"])
        relative = _relative(root, record_path)
        expected_revision = index + 1
        if document.get("revision") != expected_revision:
            errors.append(f"platform lock chain revision is not exact at {relative}")
        if record_path != path:
            if document.get("status") != "accepted" or document.get("execution_gate") != "open":
                errors.append(f"historical platform lock {relative} is not accepted")
            if not str(document.get("accepted_at") or "") or not str(
                _mapping(document.get("ratification")).get("approval_ref") or ""
            ):
                errors.append(f"historical platform lock {relative} lacks accepted_at/approval_ref")
        profiles = [_mapping(item) for item in _sequence(document.get("profiles"))]
        ids = [item.get("id") for item in profiles]
        bindings = [item.get("platform") for item in profiles]
        if not _all_unique(ids):
            errors.append(f"platform lock {relative} has duplicate IDs")
        if not _all_unique(bindings):
            errors.append(f"platform lock {relative} has duplicate platform bindings")
        for entry in profiles:
            if entry.get("conformance_status") not in CONFORMANCE_STATES:
                errors.append(
                    f"platform lock {relative} has invalid conformance status: {entry.get('id')}"
                )
            last_verified = _mapping(entry.get("last_verified"))
            if set(last_verified) != LAST_VERIFIED_FIELDS:
                errors.append(
                    f"platform lock {relative} has invalid last_verified shape: {entry.get('id')}"
                )
        _validate_platform_lifecycle(errors, f"platform lock {relative}", document, declared_platforms)
        previous_ref = document.get("previous_lock")
        if index == 0:
            if previous_ref is not None:
                errors.append("first platform lock revision must not reference a predecessor")
        else:
            prior = chain[index - 1]
            prior_path = Path(prior["path"])
            previous = _mapping(previous_ref)
            valid_ref = (
                previous.get("path") == _relative(root, prior_path)
                and previous.get("sha256") == _sha256_file(prior_path)
                and bool(
                    re.fullmatch(
                        r"openspec/platforms/history/PLATFORM-PROFILES-[A-Za-z0-9._-]+\.lock\.yaml",
                        str(previous.get("path") or ""),
                    )
                )
            )
            if not valid_ref:
                errors.append(
                    f"platform lock {relative} predecessor path/hash is not the exact prior revision"
                )
            _validate_platform_transition(
                errors,
                f"platform lock transition {expected_revision - 1}->{expected_revision}",
                _mapping(prior["document"]),
                document,
            )

    profile_entries = [_mapping(item) for item in _sequence(lock.get("profiles"))]
    if not _all_unique([entry.get("id") for entry in profile_entries]):
        errors.append("platform lock has duplicate IDs")
    if not _all_unique([entry.get("platform") for entry in profile_entries]):
        errors.append("platform lock has duplicate platform bindings")
    expected_profiles = sorted(
        _relative(root, item) for item in (root / "openspec/platforms").glob("*/profile.md")
    )
    expected_verifications = sorted(
        _relative(root, item)
        for item in (root / "openspec/platforms").glob("*/verification.md")
    )
    expected_cases = sorted(
        _relative(root, item)
        for item in (root / "openspec/platforms").glob("*/conformance-cases.yaml")
    )
    for field, expected, message in (
        ("profile_path", expected_profiles, "platform lock does not exactly cover platform profiles"),
        (
            "verification_path",
            expected_verifications,
            "platform lock does not exactly cover platform verification profiles",
        ),
        (
            "case_manifest_path",
            expected_cases,
            "platform lock does not exactly cover platform case manifests",
        ),
    ):
        if sorted(str(item.get(field)) for item in profile_entries) != expected:
            errors.append(message)

    locked_profiles: dict[str, Any] = {}
    case_definitions: dict[str, Any] = {}
    support_definitions: dict[str, Any] = {}
    for entry in profile_entries:
        profile_id = str(entry.get("id") or "")
        if profile_id not in locked_profiles:
            locked_profiles[profile_id] = entry
        for field, hash_field in (
            ("profile_path", "profile_sha256"),
            ("verification_path", "verification_sha256"),
            ("case_manifest_path", "case_manifest_sha256"),
        ):
            _validate_hash_entry(
                root,
                {"path": entry.get(field), "sha256": entry.get(hash_field)},
                errors,
                "platform lock",
            )
        profile_path = _repo_path(root, entry.get("profile_path"))
        profile_text = profile_path.read_text(encoding="utf-8") if profile_path and profile_path.is_file() else ""
        id_match = re.search(r"^> ID：([^\s]+)\s*$", profile_text, re.MULTILINE)
        version_match = re.search(r"^> Version：([^\s]+)\s*$", profile_text, re.MULTILINE)
        strategy_match = re.search(r"^> Core strategy：([^\s]+)\s*$", profile_text, re.MULTILINE)
        if (
            (id_match.group(1) if id_match else None) != entry.get("id")
            or (version_match.group(1) if version_match else None) != entry.get("version")
        ):
            errors.append(f"platform lock metadata mismatch: {entry.get('profile_path')}")
        if (strategy_match.group(1) if strategy_match else None) != "native-conforming-shared-contract-vector-suite":
            errors.append(
                "platform profile does not fix the V1 native/shared-suite Core strategy: "
                f"{entry.get('profile_path')}"
            )
        expected_platform = profile_path.parent.name if profile_path else ""
        if entry.get("platform") != expected_platform:
            errors.append(f"platform lock profile/platform binding mismatch: {profile_id}")

        case_path = _repo_path(root, entry.get("case_manifest_path"))
        manifest = _mapping(
            _load_yaml(root, case_path, errors, documents) if case_path is not None else {}
        )
        cases = [_mapping(item) for item in _sequence(manifest.get("cases"))]
        support_cells = [_mapping(item) for item in _sequence(manifest.get("support_cells"))]
        case_ids = [item.get("id") for item in cases]
        test_ids = [item.get("test_id") for item in cases]
        cell_ids = [item.get("id") for item in support_cells]
        valid = (
            manifest.get("platform") == entry.get("platform")
            and manifest.get("version") == entry.get("version")
            and bool(str(manifest.get("suite") or ""))
            and bool(case_ids)
            and _all_unique(case_ids)
            and _all_unique(test_ids)
            and bool(support_cells)
            and _all_unique(cell_ids)
        )
        for cell in support_cells:
            valid = valid and set(cell) == {
                "architecture",
                "id",
                "os_version_family",
                "package_format",
            }
            valid = valid and bool(re.fullmatch(r"[a-z][a-z0-9-]+", str(cell.get("id") or "")))
            valid = valid and all(
                bool(str(cell.get(field) or ""))
                for field in ("os_version_family", "architecture", "package_format")
            )
        for item in cases:
            expected_source, separator, anchor = str(item.get("expected_source") or "").partition("#")
            source_path = _repo_path(root, expected_source)
            valid = valid and bool(PLATFORM_CASE_ID_RE.fullmatch(str(item.get("id") or "")))
            valid = valid and bool(TEST_ID_RE.fullmatch(str(item.get("test_id") or "")))
            valid = valid and bool(str(item.get("method") or ""))
            valid = valid and bool(str(item.get("expected_result") or ""))
            valid = valid and item.get("minimum_evidence") in {"platform", "manualReview", "realHardware"}
            if item.get("minimum_evidence") == "realHardware":
                valid = valid and item.get("hardware_capability") in HARDWARE_CAPABILITIES
            else:
                valid = valid and "hardware_capability" not in item
            valid = valid and bool(
                source_path
                and source_path.is_file()
                and separator
                and anchor == item.get("id")
                and str(item.get("id")) in source_path.read_text(encoding="utf-8")
            )
        if not valid:
            errors.append(f"platform case manifest is invalid: {entry.get('case_manifest_path')}")
        else:
            case_definitions[str(entry.get("platform"))] = cases
            support_definitions[str(entry.get("platform"))] = support_cells

        release_subject = _mapping(entry.get("release_subject"))
        if set(release_subject) != {"approval_id", "path", "sha256"}:
            errors.append(
                f"platform {entry.get('platform')} has an invalid release_subject shape"
            )
        if entry.get("conformance_status") not in CONFORMANCE_STATES:
            errors.append(
                f"platform lock has invalid conformance status: {entry.get('id')}"
            )
        last_verified_value = entry.get("last_verified")
        if not (
            isinstance(last_verified_value, Mapping)
            and set(str(key) for key in last_verified_value) == LAST_VERIFIED_FIELDS
        ):
            errors.append(
                f"platform lock has invalid last_verified shape: {entry.get('id')}"
            )
        mapped_ports = [
            match.group(1)
            for match in re.finditer(r"^\| ([A-Za-z][A-Za-z0-9]+) \|", profile_text, re.MULTILINE)
            if match.group(1) in port_names
        ]
        if sorted(mapped_ports) != sorted(port_names):
            errors.append(
                f"platform profile Port mapping is incomplete: {entry.get('profile_path')}"
            )

    if lock.get("status") == "review":
        if lock.get("execution_gate") != "closed":
            errors.append("review platform lock gate must be closed")
        if lock.get("accepted_at") is not None:
            errors.append("review platform lock must not have accepted_at")
    elif lock.get("status") == "accepted":
        if lock.get("execution_gate") != "open":
            errors.append("accepted platform lock gate must be open")
        if not str(_mapping(lock.get("ratification")).get("approval_ref") or ""):
            errors.append("accepted platform lock needs approval_ref")
    return lock, locked_profiles, chain, case_definitions, support_definitions


def _validate_workflow_registry(
    root: Path,
    errors: MutableSequence[str],
    documents: dict[str, Any],
) -> dict[str, Any]:
    registry_path = root / "openspec/contracts/workflow-step-registry.yaml"
    schema_path = root / "openspec/contracts/workflow-step.schema.json"
    result: dict[str, Any] = {
        "workflow_registry": {},
        "workflow_schema": {},
        "workflow_definitions": {},
        "workflow_registry_steps": [],
        "workflow_schema_kinds": [],
        "workflow_catalogs": {},
    }
    if not (registry_path.is_file() and schema_path.is_file()):
        return result

    registry = _mapping(_load_yaml(root, registry_path, errors, documents))
    try:
        workflow_schema = _mapping(json.loads(schema_path.read_text(encoding="utf-8")))
    except (json.JSONDecodeError, OSError, UnicodeError) as exc:
        errors.append(f"invalid JSON {_relative(root, schema_path)}: {exc}")
        return result
    definitions = _mapping(workflow_schema.get("$defs"))
    schema_kinds = _sequence(_mapping(definitions.get("kind")).get("enum"))
    registry_steps = [_mapping(item) for item in _sequence(registry.get("steps"))]
    registry_kinds = [item.get("kind") for item in registry_steps]
    if not _all_unique(registry_kinds):
        errors.append("workflow registry has duplicate kinds")
    if sorted(str(item) for item in registry_kinds) != sorted(
        str(item) for item in schema_kinds
    ):
        errors.append("workflow registry and schema kind sets differ")

    argument_kinds: list[Any] = []
    typed_arguments = _mapping(definitions.get("typedArgumentsByKind"))
    for raw_rule in _sequence(typed_arguments.get("allOf")):
        rule = _mapping(raw_rule)
        kind_rule = _mapping(
            _mapping(_mapping(rule.get("if")).get("properties")).get("kind")
        )
        covered = (
            [kind_rule.get("const")]
            if "const" in kind_rule
            else _sequence(kind_rule.get("enum"))
        )
        for kind in covered:
            if kind not in argument_kinds:
                argument_kinds.append(kind)
    if sorted(str(item) for item in argument_kinds) != sorted(
        str(item) for item in schema_kinds
    ):
        errors.append("not every workflow kind has exactly one typed argument mapping")

    effect_order = ["hostOnly", "readOnly", "deviceMutation", "destructive"]
    cancellation_order = ["immediate", "atSafeBoundary", "criticalNonInterruptible"]
    binding_order = ["none", "confirmedDevice"]
    invariant_rules = _sequence(
        _mapping(definitions.get("typedStepInvariants")).get("allOf")
    )

    def suffix(order: list[str], value: Any) -> list[str]:
        try:
            return order[order.index(value) :]
        except ValueError:
            return []

    for step in registry_steps:
        kind = step.get("kind")
        actual = {
            "effect": list(effect_order),
            "cancellation": list(cancellation_order),
            "bindingRequirement": list(binding_order),
        }
        for raw_rule in invariant_rules:
            rule = _mapping(raw_rule)
            kind_rule = _mapping(
                _mapping(_mapping(rule.get("if")).get("properties")).get("kind")
            )
            covered = kind_rule.get("const") == kind or kind in _sequence(
                kind_rule.get("enum")
            )
            if not covered:
                continue
            properties = _mapping(_mapping(rule.get("then")).get("properties"))
            for field in ("effect", "cancellation", "bindingRequirement"):
                constraint = _mapping(properties.get(field))
                if not constraint:
                    continue
                permitted = (
                    [constraint.get("const")]
                    if "const" in constraint
                    else _sequence(constraint.get("enum"))
                )
                actual[field] = [value for value in actual[field] if value in permitted]
        binding_exact = step.get("binding_exact") is not None and step.get(
            "binding_exact"
        ) is not False
        expected = {
            "effect": suffix(effect_order, step.get("minimum_effect")),
            "cancellation": suffix(cancellation_order, step.get("cancellation")),
            "bindingRequirement": [step.get("binding")]
            if binding_exact
            else suffix(binding_order, step.get("binding")),
        }
        for field, values in expected.items():
            if actual[field] != values:
                errors.append(f"workflow schema {kind} {field} differs from registry minimum")

    catalog_paths = {
        "dump": root / "openspec/contracts/catalogs/dump-recipes.yaml",
        "trace": root / "openspec/contracts/catalogs/trace-presets.yaml",
        "remote": root / "openspec/contracts/catalogs/remote-operations.yaml",
    }
    catalogs = {
        name: _mapping(_load_yaml(root, path, errors, documents))
        for name, path in catalog_paths.items()
    }
    dump_catalog = catalogs["dump"]
    trace_catalog = catalogs["trace"]
    remote_catalog = catalogs["remote"]
    dump_ids = sorted(
        str(_mapping(entry).get("id"))
        for entry in _sequence(dump_catalog.get("recipes"))
        + _sequence(dump_catalog.get("legacy_fallbacks"))
    )
    trace_ids = sorted(
        str(_mapping(entry).get("id"))
        for entry in _sequence(trace_catalog.get("presets"))
    )
    stdout_arguments = _mapping(
        _mapping(definitions.get("catalogStdoutArguments")).get("properties")
    )
    if _mapping(stdout_arguments.get("catalogId")).get("const") != dump_catalog.get(
        "catalog"
    ):
        errors.append("stdout catalog ID is not closed")
    if sorted(
        str(item)
        for item in _sequence(_mapping(stdout_arguments.get("actionId")).get("enum"))
    ) != dump_ids:
        errors.append("stdout dump action set differs from catalog")

    file_all_of = _sequence(_mapping(definitions.get("catalogFileArguments")).get("allOf"))
    file_branches = _sequence(_mapping(file_all_of[0]).get("oneOf")) if file_all_of else []
    file_pairs: dict[str, list[str]] = {}
    for raw_branch in file_branches:
        properties = _mapping(_mapping(raw_branch).get("properties"))
        catalog_id = str(_mapping(properties.get("catalogId")).get("const") or "")
        file_pairs[catalog_id] = sorted(
            str(item)
            for item in _sequence(_mapping(properties.get("actionId")).get("enum"))
        )
    if file_pairs.get(str(dump_catalog.get("catalog") or "")) != dump_ids:
        errors.append("remote-file dump action set differs from catalog")
    if file_pairs.get(str(trace_catalog.get("catalog") or "")) != trace_ids:
        errors.append("remote-file trace action set differs from catalog")

    remote_by_kind: defaultdict[str, list[dict[str, Any]]] = defaultdict(list)
    for raw_operation in _sequence(remote_catalog.get("operations")):
        operation = _mapping(raw_operation)
        remote_by_kind[str(operation.get("step_kind") or "")].append(operation)
    for kind, definition_name in {
        "runApprovedRemoteRead": "approvedRemoteReadArguments",
        "runApprovedRemoteMutation": "approvedRemoteMutationArguments",
    }.items():
        argument_properties = _mapping(
            _mapping(definitions.get(definition_name)).get("properties")
        )
        catalog_operations = remote_by_kind.get(kind, [])
        if _mapping(argument_properties.get("catalogId")).get(
            "const"
        ) != remote_catalog.get("catalog"):
            errors.append(f"approved operation catalog ID is not closed for {kind}")
        schema_actions = sorted(
            str(item)
            for item in _sequence(
                _mapping(argument_properties.get("actionId")).get("enum")
            )
        )
        catalog_actions = sorted(str(item.get("id")) for item in catalog_operations)
        if schema_actions != catalog_actions:
            errors.append(f"approved operation action set differs for {kind}")
        registry_step = next(
            (item for item in registry_steps if item.get("kind") == kind), None
        )
        for operation in catalog_operations:
            valid = bool(
                registry_step
                and operation.get("minimum_effect")
                == registry_step.get("minimum_effect")
                and operation.get("cancellation") == registry_step.get("cancellation")
                and operation.get("binding") == registry_step.get("binding")
            )
            if not valid:
                errors.append(
                    f"approved operation {operation.get('id')} weakens {kind} registry policy"
                )

    result.update(
        {
            "workflow_registry": registry,
            "workflow_schema": workflow_schema,
            "workflow_definitions": definitions,
            "workflow_registry_steps": registry_steps,
            "workflow_schema_kinds": schema_kinds,
            "workflow_catalogs": catalogs,
        }
    )
    return result


def _protected_files(root: Path, errors: MutableSequence[str]) -> list[str]:
    try:
        return sdd_protected_files(root)
    except (OSError, ValueError) as exc:
        errors.append(f"cannot expand the Python protected-set definition: {exc}")
        return []


def _validate_baseline(
    root: Path,
    errors: MutableSequence[str],
    documents: dict[str, Any],
    configured_baseline: str,
    declared_platforms: list[str],
    platform_lock: Mapping[str, Any],
    platform_chain: list[dict[str, Any]],
    conformance: Mapping[str, Any],
    integration_lock: Mapping[str, Any],
) -> tuple[dict[str, Any], dict[str, Any], list[str]]:
    path = root / f"openspec/baselines/{configured_baseline}.lock.yaml"
    if not path.is_file():
        errors.append(f"configured Core baseline lock is missing: {configured_baseline}")
        return {}, {}, []
    baseline = _mapping(_load_yaml(root, path, errors, documents))
    lock_references: list[str] = []
    for entry in _walk_hash_entries(baseline):
        lock_references.append(str(entry.get("path")))
        _validate_hash_entry(root, entry, errors, "baseline")

    manifest: dict[str, Any] = {}
    locked_paths: list[str] = []
    manifest_ref = _mapping(baseline.get("file_manifest"))
    if not manifest_ref:
        errors.append("baseline has no file_manifest")
    else:
        manifest_path = _repo_path(root, manifest_ref.get("path"))
        if manifest_path is None or not manifest_path.is_file():
            errors.append(f"baseline path missing: {manifest_ref.get('path')}")
        else:
            manifest = _mapping(_load_yaml(root, manifest_path, errors, documents))
            if manifest.get("baseline") != baseline.get("baseline"):
                errors.append("baseline file manifest targets another baseline")
            if manifest.get("hash_algorithm") != baseline.get("hash_algorithm"):
                errors.append("baseline file manifest hash algorithm differs")
            entries = [_mapping(item) for item in _sequence(manifest.get("files"))]
            locked_paths = [str(item.get("path")) for item in entries]
            if len(set(locked_paths)) != len(locked_paths):
                errors.append("baseline file manifest has duplicate paths")
            if locked_paths != sorted(locked_paths):
                errors.append("baseline file manifest is not path-sorted")
            for entry in entries:
                _validate_hash_entry(
                    root,
                    entry,
                    errors,
                    "baseline protected",
                    validate_hash_format=True,
                )

    protected = _protected_files(root, errors)
    missing = sorted(set(protected) - set(locked_paths))
    extra = sorted(set(locked_paths) - set(protected))
    if missing:
        errors.append(f"baseline omits protected files: {', '.join(missing)}")
    if extra:
        errors.append(
            f"baseline file manifest contains non-protected files: {', '.join(extra)}"
        )
    expected_reference = [manifest_ref.get("path") if manifest_ref else None]
    if lock_references != expected_reference:
        errors.append("baseline must hash exactly one file manifest")

    revalidation_context = _mapping(baseline.get("platform_revalidation_context"))
    matching_record = None
    for record in platform_chain:
        document = _mapping(record.get("document"))
        record_path = Path(record.get("path"))
        if (
            document.get("lock") == revalidation_context.get("platform_lock")
            and document.get("revision") == revalidation_context.get("revision")
            and record_path.is_file()
            and _sha256_file(record_path) == revalidation_context.get("sha256")
        ):
            matching_record = record
            break
    context_current = sorted(
        str(item) for item in _sequence(revalidation_context.get("current_delivery_platforms"))
    )
    valid_context = bool(
        matching_record
        and context_current
        == sorted(
            str(item)
            for item in _sequence(
                _mapping(matching_record.get("document")).get("current_delivery_platforms")
            )
        )
    )
    if not valid_context:
        errors.append(
            f"Core baseline {baseline.get('baseline')} lacks its exact ratification-time "
            "Platform lifecycle context"
        )
    _validate_platform_revalidation(
        errors,
        f"Core baseline {baseline.get('baseline')}",
        baseline.get("platform_revalidation"),
        declared_platforms,
        context_current if valid_context else [],
    )

    if platform_lock:
        conformance_path = root / "openspec/verification/core-conformance.yaml"
        integration_path = root / "openspec/integrations/INTEGRATION-PROFILES.lock.yaml"
        current_pins_common = {
            "core_baseline": baseline.get("baseline"),
            "core_baseline_sha256": _sha256_file(path),
            "conformance_suite_sha256": _sha256_file(conformance_path)
            if conformance and conformance_path.is_file()
            else None,
            "integration_lock_sha256": _sha256_file(integration_path)
            if integration_lock and integration_path.is_file()
            else None,
        }
        for raw_entry in _sequence(platform_lock.get("profiles")):
            entry = _mapping(raw_entry)
            platform = entry.get("platform")
            state = entry.get("conformance_status")
            last = _mapping(entry.get("last_verified"))
            values = list(last.values())
            empty_last = bool(last) and all(value is None for value in values)
            complete_last = bool(last) and all(bool(str(value or "")) for value in values)
            if not (empty_last or complete_last):
                errors.append(f"platform {platform} has a partial last_verified record")
            release_subject = _mapping(entry.get("release_subject"))
            current_pins = {
                "profile_sha256": entry.get("profile_sha256"),
                "verification_sha256": entry.get("verification_sha256"),
                "case_manifest_sha256": entry.get("case_manifest_sha256"),
                "release_subject_sha256": release_subject.get("sha256"),
                "release_subject_path": release_subject.get("path"),
                "release_subject_approval_id": release_subject.get("approval_id"),
                **current_pins_common,
            }
            if state == "notStarted":
                if not empty_last:
                    errors.append(f"platform {platform} notStarted state carries a verified history")
                if not release_subject or not all(value is None for value in release_subject.values()):
                    errors.append(f"platform {platform} notStarted state carries a release subject")
            elif state == "nonConformant":
                if not (empty_last or complete_last):
                    errors.append(
                        f"platform {platform} nonConformant state has a partial verified history"
                    )
            elif state == "verified":
                if not complete_last:
                    errors.append(
                        f"platform {platform} verified without a complete four-axis record"
                    )
                if not release_subject or not all(
                    bool(str(value or "")) for value in release_subject.values()
                ):
                    errors.append(
                        f"platform {platform} verified without a complete protected release subject"
                    )
                for field, value in current_pins.items():
                    if last.get(field) != value:
                        errors.append(
                            f"platform {platform} verified {field} is stale; mark needsReverification"
                        )
            elif state == "needsReverification":
                if not complete_last:
                    errors.append(
                        f"platform {platform} needsReverification state lacks the complete prior "
                        "verified record"
                    )
                elif all(last.get(field) == value for field, value in current_pins.items()):
                    errors.append(
                        f"platform {platform} needsReverification has no stale "
                        "profile/Core/conformance/integration pin"
                    )

    ratification = _mapping(baseline.get("ratification"))
    if baseline.get("status") == "accepted":
        if ratification.get("status") != "accepted":
            errors.append("accepted baseline must have accepted ratification")
        if ratification.get("execution_gate") != "open":
            errors.append("accepted baseline execution gate must be open")
        if not str(ratification.get("approval_ref") or ""):
            errors.append("accepted baseline must have approval_ref")
        if not str(baseline.get("accepted_at") or ""):
            errors.append("accepted baseline must have accepted_at")
    elif baseline.get("status") == "review":
        if ratification.get("execution_gate") != "closed":
            errors.append("review baseline execution gate must be closed")
        if baseline.get("accepted_at") is not None:
            errors.append("review baseline must not have accepted_at")
    return baseline, manifest, protected


def _yaml_guard_self_test(errors: MutableSequence[str]) -> None:
    if not yaml_ambiguities("outer:\n  key: one\n  key: two\n"):
        errors.append("YAML ambiguity guard self-test failed for a nested duplicate key")
    if not yaml_ambiguities("one: &value x\ntwo: *value\n"):
        errors.append("YAML ambiguity guard self-test failed for an alias")
    if not yaml_ambiguities("status: review\n---\nstatus: accepted\n"):
        errors.append("YAML ambiguity guard self-test failed for a multi-document stream")


def run_core_guard(root: str | Path, errors: MutableSequence[str]) -> dict[str, Any]:
    """Validate Core repository contracts and return context for deeper guards.

    The function never replaces ``errors`` and is intentionally fail-collecting.
    A malformed or absent document is represented by an empty mapping in the
    returned context so callers can continue reporting independent violations.
    """

    require_runtime()
    repository_root = Path(root).expanduser().resolve()
    documents: dict[str, Any] = {}
    _yaml_guard_self_test(errors)
    _scan_serialized_inputs(repository_root, errors)
    trust_context = _validate_trust_policy(repository_root, errors, documents)

    config_path = repository_root / "openspec/config.yaml"
    project_config = _mapping(_load_yaml(repository_root, config_path, errors, documents))
    configured_baseline = str(project_config.get("current_core_baseline") or "CORE-1.0.0")
    declared_platforms = sorted(
        str(item) for item in _sequence(project_config.get("declared_target_platforms"))
    )
    profile_platforms = sorted(
        path.parent.name
        for path in (repository_root / "openspec/platforms").glob("*/profile.md")
    )
    if declared_platforms != profile_platforms:
        errors.append("declared target platform set differs from platform profiles")
    if "current_delivery_platforms" in project_config or "not_started_platforms" in project_config:
        errors.append("Core config must not carry current-delivery/not-started lifecycle state")

    specs = _extract_specs(repository_root, errors)
    constitution_path = repository_root / "openspec/constitution.md"
    constitution = constitution_path.read_text(encoding="utf-8") if constitution_path.is_file() else ""
    policies = {item: "openspec/constitution.md" for item in POLICY_RE.findall(constitution)}
    ports_path = repository_root / "openspec/architecture/platform-ports.md"
    ports_text = ports_path.read_text(encoding="utf-8") if ports_path.is_file() else ""
    ports = {item: True for item in PORT_ID_RE.findall(ports_text)}
    port_definitions: dict[str, dict[str, str]] = {}
    port_names: list[str] = []
    for line in ports_text.splitlines():
        match = PORT_ROW_RE.match(line)
        if not match:
            continue
        port_id, name, behavior = match.groups()
        port_names.append(name)
        port_definitions[port_id] = {"name": name, "behavior": behavior}
    if len(set(port_names)) != len(port_names):
        errors.append("platform Port contract has duplicate names")
    if sorted(port_definitions) != sorted(ports):
        errors.append("platform Port definition parser differs from the Port ID set")

    acceptance_index = _validate_acceptance_index(repository_root, specs["acceptance"], errors)
    conformance, case_definitions, case_minimum_evidence, fixture_ids = _validate_conformance(
        repository_root,
        errors,
        documents,
        specs["acceptance"],
        specs["requirements"],
        policies,
        acceptance_index,
    )
    change_context = _validate_change_acceptance(
        repository_root,
        errors,
        documents,
        configured_baseline,
        specs["requirement_acceptance"],
        specs["acceptance_owner"],
        specs["requirement_paths"],
        specs["requirements"],
        specs["acceptance"],
        policies,
        ports,
        case_definitions,
        case_minimum_evidence,
    )
    integration_lock, integration_profiles = _validate_integration_lock(
        repository_root, errors, documents, conformance
    )
    platform_lock, platform_profiles, platform_chain, platform_cases, platform_support = (
        _validate_platform_lock(
            repository_root, errors, documents, declared_platforms, port_names
        )
    )
    _validate_platform_change_contracts(
        errors,
        change_context["platform_change_case_records"],
        platform_cases,
    )
    workflow_context = _validate_workflow_registry(
        repository_root, errors, documents
    )
    current_delivery = sorted(
        str(item) for item in _sequence(platform_lock.get("current_delivery_platforms"))
    )
    not_started = sorted(
        str(item) for item in _sequence(platform_lock.get("not_started_platforms"))
    )

    applicability = _mapping(conformance.get("applicability"))
    if sorted(str(item) for item in _sequence(applicability.get("default_platforms"))) != declared_platforms:
        errors.append("conformance default platforms differ from declared targets")
    if {
        "current_delivery_platforms",
        "future_not_started_platforms",
        "not_started_platforms",
    } & set(applicability):
        errors.append("Core conformance must not carry platform delivery/not-started lifecycle state")
    if _sequence(applicability.get("platform_overrides")):
        errors.append("Core conformance platform overrides are forbidden")
    if platform_lock:
        locked_platforms = sorted(
            str(_mapping(item).get("platform"))
            for item in _sequence(platform_lock.get("profiles"))
        )
        if locked_platforms != declared_platforms:
            errors.append("platform lock bindings differ from declared target platforms")
        for raw_entry in _sequence(platform_lock.get("profiles")):
            entry = _mapping(raw_entry)
            if (
                str(entry.get("platform")) in not_started
                and entry.get("conformance_status") != "notStarted"
            ):
                errors.append(
                    f"future/not-started platform {entry.get('platform')} has an inconsistent "
                    "conformance state"
                )

    baseline, manifest, protected_files = _validate_baseline(
        repository_root,
        errors,
        documents,
        configured_baseline,
        declared_platforms,
        platform_lock,
        platform_chain,
        conformance,
        integration_lock,
    )

    context: dict[str, Any] = {
        **specs,
        "policies": policies,
        "ports": ports,
        "port_names": port_names,
        "port_definitions": port_definitions,
        "acceptance_index": acceptance_index,
        "conformance": conformance,
        "case_definitions": case_definitions,
        "case_minimum_evidence": case_minimum_evidence,
        "conformance_fixture_ids": fixture_ids,
        "integration_lock": integration_lock,
        "integration_profiles": integration_profiles,
        "platform_lock": platform_lock,
        "platform_profiles": platform_profiles,
        "platform_lock_chain": platform_chain,
        "platform_case_definitions": platform_cases,
        "platform_support_definitions": platform_support,
        "baseline": baseline,
        "baseline_lock": baseline,
        "baseline_manifest": manifest,
        "protected_files": protected_files,
        "declared_target_platforms": declared_platforms,
        "current_delivery_platforms": current_delivery,
        "not_started_platforms": not_started,
        "configured_core_baseline": configured_baseline,
        "project_config": project_config,
        "yaml_documents": documents,
        **trust_context,
        **change_context,
        **workflow_context,
    }
    return context


def validate_core(root: str | Path, errors: MutableSequence[str]) -> dict[str, Any]:
    """Compatibility name for the direct Python main guard."""

    return run_core_guard(root, errors)


def main() -> int:
    root = Path(__file__).resolve().parent.parent
    errors: list[str] = []
    context = run_core_guard(root, errors)
    if errors:
        for error in errors:
            print(f"ERROR: {error}")
        return 1
    print(
        "Core SDD guard passed: "
        f"{len(context['requirements'])} requirements, "
        f"{len(context['acceptance'])} acceptance scenarios"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
