#!/usr/bin/env python3
"""Offline, stdlib-only TASK-AIN-009R contract checks.

This validator performs no process, device, HDC or network dispatch. It checks
the frozen schema identities and semantic vector facts that Draft 2020-12
cannot express without a product-owned admission resolver.
"""

from __future__ import annotations

import hashlib
import json
import re
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any


RUN_ROOT = Path(__file__).resolve().parent
CHANGE_ROOT = RUN_ROOT.parents[2]
REPOSITORY_ROOT = CHANGE_ROOT.parents[2]
CONTRACT_ROOT = CHANGE_ROOT / "contracts"

SCHEMA_IDS = {
    "agent-device-capability.schema.v1-draft.json":
        "https://arkdeck.dev/schemas/agent-device-capability-1.0.0.json",
    "agent-execution-authority.schema.v1-draft.json":
        "https://arkdeck.dev/schemas/agent-execution-authority-1.0.0.json",
    "agent-authority-usage.schema.v1-draft.json":
        "https://arkdeck.dev/schemas/agent-authority-usage-1.0.0.json",
    "journal-event.schema.v2.2-draft.json":
        "https://arkdeck.dev/schemas/journal-event-2.2.0-draft.json",
    "manifest.schema.v2.2-draft.json":
        "https://arkdeck.dev/schemas/session-manifest-2.2.0-draft.json",
}

AUTHORITY_FIELDS = {
    "readyTask": {
        "kind", "changeId", "taskId", "mainCommitOID", "taskBlobOID",
        "approvalPRNumber",
    },
    "deviceCapability": {
        "kind", "capabilityId", "mainCommitOID", "capabilityBlobOID",
        "approvalPRNumber",
    },
    "standingAuthorization": {
        "kind", "authorizationId", "mainCommitOID", "authorizationBlobOID",
        "approvalPRNumber",
    },
}

SCOPE_CONTRACTS = {
    "hilog.device-persist-restored.v1":
        ("captureHilog", "captureOwned", "hilog"),
    "ui-dump.owned-sidecar.v1":
        ("captureUIDump", "captureOwned", "uiDump"),
    "trace.owned-capture.v1":
        ("captureTrace", "captureOwned", "trace"),
    "hap.install-preserve-data.v1": ("installHAP", "bundle", None),
    "native-library.app-owned-atomic.v1":
        ("deployNativeLibrary", "bundle", None),
    "application.start.v1": ("startApplication", "bundle", None),
    "application.stop.v1": ("stopApplication", "bundle", None),
    "owned-file.send.v1": ("sendOwnedFile", "jobOwnedRemote", None),
    "port-forward.create.v1":
        ("createPortForward", "portForward", None),
    "port-forward.remove.v1":
        ("removePortForward", "portForward", None),
    "device.reboot.v1": ("rebootDevice", "deviceMode", None),
}

FORBIDDEN_CARRIER_KEYS = {
    "approvedby", "carrier", "path", "argv", "readback", "usage", "outcome",
    "serial", "connectkey", "authorizationbytes", "authorizationpath",
    "capabilitybytes", "capabilitypath", "bookmark", "descriptor",
}


class DuplicateMemberError(ValueError):
    pass


def reject_duplicates(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise DuplicateMemberError(key)
        result[key] = value
    return result


def load(path: Path) -> dict[str, Any]:
    return json.loads(
        path.read_text(encoding="utf-8"),
        object_pairs_hook=reject_duplicates,
    )


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def walk(value: Any, callback: Any, path: str = "$") -> None:
    callback(value, path)
    if isinstance(value, dict):
        for key, nested in value.items():
            walk(nested, callback, f"{path}.{key}")
    elif isinstance(value, list):
        for index, nested in enumerate(value):
            walk(nested, callback, f"{path}[{index}]")


def check_closed_object(value: Any, path: str) -> None:
    if isinstance(value, dict) and value.get("type") == "object":
        assert value.get("additionalProperties") is False, path


def check_ref(value: Any, path: str) -> None:
    if not isinstance(value, dict) or "$ref" not in value:
        return
    reference = value["$ref"]
    if not reference.startswith("http"):
        return
    allowed = (
        "https://arkdeck.dev/schemas/workflow-step-1.0.0.json#",
        "https://arkdeck.dev/schemas/agent-execution-authority-1.0.0.json",
    )
    assert reference.startswith(allowed), f"{path}: {reference}"


def check_forbidden_carrier_key(value: Any, path: str) -> None:
    if not isinstance(value, dict):
        return
    for key in value:
        assert key.lower() not in FORBIDDEN_CARRIER_KEYS, f"{path}.{key}"


def parse_utc(value: str) -> datetime:
    assert re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z", value)
    return datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(
        tzinfo=timezone.utc)


schemas: dict[str, dict[str, Any]] = {}
for filename, identifier in SCHEMA_IDS.items():
    schema = load(CONTRACT_ROOT / filename)
    assert schema["$schema"] == "https://json-schema.org/draft/2020-12/schema"
    assert schema["$id"] == identifier
    walk(schema, check_closed_object)
    walk(schema, check_ref)
    schemas[filename] = schema

vectors = load(RUN_ROOT / "vectors.json")
capability = vectors["capability"]
walk(capability, check_forbidden_carrier_key)
assert capability["documentType"] == "agentDeviceCapability"
assert capability["schemaVersion"] == "1.0.0"
assert re.fullmatch(
    r"CAP-E1-[A-Z0-9]+(?:-[A-Z0-9]+)*", capability["capabilityId"])

registry = load(CONTRACT_ROOT / "agent-device-operation-registry.v1-draft.json")
registry_profiles: dict[str, tuple[str, dict[str, Any]]] = {}
for operation in registry["operations"]:
    for profile in operation["profiles"]:
        if profile["declaredEffect"] == "deviceMutation":
            registry_profiles[profile["id"]] = (operation["id"], profile)
assert set(registry_profiles) == set(SCOPE_CONTRACTS)

schema_branches = (
    schemas["agent-device-capability.schema.v1-draft.json"]
    ["$defs"]["operationScope"]["oneOf"]
)
assert len(schema_branches) == 11
for branch in schema_branches:
    properties = branch["properties"]
    profile_id = properties["profileId"]["const"]
    operation_id, profile = registry_profiles[profile_id]
    assert properties["operationId"]["const"] == operation_id
    assert properties["configurationId"]["const"] == profile["configurationId"]
    assert (
        properties["configurationSha256"]["const"]
        == profile["configurationSha256"]
    )

scopes = capability["operationScopes"]
assert len(scopes) == 11
assert {scope["profileId"] for scope in scopes} == set(SCOPE_CONTRACTS)
namespace_kinds: set[str] = set()
for scope in scopes:
    profile_id = scope["profileId"]
    expected_operation, expected_namespace, expected_family = (
        SCOPE_CONTRACTS[profile_id]
    )
    operation_id, profile = registry_profiles[profile_id]
    assert scope["operationId"] == expected_operation == operation_id
    assert scope["configurationId"] == profile["configurationId"]
    assert scope["configurationSha256"] == profile["configurationSha256"]
    assert scope["effect"] == "deviceMutation"
    assert scope["namespace"]["kind"] == expected_namespace
    if expected_family is not None:
        assert scope["namespace"]["family"] == expected_family
    namespace_kinds.add(scope["namespace"]["kind"])
assert namespace_kinds == {
    "captureOwned", "bundle", "jobOwnedRemote", "portForward", "deviceMode",
}

provenance = vectors["provenance"]
assert provenance["repository"] == "ArkDeck/ArkDeck"
assert provenance["branch"] == "main"
assert provenance["networkAvailable"] is True
assert provenance["offlineCacheUsed"] is False
assert (
    provenance["currentMainCapabilityBlobOID"]
    == provenance["headCapabilityBlobOID"]
    == provenance["mergeCapabilityBlobOID"]
)
approval = provenance["acceptancePR"]
assert approval["state"] == "MERGED"
assert approval["baseRefName"] == "main"
assert approval["author"] == "github-actions[bot]"
assert approval["reviewer"] == approval["merger"] == "lvye"
assert approval["reviewState"] == "APPROVED"
assert approval["reviewCommitOID"] == approval["headCommitOID"]
assert approval["mergeCommitIsCurrentMainAncestor"] is True
merged_at = parse_utc(approval["mergedAt"])
valid_until = parse_utc(capability["validUntil"])
assert merged_at < valid_until <= merged_at + timedelta(days=31)

authority_refs = vectors["authorityRefs"]
assert set(authority_refs) == {"e0", "e1", "e2"}
for reference in authority_refs.values():
    kind = reference["kind"]
    assert set(reference) == AUTHORITY_FIELDS[kind]

usage = vectors["usage"]
assert set(usage) == {"documentType", "schemaVersion", "reservations"}
assert usage["documentType"] == "agentAuthorityUsage"
assert usage["schemaVersion"] == "1.0.0"
reservation = usage["reservations"][0]
assert reservation["authorizationRef"]["kind"] == "deviceCapability"
assert reservation["ordinal"] <= reservation["maximumUses"] <= 32
assert reservation["maximumConcurrentJobs"] == 1
reserved_at = parse_utc(reservation["reservedAt"])
deadline = parse_utc(vectors["leaseRequestDeadline"])
duration = capability["limits"]["maximumJobDurationSeconds"]
grace = capability["limits"]["compensationGraceSeconds"]
expected_forward = min(
    deadline, valid_until, reserved_at + timedelta(seconds=duration))
assert parse_utc(reservation["forwardLeaseExpiresAt"]) == expected_forward
expected_compensation = min(
    valid_until + timedelta(seconds=grace),
    expected_forward + timedelta(seconds=grace),
)
assert (
    parse_utc(reservation["compensationLeaseExpiresAt"])
    == expected_compensation
)

effect_authority = {
    "readOnly": "readyTask",
    "deviceMutation": "deviceCapability",
    "destructive": "standingAuthorization",
}
for session in vectors["sessions"].values():
    assert all(event["schemaVersion"] == "2.2.0" for event in session["journal"])
    for event in session["journal"]:
        parse_utc(event["timestamp"])
    created = session["journal"][0]["payload"]
    reference = created["authorizationRef"]
    assert reference["kind"] == effect_authority[session["effect"]]
    expected_usage = session["usageReservationId"]
    assert created.get("usageReservationId") == expected_usage
    intent_ids = {
        event["eventId"] for event in session["journal"]
        if event["kind"] in {"stepIntent", "compensationIntent"}
    }
    authorization = session["manifest"]["authorization"]
    parse_utc(session["manifest"]["createdAt"])
    parse_utc(session["manifest"]["completedAt"])
    assert authorization["authorizationRef"] == reference
    assert authorization["usageReservationId"] == expected_usage
    assert set(authorization["externalIntentEventIds"]) == intent_ids

legacy = vectors["legacyVersions"]
assert [entry["version"] for entry in legacy] == ["1.x", "2.0.0", "2.1.0"]
for entry in legacy:
    assert entry["writeRule"] == "preserveDeclaredVersionAndBytes"
    for path_key, hash_key in (
        ("journalSchema", "journalSHA256"),
        ("manifestSchema", "manifestSHA256"),
    ):
        path = (REPOSITORY_ROOT / entry[path_key]).resolve()
        path.relative_to(REPOSITORY_ROOT.resolve())
        assert sha256(path) == entry[hash_key]
        load(path)

duplicate_count = 0
for filename in ("duplicate-capability.json", "duplicate-capability-escaped.json"):
    try:
        load(RUN_ROOT / filename)
    except DuplicateMemberError as error:
        assert str(error) == "capabilityId"
        duplicate_count += 1
    else:
        raise AssertionError(f"{filename} accepted")
assert duplicate_count == 2

schema_hashes = {
    filename: sha256(CONTRACT_ROOT / filename)
    for filename in sorted(SCHEMA_IDS)
}
print(
    "TEST-AIN-CAP-CONTRACT-001 PASS "
    "e1_profiles=11 namespaces=5 authority_kinds=3 legacy_versions=3 "
    "process_dispatch=0 device_dispatch=0 hdc_dispatch=0 network=0"
)
print("schema_sha256=" + json.dumps(schema_hashes, sort_keys=True))
