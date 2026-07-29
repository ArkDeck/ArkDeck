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
            ],
        )
        self.assertEqual(
            sorted(f"{p['id']}@{p['version']}" for p in profiles),
            ["dayu200@1", "openharmony-standard@1"],
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
        doc["authorization"] = {"readOnly": "defaultReadOnly"}
        self._assert_rejected(doc, "must equal the maximum")

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


if __name__ == "__main__":
    unittest.main()
