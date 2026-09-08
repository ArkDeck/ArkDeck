#!/usr/bin/env python3
"""Regression checks for publication proof and isolated candidate conformance."""
from __future__ import annotations

import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

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


if __name__ == "__main__":
    unittest.main()
