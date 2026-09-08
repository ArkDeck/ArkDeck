#!/usr/bin/env python3
"""Contract tests for the shared local/GitHub CI planner."""

from __future__ import annotations

import importlib.util
import pathlib
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


SCRIPT = pathlib.Path(__file__).with_name("plan.py")
SPEC = importlib.util.spec_from_file_location("arkdeck_ci_plan", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
PLAN = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = PLAN
SPEC.loader.exec_module(PLAN)


class PathClassificationTests(unittest.TestCase):
    def assert_lanes(self, paths, *, swift: bool, app: bool, ds: bool, rust: bool = False):
        selection = PLAN.classify_paths(paths)
        self.assertEqual(selection.swift, swift)
        self.assertEqual(selection.app, app)
        self.assertEqual(selection.ds, ds)
        self.assertEqual(selection.rust, rust)

    def test_docs_and_previews_outside_design_select_no_lane(self):
        self.assert_lanes(
            ["README.md", "docs/README.md", ".design-sync/previews/Card.tsx"],
            swift=False,
            app=False,
            ds=False,
        )

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
            "ArkDeckCore",
            "ArkDeckProcess",
            "ArkDeckRuntime",
            "ArkDeckOpenHarmony",
            "ArkDeckWorkflows",
            "ArkDeckStorage",
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
            "Packages/ArkDeckKit/Sources/ArkDeckCLI/CLI.swift",
            "Packages/ArkDeckKit/Sources/ArkDeckAgentClient/Client.swift",
            "Packages/ArkDeckKit/Sources/ArkDeckAgentDaemon/Daemon.swift",
            "Packages/ArkDeckKit/Sources/ArkDeckAgentDaemonMain/main.swift",
            "Packages/ArkDeckKit/Sources/ArkDeckWorkflows/AgentComposition/Composition.swift",
            "Packages/ArkDeckKit/LaunchAgents/LaunchAgent.swift",
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
                self.assert_lanes([path], swift=True, app=True, ds=True, rust=True)

    def test_rust_and_contract_inputs_select_rust_without_unrelated_lanes(self):
        for path in (
            "rust/Cargo.toml",
            "rust/Cargo.lock",
            "rust/rust-toolchain.toml",
            "rust/crates/arkdeck-contract/src/lib.rs",
            "rust/deny.toml",
            "rust/supply-chain/imports.lock",
            "spec/control/methods/doctor.json",
            r"rust\crates\arkdeck-control\src\lib.rs",
        ):
            with self.subTest(path=path):
                self.assert_lanes([path], swift=False, app=False, ds=False, rust=True)

    def test_contract_schema_catalog_and_generator_only_changes_select_rust(self):
        for path in (
            "openspec/contracts/runtime-control-plane.schema.json",
            "openspec/contracts/cli-canonical-json-vectors.json",
            "openspec/contracts/cli-result.schema.json",
            "openspec/contracts/cli-error-registry.yaml",
            "openspec/contracts/journal-event.schema.json",
            "openspec/contracts/workflow-step.schema.json",
            "openspec/changes/chg-2026-059-arkdeck-arkforge-authority/permit-vectors.md",
            "Catalog/operations/observe.device.json",
            "Catalog/profiles/default.json",
            "Catalog/generated/effect-authorization-matrix.md",
            "scripts/catalog_gen/generate.py",
        ):
            with self.subTest(path=path):
                self.assert_lanes([path], swift=False, app=False, ds=False, rust=True)

    def test_source_only_canonical_control_and_journal_changes_select_rust(self):
        for name in (
            "ArkDeckCore/PortableCanonicalJSON.swift",
            "ArkDeckCore/CanonicalCBOR.swift",
            "ArkDeckCore/CanonicalDigests.swift",
            "ArkDeckCore/ControlProtocolGenerated.swift",
            "ArkDeckCore/ControlProtocolContract.swift",
            "ArkDeckCore/ControlFrameJSON.swift",
            "ArkDeckStorage/JournalEvent.swift",
            "ArkDeckStorage/JournalEventValidation.swift",
            "ArkDeckStorage/JournalReplay.swift",
        ):
            path = f"Packages/ArkDeckKit/Sources/{name}"
            with self.subTest(path=path):
                self.assert_lanes([path], swift=True, app=True, ds=True, rust=True)

    def test_control_producer_and_fixture_only_changes_select_rust_without_app(self):
        for path in (
            "Packages/ArkDeckKit/Contracts/control-protocol.json",
            "Packages/ArkDeckKit/Scripts/generate-control-contract.py",
            "Packages/ArkDeckKit/Sources/ArkDeckCLI/CLICanonicalJSON.swift",
            "Packages/ArkDeckKit/Sources/ArkDeckAgentDaemon/ControlFrameRecorder.swift",
            "Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ControlFrames/job.show.jsonl",
            "Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/HDC/Golden/1.0.0/registry.json",
            "Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/CLI/argv/doctor.json",
        ):
            with self.subTest(path=path):
                self.assert_lanes([path], swift=True, app=False, ds=True, rust=True)

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

    def test_main_push_uses_exact_before_revision(self):
        head = self.commit_file("docs/note.md", "docs\n")
        plan = PLAN.plan_from_push_event(
            self.root,
            self.event(before=self.base, after=head, ref="refs/heads/main"),
        )
        self.assertFalse(plan.lanes.swift)
        self.assertFalse(plan.lanes.app)
        self.assertFalse(plan.lanes.ds)

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
    def plan(self, *, swift: bool, app: bool, ds: bool = False, rust: bool = False):
        return PLAN.CIPlan(
            lanes=PLAN.LaneSelection(swift=swift, app=app, ds=ds, rust=rust),
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

    def test_test_only_plan_runs_swift_but_not_app(self):
        flattened = "\n".join(self.commands(self.plan(swift=True, app=False)))
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
        parity = commands.index(f"{sys.executable} rust/scripts/check-contracts.py")
        fetch = commands.index("cargo fetch --locked")
        clippy = commands.index("cargo clippy --workspace --all-targets -- -D warnings")
        workspace_tests = commands.index(
            f"{sys.executable} rust/scripts/workspace-tests.py"
        )
        self.assertLess(fetch, clippy)
        self.assertLess(clippy, workspace_tests)
        self.assertLess(workspace_tests, regressions)
        self.assertLess(regressions, parity)
        self.assertLess(parity, commands.index("cargo deny --locked check"))
        self.assertNotIn(f"{sys.executable} rust/scripts/check-readonly.py", commands)
        self.assertNotIn("xcodebuild", "\n".join(commands))

    def test_rust_commands_use_workspace_toolchain_directory(self):
        root = pathlib.Path("/example/ArkDeck")
        commands = (("python3", "scripts/ci/test_plan.py"), ("cargo", "fmt", "--check"))
        with mock.patch.object(PLAN, "local_commands", return_value=commands):
            with mock.patch.object(PLAN.subprocess, "run") as run:
                PLAN.run_local(root, self.plan(swift=False, app=False, rust=True))
        self.assertEqual(
            [call.kwargs["cwd"] for call in run.call_args_list], [root, root / "rust"]
        )
        self.assertTrue(all(call.kwargs["check"] for call in run.call_args_list))

    def test_contract_or_dependency_policy_failure_cannot_pass_local_gate(self):
        for command in (
            (sys.executable, "rust/scripts/test_contract_checks.py"),
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


if __name__ == "__main__":
    unittest.main()
