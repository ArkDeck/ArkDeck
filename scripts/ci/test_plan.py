#!/usr/bin/env python3
"""Contract tests for the shared local/GitHub CI planner."""

from __future__ import annotations

import json
import importlib.util
import itertools
import os
import pathlib
import re
import subprocess
import sys
import tempfile
import textwrap
import unittest
from unittest import mock


SCRIPT = pathlib.Path(__file__).with_name("plan.py")
SPEC = importlib.util.spec_from_file_location("arkdeck_ci_plan", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
PLAN = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = PLAN
SPEC.loader.exec_module(PLAN)


class PathClassificationTests(unittest.TestCase):
    def assert_lanes(
        self, paths, *, swift: bool, app: bool, ds: bool, rust: bool = False, windows: bool = False
    ):
        selection = PLAN.classify_paths(paths)
        self.assertEqual(selection.swift, swift)
        self.assertEqual(selection.app, app)
        self.assertEqual(selection.ds, ds)
        self.assertEqual(selection.rust, rust)
        self.assertEqual(selection.windows, windows)

    def test_docs_outside_interaction_inputs_select_no_lane(self):
        self.assert_lanes(
            ["README.md", "docs/README.md"],
            swift=False,
            app=False,
            ds=False,
        )

    def test_pr_2598_acceptance_records_select_no_lane(self):
        self.assert_lanes([
            "docs/design/cross-platform/windows-phase-a-runbook.md",
            "docs/design/cross-platform/windows-remaining.md",
            "docs/design/references/v1.6-goal/gj-headless-rerun-2026-10-06-windows.json",
            "openspec/changes/chg-2026-074-shared-rust-runtime-core/evidence/runs/TASK-XPA-006/windows-gj1-2026-10-06-run.md",
            "openspec/changes/chg-2026-074-shared-rust-runtime-core/evidence/runs/TASK-XPA-011/windows-workspace-publication-delivery-20261006-run.md",
            "openspec/changes/chg-2026-074-shared-rust-runtime-core/evidence/runs/TASK-XPA-011/windows-workspace-session-publication-20261006-run.md",
            "openspec/changes/chg-2026-074-shared-rust-runtime-core/evidence/windows-remaining.md",
        ], swift=False, app=False, ds=False)

    def test_interaction_inventory_and_direct_design_reads_remain_selected(self):
        root = SCRIPT.resolve().parents[2]
        coverage = json.loads((root / "docs/design/implementation-coverage.json").read_text())
        inputs = coverage["designInputs"] + coverage["previewFiles"]
        for test in (root / PLAN.DS_PACKAGE_DIR / "scripts").glob("*interactions.test.mjs"):
            inputs.extend(re.findall(r"read\(['\"](docs/design/[^'\"]+)['\"]\)", test.read_text()))
        inputs.extend([
            "docs/design/arkdeck-ds/new-input.tsx",
            "Catalog/operations/new-operation.json",
            "ArkDeck.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved",
        ])
        for path in inputs:
            with self.subTest(path=path):
                self.assertTrue(PLAN.classify_paths([path]).ds)

    def test_design_docs_run_ds_lane_without_compiled_lanes(self):
        for path in (
            "docs/design/prototype.html",
            "docs/design/implementation-coverage.json",
            "docs/design/arkdeck-ds/scripts/workspace-interactions.test.mjs",
            "docs/design/arkdeck-ds/package.json",
        ):
            with self.subTest(path=path):
                self.assert_lanes([path], swift=False, app=False, ds=True)

    def test_package_tests_run_swift_without_rebuilding_app(self):
        self.assert_lanes(
            ["Packages/ArkDeckKit/Tests/ArkDeckCoreTests/SHA256HexTests.swift"],
            swift=True,
            app=False,
            ds=True,
        )

    def test_app_package_target_sources_run_both_composition_lanes(self):
        for target in (
            "ArkDeckClientKit",
            "ArkDeckCore",
            "ArkDeckTraceAdapter",
        ):
            with self.subTest(target=target):
                self.assert_lanes(
                    [f"Packages/ArkDeckKit/Sources/{target}/Example.swift"],
                    swift=True,
                    app=True,
                    ds=True,
                )

    def test_non_app_package_targets_skip_redundant_xcode_lane(self):
        for path in (
            "Packages/ArkDeckKit/Tests/ArkDeckFakeHDCFixture/main.swift",
            "Packages/ArkDeckKit/LaunchAgents/README.md",
        ):
            with self.subTest(path=path):
                self.assert_lanes([path], swift=True, app=False, ds=True)

    def test_package_manifest_runs_both_composition_lanes(self):
        for path in (
            "Packages/ArkDeckKit/Package.swift",
            "Packages/ArkDeckKit/Package.resolved",
        ):
            with self.subTest(path=path):
                self.assert_lanes([path], swift=True, app=True, ds=True)

    def test_app_and_ui_tests_run_xcode_and_ds_lanes(self):
        # The ds half is the PR #1606 regression pin: an ArkDeckApp-only diff
        # merged all-green while breaking two @arkdeck/ds interaction tests,
        # because no lane ran the suite that reads these sources.
        self.assert_lanes(
            ["ArkDeckApp/Features/Flash/FlashWorkspaceView.swift"],
            swift=False,
            app=True,
            ds=True,
        )
        self.assert_lanes(
            ["ArkDeckAppUITests/AppShell/AppShellUITests.swift"],
            swift=False,
            app=True,
            ds=True,
        )

    def test_xcode_project_changes_skip_uninvolved_lanes(self):
        self.assert_lanes(
            ["ArkDeck.xcodeproj/project.pbxproj"], swift=False, app=True, ds=False
        )

    def test_planner_and_workflow_changes_cannot_self_skip(self):
        for path in (
            "scripts/ci/plan.py",
            "scripts/ci/test_plan.py",
            "scripts/test_agent_pr_workflow.py",
            ".github/workflows/swift-ci.yml",
            ".github/workflows/rust-ci.yml",
        ):
            with self.subTest(path=path):
                self.assert_lanes(
                    [path], swift=True, app=True, ds=True, rust=True, windows=True
                )

    def test_rust_and_contract_inputs_select_rust_without_unrelated_lanes(self):
        for path in (
            "rust/Cargo.toml",
            "rust/Cargo.lock",
            "rust/rust-toolchain.toml",
            "rust/crates/arkdeck-contract/src/lib.rs",
            "rust/deny.toml",
            "rust/supply-chain/imports.lock",
            r"rust\crates\arkdeck-control\src\lib.rs",
        ):
            with self.subTest(path=path):
                self.assert_lanes([path], swift=False, app=False, ds=False, rust=True)
        # The method schemas are also ClientKit generator inputs.
        self.assert_lanes(
            ["spec/control/methods/doctor.json"],
            swift=False, app=False, ds=False, rust=True, windows=True,
        )

    def test_contract_schema_catalog_and_generator_only_changes_select_rust(self):
        # The contract schemas under openspec/contracts also select Swift:
        # test_every_bundle_contract_selects_rust_and_swift.
        for path in (
            "openspec/changes/chg-2026-059-arkdeck-arkforge-authority/permit-vectors.md",
            "Catalog/operations/observe.device.json",
            "Catalog/profiles/default.json",
            "Catalog/generated/effect-authorization-matrix.md",
            "scripts/catalog_gen/generate.py",
        ):
            with self.subTest(path=path):
                self.assert_lanes(
                    [path], swift=False, app=False,
                    ds=path.startswith("Catalog/operations/"), rust=True,
                )

    def test_every_bundle_contract_selects_rust_and_swift(self):
        # Swift's export can rewrite any of them without touching rust/, the
        # Rust export's test holds each one, and so do Swift's contract tests.
        root = SCRIPT.resolve().parents[2]
        paths = sorted(
            path.relative_to(root).as_posix()
            for path in (root / "openspec/contracts").iterdir()
            if path.is_file()
        )
        self.assertIn("openspec/contracts/app-product-capability-registry.yaml", paths)
        self.assertIn("openspec/contracts/cli-feature-coverage.json", paths)
        for path in paths + ["openspec/contracts/a-future-product.json"]:
            with self.subTest(path=path):
                # The Windows App's tests also read the CLI coverage commands.
                self.assert_lanes(
                    [path], swift=True, app=False, ds=False, rust=True,
                    windows=path == "openspec/contracts/cli-feature-coverage.json",
                )

    def test_source_only_canonical_control_and_journal_changes_select_rust(self):
        for name in (
            "ArkDeckCore/PortableCanonicalJSON.swift",
            "ArkDeckCore/CanonicalCBOR.swift",
            "ArkDeckCore/CanonicalDigests.swift",
            "ArkDeckCore/ControlProtocolGenerated.swift",
            "ArkDeckCore/ControlProtocolContract.swift",
            "ArkDeckCore/ControlFrameJSON.swift",
        ):
            path = f"Packages/ArkDeckKit/Sources/{name}"
            with self.subTest(path=path):
                self.assert_lanes([path], swift=True, app=True, ds=True, rust=True)

    def test_control_producer_and_fixture_only_changes_select_rust_without_app(self):
        for path in (
            "Packages/ArkDeckKit/Scripts/generate-control-contract.py",
            "Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/HDC/Golden/1.0.0/registry.json",
            "Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/CLI/argv/doctor.json",
        ):
            with self.subTest(path=path):
                self.assert_lanes([path], swift=True, app=False, ds=True, rust=True)
        # The registry and the recorded frames are ClientKit inputs as well.
        for path in (
            "Packages/ArkDeckKit/Contracts/control-protocol.json",
            "Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ControlFrames/job.show.jsonl",
        ):
            with self.subTest(path=path):
                self.assert_lanes(
                    [path], swift=True, app=False, ds=True, rust=True, windows=True
                )

    def test_windows_client_changes_select_only_the_windows_lane(self):
        for path in (
            "windows/ArkDeck.Windows.slnx",
            "windows/ClientKit/ControlClient.cs",
            "windows/ClientKit.Tests/ClientTests.cs",
            "windows/scripts/generate-clientkit.py",
            "windows/spikes/spk4/ArkDeck.Spk4/App.xaml",
            "windows/README.md",
            r"windows\ClientKit\Json\StrictJson.cs",
        ):
            with self.subTest(path=path):
                self.assert_lanes([path], swift=False, app=False, ds=False, windows=True)

    def test_every_windows_generator_and_test_input_selects_windows(self):
        root = SCRIPT.resolve().parents[2]
        declared = []
        for script in ("generate-clientkit.py", "generate-ui-strings.py", "generate-xaml-tokens.py", "generate-app-icons.py"):
            spec = importlib.util.spec_from_file_location(
                "arkdeck_windows_" + script.replace("-", "_")[:-3], root / "windows/scripts" / script
            )
            assert spec is not None and spec.loader is not None
            generator = importlib.util.module_from_spec(spec)
            sys.modules[spec.name] = generator
            spec.loader.exec_module(generator)
            with self.subTest(generator=script):
                self.assertTrue(generator.INPUTS)
            declared.extend(generator.INPUTS)
        # The tests also read the recorded corpus, the UIA semantic snapshots, the
        # Job state classes and the CLI coverage commands; the end-to-end tests
        # sign their daemon copy with the development identity script.
        declared += [
            "Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ControlFrames",
            "spec/ui-semantics",
            "spec/recovery/job-state-preflight.json",
            "openspec/contracts/cli-feature-coverage.json",
            "rust/scripts/windows-dev-identity.ps1",
            "rust/tests/fixtures/trace-inspect",
            "rust/tests/fixtures/target-adoption",
            "rust/tests/fixtures/flash-archive",
            "rust/tests/fixtures/trace-probe",
            "rust/tests/fixtures/ui-dump-inspect",
            "rust/tests/fixtures/agent-human-action",
            "rust/tests/fixtures/debug-probe",
            "rust/tests/fixtures/observe-device",
            "rust/tests/fixtures/import-upload-current",
            "rust/tests/fixtures/diagnostics-inspect",
            "rust/tests/fixtures/job-run-hilog",
            "rust/tests/fixtures/hilog-summary-analyzer",
            "Catalog/operations/capture.diagnostics.v1.json",
            "Catalog/operations/analyzer.summarize-hilog.v1.json",
            "Packages/ArkDeckKit/Sources/ArkDeckCore/FlashReviewCatalogGenerated.swift",
        ]
        for path in declared:
            source = root / path
            if source.is_dir():
                inputs = [file.relative_to(root).as_posix() for file in source.rglob("*") if file.is_file()]
                inputs.append(f"{path}/new-contract-input.json")
            else:
                self.assertTrue(source.is_file(), path)
                inputs = [path]
            for candidate in inputs:
                with self.subTest(input=path, changed_path=candidate):
                    self.assertTrue(PLAN.classify_paths([candidate]).windows)

    def test_device_shared_strings_select_the_windows_consumer_lane(self):
        self.assert_lanes(
            ["ArkDeckApp/Resources/DeviceLocalizable.xcstrings"],
            swift=False, app=True, ds=True, windows=True,
        )

    def test_unrelated_sources_do_not_select_windows(self):
        for path in (
            "rust/crates/arkdeck-contract/src/lib.rs",
            "rust/scripts/check-readonly.py",
            "spec/recovery/README.md",
            "docs/design/cross-platform/windows-phase-agent-prompt.md",
            "docs/design/arkdeck-ds/src/styles.css",
            "Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/HDC/Golden/1.0.0/registry.json",
        ):
            with self.subTest(path=path):
                self.assertFalse(PLAN.classify_paths([path]).windows)

    def test_helper_packaging_changes_select_the_rust_lane_that_checks_them(self):
        # The unsigned structure check of the Rust helper pair runs in the
        # Rust macOS workspace job; Swift's contract tests pin the release
        # script, so Swift stays selected as for any package path.
        for path in (
            "Packages/ArkDeckKit/Distribution/macOS/check-rust-helpers.py",
            "Packages/ArkDeckKit/Distribution/macOS/build-helpers.sh",
            "Packages/ArkDeckKit/Distribution/macOS/build-unsigned-rust-helpers.sh",
            "Packages/ArkDeckKit/Distribution/macOS/package-rust-helpers.sh",
            "Packages/ArkDeckKit/Resources/OpenHarmonyNativeCodeSign/arkdeck-code-sign-enable",
            "Packages/ArkDeckKit/Distribution/macOS/ArkDeckAgent.entitlements",
        ):
            with self.subTest(path=path):
                self.assert_lanes([path], swift=True, app=False, ds=True, rust=True)

    def test_release_pipeline_changes_select_the_rust_lane_that_tests_them(self):
        for path in (
            "scripts/release/build_macos_release.py",
            "scripts/release/test_build_macos_release.py",
            "scripts/release/release-version.json",
        ):
            with self.subTest(path=path):
                self.assert_lanes([path], swift=False, app=False, ds=False, rust=True)

    def test_every_declared_generator_input_selects_rust(self):
        root = SCRIPT.resolve().parents[2]
        spec = importlib.util.spec_from_file_location(
            "arkdeck_rust_contract_generator", root / "rust/scripts/generate-contract.py"
        )
        assert spec is not None and spec.loader is not None
        generator = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = generator
        spec.loader.exec_module(generator)
        self.assertTrue(generator.INPUTS)
        for path in generator.INPUTS:
            source = root / path
            if source.is_dir():
                inputs = [str(file.relative_to(root)) for file in source.rglob("*") if file.is_file()]
                # A newly added member of a declared directory must select the
                # lane too, without waiting for a baseline manifest refresh.
                inputs.append(f"{path}/new-contract-input.json")
            else:
                inputs = [path]
            for candidate in inputs:
                with self.subTest(input=path, changed_path=candidate):
                    self.assertTrue(PLAN.classify_paths([candidate]).rust)


class LightweightGateTests(unittest.TestCase):
    def test_compiled_output_covers_every_lane_combination(self):
        for flags in itertools.product((False, True), repeat=5):
            with self.subTest(flags=flags), tempfile.TemporaryDirectory() as directory:
                lanes = PLAN.LaneSelection(*flags)
                expected = any((lanes.swift, lanes.app, lanes.rust, lanes.windows))
                plan = PLAN.CIPlan(lanes, "0" * 40, "1" * 40, "test", "test", ())
                output = pathlib.Path(directory) / "output"
                PLAN._append_github_output(output, plan)
                self.assertIs(plan.as_dict()["compiled"], expected)
                self.assertIn(f"compiled={str(expected).lower()}\n", output.read_text())

    def test_actual_gate_skips_only_successful_lightweight_plan(self):
        workflow = (SCRIPT.resolve().parents[2] / ".github/workflows/swift-ci.yml").read_text()
        condition = re.search(r"^  swift:\n    if: (.+)$", workflow, re.M)[1]
        for result in ("success", "failure", "cancelled", "skipped", ""):
            for compiled in ("false", "true", "", "unknown"):
                with self.subTest(result=result, compiled=compiled):
                    # Evaluate the checked-in predicate with actual needs facts,
                    # rather than maintaining a second copy of its expression.
                    expression = condition.replace("needs.plan.result", repr(result))
                    expression = expression.replace("needs.plan.outputs.compiled", repr(compiled))
                    expression = expression.replace("always()", "True").replace("&&", "and").replace("||", "or")
                    runs = eval(expression, {"__builtins__": {}}, {})
                    self.assertEqual(runs, (result, compiled) != ("success", "false"))

    def test_actual_aggregate_rejects_failed_or_unexpectedly_skipped_lanes(self):
        workflow = (SCRIPT.resolve().parents[2] / ".github/workflows/swift-ci.yml").read_text()
        step = workflow.split("      - name: Require every selected lane\n", 1)[1]
        script = textwrap.dedent(step.split("        run: |\n", 1)[1].split("      - name:", 1)[0])
        baseline = {"PLAN_RESULT": "success"}
        for lane in ("SWIFT", "APP", "RUST", "WINDOWS"):
            baseline[f"{lane}_SELECTED"] = "false"
            baseline[f"{lane}_RESULT"] = "skipped"
        cases = [(baseline, True)]
        for result in ("failure", "cancelled", "skipped", ""):
            cases.append((baseline | {"PLAN_RESULT": result}, False))
        for lane in ("SWIFT", "APP", "RUST", "WINDOWS"):
            for selected in ("true", "false"):
                for result in ("success", "failure", "cancelled", "skipped"):
                    facts = baseline | {f"{lane}_SELECTED": selected, f"{lane}_RESULT": result}
                    cases.append((facts, result == ("success" if selected == "true" else "skipped")))
        for facts, passes in cases:
            with self.subTest(facts=facts):
                result = subprocess.run(["sh", "-c", script], env=os.environ | facts, capture_output=True)
                self.assertEqual(result.returncode == 0, passes, result.stderr)


class GitPlanTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temporary.name)
        self.git("init", "-q")
        self.git("config", "user.email", "ci@example.invalid")
        self.git("config", "user.name", "CI Test")
        (self.root / "README.md").write_text("base\n", encoding="utf-8")
        self.git("add", "README.md")
        self.git("commit", "-qm", "base")
        self.base = self.oid("HEAD")
        self.git("branch", "-M", "main")
        self.git("update-ref", "refs/remotes/origin/main", self.base)

    def tearDown(self):
        self.temporary.cleanup()

    def git(self, *arguments: str) -> str:
        return subprocess.run(
            ["git", *arguments],
            cwd=self.root,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        ).stdout.strip()

    def oid(self, revision: str) -> str:
        return self.git("rev-parse", revision)

    def commit_file(self, path: str, contents: str) -> str:
        target = self.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(contents, encoding="utf-8")
        self.git("add", path)
        self.git("commit", "-qm", f"change {path}")
        return self.oid("HEAD")

    def event(self, *, before: str, after: str, ref: str) -> dict[str, str]:
        return {"before": before, "after": after, "ref": ref}

    def queue_event(self, head=None, base=None):
        return {"action": "checks_requested", "merge_group": {
            "head_sha": head or self.oid("HEAD"), "base_sha": base or self.base,
            "head_ref": "refs/heads/gh-readonly-queue/main/pr-23",
            "base_ref": "refs/heads/main",
        }}

    def test_merge_group_covers_all_queued_changes_after_main_advances(self):
        lower = self.commit_file("Packages/ArkDeckKit/Tests/Lower.swift", "lower")
        head = self.commit_file("rust/crates/upper.rs", "upper")
        self.git("update-ref", "refs/remotes/origin/main", lower)
        result = PLAN.plan_from_event(self.root, self.queue_event())
        self.assertEqual(result.base_revision, self.base)
        self.assertEqual(result.head_revision, head)
        self.assertTrue(result.lanes.swift)
        self.assertTrue(result.lanes.rust)
        self.assertEqual(set(result.changed_files), {
            "Packages/ArkDeckKit/Tests/Lower.swift", "rust/crates/upper.rs"})

    def test_merge_group_docs_only_selects_no_compiled_lane(self):
        self.commit_file("docs/example.md", "docs")
        result = PLAN.plan_from_event(self.root, self.queue_event(), last_success="f" * 40)
        self.assertEqual(result.lanes, PLAN.LaneSelection(False, False, False, False, False))

    def test_merge_group_missing_base_selects_every_lane(self):
        self.commit_file("docs/example.md", "docs")
        for base in (None, "f" * 40, "HEAD~1", "0" * 40):
            with self.subTest(base=base):
                event = self.queue_event()
                event["merge_group"]["base_sha"] = base
                result = PLAN.plan_from_event(self.root, event)
                self.assertEqual(result.lanes, PLAN.LaneSelection(True, True, True, True, True))

    def test_merge_group_rejects_wrong_head_action_or_branch(self):
        self.commit_file("docs/example.md", "docs")
        for key, value in (("head_sha", self.base), ("head_sha", "HEAD"),
                           ("base_ref", "refs/heads/other"), ("head_ref", "refs/heads/agent/example")):
            with self.subTest(key=key, value=value):
                event = self.queue_event()
                event["merge_group"][key] = value
                with self.assertRaises(PLAN.PlanError):
                    PLAN.plan_from_event(self.root, event)
        event = self.queue_event()
        event["action"] = "destroyed"
        with self.assertRaises(PLAN.PlanError):
            PLAN.plan_from_event(self.root, event)

    def test_merge_group_rejects_unrelated_base(self):
        head = self.commit_file("docs/example.md", "docs")
        self.git("checkout", "--orphan", "unrelated")
        other = self.commit_file("other.md", "other")
        self.git("checkout", "--detach", head)
        with self.assertRaisesRegex(PLAN.PlanError, "not an ancestor"):
            PLAN.plan_from_event(self.root, self.queue_event(base=other))

    def test_cli_dispatches_merge_group_event(self):
        self.commit_file("docs/example.md", "docs")
        event_path = self.root / "queue.json"
        event_path.write_text(json.dumps(self.queue_event()))
        with mock.patch("sys.stdout"):
            self.assertEqual(PLAN.main(["--repo-root", str(self.root), "--event", str(event_path)]), 0)

    def test_first_agent_push_uses_origin_main_instead_of_all_zero_before(self):
        self.git("switch", "-qc", "agent/docs")
        head = self.commit_file("docs/note.md", "docs\n")
        plan = PLAN.plan_from_push_event(
            self.root,
            self.event(before=PLAN.ZERO_OID, after=head, ref="refs/heads/agent/docs"),
        )
        self.assertEqual(plan.base_revision, self.base)
        self.assertEqual(plan.base_kind, "origin-main-merge-base")
        self.assertFalse(plan.lanes.swift)
        self.assertFalse(plan.lanes.app)
        self.assertFalse(plan.lanes.ds)

    def test_agent_plan_is_cumulative_against_main(self):
        self.git("switch", "-qc", "agent/package")
        first = self.commit_file(
            "Packages/ArkDeckKit/Tests/ExampleTests.swift", "// test\n"
        )
        head = self.commit_file("docs/note.md", "docs\n")
        plan = PLAN.plan_from_push_event(
            self.root,
            self.event(before=first, after=head, ref="refs/heads/agent/package"),
        )
        self.assertTrue(plan.lanes.swift)
        self.assertFalse(plan.lanes.app)
        self.assertTrue(plan.lanes.ds)

    def main_plan(self, *, before: str, after: str, last_success: str | None):
        return PLAN.plan_from_push_event(
            self.root,
            self.event(before=before, after=after, ref="refs/heads/main"),
            last_success=last_success,
        )

    def test_main_push_after_a_green_run_plans_its_own_push(self):
        head = self.commit_file("docs/note.md", "docs\n")
        plan = self.main_plan(before=self.base, after=head, last_success=self.base)
        self.assertEqual(plan.base_revision, self.base)
        self.assertEqual(plan.base_kind, "main-last-success")
        self.assertFalse(plan.lanes.swift)
        self.assertFalse(plan.lanes.app)
        self.assertFalse(plan.lanes.ds)
        self.assertFalse(plan.lanes.rust)

    def test_main_push_covers_every_commit_since_the_last_green_run(self):
        # 2026-09-14: #1903's run waited behind #1904's and GitHub replaced it
        # with #1905's, one pending run per concurrency group. #1905's run then
        # planned 99dda729..6cf99fb6 and never looked at #1903's files. A red
        # run leaves the same hole; the last green commit closes both.
        source = "Packages/ArkDeckKit/Sources/ArkDeckCore/Example.swift"
        unvalidated = self.commit_file(source, "// swift\n")
        head = self.commit_file("docs/note.md", "docs\n")
        own_push = PLAN.plan_between(
            self.root, base_revision=unvalidated, head_revision=head, use_merge_base=False
        )
        self.assertFalse(own_push.lanes.swift)
        plan = self.main_plan(before=unvalidated, after=head, last_success=self.base)
        self.assertEqual(plan.base_revision, self.base)
        self.assertEqual(plan.base_kind, "main-last-success")
        self.assertIn(source, plan.changed_files)
        self.assertTrue(plan.lanes.swift)
        self.assertTrue(plan.lanes.app)
        self.assertTrue(plan.lanes.ds)

    def test_main_push_without_a_usable_last_success_runs_every_lane(self):
        head = self.commit_file("docs/note.md", "docs\n")
        for last_success in (None, "", "HEAD", "main", self.base[:12], self.base.upper(),
                             "f" * 40):
            with self.subTest(last_success=last_success):
                plan = self.main_plan(before=self.base, after=head, last_success=last_success)
                self.assertEqual(plan.reason, "main-last-success-unavailable-fail-closed")
                self.assertTrue(plan.lanes.swift)
                self.assertTrue(plan.lanes.app)
                self.assertTrue(plan.lanes.ds)
                self.assertTrue(plan.lanes.rust)

    def test_main_last_success_must_precede_the_push(self):
        self.git("switch", "-qc", "side")
        elsewhere = self.commit_file("docs/side.md", "side\n")
        self.git("switch", "-q", "main")
        head = self.commit_file("docs/note.md", "docs\n")
        plan = self.main_plan(before=self.base, after=head, last_success=elsewhere)
        self.assertEqual(plan.reason, "main-last-success-not-behind-push-fail-closed")
        self.assertTrue(plan.lanes.swift)
        self.assertTrue(plan.lanes.rust)

    def test_rerun_of_a_passed_main_commit_rechecks_its_own_push(self):
        head = self.commit_file("rust/crates/arkdeck-contract/src/lib.rs", "// Rust\n")
        plan = self.main_plan(before=self.base, after=head, last_success=head)
        self.assertEqual(plan.base_revision, self.base)
        self.assertEqual(plan.base_kind, "push-before")
        self.assertTrue(plan.lanes.rust)
        self.assertFalse(plan.lanes.swift)

    def test_agent_push_ignores_the_main_last_success(self):
        self.git("switch", "-qc", "agent/docs")
        head = self.commit_file("docs/note.md", "docs\n")
        event = self.event(before=PLAN.ZERO_OID, after=head, ref="refs/heads/agent/docs")
        self.assertEqual(
            PLAN.plan_from_push_event(self.root, event, last_success=None),
            PLAN.plan_from_push_event(self.root, event, last_success="f" * 40),
        )

    def test_cli_hands_the_main_last_success_to_the_plan(self):
        head = self.commit_file("docs/note.md", "docs\n")
        event_path = self.root / "event.json"
        event_path.write_text(
            f'{{"before": "{self.base}", "after": "{head}", "ref": "refs/heads/main"}}',
            encoding="utf-8",
        )
        output = self.root / "github-output"
        arguments = ["--repo-root", str(self.root), "--event", str(event_path),
                     "--github-output", str(output)]
        with mock.patch("sys.stdout"):
            status = PLAN.main([*arguments, "--main-last-success", self.base])
        self.assertEqual(status, 0)
        values = dict(line.split("=", 1) for line in output.read_text(encoding="utf-8").splitlines())
        self.assertEqual(values["base"], self.base)
        self.assertEqual(values["base-kind"], "main-last-success")
        # The workflow passes an empty value off main and when the lookup fails.
        output.unlink()
        with mock.patch("sys.stdout"):
            self.assertEqual(PLAN.main([*arguments, "--main-last-success", ""]), 0)
        values = dict(line.split("=", 1) for line in output.read_text(encoding="utf-8").splitlines())
        self.assertEqual(values["reason"], "main-last-success-unavailable-fail-closed")
        with mock.patch("sys.stderr"):
            self.assertEqual(
                PLAN.main(["--repo-root", str(self.root), "--base-revision", self.base,
                           "--main-last-success", self.base]),
                1,
            )

    def test_missing_main_before_runs_every_lane(self):
        plan = PLAN.plan_from_push_event(
            self.root,
            self.event(before=PLAN.ZERO_OID, after=self.base, ref="refs/heads/main"),
        )
        self.assertTrue(plan.lanes.swift)
        self.assertTrue(plan.lanes.app)
        self.assertTrue(plan.lanes.ds)
        self.assertEqual(plan.reason, "main-before-unavailable-fail-closed")
        self.assertTrue(plan.lanes.rust)

    def test_missing_agent_main_runs_every_lane(self):
        self.git("update-ref", "-d", "refs/remotes/origin/main")
        self.git("switch", "-qc", "agent/docs")
        head = self.commit_file("docs/note.md", "docs\n")
        plan = PLAN.plan_from_push_event(
            self.root,
            self.event(before=PLAN.ZERO_OID, after=head, ref="refs/heads/agent/docs"),
        )
        self.assertTrue(plan.lanes.swift)
        self.assertTrue(plan.lanes.app)
        self.assertTrue(plan.lanes.ds)
        self.assertEqual(plan.reason, "base-unavailable-fail-closed")
        self.assertTrue(plan.lanes.rust)

    def test_rust_only_agent_push_cannot_select_no_compiled_lane(self):
        self.git("switch", "-qc", "agent/rust")
        head = self.commit_file("rust/crates/arkdeck-contract/src/lib.rs", "// Rust\n")
        plan = PLAN.plan_from_push_event(
            self.root,
            self.event(before=PLAN.ZERO_OID, after=head, ref="refs/heads/agent/rust"),
        )
        self.assertTrue(plan.lanes.rust)
        self.assertFalse(plan.lanes.swift)
        self.assertFalse(plan.lanes.app)
        self.assertFalse(plan.lanes.ds)
        output = self.root / "github-output"
        PLAN._append_github_output(output, plan)
        self.assertIn("rust=true\n", output.read_text(encoding="utf-8"))
        self.assertIs(plan.as_dict()["rust"], True)

    def test_windows_only_agent_push_selects_the_windows_lane(self):
        self.git("switch", "-qc", "agent/windows")
        head = self.commit_file("windows/ClientKit/ControlClient.cs", "// C#\n")
        plan = PLAN.plan_from_push_event(
            self.root,
            self.event(before=PLAN.ZERO_OID, after=head, ref="refs/heads/agent/windows"),
        )
        self.assertTrue(plan.lanes.windows)
        self.assertFalse(plan.lanes.swift)
        self.assertFalse(plan.lanes.app)
        self.assertFalse(plan.lanes.ds)
        self.assertFalse(plan.lanes.rust)
        output = self.root / "github-output"
        PLAN._append_github_output(output, plan)
        self.assertIn("windows=true\n", output.read_text(encoding="utf-8"))
        self.assertIs(plan.as_dict()["windows"], True)

    def test_removing_rust_source_still_selects_rust(self):
        self.git("switch", "-qc", "agent/remove-rust")
        source = "rust/crates/arkdeck-contract/src/lib.rs"
        base = self.commit_file(source, "// Rust\n")
        self.git("rm", source)
        self.git("commit", "-qm", "remove Rust source")
        plan = PLAN.plan_between(
            self.root, base_revision=base, head_revision="HEAD", use_merge_base=False
        )
        self.assertIn(source, plan.changed_files)
        self.assertTrue(plan.lanes.rust)

    def test_cross_surface_rename_reports_removed_swift_path(self):
        self.git("switch", "-qc", "agent/rename")
        source = "Packages/ArkDeckKit/Sources/ArkDeckCore/Old.swift"
        self.commit_file(source, "// source\n")
        self.git("update-ref", "refs/remotes/origin/main", "HEAD")
        base = self.oid("HEAD")
        (self.root / "docs").mkdir(exist_ok=True)
        self.git("mv", source, "docs/Old.swift")
        self.git("commit", "-qm", "move source")
        plan = PLAN.plan_between(
            self.root,
            base_revision=base,
            head_revision="HEAD",
            use_merge_base=False,
        )
        self.assertIn(source, plan.changed_files)
        self.assertTrue(plan.lanes.swift)
        self.assertTrue(plan.lanes.app)
        self.assertTrue(plan.lanes.ds)

    def test_event_head_must_match_checkout(self):
        with self.assertRaises(PLAN.PlanError):
            PLAN.plan_from_push_event(
                self.root,
                self.event(before=self.base, after="1" * 40, ref="refs/heads/main"),
            )

    def test_local_plan_includes_tracked_and_untracked_worktree_changes(self):
        (self.root / "ArkDeckApp" / "App").mkdir(parents=True)
        (self.root / "ArkDeckApp" / "App" / "New.swift").write_text(
            "// app\n", encoding="utf-8"
        )
        (self.root / "README.md").write_text("edited\n", encoding="utf-8")
        plan = PLAN.plan_between(
            self.root,
            base_revision=self.base,
            head_revision="HEAD",
            use_merge_base=False,
            include_worktree=True,
        )
        self.assertIn("ArkDeckApp/App/New.swift", plan.changed_files)
        self.assertIn("README.md", plan.changed_files)
        self.assertFalse(plan.lanes.swift)
        self.assertTrue(plan.lanes.app)
        self.assertTrue(plan.lanes.ds)
        self.assertEqual(plan.reason, "classified-changed-files-and-worktree")


class CommandSelectionTests(unittest.TestCase):
    def plan(
        self, *, swift: bool, app: bool, ds: bool = False, rust: bool = False, windows: bool = False
    ):
        return PLAN.CIPlan(
            lanes=PLAN.LaneSelection(swift=swift, app=app, ds=ds, rust=rust, windows=windows),
            base_revision="0" * 40,
            head_revision="1" * 40,
            base_kind="test",
            reason="test",
            changed_files=(),
        )

    def commands(self, plan) -> list[str]:
        with tempfile.TemporaryDirectory() as directory:
            selected = PLAN.local_commands(pathlib.Path(directory), plan)
        return [" ".join(command) for command in selected]

    def test_docs_plan_has_no_compiled_or_npm_command(self):
        flattened = "\n".join(self.commands(self.plan(swift=False, app=False)))
        self.assertNotIn("run-test-lane.sh", flattened)
        self.assertNotIn("xcodebuild", flattened)
        self.assertNotIn("npm", flattened)
        self.assertNotIn("cargo", flattened)
        self.assertNotIn("dotnet", flattened)

    def test_test_only_plan_runs_swift_but_not_app(self):
        flattened = "\n".join(self.commands(self.plan(swift=True, app=False)))
        self.assertIn("generate-clientkit-models.py --check", flattened)
        self.assertIn("test_generate_clientkit_models.py", flattened)
        self.assertIn("run-test-lane.sh full", flattened)
        self.assertNotIn("xcodebuild", flattened)

    def test_app_plan_builds_for_testing(self):
        flattened = "\n".join(self.commands(self.plan(swift=False, app=True)))
        self.assertIn("scripts/ci/test_run_xcodebuild.py", flattened)
        self.assertIn("sh scripts/ci/run-xcodebuild.sh", flattened)

    def test_ds_plan_installs_exact_dependencies_before_testing(self):
        commands = self.commands(self.plan(swift=False, app=False, ds=True))
        install = commands.index("npm --prefix docs/design/arkdeck-ds ci")
        run = commands.index("npm --prefix docs/design/arkdeck-ds test")
        self.assertLess(install, run)
        flattened = "\n".join(commands)
        self.assertNotIn("run-test-lane.sh", flattened)
        self.assertNotIn("xcodebuild", flattened)

    def test_rust_plan_checks_locked_workspace_and_dependency_policy(self):
        commands = self.commands(self.plan(swift=False, app=False, rust=True))
        rust_commands = [command for command in commands if command.startswith("cargo ")]
        self.assertEqual(rust_commands, [
            "cargo fmt --all --check",
            "cargo fetch --locked",
            # Nothing else in the lane compiles the checkout: the contract
            # scripts read Git objects at the pinned Swift commit or build
            # their own candidate view, so a red workspace passed the lane.
            "cargo clippy --workspace --all-targets -- -D warnings",
            "cargo deny --locked check",
            "cargo vet --locked --no-registry-suggestions",
        ])
        generator = commands.index(
            f"{sys.executable} rust/scripts/generate-contract.py --check"
        )
        self.assertLess(generator, commands.index("cargo fmt --all --check"))
        regressions = commands.index(f"{sys.executable} rust/scripts/test_contract_checks.py")
        execution_regressions = commands.index(f"{sys.executable} rust/scripts/test_ci_execution.py")
        parity = commands.index(f"{sys.executable} rust/scripts/check-contracts.py")
        fetch = commands.index("cargo fetch --locked")
        clippy = commands.index("cargo clippy --workspace --all-targets -- -D warnings")
        workspace_tests = commands.index(
            f"{sys.executable} rust/scripts/workspace-tests.py"
        )
        self.assertLess(fetch, clippy)
        self.assertLess(clippy, workspace_tests)
        self.assertLess(workspace_tests, regressions)
        self.assertLess(regressions, execution_regressions)
        view_guards = [commands.index(f"{sys.executable} rust/scripts/{name}") for name in (
            "test_catalog_test_views.py", "test_catalog_execution.py", "test_historical_catalog_views.py")]
        self.assertLess(execution_regressions, view_guards[0])
        self.assertLess(view_guards[0], view_guards[1])
        self.assertLess(view_guards[1], view_guards[2])
        self.assertLess(view_guards[2], parity)
        self.assertLess(parity, commands.index("cargo deny --locked check"))
        self.assertNotIn(f"{sys.executable} rust/scripts/check-readonly.py", commands)
        self.assertNotIn("xcodebuild", "\n".join(commands))

    def test_rust_commands_use_the_chat_cache_runner(self):
        root = pathlib.Path("/example/ArkDeck").resolve()
        commands = (("python3", "scripts/ci/test_plan.py"), ("cargo", "fmt", "--check"),
                    ("python3", "rust/scripts/check-contracts.py"))
        with mock.patch.object(PLAN, "local_commands", return_value=commands):
            with mock.patch.object(PLAN.subprocess, "run") as run:
                PLAN.run_local(root, self.plan(swift=False, app=False, rust=True))
        self.assertEqual(
            [call.kwargs["cwd"] for call in run.call_args_list], [root, root, root]
        )
        runner = str(root / "rust/scripts/run-cargo.py")
        self.assertEqual(run.call_args_list[0].args[0], commands[0])
        self.assertEqual(run.call_args_list[1].args[0], (sys.executable, runner, "fmt", "--check"))
        self.assertEqual(run.call_args_list[2].args[0],
                         (sys.executable, runner, "exec", "--", *commands[2]))
        for call in run.call_args_list[1:]:
            self.assertEqual(call.kwargs["env"]["ARKDECK_CARGO_SOURCE_ROOT"], str(root))
        self.assertTrue(all(call.kwargs["check"] for call in run.call_args_list))

    def test_contract_or_dependency_policy_failure_cannot_pass_local_gate(self):
        for command in (
            (sys.executable, "rust/scripts/test_contract_checks.py"),
            (sys.executable, "rust/scripts/test_ci_execution.py"),
            (sys.executable, "rust/scripts/test_catalog_test_views.py"),
            (sys.executable, "rust/scripts/test_catalog_execution.py"),
            (sys.executable, "rust/scripts/test_historical_catalog_views.py"),
            (sys.executable, "rust/scripts/check-contracts.py"),
            ("cargo", "clippy", "--workspace", "--all-targets", "--", "-D", "warnings"),
            (sys.executable, "rust/scripts/workspace-tests.py"),
            ("cargo", "deny", "--locked", "check"),
            ("cargo", "vet", "--locked", "--no-registry-suggestions"),
        ):
            with self.subTest(command=command):
                with mock.patch.object(PLAN, "local_commands", return_value=(command,)):
                    with mock.patch.object(
                        PLAN.subprocess,
                        "run",
                        side_effect=subprocess.CalledProcessError(1, command),
                    ):
                        with self.assertRaises(subprocess.CalledProcessError):
                            PLAN.run_local(
                                pathlib.Path("/example/ArkDeck"),
                                self.plan(swift=False, app=False, rust=True),
                            )


class WindowsLaneTests(unittest.TestCase):
    """TASK-XPA-007: the windows lane builds and tests the ClientKit solution, and a
    host that cannot run it says so and fails instead of passing silently."""

    def plan(self, **lanes):
        selection = dict(swift=False, app=False, ds=False, rust=False, windows=False)
        selection.update(lanes)
        return PLAN.CIPlan(
            lanes=PLAN.LaneSelection(**selection),
            base_revision="0" * 40,
            head_revision="1" * 40,
            base_kind="test",
            reason="test",
            changed_files=(),
        )

    def test_windows_plan_checks_the_generator_then_builds_and_tests_the_solution(self):
        with tempfile.TemporaryDirectory() as directory:
            commands = [" ".join(c) for c in PLAN.local_commands(pathlib.Path(directory), self.plan(windows=True))]
        build = commands.index("dotnet build windows/ArkDeck.Windows.slnx -c Release")
        test = commands.index("dotnet test windows/ArkDeck.Windows.slnx -c Release --no-build")
        for script in ("generate-clientkit.py", "generate-ui-strings.py", "generate-xaml-tokens.py", "generate-app-icons.py"):
            with self.subTest(generator=script):
                generator = next(i for i, c in enumerate(commands) if c.endswith(f"windows/scripts/{script} --check"))
                self.assertLess(generator, build)
        self.assertLess(build, test)
        flattened = "\n".join(commands)
        self.assertNotIn("cargo", flattened)
        self.assertNotIn("xcodebuild", flattened)

    def test_windows_lane_is_not_runnable_elsewhere_and_fails_after_the_other_lanes(self):
        root = pathlib.Path("/example/ArkDeck")
        plan = self.plan(windows=True, rust=True)
        commands = (
            ("python3", "scripts/ci/test_plan.py"),
            ("cargo", "fmt", "--check"),
            ("python3", "windows/scripts/generate-clientkit.py", "--check"),
            ("dotnet", "build", "windows/ArkDeck.Windows.slnx", "-c", "Release"),
        )
        for system in ("Darwin", "Linux"):
            with self.subTest(system=system):
                with mock.patch.object(PLAN.platform, "system", return_value=system), \
                        mock.patch.object(PLAN, "local_commands", return_value=commands), \
                        mock.patch.object(PLAN.subprocess, "run") as run:
                    with self.assertRaisesRegex(PLAN.PlanError, "windows lane is not runnable on this host"):
                        PLAN.run_local(root, plan)
                ran = [call.args[0] for call in run.call_args_list]
                self.assertEqual(ran, [commands[0], (sys.executable,
                    str(root / "rust/scripts/run-cargo.py"), *commands[1][1:])])

    def test_windows_lane_runs_on_windows(self):
        commands = (
            ("python3", "windows/scripts/generate-clientkit.py", "--check"),
            ("dotnet", "test", "windows/ArkDeck.Windows.slnx", "-c", "Release", "--no-build"),
        )
        with mock.patch.object(PLAN.platform, "system", return_value="Windows"), \
                mock.patch.object(PLAN, "local_commands", return_value=commands), \
                mock.patch.object(PLAN.subprocess, "run") as run:
            PLAN.run_local(pathlib.Path("/example/ArkDeck"), self.plan(windows=True))
        self.assertEqual([call.args[0] for call in run.call_args_list], list(commands))

    def test_an_unselected_windows_lane_does_not_fail_other_hosts(self):
        with mock.patch.object(PLAN.platform, "system", return_value="Darwin"), \
                mock.patch.object(PLAN, "local_commands", return_value=(("python3", "x.py"),)), \
                mock.patch.object(PLAN.subprocess, "run") as run:
            PLAN.run_local(pathlib.Path("/example/ArkDeck"), self.plan(rust=True))
        self.assertEqual(run.call_count, 1)

    def test_run_local_exits_non_zero_when_the_windows_lane_cannot_run(self):
        plan = self.plan(windows=True)
        with mock.patch.object(PLAN.platform, "system", return_value="Darwin"), \
                mock.patch.object(PLAN, "plan_between", return_value=plan), \
                mock.patch.object(PLAN, "local_commands", return_value=()), \
                mock.patch("sys.stdout"), mock.patch("sys.stderr") as stderr:
            status = PLAN.main(["--base-revision", "HEAD~1", "--run-local"])
        self.assertEqual(status, 1)
        written = "".join(call.args[0] for call in stderr.write.call_args_list)
        self.assertIn("not runnable", written)


if __name__ == "__main__":
    unittest.main()
