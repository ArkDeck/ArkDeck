#!/usr/bin/env python3
"""Offline closed-contract and adversarial-vector validator for TASK-AIN-009."""

from __future__ import annotations

import copy
import hashlib
import json
import re
from pathlib import Path
from typing import Any


RUN_ROOT = Path(__file__).resolve().parent
CHANGE_ROOT = RUN_ROOT.parents[2]
REPOSITORY_ROOT = CHANGE_ROOT.parents[2]
CONTRACT_ROOT = CHANGE_ROOT / "contracts"
CORE_CONTRACT_ROOT = REPOSITORY_ROOT / "openspec" / "contracts"

AGENT_SCHEMA_PATH = CONTRACT_ROOT / "agent-device-operation.schema.v1-draft.json"
HUMAN_SCHEMA_PATH = CONTRACT_ROOT / "human-action-required.schema.v1-draft.json"
REGISTRY_SCHEMA_PATH = CONTRACT_ROOT / "agent-device-operation-registry.schema.v1-draft.json"
REGISTRY_PATH = CONTRACT_ROOT / "agent-device-operation-registry.v1-draft.json"
VECTORS_PATH = RUN_ROOT / "vectors.json"

IDENTIFIER = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$")
CHANGE_ID = re.compile(r"^CHG-[0-9]{4}-[0-9]{3}$")
TASK_ID = re.compile(r"^TASK-[A-Z0-9]+(?:-[A-Z0-9]+)*-[0-9]{3}[A-Z]?$")
AUTHORIZATION_ID = re.compile(r"^AUTH-[A-Z0-9]+(?:-[A-Z0-9]+)*$")
SHA1 = re.compile(r"^[0-9a-f]{40}$")
SHA256 = re.compile(r"^[0-9a-f]{64}$")
DATE_TIME = re.compile(
    r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]+)?Z$"
)

FORBIDDEN_REQUEST_FIELDS = {
    "submittedby",
    "executor",
    "executable",
    "argv",
    "shell",
    "command",
    "remotepath",
    "sessionroot",
    "authorizationbytes",
    "authorizationpath",
    "authorizationref",
    "capability",
    "bindingrevision",
    "readback",
    "prerequisites",
    "usage",
    "effect",
    "resolvedeffect",
    "outcome",
    "success",
}


class ContractError(AssertionError):
    def __init__(self, code: str, detail: str = "") -> None:
        super().__init__(f"{code}: {detail}" if detail else code)
        self.code = code


def fail(code: str, detail: str = "") -> None:
    raise ContractError(code, detail)


def strict_load(path: Path) -> Any:
    def no_duplicates(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        result: dict[str, Any] = {}
        for key, value in pairs:
            if key in result:
                fail("DUPLICATE_MEMBER", key)
            result[key] = value
        return result

    return json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=no_duplicates)


def exact_keys(
    value: Any,
    *,
    required: set[str],
    allowed: set[str],
    code: str,
) -> dict[str, Any]:
    if not isinstance(value, dict):
        fail(code, "not an object")
    actual = set(value)
    if not required <= actual:
        fail(code, f"missing={sorted(required - actual)}")
    if not actual <= allowed:
        fail(code, f"unknown={sorted(actual - allowed)}")
    return value


def require_string(value: Any, pattern: re.Pattern[str], code: str, field: str) -> str:
    if not isinstance(value, str) or pattern.fullmatch(value) is None:
        fail(code, field)
    return value


def require_enum(value: Any, allowed: set[str], code: str, field: str) -> str:
    if not isinstance(value, str) or value not in allowed:
        fail(code, field)
    return value


def require_unique_strings(
    value: Any, allowed: set[str] | None, code: str, field: str, *, minimum: int = 0
) -> list[str]:
    if (
        not isinstance(value, list)
        or len(value) < minimum
        or any(not isinstance(item, str) for item in value)
        or len(set(value)) != len(value)
    ):
        fail(code, field)
    if allowed is not None and not set(value) <= allowed:
        fail(code, field)
    return value


def find_forbidden_request_field(value: Any) -> str | None:
    if isinstance(value, dict):
        for key, nested in value.items():
            if key.lower() in FORBIDDEN_REQUEST_FIELDS:
                return key
            found = find_forbidden_request_field(nested)
            if found is not None:
                return found
    elif isinstance(value, list):
        for nested in value:
            found = find_forbidden_request_field(nested)
            if found is not None:
                return found
    return None


def assert_closed_schema(schema: Any, path: str = "$") -> None:
    if isinstance(schema, dict):
        if schema.get("type") == "object" and schema.get("additionalProperties") is not False:
            fail("SCHEMA_OBJECT_NOT_CLOSED", path)
        for key, value in schema.items():
            assert_closed_schema(value, f"{path}.{key}")
    elif isinstance(schema, list):
        for index, value in enumerate(schema):
            assert_closed_schema(value, f"{path}[{index}]")


def parse_core_step_registry() -> dict[str, dict[str, str]]:
    registry_path = CORE_CONTRACT_ROOT / "workflow-step-registry.yaml"
    row = re.compile(
        r"^\s*-\s*\{\s*kind:\s*([A-Za-z0-9]+),\s*"
        r"minimum_effect:\s*([A-Za-z]+),\s*"
        r"cancellation:\s*([A-Za-z]+),\s*"
        r"binding:\s*([A-Za-z]+),.*\}\s*$"
    )
    result: dict[str, dict[str, str]] = {}
    for line in registry_path.read_text(encoding="utf-8").splitlines():
        match = row.match(line)
        if match is None:
            continue
        kind, effect, cancellation, binding = match.groups()
        if kind in result:
            fail("CORE_DUPLICATE_STEP", kind)
        result[kind] = {
            "effect": effect,
            "cancellation": cancellation,
            "binding": binding,
        }
    if len(result) != 41:
        fail("CORE_STEP_COUNT", str(len(result)))
    return result


def canonical_profile_digest(profile: dict[str, Any]) -> str:
    configuration = {
        "configurationId": profile["configurationId"],
        "declaredBindingRequirement": profile["declaredBindingRequirement"],
        "declaredCancellation": profile["declaredCancellation"],
        "declaredEffect": profile["declaredEffect"],
        "emittedStepKinds": profile["emittedStepKinds"],
    }
    canonical = json.dumps(
        configuration, ensure_ascii=True, separators=(",", ":"), sort_keys=True
    ).encode("utf-8")
    return hashlib.sha256(canonical).hexdigest()


def validate_registry(
    registry: Any,
    agent_schema: dict[str, Any],
    human_schema: dict[str, Any],
    core_steps: dict[str, dict[str, str]],
) -> dict[str, tuple[str, str]]:
    root = exact_keys(
        registry,
        required={
            "schemaVersion",
            "registryId",
            "workflowStepSchemaId",
            "unknownOperationDisposition",
            "unknownProfileDisposition",
            "unknownStepDisposition",
            "effectOrder",
            "cancellationOrder",
            "bindingOrder",
            "operations",
            "humanBlockerRules",
        },
        allowed={
            "schemaVersion",
            "registryId",
            "workflowStepSchemaId",
            "unknownOperationDisposition",
            "unknownProfileDisposition",
            "unknownStepDisposition",
            "effectOrder",
            "cancellationOrder",
            "bindingOrder",
            "operations",
            "humanBlockerRules",
        },
        code="REGISTRY_SHAPE",
    )
    fixed = {
        "schemaVersion": "1.0.0",
        "registryId": "arkdeck-agent-device-operations",
        "workflowStepSchemaId": "https://arkdeck.dev/schemas/workflow-step-1.0.0.json",
        "unknownOperationDisposition": "rejectAsDestructiveUnsupported",
        "unknownProfileDisposition": "rejectAsDestructiveUnsupported",
        "unknownStepDisposition": "rejectAsDestructiveUnsupported",
    }
    for key, expected in fixed.items():
        if root[key] != expected:
            fail("REGISTRY_IDENTITY", key)

    effect_order = ["hostOnly", "readOnly", "deviceMutation", "destructive"]
    cancellation_order = ["immediate", "atSafeBoundary", "criticalNonInterruptible"]
    binding_order = ["none", "confirmedDevice"]
    if root["effectOrder"] != effect_order:
        fail("REGISTRY_ORDER", "effectOrder")
    if root["cancellationOrder"] != cancellation_order:
        fail("REGISTRY_ORDER", "cancellationOrder")
    if root["bindingOrder"] != binding_order:
        fail("REGISTRY_ORDER", "bindingOrder")

    expected_operations = agent_schema["$defs"]["operationId"]["enum"]
    operations = root["operations"]
    if not isinstance(operations, list):
        fail("REGISTRY_OPERATION_CLOSURE")
    operation_ids = [operation.get("id") for operation in operations if isinstance(operation, dict)]
    if (
        len(operations) != len(expected_operations)
        or len(operation_ids) != len(operations)
        or len(set(operation_ids)) != len(operation_ids)
        or set(operation_ids) != set(expected_operations)
    ):
        fail("REGISTRY_OPERATION_CLOSURE")

    effect_rank = {value: index for index, value in enumerate(effect_order)}
    cancellation_rank = {value: index for index, value in enumerate(cancellation_order)}
    binding_rank = {value: index for index, value in enumerate(binding_order)}
    authority = {
        "readOnly": "readyTask",
        "deviceMutation": "deviceCapability",
        "destructive": "standingAuthorization",
    }
    profile_lookup: dict[str, tuple[str, str]] = {}
    operation_keys = {
        "id",
        "minimumEffect",
        "permittedEffects",
        "minimumCancellation",
        "bindingRequirement",
        "permittedStepKinds",
        "profilePolicy",
        "escalationPolicy",
        "authorityByEffect",
        "profiles",
    }
    profile_keys = {
        "id",
        "configurationId",
        "configurationSha256",
        "declaredEffect",
        "declaredCancellation",
        "declaredBindingRequirement",
        "emittedStepKinds",
    }
    for operation in operations:
        row = exact_keys(
            operation,
            required=operation_keys,
            allowed=operation_keys,
            code="REGISTRY_OPERATION_SHAPE",
        )
        operation_id = row["id"]
        minimum_effect = require_enum(
            row["minimumEffect"], set(effect_order), "REGISTRY_OPERATION_SHAPE", "minimumEffect"
        )
        permitted_effects = require_unique_strings(
            row["permittedEffects"],
            set(effect_order),
            "REGISTRY_OPERATION_SHAPE",
            "permittedEffects",
            minimum=1,
        )
        if minimum_effect not in permitted_effects:
            fail("REGISTRY_EFFECT_DOWNGRADE", operation_id)
        minimum_cancellation = require_enum(
            row["minimumCancellation"],
            set(cancellation_order),
            "REGISTRY_OPERATION_SHAPE",
            "minimumCancellation",
        )
        binding_requirement = require_enum(
            row["bindingRequirement"],
            set(binding_order),
            "REGISTRY_OPERATION_SHAPE",
            "bindingRequirement",
        )
        permitted_steps = require_unique_strings(
            row["permittedStepKinds"],
            set(core_steps),
            "REGISTRY_UNKNOWN_STEP",
            "permittedStepKinds",
            minimum=1,
        )
        if row["profilePolicy"] != "protectedMainExactDescriptor":
            fail("REGISTRY_PROFILE_POLICY", operation_id)
        if row["escalationPolicy"] not in {
            "noElevation",
            "profileMayElevateWithinPermittedEffects",
            "destructiveOnly",
        }:
            fail("REGISTRY_PROFILE_POLICY", operation_id)

        expected_authority = {effect: authority[effect] for effect in permitted_effects}
        if row["authorityByEffect"] != expected_authority:
            fail("REGISTRY_AUTHORITY_MAPPING", operation_id)

        profiles = row["profiles"]
        if not isinstance(profiles, list) or not profiles:
            fail("REGISTRY_PROFILE_SHAPE", operation_id)
        profile_ids = [
            profile.get("id") for profile in profiles if isinstance(profile, dict)
        ]
        if len(profile_ids) != len(profiles) or len(set(profile_ids)) != len(profile_ids):
            fail("REGISTRY_DUPLICATE_PROFILE", operation_id)
        for profile in profiles:
            descriptor = exact_keys(
                profile,
                required=profile_keys,
                allowed=profile_keys,
                code="REGISTRY_PROFILE_SHAPE",
            )
            profile_id = require_string(
                descriptor["id"], IDENTIFIER, "REGISTRY_PROFILE_SHAPE", "id"
            )
            configuration_id = require_string(
                descriptor["configurationId"],
                IDENTIFIER,
                "REGISTRY_PROFILE_SHAPE",
                "configurationId",
            )
            require_string(
                descriptor["configurationSha256"],
                SHA256,
                "REGISTRY_PROFILE_SHAPE",
                "configurationSha256",
            )
            declared_effect = require_enum(
                descriptor["declaredEffect"],
                set(effect_order),
                "REGISTRY_PROFILE_SHAPE",
                "declaredEffect",
            )
            declared_cancellation = require_enum(
                descriptor["declaredCancellation"],
                set(cancellation_order),
                "REGISTRY_PROFILE_SHAPE",
                "declaredCancellation",
            )
            declared_binding = require_enum(
                descriptor["declaredBindingRequirement"],
                set(binding_order),
                "REGISTRY_PROFILE_SHAPE",
                "declaredBindingRequirement",
            )
            emitted_steps = require_unique_strings(
                descriptor["emittedStepKinds"],
                None,
                "REGISTRY_PROFILE_SHAPE",
                "emittedStepKinds",
                minimum=1,
            )
            unknown_steps = set(emitted_steps) - set(core_steps)
            if unknown_steps:
                fail("REGISTRY_UNKNOWN_STEP", sorted(unknown_steps)[0])
            if not set(emitted_steps) <= set(permitted_steps):
                fail("REGISTRY_STEP_NOT_PERMITTED", profile_id)
            if effect_rank[declared_effect] < effect_rank[minimum_effect]:
                fail("REGISTRY_EFFECT_DOWNGRADE", profile_id)
            if declared_effect not in permitted_effects:
                fail("REGISTRY_ILLEGAL_ELEVATION", profile_id)
            if row["escalationPolicy"] == "noElevation" and declared_effect != minimum_effect:
                fail("REGISTRY_ILLEGAL_ELEVATION", profile_id)
            if (
                row["escalationPolicy"] == "destructiveOnly"
                and declared_effect != "destructive"
            ):
                fail("REGISTRY_EFFECT_DOWNGRADE", profile_id)

            required_effect_rank = max(
                [effect_rank[minimum_effect]]
                + [effect_rank[core_steps[kind]["effect"]] for kind in emitted_steps]
            )
            if effect_rank[declared_effect] < required_effect_rank:
                fail("REGISTRY_EFFECT_DOWNGRADE", profile_id)
            required_cancellation_rank = max(
                [cancellation_rank[minimum_cancellation]]
                + [
                    cancellation_rank[core_steps[kind]["cancellation"]]
                    for kind in emitted_steps
                ]
            )
            if cancellation_rank[declared_cancellation] < required_cancellation_rank:
                fail("REGISTRY_CANCELLATION_DOWNGRADE", profile_id)
            required_binding_rank = max(
                [binding_rank[binding_requirement]]
                + [binding_rank[core_steps[kind]["binding"]] for kind in emitted_steps]
            )
            if binding_rank[declared_binding] < required_binding_rank:
                fail("REGISTRY_BINDING_DOWNGRADE", profile_id)
            if canonical_profile_digest(descriptor) != descriptor["configurationSha256"]:
                fail("REGISTRY_CONFIGURATION_DIGEST", profile_id)
            if profile_id in profile_lookup:
                fail("REGISTRY_DUPLICATE_PROFILE", profile_id)
            profile_lookup[profile_id] = (
                operation_id,
                configuration_id,
                descriptor["configurationSha256"],
            )

    expected_categories = human_schema["$defs"]["category"]["enum"]
    blocker_rules = root["humanBlockerRules"]
    if not isinstance(blocker_rules, list):
        fail("REGISTRY_HUMAN_CLOSURE")
    blocker_categories = [
        rule.get("category") for rule in blocker_rules if isinstance(rule, dict)
    ]
    if (
        len(blocker_rules) != len(expected_categories)
        or len(blocker_categories) != len(blocker_rules)
        or len(set(blocker_categories)) != len(blocker_categories)
        or set(blocker_categories) != set(expected_categories)
    ):
        fail("REGISTRY_HUMAN_CLOSURE")
    allowed_prohibited = set(human_schema["$defs"]["prohibitedAutomation"]["enum"])
    allowed_probes = set(human_schema["$defs"]["resumeProbeOperationId"]["enum"])
    for rule in blocker_rules:
        item = exact_keys(
            rule,
            required={
                "category",
                "resumeProbeOperationId",
                "requiredProhibitedAutomation",
            },
            allowed={
                "category",
                "resumeProbeOperationId",
                "requiredProhibitedAutomation",
            },
            code="REGISTRY_HUMAN_SHAPE",
        )
        require_enum(
            item["resumeProbeOperationId"],
            allowed_probes,
            "REGISTRY_HUMAN_SHAPE",
            "resumeProbeOperationId",
        )
        require_unique_strings(
            item["requiredProhibitedAutomation"],
            allowed_prohibited,
            "REGISTRY_HUMAN_SHAPE",
            "requiredProhibitedAutomation",
            minimum=1,
        )
    return profile_lookup


def validate_request(
    value: Any,
    operation_ids: set[str],
    profile_lookup: dict[str, tuple[str, str]],
) -> None:
    forbidden = find_forbidden_request_field(value)
    if forbidden is not None:
        fail("REQUEST_FORBIDDEN_FIELD", forbidden)
    required = {
        "documentType",
        "schemaVersion",
        "requestId",
        "changeId",
        "taskId",
        "executionMode",
        "durableTargetId",
        "operation",
    }
    allowed = required | {"authorizationId", "requestedOutputs", "deadlineUtc"}
    request = exact_keys(value, required=required, allowed=allowed, code="REQUEST_SHAPE")
    if request["documentType"] != "request":
        fail("REQUEST_SHAPE", "documentType")
    if request["schemaVersion"] != "1.0.0":
        fail("UNKNOWN_SCHEMA_VERSION")
    require_string(request["requestId"], IDENTIFIER, "REQUEST_SHAPE", "requestId")
    require_string(request["changeId"], CHANGE_ID, "REQUEST_SHAPE", "changeId")
    require_string(request["taskId"], TASK_ID, "REQUEST_SHAPE", "taskId")
    require_enum(
        request["executionMode"],
        {"execute", "planOnly", "simulated"},
        "REQUEST_SHAPE",
        "executionMode",
    )
    require_string(
        request["durableTargetId"], IDENTIFIER, "REQUEST_SHAPE", "durableTargetId"
    )
    operation = exact_keys(
        request["operation"],
        required={"id", "profileId", "configurationId", "configurationSha256"},
        allowed={
            "id",
            "profileId",
            "configurationId",
            "configurationSha256",
            "artifactLeaseIds",
        },
        code="REQUEST_SHAPE",
    )
    operation_id = operation["id"]
    if operation_id not in operation_ids:
        fail("UNKNOWN_OPERATION", str(operation_id))
    profile_id = operation["profileId"]
    if profile_id not in profile_lookup or profile_lookup[profile_id][0] != operation_id:
        fail("UNKNOWN_PROFILE", str(profile_id))
    _, expected_configuration_id, expected_digest = profile_lookup[profile_id]
    if operation["configurationId"] != expected_configuration_id:
        fail("CONFIGURATION_ID_MISMATCH", str(profile_id))
    if operation["configurationSha256"] != expected_digest:
        fail("CONFIGURATION_DIGEST_MISMATCH", str(profile_id))
    if "artifactLeaseIds" in operation:
        leases = require_unique_strings(
            operation["artifactLeaseIds"], None, "REQUEST_SHAPE", "artifactLeaseIds"
        )
        for lease in leases:
            require_string(lease, IDENTIFIER, "REQUEST_SHAPE", "artifactLeaseIds")
    if "authorizationId" in request:
        require_string(
            request["authorizationId"],
            AUTHORIZATION_ID,
            "REQUEST_SHAPE",
            "authorizationId",
        )
    if "requestedOutputs" in request:
        require_unique_strings(
            request["requestedOutputs"],
            {"rawArtifacts", "derivedArtifacts", "analysisReport", "hardwareEvidence"},
            "REQUEST_SHAPE",
            "requestedOutputs",
        )
    if "deadlineUtc" in request:
        require_string(request["deadlineUtc"], DATE_TIME, "REQUEST_SHAPE", "deadlineUtc")


def validate_authorization_ref(value: Any) -> str:
    if not isinstance(value, dict):
        fail("RESULT_AUTHORIZATION_SHAPE")
    kind = value.get("kind")
    common = {"kind", "mainCommitOID", "approvalPRNumber"}
    if kind == "readyTask":
        required = common | {"changeId", "taskId", "taskBlobOID"}
        item = exact_keys(
            value,
            required=required,
            allowed=required,
            code="RESULT_AUTHORIZATION_SHAPE",
        )
        require_string(item["changeId"], CHANGE_ID, "RESULT_AUTHORIZATION_SHAPE", "changeId")
        require_string(item["taskId"], TASK_ID, "RESULT_AUTHORIZATION_SHAPE", "taskId")
        require_string(item["taskBlobOID"], SHA1, "RESULT_AUTHORIZATION_SHAPE", "taskBlobOID")
    elif kind == "deviceCapability":
        required = common | {"capabilityId", "capabilityBlobOID"}
        item = exact_keys(
            value,
            required=required,
            allowed=required,
            code="RESULT_AUTHORIZATION_SHAPE",
        )
        require_string(
            item["capabilityId"], IDENTIFIER, "RESULT_AUTHORIZATION_SHAPE", "capabilityId"
        )
        require_string(
            item["capabilityBlobOID"],
            SHA1,
            "RESULT_AUTHORIZATION_SHAPE",
            "capabilityBlobOID",
        )
    elif kind == "standingAuthorization":
        required = common | {"authorizationId", "authorizationBlobOID"}
        item = exact_keys(
            value,
            required=required,
            allowed=required,
            code="RESULT_AUTHORIZATION_SHAPE",
        )
        require_string(
            item["authorizationId"],
            AUTHORIZATION_ID,
            "RESULT_AUTHORIZATION_SHAPE",
            "authorizationId",
        )
        require_string(
            item["authorizationBlobOID"],
            SHA1,
            "RESULT_AUTHORIZATION_SHAPE",
            "authorizationBlobOID",
        )
    else:
        fail("RESULT_AUTHORIZATION_SHAPE", "kind")
    require_string(item["mainCommitOID"], SHA1, "RESULT_AUTHORIZATION_SHAPE", "mainCommitOID")
    if (
        not isinstance(item["approvalPRNumber"], int)
        or isinstance(item["approvalPRNumber"], bool)
        or item["approvalPRNumber"] < 1
    ):
        fail("RESULT_AUTHORIZATION_SHAPE", "approvalPRNumber")
    return kind


def validate_result(value: Any, terminal_states: set[str], job_states: set[str]) -> None:
    required = {
        "documentType",
        "schemaVersion",
        "requestId",
        "jobId",
        "executionMode",
        "jobState",
        "disposition",
        "resolvedEffect",
        "outcomeCertainty",
        "executor",
        "artifacts",
    }
    allowed = required | {
        "manifestId",
        "humanActionId",
        "blockerCode",
        "authorizationRef",
    }
    result = exact_keys(value, required=required, allowed=allowed, code="RESULT_SHAPE")
    if result["documentType"] != "result":
        fail("RESULT_SHAPE", "documentType")
    if result["schemaVersion"] != "1.0.0":
        fail("UNKNOWN_SCHEMA_VERSION")
    require_string(result["requestId"], IDENTIFIER, "RESULT_SHAPE", "requestId")
    require_string(result["jobId"], IDENTIFIER, "RESULT_SHAPE", "jobId")
    mode = require_enum(
        result["executionMode"],
        {"execute", "planOnly", "simulated"},
        "RESULT_SHAPE",
        "executionMode",
    )
    state = require_enum(result["jobState"], job_states, "RESULT_SHAPE", "jobState")
    disposition = require_enum(
        result["disposition"],
        {"active", "humanActionRequired", "policyBlocked", "terminal"},
        "RESULT_SHAPE",
        "disposition",
    )
    effect = require_enum(
        result["resolvedEffect"],
        {"hostOnly", "readOnly", "deviceMutation", "destructive"},
        "RESULT_SHAPE",
        "resolvedEffect",
    )
    certainty = require_enum(
        result["outcomeCertainty"],
        {"confirmed", "unknown", "notApplicable"},
        "RESULT_SHAPE",
        "outcomeCertainty",
    )
    executor = exact_keys(
        result["executor"],
        required={"kind", "id"},
        allowed={"kind", "id"},
        code="RESULT_SHAPE",
    )
    if executor["kind"] != "agent":
        fail("RESULT_SHAPE", "executor.kind")
    require_string(executor["id"], IDENTIFIER, "RESULT_SHAPE", "executor.id")

    has_authority = "authorizationRef" in result
    if disposition == "policyBlocked" and has_authority:
        fail("RESULT_POLICY_BLOCKED_AUTHORITY")
    if mode != "execute" and has_authority:
        fail("RESULT_NON_EXECUTE_AUTHORITY")
    if has_authority:
        authority_kind = validate_authorization_ref(result["authorizationRef"])
        required_effect = {
            "readyTask": "readOnly",
            "deviceCapability": "deviceMutation",
            "standingAuthorization": "destructive",
        }[authority_kind]
        if effect != required_effect:
            fail("RESULT_AUTHORITY_EFFECT_MISMATCH")

    if disposition == "terminal":
        if state not in terminal_states:
            fail("RESULT_DISPOSITION_STATE_MISMATCH")
    elif state in terminal_states:
        fail("RESULT_DISPOSITION_STATE_MISMATCH")
    if disposition == "humanActionRequired":
        if "humanActionId" not in result or "blockerCode" not in result:
            fail("RESULT_HUMAN_REFERENCE")
    elif "humanActionId" in result or "blockerCode" in result:
        fail("RESULT_HUMAN_REFERENCE")
    if disposition in {"active", "policyBlocked", "humanActionRequired"}:
        if certainty != "notApplicable":
            fail("RESULT_CERTAINTY_MISMATCH")
    elif state == "planned":
        if certainty != "notApplicable":
            fail("RESULT_CERTAINTY_MISMATCH")
    elif state in {"succeeded", "failed", "cancelled"} and certainty != "confirmed":
        fail("RESULT_CERTAINTY_MISMATCH")

    artifacts = result["artifacts"]
    if not isinstance(artifacts, list) or len(artifacts) > 1024:
        fail("RESULT_SHAPE", "artifacts")
    for artifact in artifacts:
        item = exact_keys(
            artifact,
            required={"artifactId", "sha256", "sizeBytes"},
            allowed={"artifactId", "sha256", "sizeBytes"},
            code="RESULT_SHAPE",
        )
        require_string(item["artifactId"], IDENTIFIER, "RESULT_SHAPE", "artifactId")
        require_string(item["sha256"], SHA256, "RESULT_SHAPE", "sha256")
        if (
            not isinstance(item["sizeBytes"], int)
            or isinstance(item["sizeBytes"], bool)
            or item["sizeBytes"] < 0
        ):
            fail("RESULT_SHAPE", "sizeBytes")


def blocker_rule_map(registry: dict[str, Any]) -> dict[str, dict[str, Any]]:
    return {rule["category"]: rule for rule in registry["humanBlockerRules"]}


def validate_human_action(
    value: Any,
    human_schema: dict[str, Any],
    blocker_rules: dict[str, dict[str, Any]],
) -> None:
    required = {
        "documentType",
        "schemaVersion",
        "actionId",
        "jobId",
        "category",
        "reasonCode",
        "minimumActionKey",
        "prohibitedAutomation",
        "resumeProbeOperationId",
        "generatedAtUtc",
        "status",
    }
    allowed = required | {"stepId", "expiresAtUtc", "resolution"}
    action = exact_keys(value, required=required, allowed=allowed, code="HUMAN_SHAPE")
    if action["documentType"] != "humanActionRequired":
        fail("HUMAN_SHAPE", "documentType")
    if action["schemaVersion"] != "1.0.0":
        fail("UNKNOWN_SCHEMA_VERSION")
    for field in ["actionId", "jobId", "reasonCode"]:
        require_string(action[field], IDENTIFIER, "HUMAN_SHAPE", field)
    if "stepId" in action:
        require_string(action["stepId"], IDENTIFIER, "HUMAN_SHAPE", "stepId")
    try:
        require_string(
            action["minimumActionKey"], IDENTIFIER, "HUMAN_SHAPE", "minimumActionKey"
        )
    except ContractError:
        fail("HUMAN_MINIMUM_ACTION_KEY_INVALID")
    category = action["category"]
    if category not in set(human_schema["$defs"]["category"]["enum"]):
        fail("HUMAN_UNKNOWN_CATEGORY")
    prohibited = require_unique_strings(
        action["prohibitedAutomation"],
        None,
        "HUMAN_SHAPE",
        "prohibitedAutomation",
        minimum=1,
    )
    allowed_prohibited = set(human_schema["$defs"]["prohibitedAutomation"]["enum"])
    if not set(prohibited) <= allowed_prohibited:
        fail("HUMAN_UNKNOWN_PROHIBITED_AUTOMATION")
    rule = blocker_rules[category]
    if not set(rule["requiredProhibitedAutomation"]) <= set(prohibited):
        fail("HUMAN_REQUIRED_PROHIBITION_MISSING")
    if action["resumeProbeOperationId"] != rule["resumeProbeOperationId"]:
        fail("HUMAN_RESUME_PROBE_MISMATCH")
    require_string(
        action["generatedAtUtc"], DATE_TIME, "HUMAN_SHAPE", "generatedAtUtc"
    )
    if "expiresAtUtc" in action:
        require_string(
            action["expiresAtUtc"], DATE_TIME, "HUMAN_SHAPE", "expiresAtUtc"
        )
    status = require_enum(
        action["status"],
        {"waiting", "resolvedByFreshProbe", "expired"},
        "HUMAN_SHAPE",
        "status",
    )
    if status == "resolvedByFreshProbe":
        if "resolution" not in action:
            fail("HUMAN_FRESH_PROBE_REQUIRED")
        resolution = exact_keys(
            action["resolution"],
            required={"probeOperationId", "probeReceiptId", "observedAtUtc"},
            allowed={"probeOperationId", "probeReceiptId", "observedAtUtc"},
            code="HUMAN_SHAPE",
        )
        if resolution["probeOperationId"] != action["resumeProbeOperationId"]:
            fail("HUMAN_FRESH_PROBE_MISMATCH")
        require_string(
            resolution["probeReceiptId"], IDENTIFIER, "HUMAN_SHAPE", "probeReceiptId"
        )
        require_string(
            resolution["observedAtUtc"], DATE_TIME, "HUMAN_SHAPE", "observedAtUtc"
        )
    elif "resolution" in action:
        fail("HUMAN_FRESH_PROBE_STATUS")


def validate_human_cross_reference(
    result: dict[str, Any], human_actions: list[dict[str, Any]]
) -> None:
    if result.get("disposition") != "humanActionRequired":
        return
    actions = {
        action["actionId"]: action
        for action in human_actions
        if action.get("actionId") == result.get("humanActionId")
    }
    if len(actions) != 1:
        fail("HUMAN_CROSS_REFERENCE_MISMATCH")
    action = next(iter(actions.values()))
    if (
        action["jobId"] != result["jobId"]
        or action["reasonCode"] != result["blockerCode"]
    ):
        fail("HUMAN_CROSS_REFERENCE_MISMATCH")


def path_get(root: Any, path: list[str]) -> Any:
    current = root
    for component in path:
        if isinstance(current, list):
            current = current[int(component)]
        else:
            current = current[component]
    return current


def path_set(root: Any, path: list[str], value: Any) -> None:
    parent = path_get(root, path[:-1]) if len(path) > 1 else root
    component = path[-1]
    if isinstance(parent, list):
        parent[int(component)] = value
    else:
        parent[component] = value


def path_remove(root: Any, path: list[str]) -> None:
    parent = path_get(root, path[:-1]) if len(path) > 1 else root
    component = path[-1]
    if isinstance(parent, list):
        del parent[int(component)]
    else:
        del parent[component]


def mutation_base(
    base: str,
    vectors: dict[str, Any],
    registry: dict[str, Any],
) -> Any:
    if base == "registry":
        return copy.deepcopy(registry)
    kind, identifier = base.split(":", maxsplit=1)
    if kind == "request":
        return copy.deepcopy(vectors["requests"][identifier])
    if kind == "result":
        return copy.deepcopy(vectors["results"][identifier])
    if kind == "human":
        for action in vectors["humanActions"]:
            if action["category"] == identifier:
                return copy.deepcopy(action)
    fail("VECTOR_BASE", base)


def apply_mutation(
    mutation: dict[str, Any],
    vectors: dict[str, Any],
    registry: dict[str, Any],
) -> Any:
    candidate = mutation_base(mutation["base"], vectors, registry)
    operation = mutation["operation"]
    if operation == "set":
        path_set(candidate, mutation["path"], copy.deepcopy(mutation["value"]))
    elif operation == "remove":
        path_remove(candidate, mutation["path"])
    elif operation == "appendCopy":
        target = path_get(candidate, mutation["path"])
        if not isinstance(target, list):
            fail("VECTOR_MUTATION", mutation["id"])
        target.append(copy.deepcopy(path_get(candidate, mutation["copyFrom"])))
    else:
        fail("VECTOR_MUTATION", mutation["id"])
    return candidate


def main() -> None:
    agent_schema = strict_load(AGENT_SCHEMA_PATH)
    human_schema = strict_load(HUMAN_SCHEMA_PATH)
    registry_schema = strict_load(REGISTRY_SCHEMA_PATH)
    registry = strict_load(REGISTRY_PATH)
    vectors = strict_load(VECTORS_PATH)
    core_step_schema = strict_load(CORE_CONTRACT_ROOT / "workflow-step.schema.json")

    expected_ids = {
        agent_schema["$id"]: "https://arkdeck.dev/schemas/agent-device-operation-1.0.0.json",
        human_schema["$id"]: "https://arkdeck.dev/schemas/human-action-required-1.0.0.json",
        registry_schema[
            "$id"
        ]: "https://arkdeck.dev/schemas/agent-device-operation-registry-1.0.0.json",
    }
    if any(actual != expected for actual, expected in expected_ids.items()):
        fail("SCHEMA_IDENTITY")
    for schema in [agent_schema, human_schema, registry_schema]:
        if schema.get("$schema") != "https://json-schema.org/draft/2020-12/schema":
            fail("SCHEMA_DIALECT")
        assert_closed_schema(schema)
    if registry["workflowStepSchemaId"] != core_step_schema["$id"]:
        fail("CORE_SCHEMA_IDENTITY")

    core_steps = parse_core_step_registry()
    profile_lookup = validate_registry(registry, agent_schema, human_schema, core_steps)
    operation_ids = set(agent_schema["$defs"]["operationId"]["enum"])
    job_states = set(agent_schema["$defs"]["jobState"]["enum"])
    terminal_states = set(agent_schema["$defs"]["terminalJobState"]["enum"])
    if job_states - terminal_states != set(
        agent_schema["$defs"]["nonTerminalJobState"]["enum"]
    ):
        fail("RESULT_STATE_PARTITION")

    for request in vectors["requests"].values():
        validate_request(request, operation_ids, profile_lookup)
    for result in vectors["results"].values():
        validate_result(result, terminal_states, job_states)
    rules = blocker_rule_map(registry)
    for action in vectors["humanActions"]:
        validate_human_action(action, human_schema, rules)
    validate_human_cross_reference(
        vectors["results"]["human"], vectors["humanActions"]
    )

    exact_forbidden_vectors = {
        mutation["path"][0].lower()
        for mutation in vectors["negativeMutations"]
        if mutation["id"].startswith("request-forbidden-")
        and len(mutation["path"]) == 1
    }
    if exact_forbidden_vectors != FORBIDDEN_REQUEST_FIELDS:
        fail(
            "VECTOR_FORBIDDEN_COVERAGE",
            f"missing={sorted(FORBIDDEN_REQUEST_FIELDS - exact_forbidden_vectors)}",
        )

    negative_count = 0
    for mutation in vectors["negativeMutations"]:
        candidate = apply_mutation(mutation, vectors, registry)
        try:
            if mutation["base"].startswith("request:"):
                validate_request(candidate, operation_ids, profile_lookup)
            elif mutation["base"].startswith("result:"):
                validate_result(candidate, terminal_states, job_states)
                validate_human_cross_reference(candidate, vectors["humanActions"])
            elif mutation["base"].startswith("human:"):
                validate_human_action(candidate, human_schema, rules)
            elif mutation["base"] == "registry":
                validate_registry(candidate, agent_schema, human_schema, core_steps)
            else:
                fail("VECTOR_BASE", mutation["base"])
        except ContractError as error:
            if error.code != mutation["reasonCode"]:
                fail(
                    "VECTOR_REASON_CODE",
                    f"{mutation['id']}: expected={mutation['reasonCode']} actual={error.code}",
                )
            negative_count += 1
        else:
            fail("VECTOR_FALSE_ACCEPT", mutation["id"])

    duplicate_count = 0
    for path in [RUN_ROOT / "duplicate-request.json", RUN_ROOT / "duplicate-request-escaped.json"]:
        try:
            strict_load(path)
        except ContractError as error:
            if error.code != "DUPLICATE_MEMBER":
                raise
            duplicate_count += 1
        else:
            fail("VECTOR_FALSE_ACCEPT", path.name)

    print(
        "TEST-AIN-OP-CONTRACT-001 PASS "
        f"requests={len(vectors['requests'])} results={len(vectors['results'])} "
        f"operations={len(registry['operations'])} profiles={len(profile_lookup)} "
        f"human_blockers={len(vectors['humanActions'])} negatives={negative_count} "
        f"duplicates={duplicate_count} core_steps={len(core_steps)} "
        "process_dispatch=0 device_dispatch=0 hdc_dispatch=0 network=0"
    )


if __name__ == "__main__":
    main()
