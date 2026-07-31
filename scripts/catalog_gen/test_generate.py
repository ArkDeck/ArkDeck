"""Contract tests for the Operation Catalog validator/generator (CHG-2026-046).

Run: python3 scripts/catalog_gen/test_generate.py (interpreter must satisfy
scripts/requirements-sdd.txt, same as check-sdd). Wired into CI through
scripts/test_check_sdd.py::OperationCatalogFamilyTests, which runs this file
as a subprocess.
"""

from __future__ import annotations

import copy
import json
import re
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import generate  # noqa: E402


def _real_operations():
    operations, profiles = generate.load_catalog()
    return operations, profiles


def _first_operation() -> dict:
    operations, _ = _real_operations()
    return copy.deepcopy(next(op for op in operations if op["id"] == "observe.device"))


def _stdout_operation() -> dict:
    operations, _ = _real_operations()
    return copy.deepcopy(next(op for op in operations if op["id"] == "capture.diagnostics"))


class RealCatalogTests(unittest.TestCase):
    def test_real_catalog_validates_and_cross_references(self):
        operations, profiles = _real_operations()
        self.assertEqual(
            sorted(f"{op['id']}@{op['version']}" for op in operations),
            [
                "capture.diagnostics@1",
                "debug.hap@1",
                "deploy.native-library.app-owned@1",
                "deploy.native-library.system@1",
                "flash.dayu200@1",
                "observe.device@1",
                "workspace.apply-patch@1",
                "workspace.build-openharmony@1",
                "workspace.inspect-source@1",
                "workspace.revert-patch@1",
                "workspace.run-tests@1",
                "workspace.symbolize-crash@1",
            ],
        )
        self.assertEqual(
            sorted(f"{p['id']}@{p['version']}" for p in profiles),
            ["dayu200@1", "openharmony-standard@1", "workspace-host@1"],
        )

    def test_generation_is_deterministic(self):
        first = generate.generated_outputs()
        second = generate.generated_outputs()
        self.assertEqual(first, second)

    def test_repo_has_zero_drift(self):
        self.assertEqual(generate.drift_report(), [])

    def test_digest_is_stable_under_key_reordering(self):
        operations, _ = _real_operations()
        digest = generate.catalog_digest(operations)
        reordered = [
            {key: doc[key] for key in reversed(list(doc))} for doc in operations
        ]
        self.assertEqual(generate.catalog_digest(reordered), digest)

    def test_digest_changes_on_semantic_change(self):
        operations, _ = _real_operations()
        digest = generate.catalog_digest(operations)
        mutated = copy.deepcopy(operations)
        mutated[0]["timeoutSeconds"] += 1
        self.assertNotEqual(generate.catalog_digest(mutated), digest)

    def test_e2_operations_are_pinned(self):
        operations, _ = _real_operations()
        for op_id in ("deploy.native-library.system", "flash.dayu200"):
            doc = next(op for op in operations if op["id"] == op_id)
            self.assertEqual(doc["effect"]["permitted"], ["destructive"], op_id)
            self.assertEqual(doc["authorization"], {"destructive": "oneShotExactPlan"}, op_id)
        system = next(op for op in operations if op["id"] == "deploy.native-library.system")
        self.assertEqual(system.get("defaultPolicyIssuance"), "disabled")

    def test_every_stdout_step_has_an_exact_registered_action(self):
        operations, _ = _real_operations()
        registry = generate.load_stdout_action_registry()
        observed = {}
        for operation in operations:
            for step in operation["steps"]:
                if step["kind"] != "captureRemoteStdout":
                    continue
                action_ref = step["actionRef"]
                pair = (action_ref["catalogId"], action_ref["actionId"])
                self.assertIn(pair[1], registry[pair[0]])
                observed[f"{operation['id']}@{operation['version']}/{step['stepID']}"] = pair
        self.assertEqual(
            observed,
            {
                "capture.diagnostics@1/capture-hilog": (
                    "arkdeck-diagnostics", "boundedHilog"
                ),
                "capture.diagnostics@1/capture-ui-dump": (
                    "arkdeck-diagnostics", "windowInventory"
                ),
                "capture.diagnostics@1/capture-crash-index": (
                    "arkdeck-diagnostics", "crashIndex"
                ),
                "capture.diagnostics@1/capture-crash-log": (
                    "arkdeck-diagnostics", "crashLog"
                ),
                "debug.hap@1/capture-diagnostics": (
                    "arkdeck-diagnostics", "boundedHilog"
                ),
                "flash.dayu200@1/capture-post-flash-diagnostics": (
                    "arkdeck-diagnostics", "boundedHilog"
                ),
            },
        )

    def test_evidence_remote_reads_have_exact_registered_actions(self):
        operations, _ = _real_operations()
        registry = generate.load_remote_action_registry()
        observed = {}
        for operation in operations:
            if operation["id"] not in generate.ACTION_REFERENCE_REQUIRED_OPERATIONS:
                continue
            for step in operation["steps"]:
                if step["kind"] != "runApprovedRemoteRead":
                    continue
                action_ref = step["actionRef"]
                self.assertEqual(action_ref["catalogId"], "arkdeck-remote-operations")
                self.assertEqual(registry[action_ref["actionId"]], step["kind"])
                observed[
                    f"{operation['id']}@{operation['version']}/{step['stepID']}"
                ] = action_ref["actionId"]
        self.assertEqual(
            observed,
            {
                "capture.diagnostics@1/read-evidence-model": "deviceModel",
                "capture.diagnostics@1/read-evidence-firmware": "firmwareBuild",
                "debug.hap@1/read-evidence-model": "deviceModel",
                "debug.hap@1/read-evidence-firmware": "firmwareBuild",
                "debug.hap@1/package-readback": "packageInfo",
                "observe.device@1/read-evidence-model": "deviceModel",
                "observe.device@1/read-evidence-firmware": "firmwareBuild",
            },
        )

    def test_evidence_preflight_is_the_first_three_device_bound_steps(self):
        operations, _ = _real_operations()
        expected = [
            ("confirm-evidence-target", "probeDevice", None),
            (
                "read-evidence-model",
                "runApprovedRemoteRead",
                ("arkdeck-remote-operations", "deviceModel"),
            ),
            (
                "read-evidence-firmware",
                "runApprovedRemoteRead",
                ("arkdeck-remote-operations", "firmwareBuild"),
            ),
        ]
        for operation in operations:
            if operation["id"] not in generate.ACTION_REFERENCE_REQUIRED_OPERATIONS:
                continue
            device_steps = [
                step for step in operation["steps"]
                if step["binding"] == "confirmedDevice"
            ]
            observed = []
            for step in device_steps[:3]:
                action_ref = step.get("actionRef")
                observed.append(
                    (
                        step["stepID"],
                        step["kind"],
                        None if action_ref is None else (
                            action_ref["catalogId"], action_ref["actionId"]
                        ),
                    )
                )
            self.assertEqual(observed, expected, operation["id"])
            self.assertTrue(
                all(not step.get("optional", False) for step in device_steps[:3]),
                operation["id"],
            )


class ValidatorNegativeTests(unittest.TestCase):
    def setUp(self):
        self.registry = generate.load_step_registry()

    def _assert_rejected(self, doc, fragment: str):
        with self.assertRaises(generate.CatalogError) as ctx:
            generate.validate_operation(doc, self.registry, "test-doc")
        self.assertIn(fragment, str(ctx.exception))

    def test_unknown_step_kind_rejected(self):
        doc = _first_operation()
        doc["steps"][0]["kind"] = "runShellCommand"
        self._assert_rejected(doc, "unknown step kind")

    def test_effect_below_registry_minimum_rejected(self):
        doc = _first_operation()
        for step in doc["steps"]:
            if step["kind"] == "probeDevice":
                step["effect"] = "hostOnly"
        self._assert_rejected(doc, "below registry minimum")

    def test_forbidden_field_name_rejected(self):
        for name in sorted(generate.FORBIDDEN_FIELD_NAMES):
            doc = _first_operation()
            doc["inputs"]["fields"][name] = {"type": "string", "required": False}
            self._assert_rejected(doc, "forbidden field name")

    def test_unknown_top_level_key_rejected(self):
        doc = _first_operation()
        doc["shellSteps"] = []
        self._assert_rejected(doc, "unknown keys")

    def test_destructive_requires_one_shot_exact_plan(self):
        doc = _first_operation()
        doc["effect"] = {"minimum": "readOnly", "permitted": ["readOnly", "destructive"]}
        doc["authorization"] = {
            "readOnly": "defaultReadOnly",
            "destructive": "standingCapability",
        }
        self._assert_rejected(doc, "oneShotExactPlan")

    def test_default_read_only_cannot_gate_mutation(self):
        doc = _first_operation()
        doc["effect"] = {"minimum": "readOnly", "permitted": ["readOnly", "deviceMutation"]}
        doc["authorization"] = {
            "readOnly": "defaultReadOnly",
            "deviceMutation": "defaultReadOnly",
        }
        self._assert_rejected(doc, "may not gate a mutation")

    def test_mutation_retry_is_pinned_to_one(self):
        doc = _first_operation()
        doc["retry"]["mutationAttempts"] = 2
        self._assert_rejected(doc, "pinned to 1")

    def test_unknown_outcome_is_pinned(self):
        doc = _first_operation()
        doc["unknownOutcome"] = "autoRetry"
        self._assert_rejected(doc, "reconcileRequired")

    def test_duplicate_step_ids_rejected(self):
        doc = _first_operation()
        doc["steps"][1]["stepID"] = doc["steps"][0]["stepID"]
        self._assert_rejected(doc, "duplicate stepIDs")

    def test_minimum_effect_must_match_required_steps(self):
        doc = _first_operation()
        doc["effect"] = {"minimum": "hostOnly", "permitted": ["hostOnly", "readOnly"]}
        doc["authorization"] = {
            "hostOnly": "defaultReadOnly",
            "readOnly": "defaultReadOnly",
        }
        self._assert_rejected(doc, "must equal the maximum")

    def test_authorization_must_name_a_gate_for_host_only(self):
        # A purely hostOnly operation used to be unconstructible: the coverage
        # rule excluded hostOnly while also demanding a non-empty map. Every
        # permitted effect now names its gate, host-only work included.
        doc = _first_operation()
        doc["effect"] = {"minimum": "hostOnly", "permitted": ["hostOnly"]}
        doc["authorization"] = {}
        self._assert_rejected(doc, "non-empty object")
        doc["authorization"] = {"readOnly": "defaultReadOnly"}
        self._assert_rejected(doc, "cover exactly")

    def test_permitted_effect_must_be_reachable(self):
        doc = _first_operation()
        doc["effect"] = {"minimum": "readOnly", "permitted": ["readOnly", "deviceMutation"]}
        doc["authorization"] = {
            "readOnly": "defaultReadOnly",
            "deviceMutation": "standingCapability",
        }
        self._assert_rejected(doc, "unreachable")

    def test_authorization_must_cover_exactly_permitted_effects(self):
        doc = _first_operation()
        doc["authorization"] = {}
        self._assert_rejected(doc, "non-empty object")
        doc = _first_operation()
        doc["authorization"]["deviceMutation"] = "standingCapability"
        self._assert_rejected(doc, "cover exactly")

    def test_stdout_step_requires_action_reference(self):
        doc = _stdout_operation()
        del next(step for step in doc["steps"] if step["kind"] == "captureRemoteStdout")[
            "actionRef"
        ]
        self._assert_rejected(doc, "requires actionRef")

    def test_stdout_step_rejects_unknown_catalog_and_action(self):
        for catalog_id, action_id in (
            ("unknown-diagnostics", "boundedHilog"),
            ("arkdeck-diagnostics", "unknownAction"),
            ("arkui-ui-dump", "boundedHilog"),
        ):
            doc = _stdout_operation()
            step = next(step for step in doc["steps"] if step["kind"] == "captureRemoteStdout")
            step["actionRef"] = {"catalogId": catalog_id, "actionId": action_id}
            self._assert_rejected(doc, "unregistered stdout action")

    def test_non_stdout_step_rejects_action_reference(self):
        for action_ref in (
            {
                "catalogId": "arkdeck-diagnostics",
                "actionId": "boundedHilog",
            },
            None,
        ):
            doc = _first_operation()
            doc["steps"][0]["actionRef"] = action_ref
            self._assert_rejected(
                doc, "only captureRemoteStdout or runApprovedRemoteRead")

    def test_evidence_remote_read_requires_action_reference(self):
        doc = _first_operation()
        step = next(
            step for step in doc["steps"]
            if step["kind"] == "runApprovedRemoteRead")
        del step["actionRef"]
        self._assert_rejected(doc, "evidence-eligible operation requires actionRef")

    def test_remote_read_rejects_unknown_or_cross_catalog_action(self):
        for action_ref, fragment in (
            (
                {"catalogId": "arkdeck-remote-operations", "actionId": "unknownRead"},
                "unregistered remote action",
            ),
            (
                {"catalogId": "arkdeck-diagnostics", "actionId": "boundedHilog"},
                "requires arkdeck-remote-operations",
            ),
        ):
            doc = _first_operation()
            step = next(
                step for step in doc["steps"]
                if step["kind"] == "runApprovedRemoteRead")
            step["actionRef"] = action_ref
            self._assert_rejected(doc, fragment)

    def test_action_reference_is_closed(self):
        doc = _stdout_operation()
        step = next(step for step in doc["steps"] if step["kind"] == "captureRemoteStdout")
        step["actionRef"]["command"] = "hilog"
        self._assert_rejected(doc, "unknown keys")


class SchemaVocabularyLockstepTests(unittest.TestCase):
    """The JSON Schema file and the python validator must not drift apart."""

    @classmethod
    def setUpClass(cls):
        schema_path = generate.CATALOG_DIR / "schema" / "operation.schema.json"
        cls.schema = json.loads(schema_path.read_text(encoding="utf-8"))

    def test_top_level_vocabulary_matches(self):
        self.assertEqual(
            set(self.schema["required"]), set(generate.TOP_LEVEL_REQUIRED)
        )
        self.assertEqual(
            set(self.schema["properties"]),
            set(generate.TOP_LEVEL_REQUIRED) | set(generate.TOP_LEVEL_OPTIONAL),
        )

    def test_step_vocabulary_matches(self):
        step = self.schema["$defs"]["step"]
        self.assertEqual(set(step["required"]), set(generate.STEP_REQUIRED))
        self.assertEqual(
            set(step["properties"]),
            set(generate.STEP_REQUIRED) | set(generate.STEP_OPTIONAL),
        )
        self.assertEqual(
            step["properties"]["actionRef"], {"$ref": "#/$defs/actionRef"})
        condition = step["allOf"][0]
        self.assertEqual(
            condition["if"]["properties"]["kind"]["const"], "captureRemoteStdout")
        self.assertEqual(condition["then"]["required"], ["actionRef"])
        remote_condition = condition["else"]
        self.assertEqual(
            remote_condition["if"]["properties"]["kind"]["const"],
            "runApprovedRemoteRead")
        self.assertNotIn("required", remote_condition["then"])
        self.assertEqual(
            remote_condition["else"]["not"]["required"], ["actionRef"])
        selected = self.schema["allOf"][0]
        self.assertEqual(
            set(selected["if"]["properties"]["id"]["enum"]),
            set(generate.ACTION_REFERENCE_REQUIRED_OPERATIONS),
        )

    def test_field_vocabulary_matches(self):
        field = self.schema["$defs"]["field"]
        self.assertEqual(set(field["required"]), set(generate.FIELD_REQUIRED))
        self.assertEqual(
            set(field["properties"]),
            set(generate.FIELD_REQUIRED) | set(generate.FIELD_OPTIONAL),
        )
        self.assertEqual(set(field["properties"]["type"]["enum"]), set(generate.FIELD_TYPES))

    def test_enum_vocabularies_match(self):
        defs = self.schema["$defs"]
        self.assertEqual(tuple(defs["effect"]["enum"]), generate.EFFECTS)
        self.assertEqual(tuple(defs["cancellation"]["enum"]), generate.CANCELLATIONS)
        self.assertEqual(tuple(defs["binding"]["enum"]), generate.BINDINGS)
        self.assertEqual(tuple(defs["compensation"]["enum"]), generate.COMPENSATIONS)
        self.assertEqual(
            tuple(defs["authorizationPolicy"]["enum"]), generate.AUTHORIZATION_POLICIES
        )
        self.assertEqual(tuple(self.schema["properties"]["provider"]["enum"]), generate.PROVIDERS)
        self.assertEqual(
            tuple(self.schema["properties"]["concurrencyKey"]["enum"]),
            generate.CONCURRENCY_KEYS,
        )

    def test_forbidden_field_names_match_schema_pattern(self):
        pattern = self.schema["$defs"]["fieldTable"]["properties"]["fields"][
            "propertyNames"
        ]["pattern"]
        match = re.match(r"^\^\(\?!(.+)\)\[a-z\]\[a-zA-Z0-9\]\*\$$", pattern)
        self.assertIsNotNone(match, f"unexpected propertyNames pattern shape: {pattern}")
        names = {token.rstrip("$").lstrip("^") for token in match.group(1).split("|")}
        self.assertEqual(names, set(generate.FORBIDDEN_FIELD_NAMES))

    def test_schema_pins_unknown_outcome_and_mutation_attempts(self):
        self.assertEqual(
            self.schema["properties"]["unknownOutcome"]["const"], "reconcileRequired"
        )
        self.assertEqual(
            self.schema["properties"]["retry"]["properties"]["mutationAttempts"]["const"], 1
        )
        self.assertEqual(
            self.schema["properties"]["authorization"]["properties"]["destructive"]["const"],
            "oneShotExactPlan",
        )

    def test_schema_has_no_executable_surface(self):
        text = json.dumps(self.schema)
        for needle in ("\"argv\":", "\"shell\":", "\"command\":", "\"executable\":"):
            self.assertNotIn(needle, text.replace("argv$", "").replace("shell$", ""))

    def test_action_reference_schema_matches_registered_pairs(self):
        action_ref = self.schema["$defs"]["actionRef"]
        schema_pairs = {
            arm["properties"]["catalogId"]["const"]: set(
                arm["properties"]["actionId"]["enum"])
            for arm in action_ref["oneOf"]
        }
        self.assertEqual(
            schema_pairs,
            {
                **{
                    key: set(value)
                    for key, value in generate.load_stdout_action_registry().items()
                },
                "arkdeck-remote-operations": set(
                    action_id
                    for action_id, step_kind
                    in generate.load_remote_action_registry().items()
                    if step_kind == "runApprovedRemoteRead"),
            },
        )


class GeneratedSwiftShapeTests(unittest.TestCase):
    def test_generated_swift_mentions_every_operation_once(self):
        operations, _ = _real_operations()
        swift = generate.generate_swift(operations, generate.catalog_digest(operations))
        for doc in operations:
            self.assertEqual(swift.count(f'id: "{doc["id"]}",'), 1)
        self.assertIn("GENERATED FILE - DO NOT EDIT", swift)
        self.assertNotIn("argv", swift)

    def test_generated_swift_carries_digest(self):
        operations, _ = _real_operations()
        digest = generate.catalog_digest(operations)
        swift = generate.generate_swift(operations, digest)
        self.assertIn(f'catalogDigest = "{digest}"', swift)
        self.assertRegex(digest, r"^[0-9a-f]{64}$")

    def test_generated_swift_carries_exact_stdout_action_references(self):
        operations, _ = _real_operations()
        swift = generate.generate_swift(operations, generate.catalog_digest(operations))
        self.assertEqual(
            swift.count(
                'actionReference: CatalogActionReference('
                'catalogID: "arkdeck-diagnostics", actionID: "boundedHilog")'
            ),
            3,
        )
        self.assertEqual(
            swift.count(
                'actionReference: CatalogActionReference('
                'catalogID: "arkdeck-diagnostics", actionID: "windowInventory")'
            ),
            1,
        )
        self.assertEqual(
            swift.count(
                'actionReference: CatalogActionReference('
                'catalogID: "arkdeck-diagnostics", actionID: "componentTree")'
            ),
            0,
        )
        self.assertEqual(
            swift.count(
                'actionReference: CatalogActionReference('
                'catalogID: "arkdeck-remote-operations", actionID: "deviceModel")'
            ),
            3,
        )
        self.assertEqual(
            swift.count(
                'actionReference: CatalogActionReference('
                'catalogID: "arkdeck-remote-operations", actionID: "firmwareBuild")'
            ),
            3,
        )
        self.assertEqual(
            swift.count(
                'actionReference: CatalogActionReference('
                'catalogID: "arkdeck-remote-operations", actionID: "packageInfo")'
            ),
            1,
        )


if __name__ == "__main__":
    unittest.main()
