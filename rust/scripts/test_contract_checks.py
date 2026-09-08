#!/usr/bin/env python3
"""Regression checks for publication proof and isolated candidate conformance."""
from __future__ import annotations

import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import jsonschema

SCRIPT = Path(__file__).resolve().with_name("check-contracts.py")
SPEC = importlib.util.spec_from_file_location("arkdeck_dual_contract_checks", SCRIPT)
runner = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = runner
SPEC.loader.exec_module(runner)
contract = runner.contract


class ContractChecksTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="arkdeck-contract-tests-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        for module, key, value in [
            (runner, "ROOT", self.root), (contract, "ROOT", self.root),
            (contract, "BASELINE", self.root / "spec/baselines/swift-single-v1.json"),
            (contract, "GENERATED", self.root / "rust/crates/arkdeck-contract/src/control_generated.rs"),
            # Rust formatting is exercised by the real generation check. These
            # tests isolate Git/input behavior and require no installed compiler.
            (contract, "formatted", lambda source: source),
        ]:
            replacement = patch.object(module, key, value)
            replacement.start()
            self.addCleanup(replacement.stop)
        methods = ["device.observations", "doctor", "health", "operation.list"]
        registry = {"currentVersion": "1.0.0", "maximumRequestFrameBytes": 1000,
                    "maximumResponseFrameBytes": 2000, "methods": methods}
        identity = contract.sha(json.dumps(registry, sort_keys=True, separators=(",", ":")).encode())
        directories = {contract.METHODS, contract.CORPUS, "Catalog/operations", "Catalog/profiles",
                       "Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/HDC"}
        for name in contract.INPUTS:
            if name in directories:
                (self.root / name).mkdir(parents=True)
            else:
                self.write(name, b"test input\n")
        self.write(contract.REGISTRY, registry)
        self.write("Catalog/generated/effect-authorization-matrix.md", b"Catalog digest: `" + b"a" * 64 + b"`\n")
        self.write("Catalog/operations/example.json", {})
        self.write("Catalog/profiles/example.json", {})
        self.write("Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/HDC/example.txt", b"host fixture\n")
        for method in methods:
            schema = {"x-arkdeck-contractIdentity": identity,
                      "$defs": {part: {"type": "object", "properties": {}, "additionalProperties": False}
                                for part in ("request", "result")}}
            self.write(f"{contract.METHODS}/{method}.json", schema)
            self.write(f"{contract.CORPUS}/{method}.jsonl", {
                "method": method, "protocolVersion": "1.0.0", "params": {}, "ok": True, "result": {},
            })
        self.write("rust/crates/arkdeck-contract/src/catalog_generated.rs", b"// test catalog\n")
        self.write("rust/scripts/check-readonly.py", b"# test source; not executed\n")
        self.write("scripts/catalog_gen/generate.py", b"def generate_rust(operations, digest):\n    return '// test catalog\\n'\n")
        self.git("init", "-q", "-b", "main")
        self.git("-c", "user.name=Contract test", "-c", "user.email=contract@example.invalid", "add", ".")
        self.git("-c", "user.name=Contract test", "-c", "user.email=contract@example.invalid",
                 "commit", "-qm", "Published test inputs")
        self.git("update-ref", "refs/remotes/origin/main", "HEAD")
        self.commit = self.git("rev-parse", "HEAD").decode().strip()
        self.published, self.info, outputs = contract.published_outputs(self.commit)
        for path, text in outputs.items():
            self.write(path.relative_to(self.root).as_posix(), text.encode())

    def write(self, name, value):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(value if isinstance(value, bytes) else (json.dumps(value) + "\n").encode())

    def git(self, *args):
        return subprocess.check_output(["git", "-C", str(self.root), *args], stderr=subprocess.PIPE)

    def change_candidate(self):
        name = f"{contract.METHODS}/health.json"
        schema = json.loads((self.root / name).read_bytes())
        schema["$defs"]["result"]["properties"]["candidateOnly"] = {"type": "string"}
        self.write(name, schema)
        corpus = self.root / contract.CORPUS / "health.jsonl"
        corpus.write_bytes(corpus.read_bytes() * 2)
        current = contract.working_inputs()
        return current, contract.candidate(current, self.commit, self.commit)

    def test_candidate_changes_pass_published_check_without_rewriting_pin(self):
        before = contract.BASELINE.read_bytes()
        current, info = self.change_candidate()
        contract.verify_published()
        generated = contract.generate(info, current)
        self.assertIn("candidate_only", generated)
        self.assertIn("swift-candidate-inputs.json", generated)
        self.assertEqual(info["kind"], "candidate")
        self.assertNotIn("commit", info)
        self.assertEqual(info["publishedBaselineCommit"], self.commit)
        self.assertEqual(info["corpusRecordCounts"], {"requests": 5, "successes": 5, "errors": 0})
        self.assertEqual(info["corpusMethodCounts"]["health"]["requests"], 2)
        self.assertEqual(contract.BASELINE.read_bytes(), before)

    def test_candidate_new_keywords_stay_isolated_from_the_published_baseline(self):
        before_pin = contract.BASELINE.read_bytes()
        before_generated = contract.GENERATED.read_bytes()
        name = f"{contract.METHODS}/health.json"
        document = json.loads((self.root / name).read_bytes())
        data = {"oneOf": [{"unknownDataKey": True}], "pattern": "ordinary data"}
        result_schema = {
            "type": "object", "additionalProperties": False,
            "required": ["digest", "revision", "payload"],
            "properties": {
                "digest": {"type": "string", "pattern": contract.SCHEMA_PATTERNS["lowercaseSha256"],
                           "minLength": 64},
                "revision": {"oneOf": [
                    {"const": None},
                    {"type": "string", "pattern": contract.SCHEMA_PATTERNS["nonnegativeInt64Decimal"],
                     "not": {"const": "0"}},
                ]},
                "payload": {"const": data},
            },
        }
        document["$defs"]["result"] = result_schema
        self.write(name, document)
        result = {"digest": "a" * 64, "revision": "42", "payload": data}
        self.write(f"{contract.CORPUS}/health.jsonl", {
            "method": "health", "protocolVersion": "1.0.0", "params": {}, "ok": True, "result": result,
        })
        current = contract.working_inputs()
        candidate = contract.candidate(current, self.commit, self.commit)
        contract.verify_published()
        view = self.root / "candidate-view"
        runner.materialize(view, current, candidate, self.info)
        self.assertEqual(json.loads((view / name).read_bytes())["$defs"]["result"], result_schema)
        self.assertEqual((view / "spec/baselines/swift-single-v1.json").read_bytes(), before_pin)
        generated = (view / "rust/crates/arkdeck-contract/src/control_generated.rs").read_text()
        self.assertIn("swift-candidate-inputs.json", generated)
        self.assertEqual(contract.BASELINE.read_bytes(), before_pin)
        self.assertEqual(contract.GENERATED.read_bytes(), before_generated)
        validator = jsonschema.Draft202012Validator(result_schema)
        validator.validate(result)
        for field, value in [("digest", "a" * 64 + "\n"), ("revision", "0"), ("payload", {})]:
            with self.subTest(field=field):
                self.assertFalse(validator.is_valid({**result, field: value}))

    def test_candidate_unused_definitions_cannot_hide_invalid_new_vocabulary(self):
        name = f"{contract.METHODS}/health.json"
        before = (self.root / name).read_bytes()
        for invalid in [{"oneOf": []}, {"pattern": "^.*$"}, {"minLength": True},
                        {"not": []}, {"oneOf": [{}, {"unpublishedKeyword": True}]}]:
            with self.subTest(schema=invalid):
                document = json.loads(before)
                document["$defs"]["unusedDefinition"] = {"properties": {"unused": invalid}}
                self.write(name, document)
                current = contract.working_inputs()
                candidate = contract.candidate(current, self.commit, self.commit)
                with self.assertRaises(ValueError):
                    contract.generate(candidate, current)
                contract.verify_published()

    def test_published_path_types_and_membership_do_not_depend_on_worktree(self):
        shutil.rmtree(self.root / contract.CORPUS)
        self.write(contract.CORPUS, b"candidate replaced directory\n")
        inputs, info = contract.verify_published()
        self.assertIn(contract.CORPUS, inputs.directories)
        self.assertEqual(info, self.info)
        with self.assertRaisesRegex(ValueError, "method/file set drift"):
            contract.describe_inputs(contract.working_inputs())

    def test_unpublished_commit_cannot_be_used_as_a_pin(self):
        self.change_candidate()
        self.git("add", ".")
        self.git("-c", "user.name=Contract test", "-c", "user.email=contract@example.invalid",
                 "commit", "-qm", "Unpublished candidate")
        candidate_commit = self.git("rev-parse", "HEAD").decode().strip()
        with self.assertRaises(subprocess.CalledProcessError):
            contract.published_outputs(candidate_commit)
        contract.verify_published()

    def test_missing_publication_reference_fails_closed(self):
        self.git("update-ref", "-d", "refs/remotes/origin/main")
        with self.assertRaises(subprocess.CalledProcessError):
            contract.verify_published()

    def test_moving_references_and_abbreviations_cannot_replace_immutable_pin(self):
        for reference in ("origin/main", "HEAD", self.commit[:12], self.commit.upper()):
            with self.subTest(reference=reference):
                self.write(contract.BASELINE.relative_to(self.root), {**self.info, "commit": reference})
                with self.assertRaisesRegex(ValueError, "full immutable commit"):
                    contract.verify_published()

    def test_pin_hash_blob_membership_and_counts_tampering_is_rejected(self):
        before = contract.BASELINE.read_bytes()
        for field in ("sha256", "blob", "directory", "membership", "counts"):
            with self.subTest(field=field):
                info = json.loads(before)
                if field in ("sha256", "blob"):
                    info["files"][contract.REGISTRY][field] = "0" * 64
                elif field == "directory":
                    info["directoryDigests"][contract.CORPUS] = "0" * 64
                elif field == "membership":
                    del info["files"][contract.REGISTRY]
                else:
                    info["corpusRecordCounts"]["requests"] = 1
                self.write(contract.BASELINE.relative_to(self.root), info)
                with self.assertRaisesRegex(ValueError, "generated input drift"):
                    contract.verify_published()
                contract.BASELINE.write_bytes(before)

    def test_stale_published_rust_generation_is_rejected(self):
        contract.GENERATED.write_bytes(contract.GENERATED.read_bytes() + b"// stale\n")
        with self.assertRaisesRegex(ValueError, "generated input drift"):
            contract.verify_published()

    def test_candidate_unknown_vocabulary_and_unclosed_method_set_are_rejected(self):
        current, info = self.change_candidate()
        name = f"{contract.METHODS}/health.json"
        schema = current.json(name)
        schema["$defs"]["result"]["patternProperties"] = {}
        current.files[name] = json.dumps(schema).encode()
        with self.assertRaisesRegex(ValueError, "unsupported schema vocabulary"):
            contract.generate(info, current)
        self.write(f"{contract.METHODS}/unknown.json", {})
        with self.assertRaisesRegex(ValueError, "method/file set drift"):
            contract.describe_inputs(contract.working_inputs())

    def test_candidate_identity_missing_method_and_torn_corpus_are_rejected(self):
        name = f"{contract.METHODS}/health.json"
        current = contract.working_inputs()
        schema = current.json(name)
        schema["x-arkdeck-contractIdentity"] = "0" * 64
        current.files[name] = json.dumps(schema).encode()
        with self.assertRaisesRegex(ValueError, "schema identity drift"):
            contract.generate(self.info, current)
        path = self.root / contract.CORPUS / "health.jsonl"
        before = path.read_bytes()
        path.write_bytes(before[:-1])
        with self.assertRaisesRegex(ValueError, "torn corpus"):
            contract.describe_inputs(contract.working_inputs())
        path.unlink()
        with self.assertRaisesRegex(ValueError, "method/file set drift"):
            contract.describe_inputs(contract.working_inputs())

    def test_input_views_keep_the_published_pin_and_consume_distinct_schema_bytes(self):
        current, candidate = self.change_candidate()
        before = contract.BASELINE.read_bytes()
        for name, inputs, info in [("published", self.published, self.info), ("candidate", current, candidate)]:
            view = self.root / name
            runner.materialize(view, inputs, info, self.info)
            pin = view / "spec/baselines/swift-single-v1.json"
            self.assertEqual(pin.read_bytes(), before)
            schema = f"{contract.METHODS}/health.json"
            self.assertEqual((view / schema).read_bytes(), inputs.files[schema])
            candidate_file = view / "spec/baselines/swift-candidate-inputs.json"
            self.assertEqual(candidate_file.exists(), name == "candidate")
            if candidate_file.exists():
                self.assertEqual(json.loads(candidate_file.read_bytes())["kind"], "candidate")
        self.assertEqual(contract.BASELINE.read_bytes(), before)

    def test_each_view_runs_the_complete_ordered_native_checks(self):
        view = self.root / "view"
        commands = runner.commands(view, self.root / "output")
        self.assertEqual([argv[1] for argv, _ in commands[:4]], ["clippy", "test", "run", "build"])
        self.assertIn("--all-targets", commands[0][0])
        self.assertEqual(commands[0][0][-3:], ["--", "-D", "warnings"])
        self.assertEqual(commands[2][0][-1], "process-selftest")
        self.assertIn("--bins", commands[3][0])
        checker, cwd = commands[4]
        self.assertEqual(checker[1], str(view / "rust/scripts/check-readonly.py"))
        self.assertEqual(checker[checker.index("--bin-dir") + 1], str(view / "rust/target/debug"))
        self.assertEqual(cwd, view)

    def test_any_native_stage_failure_stops_that_view_and_is_preserved(self):
        for fail_at in range(5):
            with self.subTest(stage=fail_at):
                calls = []

                def run(argv, *, cwd, env, check):
                    self.assertTrue(check)
                    self.assertEqual(env["CARGO_TARGET_DIR"], str(self.root / "view/rust/target"))
                    calls.append(argv)
                    if len(calls) == fail_at + 1:
                        raise subprocess.CalledProcessError(9, argv)
                    return subprocess.CompletedProcess(argv, 0)

                output = self.root / f"failure-{fail_at}"
                with patch.dict(os.environ, {"CARGO_TARGET_DIR": "/unrelated/shared/target"}):
                    with self.assertRaises(subprocess.CalledProcessError):
                        runner.run_view(self.root / "view", output, self.info, self.info, run=run)
                provenance = json.loads((output / "provenance.json").read_bytes())
                self.assertFalse(provenance["completed"])
                self.assertFalse(provenance["deviceAcceptance"])
                self.assertEqual(provenance["result"], "fail")
                self.assertEqual(len(calls), fail_at + 1)

    def test_failure_in_either_view_cannot_leave_combined_check_green(self):
        for failing_view in ("development", "candidate"):
            with self.subTest(view=failing_view):
                calls = []

                def check_view(view, output, info, published_info):
                    calls.append(info["kind"])
                    if info["kind"] == failing_view:
                        raise ValueError("expected test failure")

                with patch.object(runner, "run_view", check_view):
                    with self.assertRaisesRegex(ValueError, "contract checks failed"):
                        runner.check(self.root / "outputs")
                self.assertEqual(calls, ["development", "candidate"])

    def test_both_views_use_one_source_snapshot_and_report_concurrent_edits(self):
        calls = []
        source = self.root / "rust/scripts/check-readonly.py"
        original = source.read_bytes()

        def check_view(view, output, info, published_info):
            calls.append(info["kind"])
            self.assertEqual((view / "rust/scripts/check-readonly.py").read_bytes(), original)
            self.assertEqual((view / "rust/crates/arkdeck-contract/src/catalog_generated.rs").read_bytes(),
                             b"// test catalog\n")
            if info["kind"] == "development":
                source.write_bytes(b"# concurrently edited Rust checker\n")
                self.write("scripts/catalog_gen/generate.py", b"raise RuntimeError('changed generator')\n")

        with patch.object(runner, "run_view", check_view):
            with self.assertRaisesRegex(ValueError, "Rust sources changed.*Catalog generator changed"):
                runner.check(self.root / "outputs")
        self.assertEqual(calls, ["development", "candidate"])

    def test_stale_candidate_catalog_output_cannot_be_hidden_by_isolation(self):
        self.write("rust/crates/arkdeck-contract/src/catalog_generated.rs", b"// stale\n")
        with self.assertRaisesRegex(ValueError, "candidate Catalog generated input drift"):
            runner.check(self.root / "outputs")


class SchemaVocabularyTests(unittest.TestCase):
    @staticmethod
    def locations(schema):
        # The first combinator branch already accepts every instance. Vocabulary
        # validation must still inspect the later branch and unused properties.
        return {
            "root": schema,
            "anyOf": {"anyOf": [{}, schema]},
            "oneOf": {"oneOf": [{}, schema]},
            "not": {"not": schema},
            "unused property": {"type": "object", "properties": {"unused": schema}},
            "items": {"type": "array", "items": schema},
        }

    def test_current_and_new_supported_keyword_shapes(self):
        schemas = [
            {}, {"type": "string"}, {"type": ["string", "null"]},
            {"properties": {}}, {"required": []}, {"required": ["", "known"]},
            {"items": {}}, {"additionalProperties": False}, {"additionalProperties": True},
            {"enum": [None, True, 1, 1.0, {"type": "data"}, ["nested"]]},
            {"anyOf": [{"type": "string"}, {"type": "null"}]},
            {"oneOf": [{"const": 1}, {"const": "one"}]}, {"not": {}},
            {"minLength": 0}, {"minLength": (1 << 64) - 1},
            *({"pattern": pattern} for pattern in contract.SCHEMA_PATTERNS.values()),
        ]
        for schema in schemas:
            with self.subTest(schema=schema):
                contract.check_vocabulary(schema)

    def test_const_and_enum_objects_are_data_without_schema_key_recursion(self):
        values = [None, False, 0, 1.5, "", [None, {"unknownKeyword": 1}],
                  {"oneOf": False, "not": "data", "properties": {"$ref": None},
                   "pattern": "not a registered pattern", "minLength": -1}]
        for value in values:
            with self.subTest(value=value):
                contract.check_vocabulary({"const": value})
                contract.check_vocabulary({"enum": [value, value]})

    def test_malformed_keyword_values_are_rejected_at_every_schema_location(self):
        malformed = {
            "type": [None, True, 1, "unknown", {}, [], ["string", "string"], ["string", None]],
            "properties": [None, [], "name", {"unused": True}],
            "required": [None, True, "name", [None], ["name", "name"]],
            "items": [None, True, [], "string"],
            "additionalProperties": [None, 0, 1, [], {}, "false"],
            "enum": [None, False, 1, {}, [], "choice"],
            "anyOf": [None, True, {}, [], "schema", [True], [{}, None]],
            "oneOf": [None, True, {}, [], "schema", [True], [{}, None]],
            "not": [None, False, [], "schema"],
            "pattern": [None, True, 1, [], {}, "", "^.*$"],
            "minLength": [None, False, True, -1, 0.0, 1.0, 1.5, "1", [], {}, 1 << 64],
        }
        for keyword, values in malformed.items():
            for value in values:
                for location, schema in self.locations({keyword: value}).items():
                    with self.subTest(keyword=keyword, value=value, location=location):
                        with self.assertRaises(ValueError):
                            contract.check_vocabulary(schema)

    def test_unknown_keywords_cannot_hide_in_any_supported_schema_branch(self):
        for location, schema in self.locations({"unpublishedKeyword": True}).items():
            with self.subTest(location=location):
                with self.assertRaisesRegex(ValueError, "unsupported schema vocabulary"):
                    contract.check_vocabulary(schema)

    def test_non_json_const_or_enum_values_are_rejected(self):
        for value in [float("nan"), float("inf"), float("-inf"), (1,), {1: "key"}, {"key": {1}}]:
            for keyword, candidate in [("const", value), ("enum", [value])]:
                with self.subTest(keyword=keyword, value=value):
                    with self.assertRaisesRegex(ValueError, "expected JSON data"):
                        contract.check_vocabulary({keyword: candidate})

    def test_pattern_vocabulary_is_independent_of_the_candidate_root(self):
        with tempfile.TemporaryDirectory(prefix="arkdeck-pattern-root-") as directory:
            root = Path(directory)
            candidate_patterns = root / "rust/crates/arkdeck-contract/src/schema_patterns.json"
            candidate_patterns.parent.mkdir(parents=True)
            candidate_patterns.write_text(json.dumps({name: ".*" for name in contract.SCHEMA_PATTERNS}))
            with patch.object(contract, "ROOT", root):
                for pattern in contract.SCHEMA_PATTERNS.values():
                    contract.check_vocabulary({"pattern": pattern})
                with self.assertRaisesRegex(ValueError, "unsupported schema pattern"):
                    contract.check_vocabulary({"pattern": ".*"})

    def assert_pattern_matches(self, name, values, expected):
        pattern = contract.SCHEMA_PATTERNS[name]
        schema = {"type": "string", "pattern": pattern}
        contract.check_vocabulary(schema)
        jsonschema.Draft202012Validator.check_schema(schema)
        validator = jsonschema.Draft202012Validator(schema)
        for value in sorted(set(values)):
            with self.subTest(pattern=name, value=value):
                allowed = expected(value)
                self.assertEqual(re.search(pattern, value) is not None, allowed)
                self.assertEqual(validator.is_valid(value), allowed)

    def test_lowercase_sha256_pattern_matches_exact_ascii_boundaries(self):
        values = ["", "a" * 63, "a" * 64, "a" * 65, "0" * 64, "f" * 64,
                  "0123456789abcdef" * 4, "A" * 64, "g" + "a" * 63,
                  "\u0660" * 64, "\uff41" * 64, "\U0001f600" + "a" * 63]
        for ending in ("\n", "\r", "\r\n", "\u2028", "\u2029", "\0", " "):
            values.extend(["a" * 64 + ending, ending + "a" * 64, "a" * 32 + ending + "a" * 32])
        self.assert_pattern_matches("lowercaseSha256", values,
                                    lambda value: len(value) == 64
                                    and all(character in "0123456789abcdef" for character in value))

    def test_nonnegative_int64_decimal_pattern_matches_range_and_lexical_boundaries(self):
        maximum = (1 << 63) - 1
        digits = str(maximum)
        values = ["", "0", "1", "9", "10", "00", "01", "+1", "-0", "-1", "1.0", "1e3",
                  "\u0661", "\uff11", "1_000", "10000000000000000000"]
        values.extend(str(maximum + offset) for offset in range(-2, 3))
        values.extend("9" * length for length in (17, 18, 19, 20))
        # Probe both sides of every decimal prefix represented by the bounded
        # pattern, without borrowing Swift candidate fixtures or copying regexes.
        for index in range(len(digits)):
            for digit in "0123456789":
                for suffix in "09":
                    values.append(digits[:index] + digit + suffix * (len(digits) - index - 1))
        for ending in ("\n", "\r", "\r\n", "\u2028", "\u2029", "\0", " "):
            values.extend(["0" + ending, digits + ending, ending + "0", "1" + ending + "0"])

        def expected(value):
            return (bool(value) and all(character in "0123456789" for character in value)
                    and (value == "0" or value[0] != "0") and int(value) <= maximum)

        self.assert_pattern_matches("nonnegativeInt64Decimal", values, expected)


if __name__ == "__main__":
    unittest.main()
