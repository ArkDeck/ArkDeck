#!/usr/bin/env python3
"""Contract tests for the shared local/GitHub CI planner."""

from __future__ import annotations

import importlib.util
import pathlib
import subprocess
import sys
import tempfile
import unittest


SCRIPT = pathlib.Path(__file__).with_name("plan.py")
SPEC = importlib.util.spec_from_file_location("arkdeck_ci_plan", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
PLAN = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = PLAN
SPEC.loader.exec_module(PLAN)


class PathClassificationTests(unittest.TestCase):
    def assert_lanes(self, paths, *, swift: bool, app: bool, ds: bool):
        selection = PLAN.classify_paths(paths)
        self.assertEqual(selection.swift, swift)
        self.assertEqual(selection.app, app)
        self.assertEqual(selection.ds, ds)

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
        self.assert_lanes(
            ["scripts/ci/plan.py"], swift=True, app=True, ds=True
        )
        self.assert_lanes(
            [".github/workflows/swift-ci.yml"], swift=True, app=True, ds=True
        )


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
    def plan(self, *, swift: bool, app: bool, ds: bool = False):
        return PLAN.CIPlan(
            lanes=PLAN.LaneSelection(swift=swift, app=app, ds=ds),
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


if __name__ == "__main__":
    unittest.main()
