#!/usr/bin/env python3
"""Offline contract tests for TASK-MECH-004 PR allowed-path checks."""

from __future__ import annotations

import json
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

    def test_non_declarable_task_header_still_delimits_previous_section(self):
        tasks = """\
## TASK-MECH-004 — path guard
- Allowed paths:`scripts/check_pr_paths.py`

## TASK-MECH-004R — later remediation
- Allowed paths:`scripts/other.py`
"""
        temporary, root = self.make_repo(tasks)
        self.addCleanup(temporary.cleanup)
        task = check_pr_paths.load_task_definitions(root)["TASK-MECH-004"]
        self.assertEqual(
            check_pr_paths.extract_allowed_patterns(root, task),
            ("scripts/check_pr_paths.py",),
        )

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
