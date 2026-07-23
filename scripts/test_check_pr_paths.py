#!/usr/bin/env python3
"""Offline contract tests for TASK-MECH-004 PR allowed-path checks."""

from __future__ import annotations

import json
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

import check_pr_paths


ZERO_OID = "0" * 40
ONE_OID = "1" * 40


class PullRequestPathTests(unittest.TestCase):
    def context(
        self,
        *,
        title: str = "docs: governance update",
        body: str = "",
        head_ref: str = "agent/governance-update",
    ) -> check_pr_paths.PullRequestContext:
        return check_pr_paths.PullRequestContext(
            title=title,
            body=body,
            head_ref=head_ref,
            base_oid=ZERO_OID,
            head_oid=ONE_OID,
        )

    def make_repo(self, task_section: str | None) -> tuple[tempfile.TemporaryDirectory, Path]:
        temporary = tempfile.TemporaryDirectory(prefix="check-pr-paths-")
        root = Path(temporary.name)
        if task_section is not None:
            change = root / "openspec" / "changes" / "chg-test"
            change.mkdir(parents=True)
            (change / "tasks.md").write_text(task_section, encoding="utf-8")
        return temporary, root

    def run_git(self, root: Path, *arguments: str) -> str:
        completed = subprocess.run(
            ["git", "-C", str(root), *arguments],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(
            completed.returncode,
            0,
            msg=f"git {' '.join(arguments)} failed: {completed.stderr}",
        )
        return completed.stdout.strip()

    def commit(self, root: Path, message: str) -> str:
        self.run_git(root, "add", "-A")
        self.run_git(root, "commit", "--quiet", "-m", message)
        return self.run_git(root, "rev-parse", "HEAD")

    def make_archivable_repo(
        self,
    ) -> tuple[tempfile.TemporaryDirectory, Path, Path, str]:
        temporary = tempfile.TemporaryDirectory(prefix="check-pr-archive-")
        root = Path(temporary.name)
        self.run_git(root, "init", "--quiet")
        self.run_git(root, "config", "user.name", "Contract Test")
        self.run_git(root, "config", "user.email", "contract@example.invalid")
        self.run_git(root, "config", "core.filemode", "true")
        change = root / "openspec" / "changes" / "chg-test-archive"
        (change / "evidence").mkdir(parents=True)
        (change / "tasks.md").write_text(
            "## TASK-ARC-001 — archive fixture\n"
            "- Allowed paths:`docs/allowed.md`\n",
            encoding="utf-8",
        )
        (change / "proposal.md").write_text("# proposal\n", encoding="utf-8")
        (change / "evidence" / "run.md").write_text("run\n", encoding="utf-8")
        base_oid = self.commit(root, "base active change")
        return temporary, root, change, base_oid

    def archive_context(
        self, base_oid: str, head_oid: str
    ) -> check_pr_paths.PullRequestContext:
        return check_pr_paths.PullRequestContext(
            title="governance(TASK-ARC-001): archive change",
            body="Task: TASK-ARC-001\n",
            head_ref="agent/task-arc-001-archive",
            base_oid=base_oid,
            head_oid=head_oid,
        )

    def move_to_archive(self, root: Path, change: Path, target_name: str) -> Path:
        archive_root = root / "openspec" / "changes" / "archive"
        archive_root.mkdir(parents=True, exist_ok=True)
        target = archive_root / target_name
        change.rename(target)
        return target

    def assert_error(self, expected: str, callback) -> None:
        with self.assertRaises(check_pr_paths.CheckError) as caught:
            callback()
        self.assertIn(expected, str(caught.exception))

    def test_declaration_precedence_and_ambiguity(self):
        body = "Task: TASK-MECH-004\n"
        matching = self.context(
            title="feat(TASK-MECH-004): add guard",
            body=body,
            head_ref="agent/task-something-else",
        )
        self.assertEqual(check_pr_paths.resolve_task_declaration(matching), "TASK-MECH-004")

        title_fallback = self.context(title="feat(TASK-MECH-004): add guard")
        self.assertEqual(
            check_pr_paths.resolve_task_declaration(title_fallback), "TASK-MECH-004"
        )

        branch_fallback = self.context(
            title="feat: add guard", head_ref="agent/task-mech-004"
        )
        self.assertEqual(
            check_pr_paths.resolve_task_declaration(branch_fallback), "TASK-MECH-004"
        )

        ambiguous = self.context(
            title="feat(TASK-MECH-003): add guard",
            body=body,
        )
        self.assert_error(
            "multiple distinct tasks",
            lambda: check_pr_paths.resolve_task_declaration(ambiguous),
        )

    def test_suffix_task_tokens_bind_and_malformed_variants_fail_closed(self):
        self.assertEqual(
            check_pr_paths.TASK_TOKEN_TEXT,
            r"TASK-[A-Z0-9]+(?:-[A-Z0-9]+)*-[0-9]{3}[A-Z]?",
        )
        for task_id in (
            "TASK-HLR-002A",
            "TASK-M1-001R",
            "TASK-M0A-005B",
            "TASK-HLR-003",
        ):
            with self.subTest(task_id=task_id, source="title"):
                context = self.context(
                    title=f"feat({task_id}): suffix-compatible declaration",
                    head_ref="agent/descriptive-branch",
                )
                self.assertEqual(
                    check_pr_paths.resolve_task_declaration(context), task_id
                )
            with self.subTest(task_id=task_id, source="body"):
                context = self.context(
                    body=f"Task: {task_id}\n",
                    head_ref="agent/descriptive-branch",
                )
                self.assertEqual(
                    check_pr_paths.resolve_task_declaration(context), task_id
                )

        for malformed in (
            "TASK-HLR-002AB",
            "TASK-HLR-02A",
            "task-HLR-002A",
            "TASK-HLR-002a",
        ):
            with self.subTest(malformed=malformed):
                context = self.context(
                    body=f"Task: {malformed}\n",
                    head_ref="agent/task-hlr-002a-bootstrap-partition-r2",
                )
                self.assert_error(
                    "normalizes to invalid",
                    lambda context=context: check_pr_paths.resolve_task_declaration(
                        context
                    ),
                )

        adjacency = self.context(
            title="feat(XTASK-HLR-002AY): reject adjacent token",
            head_ref="agent/governance-update",
        )
        self.assertIsNone(check_pr_paths.resolve_task_declaration(adjacency))

        descriptive = self.context(
            title="feat: bootstrap partition",
            head_ref="agent/task-hlr-002a-bootstrap-partition-r2",
        )
        self.assert_error(
            "normalizes to invalid",
            lambda: check_pr_paths.resolve_task_declaration(descriptive),
        )

        ambiguous = self.context(
            title="feat(TASK-HLR-002A): suffix task",
            body="Task: TASK-HLR-003\n",
        )
        self.assert_error(
            "multiple distinct tasks",
            lambda: check_pr_paths.resolve_task_declaration(ambiguous),
        )

        tasks = """\
## TASK-HLR-002A — suffix task
- Allowed paths:`scripts/check_pr_paths.py`
"""
        temporary, root = self.make_repo(tasks)
        self.addCleanup(temporary.cleanup)
        context = self.context(title="feat(TASK-HLR-002A): suffix task")
        result = check_pr_paths.check_paths(
            root, context, ("scripts/check_pr_paths.py",)
        )
        self.assertEqual(result.task_id, "TASK-HLR-002A")

        unknown = self.context(title="feat(TASK-M1-001R): unknown active task")
        self.assert_error(
            "does not exist in an active change",
            lambda: check_pr_paths.check_paths(root, unknown, ("docs/x.md",)),
        )

    def test_declared_task_allows_exact_glob_and_change_relative_paths(self):
        tasks = """\
## TASK-MECH-004 — path guard
- Allowed paths:`scripts/check_pr_paths.py`、`Packages/ArkDeckKit/**`、本 change
  `evidence/**`。
- Risk:low
"""
        temporary, root = self.make_repo(tasks)
        self.addCleanup(temporary.cleanup)
        context = self.context(
            body="Task: TASK-MECH-004\n", head_ref="agent/task-mech-004"
        )
        changed = (
            "scripts/check_pr_paths.py",
            "Packages/ArkDeckKit/Sources/Deep/File.swift",
            "openspec/changes/chg-test/evidence/run.md",
        )
        result = check_pr_paths.check_paths(root, context, changed)
        self.assertEqual(result.task_id, "TASK-MECH-004")
        self.assertEqual(result.changed_paths, changed)

    def test_declared_task_violation_lists_every_offending_path(self):
        tasks = """\
## TASK-MECH-004 — path guard
- Allowed paths:`scripts/check_pr_paths.py`
"""
        temporary, root = self.make_repo(tasks)
        self.addCleanup(temporary.cleanup)
        context = self.context(body="Task: TASK-MECH-004\n")
        self.assert_error(
            "README.md, scripts/other.py",
            lambda: check_pr_paths.check_paths(
                root,
                context,
                ("scripts/check_pr_paths.py", "scripts/other.py", "README.md"),
            ),
        )

    def test_backslash_filename_cannot_be_rewritten_into_allowed_directory(self):
        tasks = """\
## TASK-MECH-004 — path guard
- Allowed paths:`scripts/**`
"""
        temporary, root = self.make_repo(tasks)
        self.addCleanup(temporary.cleanup)
        context = self.context(body="Task: TASK-MECH-004\n")
        self.assert_error(
            r"scripts\outside.py",
            lambda: check_pr_paths.check_paths(
                root,
                context,
                (r"scripts\outside.py",),
            ),
        )

    def test_undeclared_sensitive_fails_and_docs_governance_passes(self):
        temporary, root = self.make_repo(None)
        self.addCleanup(temporary.cleanup)
        context = self.context()
        sensitive_paths = (
            "Packages/A.swift",
            "ArkDeckApp/App.swift",
            "ArkDeckAppUITests/AppTests.swift",
            "scripts/x.py",
            ".github/workflows/guard.yml",
        )
        for sensitive_path in sensitive_paths:
            with self.subTest(sensitive_path=sensitive_path):
                self.assert_error(
                    f"touches sensitive paths: {sensitive_path}",
                    lambda path=sensitive_path: check_pr_paths.check_paths(
                        root, context, ("docs/notes.md", path)
                    ),
                )
        result = check_pr_paths.check_paths(
            root,
            context,
            (
                "openspec/changes/chg-new/proposal.md",
                "openspec/changes/chg-new/tasks.md",
            ),
        )
        self.assertIsNone(result.task_id)

    def test_unknown_task_missing_line_and_zero_tokens_fail_closed(self):
        context = self.context(body="Task: TASK-MECH-004\n")

        temporary, root = self.make_repo(None)
        self.addCleanup(temporary.cleanup)
        self.assert_error(
            "does not exist in an active change",
            lambda: check_pr_paths.check_paths(root, context, ("docs/x.md",)),
        )

        for label, allowed_line, expected in (
            ("missing", "- Risk:low\n", "has no Allowed paths line"),
            ("empty", "- Allowed paths:plain prose only\n", "yields zero backtick"),
        ):
            with self.subTest(label=label):
                case_temp, case_root = self.make_repo(
                    "## TASK-MECH-004 — path guard\n" + allowed_line
                )
                self.addCleanup(case_temp.cleanup)
                self.assert_error(
                    expected,
                    lambda root=case_root: check_pr_paths.check_paths(
                        root, context, ("docs/x.md",)
                    ),
                )

    def test_archived_task_is_not_an_active_declaration_target(self):
        temporary, root = self.make_repo(None)
        self.addCleanup(temporary.cleanup)
        archived = root / "openspec" / "changes" / "archive" / "old"
        archived.mkdir(parents=True)
        (archived / "tasks.md").write_text(
            "## TASK-MECH-004 — old\n- Allowed paths:`**`\n", encoding="utf-8"
        )
        context = self.context(body="Task: TASK-MECH-004\n")
        self.assert_error(
            "does not exist in an active change",
            lambda: check_pr_paths.check_paths(root, context, ("docs/x.md",)),
        )

    def test_suffix_task_header_delimits_previous_section_and_is_loaded(self):
        tasks = """\
## TASK-MECH-004 — path guard
- Allowed paths:`scripts/check_pr_paths.py`

## TASK-MECH-004R — later remediation
- Allowed paths:`scripts/other.py`
"""
        temporary, root = self.make_repo(tasks)
        self.addCleanup(temporary.cleanup)
        definitions = check_pr_paths.load_task_definitions(root)
        task = definitions["TASK-MECH-004"]
        self.assertEqual(
            check_pr_paths.extract_allowed_patterns(root, task),
            ("scripts/check_pr_paths.py",),
        )
        self.assertIn("TASK-MECH-004R", definitions)

    def test_existing_allowed_paths_label_variants_are_parsed(self):
        variants = (
            "- Allowed paths:`scripts/a.py`\n",
            "- Allowed paths(approve/readiness 后细化):`scripts/a.py`\n",
            "- Allowed paths after readiness:`scripts/a.py`\n",
            "- Allowed paths（实现 PR 的封闭文件面）：`scripts/a.py`\n",
        )
        for index, allowed_line in enumerate(variants):
            with self.subTest(allowed_line=allowed_line):
                temporary, root = self.make_repo(
                    f"## TASK-MECH-{index:03d} — path guard\n" + allowed_line
                )
                self.addCleanup(temporary.cleanup)
                task_id = f"TASK-MECH-{index:03d}"
                task = check_pr_paths.load_task_definitions(root)[task_id]
                self.assertEqual(
                    check_pr_paths.extract_allowed_patterns(root, task),
                    ("scripts/a.py",),
                )

    def test_real_shape_implementation_status_and_propose_cases(self):
        tasks = """\
## TASK-MECH-004 — path guard
- Allowed paths:`scripts/check_pr_paths.py`、本 change `tasks.md`
"""
        temporary, root = self.make_repo(tasks)
        self.addCleanup(temporary.cleanup)

        implementation = self.context(
            title="feat(TASK-MECH-004): implement path guard",
            body="Task: TASK-MECH-004\n",
            head_ref="agent/task-mech-004",
        )
        check_pr_paths.check_paths(root, implementation, ("scripts/check_pr_paths.py",))

        status = self.context(
            title="docs(TASK-MECH-004): mark done",
            body="Task: TASK-MECH-004\n",
            head_ref="agent/task-mech-004-done",
        )
        check_pr_paths.check_paths(
            root, status, ("openspec/changes/chg-test/tasks.md",)
        )

        propose = self.context(
            title="docs(CHG-TEST): propose change",
            body="",
            head_ref="agent/chg-test-proposal",
        )
        check_pr_paths.check_paths(
            root,
            propose,
            (
                "openspec/changes/chg-proposed/proposal.md",
                "openspec/changes/chg-proposed/tasks.md",
            ),
        )

    def test_atomic_archive_uses_base_task_and_allows_declared_living_path(self):
        temporary, root, change, base_oid = self.make_archivable_repo()
        self.addCleanup(temporary.cleanup)
        self.move_to_archive(root, change, "2026-07-23-chg-test-archive")
        allowed = root / "docs" / "allowed.md"
        allowed.parent.mkdir(parents=True)
        allowed.write_text("allowed living update\n", encoding="utf-8")
        head_oid = self.commit(root, "atomic archive")
        context = self.archive_context(base_oid, head_oid)
        changed = check_pr_paths.git_changed_paths(root, base_oid, head_oid)

        result = check_pr_paths.check_paths(root, context, changed)

        self.assertEqual(result.task_id, "TASK-ARC-001")
        self.assertEqual(result.allowed_patterns, ("docs/allowed.md",))
        self.assertIn(
            "openspec/changes/archive/2026-07-23-chg-test-archive/tasks.md",
            result.changed_paths,
        )

    def test_archive_only_task_never_supplies_authority(self):
        temporary = tempfile.TemporaryDirectory(prefix="check-pr-archive-only-")
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        self.run_git(root, "init", "--quiet")
        self.run_git(root, "config", "user.name", "Contract Test")
        self.run_git(root, "config", "user.email", "contract@example.invalid")
        archived = (
            root
            / "openspec"
            / "changes"
            / "archive"
            / "2026-07-22-chg-old"
        )
        archived.mkdir(parents=True)
        (archived / "tasks.md").write_text(
            "## TASK-ARC-001 — archive only\n- Allowed paths:`**`\n",
            encoding="utf-8",
        )
        base_oid = self.commit(root, "archive-only base")
        note = root / "docs" / "note.md"
        note.parent.mkdir(parents=True)
        note.write_text("update\n", encoding="utf-8")
        head_oid = self.commit(root, "unrelated update")
        context = self.archive_context(base_oid, head_oid)

        self.assert_error(
            "archive-only tasks are not authority",
            lambda: check_pr_paths.check_paths(
                root,
                context,
                check_pr_paths.git_changed_paths(root, base_oid, head_oid),
            ),
        )

    def test_atomic_archive_rejects_partial_extra_mutated_and_mode_drift(self):
        cases = (
            (
                "partial",
                lambda target: (target / "proposal.md").unlink(),
                "partial/extra move",
            ),
            (
                "extra",
                lambda target: (target / "extra.md").write_text(
                    "extra\n", encoding="utf-8"
                ),
                "partial/extra move",
            ),
            (
                "mutated",
                lambda target: (target / "proposal.md").write_text(
                    "mutated\n", encoding="utf-8"
                ),
                "mutated=proposal.md",
            ),
            (
                "mode",
                lambda target: (target / "proposal.md").chmod(0o755),
                "mode mismatch=proposal.md",
            ),
        )
        for label, mutate, expected in cases:
            with self.subTest(label=label):
                temporary, root, change, base_oid = self.make_archivable_repo()
                self.addCleanup(temporary.cleanup)
                target = self.move_to_archive(
                    root, change, "2026-07-23-chg-test-archive"
                )
                mutate(target)
                head_oid = self.commit(root, f"{label} archive")
                context = self.archive_context(base_oid, head_oid)
                self.assert_error(
                    expected,
                    lambda root=root, context=context, base_oid=base_oid, head_oid=head_oid: check_pr_paths.check_paths(
                        root,
                        context,
                        check_pr_paths.git_changed_paths(root, base_oid, head_oid),
                    ),
                )

    def test_atomic_archive_rejects_copy_with_active_root_residue(self):
        temporary, root, change, base_oid = self.make_archivable_repo()
        self.addCleanup(temporary.cleanup)
        target = (
            root
            / "openspec"
            / "changes"
            / "archive"
            / "2026-07-23-chg-test-archive"
        )
        target.parent.mkdir(parents=True)
        shutil.copytree(change, target)
        head_oid = self.commit(root, "copied archive")
        context = self.archive_context(base_oid, head_oid)

        self.assert_error(
            "active-root residue",
            lambda: check_pr_paths.check_paths(
                root,
                context,
                check_pr_paths.git_changed_paths(root, base_oid, head_oid),
            ),
        )

    def test_atomic_archive_rejects_ambiguous_new_targets(self):
        temporary, root, change, base_oid = self.make_archivable_repo()
        self.addCleanup(temporary.cleanup)
        first = self.move_to_archive(root, change, "2026-07-22-chg-test-archive")
        second = first.parent / "2026-07-23-chg-test-archive"
        shutil.copytree(first, second)
        head_oid = self.commit(root, "ambiguous archive")
        context = self.archive_context(base_oid, head_oid)

        self.assert_error(
            "ambiguous newly added targets",
            lambda: check_pr_paths.check_paths(
                root,
                context,
                check_pr_paths.git_changed_paths(root, base_oid, head_oid),
            ),
        )

    def test_atomic_archive_rejects_wrong_or_invalid_target_name(self):
        for target_name in (
            "chg-test-archive",
            "2026-W01-1-chg-test-archive",
            "2026-99-99-chg-test-archive",
            "2026-07-23-chg-other",
        ):
            with self.subTest(target_name=target_name):
                temporary, root, change, base_oid = self.make_archivable_repo()
                self.addCleanup(temporary.cleanup)
                self.move_to_archive(root, change, target_name)
                head_oid = self.commit(root, "wrong archive target")
                context = self.archive_context(base_oid, head_oid)
                self.assert_error(
                    "must be named YYYY-MM-DD-chg-test-archive",
                    lambda root=root, context=context, base_oid=base_oid, head_oid=head_oid: check_pr_paths.check_paths(
                        root,
                        context,
                        check_pr_paths.git_changed_paths(root, base_oid, head_oid),
                    ),
                )

    def test_atomic_archive_rejects_pre_existing_target(self):
        temporary, root, change, _ = self.make_archivable_repo()
        self.addCleanup(temporary.cleanup)
        target = (
            root
            / "openspec"
            / "changes"
            / "archive"
            / "2026-07-23-chg-test-archive"
        )
        target.mkdir(parents=True)
        (target / "marker.md").write_text("pre-existing\n", encoding="utf-8")
        base_oid = self.commit(root, "add pre-existing archive target")
        for child in tuple(change.iterdir()):
            child.rename(target / child.name)
        change.rmdir()
        head_oid = self.commit(root, "move into pre-existing target")
        context = self.archive_context(base_oid, head_oid)

        self.assert_error(
            "pre-existing target",
            lambda: check_pr_paths.check_paths(
                root,
                context,
                check_pr_paths.git_changed_paths(root, base_oid, head_oid),
            ),
        )

    def test_atomic_archive_rejects_living_scope_expansion(self):
        temporary, root, change, base_oid = self.make_archivable_repo()
        self.addCleanup(temporary.cleanup)
        self.move_to_archive(root, change, "2026-07-23-chg-test-archive")
        outside = root / "scripts" / "outside.py"
        outside.parent.mkdir(parents=True)
        outside.write_text("print('outside')\n", encoding="utf-8")
        head_oid = self.commit(root, "archive plus living scope expansion")
        context = self.archive_context(base_oid, head_oid)

        self.assert_error(
            "paths outside Allowed paths: scripts/outside.py",
            lambda: check_pr_paths.check_paths(
                root,
                context,
                check_pr_paths.git_changed_paths(root, base_oid, head_oid),
            ),
        )

    def test_event_parser_rejects_missing_shape_and_short_oids(self):
        with tempfile.TemporaryDirectory(prefix="check-pr-event-") as temp:
            event_path = Path(temp) / "event.json"
            event_path.write_text("{}", encoding="utf-8")
            self.assert_error(
                "no pull_request object",
                lambda: check_pr_paths.load_pull_request_context(event_path),
            )

            event_path.write_text(
                json.dumps(
                    {
                        "pull_request": {
                            "title": "docs",
                            "body": None,
                            "base": {"sha": "abc"},
                            "head": {"sha": ONE_OID, "ref": "agent/docs"},
                        }
                    }
                ),
                encoding="utf-8",
            )
            self.assert_error(
                "full 40-hex OID",
                lambda: check_pr_paths.load_pull_request_context(event_path),
            )

    def test_workflow_rechecks_when_pr_metadata_or_base_is_edited(self):
        repo_root = Path(__file__).resolve().parents[1]
        workflow = (repo_root / ".github" / "workflows" / "sdd-guard.yml").read_text(
            encoding="utf-8"
        )
        self.assertIn(
            "pull_request:\n    types: [opened, synchronize, reopened, edited]",
            workflow,
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
