#!/usr/bin/env python3.14
"""Shared compatibility and validator helpers for ArkDeck's Python SDD guard.

This module is the semantic bridge for the Ruby-to-Python guard migration.  It
deliberately centralizes behavior where a direct translation would otherwise be
unsafe: compact JSON contract hashes, raw Git bytes, Ruby-compatible collection
coercion and path matching, strict YAML ambiguity detection, RFC 3339 time
parsing, and external verifier invocation without a host shell.

Runtime target: CPython 3.14.6 and PyYAML 6.0.3.
"""

from __future__ import annotations

import fnmatch
import hashlib
import json
import os
import re
import stat
import subprocess
import sys
import tempfile
from collections.abc import Callable, Iterable, Mapping, Sequence
from dataclasses import dataclass
from datetime import date, datetime, timedelta
from fractions import Fraction
from functools import total_ordering
from pathlib import Path
from typing import Any, Final

try:
    import yaml
    from yaml.nodes import MappingNode, Node, ScalarNode, SequenceNode
    from yaml.tokens import AliasToken, AnchorToken
except ModuleNotFoundError as exc:  # pragma: no cover - import boundary
    raise RuntimeError(
        "ArkDeck SDD guard requires PyYAML 6.0.3; install "
        "scripts/requirements-sdd.txt with CPython 3.14.6"
    ) from exc


ROOT: Final[Path] = Path(__file__).resolve().parent.parent
SUPPORTED_PYTHON: Final[str] = "3.14.6"
SUPPORTED_PYYAML: Final[str] = "6.0.3"


def require_runtime() -> None:
    actual_python = sys.version_info[:3]
    if actual_python != (3, 14, 6):
        raise RuntimeError(
            "ArkDeck SDD guard requires CPython 3.14.6; found "
            + ".".join(str(value) for value in actual_python)
        )
    actual_pyyaml = getattr(yaml, "__version__", None)
    if actual_pyyaml != SUPPORTED_PYYAML:
        raise RuntimeError(
            f"ArkDeck SDD guard requires PyYAML {SUPPORTED_PYYAML}; "
            f"found {actual_pyyaml or 'unknown'}"
        )


require_runtime()

RFC3339_DATE_TIME: Final[re.Pattern[str]] = re.compile(
    r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}"
    r"(?:\.[0-9]+)?(?:Z|[+-][0-9]{2}:[0-9]{2})"
)
_RFC3339_PARTS: Final[re.Pattern[str]] = re.compile(
    r"(?P<year>[0-9]{4})-(?P<month>[0-9]{2})-(?P<day>[0-9]{2})"
    r"T(?P<hour>[0-9]{2}):(?P<minute>[0-9]{2}):(?P<second>[0-9]{2})"
    r"(?:\.(?P<fraction>[0-9]+))?"
    r"(?P<zone>Z|(?P<offset_sign>[+-])(?P<offset_hour>[0-9]{2}):"
    r"(?P<offset_minute>[0-9]{2}))"
)
CANONICAL_GIT_OID: Final[re.Pattern[str]] = re.compile(
    r"(?:[a-f0-9]{40}|[a-f0-9]{64})"
)
PRE_ARCHIVE_INVARIANTS: Final[tuple[str, ...]] = (
    "task-packet-ready-and-pins",
    "atomic-claim-owner-and-lease",
    "canonical-resource-identity",
    "controlled-lab-pre-dispatch-authorization",
    "typed-plan-to-execution-binding",
    "hardware-evidence-provenance",
    "approval-chronology",
    "exact-task-result-aggregate-provenance",
    "acceptance-and-change-verification",
)
PLATFORM_REVALIDATION_TRIGGERS: Final[tuple[str, ...]] = (
    "implementationRevisionChanged",
    "releaseArtifactChanged",
    "osBuildChanged",
    "architectureChanged",
    "toolchainChanged",
    "platformProfileChanged",
    "platformVerificationChanged",
    "coreBaselineChanged",
    "conformanceSuiteChanged",
    "integrationLockChanged",
)
CORE_ACCEPTANCE_ID: Final[re.Pattern[str]] = re.compile(
    r"AC-[A-Z]+-[0-9]{3}-[0-9]{2}"
)
PLATFORM_ACCEPTANCE_ID: Final[re.Pattern[str]] = re.compile(
    r"[A-Z]+-M[0-9]+[A-Z]*-[A-Z0-9]+(?:-[A-Z0-9]+)*-[0-9]{3}"
)
ACCEPTANCE_EVIDENCE_CLASSES: Final[tuple[str, ...]] = (
    "contract",
    "parserGolden",
    "platform",
    "realHardware",
    "manualReview",
)


class _InvalidTreeEntry:
    __slots__ = ()

    def __repr__(self) -> str:
        return "INVALID_TREE_ENTRY"


INVALID_TREE_ENTRY: Final = _InvalidTreeEntry()


def ruby_to_s(value: Any) -> str:
    """Match Ruby's nil-safe ``to_s`` for governance document fields."""

    return "" if value is None else str(value)


def ruby_array(value: Any) -> list[Any]:
    """Match Ruby's ``Array(value)`` coercion used throughout the old guard."""

    if value is None:
        return []
    if isinstance(value, list):
        return value
    if isinstance(value, tuple):
        return list(value)
    return [value]


def ruby_truthy(value: Any) -> bool:
    """Ruby treats only nil and false as falsey."""

    return value is not None and value is not False


def dig(value: Any, *keys: Any) -> Any:
    """Nil-safe dictionary/list traversal corresponding to Hash#dig."""

    current = value
    for key in keys:
        if isinstance(current, Mapping):
            current = current.get(key)
        elif isinstance(current, Sequence) and not isinstance(
            current, (str, bytes, bytearray)
        ) and isinstance(key, int):
            if key < 0 or key >= len(current):
                return None
            current = current[key]
        else:
            return None
        if current is None:
            return None
    return current


def ordered_union(left: Iterable[Any], right: Iterable[Any]) -> list[Any]:
    """Ruby Array#| semantics without requiring hashable elements."""

    result: list[Any] = []
    for item in [*left, *right]:
        if item not in result:
            result.append(item)
    return result


def ordered_difference(left: Iterable[Any], right: Iterable[Any]) -> list[Any]:
    """Ruby Array#- semantics while preserving left-hand ordering."""

    excluded = list(right)
    return [item for item in left if item not in excluded]


def ordered_intersection(left: Iterable[Any], right: Iterable[Any]) -> list[Any]:
    """Ruby Array#& semantics without requiring hashable elements."""

    candidates = list(right)
    result: list[Any] = []
    for item in left:
        if item in candidates and item not in result:
            result.append(item)
    return result


def compact_json_bytes(value: Any) -> bytes:
    """Return bytes compatible with JSON.generate for ArkDeck hash payloads."""

    return json.dumps(
        value,
        ensure_ascii=False,
        separators=(",", ":"),
        allow_nan=False,
    ).encode("utf-8")


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_text(value: str) -> str:
    return sha256_bytes(value.encode("utf-8"))


def sha256_file(path: str | os.PathLike[str]) -> str:
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def read_utf8(path: str | os.PathLike[str]) -> str:
    """Decode exact file bytes without universal-newline translation."""

    return Path(path).read_bytes().decode("utf-8")


def write_utf8(path: str | os.PathLike[str], content: str) -> None:
    Path(path).write_bytes(content.encode("utf-8"))


def acceptance_case_contract_sha256(
    acceptance_id: str, definition: Mapping[str, Any] | None
) -> str:
    normalized = {
        "acceptanceId": acceptance_id,
        "testId": definition.get("test_id") if definition else None,
        "method": definition.get("method") if definition else None,
        "minimumEvidence": (
            definition.get("minimum_evidence") if definition else None
        ),
        "hardwareCapability": (
            definition.get("hardware_capability") if definition else None
        ),
        "sourceSha256": (
            definition.get("source_sha256") if definition else None
        ),
        "expectedResult": (
            definition.get("expected_result") if definition else None
        ),
    }
    return sha256_bytes(compact_json_bytes(normalized))


def port_contract_sha256(
    port_id: str, definition: Mapping[str, Any] | None
) -> str:
    return sha256_bytes(
        compact_json_bytes(
            {
                "portId": port_id,
                "portName": definition.get("name") if definition else None,
                "normativeBehavior": (
                    definition.get("behavior") if definition else None
                ),
            }
        )
    )


def support_cell_contract_sha256(cell: Mapping[str, Any] | None) -> str:
    return sha256_bytes(
        compact_json_bytes(
            {
                "cellId": cell.get("cellId") if cell else None,
                "implementation": cell.get("implementation") if cell else None,
                "environment": cell.get("environment") if cell else None,
            }
        )
    )


def relative(path: str | os.PathLike[str], root: Path = ROOT) -> str:
    return Path(os.path.relpath(os.fspath(path), os.fspath(root))).as_posix()


def archived_change_path(path: str | os.PathLike[str], root: Path = ROOT) -> bool:
    return relative(path, root).startswith("openspec/changes/archive/")


def _run(
    arguments: Sequence[str | os.PathLike[str]],
    *,
    timeout: float | None = None,
) -> subprocess.CompletedProcess[bytes] | None:
    try:
        return subprocess.run(
            [os.fspath(item) for item in arguments],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            shell=False,
            timeout=timeout,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None


def git_commit(revision: Any, root: Path = ROOT) -> bool:
    revision_text = ruby_to_s(revision)
    if CANONICAL_GIT_OID.fullmatch(revision_text) is None or not root.joinpath(
        ".git"
    ).exists():
        return False
    result = _run(
        ["git", "-C", root, "rev-parse", "--verify", f"{revision_text}^{{commit}}"]
    )
    return bool(
        result
        and result.returncode == 0
        and result.stdout.decode("ascii", "strict").strip() == revision_text
    )


def git_head_revision(root: Path = ROOT) -> str | None:
    if not root.joinpath(".git").exists():
        return None
    result = _run(["git", "-C", root, "rev-parse", "HEAD"])
    if not result or result.returncode != 0:
        return None
    try:
        return result.stdout.decode("ascii", "strict").strip()
    except UnicodeDecodeError:
        return None


def git_ancestor(ancestor: Any, descendant: Any, root: Path = ROOT) -> bool:
    if not git_commit(ancestor, root) or not git_commit(descendant, root):
        return False
    result = _run(
        ["git", "-C", root, "merge-base", "--is-ancestor", ancestor, descendant]
    )
    return bool(result and result.returncode == 0)


def git_diff_entries(
    base_revision: Any, result_revision: Any, root: Path = ROOT
) -> list[dict[str, str]] | None:
    result = _run(
        [
            "git",
            "-C",
            root,
            "diff",
            "--name-status",
            "--no-renames",
            "--diff-filter=ACDMRTUXB",
            base_revision,
            result_revision,
            "--",
        ]
    )
    if not result or result.returncode != 0:
        return None
    try:
        source = result.stdout.decode("utf-8", "strict")
    except UnicodeDecodeError:
        return None
    entries: list[dict[str, str]] = []
    for line in source.splitlines():
        if not line:
            continue
        status_code, separator, path = line.partition("\t")
        if not separator:
            path = ""
        entries.append({"status": status_code, "path": path})
    return sorted(entries, key=lambda entry: ruby_to_s(entry.get("path")))


def git_diff_paths(
    base_revision: Any, result_revision: Any, root: Path = ROOT
) -> list[str] | None:
    entries = git_diff_entries(base_revision, result_revision, root)
    return None if entries is None else sorted(entry["path"] for entry in entries)


def git_file_bytes(
    revision: Any, path: str, root: Path = ROOT
) -> bytes | None:
    if not git_commit(revision, root):
        return None
    result = _run(["git", "-C", root, "show", f"{revision}:{path}"])
    return result.stdout if result and result.returncode == 0 else None


def git_file_sha256(
    revision: Any, path: str, root: Path = ROOT
) -> str | None:
    content = git_file_bytes(revision, path, root)
    return sha256_bytes(content) if content is not None else None


def git_file_content(
    revision: Any, path: str, root: Path = ROOT
) -> str | None:
    content = git_file_bytes(revision, path, root)
    if content is None:
        return None
    try:
        return content.decode("utf-8", "strict")
    except UnicodeDecodeError:
        return None


TreeIdentity = tuple[str, str, str]


def git_tree_entry_identity(
    revision: Any, path: str, root: Path = ROOT
) -> TreeIdentity | _InvalidTreeEntry | None:
    if not git_commit(revision, root) or not path:
        return None
    result = _run(
        ["git", "-C", root, "ls-tree", "-z", revision, "--", f":(literal){path}"]
    )
    if not result or result.returncode != 0:
        return None
    records = [record for record in result.stdout.split(b"\0") if record]
    if not records:
        return None
    if len(records) != 1:
        return INVALID_TREE_ENTRY
    metadata, separator, raw_path = records[0].partition(b"\t")
    if not separator or raw_path != path.encode("utf-8"):
        return INVALID_TREE_ENTRY
    parts = metadata.decode("ascii", "strict").split(" ", 2)
    if len(parts) != 3 or not all(parts):
        return INVALID_TREE_ENTRY
    return parts[0], parts[1], parts[2]


def validate_task_result_aggregate(
    *,
    errors: list[str],
    subject: str,
    base_revision: Any,
    result_revision: Any,
    runs: Sequence[Mapping[str, Any]],
    provenance_files: Mapping[str, str],
    root: Path = ROOT,
) -> bool:
    valid = True
    if not (
        git_commit(base_revision, root)
        and git_commit(result_revision, root)
        and git_ancestor(base_revision, result_revision, root)
    ):
        errors.append(f"{subject} aggregate base/result is not a canonical ancestor pair")
        return False
    if not runs:
        errors.append(f"{subject} aggregate has no exact bound done runs")
        return False

    contributions: dict[str, list[TreeIdentity | tuple[str]]] = {}
    for run in runs:
        run_result = run.get("resultRevision")
        if not (
            run.get("baseRevision") == base_revision
            and git_commit(run_result, root)
            and git_ancestor(base_revision, run_result, root)
            and git_ancestor(run_result, result_revision, root)
        ):
            errors.append(
                f"{subject} run {run.get('runId')} is not rooted at the exact "
                "aggregate base/result lineage"
            )
            valid = False
            continue

        entries = git_diff_entries(base_revision, run_result, root)
        if entries is None or sorted(entry["path"] for entry in entries) != sorted(
            ruby_array(run.get("modifiedFiles"))
        ):
            errors.append(
                f"{subject} run {run.get('runId')} does not contribute its exact "
                "approved Git diff"
            )
            valid = False
            continue
        for entry in entries:
            identity = git_tree_entry_identity(run_result, entry["path"], root)
            if identity is INVALID_TREE_ENTRY:
                errors.append(
                    f"{subject} run {run.get('runId')} has an ambiguous Git tree "
                    f"path {entry['path']}"
                )
                valid = False
            else:
                contributions.setdefault(entry["path"], []).append(
                    identity if identity is not None else ("absent",)
                )

    conflicting_paths = sorted(
        path
        for path, identities in contributions.items()
        if any(identity != identities[0] for identity in identities[1:])
    )
    if conflicting_paths:
        errors.append(
            f"{subject} bound runs have conflicting final Git tree identities: "
            f"{', '.join(conflicting_paths)}"
        )
        valid = False

    aggregate_entries = git_diff_entries(base_revision, result_revision, root)
    if aggregate_entries is None:
        errors.append(f"{subject} aggregate Git diff cannot be read")
        return False
    aggregate_by_path = {entry["path"]: entry for entry in aggregate_entries}
    if len(aggregate_by_path) != len(aggregate_entries):
        errors.append(f"{subject} aggregate Git diff contains duplicate paths")
        valid = False

    owned_paths = sorted(contributions)
    aggregate_paths = sorted(aggregate_by_path)
    missing_owned_paths = ordered_difference(owned_paths, aggregate_paths)
    if missing_owned_paths:
        errors.append(
            f"{subject} drops approved Task result paths: "
            f"{', '.join(missing_owned_paths)}"
        )
        valid = False
    for path in owned_paths:
        identities = contributions[path]
        if path not in aggregate_by_path or any(
            identity != identities[0] for identity in identities[1:]
        ):
            continue
        final_identity = git_tree_entry_identity(result_revision, path, root)
        expected_identity = None if identities[0] == ("absent",) else identities[0]
        if final_identity != expected_identity:
            errors.append(
                f"{subject} final Git tree overrides approved Task result path {path}"
            )
            valid = False

    unowned_paths = ordered_difference(aggregate_paths, owned_paths)
    unknown_paths = ordered_difference(unowned_paths, provenance_files.keys())
    if unknown_paths:
        errors.append(
            f"{subject} contains paths not owned by any approved Task run or exact "
            f"lifecycle provenance: {', '.join(unknown_paths)}"
        )
        valid = False
    for path in ordered_intersection(unowned_paths, provenance_files.keys()):
        identity = git_tree_entry_identity(result_revision, path, root)
        exact_regular_blob = (
            isinstance(identity, tuple)
            and len(identity) == 3
            and identity[0] == "100644"
            and identity[1] == "blob"
            and git_file_sha256(result_revision, path, root) == provenance_files[path]
        )
        if not exact_regular_blob:
            errors.append(
                f"{subject} lifecycle provenance bytes or Git mode drift at {path}"
            )
            valid = False
    return valid


def git_tree_paths(
    revision: Any, prefix: str, root: Path = ROOT
) -> list[str] | None:
    if not git_commit(revision, root):
        return None
    result = _run(
        ["git", "-C", root, "ls-tree", "-r", "--name-only", revision, "--", prefix]
    )
    if not result or result.returncode != 0:
        return None
    try:
        return sorted(line for line in result.stdout.decode("utf-8").splitlines() if line)
    except UnicodeDecodeError:
        return None


def git_path_add_commits(
    ancestor_revision: Any,
    descendant_revision: Any,
    path: str,
    root: Path = ROOT,
) -> list[str] | None:
    if not (
        git_commit(ancestor_revision, root)
        and git_commit(descendant_revision, root)
        and git_ancestor(ancestor_revision, descendant_revision, root)
    ):
        return None
    result = _run(
        [
            "git",
            "-C",
            root,
            "log",
            "--format=%H",
            "--diff-filter=A",
            "--reverse",
            f"{ancestor_revision}..{descendant_revision}",
            "--",
            path,
        ]
    )
    if not result or result.returncode != 0:
        return None
    try:
        return [line for line in result.stdout.decode("ascii").splitlines() if line]
    except UnicodeDecodeError:
        return None


def yaml_ambiguities(source: str) -> list[str]:
    """Detect YAML constructs forbidden by ArkDeck before semantic loading.

    PyYAML resolves aliases during composition, so anchor and alias tokens are
    rejected in a separate lexical pass. Duplicate keys and merge keys are
    rejected from the composed node graph using their raw scalar spelling,
    matching Psych's old guard rather than Python value equality.
    """

    findings: list[str] = []
    tokens = list(yaml.scan(source, Loader=yaml.SafeLoader))
    for token in tokens:
        if isinstance(token, AnchorToken):
            findings.append(
                f"$yaml/line[{token.start_mark.line + 1}]: YAML anchors are forbidden"
            )
        elif isinstance(token, AliasToken):
            findings.append(
                f"$yaml/line[{token.start_mark.line + 1}]: YAML aliases are forbidden"
            )

    documents = list(yaml.compose_all(source, Loader=yaml.SafeLoader))
    if len(documents) != 1:
        findings.append("$yaml: exactly one YAML document is required")

    def visit(node: Node | None, location: str) -> None:
        if node is None:
            return
        if isinstance(node, MappingNode):
            seen: set[str] = set()
            for index, (key, value) in enumerate(node.value):
                if not isinstance(key, ScalarNode):
                    findings.append(
                        f"{location}/key[{index}]: mapping keys must be scalars"
                    )
                    key_name = None
                else:
                    key_name = ruby_to_s(key.value)
                    if key_name in seen:
                        findings.append(
                            f"{location}/{key_name}: duplicate YAML mapping key"
                        )
                    if key_name == "<<":
                        findings.append(
                            f"{location}/{key_name}: YAML merge keys are forbidden"
                        )
                    seen.add(key_name)
                visit(key, f"{location}/key[{index}]")
                visit(value, f"{location}/value[{index}]")
        elif isinstance(node, SequenceNode):
            for index, child in enumerate(node.value):
                visit(child, f"{location}[{index}]")

    for index, document in enumerate(documents):
        visit(document, f"$yaml/document[{index}]/root")
    return findings


def yaml_safe_load(source: str) -> Any:
    """Load one YAML document after fail-closed ambiguity validation."""

    findings = yaml_ambiguities(source)
    if findings:
        raise yaml.YAMLError("; ".join(findings))
    return yaml.safe_load(source)


def platform_context_for_task(
    revision: Any, task: Mapping[str, Any] | None, root: Path = ROOT
) -> dict[str, Any] | None:
    if task is None or not git_commit(revision, root):
        return None
    lock_source = git_file_content(
        revision, "openspec/platforms/PLATFORM-PROFILES.lock.yaml", root
    )
    if lock_source is None:
        return None
    try:
        lock = yaml_safe_load(lock_source) or {}
        entry = next(
            (
                candidate
                for candidate in ruby_array(lock.get("profiles"))
                if candidate.get("id") == dig(task, "platformProfile", "id")
                and candidate.get("version")
                == dig(task, "platformProfile", "version")
                and candidate.get("platform") == task.get("platform")
                and candidate.get("profile_sha256")
                == dig(task, "platformProfile", "sha256")
            ),
            None,
        )
        if entry is None or git_file_sha256(
            revision, ruby_to_s(entry.get("profile_path")), root
        ) != entry.get("profile_sha256"):
            return None
        case_source = git_file_content(
            revision, ruby_to_s(entry.get("case_manifest_path")), root
        )
        if case_source is None or sha256_text(case_source) != entry.get(
            "case_manifest_sha256"
        ):
            return None
        case_document = yaml_safe_load(case_source) or {}
        if case_document.get("platform") != task.get("platform"):
            return None
        return {"lock": lock, "entry": entry, "caseDocument": case_document}
    except (yaml.YAMLError, AttributeError, TypeError):
        return None


PatternLike = str | re.Pattern[str]


def _search(pattern: PatternLike, text: str, pos: int = 0) -> re.Match[str] | None:
    if isinstance(pattern, str):
        return re.compile(pattern, re.MULTILINE).search(text, pos)
    return pattern.search(text, pos)


def canonical_markdown_block(
    text: str,
    heading_pattern: PatternLike,
    following_heading_pattern: PatternLike,
) -> str | None:
    start_match = _search(heading_pattern, text)
    if start_match is None:
        return None
    tail = text[start_match.start() :]
    following_heading = _search(
        following_heading_pattern, tail, len(start_match.group(0))
    )
    block = tail[: following_heading.start()] if following_heading else tail
    return f"{block.rstrip()}\n"


_REQUIREMENT_HEADING = re.compile(
    r"^### Requirement: REQ-[A-Z0-9-]+\b.*$", re.MULTILINE
)
_LEVEL_1_TO_3_HEADING = re.compile(r"^#{1,3} ", re.MULTILINE)


def canonical_non_requirement_content(text: str) -> str:
    remainder = text
    outside: list[str] = []
    while True:
        start_match = _REQUIREMENT_HEADING.search(remainder)
        if start_match is None:
            outside.append(remainder)
            break
        outside.append(remainder[: start_match.start()])
        tail = remainder[start_match.start() :]
        following_heading = _LEVEL_1_TO_3_HEADING.search(
            tail, len(start_match.group(0))
        )
        if following_heading is None:
            break
        remainder = tail[following_heading.start() :]
    normalized_lines = [line.rstrip() for line in "".join(outside).splitlines()]
    normalized_lines = [line for line in normalized_lines if line]
    return "" if not normalized_lines else "\n".join(normalized_lines) + "\n"


def behavior_target_spec_path(delta_path: str) -> str | None:
    match = re.search(r"(?:^|/)specs/(.+/spec\.md)$", ruby_to_s(delta_path))
    return f"openspec/specs/{match.group(1)}" if match else None


def normative_spec_snapshot(
    *,
    sources: Sequence[Mapping[str, str]],
    errors: list[str],
    subject: str,
) -> dict[str, Any]:
    requirement_records: dict[str, dict[str, Any]] = {}
    requirement_acceptance: dict[str, list[str]] = {}
    acceptance_owner: dict[str, str] = {}
    files: dict[str, dict[str, str]] = {}
    requirement_heading = re.compile(
        r"^### Requirement: (REQ-[A-Z0-9-]+)\b", re.MULTILINE
    )
    for source in sources:
        path = source["path"]
        text = source["text"]
        files[path] = {
            "sha256": sha256_text(text),
            "non_requirement_sha256": sha256_text(
                canonical_non_requirement_content(text)
            ),
        }
        for requirement_id in requirement_heading.findall(text):
            if requirement_id in requirement_records:
                errors.append(f"{subject} contains duplicate Requirement {requirement_id}")
                continue
            block = canonical_markdown_block(
                text,
                re.compile(
                    rf"^### Requirement: {re.escape(requirement_id)}\b.*$",
                    re.MULTILINE,
                ),
                _LEVEL_1_TO_3_HEADING,
            )
            if block is None:
                errors.append(
                    f"{subject} cannot canonicalize Requirement {requirement_id}"
                )
                continue
            acceptance_ids = re.findall(
                r"^#### Scenario: (AC-[A-Z0-9-]+)\b", block, re.MULTILINE
            )
            if not acceptance_ids:
                errors.append(
                    f"{subject} Requirement {requirement_id} has no Scenario"
                )
            requirement_records[requirement_id] = {
                "path": path,
                "block_sha256": sha256_text(block),
                "acceptance": acceptance_ids,
            }
            requirement_acceptance[requirement_id] = acceptance_ids
            for acceptance_id in acceptance_ids:
                prior_owner = acceptance_owner.get(acceptance_id)
                if prior_owner is not None:
                    errors.append(
                        f"{subject} assigns Acceptance {acceptance_id} to both "
                        f"{prior_owner} and {requirement_id}"
                    )
                else:
                    acceptance_owner[acceptance_id] = requirement_id
    return {
        "requirements": requirement_records,
        "requirement_acceptance": requirement_acceptance,
        "acceptance_owner": acceptance_owner,
        "files": files,
    }


def git_normative_spec_snapshot(
    *, revision: Any, errors: list[str], subject: str, root: Path = ROOT
) -> dict[str, Any] | None:
    paths = git_tree_paths(revision, "openspec/specs", root)
    if paths is None:
        errors.append(f"{subject} cannot read the Git specs tree at {revision}")
        return None
    spec_paths = [
        path
        for path in paths
        if re.fullmatch(r"openspec/specs/.+/spec\.md", path) is not None
    ]
    sources: list[dict[str, str]] = []
    for path in spec_paths:
        text = git_file_content(revision, path, root)
        if text is None:
            errors.append(f"{subject} cannot read {path} at {revision}")
        else:
            sources.append({"path": path, "text": text})
    return normative_spec_snapshot(sources=sources, errors=errors, subject=subject)


def apply_behavior_overlay_to_snapshot(
    baseline_snapshot: Mapping[str, Any], overlay: Mapping[str, Any]
) -> dict[str, dict[str, Any]]:
    expected = {
        key: dict(value) for key, value in baseline_snapshot["requirements"].items()
    }
    for requirement_id, record in overlay["records"].items():
        if record.get("operation") not in ("added", "modified"):
            continue
        expected[requirement_id] = {
            "path": record.get("target_path"),
            "block_sha256": record.get("block_sha256"),
            "acceptance": record.get("scenarios"),
        }
    return expected


def iter_hash_entries(value: Any) -> Iterable[Mapping[str, Any]]:
    if isinstance(value, Mapping):
        if "path" in value and "sha256" in value:
            yield value
        for child in value.values():
            yield from iter_hash_entries(child)
    elif isinstance(value, list):
        for child in value:
            yield from iter_hash_entries(child)


def walk_hash_entries(
    value: Any, callback: Callable[[Mapping[str, Any]], None] | None = None
) -> list[Mapping[str, Any]]:
    entries = list(iter_hash_entries(value))
    if callback is not None:
        for entry in entries:
            callback(entry)
    return entries


_FRONTMATTER = re.compile(r"\A---\s*\n(.*?)\n---\s*\n", re.DOTALL)


def markdown_frontmatter(path: str | os.PathLike[str]) -> dict[str, Any]:
    match = _FRONTMATTER.search(read_utf8(path))
    if match is None:
        return {}
    document = yaml_safe_load(match.group(1))
    return document or {}


def validate_platform_revalidation(
    *,
    errors: list[str],
    subject: str,
    matrix: Any,
    declared_platforms: Sequence[str],
    current_delivery_platforms: Sequence[str],
) -> None:
    normalized = matrix if isinstance(matrix, Mapping) else {}
    actual_platforms = sorted(ruby_to_s(key) for key in normalized.keys())
    if actual_platforms != list(declared_platforms):
        errors.append(f"{subject} lacks an exact target-platform revalidation matrix")
    for platform, disposition in normalized.items():
        valid = (
            isinstance(disposition, Mapping)
            and disposition.get("disposition")
            in ("reverifyRequired", "nonConformant", "deferred")
            and ruby_to_s(disposition.get("owner")) != ""
            and ruby_to_s(disposition.get("milestone")) != ""
        )
        if not valid:
            errors.append(
                f"{subject} has invalid revalidation disposition for {platform}"
            )
        if (
            ruby_to_s(platform) in current_delivery_platforms
            and isinstance(disposition, Mapping)
            and disposition.get("disposition") == "deferred"
        ):
            errors.append(f"{subject} defers current delivery platform {platform}")


def validate_platform_lifecycle(
    *,
    errors: list[str],
    subject: str,
    lock: Mapping[str, Any],
    declared_platforms: Sequence[str],
) -> None:
    current = [ruby_to_s(value) for value in ruby_array(lock.get("current_delivery_platforms"))]
    not_started = [ruby_to_s(value) for value in ruby_array(lock.get("not_started_platforms"))]
    if len(set(current)) != len(current):
        errors.append(f"{subject} has duplicate current-delivery platforms")
    if len(set(not_started)) != len(not_started):
        errors.append(f"{subject} has duplicate not-started platforms")
    if set(current).intersection(not_started):
        errors.append(f"{subject} platform lifecycle sets overlap")
    if sorted(current + not_started) != list(declared_platforms):
        errors.append(f"{subject} platform lifecycle does not exactly cover declared targets")
    profiles = ruby_array(lock.get("profiles"))
    profile_platforms = [ruby_to_s(entry.get("platform")) for entry in profiles]
    if sorted(profile_platforms) != list(declared_platforms):
        errors.append(f"{subject} profile set differs from declared targets")
    for platform in not_started:
        entry = next(
            (
                candidate
                for candidate in profiles
                if ruby_to_s(candidate.get("platform")) == platform
            ),
            None,
        )
        if entry is None or entry.get("conformance_status") != "notStarted":
            errors.append(
                f"{subject} not-started platform {platform} is not in notStarted "
                "conformance state"
            )


def validate_platform_transition(
    *,
    errors: list[str],
    subject: str,
    prior: Mapping[str, Any],
    current: Mapping[str, Any],
) -> None:
    prior_entries = {
        entry.get("platform"): entry for entry in ruby_array(prior.get("profiles"))
    }
    for entry in ruby_array(current.get("profiles")):
        previous = prior_entries.get(entry.get("platform"))
        if previous is None:
            continue
        if (
            previous.get("conformance_status") in ("verified", "needsReverification")
            and entry.get("conformance_status") == "notStarted"
        ):
            errors.append(
                f"{subject} illegally resets {entry.get('platform')} conformance "
                "history to notStarted"
            )
        if (
            entry.get("conformance_status")
            in ("needsReverification", "nonConformant")
            and previous.get("conformance_status")
            in ("verified", "needsReverification")
            and entry.get("last_verified") != previous.get("last_verified")
        ):
            errors.append(
                f"{subject} {entry.get('platform')} "
                f"{entry.get('conformance_status')} erases or rewrites prior "
                "verified pins/evidence"
            )


def change_supersession_cycles(links: Mapping[str, str | None]) -> list[list[str]]:
    cycles: list[list[str]] = []
    for start in links:
        order: list[str] = []
        positions: dict[str, int] = {}
        cursor: str | None = start
        while cursor is not None and cursor in links:
            if cursor in positions:
                cycle = sorted(order[positions[cursor] :])
                if cycle not in cycles:
                    cycles.append(cycle)
                break
            positions[cursor] = len(order)
            order.append(cursor)
            cursor = links[cursor]
    return cycles


@total_ordering
@dataclass(frozen=True, slots=True)
class Rfc3339Instant:
    """An exact UTC instant backed by rational seconds.

    Ruby DateTime preserves all fractional-second digits.  CPython datetime
    truncates to microseconds, which can reverse approval/lease chronology when
    two records differ only after the sixth digit.  The guard only needs exact
    ordering and timedelta adjustment, so storing rational seconds avoids both
    truncation and floating-point timestamps.
    """

    seconds: Fraction

    @staticmethod
    def _datetime_seconds(value: datetime) -> Fraction:
        if value.tzinfo is None or value.utcoffset() is None:
            raise TypeError("cannot compare an aware RFC3339 instant to naive datetime")
        ordinal_seconds = Fraction((value.toordinal() - 1) * 86_400)
        clock_seconds = Fraction(
            value.hour * 3_600 + value.minute * 60 + value.second
        ) + Fraction(value.microsecond, 1_000_000)
        offset = value.utcoffset()
        assert offset is not None
        offset_seconds = Fraction(
            offset.days * 86_400 + offset.seconds,
        ) + Fraction(offset.microseconds, 1_000_000)
        return ordinal_seconds + clock_seconds - offset_seconds

    @classmethod
    def coerce(cls, value: Rfc3339Instant | datetime) -> Rfc3339Instant:
        if isinstance(value, cls):
            return value
        if isinstance(value, datetime):
            return cls(cls._datetime_seconds(value))
        raise TypeError(f"unsupported instant type: {type(value).__name__}")

    def __eq__(self, other: object) -> bool:
        if not isinstance(other, (Rfc3339Instant, datetime)):
            return NotImplemented
        return self.seconds == self.coerce(other).seconds

    def __lt__(self, other: object) -> bool:
        if not isinstance(other, (Rfc3339Instant, datetime)):
            return NotImplemented
        return self.seconds < self.coerce(other).seconds

    def __sub__(
        self, other: timedelta | Rfc3339Instant | datetime
    ) -> Rfc3339Instant | Fraction:
        if isinstance(other, timedelta):
            delta = Fraction(other.days * 86_400 + other.seconds) + Fraction(
                other.microseconds, 1_000_000
            )
            return Rfc3339Instant(self.seconds - delta)
        return self.seconds - self.coerce(other).seconds

    def __add__(self, other: timedelta) -> Rfc3339Instant:
        if not isinstance(other, timedelta):
            return NotImplemented
        delta = Fraction(other.days * 86_400 + other.seconds) + Fraction(
            other.microseconds, 1_000_000
        )
        return Rfc3339Instant(self.seconds + delta)


def parse_iso8601(value: str) -> Rfc3339Instant:
    match = _RFC3339_PARTS.fullmatch(value)
    if match is None:
        raise ValueError("not an RFC 3339 date-time")
    year = int(match.group("year"))
    month = int(match.group("month"))
    day = int(match.group("day"))
    hour = int(match.group("hour"))
    minute = int(match.group("minute"))
    second = int(match.group("second"))
    if hour > 23 or minute > 59 or second > 60:
        raise ValueError("invalid RFC 3339 clock time")
    ordinal = date(year, month, day).toordinal()
    fraction_text = match.group("fraction")
    fractional_second = (
        Fraction(int(fraction_text), 10 ** len(fraction_text))
        if fraction_text
        else Fraction(0)
    )
    zone = match.group("zone")
    offset_seconds = 0
    if zone != "Z":
        offset_hour = int(match.group("offset_hour"))
        offset_minute = int(match.group("offset_minute"))
        if offset_hour > 23 or offset_minute > 59:
            raise ValueError("invalid RFC 3339 UTC offset")
        offset_seconds = offset_hour * 3_600 + offset_minute * 60
        if match.group("offset_sign") == "-":
            offset_seconds = -offset_seconds
    utc_seconds = (
        Fraction((ordinal - 1) * 86_400)
        + Fraction(hour * 3_600 + minute * 60 + second)
        + fractional_second
        - Fraction(offset_seconds)
    )
    return Rfc3339Instant(utc_seconds)


def claim_precedes_successor(
    *,
    claimed_at: Rfc3339Instant | datetime,
    successor_approved_at: Rfc3339Instant | datetime,
) -> bool:
    return Rfc3339Instant.coerce(claimed_at) < Rfc3339Instant.coerce(
        successor_approved_at
    )


def predecessor_claim_closed_before_successor(
    *,
    claimed_at: Rfc3339Instant | datetime,
    terminal_at: Rfc3339Instant | datetime | None,
    successor_approved_at: Rfc3339Instant | datetime,
) -> bool:
    normalized_successor = Rfc3339Instant.coerce(successor_approved_at)
    return claim_precedes_successor(
        claimed_at=claimed_at, successor_approved_at=normalized_successor
    ) and terminal_at is not None and Rfc3339Instant.coerce(
        terminal_at
    ) < normalized_successor


def required_change_artifact_paths(
    change_root: Path, proposal: Mapping[str, Any]
) -> list[Path]:
    paths = [
        change_root / name
        for name in (
            "proposal.md",
            "scope.yaml",
            "design.md",
            "verification.md",
            "review.md",
            "ready-review.md",
            "acceptance-cases.yaml",
        )
    ]
    if proposal.get("schema") == "arkdeck-platform":
        paths.append(change_root / "spec-impact.md")
    return paths


def expected_change_input_paths(change_root: Path, root: Path = ROOT) -> list[str]:
    proposal_path = change_root / "proposal.md"
    proposal = markdown_frontmatter(proposal_path) if proposal_path.is_file() else {}
    paths = required_change_artifact_paths(change_root, proposal)
    if proposal.get("schema") == "arkdeck-behavior":
        paths.extend(path for path in change_root.glob("specs/**/*.md") if path.is_file())
    return sorted(set(relative(path, root) for path in paths))


def build_behavior_overlay(
    *,
    delta_sources: Sequence[Mapping[str, str]],
    baseline_requirement_acceptance: Mapping[str, Sequence[str]],
    baseline_acceptance_owner: Mapping[str, str],
    errors: list[str],
    subject: str,
    baseline_requirement_paths: Mapping[str, str] | None = None,
) -> dict[str, Any]:
    baseline_requirement_paths = baseline_requirement_paths or {}
    records: dict[str, dict[str, Any]] = {}
    section_pattern = re.compile(
        r"## (ADDED|MODIFIED|REMOVED|RENAMED) Requirements\s*"
    )
    requirement_pattern = re.compile(r"### Requirement: (REQ-[A-Z0-9-]+)\b")
    scenario_pattern = re.compile(r"#### Scenario: (AC-[A-Z0-9-]+)\b")
    for source in delta_sources:
        section: str | None = None
        current_requirement: str | None = None
        fenced = False
        html_comment = False
        seen_sections: set[str] = set()
        source_path = source["path"]
        source_text = source["text"]
        for line_number, line in enumerate(source_text.splitlines(keepends=True), 1):
            if re.match(r"(?:```|~~~)", line):
                fenced = not fenced
                continue
            if fenced:
                continue
            if html_comment:
                if "-->" in line:
                    html_comment = False
                continue
            if "<!--" in line:
                if "-->" not in line:
                    html_comment = True
                continue

            match = section_pattern.fullmatch(line)
            if match:
                section = match.group(1).lower()
                if section in seen_sections:
                    errors.append(
                        f"{subject} repeats the {match.group(1)} Requirements "
                        f"section in {source_path}"
                    )
                seen_sections.add(section)
                current_requirement = None
                continue
            if line.startswith("## "):
                section = None
                current_requirement = None
                continue

            match = requirement_pattern.match(line)
            if match:
                current_requirement = None
                requirement_id = match.group(1)
                if section == "renamed":
                    errors.append(
                        f"{subject} uses unsupported V1 RENAMED Requirement "
                        f"{requirement_id}; create a complete MODIFIED replacement "
                        "with stable IDs"
                    )
                    continue
                if section == "removed":
                    errors.append(
                        f"{subject} uses unsupported V1 REMOVED Requirement "
                        f"{requirement_id}; removal requires a future "
                        "tombstone/migration contract"
                    )
                    continue
                if section not in ("added", "modified"):
                    errors.append(
                        f"{subject} has Requirement {requirement_id} outside an "
                        "ADDED/MODIFIED section"
                    )
                    continue
                if requirement_id in records:
                    errors.append(f"{subject} declares {requirement_id} more than once")
                    continue
                block = canonical_markdown_block(
                    source_text,
                    re.compile(
                        rf"^### Requirement: {re.escape(requirement_id)}\b.*$",
                        re.MULTILINE,
                    ),
                    _LEVEL_1_TO_3_HEADING,
                )
                records[requirement_id] = {
                    "operation": section,
                    "scenarios": [],
                    "path": source_path,
                    "target_path": behavior_target_spec_path(source_path),
                    "line": line_number,
                    "block_sha256": sha256_text(block or ""),
                }
                if records[requirement_id]["target_path"] is None:
                    errors.append(
                        f"{subject} delta {source_path} does not map to "
                        "openspec/specs/<capability>/spec.md"
                    )
                current_requirement = requirement_id
                continue

            match = scenario_pattern.match(line)
            if match is None:
                if section in ("removed", "renamed") and line.strip():
                    errors.append(
                        f"{subject} has unsupported V1 {section.upper()} content "
                        f"at {source_path}:{line_number}"
                    )
                continue
            acceptance_id = match.group(1)
            if current_requirement is None:
                errors.append(
                    f"{subject} has Scenario {acceptance_id} outside an "
                    "ADDED/MODIFIED Requirement"
                )
                continue
            record = records[current_requirement]
            if record.get("operation") == "removed":
                errors.append(
                    f"{subject} removed Requirement {current_requirement} must be "
                    "a tombstone without Scenario blocks"
                )
                continue
            if acceptance_id in record["scenarios"]:
                errors.append(
                    f"{subject} declares Scenario {acceptance_id} more than once "
                    f"in {current_requirement}"
                )
                continue
            record["scenarios"].append(acceptance_id)
            scenario_block = canonical_markdown_block(
                source_text,
                re.compile(
                    rf"^#### Scenario: {re.escape(acceptance_id)}\b.*$",
                    re.MULTILINE,
                ),
                re.compile(r"^#{1,4} ", re.MULTILINE),
            )
            record.setdefault("scenario_metadata", {})[acceptance_id] = {
                "path": source_path,
                "anchor": acceptance_id,
                "block_sha256": sha256_text(scenario_block or ""),
            }
        if fenced:
            errors.append(f"{subject} has an unclosed Markdown fence in {source_path}")

    effective_requirements = {
        key: list(value) for key, value in baseline_requirement_acceptance.items()
    }
    touched_requirements: list[str] = []
    touched_acceptance: list[str] = []
    scenario_sources: dict[str, dict[str, Any]] = {}
    baseline_targets = list(baseline_requirement_paths.values())
    for requirement_id, record in records.items():
        operation = record["operation"]
        scenarios = record["scenarios"]
        touched_requirements.append(requirement_id)
        if operation == "added":
            if requirement_id in baseline_requirement_acceptance:
                errors.append(
                    f"{subject} ADDED Requirement {requirement_id} already exists "
                    "in its baseline"
                )
            if record.get("target_path") not in baseline_targets:
                errors.append(
                    f"{subject} ADDED Requirement {requirement_id} targets a new "
                    "spec file; V1 requires adding to an existing capability spec "
                    "so full-file archive equality is deterministic"
                )
            if not scenarios:
                errors.append(
                    f"{subject} ADDED Requirement {requirement_id} has no complete "
                    "Scenario set"
                )
            for acceptance_id in scenarios:
                if acceptance_id in baseline_acceptance_owner:
                    errors.append(
                        f"{subject} ADDED Requirement {requirement_id} reuses "
                        f"baseline Acceptance {acceptance_id}"
                    )
                touched_acceptance.append(acceptance_id)
                scenario_sources[acceptance_id] = record["scenario_metadata"][
                    acceptance_id
                ]
            if requirement_id not in baseline_requirement_acceptance:
                effective_requirements[requirement_id] = list(scenarios)
        elif operation == "modified":
            baseline_scenarios = baseline_requirement_acceptance.get(requirement_id)
            if baseline_scenarios is None:
                errors.append(
                    f"{subject} MODIFIED Requirement {requirement_id} does not "
                    "exist in its baseline"
                )
                continue
            baseline_scenarios = list(baseline_scenarios)
            baseline_path = baseline_requirement_paths.get(requirement_id)
            if baseline_path is not None and record.get("target_path") != baseline_path:
                errors.append(
                    f"{subject} MODIFIED Requirement {requirement_id} targets "
                    f"{record.get('target_path')} instead of baseline path "
                    f"{baseline_path}"
                )
            if not scenarios:
                errors.append(
                    f"{subject} MODIFIED Requirement {requirement_id} has no "
                    "complete replacement Scenario set"
                )
            missing = ordered_difference(baseline_scenarios, scenarios)
            if missing:
                errors.append(
                    f"{subject} MODIFIED Requirement {requirement_id} removes "
                    f"Acceptance {', '.join(missing)}; V1 requires preserving all "
                    "old AC IDs"
                )
            for acceptance_id in scenarios:
                baseline_owner = baseline_acceptance_owner.get(acceptance_id)
                if baseline_owner is not None and baseline_owner != requirement_id:
                    errors.append(
                        f"{subject} MODIFIED Requirement {requirement_id} "
                        f"moves/reuses Acceptance {acceptance_id} from {baseline_owner}"
                    )
                scenario_sources[acceptance_id] = record["scenario_metadata"][
                    acceptance_id
                ]
            touched_acceptance.extend(ordered_union(baseline_scenarios, scenarios))
            effective_requirements[requirement_id] = list(scenarios)

    effective_acceptance_owner: dict[str, str] = {}
    for requirement_id, acceptance_ids in effective_requirements.items():
        for acceptance_id in acceptance_ids:
            prior_owner = effective_acceptance_owner.get(acceptance_id)
            if prior_owner is not None and prior_owner != requirement_id:
                errors.append(
                    f"{subject} effective overlay assigns Acceptance {acceptance_id} "
                    f"to both {prior_owner} and {requirement_id}"
                )
            else:
                effective_acceptance_owner[acceptance_id] = requirement_id
    if not records:
        errors.append(f"{subject} has no ADDED/MODIFIED/REMOVED Requirement")
    return {
        "records": records,
        "effective_requirements": sorted(effective_requirements),
        "effective_acceptance": sorted(effective_acceptance_owner),
        "reference_requirements": sorted(effective_requirements),
        "reference_acceptance": sorted(effective_acceptance_owner),
        "touched_requirements": sorted(set(touched_requirements)),
        "touched_acceptance": sorted(set(touched_acceptance)),
        "scenario_sources": scenario_sources,
    }


def plan_executables(plan: Mapping[str, Any] | None) -> list[Any]:
    steps = ruby_array(plan.get("steps") if plan else None)
    return steps + [
        descriptor
        for step in steps
        for descriptor in ruby_array(step.get("compensationDescriptors"))
    ]


def runtime_capability_for_step(record: Mapping[str, Any]) -> str | None:
    if record.get("disposition") != "executed":
        return None
    effect = record.get("effect")
    if effect == "readOnly":
        return (
            "realDeviceRead"
            if record.get("bindingRequirement") == "confirmedDevice"
            else None
        )
    if effect == "deviceMutation":
        return "realDeviceMutation"
    if effect == "destructive":
        return "destructiveDeviceMutation"
    return None


def _expand_braces(pattern: str) -> list[str]:
    """Expand Ruby FNM_EXTGLOB's ``{a,b}`` alternatives."""

    start = -1
    depth = 0
    for index, character in enumerate(pattern):
        if character == "{" and depth == 0:
            start = index
            depth = 1
            continue
        if start < 0:
            continue
        if character == "{":
            depth += 1
        elif character == "}":
            depth -= 1
            if depth == 0:
                inside = pattern[start + 1 : index]
                parts: list[str] = []
                current: list[str] = []
                nested = 0
                for item in inside:
                    if item == "{":
                        nested += 1
                    elif item == "}":
                        nested -= 1
                    if item == "," and nested == 0:
                        parts.append("".join(current))
                        current = []
                    else:
                        current.append(item)
                parts.append("".join(current))
                if len(parts) == 1:
                    return [pattern]
                suffix = pattern[index + 1 :]
                expanded: list[str] = []
                for part in parts:
                    expanded.extend(
                        _expand_braces(pattern[:start] + part + suffix)
                    )
                return expanded
    return [pattern]


def _segment_matches(pattern: str, segment: str) -> bool:
    if segment.startswith(".") and not pattern.startswith("."):
        return False
    return any(fnmatch.fnmatchcase(segment, item) for item in _expand_braces(pattern))


def ruby_path_fnmatch(pattern: str, path: str) -> bool:
    """Match Ruby ``File.fnmatch`` with FNM_PATHNAME | FNM_EXTGLOB.

    Ruby treats a non-terminal ``**`` path component as recursive, while a
    terminal ``**`` is the same one-component wildcard as ``*``.  Python's
    fnmatch and pathlib each differ from this behavior, so a small component
    matcher is used instead.
    """

    if "\\" in path:
        # Git/task paths are canonical POSIX paths even on Windows.
        return False
    pattern_parts = pattern.split("/")
    path_parts = path.split("/")
    memo: dict[tuple[int, int], bool] = {}

    def match(pattern_index: int, path_index: int) -> bool:
        key = pattern_index, path_index
        if key in memo:
            return memo[key]
        if pattern_index == len(pattern_parts):
            answer = path_index == len(path_parts)
        else:
            part = pattern_parts[pattern_index]
            recursive = part == "**" and pattern_index < len(pattern_parts) - 1
            if recursive:
                answer = match(pattern_index + 1, path_index)
                cursor = path_index
                while not answer and cursor < len(path_parts):
                    if path_parts[cursor].startswith("."):
                        break
                    cursor += 1
                    answer = match(pattern_index + 1, cursor)
            else:
                answer = path_index < len(path_parts) and _segment_matches(
                    part, path_parts[path_index]
                ) and match(pattern_index + 1, path_index + 1)
        memo[key] = answer
        return answer

    return match(0, 0)


def externally_verified(
    approval_path: str | os.PathLike[str] | None,
    subject: str | os.PathLike[str],
    approval: Mapping[str, Any] | None,
    verifiers: Sequence[Mapping[str, Any]],
    *,
    root: Path = ROOT,
) -> bool:
    if approval_path is None or approval is None:
        return False
    for entry in verifiers:
        if approval.get("mechanism") not in ruby_array(entry.get("mechanisms")):
            continue
        if approval.get("subjectType") not in ruby_array(entry.get("subject_types")):
            continue
        issuer = approval.get("issuer")
        if isinstance(issuer, Mapping) and issuer.get("id") != entry.get("id"):
            continue
        executable = Path(ruby_to_s(entry.get("executable_path")))
        if not executable.is_absolute() or not executable.is_file():
            continue
        try:
            mode = executable.stat().st_mode
        except OSError:
            continue
        if not mode & (stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH):
            continue
        if not relative(executable, root).startswith("../"):
            continue
        try:
            executable_hash = sha256_file(executable)
        except OSError:
            continue
        if executable_hash != entry.get("sha256"):
            continue
        result = _run(
            [
                executable,
                "verify",
                "--attestation",
                os.fspath(approval_path),
                "--subject",
                os.fspath(subject),
            ],
            timeout=15,
        )
        if result is not None and result.returncode == 0:
            return True
    return False


def externally_verified_content(
    approval_path: str | os.PathLike[str] | None,
    subject_content: str | bytes | None,
    subject_name: str,
    approval: Mapping[str, Any] | None,
    verifiers: Sequence[Mapping[str, Any]],
    *,
    root: Path = ROOT,
) -> bool:
    if approval_path is None or subject_content is None:
        return False
    suffix = Path(subject_name).suffix
    descriptor, temp_name = tempfile.mkstemp(
        prefix="arkdeck-historical-subject-", suffix=suffix
    )
    temp_path = Path(temp_name)
    try:
        content = (
            subject_content.encode("utf-8")
            if isinstance(subject_content, str)
            else subject_content
        )
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        temp_path.chmod(0o400)
        return externally_verified(
            approval_path, temp_path, approval, verifiers, root=root
        )
    except OSError:
        return False
    finally:
        try:
            temp_path.unlink()
        except OSError:
            pass


def valid_historical_approval(
    *,
    source: str | bytes | None,
    subject_name: str,
    document: Mapping[str, Any],
    approval: Mapping[str, Any] | None,
    approval_path: str | os.PathLike[str] | None,
    subject_type: str,
    subject_id: str,
    result_revision: Any,
    verifiers: Sequence[Mapping[str, Any]],
    exact_base: bool = False,
    root: Path = ROOT,
) -> bool:
    if source is None or approval is None or approval_path is None:
        return False
    source_bytes = source.encode("utf-8") if isinstance(source, str) else source
    base_valid = git_commit(approval.get("baseRevision"), root) and git_ancestor(
        approval.get("baseRevision"), result_revision, root
    )
    if exact_base:
        base_valid = base_valid and approval.get("baseRevision") == result_revision
    return bool(
        approval.get("subjectType") == subject_type
        and approval.get("subjectId") == subject_id
        and approval.get("subjectRevision") == document.get("revision")
        and approval.get("subjectSha256") == sha256_bytes(source_bytes)
        and approval.get("decision") == "approved"
        and base_valid
        and externally_verified_content(
            approval_path,
            source_bytes,
            subject_name,
            approval,
            verifiers,
            root=root,
        )
    )


def valid_task_supersession(
    *,
    run: Mapping[str, Any],
    run_path: Path,
    original: Mapping[str, Any] | None,
    replacement: Mapping[str, Any] | None,
    replacement_path: Path | None,
    approvals: Mapping[str, Mapping[str, Any]],
    approval_paths: Mapping[str, str | os.PathLike[str]],
    verifiers: Sequence[Mapping[str, Any]],
    root: Path = ROOT,
) -> bool:
    if (
        original is None
        or replacement is None
        or replacement_path is None
        or not replacement_path.is_file()
    ):
        return False
    if (
        run.get("supersededByTaskId") != replacement.get("taskId")
        or replacement.get("taskId") == original.get("taskId")
        or replacement.get("status") != "ready"
        or replacement.get("revision") != 1
    ):
        return False
    if not all(
        replacement.get(field) == original.get(field)
        for field in ("changeId", "changeRevision", "platform", "baseRevision")
    ):
        return False
    for field in (
        "requirementRefs",
        "acceptanceRefs",
        "allowedPaths",
        "forbiddenPaths",
        "deliverables",
    ):
        if ordered_difference(
            ruby_array(original.get(field)), ruby_array(replacement.get(field))
        ):
            return False
    replacement_approval = approvals.get(ruby_to_s(replacement.get("approvalId")))
    scope_approval = approvals.get(ruby_to_s(run.get("supersessionApprovalId")))
    if replacement_approval is None or scope_approval is None:
        return False
    try:
        ended_at = parse_iso8601(ruby_to_s(run["endedAt"]))
        replacement_approved_at = parse_iso8601(
            ruby_to_s(replacement_approval["approvedAt"])
        )
        scope_approved_at = parse_iso8601(ruby_to_s(scope_approval["approvedAt"]))
    except (KeyError, ValueError, TypeError):
        return False
    if not ended_at <= replacement_approved_at <= scope_approved_at:
        return False
    replacement_valid = (
        replacement_approval.get("subjectType") == "taskPacket"
        and replacement_approval.get("subjectId") == replacement.get("taskId")
        and replacement_approval.get("subjectRevision") == replacement.get("revision")
        and replacement_approval.get("subjectSha256")
        == sha256_file(replacement_path)
        and replacement_approval.get("baseRevision")
        == replacement.get("baseRevision")
        and replacement_approval.get("decision") == "approved"
        and externally_verified(
            approval_paths.get(ruby_to_s(replacement_approval.get("approvalId"))),
            replacement_path,
            replacement_approval,
            verifiers,
            root=root,
        )
    )
    scope_valid = (
        scope_approval.get("subjectType") == "taskSupersession"
        and scope_approval.get("subjectId") == run.get("runId")
        and scope_approval.get("subjectRevision") == run.get("attempt")
        and scope_approval.get("subjectSha256") == sha256_file(run_path)
        and scope_approval.get("baseRevision") == run.get("baseRevision")
        and scope_approval.get("decision") == "approved"
        and externally_verified(
            approval_paths.get(ruby_to_s(scope_approval.get("approvalId"))),
            run_path,
            scope_approval,
            verifiers,
            root=root,
        )
    )
    return bool(replacement_valid and scope_valid)


def load_json(path: str | os.PathLike[str]) -> Any:
    return json.loads(read_utf8(path))


def validate_change_supersession_barrier(
    *,
    errors: list[str],
    successor_id: str,
    successor_record: Mapping[str, Any],
    predecessor_id: str,
    predecessor_record: Mapping[str, Any],
    verifiers: Sequence[Mapping[str, Any]],
    root: Path = ROOT,
) -> dict[str, Any] | None:
    barrier_path = Path(successor_record["proposal_path"]).parent / (
        "supersession-barrier-attestation.json"
    )
    if not barrier_path.is_file():
        errors.append(
            f"approved successor Change {successor_id} lacks a protected "
            "supersession barrier attestation"
        )
        return None
    try:
        barrier = load_json(barrier_path)
        successor_lock_path = Path(successor_record["lock_path"])
        predecessor_lock_path = Path(predecessor_record["lock_path"])
        predecessor_root = Path(predecessor_record["proposal_path"]).parent.resolve()
        expected_claim_paths = sorted(
            relative(path, root)
            for path in predecessor_root.glob("evidence/runs/**/claim.json")
        )
        inventory = ruby_array(barrier.get("claims"))
        inventory_claim_paths = [entry.get("claimPath") for entry in inventory]
        try:
            closed_at = parse_iso8601(ruby_to_s(barrier["closedAt"]))
            successor_approved_at = Rfc3339Instant.coerce(
                successor_record["approved_at"]
            )
            predecessor_approved_at = Rfc3339Instant.coerce(
                predecessor_record["approved_at"]
            )
            chronology_valid = (
                predecessor_approved_at < closed_at < successor_approved_at
            )
        except (KeyError, ValueError, TypeError):
            closed_at = None
            chronology_valid = False

        lock_bindings_valid = (
            predecessor_lock_path.is_file()
            and successor_lock_path.is_file()
            and dig(barrier, "predecessor", "changeId") == predecessor_id
            and dig(barrier, "predecessor", "revision")
            == dig(predecessor_record, "proposal", "revision")
            and dig(barrier, "predecessor", "changeLockSha256")
            == sha256_file(predecessor_lock_path)
            and dig(barrier, "predecessor", "changeApprovalId")
            == dig(predecessor_record, "lock", "approval_id")
            and dig(barrier, "successor", "changeId") == successor_id
            and dig(barrier, "successor", "revision")
            == dig(successor_record, "proposal", "revision")
            and dig(barrier, "successor", "changeLockSha256")
            == sha256_file(successor_lock_path)
            and dig(barrier, "successor", "changeApprovalId")
            == dig(successor_record, "lock", "approval_id")
        )
        ledger_revision = dig(barrier, "ledger", "revision")
        lineage_sequence = dig(barrier, "ledger", "lineageSequence")
        inventory_shape_valid = (
            barrier.get("attestationId")
            == dig(successor_record, "proposal", "supersession_barrier_attestation_id")
            and barrier.get("subjectType") == "changeSupersessionBarrier"
            and barrier.get("mechanism") == "protectedClaimService"
            and isinstance(barrier.get("ledger"), Mapping)
            and ruby_to_s(dig(barrier, "ledger", "ledgerId")) != ""
            and isinstance(ledger_revision, int)
            and not isinstance(ledger_revision, bool)
            and ledger_revision > 0
            and isinstance(lineage_sequence, int)
            and not isinstance(lineage_sequence, bool)
            and lineage_sequence > 0
            and barrier.get("claimCount") == len(inventory)
            and inventory_claim_paths == sorted(inventory_claim_paths)
            and len(set(inventory_claim_paths)) == len(inventory_claim_paths)
            and inventory_claim_paths == expected_claim_paths
        )
        barrier_verified = externally_verified(
            barrier_path,
            successor_lock_path,
            barrier,
            verifiers,
            root=root,
        )
        inventory_valid = True
        for entry in inventory:
            artifact_paths = {
                field: root.joinpath(ruby_to_s(entry.get(field))).resolve()
                for field in (
                    "claimPath",
                    "claimOwnerAttestationPath",
                    "runPath",
                    "runOwnerAttestationPath",
                )
            }
            contained = all(
                path.is_file() and path.is_relative_to(predecessor_root)
                for path in artifact_paths.values()
            )
            if not contained:
                inventory_valid = False
                continue
            claim_path = artifact_paths["claimPath"]
            claim_owner_path = artifact_paths["claimOwnerAttestationPath"]
            run_path = artifact_paths["runPath"]
            run_owner_path = artifact_paths["runOwnerAttestationPath"]
            if not (
                claim_path.name == "claim.json"
                and claim_owner_path.name == "claim-owner-attestation.json"
                and run_path.name == "run.json"
                and run_owner_path.name == "run-owner-attestation.json"
                and len(
                    {
                        claim_path.parent,
                        claim_owner_path.parent,
                        run_path.parent,
                        run_owner_path.parent,
                    }
                )
                == 1
            ):
                inventory_valid = False
                continue
            claim = load_json(claim_path)
            claim_owner = load_json(claim_owner_path)
            run = load_json(run_path)
            run_owner = load_json(run_owner_path)
            try:
                claimed_at = parse_iso8601(ruby_to_s(claim["claimedAt"]))
                terminal_at = parse_iso8601(ruby_to_s(run["endedAt"]))
                temporal = bool(
                    closed_at
                    and claimed_at < terminal_at < closed_at
                    and entry.get("claimedAt") == claim.get("claimedAt")
                    and entry.get("terminalAt") == run.get("endedAt")
                )
            except (KeyError, ValueError, TypeError):
                temporal = False
            exact = (
                entry.get("claimId") == claim.get("claimId")
                and entry.get("taskId") == claim.get("taskId")
                and entry.get("attempt") == claim.get("attempt")
                and entry.get("claimSha256") == sha256_file(claim_path)
                and entry.get("claimOwnerAttestationId")
                == claim_owner.get("attestationId")
                and entry.get("claimOwnerAttestationSha256")
                == sha256_file(claim_owner_path)
                and claim_owner.get("subjectType") == "taskClaim"
                and claim_owner.get("claimId") == claim.get("claimId")
                and claim_owner.get("claimSha256") == entry.get("claimSha256")
                and claim_owner.get("taskId") == claim.get("taskId")
                and claim_owner.get("attempt") == claim.get("attempt")
                and entry.get("runId") == run.get("runId")
                and entry.get("terminalStatus") == run.get("status")
                and run.get("status") in ("done", "blocked", "interrupted", "superseded")
                and run.get("claimId") == claim.get("claimId")
                and run.get("taskId") == claim.get("taskId")
                and run.get("attempt") == claim.get("attempt")
                and entry.get("runSha256") == sha256_file(run_path)
                and entry.get("runOwnerAttestationId")
                == run_owner.get("attestationId")
                and entry.get("runOwnerAttestationSha256")
                == sha256_file(run_owner_path)
                and run_owner.get("subjectType") == "taskRunLease"
                and run_owner.get("claimAttestationId")
                == claim_owner.get("attestationId")
                and run_owner.get("claimId") == claim.get("claimId")
                and run_owner.get("runId") == run.get("runId")
                and run_owner.get("runSha256") == entry.get("runSha256")
                and run_owner.get("taskId") == run.get("taskId")
                and run_owner.get("attempt") == run.get("attempt")
                and run_owner.get("finalizedAt") == run.get("endedAt")
                and claim_owner.get("issuer") == barrier.get("issuer")
                and run_owner.get("issuer") == barrier.get("issuer")
            )
            owner_proofs = externally_verified(
                claim_owner_path,
                claim_path,
                claim_owner,
                verifiers,
                root=root,
            ) and externally_verified(
                run_owner_path,
                run_path,
                run_owner,
                verifiers,
                root=root,
            )
            inventory_valid = inventory_valid and temporal and exact and owner_proofs

        valid = (
            chronology_valid
            and lock_bindings_valid
            and inventory_shape_valid
            and inventory_valid
            and barrier_verified
        )
        if not valid:
            errors.append(
                f"approved successor Change {successor_id} has a stale, "
                "incomplete or unverified supersession barrier"
            )
        return (
            {"document": barrier, "path": barrier_path, "closed_at": closed_at}
            if valid
            else None
        )
    except (json.JSONDecodeError, UnicodeDecodeError):
        errors.append(
            f"approved successor Change {successor_id} has invalid supersession "
            "barrier JSON"
        )
        return None


def run_helper_self_tests(errors: list[str]) -> None:
    """Run the executable helper assertions inherited from the original guard."""

    case_hash_definition = {
        "test_id": "TEST-CASE-HASH",
        "method": "realHardwareMatrix",
        "minimum_evidence": "realHardware",
        "hardware_capability": "flash",
        "source_sha256": "a" * 64,
        "expected_result": None,
    }
    baseline_hash = acceptance_case_contract_sha256(
        "AC-CASE-HASH-001-01", case_hash_definition
    )
    if baseline_hash == acceptance_case_contract_sha256(
        "AC-CASE-HASH-001-01",
        case_hash_definition | {"source_sha256": "b" * 64},
    ):
        errors.append("acceptance case contract hash ignores canonical Scenario semantics")
    if baseline_hash == acceptance_case_contract_sha256(
        "AC-CASE-HASH-001-01",
        case_hash_definition | {"expected_result": "different result"},
    ):
        errors.append("acceptance case contract hash ignores platform expected result")

    shell_a = "# Capability\nPreamble\n\n### Requirement: REQ-X-001 One\nBody A\n#### Scenario: AC-X-001-01 One\n- THEN A\n"
    shell_b = "# Capability\nPreamble\n\n### Requirement: REQ-X-001 One\nBody B\n#### Scenario: AC-X-001-01 One\n- THEN B\n"
    shell_c = shell_b.replace("Preamble", "Changed preamble", 1)
    if canonical_non_requirement_content(shell_a) != canonical_non_requirement_content(
        shell_b
    ):
        errors.append(
            "spec non-Requirement shell guard self-test failed for a Requirement-only change"
        )
    if canonical_non_requirement_content(shell_a) == canonical_non_requirement_content(
        shell_c
    ):
        errors.append(
            "spec non-Requirement shell guard self-test failed for a preamble change"
        )

    if not yaml_ambiguities("outer:\n  key: one\n  key: two\n"):
        errors.append("YAML ambiguity guard self-test failed for a nested duplicate key")
    if not yaml_ambiguities("one: &value x\ntwo: *value\n"):
        errors.append("YAML ambiguity guard self-test failed for an alias")
    if not yaml_ambiguities("status: review\n---\nstatus: accepted\n"):
        errors.append("YAML ambiguity guard self-test failed for a multi-document stream")

    lineage_time = parse_iso8601("2026-01-01T00:00:01Z")
    if not change_supersession_cycles({"A": "B", "B": "A"}):
        errors.append("Change lineage cycle guard self-test failed")
    if change_supersession_cycles({"B": "A", "C": "B"}):
        errors.append("Change lineage acyclic guard self-test failed")
    if claim_precedes_successor(
        claimed_at=lineage_time, successor_approved_at=lineage_time
    ):
        errors.append("post-supersession claim guard self-test failed")
    if predecessor_claim_closed_before_successor(
        claimed_at=lineage_time - timedelta(seconds=2),
        terminal_at=None,
        successor_approved_at=lineage_time,
    ):
        errors.append("active predecessor claim guard self-test failed")
    if not predecessor_claim_closed_before_successor(
        claimed_at=lineage_time - timedelta(seconds=2),
        terminal_at=lineage_time - timedelta(seconds=1),
        successor_approved_at=lineage_time,
    ):
        errors.append("closed predecessor claim guard self-test failed")

    overlay_errors: list[str] = []
    overlay = build_behavior_overlay(
        delta_sources=[
            {
                "path": "openspec/changes/chg-self/specs/capability/spec.md",
                "text": (
                    "## ADDED Requirements\n"
                    "### Requirement: REQ-NEW-001 New\n"
                    "#### Scenario: AC-NEW-001-01 New\n"
                    "## MODIFIED Requirements\n"
                    "### Requirement: REQ-OLD-001 Updated\n"
                    "#### Scenario: AC-OLD-001-01 Kept\n"
                    "#### Scenario: AC-OLD-001-02 Kept too\n"
                    "#### Scenario: AC-OLD-001-03 Added\n"
                ),
            }
        ],
        baseline_requirement_acceptance={
            "REQ-OLD-001": ["AC-OLD-001-01", "AC-OLD-001-02"]
        },
        baseline_acceptance_owner={
            "AC-OLD-001-01": "REQ-OLD-001",
            "AC-OLD-001-02": "REQ-OLD-001",
        },
        baseline_requirement_paths={
            "REQ-OLD-001": "openspec/specs/capability/spec.md"
        },
        errors=overlay_errors,
        subject="behavior overlay self-test",
    )
    overlay_valid = (
        not overlay_errors
        and overlay["effective_requirements"] == ["REQ-NEW-001", "REQ-OLD-001"]
        and overlay["effective_acceptance"]
        == [
            "AC-NEW-001-01",
            "AC-OLD-001-01",
            "AC-OLD-001-02",
            "AC-OLD-001-03",
        ]
    )
    if not overlay_valid:
        errors.append(
            "behavior baseline+delta overlay guard self-test failed: "
            + "; ".join(overlay_errors)
        )

    fail_closed_errors: list[str] = []
    build_behavior_overlay(
        delta_sources=[
            {
                "path": "openspec/changes/chg-self/specs/capability/spec.md",
                "text": (
                    "## MODIFIED Requirements\n"
                    "### Requirement: REQ-OLD-001 Incomplete\n"
                    "#### Scenario: AC-OLD-001-01 Only one old AC\n"
                    "## REMOVED Requirements\n"
                    "### Requirement: REQ-GONE-001 Unsupported\n"
                    "## CHANGED Requirements\n"
                    "### Requirement: REQ-UNKNOWN-001 Ambiguous\n"
                    "## RENAMED Requirements\n"
                    "- FROM: Old title\n"
                    "- TO: New title\n"
                ),
            }
        ],
        baseline_requirement_acceptance={
            "REQ-OLD-001": ["AC-OLD-001-01", "AC-OLD-001-02"],
            "REQ-GONE-001": ["AC-GONE-001-01"],
        },
        baseline_acceptance_owner={
            "AC-OLD-001-01": "REQ-OLD-001",
            "AC-OLD-001-02": "REQ-OLD-001",
            "AC-GONE-001-01": "REQ-GONE-001",
        },
        baseline_requirement_paths={
            "REQ-OLD-001": "openspec/specs/capability/spec.md",
            "REQ-GONE-001": "openspec/specs/capability/spec.md",
        },
        errors=fail_closed_errors,
        subject="behavior fail-closed self-test",
    )
    required_fragments = (
        "unsupported V1 REMOVED",
        "requires preserving all old AC IDs",
        "outside an ADDED/MODIFIED section",
        "unsupported V1 RENAMED content",
    )
    if not all(
        any(fragment in item for item in fail_closed_errors)
        for fragment in required_fragments
    ):
        errors.append("behavior unsupported/removal/ambiguous-section guard self-test failed")

    if runtime_capability_for_step(
        {
            "disposition": "executed",
            "effect": "destructive",
            "bindingRequirement": "confirmedDevice",
        }
    ) != "destructiveDeviceMutation":
        errors.append("runtime-capability guard self-test failed for destructive execution")
    if runtime_capability_for_step(
        {
            "disposition": "skipped",
            "effect": "destructive",
            "bindingRequirement": "confirmedDevice",
        }
    ) is not None:
        errors.append("runtime-capability guard self-test failed for skipped destructive plan")

    glob_cases = (
        ("foo/**", "foo/a", True),
        ("foo/**", "foo/a/b", False),
        ("foo/**/*.md", "foo/a.md", True),
        ("foo/**/*.md", "foo/x/a.md", True),
        ("{foo,bar}/**", "bar/a", True),
        ("foo/*", "foo/.hidden", False),
    )
    if any(ruby_path_fnmatch(pattern, path) != expected for pattern, path, expected in glob_cases):
        errors.append("Ruby FNM_PATHNAME/FNM_EXTGLOB compatibility self-test failed")


__all__ = [
    "ACCEPTANCE_EVIDENCE_CLASSES",
    "CANONICAL_GIT_OID",
    "CORE_ACCEPTANCE_ID",
    "INVALID_TREE_ENTRY",
    "PLATFORM_ACCEPTANCE_ID",
    "PLATFORM_REVALIDATION_TRIGGERS",
    "PRE_ARCHIVE_INVARIANTS",
    "RFC3339_DATE_TIME",
    "ROOT",
    "Rfc3339Instant",
    "SUPPORTED_PYYAML",
    "SUPPORTED_PYTHON",
    "acceptance_case_contract_sha256",
    "apply_behavior_overlay_to_snapshot",
    "archived_change_path",
    "behavior_target_spec_path",
    "build_behavior_overlay",
    "canonical_markdown_block",
    "canonical_non_requirement_content",
    "change_supersession_cycles",
    "claim_precedes_successor",
    "compact_json_bytes",
    "dig",
    "expected_change_input_paths",
    "externally_verified",
    "externally_verified_content",
    "git_ancestor",
    "git_commit",
    "git_diff_entries",
    "git_diff_paths",
    "git_file_bytes",
    "git_file_content",
    "git_file_sha256",
    "git_head_revision",
    "git_normative_spec_snapshot",
    "git_path_add_commits",
    "git_tree_entry_identity",
    "git_tree_paths",
    "iter_hash_entries",
    "load_json",
    "markdown_frontmatter",
    "normative_spec_snapshot",
    "ordered_difference",
    "ordered_intersection",
    "ordered_union",
    "parse_iso8601",
    "plan_executables",
    "platform_context_for_task",
    "port_contract_sha256",
    "predecessor_claim_closed_before_successor",
    "read_utf8",
    "relative",
    "require_runtime",
    "required_change_artifact_paths",
    "ruby_array",
    "ruby_path_fnmatch",
    "ruby_to_s",
    "ruby_truthy",
    "run_helper_self_tests",
    "runtime_capability_for_step",
    "sha256_bytes",
    "sha256_file",
    "sha256_text",
    "support_cell_contract_sha256",
    "valid_historical_approval",
    "valid_task_supersession",
    "validate_change_supersession_barrier",
    "validate_platform_lifecycle",
    "validate_platform_revalidation",
    "validate_platform_transition",
    "validate_task_result_aggregate",
    "walk_hash_entries",
    "write_utf8",
    "yaml_ambiguities",
    "yaml_safe_load",
]
