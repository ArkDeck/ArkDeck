"""ArkDeck Operation Catalog validator and generator (CHG-2026-046, T04).

Single source of truth: ``Catalog/operations/*.json`` + ``Catalog/profiles/*.json``.
This module (a) validates every catalog document against a closed, hand-rolled
rule set (stdlib only; the JSON Schema file is the human/machine contract and
its vocabulary is held in lockstep by test_generate.py), (b) deterministically
generates the Swift constant table and the effect/authorization matrix, and
(c) offers a zero-write drift check used by scripts/check_sdd.py.

Deliberately impossible to express here: a generic shell step. There is no
executable/argv/shell/command field in the vocabulary, forbidden field names
are rejected at validation time, and every step kind must be registered in
openspec/contracts/workflow-step-registry.yaml at or above the registry's
minimum effect/cancellation/binding.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path

import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
CATALOG_DIR = REPO_ROOT / "Catalog"
OPERATIONS_DIR = CATALOG_DIR / "operations"
PROFILES_DIR = CATALOG_DIR / "profiles"
STEP_REGISTRY_PATH = REPO_ROOT / "openspec" / "contracts" / "workflow-step-registry.yaml"
DUMP_RECIPES_PATH = REPO_ROOT / "openspec" / "contracts" / "catalogs" / "dump-recipes.yaml"
DIAGNOSTICS_STDOUT_PATH = (
    REPO_ROOT / "openspec" / "contracts" / "catalogs" / "diagnostics-stdout.yaml"
)
REMOTE_OPERATIONS_PATH = (
    REPO_ROOT / "openspec" / "contracts" / "catalogs" / "remote-operations.yaml"
)
GENERATED_SWIFT_PATH = (
    REPO_ROOT
    / "Packages"
    / "ArkDeckKit"
    / "Sources"
    / "ArkDeckCore"
    / "RuntimeOperationCatalogGenerated.swift"
)
GENERATED_MATRIX_PATH = CATALOG_DIR / "generated" / "effect-authorization-matrix.md"

EFFECTS = ("hostOnly", "readOnly", "deviceMutation", "destructive")
CANCELLATIONS = ("immediate", "atSafeBoundary", "criticalNonInterruptible")
BINDINGS = ("none", "confirmedDevice")
AUTHORIZATION_POLICIES = ("defaultReadOnly", "standingCapability", "runtimeCapability")
PROVIDERS = ("hdc", "rockchip", "workspace", "analyzer")
CONCURRENCY_KEYS = ("device-exclusive", "device-shared-readonly", "host-exclusive")
COMPENSATIONS = ("none", "bestEffortCleanup", "rollbackPublished")
ACTION_REFERENCE_REQUIRED_OPERATIONS = frozenset(
    {"observe.device", "capture.diagnostics", "debug.hap"}
)
FIELD_TYPES = (
    "string",
    "integer",
    "boolean",
    "stringArray",
    "artifactLease",
    # An ordered list of artifact leases. Introduced for multi-package HAP
    # install (CHG-2026-049 r4): one operation input naming several packages
    # that must land in one directory and install as one application.
    "artifactLeaseArray",
    "artifactReference",
)
ARTIFACT_ROLES = ("raw", "derived", "log", "plan", "diagnostic")
ARTIFACT_PRIVACY = ("standard", "sensitive")
RETENTION_CLASSES = ("default", "pinnedUntilVerified", "shortLived")
# A field name that could smuggle an executable surface is rejected outright.
FORBIDDEN_FIELD_NAMES = frozenset(
    {"argv", "shell", "exec", "command", "runHDC", "rawCommand", "executable"}
)

TOP_LEVEL_REQUIRED = (
    "schemaVersion",
    "id",
    "title",
    "provider",
    "effect",
    "authorization",
    "binding",
    "concurrencyKey",
    "inputs",
    "outputs",
    "steps",
    "timeoutSeconds",
    "outputByteBudget",
    "retry",
    "unknownOutcome",
    "artifacts",
    "profiles",
)
TOP_LEVEL_OPTIONAL = ("version", "defaultPolicyIssuance", "completeOverwriteRecovery")
STEP_REQUIRED = ("stepID", "kind", "effect", "cancellation", "binding", "compensation")
STEP_OPTIONAL = ("actionRef", "optional", "notes")
FIELD_REQUIRED = ("type", "required")
FIELD_OPTIONAL = (
    "description",
    "enum",
    "pattern",
    "minimum",
    "maximum",
    "maxLength",
    "maxItems",
    "default",
)
ARTIFACT_REQUIRED = ("name", "role", "mediaType", "privacy", "required")
ARTIFACT_OPTIONAL = ("retentionClass",)


class CatalogError(Exception):
    """A catalog document violates the closed contract."""


def _rank(value: str, order: tuple[str, ...]) -> int:
    return order.index(value)


def load_step_registry(path: Path = STEP_REGISTRY_PATH) -> dict[str, dict[str, str]]:
    data = yaml.safe_load(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict) or not isinstance(data.get("steps"), list):
        raise CatalogError(f"{path}: unexpected step registry shape")
    registry: dict[str, dict[str, str]] = {}
    for row in data["steps"]:
        registry[row["kind"]] = {
            "minimum_effect": row["minimum_effect"],
            "cancellation": row["cancellation"],
            "binding": row["binding"],
        }
    if not registry:
        raise CatalogError(f"{path}: empty step registry")
    return registry


def load_stdout_action_registry(
    dump_recipes_path: Path = DUMP_RECIPES_PATH,
    diagnostics_path: Path = DIAGNOSTICS_STDOUT_PATH,
) -> dict[str, frozenset[str]]:
    dump = yaml.safe_load(dump_recipes_path.read_text(encoding="utf-8"))
    if not isinstance(dump, dict) or dump.get("catalog") != "arkui-ui-dump":
        raise CatalogError(f"{dump_recipes_path}: unexpected stdout recipe catalog")
    dump_rows = dump.get("recipes", []) + dump.get("legacy_fallbacks", [])
    if not dump_rows or not all(isinstance(row, dict) and isinstance(row.get("id"), str) for row in dump_rows):
        raise CatalogError(f"{dump_recipes_path}: malformed stdout recipes")

    diagnostics = yaml.safe_load(diagnostics_path.read_text(encoding="utf-8"))
    if not isinstance(diagnostics, dict) or set(diagnostics) != {
        "schema_version", "catalog", "actions", "rules", "behavior_specs"
    }:
        raise CatalogError(f"{diagnostics_path}: unexpected diagnostics stdout catalog shape")
    if diagnostics["schema_version"] != "1.0.0" or diagnostics["catalog"] != "arkdeck-diagnostics":
        raise CatalogError(f"{diagnostics_path}: unsupported diagnostics stdout catalog")
    actions = diagnostics["actions"]
    if not isinstance(actions, list) or not actions:
        raise CatalogError(f"{diagnostics_path}: actions must be a non-empty list")
    action_ids: list[str] = []
    for index, action in enumerate(actions):
        where = f"{diagnostics_path}.actions[{index}]"
        if not isinstance(action, dict) or set(action) != {
            "id", "step_kind", "output_mode", "required_inputs", "limits"
        }:
            raise CatalogError(f"{where}: malformed diagnostics stdout action")
        if action["step_kind"] != "captureRemoteStdout" or action["output_mode"] != "stdout":
            raise CatalogError(f"{where}: action must be captureRemoteStdout/stdout")
        action_id = action["id"]
        if not isinstance(action_id, str) or not action_id:
            raise CatalogError(f"{where}.id: must be a non-empty string")
        if not isinstance(action["required_inputs"], list) or not isinstance(action["limits"], dict):
            raise CatalogError(f"{where}: malformed parameter contract")
        if set(action["required_inputs"]) != set(action["limits"]):
            raise CatalogError(f"{where}: required_inputs and limits must match exactly")
        action_ids.append(action_id)
    if len(action_ids) != len(set(action_ids)):
        raise CatalogError(f"{diagnostics_path}: duplicate action ids")

    return {
        "arkui-ui-dump": frozenset(row["id"] for row in dump_rows),
        "arkdeck-diagnostics": frozenset(action_ids),
    }


def load_remote_action_registry(
    path: Path = REMOTE_OPERATIONS_PATH,
) -> dict[str, str]:
    data = yaml.safe_load(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict) or set(data) != {
        "schema_version", "catalog", "version", "rules", "operations", "behavior_spec"
    }:
        raise CatalogError(f"{path}: unexpected remote-operation catalog shape")
    if data["schema_version"] != "1.0.0" or data["catalog"] != "arkdeck-remote-operations":
        raise CatalogError(f"{path}: unsupported remote-operation catalog")
    operations = data["operations"]
    if not isinstance(operations, list) or not operations:
        raise CatalogError(f"{path}: operations must be a non-empty list")
    registry: dict[str, str] = {}
    required = ("id", "step_kind", "minimum_effect", "cancellation", "binding")
    optional = ("confirmation",)
    for index, action in enumerate(operations):
        where = f"{path}.operations[{index}]"
        if not isinstance(action, dict):
            raise CatalogError(f"{where}: action must be an object")
        _require_keys(action, required, optional, where)
        action_id = action["id"]
        step_kind = action["step_kind"]
        if not isinstance(action_id, str) or not action_id:
            raise CatalogError(f"{where}.id: must be a non-empty string")
        if not isinstance(step_kind, str) or not step_kind:
            raise CatalogError(f"{where}.step_kind: must be a non-empty string")
        if action_id in registry:
            raise CatalogError(f"{path}: duplicate remote action id {action_id}")
        registry[action_id] = step_kind
    return registry


def _require_keys(doc: dict, required, optional, where: str) -> None:
    keys = set(doc)
    missing = [key for key in required if key not in keys]
    unknown = sorted(keys - set(required) - set(optional))
    if missing:
        raise CatalogError(f"{where}: missing keys {missing}")
    if unknown:
        raise CatalogError(f"{where}: unknown keys {unknown}")


def _require_enum(value, allowed, where: str) -> None:
    if value not in allowed:
        raise CatalogError(f"{where}: {value!r} not in {sorted(allowed)}")


def _require_int(value, where: str, minimum: int, maximum: int) -> None:
    if isinstance(value, bool) or not isinstance(value, int):
        raise CatalogError(f"{where}: must be an integer, got {type(value).__name__}")
    if not (minimum <= value <= maximum):
        raise CatalogError(f"{where}: {value} outside [{minimum}, {maximum}]")


def _validate_field_table(table, where: str) -> None:
    if not isinstance(table, dict) or set(table) != {"fields"}:
        raise CatalogError(f"{where}: must be an object with exactly a 'fields' key")
    fields = table["fields"]
    if not isinstance(fields, dict) or len(fields) > 24:
        raise CatalogError(f"{where}: fields must be an object with at most 24 entries")
    for name, spec in fields.items():
        field_where = f"{where}.fields.{name}"
        if name in FORBIDDEN_FIELD_NAMES:
            raise CatalogError(f"{field_where}: forbidden field name")
        if not name or not name[0].islower() or not name.isascii() or not name.isalnum():
            raise CatalogError(f"{field_where}: field names must be lowerCamelCase ASCII")
        if not isinstance(spec, dict):
            raise CatalogError(f"{field_where}: must be an object")
        _require_keys(spec, FIELD_REQUIRED, FIELD_OPTIONAL, field_where)
        _require_enum(spec["type"], FIELD_TYPES, f"{field_where}.type")
        if not isinstance(spec["required"], bool):
            raise CatalogError(f"{field_where}.required: must be a boolean")
        if "enum" in spec:
            values = spec["enum"]
            if (
                not isinstance(values, list)
                or not values
                or len(values) > 16
                or len(set(values)) != len(values)
                or not all(isinstance(v, str) and len(v) <= 64 for v in values)
            ):
                raise CatalogError(f"{field_where}.enum: malformed enum list")


def _validate_step(
    step,
    registry: dict[str, dict[str, str]],
    stdout_actions: dict[str, frozenset[str]],
    remote_actions: dict[str, str],
    where: str,
) -> None:
    if not isinstance(step, dict):
        raise CatalogError(f"{where}: step must be an object")
    _require_keys(step, STEP_REQUIRED, STEP_OPTIONAL, where)
    kind = step["kind"]
    if kind not in registry:
        raise CatalogError(f"{where}: unknown step kind {kind!r} (not in workflow-step-registry)")
    _require_enum(step["effect"], EFFECTS, f"{where}.effect")
    _require_enum(step["cancellation"], CANCELLATIONS, f"{where}.cancellation")
    _require_enum(step["binding"], BINDINGS, f"{where}.binding")
    _require_enum(step["compensation"], COMPENSATIONS, f"{where}.compensation")
    minimums = registry[kind]
    if _rank(step["effect"], EFFECTS) < _rank(minimums["minimum_effect"], EFFECTS):
        raise CatalogError(
            f"{where}: effect {step['effect']} below registry minimum "
            f"{minimums['minimum_effect']} for kind {kind}"
        )
    if _rank(step["cancellation"], CANCELLATIONS) < _rank(minimums["cancellation"], CANCELLATIONS):
        raise CatalogError(
            f"{where}: cancellation {step['cancellation']} below registry minimum "
            f"{minimums['cancellation']} for kind {kind}"
        )
    if _rank(step["binding"], BINDINGS) < _rank(minimums["binding"], BINDINGS):
        raise CatalogError(
            f"{where}: binding {step['binding']} below registry minimum "
            f"{minimums['binding']} for kind {kind}"
        )
    if "optional" in step and not isinstance(step["optional"], bool):
        raise CatalogError(f"{where}.optional: must be a boolean")
    action_ref = step.get("actionRef")
    if kind == "captureRemoteStdout":
        if not isinstance(action_ref, dict):
            raise CatalogError(f"{where}: captureRemoteStdout requires actionRef")
        _require_keys(action_ref, ("catalogId", "actionId"), (), f"{where}.actionRef")
        catalog_id = action_ref["catalogId"]
        action_id = action_ref["actionId"]
        if (
            not isinstance(catalog_id, str)
            or not isinstance(action_id, str)
            or action_id not in stdout_actions.get(catalog_id, frozenset())
        ):
            raise CatalogError(
                f"{where}.actionRef: unregistered stdout action {catalog_id!r}/{action_id!r}"
            )
    elif kind == "runApprovedRemoteRead" and action_ref is not None:
        if not isinstance(action_ref, dict):
            raise CatalogError(f"{where}.actionRef: must be an object")
        _require_keys(action_ref, ("catalogId", "actionId"), (), f"{where}.actionRef")
        catalog_id = action_ref["catalogId"]
        action_id = action_ref["actionId"]
        if catalog_id != "arkdeck-remote-operations":
            raise CatalogError(
                f"{where}.actionRef: runApprovedRemoteRead requires "
                "arkdeck-remote-operations")
        if not isinstance(action_id, str) or action_id not in remote_actions:
            raise CatalogError(
                f"{where}.actionRef: unregistered remote action {catalog_id!r}/{action_id!r}")
        if remote_actions[action_id] != kind:
            raise CatalogError(
                f"{where}.actionRef: remote action {action_id!r} is registered for "
                f"{remote_actions[action_id]!r}, not {kind!r}")
    elif "actionRef" in step:
        raise CatalogError(
            f"{where}.actionRef: only captureRemoteStdout or "
            "runApprovedRemoteRead may carry actionRef")


def validate_operation(
    doc,
    registry: dict[str, dict[str, str]],
    where: str,
    stdout_actions: dict[str, frozenset[str]] | None = None,
    remote_actions: dict[str, str] | None = None,
) -> None:
    if not isinstance(doc, dict):
        raise CatalogError(f"{where}: document must be an object")
    _require_keys(doc, TOP_LEVEL_REQUIRED, TOP_LEVEL_OPTIONAL, where)
    if doc["schemaVersion"] != "1.0.0":
        raise CatalogError(f"{where}: unsupported schemaVersion {doc['schemaVersion']!r}")
    _require_enum(doc["provider"], PROVIDERS, f"{where}.provider")
    _require_enum(doc["binding"], BINDINGS, f"{where}.binding")
    _require_enum(doc["concurrencyKey"], CONCURRENCY_KEYS, f"{where}.concurrencyKey")
    if "version" in doc:
        _require_int(doc["version"], f"{where}.version", 1, 10_000)
    _require_int(doc["timeoutSeconds"], f"{where}.timeoutSeconds", 1, 7200)
    _require_int(doc["outputByteBudget"], f"{where}.outputByteBudget", 1024, 1 << 30)

    effect = doc["effect"]
    if not isinstance(effect, dict) or set(effect) != {"minimum", "permitted"}:
        raise CatalogError(f"{where}.effect: must have exactly minimum and permitted")
    _require_enum(effect["minimum"], EFFECTS, f"{where}.effect.minimum")
    permitted = effect["permitted"]
    if (
        not isinstance(permitted, list)
        or not permitted
        or len(set(permitted)) != len(permitted)
    ):
        raise CatalogError(f"{where}.effect.permitted: must be a non-empty unique list")
    for value in permitted:
        _require_enum(value, EFFECTS, f"{where}.effect.permitted[]")
    if effect["minimum"] not in permitted:
        raise CatalogError(f"{where}.effect: minimum must be a member of permitted")

    authorization = doc["authorization"]
    if not isinstance(authorization, dict) or not authorization:
        raise CatalogError(f"{where}.authorization: must be a non-empty object")
    for auth_effect, policy in authorization.items():
        _require_enum(auth_effect, EFFECTS, f"{where}.authorization key")
        _require_enum(policy, AUTHORIZATION_POLICIES, f"{where}.authorization.{auth_effect}")
    if set(authorization) != set(permitted):
        raise CatalogError(
            f"{where}.authorization: keys must cover exactly the permitted "
            f"effects; got {sorted(authorization)} for permitted {sorted(permitted)}"
        )
    if "destructive" in authorization and authorization["destructive"] != "runtimeCapability":
        raise CatalogError(f"{where}: destructive effect requires runtimeCapability authorization")
    for auth_effect, policy in authorization.items():
        if policy == "defaultReadOnly" and _rank(auth_effect, EFFECTS) > _rank("readOnly", EFFECTS):
            raise CatalogError(
                f"{where}.authorization.{auth_effect}: defaultReadOnly may not gate a mutation"
            )

    if "defaultPolicyIssuance" in doc:
        _require_enum(
            doc["defaultPolicyIssuance"], ("enabled", "disabled"), f"{where}.defaultPolicyIssuance"
        )

    retry = doc["retry"]
    if not isinstance(retry, dict) or set(retry) != {"preflightAttempts", "mutationAttempts"}:
        raise CatalogError(f"{where}.retry: must have exactly preflightAttempts and mutationAttempts")
    _require_int(retry["preflightAttempts"], f"{where}.retry.preflightAttempts", 1, 3)
    if retry["mutationAttempts"] != 1:
        raise CatalogError(f"{where}.retry.mutationAttempts: pinned to 1 (no automatic mutation retry)")
    if doc["unknownOutcome"] != "reconcileRequired":
        raise CatalogError(f"{where}.unknownOutcome: pinned to reconcileRequired")

    _validate_field_table(doc["inputs"], f"{where}.inputs")
    _validate_field_table(doc["outputs"], f"{where}.outputs")

    if stdout_actions is None:
        stdout_actions = load_stdout_action_registry()
    if remote_actions is None:
        remote_actions = load_remote_action_registry()

    steps = doc["steps"]
    if not isinstance(steps, list) or not (1 <= len(steps) <= 32):
        raise CatalogError(f"{where}.steps: must be a list of 1..32 steps")
    step_ids = []
    step_effect_max = "hostOnly"
    for index, step in enumerate(steps):
        _validate_step(
            step, registry, stdout_actions, remote_actions, f"{where}.steps[{index}]")
        step_ids.append(step["stepID"])
        if _rank(step["effect"], EFFECTS) > _rank(step_effect_max, EFFECTS):
            step_effect_max = step["effect"]
    if doc["id"] in ACTION_REFERENCE_REQUIRED_OPERATIONS:
        missing_action_refs = [
            step["stepID"] for step in steps
            if step["kind"] == "runApprovedRemoteRead" and "actionRef" not in step
        ]
        if missing_action_refs:
            raise CatalogError(
                f"{where}.steps: evidence-eligible operation requires actionRef on "
                f"runApprovedRemoteRead steps {missing_action_refs}")
    if len(set(step_ids)) != len(step_ids):
        raise CatalogError(f"{where}.steps: duplicate stepIDs")
    if step_effect_max not in permitted:
        raise CatalogError(
            f"{where}: maximum step effect {step_effect_max} is not in permitted effects"
        )
    max_permitted = max(permitted, key=lambda value: _rank(value, EFFECTS))
    if _rank(step_effect_max, EFFECTS) < _rank(max_permitted, EFFECTS):
        raise CatalogError(
            f"{where}: permitted effect {max_permitted} is unreachable; "
            f"maximum step effect is {step_effect_max}"
        )
    required_step_effects = {
        step["effect"] for step in steps if not step.get("optional", False)
    }
    required_max = max(required_step_effects, key=lambda value: _rank(value, EFFECTS))
    if _rank(effect["minimum"], EFFECTS) != _rank(required_max, EFFECTS):
        raise CatalogError(
            f"{where}: effect.minimum {effect['minimum']} must equal the maximum "
            f"non-optional step effect {required_max}"
        )

    artifacts = doc["artifacts"]
    if not isinstance(artifacts, list) or len(artifacts) > 16:
        raise CatalogError(f"{where}.artifacts: must be a list of at most 16 entries")
    artifact_names = []
    for index, artifact in enumerate(artifacts):
        artifact_where = f"{where}.artifacts[{index}]"
        if not isinstance(artifact, dict):
            raise CatalogError(f"{artifact_where}: must be an object")
        _require_keys(artifact, ARTIFACT_REQUIRED, ARTIFACT_OPTIONAL, artifact_where)
        _require_enum(artifact["role"], ARTIFACT_ROLES, f"{artifact_where}.role")
        _require_enum(artifact["privacy"], ARTIFACT_PRIVACY, f"{artifact_where}.privacy")
        if "retentionClass" in artifact:
            _require_enum(
                artifact["retentionClass"], RETENTION_CLASSES, f"{artifact_where}.retentionClass"
            )
        if not isinstance(artifact["required"], bool):
            raise CatalogError(f"{artifact_where}.required: must be a boolean")
        artifact_names.append(artifact["name"])
    if len(set(artifact_names)) != len(artifact_names):
        raise CatalogError(f"{where}.artifacts: duplicate artifact names")

    profiles = doc["profiles"]
    if (
        not isinstance(profiles, list)
        or not profiles
        or len(set(profiles)) != len(profiles)
    ):
        raise CatalogError(f"{where}.profiles: must be a non-empty unique list")

    recovery = doc.get("completeOverwriteRecovery")
    if recovery is not None:
        recovery_required = (
            "contractVersion", "profiles",
            "overwriteStepID", "verificationStepIDs",
        )
        if not isinstance(recovery, dict):
            raise CatalogError(f"{where}.completeOverwriteRecovery: must be an object")
        _require_keys(recovery, recovery_required, (), f"{where}.completeOverwriteRecovery")
        if doc["effect"]["minimum"] != "destructive" or doc["provider"] != "rockchip":
            raise CatalogError(
                f"{where}.completeOverwriteRecovery: only a destructive rockchip operation may declare coverage"
            )
        if recovery["contractVersion"] != "1.0.0":
            raise CatalogError(
                f"{where}.completeOverwriteRecovery.contractVersion: unsupported version"
            )
        recovery_profiles = recovery["profiles"]
        if (
            not isinstance(recovery_profiles, list)
            or not recovery_profiles
            or not all(isinstance(item, dict) for item in recovery_profiles)
        ):
            raise CatalogError(
                f"{where}.completeOverwriteRecovery.profiles: must be a non-empty list of exact profile coverage objects"
            )
        recovery_references = []
        for index, item in enumerate(recovery_profiles):
            profile_where = f"{where}.completeOverwriteRecovery.profiles[{index}]"
            _require_keys(item, ("reference", "coveredEffects"), (), profile_where)
            reference = item["reference"]
            effects = item["coveredEffects"]
            if not isinstance(reference, str) or reference not in profiles:
                raise CatalogError(
                    f"{profile_where}.reference: must name one operation profile"
                )
            if (
                not isinstance(effects, list)
                or not effects
                or len(effects) > 32
                or len(set(effects)) != len(effects)
                or not all(
                    isinstance(effect, str)
                    and effect.startswith("partition:")
                    and effect.removeprefix("partition:").replace("_", "").isalnum()
                    for effect in effects
                )
            ):
                raise CatalogError(
                    f"{profile_where}.coveredEffects: must be 1..32 unique typed partition effects"
                )
            recovery_references.append(reference)
        if len(set(recovery_references)) != len(recovery_references):
            raise CatalogError(
                f"{where}.completeOverwriteRecovery.profiles: references must be unique"
            )
        overwrite_step = recovery["overwriteStepID"]
        verification_steps = recovery["verificationStepIDs"]
        if overwrite_step not in step_ids:
            raise CatalogError(
                f"{where}.completeOverwriteRecovery.overwriteStepID: unknown step"
            )
        if (
            not isinstance(verification_steps, list)
            or not verification_steps
            or len(set(verification_steps)) != len(verification_steps)
            or not set(verification_steps).issubset(set(step_ids))
            or overwrite_step in verification_steps
        ):
            raise CatalogError(
                f"{where}.completeOverwriteRecovery.verificationStepIDs: must be unique known post-write steps"
            )


def validate_profile(doc, where: str) -> None:
    required = ("schemaVersion", "id", "provider", "title", "constraints", "supportedOperations")
    if not isinstance(doc, dict):
        raise CatalogError(f"{where}: document must be an object")
    _require_keys(doc, required, ("version",), where)
    if doc["schemaVersion"] != "1.0.0":
        raise CatalogError(f"{where}: unsupported schemaVersion")
    _require_enum(doc["provider"], PROVIDERS, f"{where}.provider")
    if "version" in doc:
        _require_int(doc["version"], f"{where}.version", 1, 10_000)
    if not isinstance(doc["constraints"], dict):
        raise CatalogError(f"{where}.constraints: must be an object")
    ops = doc["supportedOperations"]
    if not isinstance(ops, list) or not ops or len(set(ops)) != len(ops):
        raise CatalogError(f"{where}.supportedOperations: must be a non-empty unique list")


def operation_reference(doc: dict) -> str:
    version = doc.get("version")
    return doc["id"] if version is None else f"{doc['id']}@{version}"


def operation_sort_key(doc: dict) -> tuple[str, int]:
    return doc["id"], doc.get("version", 0)


def profile_reference(doc: dict) -> str:
    """Return the public identity of a profile.

    Most profiles remain explicitly versioned. A profile with no meaningful
    parallel revisions may omit ``version`` and use its bare ID; this prevents
    a board identity such as DAYU200 from being confused with firmware builds.
    """
    version = doc.get("version")
    return doc["id"] if version is None else f"{doc['id']}@{version}"


def profile_sort_key(doc: dict) -> tuple[str, int]:
    return doc["id"], doc.get("version", 0)


def load_catalog(
    operations_dir: Path = OPERATIONS_DIR,
    profiles_dir: Path = PROFILES_DIR,
    registry_path: Path = STEP_REGISTRY_PATH,
) -> tuple[list[dict], list[dict]]:
    registry = load_step_registry(registry_path)
    stdout_actions = load_stdout_action_registry()
    remote_actions = load_remote_action_registry()
    operations = []
    for path in sorted(operations_dir.glob("*.json")):
        doc = json.loads(path.read_text(encoding="utf-8"))
        validate_operation(
            doc, registry, str(path.relative_to(REPO_ROOT)),
            stdout_actions=stdout_actions, remote_actions=remote_actions
        )
        expected_name = (
            f"{doc['id']}.json" if "version" not in doc
            else f"{doc['id']}.v{doc['version']}.json"
        )
        if path.name != expected_name:
            raise CatalogError(f"{path}: file name must be {expected_name}")
        operations.append(doc)
    if not operations:
        raise CatalogError(f"{operations_dir}: no operation documents")
    profiles = []
    for path in sorted(profiles_dir.glob("*.json")):
        doc = json.loads(path.read_text(encoding="utf-8"))
        validate_profile(doc, str(path.relative_to(REPO_ROOT)))
        expected_name = (
            f"{doc['id']}.json" if "version" not in doc
            else f"{doc['id']}.v{doc['version']}.json"
        )
        if path.name != expected_name:
            raise CatalogError(f"{path}: file name must be {expected_name}")
        profiles.append(doc)

    operation_refs = {operation_reference(doc) for doc in operations}
    profile_refs = {profile_reference(doc) for doc in profiles}
    for doc in operations:
        missing = set(doc["profiles"]) - profile_refs
        if missing:
            raise CatalogError(
                f"operation {operation_reference(doc)}: unknown profiles {sorted(missing)}"
            )
    for doc in profiles:
        missing = set(doc["supportedOperations"]) - operation_refs
        if missing:
            raise CatalogError(
                f"profile {profile_reference(doc)}: unknown operations {sorted(missing)}"
            )
    duplicate_ids = len(operation_refs) != len(operations)
    if duplicate_ids:
        raise CatalogError("duplicate operation reference")
    operations_by_id: dict[str, list[dict]] = {}
    for doc in operations:
        operations_by_id.setdefault(doc["id"], []).append(doc)
    for operation_id, variants in operations_by_id.items():
        if len(variants) > 1 and any("version" not in item for item in variants):
            raise CatalogError(
                f"operation {operation_id}: an unversioned operation cannot coexist with versioned variants"
            )
    if len(profile_refs) != len(profiles):
        raise CatalogError("duplicate profile reference")
    profiles_by_id: dict[str, list[dict]] = {}
    for doc in profiles:
        profiles_by_id.setdefault(doc["id"], []).append(doc)
    for profile_id, variants in profiles_by_id.items():
        if len(variants) > 1 and any("version" not in item for item in variants):
            raise CatalogError(
                f"profile {profile_id}: an unversioned profile cannot coexist with versioned variants"
            )
    # Both sides name each other, so both sides have to agree. Checking only
    # that each name resolves let the two drift apart while every reference
    # stayed valid: fourteen operations claimed a profile that did not list
    # them, and the generated authorisation matrix — the only published view of
    # what a profile supports — showed workspace-host@1 with seven operations
    # when seventeen claimed it.
    claimed: dict[str, set[str]] = {}
    for doc in operations:
        for profile_ref in doc["profiles"]:
            claimed.setdefault(profile_ref, set()).add(operation_reference(doc))
    for doc in profiles:
        profile_ref = profile_reference(doc)
        listed = set(doc["supportedOperations"])
        unlisted = claimed.get(profile_ref, set()) - listed
        if unlisted:
            raise CatalogError(
                f"profile {profile_ref}: operations {sorted(unlisted)} declare this profile "
                f"but it does not list them"
            )
        unclaimed = listed - claimed.get(profile_ref, set())
        if unclaimed:
            raise CatalogError(
                f"profile {profile_ref}: lists operations {sorted(unclaimed)} that do not "
                f"declare it"
            )
    return operations, profiles



def catalog_digest(operations: list[dict]) -> str:
    canonical = json.dumps(
        sorted(operations, key=operation_sort_key),
        ensure_ascii=True,
        sort_keys=True,
        separators=(",", ":"),
    )
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def _swift_string(value: str) -> str:
    escaped = value.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


def _swift_field(name: str, spec: dict) -> str:
    parts = [
        f"name: {_swift_string(name)}",
        f"type: .{spec['type']}",
        f"isRequired: {'true' if spec['required'] else 'false'}",
    ]
    if "enum" in spec:
        values = ", ".join(_swift_string(v) for v in spec["enum"])
        parts.append(f"enumValues: [{values}]")
    if "pattern" in spec:
        parts.append(f"pattern: {_swift_string(spec['pattern'])}")
    if "minimum" in spec:
        parts.append(f"minimum: {spec['minimum']}")
    if "maximum" in spec:
        parts.append(f"maximum: {spec['maximum']}")
    if "maxLength" in spec:
        parts.append(f"maxLength: {spec['maxLength']}")
    if "maxItems" in spec:
        parts.append(f"maxItems: {spec['maxItems']}")
    return "CatalogFieldDescriptor(" + ", ".join(parts) + ")"


def _swift_step(step: dict) -> str:
    parts = [
        f"stepID: {_swift_string(step['stepID'])}",
        f"kind: .{step['kind']}",
        f"effect: .{step['effect']}",
        f"cancellation: .{step['cancellation']}",
        f"binding: .{step['binding']}",
        f"isOptional: {'true' if step.get('optional', False) else 'false'}",
        f"compensation: .{step['compensation']}",
    ]
    if "actionRef" in step:
        action_ref = step["actionRef"]
        parts.append(
            "actionReference: CatalogActionReference("
            f"catalogID: {_swift_string(action_ref['catalogId'])}, "
            f"actionID: {_swift_string(action_ref['actionId'])})"
        )
    return "CatalogStepDescriptor(" + ", ".join(parts) + ")"


def _swift_artifact(artifact: dict) -> str:
    parts = [
        f"name: {_swift_string(artifact['name'])}",
        f"role: .{artifact['role']}",
        f"mediaType: {_swift_string(artifact['mediaType'])}",
        f"privacy: .{artifact['privacy']}",
        f"isRequired: {'true' if artifact['required'] else 'false'}",
        f"retentionClass: .{artifact.get('retentionClass', 'default')}",
    ]
    return "CatalogArtifactDescriptor(" + ", ".join(parts) + ")"


def generate_swift(operations: list[dict], digest: str) -> str:
    lines = [
        "// GENERATED FILE - DO NOT EDIT BY HAND.",
        "// Source of truth: Catalog/operations/*.json (CHG-2026-046 T04).",
        "// Regenerate: python3 scripts/catalog_gen/generate.py --write",
        "// Drift is a check-sdd error (bidirectional byte comparison).",
        "",
        "extension RuntimeOperationCatalog {",
        f"  public static let catalogDigest = {_swift_string(digest)}",
        "",
        "  public static let operations: [CatalogOperationDescriptor] = [",
    ]
    for doc in sorted(operations, key=operation_sort_key):
        permitted = ", ".join(f".{value}" for value in sorted(doc["effect"]["permitted"], key=lambda v: EFFECTS.index(v)))
        authorization = ", ".join(
            f".{auth_effect}: .{policy}"
            for auth_effect, policy in sorted(
                doc["authorization"].items(), key=lambda item: EFFECTS.index(item[0])
            )
        )
        issuance = doc.get("defaultPolicyIssuance", "enabled")
        lines.append("    CatalogOperationDescriptor(")
        lines.append(f"      id: {_swift_string(doc['id'])},")
        version = "nil" if "version" not in doc else str(doc["version"])
        lines.append(f"      version: {version},")
        lines.append(f"      title: {_swift_string(doc['title'])},")
        lines.append(f"      provider: .{doc['provider']},")
        lines.append(f"      minimumEffect: .{doc['effect']['minimum']},")
        lines.append(f"      permittedEffects: [{permitted}],")
        lines.append(f"      authorization: [{authorization}],")
        lines.append(
            f"      defaultPolicyIssuanceEnabled: {'true' if issuance == 'enabled' else 'false'},"
        )
        lines.append(f"      binding: .{doc['binding']},")
        concurrency = (
            {
                "device-exclusive": "deviceExclusive",
                "device-shared-readonly": "deviceSharedReadOnly",
                "host-exclusive": "hostExclusive",
            }[doc["concurrencyKey"]]
        )
        lines.append(f"      concurrencyKey: .{concurrency},")
        input_fields = ",\n        ".join(
            _swift_field(name, spec) for name, spec in sorted(doc["inputs"]["fields"].items())
        )
        output_fields = ",\n        ".join(
            _swift_field(name, spec) for name, spec in sorted(doc["outputs"]["fields"].items())
        )
        lines.append(f"      inputs: [\n        {input_fields}\n      ],")
        lines.append(f"      outputs: [\n        {output_fields}\n      ],")
        steps = ",\n        ".join(_swift_step(step) for step in doc["steps"])
        lines.append(f"      steps: [\n        {steps}\n      ],")
        lines.append(f"      timeoutSeconds: {doc['timeoutSeconds']},")
        lines.append(f"      outputByteBudget: {doc['outputByteBudget']},")
        lines.append(f"      preflightAttempts: {doc['retry']['preflightAttempts']},")
        artifacts = ",\n        ".join(_swift_artifact(a) for a in doc["artifacts"])
        lines.append(f"      artifacts: [\n        {artifacts}\n      ],")
        profiles = ", ".join(_swift_string(p) for p in doc["profiles"])
        recovery = doc.get("completeOverwriteRecovery")
        if recovery is None:
            lines.append(f"      profiles: [{profiles}]")
        else:
            recovery_profiles = ", ".join(
                "CatalogCompleteOverwriteRecoveryProfileDescriptor("
                f"reference: {_swift_string(profile['reference'])}, coveredEffects: ["
                + ", ".join(_swift_string(value) for value in profile["coveredEffects"])
                + "])"
                for profile in recovery["profiles"]
            )
            verification_steps = ", ".join(
                _swift_string(value) for value in recovery["verificationStepIDs"]
            )
            lines.append(f"      profiles: [{profiles}],")
            lines.append("      completeOverwriteRecovery: CatalogCompleteOverwriteRecoveryDescriptor(")
            lines.append(
                f"        contractVersion: {_swift_string(recovery['contractVersion'])},"
            )
            lines.append(f"        profiles: [{recovery_profiles}],")
            lines.append(
                f"        overwriteStepID: {_swift_string(recovery['overwriteStepID'])},"
            )
            lines.append(f"        verificationStepIDs: [{verification_steps}])")
        lines.append("    ),")
    lines.append("  ]")
    lines.append("}")
    lines.append("")
    return "\n".join(lines)


def generate_matrix(operations: list[dict], profiles: list[dict], digest: str) -> str:
    lines = [
        "<!-- GENERATED FILE - DO NOT EDIT BY HAND. -->",
        "<!-- Source of truth: Catalog/operations/*.json; regenerate via scripts/catalog_gen/generate.py --write -->",
        "",
        "# Operation effect / authorization matrix",
        "",
        f"Catalog digest: `{digest}`",
        "",
        "| Operation | Provider | Effect (min → max) | Authorization | Default issuance | Binding | Concurrency | Timeout (s) | Output budget (bytes) |",
        "| --- | --- | --- | --- | --- | --- | --- | --- | --- |",
    ]
    for doc in sorted(operations, key=operation_sort_key):
        permitted = sorted(doc["effect"]["permitted"], key=lambda v: EFFECTS.index(v))
        effect_span = (
            permitted[0] if len(permitted) == 1 else f"{permitted[0]} → {permitted[-1]}"
        )
        authorization = "; ".join(
            f"{auth_effect}: {policy}"
            for auth_effect, policy in sorted(
                doc["authorization"].items(), key=lambda item: EFFECTS.index(item[0])
            )
        )
        issuance = doc.get("defaultPolicyIssuance", "enabled")
        lines.append(
            f"| `{operation_reference(doc)}` | {doc['provider']} | {effect_span} "
            f"| {authorization} | {issuance} | {doc['binding']} | {doc['concurrencyKey']} "
            f"| {doc['timeoutSeconds']} | {doc['outputByteBudget']} |"
        )
    lines.append("")
    lines.append("## Profiles")
    lines.append("")
    lines.append("| Profile | Provider | Supported operations |")
    lines.append("| --- | --- | --- |")
    for doc in sorted(profiles, key=profile_sort_key):
        ops = ", ".join(f"`{ref}`" for ref in doc["supportedOperations"])
        lines.append(f"| `{profile_reference(doc)}` | {doc['provider']} | {ops} |")
    lines.append("")
    return "\n".join(lines)


def generated_outputs(
    operations_dir: Path = OPERATIONS_DIR,
    profiles_dir: Path = PROFILES_DIR,
    registry_path: Path = STEP_REGISTRY_PATH,
) -> dict[Path, str]:
    operations, profiles = load_catalog(operations_dir, profiles_dir, registry_path)
    digest = catalog_digest(operations)
    return {
        GENERATED_SWIFT_PATH: generate_swift(operations, digest),
        GENERATED_MATRIX_PATH: generate_matrix(operations, profiles, digest),
    }


def drift_report() -> list[str]:
    """Zero-write drift check: returns human-readable problems (empty = clean)."""
    problems: list[str] = []
    try:
        outputs = generated_outputs()
    except (CatalogError, OSError, json.JSONDecodeError, yaml.YAMLError) as error:
        return [f"catalog validation failed: {error}"]
    for path, expected in outputs.items():
        relative = path.relative_to(REPO_ROOT)
        if not path.is_file():
            problems.append(f"{relative}: generated file is missing; run generate.py --write")
            continue
        actual = path.read_text(encoding="utf-8")
        if actual != expected:
            problems.append(
                f"{relative}: drift between Catalog/ and generated output; "
                "run generate.py --write and commit both sides"
            )
    return problems


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--check", action="store_true", help="validate + drift check, zero writes")
    mode.add_argument("--write", action="store_true", help="validate + write generated files")
    args = parser.parse_args(argv)
    if args.check:
        problems = drift_report()
        for problem in problems:
            print(f"catalog_gen: {problem}", file=sys.stderr)
        return 1 if problems else 0
    outputs = generated_outputs()
    for path, content in outputs.items():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")
        print(f"wrote {path.relative_to(REPO_ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
