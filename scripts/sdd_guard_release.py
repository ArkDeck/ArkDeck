#!/usr/bin/env python3.14
"""Immutable-identity, release-subject, and platform-evidence SDD checks."""

from __future__ import annotations

import json
import os
import re
from collections.abc import Mapping, Sequence
from pathlib import Path
from typing import Any, Final

import sdd_guard_support as support


REQUIRED_CONTEXT_KEYS: Final[frozenset[str]] = frozenset(
    {
        "acceptance",
        "approval_paths",
        "approvals",
        "baseline",
        "conformance",
        "conformance_fixture_ids",
        "core_case_definitions",
        "external_trust_root",
        "external_trust_root_valid",
        "hardware_evaluation_time",
        "integration_lock",
        "platform_case_definitions",
        "platform_lock",
        "platform_lock_chain",
        "platform_support_definitions",
        "port_definitions",
        "ports",
        "trust_policy",
        "trusted_verifiers",
        "verified_hardware",
        "versioned_schemas",
    }
)

_SHA256 = re.compile(r"[a-f0-9]{64}")
_PCE_PATH = re.compile(
    r"openspec/platforms/conformance-evidence/PCE-[A-Z0-9._-]+\.json"
)
_PCE_BINDING_PATH = re.compile(
    r"openspec/platforms/conformance-evidence/bindings/PCEV-[A-Z0-9._-]+\.json"
)
_RELEASE_SUBJECT_PATH = re.compile(
    r"openspec/platforms/release-subjects/PRS-[A-Z0-9._-]+\.json"
)


def _glob_files(root: Path, pattern: str) -> list[Path]:
    return sorted(path for path in root.glob(pattern) if path.is_file())


def _json(path: Path) -> dict[str, Any]:
    document = support.load_json(path)
    return document if isinstance(document, dict) else {}


def _yaml(path: Path) -> dict[str, Any]:
    document = support.yaml_safe_load(support.read_utf8(path))
    return document if isinstance(document, dict) else {}


def _repo_path(
    root: Path, relative_path: str, expected_pattern: re.Pattern[str]
) -> tuple[Path, bool]:
    candidate = Path(os.path.abspath(root / relative_path))
    contained = (
        expected_pattern.fullmatch(relative_path) is not None
        and candidate != root
        and candidate.is_relative_to(root)
    )
    return candidate, contained


def _normalize_bindings(bindings: Any) -> list[dict[str, Any]]:
    unique: list[dict[str, Any]] = []
    for binding in support.ruby_array(bindings):
        if binding not in unique:
            unique.append(binding)
    return sorted(
        unique,
        key=lambda binding: (
            support.ruby_to_s(binding.get("subjectType")),
            support.ruby_to_s(binding.get("subjectId")),
            support.ruby_to_s(binding.get("definitionSha256")),
        ),
    )


def _add_identity(
    inventory: dict[tuple[str, str, str], str],
    errors: list[str],
    kind: Any,
    identity: Any,
    revision: Any,
    sha256: Any,
) -> None:
    key = (
        support.ruby_to_s(kind),
        support.ruby_to_s(identity),
        support.ruby_to_s(revision),
    )
    sha256_text = support.ruby_to_s(sha256)
    if any(not item for item in key) or _SHA256.fullmatch(sha256_text) is None:
        errors.append(
            f"immutable identity inventory contains an invalid {'/'.join(key)} binding"
        )
        return
    if key in inventory and inventory[key] != sha256_text:
        errors.append(
            f"immutable identity {'/'.join(key)} maps to multiple hashes in the current tree"
        )
    else:
        inventory[key] = sha256_text


def _identity_and_ledger_guard(
    root: Path, errors: list[str], context: Mapping[str, Any]
) -> None:
    approvals: Mapping[str, Mapping[str, Any]] = context["approvals"]
    approval_paths: Mapping[str, Path] = context["approval_paths"]
    versioned_schemas: Mapping[str, Mapping[str, Any]] = context["versioned_schemas"]
    trust_policy: Mapping[str, Any] = context["trust_policy"]
    external_trust_root = context["external_trust_root"]
    trusted_verifiers = context["trusted_verifiers"]

    all_task_packet_paths = _glob_files(
        root, "openspec/changes/**/task-packets/*.json"
    )
    global_task_identities: dict[Any, list[dict[str, Any]]] = {}
    for packet_path in all_task_packet_paths:
        packet = _json(packet_path)
        global_task_identities.setdefault(packet.get("taskId"), []).append(
            {
                "revision": packet.get("revision"),
                "path": support.relative(packet_path, root),
            }
        )
    for task_id, entries in global_task_identities.items():
        if len(entries) > 1:
            paths = sorted(entry["path"] for entry in entries)
            errors.append(
                f"Task identity {task_id} is reused across live/archive packets: "
                f"{', '.join(paths)}"
            )

    all_claim_paths = _glob_files(
        root, "openspec/changes/**/evidence/runs/**/claim.json"
    )
    global_claim_ids: dict[Any, list[str]] = {}
    global_task_attempts: dict[tuple[Any, Any], list[str]] = {}
    for claim_path in all_claim_paths:
        claim = _json(claim_path)
        relative_path = support.relative(claim_path, root)
        global_claim_ids.setdefault(claim.get("claimId"), []).append(relative_path)
        global_task_attempts.setdefault(
            (claim.get("taskId"), claim.get("attempt")), []
        ).append(relative_path)
    for claim_id, paths in global_claim_ids.items():
        if len(paths) > 1:
            errors.append(
                f"claim identity {claim_id} is reused across live/archive history"
            )
    for (task_id, attempt), paths in global_task_attempts.items():
        if len(paths) > 1:
            errors.append(
                f"Task attempt {task_id}/{attempt} is reused across live/archive history"
            )

    all_run_paths = _glob_files(root, "openspec/changes/**/evidence/runs/**/run.json")
    global_run_ids: dict[Any, list[str]] = {}
    global_runs_by_claim: dict[Any, list[str]] = {}
    for run_path in all_run_paths:
        run = _json(run_path)
        relative_path = support.relative(run_path, root)
        global_run_ids.setdefault(run.get("runId"), []).append(relative_path)
        global_runs_by_claim.setdefault(run.get("claimId"), []).append(relative_path)
    for run_id, paths in global_run_ids.items():
        if len(paths) > 1:
            errors.append(f"run identity {run_id} is reused across live/archive history")
    for claim_id, paths in global_runs_by_claim.items():
        if len(paths) > 1:
            errors.append(
                f"claim {claim_id} has multiple terminal runs across live/archive history"
            )

    global_attestation_ids: dict[Any, list[str]] = {}
    all_change_json = _glob_files(root, "openspec/changes/**/*.json")
    for path in all_change_json:
        document = _json(path)
        attestation_id = support.ruby_to_s(document.get("attestationId"))
        if attestation_id:
            global_attestation_ids.setdefault(attestation_id, []).append(
                support.relative(path, root)
            )
    for attestation_id, paths in global_attestation_ids.items():
        if len(paths) > 1:
            errors.append(
                f"attestation identity {attestation_id} is reused across live/archive history"
            )

    approved_by_identity: dict[tuple[Any, Any, Any], list[Mapping[str, Any]]] = {}
    for approval in approvals.values():
        if approval.get("decision") == "approved":
            identity = (
                approval.get("subjectType"),
                approval.get("subjectId"),
                approval.get("subjectRevision"),
            )
            approved_by_identity.setdefault(identity, []).append(approval)
    for identity, subject_approvals in approved_by_identity.items():
        hashes: list[Any] = []
        for approval in subject_approvals:
            value = approval.get("subjectSha256")
            if value not in hashes:
                hashes.append(value)
        if len(hashes) != 1:
            errors.append(
                "approved subject identity "
                + "/".join(support.ruby_to_s(item) for item in identity)
                + " maps to multiple immutable hashes"
            )

    for approval in approvals.values():
        if not (
            approval.get("subjectType") == "taskPacket"
            and approval.get("decision") == "approved"
        ):
            continue
        matches = []
        for packet_path in all_task_packet_paths:
            packet = _json(packet_path)
            if (
                packet.get("taskId") == approval.get("subjectId")
                and packet.get("revision") == approval.get("subjectRevision")
                and support.sha256_file(packet_path) == approval.get("subjectSha256")
                and packet.get("baseRevision") == approval.get("baseRevision")
            ):
                matches.append(packet_path)
        if len(matches) != 1:
            errors.append(
                f"approved Task packet {approval.get('subjectId')} was removed or rewritten"
            )

    all_change_lock_paths = _glob_files(root, "openspec/changes/**/change-lock.yaml")
    for approval in approvals.values():
        if not (
            approval.get("subjectType") == "change"
            and approval.get("decision") == "approved"
        ):
            continue
        matches = []
        for lock_path in all_change_lock_paths:
            lock = _yaml(lock_path)
            if (
                lock.get("change_id") == approval.get("subjectId")
                and lock.get("revision") == approval.get("subjectRevision")
                and support.sha256_file(lock_path) == approval.get("subjectSha256")
                and approval.get("subjectRevision") == 1
            ):
                matches.append(lock_path)
        if len(matches) != 1:
            errors.append(
                f"approved Change {approval.get('subjectId')} was removed, rewritten or illegally revisioned"
            )

    inventory: dict[tuple[str, str, str], str] = {}
    for path in all_task_packet_paths:
        packet = _json(path)
        if packet.get("status") == "ready":
            _add_identity(
                inventory,
                errors,
                "taskPacket",
                packet.get("taskId"),
                packet.get("revision"),
                support.sha256_file(path),
            )
    for path in all_claim_paths:
        claim = _json(path)
        _add_identity(
            inventory,
            errors,
            "claim",
            claim.get("claimId"),
            claim.get("attempt"),
            support.sha256_file(path),
        )
    for path in all_run_paths:
        run = _json(path)
        _add_identity(
            inventory,
            errors,
            "run",
            run.get("runId"),
            run.get("attempt"),
            support.sha256_file(path),
        )
    for path in all_change_json:
        document = _json(path)
        if support.ruby_to_s(document.get("attestationId")):
            _add_identity(
                inventory,
                errors,
                "attestation",
                document.get("attestationId"),
                document.get("schemaVersion") or "1",
                support.sha256_file(path),
            )
    for approval_id, path in approval_paths.items():
        approval = approvals.get(approval_id, {})
        _add_identity(
            inventory,
            errors,
            "approval",
            approval_id,
            approval.get("subjectRevision"),
            support.sha256_file(path),
        )
        if approval.get("decision") == "approved":
            _add_identity(
                inventory,
                errors,
                "approvedSubject",
                f"{approval.get('subjectType')}:{approval.get('subjectId')}",
                approval.get("subjectRevision"),
                approval.get("subjectSha256"),
            )
    for path in all_change_lock_paths:
        lock = _yaml(path)
        if lock.get("status") == "approved":
            _add_identity(
                inventory,
                errors,
                "changeLock",
                lock.get("change_id"),
                lock.get("revision"),
                support.sha256_file(path),
            )
    for path in _glob_files(root, "openspec/changes/archive/*/archive-lock.yaml"):
        lock = _yaml(path)
        if lock.get("status") == "archived":
            _add_identity(
                inventory,
                errors,
                "archiveLock",
                lock.get("change_id"),
                lock.get("revision"),
                support.sha256_file(path),
            )
    evidence_paths = _glob_files(
        root, "openspec/verification/hardware-evidence/*.json"
    ) + _glob_files(root, "openspec/platforms/conformance-evidence/*.json")
    for path in sorted(evidence_paths):
        record = _json(path)
        if support.ruby_to_s(record.get("evidenceId")) and support.ruby_to_s(
            record.get("approvalId")
        ):
            _add_identity(
                inventory,
                errors,
                "evidenceRecord",
                record.get("evidenceId"),
                record.get("schemaVersion") or "1",
                support.sha256_file(path),
            )
    for path in _glob_files(
        root, "openspec/platforms/conformance-evidence/bindings/*.json"
    ):
        record = _json(path)
        if support.ruby_to_s(record.get("bindingId")) and support.ruby_to_s(
            record.get("approvalId")
        ):
            _add_identity(
                inventory,
                errors,
                "evidenceRecord",
                record.get("bindingId"),
                record.get("schemaVersion") or "1",
                support.sha256_file(path),
            )
    for path in _glob_files(root, "openspec/platforms/release-subjects/*.json"):
        record = _json(path)
        if support.ruby_to_s(record.get("releaseId")) and support.ruby_to_s(
            record.get("approvalId")
        ):
            _add_identity(
                inventory,
                errors,
                "releaseSubject",
                record.get("releaseId"),
                record.get("schemaVersion") or "1",
                support.sha256_file(path),
            )
    for path in _glob_files(root, "openspec/baselines/CORE-*.lock.yaml"):
        lock = _yaml(path)
        if lock.get("status") == "accepted":
            _add_identity(
                inventory,
                errors,
                "acceptedBaseline",
                lock.get("baseline"),
                lock.get("revision"),
                support.sha256_file(path),
            )

    context_sink = context.get("_identity_inventory_sink")
    if isinstance(context_sink, dict):
        # Shared with tooling (scripts/ledger_snapshot.py) so the external
        # ledger snapshot is produced by exactly the guard's inventory logic.
        context_sink.clear()
        context_sink.update(inventory)

    if trust_policy.get("status") != "accepted" or trust_policy.get(
        "execution_gate"
    ) != "open":
        return
    ledger_location = os.environ.get("ARKDECK_IDENTITY_LEDGER_SNAPSHOT", "")
    ledger_path = Path(ledger_location)
    ledger_outside = bool(
        ledger_location
        and ledger_path.is_absolute()
        and support.relative(ledger_path, root).startswith("../")
    )
    if not ledger_outside or not ledger_path.is_file():
        errors.append(
            "open execution gate requires an external protected identity ledger snapshot"
        )
        return
    try:
        ledger = _json(ledger_path)
        schema = versioned_schemas.get(
            "https://arkdeck.dev/schemas/identity-ledger-snapshot-"
            f"{ledger.get('schemaVersion')}.json"
        )
        ledger_missing = (
            support.ordered_difference(schema.get("required", []), ledger.keys())
            if schema
            else ["versioned schema"]
        )
        ledger_extra = (
            support.ordered_difference(ledger.keys(), schema.get("properties", {}).keys())
            if schema
            else list(ledger.keys())
        )
        entries = support.ruby_array(ledger.get("entries"))
        entry_keys = [
            (
                support.ruby_to_s(entry.get("kind")),
                support.ruby_to_s(entry.get("id")),
                support.ruby_to_s(entry.get("revision")),
            )
            for entry in entries
        ]
        entries_sorted = sorted(
            entries,
            key=lambda entry: (
                support.ruby_to_s(entry.get("kind")),
                support.ruby_to_s(entry.get("id")),
                support.ruby_to_s(entry.get("revision")),
            ),
        )
        current_entries = sorted(
            (
                {"kind": kind, "id": identity, "revision": revision, "sha256": sha}
                for (kind, identity, revision), sha in inventory.items()
            ),
            key=lambda entry: (entry["kind"], entry["id"], entry["revision"]),
        )
        revision = ledger.get("revision")
        chain_shape_valid = (
            isinstance(revision, int)
            and not isinstance(revision, bool)
            and revision > 0
            and (
                ledger.get("previousSnapshotSha256") is None
                if revision == 1
                else _SHA256.fullmatch(
                    support.ruby_to_s(ledger.get("previousSnapshotSha256"))
                )
                is not None
            )
        )
        generated_at_valid = (
            support.RFC3339_DATE_TIME.fullmatch(
                support.ruby_to_s(ledger.get("generatedAt"))
            )
            is not None
        )
        exact_inventory = (
            entries == entries_sorted
            and len(set(entry_keys)) == len(entry_keys)
            and entries == current_entries
        )
        valid_ledger = bool(
            not ledger_missing
            and not ledger_extra
            and chain_shape_valid
            and generated_at_valid
            and exact_inventory
            and ledger.get("subjectType") == "identityLedger"
            and ledger.get("decision") == "approved"
            and external_trust_root
            and ledger.get("repositoryId")
            == external_trust_root.get("repository_id")
            and ledger.get("repositoryRevision") == support.git_head_revision(root)
            and support.externally_verified(
                ledger_path,
                ledger_path,
                ledger,
                trusted_verifiers,
                root=root,
            )
        )
        if not valid_ledger:
            errors.append(
                "protected identity ledger is stale, incomplete, ambiguous or externally unverified"
            )
    except (json.JSONDecodeError, UnicodeDecodeError):
        errors.append("external protected identity ledger snapshot is invalid JSON")


def _accepted_axis_approvals(
    root: Path, errors: list[str], context: Mapping[str, Any]
) -> None:
    approvals = context["approvals"]
    approval_paths = context["approval_paths"]
    trusted_verifiers = context["trusted_verifiers"]
    trust_policy = context["trust_policy"]
    trust_policy_path = root / "openspec/governance/trust-policy.yaml"
    if trust_policy.get("status") == "accepted":
        approval = approvals.get(support.dig(trust_policy, "ratification", "approval_ref"))
        valid = bool(
            context["external_trust_root_valid"]
            and approval
            and approval.get("subjectType") == "trustPolicy"
            and approval.get("subjectId") == trust_policy.get("policy")
            and approval.get("subjectRevision") == trust_policy.get("revision")
            and approval.get("subjectSha256") == support.sha256_file(trust_policy_path)
            and approval.get("decision") == "approved"
            and support.git_commit(approval.get("baseRevision"), root)
            and support.externally_verified(
                approval_paths.get(approval.get("approvalId")),
                trust_policy_path,
                approval,
                trusted_verifiers,
                root=root,
            )
        )
        if not valid:
            errors.append("accepted trust policy lacks externally verified approval")

    baseline = context["baseline"]
    baseline_path = (
        root / "openspec/baselines" / f"{baseline.get('baseline')}.lock.yaml"
        if baseline
        else root / "openspec/baselines/missing.lock.yaml"
    )
    if baseline and baseline.get("status") == "accepted":
        approval = approvals.get(support.dig(baseline, "ratification", "approval_ref"))
        valid = bool(
            approval
            and approval.get("subjectType") == "baseline"
            and approval.get("subjectId") == baseline.get("baseline")
            and approval.get("subjectRevision") == baseline.get("revision")
            and approval.get("subjectSha256") == support.sha256_file(baseline_path)
            and approval.get("decision") == "approved"
            and support.git_commit(approval.get("baseRevision"), root)
            and support.externally_verified(
                approval_paths.get(approval.get("approvalId")),
                baseline_path,
                approval,
                trusted_verifiers,
                root=root,
            )
        )
        if not valid:
            errors.append("accepted Core baseline lacks externally verified approval")

    integration_lock = context["integration_lock"]
    integration_lock_path = root / "openspec/integrations/INTEGRATION-PROFILES.lock.yaml"
    if integration_lock and integration_lock.get("status") == "accepted":
        approval = approvals.get(
            support.dig(integration_lock, "ratification", "approval_ref")
        )
        valid = bool(
            approval
            and approval.get("subjectType") == "integrationLock"
            and approval.get("subjectId") == integration_lock.get("lock")
            and approval.get("subjectRevision") == integration_lock.get("revision")
            and approval.get("subjectSha256")
            == support.sha256_file(integration_lock_path)
            and approval.get("decision") == "approved"
            and support.git_commit(approval.get("baseRevision"), root)
            and support.externally_verified(
                approval_paths.get(approval.get("approvalId")),
                integration_lock_path,
                approval,
                trusted_verifiers,
                root=root,
            )
        )
        if not valid:
            errors.append("accepted Integration lock lacks externally verified approval")


def _binding_is_valid(
    *,
    root: Path,
    item: Mapping[str, Any],
    record: Mapping[str, Any],
    support_revisions: Sequence[Any],
    expected_bindings: Sequence[Mapping[str, Any]],
    approvals: Mapping[str, Mapping[str, Any]],
    approval_paths: Mapping[str, Path],
    trusted_verifiers: Sequence[Mapping[str, Any]],
) -> bool:
    evidence_approval = approvals.get(item.get("approvalId"))
    binding_relative = support.ruby_to_s(item.get("bindingPath"))
    binding_path, binding_contained = _repo_path(
        root, binding_relative, _PCE_BINDING_PATH
    )
    binding_record = _json(binding_path) if binding_contained and binding_path.is_file() else {}
    try:
        approval_precedes_observation = bool(
            evidence_approval
            and support.parse_iso8601(evidence_approval["approvedAt"])
            <= support.parse_iso8601(record["observedAt"])
        )
    except (KeyError, TypeError, ValueError):
        approval_precedes_observation = False
    exact_bindings = _normalize_bindings(item.get("caseBindings")) == _normalize_bindings(
        expected_bindings
    )
    binding_exact = bool(
        binding_contained
        and binding_path.is_file()
        and binding_path.stem == item.get("evidenceId")
        and item.get("bindingSha256") == support.sha256_file(binding_path)
        and binding_record.get("bindingId") == item.get("evidenceId")
        and binding_record.get("artifactSha256") == item.get("sha256")
        and binding_record.get("classification") == item.get("classification")
        and binding_record.get("location") == item.get("location")
        and binding_record.get("coreBaselineSha256")
        == item.get("coreBaselineSha256")
        and binding_record.get("conformanceSuiteSha256")
        == item.get("conformanceSuiteSha256")
        and binding_record.get("integrationLockSha256")
        == item.get("integrationLockSha256")
        and binding_record.get("platformProfileSha256")
        == item.get("platformProfileSha256")
        and binding_record.get("platformVerificationSha256")
        == item.get("platformVerificationSha256")
        and binding_record.get("platformCaseManifestSha256")
        == item.get("platformCaseManifestSha256")
        and sorted(support.ruby_array(binding_record.get("implementationRevisions")))
        == sorted(support.ruby_array(item.get("implementationRevisions")))
        and _normalize_bindings(binding_record.get("caseBindings"))
        == _normalize_bindings(item.get("caseBindings"))
        and binding_record.get("approvalId") == item.get("approvalId")
    )
    return bool(
        item.get("coreBaselineSha256") == support.dig(record, "coreBaseline", "sha256")
        and item.get("conformanceSuiteSha256")
        == support.dig(record, "conformanceSuite", "sha256")
        and item.get("integrationLockSha256")
        == support.dig(record, "integrationLock", "sha256")
        and item.get("platformProfileSha256")
        == support.dig(record, "platformProfile", "profileSha256")
        and item.get("platformVerificationSha256")
        == support.dig(record, "platformProfile", "verificationSha256")
        and item.get("platformCaseManifestSha256")
        == support.dig(record, "platformProfile", "caseManifestSha256")
        and sorted(support.ruby_array(item.get("implementationRevisions")))
        == sorted(support_revisions)
        and exact_bindings
        and binding_exact
        and evidence_approval
        and evidence_approval.get("subjectType") == "evidence"
        and evidence_approval.get("subjectId") == item.get("evidenceId")
        and evidence_approval.get("subjectRevision") == 1
        and evidence_approval.get("subjectSha256") == item.get("bindingSha256")
        and len(support_revisions) == 1
        and evidence_approval.get("baseRevision") == support_revisions[0]
        and evidence_approval.get("decision") == "approved"
        and approval_precedes_observation
        and support.externally_verified(
            approval_paths.get(evidence_approval.get("approvalId")),
            binding_path,
            evidence_approval,
            trusted_verifiers,
            root=root,
        )
    )


def _capability_scope_guard(
    root: Path, errors: list[str], context: Mapping[str, Any]
) -> dict[str, Any]:
    """Validate the capability registry and every release subject's scope.

    Staged/iterative releases declare their exact capability scope in the
    release subject's ``includedCapabilities``. This guard proves:

    1. the registry covers exactly the ``openspec/specs/<capability>``
       directories (no phantom or missing capabilities);
    2. every registry entry has a valid release class and known, acyclic
       ``requires`` dependencies;
    3. every release subject includes all ``release: required`` capabilities
       and is dependency-closed.

    Returns the acceptance-scoping context used by :func:`_pce_guard`. On any
    registry defect the returned ``registry_ok`` is False so verified release
    claims fail closed instead of falling back to guessed applicability.
    """

    acceptance = context["acceptance"]
    specs_root = root / "openspec/specs"
    spec_capabilities = sorted(
        entry.name
        for entry in specs_root.iterdir()
        if entry.is_dir() and (entry / "spec.md").is_file()
    ) if specs_root.is_dir() else []

    capability_of_acceptance: dict[str, str] = {}
    for acceptance_id, paths in acceptance.items():
        parts = support.ruby_array(paths)
        if parts:
            segments = str(parts[0]).split("/")
            if len(segments) >= 3 and segments[0] == "openspec" and segments[1] == "specs":
                capability_of_acceptance[acceptance_id] = segments[2]

    registry_ok = True
    required: set[str] = set()
    requires: dict[str, set[str]] = {}
    registry_path = root / "openspec/contracts/capability-registry.yaml"
    if not registry_path.is_file():
        errors.append("capability registry is missing: openspec/contracts/capability-registry.yaml")
        registry_ok = False
    else:
        registry = _yaml(registry_path)
        entries = support.ruby_array(registry.get("capabilities"))
        registry_ids = [support.ruby_to_s(entry.get("id")) for entry in entries]
        if sorted(registry_ids) != spec_capabilities or len(set(registry_ids)) != len(registry_ids):
            errors.append(
                "capability registry does not exactly cover openspec/specs capabilities"
            )
            registry_ok = False
        for entry in entries:
            entry_id = support.ruby_to_s(entry.get("id"))
            release_class = support.ruby_to_s(entry.get("release"))
            if release_class not in ("required", "optional"):
                errors.append(
                    f"capability registry entry {entry_id} has invalid release class: "
                    f"{release_class or '(missing)'}"
                )
                registry_ok = False
            if release_class == "required":
                required.add(entry_id)
            entry_requires = {
                support.ruby_to_s(item) for item in support.ruby_array(entry.get("requires"))
            }
            unknown_requires = sorted(entry_requires.difference(registry_ids))
            if unknown_requires:
                errors.append(
                    f"capability registry entry {entry_id} requires unknown capabilities: "
                    + ", ".join(unknown_requires)
                )
                registry_ok = False
            if entry_id in entry_requires:
                errors.append(f"capability registry entry {entry_id} requires itself")
                registry_ok = False
            requires[entry_id] = entry_requires
        # Reject dependency cycles: repeatedly peel entries whose requirements
        # are all already peeled; anything left participates in a cycle.
        remaining = dict(requires)
        peeled: set[str] = set()
        while True:
            leaves = [name for name, deps in remaining.items() if deps <= peeled]
            if not leaves:
                break
            for name in leaves:
                peeled.add(name)
                del remaining[name]
        if remaining:
            errors.append(
                "capability registry has a dependency cycle involving: "
                + ", ".join(sorted(remaining))
            )
            registry_ok = False

    for path in _glob_files(root, "openspec/platforms/release-subjects/*.json"):
        record = _json(path)
        rel = support.relative(path, root)
        included_raw = support.ruby_array(record.get("includedCapabilities"))
        included = [support.ruby_to_s(item) for item in included_raw]
        if not included:
            errors.append(f"release subject {rel} declares no includedCapabilities")
            continue
        if len(set(included)) != len(included):
            errors.append(f"release subject {rel} has duplicate includedCapabilities")
        unknown = sorted(set(included).difference(spec_capabilities))
        if unknown:
            errors.append(
                f"release subject {rel} includes unknown capabilities: " + ", ".join(unknown)
            )
        if registry_ok:
            missing_required = sorted(required.difference(included))
            if missing_required:
                errors.append(
                    f"release subject {rel} omits required capabilities: "
                    + ", ".join(missing_required)
                )
            for capability in included:
                missing_deps = sorted(
                    requires.get(capability, set()).difference(included)
                )
                if missing_deps:
                    errors.append(
                        f"release subject {rel} violates capability dependency closure: "
                        f"{capability} requires " + ", ".join(missing_deps)
                    )

    return {
        "registry_ok": registry_ok,
        "spec_capabilities": spec_capabilities,
        "required": required,
        "requires": requires,
        "capability_of_acceptance": capability_of_acceptance,
    }


def _pce_guard(
    root: Path,
    errors: list[str],
    context: Mapping[str, Any],
    capability_scope: Mapping[str, Any],
) -> None:
    platform_lock = context["platform_lock"]
    if not platform_lock:
        return
    approvals = context["approvals"]
    approval_paths = context["approval_paths"]
    trusted_verifiers = context["trusted_verifiers"]
    acceptance = context["acceptance"]
    core_case_definitions = context["core_case_definitions"]
    conformance_fixture_ids = context["conformance_fixture_ids"]
    verified_hardware = context["verified_hardware"]
    hardware_evaluation_time = context["hardware_evaluation_time"]
    ports = context["ports"]
    port_contract_definitions = context["port_definitions"]
    platform_case_definitions = context["platform_case_definitions"]
    platform_support_definitions = context["platform_support_definitions"]
    conformance = context["conformance"]
    conformance_path = root / "openspec/verification/core-conformance.yaml"
    integration_lock = context["integration_lock"]

    for entry in support.ruby_array(platform_lock.get("profiles")):
        if entry.get("conformance_status") not in (
            "verified",
            "needsReverification",
        ):
            continue
        last = entry.get("last_verified") or {}
        evidence_relative = support.ruby_to_s(last.get("evidence_path"))
        evidence_path, contained = _repo_path(root, evidence_relative, _PCE_PATH)
        record = _json(evidence_path) if contained and evidence_path.is_file() else {}
        release_relative = support.ruby_to_s(last.get("release_subject_path"))
        release_path, release_contained = _repo_path(
            root, release_relative, _RELEASE_SUBJECT_PATH
        )
        release_subject = (
            _json(release_path) if release_contained and release_path.is_file() else {}
        )
        release_approval = approvals.get(release_subject.get("approvalId"))

        acceptance_results = support.ruby_array(record.get("acceptanceResults"))
        acceptance_ids = [result.get("acceptanceId") for result in acceptance_results]
        port_results = support.ruby_array(record.get("portResults"))
        port_ids = [result.get("portId") for result in port_results]
        platform_results = support.ruby_array(record.get("platformCaseResults"))
        platform_ids = [result.get("caseId") for result in platform_results]
        matrix = support.ruby_array(record.get("supportMatrix"))
        cell_ids = [cell.get("cellId") for cell in matrix]
        support_revisions: list[Any] = []
        for cell in matrix:
            revision = support.dig(cell, "implementation", "resultRevision")
            if revision not in support_revisions:
                support_revisions.append(revision)
        evidence_manifest = support.ruby_array(record.get("evidenceManifest"))
        evidence_ids = [item.get("evidenceId") for item in evidence_manifest]
        evidence_hashes = [item.get("sha256") for item in evidence_manifest]
        result_cells = [
            cell
            for result in acceptance_results + port_results + platform_results
            for cell in support.ruby_array(result.get("cells"))
        ]
        result_evidence_hashes = sorted(
            set(
                [cell.get("evidenceSha256") for cell in result_cells]
                + [cell.get("evidenceSha256") for cell in matrix]
            )
        )
        expected_bindings: dict[Any, list[dict[str, Any]]] = {}
        support_by_id = {cell.get("cellId"): cell for cell in matrix}

        def append_binding(evidence_sha: Any, binding: dict[str, Any], cell_id: Any) -> None:
            expected_bindings.setdefault(evidence_sha, []).append(binding)
            support_cell = support_by_id.get(cell_id)
            if support_cell:
                expected_bindings[evidence_sha].append(
                    {
                        "subjectType": "supportCell",
                        "subjectId": cell_id,
                        "definitionSha256": support.support_cell_contract_sha256(
                            support_cell
                        ),
                    }
                )

        for result, subject_type, id_field in (
            *[(result, "coreAcceptance", "acceptanceId") for result in acceptance_results],
            *[(result, "port", "portId") for result in port_results],
            *[(result, "platformCase", "caseId") for result in platform_results],
        ):
            binding = {
                "subjectType": subject_type,
                "subjectId": result.get(id_field),
                "definitionSha256": result.get("definitionSha256"),
            }
            for cell in support.ruby_array(result.get("cells")):
                append_binding(
                    cell.get("evidenceSha256"), binding, cell.get("cellId")
                )
        for cell in matrix:
            expected_bindings.setdefault(cell.get("evidenceSha256"), []).append(
                {
                    "subjectType": "supportCell",
                    "subjectId": cell.get("cellId"),
                    "definitionSha256": support.support_cell_contract_sha256(cell),
                }
            )
        manifest_bindings_valid = all(
            _binding_is_valid(
                root=root,
                item=item,
                record=record,
                support_revisions=support_revisions,
                expected_bindings=expected_bindings.get(item.get("sha256"), []),
                approvals=approvals,
                approval_paths=approval_paths,
                trusted_verifiers=trusted_verifiers,
            )
            for item in evidence_manifest
        )

        def passed_cells(result: Mapping[str, Any]) -> bool:
            cells = support.ruby_array(result.get("cells"))
            ids = [cell.get("cellId") for cell in cells]
            return bool(
                result.get("result") == "passed"
                and cells
                and sorted(ids) == sorted(cell_ids)
                and len(set(ids)) == len(ids)
                and all(
                    _SHA256.fullmatch(
                        support.ruby_to_s(cell.get("evidenceSha256"))
                    )
                    is not None
                    for cell in cells
                )
            )

        structurally_complete = bool(
            record.get("acceptanceCount") == len(acceptance_results)
            and len(set(acceptance_ids)) == len(acceptance_ids)
            and len(set(port_ids)) == len(port_ids)
            and len(set(platform_ids)) == len(platform_ids)
            and len(set(cell_ids)) == len(cell_ids)
            and len(set(evidence_ids)) == len(evidence_ids)
            and len(set(evidence_hashes)) == len(evidence_hashes)
            and sorted(evidence_hashes) == result_evidence_hashes
            and manifest_bindings_valid
            and all(passed_cells(result) for result in acceptance_results)
            and all(passed_cells(result) for result in port_results)
            and all(passed_cells(result) for result in platform_results)
            and all(
                cell.get("result") == "passed"
                and support.dig(cell, "environment", "osName") == entry.get("platform")
                and _SHA256.fullmatch(
                    support.ruby_to_s(cell.get("evidenceSha256"))
                )
                is not None
                and _SHA256.fullmatch(
                    support.ruby_to_s(
                        support.dig(
                            cell, "implementation", "releaseArtifactSha256"
                        )
                    )
                )
                is not None
                and support.git_commit(
                    support.dig(cell, "implementation", "resultRevision"), root
                )
                and support.git_ancestor(
                    support.dig(cell, "implementation", "resultRevision"),
                    support.git_head_revision(root),
                    root,
                )
                for cell in matrix
            )
        )
        approval = approvals.get(last.get("approval_id"))
        matrix_hash = support.sha256_bytes(support.compact_json_bytes(matrix))
        try:
            observed_at = support.parse_iso8601(record["observedAt"])
            valid_until = support.parse_iso8601(record["validUntil"])
            approved_at = (
                support.parse_iso8601(approval["approvedAt"]) if approval else None
            )
            valid_approval_time = bool(
                approval
                and approved_at is not None
                and observed_at <= approved_at <= valid_until
            )
            current_window = bool(
                hardware_evaluation_time
                and approved_at is not None
                and approved_at
                <= support.Rfc3339Instant.coerce(hardware_evaluation_time)
                <= valid_until
            )
            release_created = support.parse_iso8601(release_subject["createdAt"])
            release_approved = (
                support.parse_iso8601(release_approval["approvedAt"])
                if release_approval
                else None
            )
            valid_release_time = bool(
                release_approval
                and release_approved is not None
                and release_created <= release_approved <= observed_at
            )
        except (KeyError, TypeError, ValueError):
            valid_approval_time = False
            current_window = False
            valid_release_time = False
        normalized_matrix = [
            {
                "cellId": cell.get("cellId"),
                "implementation": cell.get("implementation"),
                "environment": cell.get("environment"),
            }
            for cell in matrix
        ]
        release_valid = bool(
            release_contained
            and release_path.is_file()
            and support.sha256_file(release_path) == last.get("release_subject_sha256")
            and support.dig(record, "releaseSubject", "id")
            == release_subject.get("releaseId")
            and support.dig(record, "releaseSubject", "sha256")
            == last.get("release_subject_sha256")
            and release_subject.get("platform") == entry.get("platform")
            and release_subject.get("supportMatrix") == normalized_matrix
            and support.dig(release_subject, "platformProfile", "id")
            == entry.get("id")
            and support.dig(release_subject, "platformProfile", "version")
            == entry.get("version")
            and support.dig(release_subject, "platformProfile", "profileSha256")
            == last.get("profile_sha256")
            and support.dig(
                release_subject, "platformProfile", "verificationSha256"
            )
            == last.get("verification_sha256")
            and support.dig(
                release_subject, "platformProfile", "caseManifestSha256"
            )
            == last.get("case_manifest_sha256")
            and support.dig(release_subject, "coreBaseline", "id")
            == last.get("core_baseline")
            and support.dig(release_subject, "coreBaseline", "sha256")
            == last.get("core_baseline_sha256")
            and release_subject.get("conformanceSuiteSha256")
            == last.get("conformance_suite_sha256")
            and release_subject.get("integrationLockSha256")
            == last.get("integration_lock_sha256")
            and release_subject.get("approvalId")
            == last.get("release_subject_approval_id")
            and len(support_revisions) == 1
            and release_approval
            and valid_release_time
            and release_approval.get("subjectType") == "platformReleaseSubject"
            and release_approval.get("subjectId") == release_subject.get("releaseId")
            and release_approval.get("subjectRevision") == 1
            and release_approval.get("subjectSha256")
            == last.get("release_subject_sha256")
            and release_approval.get("baseRevision") == support_revisions[0]
            and release_approval.get("decision") == "approved"
            and support.externally_verified(
                approval_paths.get(release_approval.get("approvalId")),
                release_path,
                release_approval,
                trusted_verifiers,
                root=root,
            )
        )
        valid = bool(
            contained
            and evidence_path.is_file()
            and evidence_path.stem == record.get("evidenceId")
            and support.sha256_file(evidence_path) == last.get("evidence_sha256")
            and structurally_complete
            and release_valid
            and record.get("status") == "verified"
            and record.get("platform") == entry.get("platform")
            and support.dig(record, "platformProfile", "id") == entry.get("id")
            and support.dig(record, "platformProfile", "version")
            == entry.get("version")
            and support.dig(record, "platformProfile", "profileSha256")
            == last.get("profile_sha256")
            and support.dig(record, "platformProfile", "verificationSha256")
            == last.get("verification_sha256")
            and support.dig(record, "platformProfile", "caseManifestSha256")
            == last.get("case_manifest_sha256")
            and support.dig(record, "coreBaseline", "id")
            == last.get("core_baseline")
            and support.dig(record, "coreBaseline", "sha256")
            == last.get("core_baseline_sha256")
            and support.dig(record, "conformanceSuite", "sha256")
            == last.get("conformance_suite_sha256")
            and support.dig(record, "integrationLock", "sha256")
            == last.get("integration_lock_sha256")
            and matrix_hash == last.get("support_matrix_sha256")
            and record.get("validUntil") == last.get("valid_until")
            and len(support_revisions) == 1
            and sorted(support.ruby_array(record.get("revalidationTriggers")))
            == sorted(support.PLATFORM_REVALIDATION_TRIGGERS)
            and valid_approval_time
            and record.get("approvalId") == last.get("approval_id")
            and approval
            and approval.get("subjectType") == "platformConformance"
            and approval.get("subjectId") == record.get("evidenceId")
            and approval.get("subjectRevision") == 1
            and approval.get("subjectSha256") == last.get("evidence_sha256")
            and approval.get("baseRevision") == support_revisions[0]
            and approval.get("decision") == "approved"
            and support.externally_verified(
                approval_paths.get(approval.get("approvalId")),
                evidence_path,
                approval,
                trusted_verifiers,
                root=root,
            )
        )

        if entry.get("conformance_status") == "verified":
            results_by_acceptance = {
                result.get("acceptanceId"): result for result in acceptance_results
            }
            # Staged-release scoping: a verified PCE must cover exactly the
            # acceptance IDs of the release subject's includedCapabilities.
            # An invalid registry or an empty/undeclared scope fails closed —
            # applicability is never guessed from the full Core AC set.
            included_capabilities = {
                support.ruby_to_s(item)
                for item in support.ruby_array(
                    release_subject.get("includedCapabilities")
                )
            }
            capability_of_acceptance = capability_scope["capability_of_acceptance"]
            scoped_acceptance = sorted(
                scoped_id
                for scoped_id, capability in capability_of_acceptance.items()
                if capability in included_capabilities
            )
            exact_acceptance = (
                bool(capability_scope["registry_ok"])
                and bool(scoped_acceptance)
                and sorted(acceptance_ids) == scoped_acceptance
            )
            support_by_id = {cell.get("cellId"): cell for cell in matrix}
            for result in acceptance_results:
                definition = core_case_definitions.get(result.get("acceptanceId"), {})
                minimum = definition.get("minimum_evidence")
                cells = support.ruby_array(result.get("cells"))
                cells_valid = [cell.get("cellId") for cell in cells] == cell_ids
                for cell in cells:
                    evidence_item = next(
                        (
                            item
                            for item in evidence_manifest
                            if item.get("sha256") == cell.get("evidenceSha256")
                        ),
                        None,
                    )
                    if minimum == "parserGolden":
                        fixtures = support.ruby_array(cell.get("fixtureRefs"))
                        refs_valid = bool(
                            fixtures
                            and not support.ordered_difference(
                                fixtures, conformance_fixture_ids
                            )
                            and not support.ruby_array(cell.get("hardwareMatrixRefs"))
                        )
                    elif minimum == "realHardware":
                        hardware_refs = support.ruby_array(
                            cell.get("hardwareMatrixRefs")
                        )
                        refs_valid = bool(
                            hardware_refs
                            and not support.ruby_array(cell.get("fixtureRefs"))
                            and all(
                                _hardware_ref_valid(
                                    evidence_id=evidence_id,
                                    verified_hardware=verified_hardware,
                                    platform=entry.get("platform"),
                                    cell=cell,
                                    support_by_id=support_by_id,
                                    result_id=result.get("acceptanceId"),
                                    entry=entry,
                                    definition=definition,
                                )
                                for evidence_id in hardware_refs
                            )
                        )
                    else:
                        refs_valid = not support.ruby_array(
                            cell.get("fixtureRefs")
                        ) and not support.ruby_array(cell.get("hardwareMatrixRefs"))
                    cells_valid = bool(
                        cells_valid
                        and evidence_item
                        and evidence_item.get("classification") == minimum
                        and refs_valid
                    )
                exact_acceptance = bool(
                    exact_acceptance
                    and definition.get("test_id") == result.get("testId")
                    and definition.get("method") == result.get("method")
                    and result.get("definitionSha256")
                    == support.acceptance_case_contract_sha256(
                        result.get("acceptanceId"), definition
                    )
                    and minimum == result.get("minimumEvidence")
                    and cells_valid
                )

            exact_ports = sorted(port_ids) == sorted(ports.keys()) and all(
                (definition := port_contract_definitions.get(result.get("portId")))
                is not None
                and result.get("definitionSha256")
                == support.port_contract_sha256(result.get("portId"), definition)
                for result in port_results
            )
            expected_platform_cases = support.ruby_array(
                platform_case_definitions.get(entry.get("platform"))
            )
            expected_platform_ids = [case.get("id") for case in expected_platform_cases]
            exact_platform = sorted(platform_ids) == sorted(expected_platform_ids)
            for result in platform_results:
                expected_case = next(
                    (
                        case
                        for case in expected_platform_cases
                        if case.get("id") == result.get("caseId")
                    ),
                    {},
                )
                cells = support.ruby_array(result.get("cells"))
                refs_valid = [cell.get("cellId") for cell in cells] == cell_ids
                for cell in cells:
                    evidence_item = next(
                        (
                            item
                            for item in evidence_manifest
                            if item.get("sha256") == cell.get("evidenceSha256")
                        ),
                        None,
                    )
                    hardware_refs = support.ruby_array(
                        cell.get("hardwareMatrixRefs")
                    )
                    if expected_case.get("minimum_evidence") == "realHardware":
                        cell_refs_valid = bool(
                            hardware_refs
                            and all(
                                _hardware_ref_valid(
                                    evidence_id=evidence_id,
                                    verified_hardware=verified_hardware,
                                    platform=entry.get("platform"),
                                    cell=cell,
                                    support_by_id=support_by_id,
                                    result_id=result.get("caseId"),
                                    entry=entry,
                                    definition=expected_case,
                                )
                                for evidence_id in hardware_refs
                            )
                        )
                    else:
                        cell_refs_valid = not hardware_refs
                    refs_valid = bool(
                        refs_valid
                        and not support.ruby_array(cell.get("fixtureRefs"))
                        and cell_refs_valid
                        and evidence_item
                        and evidence_item.get("classification")
                        == expected_case.get("minimum_evidence")
                    )
                exact_platform = bool(
                    exact_platform
                    and expected_case.get("test_id") == result.get("testId")
                    and expected_case.get("method") == result.get("method")
                    and result.get("definitionSha256")
                    == support.acceptance_case_contract_sha256(
                        result.get("caseId"), expected_case
                    )
                    and expected_case.get("minimum_evidence")
                    == result.get("minimumEvidence")
                    and refs_valid
                )

            expected_cells = support.ruby_array(
                platform_support_definitions.get(entry.get("platform"))
            )
            exact_matrix = cell_ids == [cell.get("id") for cell in expected_cells]
            for index, cell in enumerate(matrix):
                expected = expected_cells[index] if index < len(expected_cells) else {}
                environment = cell.get("environment") or {}
                evidence_item = next(
                    (
                        item
                        for item in evidence_manifest
                        if item.get("sha256") == cell.get("evidenceSha256")
                    ),
                    None,
                )
                exact_matrix = bool(
                    exact_matrix
                    and environment.get("architecture") == expected.get("architecture")
                    and environment.get("packageFormat")
                    == expected.get("package_format")
                    and support.ruby_to_s(environment.get("osVersion")).startswith(
                        support.ruby_to_s(expected.get("os_version_family"))
                    )
                    and evidence_item
                    and evidence_item.get("classification") == "platform"
                )
            exact_port_evidence = True
            for result in port_results:
                cells = support.ruby_array(result.get("cells"))
                cell_valid = [cell.get("cellId") for cell in cells] == cell_ids
                for cell in cells:
                    evidence_item = next(
                        (
                            item
                            for item in evidence_manifest
                            if item.get("sha256") == cell.get("evidenceSha256")
                        ),
                        None,
                    )
                    cell_valid = bool(
                        cell_valid
                        and not support.ruby_array(cell.get("fixtureRefs"))
                        and not support.ruby_array(cell.get("hardwareMatrixRefs"))
                        and evidence_item
                        and evidence_item.get("classification") == "platform"
                    )
                exact_port_evidence = exact_port_evidence and cell_valid

            if not exact_acceptance:
                errors.append(
                    f"platform {entry.get('platform')} conformance evidence does not exactly cover current Core AC/Test IDs"
                )
            if not exact_ports:
                errors.append(
                    f"platform {entry.get('platform')} conformance evidence does not exactly cover current Core Port IDs"
                )
            if not exact_platform:
                errors.append(
                    f"platform {entry.get('platform')} conformance evidence does not exactly cover current platform release cases"
                )
            if not exact_matrix:
                errors.append(
                    f"platform {entry.get('platform')} conformance evidence does not exactly cover its declared support matrix"
                )
            if not exact_port_evidence:
                errors.append(
                    f"platform {entry.get('platform')} Port evidence is not classified as platform evidence"
                )
            valid = bool(
                valid
                and support.dig(record, "conformanceSuite", "id")
                == conformance.get("suite")
                and support.dig(record, "conformanceSuite", "sha256")
                == support.sha256_file(conformance_path)
                and support.dig(record, "integrationLock", "id")
                == integration_lock.get("lock")
                and record.get("acceptanceCount")
                == support.dig(conformance, "acceptance_index", "count")
                and len(results_by_acceptance)
                == support.dig(conformance, "acceptance_index", "count")
                and support.dig(record, "platformProfile", "caseManifestSha256")
                == entry.get("case_manifest_sha256")
                and current_window
                and exact_acceptance
                and exact_ports
                and exact_port_evidence
                and exact_platform
                and exact_matrix
            )
        if not valid:
            errors.append(
                f"platform {entry.get('platform')} {entry.get('conformance_status')} lacks matching externally verified four-axis evidence"
            )


def _hardware_ref_valid(
    *,
    evidence_id: Any,
    verified_hardware: Mapping[str, Mapping[str, Any]],
    platform: Any,
    cell: Mapping[str, Any],
    support_by_id: Mapping[Any, Mapping[str, Any]],
    result_id: Any,
    entry: Mapping[str, Any],
    definition: Mapping[str, Any],
) -> bool:
    hardware = verified_hardware.get(evidence_id)
    if not hardware:
        return False
    bindings = support.ruby_array(hardware.get("acceptanceCaseBindings"))
    return bool(
        hardware.get("platform") == platform
        and hardware.get("hostSupportCellId") == cell.get("cellId")
        and hardware.get("implementationRevision")
        == support.dig(
            support_by_id.get(cell.get("cellId")), "implementation", "resultRevision"
        )
        and result_id in support.ruby_array(hardware.get("acceptanceIds"))
        and hardware.get("platformCaseManifestSha256")
        == entry.get("case_manifest_sha256")
        and any(
            binding.get("acceptanceId") == result_id
            and binding.get("testId") == definition.get("test_id")
            and binding.get("method") == definition.get("method")
            and binding.get("definitionSha256")
            == support.acceptance_case_contract_sha256(result_id, definition)
            for binding in bindings
        )
        and support.dig(hardware, "artifact", "sha256")
        == cell.get("evidenceSha256")
    )


def _platform_and_conformance_ratification(
    root: Path, errors: list[str], context: Mapping[str, Any]
) -> None:
    approvals = context["approvals"]
    approval_paths = context["approval_paths"]
    trusted_verifiers = context["trusted_verifiers"]
    current_platform_path = root / "openspec/platforms/PLATFORM-PROFILES.lock.yaml"
    history_records = []
    for record in context["platform_lock_chain"]:
        record_path = Path(record.get("path", ""))
        if not record_path.is_absolute():
            record_path = root / record_path
        if record_path.resolve() != current_platform_path.resolve():
            history_records.append(record)
    for record in history_records:
        lock = record["document"]
        path = Path(record["path"])
        if not path.is_absolute():
            path = root / path
        approval = approvals.get(support.dig(lock, "ratification", "approval_ref"))
        valid = bool(
            approval
            and approval.get("subjectType") == "platformLock"
            and approval.get("subjectId") == lock.get("lock")
            and approval.get("subjectRevision") == lock.get("revision")
            and approval.get("subjectSha256") == support.sha256_file(path)
            and approval.get("decision") == "approved"
            and support.git_commit(approval.get("baseRevision"), root)
            and support.externally_verified(
                approval_paths.get(approval.get("approvalId")),
                path,
                approval,
                trusted_verifiers,
                root=root,
            )
        )
        if not valid:
            errors.append(
                f"historical platform lock {support.relative(path, root)} lacks externally verified immutable approval"
            )

    platform_lock = context["platform_lock"]
    platform_lock_path = current_platform_path
    if platform_lock and platform_lock.get("status") == "accepted":
        approval = approvals.get(
            support.dig(platform_lock, "ratification", "approval_ref")
        )
        try:
            platform_approved = (
                support.parse_iso8601(approval["approvedAt"]) if approval else None
            )
            prerequisites = [
                approvals.get(reference)
                for entry in support.ruby_array(platform_lock.get("profiles"))
                if entry.get("conformance_status") == "verified"
                for reference in (
                    support.dig(entry, "last_verified", "approval_id"),
                    support.dig(
                        entry, "last_verified", "release_subject_approval_id"
                    ),
                )
            ]
            chronology_valid = bool(
                approval
                and platform_approved is not None
                and all(
                    prerequisite
                    and support.parse_iso8601(prerequisite["approvedAt"])
                    <= platform_approved
                    for prerequisite in prerequisites
                )
            )
        except (KeyError, TypeError, ValueError):
            chronology_valid = False
        valid = bool(
            approval
            and approval.get("subjectType") == "platformLock"
            and approval.get("subjectId") == platform_lock.get("lock")
            and approval.get("subjectRevision") == platform_lock.get("revision")
            and approval.get("subjectSha256")
            == support.sha256_file(platform_lock_path)
            and approval.get("decision") == "approved"
            and support.git_commit(approval.get("baseRevision"), root)
            and chronology_valid
            and support.externally_verified(
                approval_paths.get(approval.get("approvalId")),
                platform_lock_path,
                approval,
                trusted_verifiers,
                root=root,
            )
        )
        if not valid:
            errors.append("accepted platform lock lacks externally verified approval")

    conformance = context["conformance"]
    conformance_path = root / "openspec/verification/core-conformance.yaml"
    baseline = context["baseline"]
    integration_lock = context["integration_lock"]
    if conformance and conformance.get("status") == "accepted":
        approval = approvals.get(
            support.dig(conformance, "ratification", "approval_ref")
        )
        valid = bool(
            approval
            and approval.get("subjectType") == "conformanceSuite"
            and approval.get("subjectId") == conformance.get("suite")
            and approval.get("subjectRevision") == conformance.get("revision")
            and approval.get("subjectSha256") == support.sha256_file(conformance_path)
            and approval.get("decision") == "approved"
            and support.git_commit(approval.get("baseRevision"), root)
            and baseline
            and conformance.get("core_baseline") == baseline.get("baseline")
            and baseline.get("status") == "accepted"
            and integration_lock
            and integration_lock.get("status") == "accepted"
            and integration_lock.get("execution_gate") == "open"
            and support.externally_verified(
                approval_paths.get(approval.get("approvalId")),
                conformance_path,
                approval,
                trusted_verifiers,
                root=root,
            )
        )
        if not valid:
            errors.append(
                "accepted conformance suite lacks external approval or accepted Core binding"
            )


def run_release_guard(
    root: Path, errors: list[str], context: Mapping[str, Any]
) -> None:
    """Run the Ruby guard's immutable identity and release verification tail."""

    root = root.resolve()
    missing = sorted(REQUIRED_CONTEXT_KEYS.difference(context.keys()))
    if missing:
        errors.append(
            "release guard context missing required keys: " + ", ".join(missing)
        )
        return
    try:
        _identity_and_ledger_guard(root, errors, context)
        _accepted_axis_approvals(root, errors, context)
        capability_scope = _capability_scope_guard(root, errors, context)
        _pce_guard(root, errors, context, capability_scope)
        _platform_and_conformance_ratification(root, errors, context)
    except (AttributeError, KeyError, TypeError, ValueError, OSError) as exc:
        errors.append(
            f"release guard failed closed on malformed lifecycle context: {exc}"
        )


__all__ = ["REQUIRED_CONTEXT_KEYS", "run_release_guard"]
