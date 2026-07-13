#!/usr/bin/env python3
"""Dependency-free structural checks for ArkDeck JSON and JSON Schema files."""

from __future__ import annotations

import json
import pathlib
import re
import sys
from datetime import datetime
from typing import Any

from sdd_protected_set import require_sdd_runtime

# The structural checks below only use the standard library, but the whole
# SDD toolchain fails closed on an unpinned runtime (enforcement.md).
require_sdd_runtime()

ROOT = pathlib.Path(__file__).resolve().parent.parent
errors: list[str] = []
RFC3339_DATE_TIME = re.compile(
    r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]+)?(?:Z|[+-][0-9]{2}:[0-9]{2})$"
)


def no_duplicate_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate object key: {key}")
        result[key] = value
    return result


def pointer(document: Any, fragment: str) -> Any:
    current = document
    if fragment in ("", "#"):
        return current
    if not fragment.startswith("#/"):
        raise KeyError(f"unsupported JSON Pointer fragment {fragment}")
    for raw in fragment[2:].split("/"):
        token = raw.replace("~1", "/").replace("~0", "~")
        current = current[int(token)] if isinstance(current, list) else current[token]
    return current


documents: dict[pathlib.Path, Any] = {}
schema_by_id: dict[str, tuple[pathlib.Path, Any]] = {}

for path in sorted((ROOT / "openspec").rglob("*.json")):
    try:
        document = json.loads(path.read_text(), object_pairs_hook=no_duplicate_object)
        documents[path] = document
        if path.name.endswith(".schema.json"):
            if document.get("$schema") != "https://json-schema.org/draft/2020-12/schema":
                errors.append(f"{path.relative_to(ROOT)}: JSON Schema draft is not 2020-12")
            schema_id = document.get("$id")
            if not isinstance(schema_id, str) or not schema_id:
                errors.append(f"{path.relative_to(ROOT)}: missing $id")
            elif schema_id in schema_by_id:
                errors.append(f"duplicate JSON Schema $id: {schema_id}")
            else:
                schema_by_id[schema_id] = (path, document)
    except (json.JSONDecodeError, ValueError) as exc:
        errors.append(f"{path.relative_to(ROOT)}: {exc}")


def walk_refs(value: Any, owner_path: pathlib.Path, owner_document: Any) -> None:
    if isinstance(value, dict):
        ref = value.get("$ref")
        if isinstance(ref, str):
            try:
                if ref.startswith("#"):
                    pointer(owner_document, ref)
                else:
                    base, separator, fragment = ref.partition("#")
                    if base not in schema_by_id:
                        raise KeyError(f"unknown schema ID {base}")
                    pointer(schema_by_id[base][1], f"#{fragment}" if separator else "#")
            except (KeyError, IndexError, ValueError) as exc:
                errors.append(f"{owner_path.relative_to(ROOT)}: unresolved $ref {ref}: {exc}")
        for child in value.values():
            walk_refs(child, owner_path, owner_document)
    elif isinstance(value, list):
        for child in value:
            walk_refs(child, owner_path, owner_document)


for path, document in documents.items():
    if path.name.endswith(".schema.json"):
        walk_refs(document, path, document)


def type_matches(value: Any, expected: str) -> bool:
    return {
        "null": value is None,
        "boolean": isinstance(value, bool),
        "object": isinstance(value, dict),
        "array": isinstance(value, list),
        "string": isinstance(value, str),
        "integer": isinstance(value, int) and not isinstance(value, bool),
        "number": isinstance(value, (int, float)) and not isinstance(value, bool),
    }.get(expected, False)


def resolve_ref(owner: Any, ref: str) -> tuple[Any, Any]:
    if ref.startswith("#"):
        return pointer(owner, ref), owner
    base, separator, fragment = ref.partition("#")
    target = schema_by_id[base][1]
    return pointer(target, f"#{fragment}" if separator else "#"), target


def validate(instance: Any, schema: Any, owner: Any, location: str = "$") -> list[str]:
    failures: list[str] = []
    if schema is True:
        return failures
    if schema is False:
        return [f"{location}: false schema"]
    if not isinstance(schema, dict):
        return [f"{location}: invalid schema node"]

    if "$ref" in schema:
        target, target_owner = resolve_ref(owner, schema["$ref"])
        failures.extend(validate(instance, target, target_owner, location))

    expected_types = schema.get("type")
    if expected_types is not None:
        expected_types = [expected_types] if isinstance(expected_types, str) else expected_types
        if not any(type_matches(instance, item) for item in expected_types):
            return failures + [f"{location}: expected type {expected_types}, got {type(instance).__name__}"]

    if "const" in schema and instance != schema["const"]:
        failures.append(f"{location}: value differs from const")
    if "enum" in schema and instance not in schema["enum"]:
        failures.append(f"{location}: value is not in enum")

    for index, child in enumerate(schema.get("allOf", [])):
        failures.extend(validate(instance, child, owner, f"{location}.allOf[{index}]"))
    if "anyOf" in schema:
        if not any(not validate(instance, child, owner, location) for child in schema["anyOf"]):
            failures.append(f"{location}: no anyOf branch matched")
    if "oneOf" in schema:
        matches = sum(not validate(instance, child, owner, location) for child in schema["oneOf"])
        if matches != 1:
            failures.append(f"{location}: expected exactly one oneOf match, got {matches}")
    if "not" in schema and not validate(instance, schema["not"], owner, location):
        failures.append(f"{location}: forbidden not schema matched")
    if "if" in schema:
        branch = "then" if not validate(instance, schema["if"], owner, location) else "else"
        if branch in schema:
            failures.extend(validate(instance, schema[branch], owner, location))

    if isinstance(instance, dict):
        required = schema.get("required", [])
        for key in required:
            if key not in instance:
                failures.append(f"{location}: missing required property {key}")
        properties = schema.get("properties", {})
        for key, child in properties.items():
            if key in instance:
                failures.extend(validate(instance[key], child, owner, f"{location}.{key}"))
        additional = schema.get("additionalProperties", True)
        for key in instance.keys() - properties.keys():
            if additional is False:
                failures.append(f"{location}: additional property {key}")
            elif isinstance(additional, dict):
                failures.extend(validate(instance[key], additional, owner, f"{location}.{key}"))
        if "propertyNames" in schema:
            for key in instance:
                failures.extend(validate(key, schema["propertyNames"], owner, f"{location}.propertyName"))
        if len(instance) < schema.get("minProperties", 0):
            failures.append(f"{location}: too few properties")
        if "maxProperties" in schema and len(instance) > schema["maxProperties"]:
            failures.append(f"{location}: too many properties")

    if isinstance(instance, list):
        if len(instance) < schema.get("minItems", 0):
            failures.append(f"{location}: too few items")
        if "maxItems" in schema and len(instance) > schema["maxItems"]:
            failures.append(f"{location}: too many items")
        if schema.get("uniqueItems"):
            normalized = [json.dumps(item, sort_keys=True, separators=(",", ":")) for item in instance]
            if len(normalized) != len(set(normalized)):
                failures.append(f"{location}: duplicate array items")
        if "items" in schema:
            for index, item in enumerate(instance):
                failures.extend(validate(item, schema["items"], owner, f"{location}[{index}]"))
        if "contains" in schema:
            matches = sum(not validate(item, schema["contains"], owner, f"{location}[{index}]") for index, item in enumerate(instance))
            minimum = schema.get("minContains", 1)
            maximum = schema.get("maxContains")
            if matches < minimum:
                failures.append(f"{location}: contains matched {matches}, below {minimum}")
            if maximum is not None and matches > maximum:
                failures.append(f"{location}: contains matched {matches}, above {maximum}")

    if isinstance(instance, str):
        if len(instance) < schema.get("minLength", 0):
            failures.append(f"{location}: string is too short")
        if "maxLength" in schema and len(instance) > schema["maxLength"]:
            failures.append(f"{location}: string is too long")
        if "pattern" in schema and re.search(schema["pattern"], instance) is None:
            failures.append(f"{location}: string does not match pattern")
        if schema.get("format") == "date-time":
            try:
                if RFC3339_DATE_TIME.fullmatch(instance) is None:
                    raise ValueError("not RFC 3339 date-time")
                parsed = datetime.fromisoformat(instance.replace("Z", "+00:00"))
                if parsed.tzinfo is None:
                    raise ValueError("timezone is required")
            except ValueError:
                failures.append(f"{location}: invalid date-time")

    if isinstance(instance, (int, float)) and not isinstance(instance, bool):
        if "minimum" in schema and instance < schema["minimum"]:
            failures.append(f"{location}: below minimum")
        if "maximum" in schema and instance > schema["maximum"]:
            failures.append(f"{location}: above maximum")

    return failures


def check_schema_shape(value: Any, path: str = "$") -> None:
    if isinstance(value, dict):
        if "type" in value:
            types = [value["type"]] if isinstance(value["type"], str) else value["type"]
            if not isinstance(types, list) or any(item not in {"null", "boolean", "object", "array", "string", "integer", "number"} for item in types):
                errors.append(f"schema {path}: invalid type keyword")
        if "required" in value:
            required = value["required"]
            if not isinstance(required, list) or any(not isinstance(item, str) for item in required) or len(required) != len(set(required)):
                errors.append(f"schema {path}: invalid/duplicate required entries")
        for keyword in ("minContains", "maxContains"):
            if keyword in value and (not isinstance(value[keyword], int) or isinstance(value[keyword], bool) or value[keyword] < 0):
                errors.append(f"schema {path}: invalid {keyword}")
        if "pattern" in value:
            try:
                re.compile(value["pattern"])
            except re.error as exc:
                errors.append(f"schema {path}: invalid pattern: {exc}")
        for key, child in value.items():
            check_schema_shape(child, f"{path}.{key}")
    elif isinstance(value, list):
        for index, child in enumerate(value):
            check_schema_shape(child, f"{path}[{index}]")


for path, document in documents.items():
    if path.name.endswith(".schema.json"):
        check_schema_shape(document, str(path.relative_to(ROOT)))

instance_patterns = {
    "openspec/changes/**/task-packets/*.json": {"1.0.0": "https://arkdeck.dev/schemas/task-packet-1.0.0.json"},
    "openspec/changes/**/supersession-barrier-attestation.json": {"1.0.0": "https://arkdeck.dev/schemas/change-supersession-barrier-1.0.0.json"},
    "openspec/approvals/**/*.json": {"1.0.0": "https://arkdeck.dev/schemas/approval-1.0.0.json"},
    "openspec/changes/**/evidence/runs/**/claim.json": {"1.0.0": "https://arkdeck.dev/schemas/task-claim-1.0.0.json"},
    "openspec/changes/**/evidence/runs/**/claim-owner-attestation.json": {"1.0.0": "https://arkdeck.dev/schemas/claim-owner-attestation-1.0.0.json"},
    "openspec/changes/**/evidence/runs/**/resource-identity-attestation.json": {"1.0.0": "https://arkdeck.dev/schemas/resource-identity-attestation-1.0.0.json"},
    "openspec/changes/**/evidence/runs/**/run.json": {"1.0.0": "https://arkdeck.dev/schemas/task-run-1.0.0.json"},
    "openspec/changes/**/evidence/runs/**/run-owner-attestation.json": {"1.0.0": "https://arkdeck.dev/schemas/run-owner-attestation-1.0.0.json"},
    "openspec/changes/**/evidence/runs/**/lab-execution-authorization.json": {"1.0.0": "https://arkdeck.dev/schemas/lab-execution-authorization-1.0.0.json"},
    "openspec/changes/**/evidence/runs/**/lab-execution-plan.json": {"1.0.0": "https://arkdeck.dev/schemas/lab-execution-plan-1.0.0.json"},
    "openspec/verification/hardware-evidence/*.json": {"1.0.0": "https://arkdeck.dev/schemas/hardware-evidence-1.0.0.json"},
    "openspec/platforms/conformance-evidence/*.json": {"1.0.0": "https://arkdeck.dev/schemas/platform-conformance-evidence-1.0.0.json"},
    "openspec/platforms/conformance-evidence/bindings/*.json": {"1.0.0": "https://arkdeck.dev/schemas/pce-evidence-binding-1.0.0.json"},
    "openspec/platforms/release-subjects/*.json": {"1.0.0": "https://arkdeck.dev/schemas/platform-release-subject-1.0.0.json"},
    "openspec/changes/archive/**/pre-archive-verification.json": {"1.0.0": "https://arkdeck.dev/schemas/pre-archive-verification-1.0.0.json"},
    "openspec/changes/**/verification-result.json": {"1.0.0": "https://arkdeck.dev/schemas/change-verification-result-1.0.0.json"},
}
for pattern, version_routes in instance_patterns.items():
    for path in sorted(ROOT.glob(pattern)):
        instance = documents.get(path) or json.loads(path.read_text(), object_pairs_hook=no_duplicate_object)
        schema_version = instance.get("schemaVersion") if isinstance(instance, dict) else None
        schema_id = version_routes.get(schema_version)
        if schema_id is None:
            errors.append(f"{path.relative_to(ROOT)}: unsupported/pinned schemaVersion {schema_version!r}")
            continue
        schema_path, schema = schema_by_id[schema_id]
        for failure in validate(instance, schema, schema):
            errors.append(f"{path.relative_to(ROOT)} against {schema_path.relative_to(ROOT)}: {failure}")


def assert_schema_case(
    name: str,
    schema_id: str,
    fragment: str,
    instance: Any,
    should_accept: bool,
) -> None:
    owner = schema_by_id[schema_id][1]
    schema = pointer(owner, fragment)
    failures = validate(instance, schema, owner)
    accepted = not failures
    if accepted != should_accept:
        expectation = "accept" if should_accept else "reject"
        errors.append(f"schema self-test {name}: expected {expectation}, failures={failures}")


workflow_id = "https://arkdeck.dev/schemas/workflow-step-1.0.0.json"
manifest_id = "https://arkdeck.dev/schemas/manifest-1.0.0.json"
journal_id = "https://arkdeck.dev/schemas/journal-event-1.0.0.json"
task_run_id = "https://arkdeck.dev/schemas/task-run-1.0.0.json"
approval_id = "https://arkdeck.dev/schemas/approval-1.0.0.json"
claim_owner_id = "https://arkdeck.dev/schemas/claim-owner-attestation-1.0.0.json"
lab_plan_id = "https://arkdeck.dev/schemas/lab-execution-plan-1.0.0.json"
pce_id = "https://arkdeck.dev/schemas/platform-conformance-evidence-1.0.0.json"

assert_schema_case(
    "canonical full Git OID",
    approval_id,
    "#/properties/baseRevision",
    "a" * 40,
    True,
)
assert_schema_case(
    "movable Git revspec",
    approval_id,
    "#/properties/baseRevision",
    "refs/tags/release",
    False,
)
assert_schema_case(
    "PCE raw artifact without canonical binding",
    pce_id,
    "#/properties/evidenceManifest/items",
    {
        "evidenceId": "PCEV-RAW",
        "sha256": "a" * 64,
        "classification": "platform",
        "location": "controlledExternal:artifact",
    },
    False,
)

assert_schema_case(
    "closed approved read operation",
    workflow_id,
    "#/$defs/approvedRemoteReadArguments",
    {"catalogId": "arkdeck-remote-operations", "actionId": "deviceSummary", "parameters": {}, "artifactId": "artifact-1"},
    True,
)
assert_schema_case(
    "unknown approved read operation",
    workflow_id,
    "#/$defs/approvedRemoteReadArguments",
    {"catalogId": "evil-catalog", "actionId": "erase-userdata", "parameters": {}, "artifactId": "artifact-1"},
    False,
)
assert_schema_case(
    "destructive effect downgrade",
    workflow_id,
    "#/$defs/typedStepInvariants",
    {"kind": "flashPartition", "effect": "readOnly", "cancellation": "criticalNonInterruptible", "bindingRequirement": "confirmedDevice"},
    False,
)
execution_record_owner = schema_by_id[workflow_id][1]
source_trigger_rule_index = next(
    index
    for index, rule in enumerate(execution_record_owner["$defs"]["executionRecord"]["allOf"])
    if rule.get("if", {}).get("properties", {}).get("sourceStepId", {}).get("type") == "null"
)
assert_schema_case(
    "main execution record cannot claim a compensation trigger",
    workflow_id,
    f"#/$defs/executionRecord/allOf/{source_trigger_rule_index}",
    {"sourceStepId": None, "compensationTrigger": "onFailure"},
    False,
)
assert_schema_case(
    "compensation execution record binds a trigger",
    workflow_id,
    f"#/$defs/executionRecord/allOf/{source_trigger_rule_index}",
    {"sourceStepId": "source-1", "compensationTrigger": "onFailure"},
    True,
)

manifest_owner = schema_by_id[manifest_id][1]
agent_authority_rule_index = next(
    index
    for index, rule in enumerate(manifest_owner["allOf"])
    if rule.get("if", {}).get("properties", {}).get("executionAuthority", {}).get("const") == "standardAgent"
)
assert_schema_case(
    "standard Agent destructive execution",
    manifest_id,
    f"#/allOf/{agent_authority_rule_index}",
    {
        "executionAuthority": "standardAgent",
        "steps": [{"effect": "destructive", "disposition": "executed", "outcomeCertainty": "confirmed", "semanticResult": "succeeded"}],
    },
    False,
)
assert_schema_case(
    "standard Agent destructive compensation execution",
    manifest_id,
    f"#/allOf/{agent_authority_rule_index}",
    {
        "executionAuthority": "standardAgent",
        "steps": [],
        "compensations": [{"descriptor": {"effect": "destructive"}, "disposition": "executed", "outcomeCertainty": "confirmed", "result": "succeeded"}],
    },
    False,
)
agent_destructive_success_rule_index = next(
    index
    for index, rule in enumerate(manifest_owner["allOf"])
    if isinstance(rule.get("if", {}).get("allOf"), list)
    and any(
        branch.get("properties", {}).get("executionAuthority", {}).get("const") == "standardAgent"
        and branch.get("properties", {}).get("executionMode", {}).get("const") == "execute"
        for branch in rule["if"]["allOf"]
    )
)
assert_schema_case(
    "standard Agent cannot report destructive execute as succeeded",
    manifest_id,
    f"#/allOf/{agent_destructive_success_rule_index}",
    {
        "executionAuthority": "standardAgent",
        "executionMode": "execute",
        "status": "succeeded",
        "steps": [{"effect": "destructive", "disposition": "skipped", "outcomeCertainty": "notApplicable", "semanticResult": "notRun"}],
    },
    False,
)
assert_schema_case(
    "standard Agent may report read-only execute as succeeded",
    manifest_id,
    f"#/allOf/{agent_destructive_success_rule_index}",
    {
        "executionAuthority": "standardAgent",
        "executionMode": "execute",
        "status": "succeeded",
        "steps": [{"effect": "readOnly", "disposition": "executed", "outcomeCertainty": "confirmed", "semanticResult": "succeeded"}],
    },
    True,
)
succeeded_rule_index = next(
    index
    for index, rule in enumerate(manifest_owner["allOf"])
    if rule.get("if", {}).get("properties", {}).get("status", {}).get("const") == "succeeded"
)
assert_schema_case(
    "succeeded manifest with succeeded step",
    manifest_id,
    f"#/allOf/{succeeded_rule_index}",
    {
        "status": "succeeded",
        "outcomeCertainty": "confirmed",
        "failure": None,
        "recovery": None,
        "steps": [{"semanticResult": "succeeded", "disposition": "executed", "outcomeCertainty": "confirmed"}],
        "compensations": [],
        "parameters": [],
    },
    True,
)
assert_schema_case(
    "succeeded manifest with failed step",
    manifest_id,
    f"#/allOf/{succeeded_rule_index}",
    {
        "status": "succeeded",
        "outcomeCertainty": "confirmed",
        "failure": None,
        "recovery": None,
        "steps": [{"semanticResult": "failed", "disposition": "executed", "outcomeCertainty": "confirmed"}],
        "compensations": [],
        "parameters": [],
    },
    False,
)
assert_schema_case(
    "legal state transition",
    journal_id,
    "#/$defs/stateTransitionPair",
    {"from": "running", "to": "waitingForRecovery"},
    True,
)
assert_schema_case(
    "terminal state transition",
    journal_id,
    "#/$defs/stateTransitionPair",
    {"from": "succeeded", "to": "running"},
    False,
)
assert_schema_case(
    "repository evidence path",
    task_run_id,
    "#/properties/evidence/items/allOf/0/then/properties/location",
    "repo:openspec/changes/evidence.txt",
    True,
)
assert_schema_case(
    "repository evidence traversal",
    task_run_id,
    "#/properties/evidence/items/allOf/0/then/properties/location",
    "repo:../outside/evidence.txt",
    False,
)
assert_schema_case(
    "detached approval without signature",
    approval_id,
    "#",
    {
        "schemaVersion": "1.0.0",
        "approvalId": "APR-SELF-TEST",
        "subjectType": "taskPacket",
        "subjectId": "TASK-SELF-TEST",
        "subjectRevision": 1,
        "subjectSha256": "0" * 64,
        "baseRevision": "deadbeef",
        "decision": "approved",
        "approver": {"kind": "human", "id": "self-test"},
        "approvedAt": "2026-07-12T00:00:00Z",
        "mechanism": "detachedSignature",
        "approvalRef": "self-test",
    },
    False,
)

assert_schema_case(
    "strict RFC3339 owner timestamp",
    claim_owner_id,
    "#/properties/claimedAt",
    "2026-07-12T12:34:56+08:00",
    True,
)
assert_schema_case(
    "date-only owner timestamp",
    claim_owner_id,
    "#/properties/claimedAt",
    "2026-07-12",
    False,
)

lab_target = {
    "deviceIdentity": "device-1",
    "bindingRevision": 1,
    "firmware": "build-1",
    "transport": "usb",
    "hdcExecutableSha256": "0" * 64,
    "hdcClientVersion": "1",
    "hdcServerVersion": "1",
    "hdcDaemonVersion": "1",
    "hdcServerEndpoint": "127.0.0.1:8710",
    "hdcServerGeneration": 1,
    "hostVolumeIdentity": "volume-1",
    "resourceUrns": {
        "hdcServer": "arkdeck-resource:hdc-server:" + "0" * 64,
        "deviceBinding": "arkdeck-resource:device-binding:" + "1" * 64,
        "hostVolume": "arkdeck-resource:host-volume:" + "2" * 64,
    },
    "providerId": "provider-1",
    "providerVersion": "1",
}
valid_lab_plan = {
    "schemaVersion": "1.0.0",
    "serialization": "arkdeck-plan-json-bytes-v1",
    "planId": "LABPLAN-SELF-TEST",
    "taskId": "TASK-SELF-TEST",
    "platform": "macos",
    "target": lab_target,
    "steps": [
        {
            "id": "step-1",
            "kind": "probeDevice",
            "effect": "readOnly",
            "cancellation": "immediate",
            "bindingRequirement": "confirmedDevice",
            "arguments": {"evidencePolicy": "policy-1"},
            "compensationDescriptors": [],
        }
    ],
}
assert_schema_case("typed read-only lab plan", lab_plan_id, "#", valid_lab_plan, True)
invalid_lab_plan = json.loads(json.dumps(valid_lab_plan))
invalid_lab_plan["steps"][0]["bindingRequirement"] = "none"
assert_schema_case("lab plan weakens device binding", lab_plan_id, "#", invalid_lab_plan, False)

if errors:
    print("\n".join(f"ERROR: {error}" for error in errors), file=sys.stderr)
    sys.exit(1)

print(f"JSON structural checks passed: {len(documents)} files, {len(schema_by_id)} schemas.")
