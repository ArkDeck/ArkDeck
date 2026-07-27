#!/usr/bin/env python3
"""Offline contract tests for TASK-MECH-004 PR allowed-path checks."""

from __future__ import annotations

import contextlib
import io
import json
import shutil
import subprocess
import sys
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
        oid: str | None = None,
    ) -> check_pr_paths.PullRequestContext:
        # The allowlist is read from the base tree, so a fixture repository's
        # real commit has to stand behind the context; the synthetic OIDs
        # remain for the cases that never reach a task lookup.
        return check_pr_paths.PullRequestContext(
            title=title,
            body=body,
            head_ref=head_ref,
            base_oid=oid or ZERO_OID,
            head_oid=oid or ONE_OID,
        )

    def pull_request_api(
        self,
        *,
        number: object = 483,
        state: object = "open",
        merged: object = False,
        title: object = "ci(TASK-HLR-001A): automate Agent PR checks",
        body: object = None,
        base_ref: object = "main",
        base_sha: object = ZERO_OID,
        base_repo: object = "ArkDeck/ArkDeck",
        head_ref: object = "agent/task-hlr-001a-auto-ci",
        head_sha: object = ONE_OID,
        head_repo: object = "ArkDeck/ArkDeck",
        author: object = "github-actions[bot]",
    ) -> dict[str, object]:
        return {
            "number": number,
            "state": state,
            "merged": merged,
            "title": title,
            "body": body,
            "base": {
                "ref": base_ref,
                "sha": base_sha,
                "repo": {"full_name": base_repo},
            },
            "head": {
                "ref": head_ref,
                "sha": head_sha,
                "repo": {"full_name": head_repo},
            },
            "user": {"login": author},
        }

    def make_repo(
        self, task_section: str | None
    ) -> tuple[tempfile.TemporaryDirectory, Path, str]:
        """A committed fixture repository, returning its commit OID.

        A bare directory used to be enough because the checker read the
        working tree. It now reads the base tree out of git, so the fixture
        has to be a real repository with a real commit.
        """
        temporary = tempfile.TemporaryDirectory(prefix="check-pr-paths-")
        root = Path(temporary.name)
        self.run_git(root, "init", "--quiet")
        self.run_git(root, "config", "user.name", "Contract Test")
        self.run_git(root, "config", "user.email", "contract@example.invalid")
        if task_section is not None:
            change = root / "openspec" / "changes" / "chg-test"
            change.mkdir(parents=True)
            (change / "tasks.md").write_text(task_section, encoding="utf-8")
        (root / "README.md").write_text("fixture\n", encoding="utf-8")
        return temporary, root, self.commit(root, "fixture base")

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
        temporary, root, oid = self.make_repo(tasks)
        self.addCleanup(temporary.cleanup)
        context = self.context(title="feat(TASK-HLR-002A): suffix task", oid=oid)
        result = check_pr_paths.check_paths(
            root, context, ("scripts/check_pr_paths.py",)
        )
        self.assertEqual(result.task_id, "TASK-HLR-002A")

        unknown = self.context(title="feat(TASK-M1-001R): unknown active task", oid=oid)
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
        temporary, root, oid = self.make_repo(tasks)
        self.addCleanup(temporary.cleanup)
        context = self.context(
            body="Task: TASK-MECH-004\n", head_ref="agent/task-mech-004", oid=oid
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
        temporary, root, oid = self.make_repo(tasks)
        self.addCleanup(temporary.cleanup)
        context = self.context(body="Task: TASK-MECH-004\n", oid=oid)
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
        temporary, root, oid = self.make_repo(tasks)
        self.addCleanup(temporary.cleanup)
        context = self.context(body="Task: TASK-MECH-004\n", oid=oid)
        self.assert_error(
            r"scripts\outside.py",
            lambda: check_pr_paths.check_paths(
                root,
                context,
                (r"scripts\outside.py",),
            ),
        )

    def test_undeclared_sensitive_fails_and_docs_governance_passes(self):
        temporary, root, oid = self.make_repo(None)
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
        temporary, root, oid = self.make_repo(None)
        self.addCleanup(temporary.cleanup)
        self.assert_error(
            "does not exist in an active change",
            lambda: check_pr_paths.check_paths(
                root, self.context(body="Task: TASK-MECH-004\n", oid=oid),
                ("docs/x.md",)
            ),
        )

        for label, allowed_line, expected in (
            ("missing", "- Risk:low\n", "has no Allowed paths line"),
            ("empty", "- Allowed paths:plain prose only\n", "yields zero backtick"),
        ):
            with self.subTest(label=label):
                case_temp, case_root, case_oid = self.make_repo(
                    "## TASK-MECH-004 — path guard\n" + allowed_line
                )
                self.addCleanup(case_temp.cleanup)
                self.assert_error(
                    expected,
                    lambda root=case_root, oid=case_oid: check_pr_paths.check_paths(
                        root,
                        self.context(body="Task: TASK-MECH-004\n", oid=oid),
                        ("docs/x.md",),
                    ),
                )

    def test_archived_task_is_not_an_active_declaration_target(self):
        temporary, root, oid = self.make_repo(None)
        self.addCleanup(temporary.cleanup)
        archived = root / "openspec" / "changes" / "archive" / "old"
        archived.mkdir(parents=True)
        (archived / "tasks.md").write_text(
            "## TASK-MECH-004 — old\n- Allowed paths:`**`\n", encoding="utf-8"
        )
        oid = self.commit(root, "archive-only task")
        context = self.context(body="Task: TASK-MECH-004\n", oid=oid)
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
        temporary, root, oid = self.make_repo(tasks)
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
                temporary, root, oid = self.make_repo(
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
        temporary, root, oid = self.make_repo(tasks)
        self.addCleanup(temporary.cleanup)

        implementation = self.context(
            title="feat(TASK-MECH-004): implement path guard",
            body="Task: TASK-MECH-004\n",
            head_ref="agent/task-mech-004",
            oid=oid,
        )
        check_pr_paths.check_paths(root, implementation, ("scripts/check_pr_paths.py",))

        status = self.context(
            title="docs(TASK-MECH-004): mark done",
            body="Task: TASK-MECH-004\n",
            head_ref="agent/task-mech-004-done",
            oid=oid,
        )
        check_pr_paths.check_paths(
            root, status, ("openspec/changes/chg-test/tasks.md",)
        )

        propose = self.context(
            title="docs(CHG-TEST): propose change",
            body="",
            head_ref="agent/chg-test-proposal",
            oid=oid,
        )
        check_pr_paths.check_paths(
            root,
            propose,
            (
                "openspec/changes/chg-proposed/proposal.md",
                "openspec/changes/chg-proposed/tasks.md",
            ),
        )

    def test_a_live_task_declaration_authorizes_only_its_reviewed_surface(self):
        """The real-repo end-to-end: a genuine task's declaration authorizes
        exactly its reviewed surface. The original form pinned TASK-HLR-001A,
        which stops resolving once its change archives (an archived task must
        not supply authority — the invariant this file pins elsewhere), so
        the task is now sampled from a live change dynamically
        (TASK-NAV-002)."""
        import sys as _sys

        repo_root = Path(__file__).resolve().parents[1]
        if str(repo_root / "scripts") not in _sys.path:
            _sys.path.insert(0, str(repo_root / "scripts"))
        from host_loop.test_support import live_sample_change

        sample = live_sample_change(repo_root)
        definitions = check_pr_paths.load_task_definitions(repo_root)
        chosen = None
        for task_id in sorted(definitions):
            task = definitions[task_id]
            if not task.tasks_file.match(f"*/{sample.lower()}/tasks.md"):
                continue
            patterns = check_pr_paths.extract_allowed_patterns(repo_root, task)
            literals = [p for p in patterns if "*" not in p]
            if literals and not check_pr_paths.path_matches(".gitignore", patterns):
                chosen = (task_id, literals[0])
                break
        self.assertIsNotNone(
            chosen, f"{sample} offers no task with a literal allowed path"
        )
        task_id, literal = chosen
        head_oid = subprocess.run(
            ["git", "-C", str(repo_root), "rev-parse", "HEAD"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
        context = check_pr_paths.PullRequestContext(
            title=f"feat({task_id}): live sample surface",
            body="",
            head_ref=f"agent/task-{task_id.lower()}",
            base_oid=head_oid,
            head_oid=head_oid,
        )
        result = check_pr_paths.check_paths(repo_root, context, (literal,))
        self.assertEqual(result.task_id, task_id)
        self.assertEqual(result.changed_paths, (literal,))

        self.assert_error(
            "paths outside Allowed paths: .gitignore",
            lambda: check_pr_paths.check_paths(
                repo_root, context, (literal, ".gitignore")
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

    def test_paginated_pull_list_create_or_find_matrix_fails_closed(self):
        with tempfile.TemporaryDirectory(prefix="check-pr-list-") as temp:
            list_path = Path(temp) / "pulls.json"

            list_path.write_text("[[]]", encoding="utf-8")
            self.assertIsNone(
                check_pr_paths.select_unique_pull_request_number(
                    list_path, allow_zero=True
                )
            )
            self.assert_error(
                "found 0",
                lambda: check_pr_paths.select_unique_pull_request_number(
                    list_path, allow_zero=False
                ),
            )

            list_path.write_text('[[{"number":483}]]', encoding="utf-8")
            self.assertEqual(
                check_pr_paths.select_unique_pull_request_number(
                    list_path, allow_zero=False
                ),
                483,
            )

            for payload, expected in (
                ('[[{"number":483},{"number":484}]]', "found 2"),
                ('[{"number":483}]', "array of page arrays"),
                ('[[{"number":"483"}]]', "positive integer"),
                ('[[{"number":true}]]', "positive integer"),
                ('[[null]]', "non-object"),
            ):
                with self.subTest(payload=payload):
                    list_path.write_text(payload, encoding="utf-8")
                    self.assert_error(
                        expected,
                        lambda: check_pr_paths.select_unique_pull_request_number(
                            list_path, allow_zero=False
                        ),
                    )

    def test_pull_request_api_identity_positive_and_negative_matrix(self):
        expected = {
            "expected_repository": "ArkDeck/ArkDeck",
            "expected_number": 483,
            "expected_base_ref": "main",
            "expected_head_ref": "agent/task-hlr-001a-auto-ci",
            "expected_head_oid": ONE_OID,
            "expected_author": "github-actions[bot]",
        }
        context = check_pr_paths.validate_pull_request_identity(
            self.pull_request_api(), **expected
        )
        self.assertEqual(context.base_oid, ZERO_OID)
        self.assertEqual(context.head_oid, ONE_OID)
        self.assertEqual(context.body, "")

        cases = (
            ("number", {"number": 484}, "number does not match"),
            ("number type", {"number": "483"}, "positive integer"),
            ("state", {"state": "closed"}, "state must be open"),
            ("merged", {"merged": True}, "merged must be false"),
            ("base ref", {"base_ref": "develop"}, "base.ref"),
            ("base repo", {"base_repo": "fork/ArkDeck"}, "base repository"),
            ("head ref", {"head_ref": "agent/other"}, "head.ref"),
            ("head repo", {"head_repo": "fork/ArkDeck"}, "head repository"),
            ("head sha", {"head_sha": ZERO_OID}, "head.sha"),
            ("author", {"author": "lvye"}, "author"),
            ("short base", {"base_sha": "abc"}, "full 40-hex OID"),
            ("null title", {"title": None}, "title must be a string"),
        )
        for label, changes, expected_error in cases:
            with self.subTest(label=label):
                self.assert_error(
                    expected_error,
                    lambda changes=changes: check_pr_paths.validate_pull_request_identity(
                        self.pull_request_api(**changes), **expected
                    ),
                )

    def test_workflow_rechecks_when_pr_metadata_or_base_is_edited(self):
        repo_root = Path(__file__).resolve().parents[1]
        workflow = (repo_root / ".github" / "workflows" / "sdd-guard.yml").read_text(
            encoding="utf-8"
        )
        self.assertIn(
            "    types: [reopened, edited]",
            workflow,
        )
        self.assertNotIn("types: [opened, synchronize", workflow)


class AutomationConfigTests(unittest.TestCase):
    """TASK-DEC-001: the sensitive-path table is data, loaded fail-closed."""

    # The exact table the shipped config must parse to, in this order; any
    # content or ordering change must turn this suite red. The first five are
    # the patterns TASK-DEC-001 moved out of this module byte-for-byte; the
    # last four are the root-level entries TASK-DEC-004 added under its
    # readiness r1 decision, which enumerated them as the approved list. This
    # stays an exact-content anchor: a `len()` or "contains" assertion here
    # would let the table be rewritten without a test noticing.
    R1_ANCHOR_PATTERNS = (
        "Packages/**",
        "ArkDeckApp/**",
        "ArkDeckAppUITests/**",
        "scripts/**",
        ".github/**",
    )
    DEC_004_ADDED_PATTERNS = (
        "ArkDeck.xcodeproj/**",
        "AGENTS.md",
        ".gitignore",
        ".python-version",
    )
    ANCHOR_PATTERNS = R1_ANCHOR_PATTERNS + DEC_004_ADDED_PATTERNS

    def taskless_context(self) -> check_pr_paths.PullRequestContext:
        return check_pr_paths.PullRequestContext(
            title="docs: governance update",
            body="",
            head_ref="agent/governance-update",
            base_oid=ZERO_OID,
            head_oid=ONE_OID,
        )

    def write_config(self, text: str) -> Path:
        temporary = tempfile.TemporaryDirectory(prefix="automation-config-")
        self.addCleanup(temporary.cleanup)
        config_path = Path(temporary.name) / "automation_config.json"
        config_path.write_text(text, encoding="utf-8")
        return config_path

    def config_text(self, patterns: object) -> str:
        return json.dumps(
            {"schema": check_pr_paths.CONFIG_SCHEMA, "sensitive_paths": patterns}
        )

    def assert_config_error(self, expected: str, config_path: Path) -> None:
        with self.assertRaises(check_pr_paths.CheckError) as caught:
            check_pr_paths.load_sensitive_patterns(config_path)
        self.assertIn(expected, str(caught.exception))

    def test_shipped_config_parses_to_the_anchor_exactly(self):
        self.assertEqual(
            check_pr_paths.load_sensitive_patterns(),
            self.ANCHOR_PATTERNS,
        )

    def test_malformed_configs_each_fail_closed_with_a_valid_control(self):
        control = self.write_config(self.config_text(list(self.ANCHOR_PATTERNS)))
        self.assertEqual(
            check_pr_paths.load_sensitive_patterns(control),
            self.ANCHOR_PATTERNS,
        )

        with self.subTest(shape="missing file"):
            self.assert_config_error(
                "cannot read automation config",
                control.parent / "does-not-exist.json",
            )

        text_cases = (
            ("unparseable JSON", "{", "cannot parse automation config"),
            ("top level not an object", "[]", "top level must be a JSON object"),
            (
                "schema mismatch",
                json.dumps({"schema": "other/v0", "sensitive_paths": ["scripts/**"]}),
                "schema must be",
            ),
            (
                "schema absent",
                json.dumps({"sensitive_paths": ["scripts/**"]}),
                "schema must be",
            ),
            (
                "unknown key",
                json.dumps(
                    {
                        "schema": check_pr_paths.CONFIG_SCHEMA,
                        "sensitive_paths": ["scripts/**"],
                        "extra": 1,
                    }
                ),
                "unknown keys: extra",
            ),
            (
                "sensitive_paths not a list",
                self.config_text("scripts/**"),
                "non-empty list",
            ),
            ("sensitive_paths empty", self.config_text([]), "non-empty list"),
            (
                "non-string entry",
                self.config_text(["scripts/**", 7]),
                "must all be strings",
            ),
            (
                "boolean entry",
                self.config_text([True]),
                "must all be strings",
            ),
            (
                "duplicate entries",
                self.config_text(["scripts/**", "Packages/**", "scripts/**"]),
                "duplicate entries: scripts/**",
            ),
        )
        for label, text, expected in text_cases:
            with self.subTest(shape=label):
                self.assert_config_error(expected, self.write_config(text))

    def test_check_paths_consults_the_config_file_not_a_builtin_default(self):
        custom = self.write_config(self.config_text(["guarded_zone/**"]))
        temporary = tempfile.TemporaryDirectory(prefix="check-pr-config-")
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        context = self.taskless_context()

        with self.assertRaises(check_pr_paths.CheckError) as caught:
            check_pr_paths.check_paths(
                root,
                context,
                ("guarded_zone/pin.txt",),
                config_path=custom,
            )
        self.assertIn(
            "touches sensitive paths: guarded_zone/pin.txt", str(caught.exception)
        )

        # Paths the custom table does not name must pass, even though the
        # shipped table names them: red here means check_paths fell back to
        # a builtin default instead of the configured data.
        result = check_pr_paths.check_paths(
            root,
            context,
            ("scripts/x.py", "Packages/A.swift"),
            config_path=custom,
        )
        self.assertIsNone(result.task_id)
        self.assertEqual(result.allowed_patterns, ("guarded_zone/**",))

    def test_a_broken_config_blocks_even_a_task_declared_pr(self):
        temporary = tempfile.TemporaryDirectory(prefix="check-pr-broken-config-")
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        change = root / "openspec" / "changes" / "chg-test"
        change.mkdir(parents=True)
        (change / "tasks.md").write_text(
            "## TASK-MECH-004 — path guard\n"
            "- Allowed paths:`scripts/check_pr_paths.py`\n",
            encoding="utf-8",
        )
        context = check_pr_paths.PullRequestContext(
            title="feat(TASK-MECH-004): guarded change",
            body="Task: TASK-MECH-004\n",
            head_ref="agent/task-mech-004",
            base_oid=ZERO_OID,
            head_oid=ONE_OID,
        )
        with self.assertRaises(check_pr_paths.CheckError) as caught:
            check_pr_paths.check_paths(
                root,
                context,
                ("scripts/check_pr_paths.py",),
                config_path=root / "absent.json",
            )
        self.assertIn("cannot read automation config", str(caught.exception))

    def test_the_config_file_is_protected_by_its_own_declared_table(self):
        patterns = check_pr_paths.load_sensitive_patterns()
        self.assertTrue(
            check_pr_paths.path_matches("scripts/automation_config.json", patterns)
        )

        temporary = tempfile.TemporaryDirectory(prefix="check-pr-self-guard-")
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        with self.assertRaises(check_pr_paths.CheckError) as caught:
            check_pr_paths.check_paths(
                root,
                self.taskless_context(),
                ("scripts/automation_config.json",),
            )
        self.assertIn(
            "touches sensitive paths: scripts/automation_config.json",
            str(caught.exception),
        )

    def test_readme_boundary_map_covers_every_first_level_scripts_entry(self):
        repo_root = Path(__file__).resolve().parents[1]
        readme_text = (repo_root / "scripts" / "README.md").read_text(
            encoding="utf-8"
        )
        completed = subprocess.run(
            ["git", "-C", str(repo_root), "ls-tree", "--name-only", "HEAD", "scripts/"],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        entries = [
            line[len("scripts/") :]
            for line in completed.stdout.splitlines()
            if line.startswith("scripts/")
        ]
        self.assertTrue(entries, "git ls-tree returned no scripts/ entries")
        missing = [
            entry
            for entry in entries
            if f"`{entry}`" not in readme_text and f"`{entry}/`" not in readme_text
        ]
        self.assertEqual(
            missing, [], f"scripts/README.md does not mention: {missing}"
        )


class TrustBoundaryTests(unittest.TestCase):
    """TASK-DEC-004: what the guard trusts, and what it refuses to read."""

    run_git = PullRequestPathTests.run_git
    commit = PullRequestPathTests.commit
    assert_error = PullRequestPathTests.assert_error

    def git_repo(self) -> Path:
        temporary = tempfile.TemporaryDirectory(prefix="check-pr-trust-")
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        self.run_git(root, "init", "--quiet")
        self.run_git(root, "config", "user.name", "Contract Test")
        self.run_git(root, "config", "user.email", "contract@example.invalid")
        return root

    def write_task(self, root: Path, allowed_line: str) -> None:
        change = root / "openspec" / "changes" / "chg-trust"
        change.mkdir(parents=True, exist_ok=True)
        (change / "tasks.md").write_text(
            f"## TASK-TRUST-001 — trust boundary fixture\n{allowed_line}",
            encoding="utf-8",
        )

    def trust_context(self, base_oid: str, head_oid: str):
        return check_pr_paths.PullRequestContext(
            title="feat(TASK-TRUST-001): trust boundary",
            body="",
            head_ref="agent/task-trust-001",
            base_oid=base_oid,
            head_oid=head_oid,
        )

    # --- B-H1: the tree under review does not supply its own allowlist ---

    def test_a_pull_request_cannot_widen_its_own_allowed_paths(self):
        root = self.git_repo()
        self.write_task(root, "- Allowed paths:`docs/note.md`\n")
        (root / "docs").mkdir()
        (root / "docs" / "note.md").write_text("note\n", encoding="utf-8")
        base_oid = self.commit(root, "base")

        self.write_task(root, "- Allowed paths:`**`\n")
        (root / "scripts").mkdir()
        (root / "scripts" / "reach.py").write_text("reach\n", encoding="utf-8")
        head_oid = self.commit(root, "widen and reach")
        context = self.trust_context(base_oid, head_oid)
        changed = check_pr_paths.git_changed_paths(root, base_oid, head_oid)

        with self.assertRaises(check_pr_paths.CheckError) as caught:
            check_pr_paths.check_paths(root, context, changed)
        message = str(caught.exception)
        self.assertIn("paths outside Allowed paths", message)
        self.assertIn("scripts/reach.py", message)

        # Positive control: the same widening is authority once it is in the
        # base, which is what merging the readiness first accomplishes.
        (root / "docs" / "later.md").write_text("later\n", encoding="utf-8")
        follow_up = self.commit(root, "later work on the widened surface")
        self.assertEqual(
            check_pr_paths.check_paths(
                root,
                self.trust_context(head_oid, follow_up),
                ("scripts/reach.py",),
            ).task_id,
            "TASK-TRUST-001",
        )

    def test_a_task_only_the_head_defines_is_not_authority(self):
        root = self.git_repo()
        (root / "docs").mkdir()
        (root / "docs" / "note.md").write_text("note\n", encoding="utf-8")
        base_oid = self.commit(root, "base without the task")
        self.write_task(root, "- Allowed paths:`**`\n")
        head_oid = self.commit(root, "introduce the task it declares")

        self.assert_error(
            "does not exist in an active change",
            lambda: check_pr_paths.check_paths(
                root,
                self.trust_context(base_oid, head_oid),
                check_pr_paths.git_changed_paths(root, base_oid, head_oid),
            ),
        )

    # --- B-H4: the compared base cannot be chosen by the pull request ---

    def test_a_base_off_the_head_history_is_refused(self):
        root = self.git_repo()
        (root / "docs").mkdir()
        (root / "docs" / "note.md").write_text("note\n", encoding="utf-8")
        true_base = self.commit(root, "root")
        (root / "scripts").mkdir()
        (root / "scripts" / "reach.py").write_text("reach\n", encoding="utf-8")
        head_oid = self.commit(root, "offending")

        self.run_git(root, "checkout", "--quiet", "-b", "side", true_base)
        (root / "scripts").mkdir(exist_ok=True)
        (root / "scripts" / "reach.py").write_text("reach\n", encoding="utf-8")
        side_oid = self.commit(root, "side branch carrying the same file")
        self.run_git(root, "checkout", "--quiet", "-")

        # The substitution works on the diff: against the side branch the
        # offending file is not "new", so it vanishes from the comparison.
        self.assertEqual(
            check_pr_paths.git_changed_paths(root, side_oid, head_oid), ()
        )
        self.assertIn(
            "scripts/reach.py",
            check_pr_paths.git_changed_paths(root, true_base, head_oid),
        )

        self.assert_error(
            "is not an ancestor of head",
            lambda: check_pr_paths.assert_base_is_ancestor(
                root, self.trust_context(side_oid, head_oid)
            ),
        )
        check_pr_paths.assert_base_is_ancestor(
            root, self.trust_context(true_base, head_oid)
        )

    def test_event_mode_run_refuses_a_substituted_base(self):
        """Drives main(), so unhooking the gate is what turns this red.

        Asserting on the helper alone would leave the call site free to
        disappear — the shape this repository has been bitten by before.
        """
        root = self.git_repo()
        (root / "docs").mkdir()
        (root / "docs" / "note.md").write_text("note\n", encoding="utf-8")
        true_base = self.commit(root, "root")
        (root / "scripts").mkdir()
        (root / "scripts" / "reach.py").write_text("reach\n", encoding="utf-8")
        head_oid = self.commit(root, "offending")
        self.run_git(root, "checkout", "--quiet", "-b", "side", true_base)
        (root / "scripts").mkdir(exist_ok=True)
        (root / "scripts" / "reach.py").write_text("reach\n", encoding="utf-8")
        side_oid = self.commit(root, "side branch carrying the same file")
        self.run_git(root, "checkout", "--quiet", "-")

        def run(base_oid: str) -> tuple[int, str]:
            event = root / "event.json"
            event.write_text(
                json.dumps(
                    {
                        "pull_request": {
                            "state": "open",
                            "merged": False,
                            "title": "docs: governance update",
                            "body": None,
                            "base": {
                                "ref": "main",
                                "sha": base_oid,
                                "repo": {"full_name": "ArkDeck/ArkDeck"},
                            },
                            "head": {
                                "ref": "agent/docs",
                                "sha": head_oid,
                                "repo": {"full_name": "ArkDeck/ArkDeck"},
                            },
                        }
                    }
                ),
                encoding="utf-8",
            )
            completed = subprocess.run(
                [
                    sys.executable,
                    str(Path(__file__).resolve().parent / "check_pr_paths.py"),
                    "--repo-root",
                    str(root),
                    "--event",
                    str(event),
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            return completed.returncode, completed.stderr + completed.stdout

        code, output = run(side_oid)
        self.assertEqual(code, 1, output)
        self.assertIn("is not an ancestor of head", output)

        code, output = run(true_base)
        self.assertEqual(code, 1, output)
        self.assertIn("touches sensitive paths: scripts/reach.py", output)

    def test_event_mode_validates_identity_not_only_shape(self):
        def event(**overrides: object) -> Path:
            pull_request = {
                "state": "open",
                "merged": False,
                "title": "docs: governance update",
                "body": None,
                "base": {
                    "ref": "main",
                    "sha": ZERO_OID,
                    "repo": {"full_name": "ArkDeck/ArkDeck"},
                },
                "head": {
                    "ref": "agent/docs",
                    "sha": ONE_OID,
                    "repo": {"full_name": "ArkDeck/ArkDeck"},
                },
            }
            for key, value in overrides.items():
                if key in ("base_repo", "head_repo"):
                    pull_request[key.split("_")[0]]["repo"]["full_name"] = value
                else:
                    pull_request[key] = value
            temporary = tempfile.TemporaryDirectory(prefix="check-pr-event-")
            self.addCleanup(temporary.cleanup)
            path = Path(temporary.name) / "event.json"
            path.write_text(
                json.dumps({"pull_request": pull_request}), encoding="utf-8"
            )
            return path

        context = check_pr_paths.load_pull_request_context(event())
        self.assertEqual(context.base_oid, ZERO_OID)

        for label, overrides, expected in (
            ("closed", {"state": "closed"}, "state must be open"),
            ("merged", {"merged": True}, "merged must be false"),
            ("fork head", {"head_repo": "fork/ArkDeck"}, "repositories differ"),
            ("other base", {"base_repo": "other/ArkDeck"}, "repositories differ"),
        ):
            with self.subTest(label=label):
                self.assert_error(
                    expected,
                    lambda overrides=overrides: (
                        check_pr_paths.load_pull_request_context(event(**overrides))
                    ),
                )

    # --- B-H3: the block is a list, not a paragraph to mine for tokens ---

    def test_prose_around_the_declared_list_is_not_absorbed(self):
        root = self.git_repo()
        change = root / "openspec" / "changes" / "chg-trust"
        change.mkdir(parents=True)
        (change / "tasks.md").write_text(
            "## TASK-TRUST-001 — trust boundary fixture\n"
            "- Allowed paths:`docs/note.md`、本 change `evidence/**`。\n"
            "  the layout mirrors `scripts/**` and `Packages/**`, keep it stable\n"
            "- Risk:low\n",
            encoding="utf-8",
        )
        oid = self.commit(root, "task with prose under its allowed paths")
        task = check_pr_paths.load_task_definitions_at_commit(root, oid)[
            "TASK-TRUST-001"
        ]
        self.assertEqual(
            check_pr_paths.extract_allowed_patterns(root, task),
            ("docs/note.md", "openspec/changes/chg-trust/evidence/**"),
        )

    def test_a_wrapped_list_keeps_its_paths_and_drops_the_annotation(self):
        root = self.git_repo()
        change = root / "openspec" / "changes" / "chg-trust"
        change.mkdir(parents=True)
        (change / "tasks.md").write_text(
            "## TASK-TRUST-001 — trust boundary fixture\n"
            "- Allowed paths:\n"
            "  - 修改 `Packages/Kit/One.swift`\n"
            "    `1111111111111111111111111111111111111111`（仅给 `SomeSymbol` 增加\n"
            "    `OtherSymbol` 依赖）\n"
            "  - 新增 `Packages/Kit/Two.swift` 与\n"
            "    `Packages/Kit/Three.swift`；v1/v2 文件只读；\n"
            "- Risk:low\n",
            encoding="utf-8",
        )
        oid = self.commit(root, "wrapped declaration list")
        task = check_pr_paths.load_task_definitions_at_commit(root, oid)[
            "TASK-TRUST-001"
        ]
        self.assertEqual(
            check_pr_paths.extract_allowed_patterns(root, task),
            (
                "Packages/Kit/One.swift",
                "Packages/Kit/Two.swift",
                "Packages/Kit/Three.swift",
            ),
        )

    def test_the_block_ends_at_asterisk_tab_and_deeper_headings(self):
        for label, terminator in (
            ("asterisk bullet", "* `Packages/**` is forbidden here\n"),
            ("tab bullet", "\t- `Packages/**` is forbidden here\n"),
            ("deeper heading", "### `Packages/**` is forbidden here\n"),
        ):
            with self.subTest(label=label):
                root = self.git_repo()
                change = root / "openspec" / "changes" / "chg-trust"
                change.mkdir(parents=True)
                (change / "tasks.md").write_text(
                    "## TASK-TRUST-001 — trust boundary fixture\n"
                    "- Allowed paths:`docs/note.md`\n" + terminator,
                    encoding="utf-8",
                )
                oid = self.commit(root, f"block ends at {label}")
                task = check_pr_paths.load_task_definitions_at_commit(root, oid)[
                    "TASK-TRUST-001"
                ]
                self.assertEqual(
                    check_pr_paths.extract_allowed_patterns(root, task),
                    ("docs/note.md",),
                )

    def test_the_live_corpus_keeps_every_path_like_pattern(self):
        """No active task may lose a path-shaped pattern to the new parser.

        Read against the repository's own tasks.md files rather than
        fixtures: the shapes that matter here were written by hand over
        forty changes and no synthetic corpus reproduces them.
        """
        repo_root = Path(__file__).resolve().parents[1]
        definitions = check_pr_paths.load_task_definitions(repo_root)
        self.assertGreater(len(definitions), 40, "corpus unexpectedly small")
        path_like = 0
        for task_id in sorted(definitions):
            try:
                patterns = check_pr_paths.extract_allowed_patterns(
                    repo_root, definitions[task_id]
                )
            except check_pr_paths.CheckError:
                continue
            for pattern in patterns:
                with self.subTest(task_id=task_id, pattern=pattern):
                    self.assertTrue(
                        "/" in pattern or "*" in pattern or "." in pattern,
                        f"{task_id} kept a non-path token: {pattern!r}",
                    )
                path_like += 1
        self.assertGreater(path_like, 100, "corpus census collected too little")

    # --- B-M1: a single star stays inside one path segment ---

    def test_a_single_star_no_longer_crosses_a_directory_boundary(self):
        self.assertFalse(
            check_pr_paths.path_matches(
                "Packages/Kit/Sources/Deep/File.swift",
                ("Packages/Kit/Sources/*.swift",),
            )
        )
        self.assertTrue(
            check_pr_paths.path_matches(
                "Packages/Kit/Sources/File.swift",
                ("Packages/Kit/Sources/*.swift",),
            )
        )
        self.assertTrue(
            check_pr_paths.path_matches(
                "Packages/Kit/Sources/Deep/File.swift", ("Packages/Kit/**",)
            )
        )

    def test_both_glob_engines_in_this_repository_agree(self):
        """The workflow contract had the non-crossing semantics right first.

        Two implementations of one dialect drift unless something compares
        them, and the drift was live: this module's `*` crossed `/` while
        the workflow test's did not.
        """
        import test_agent_pr_workflow

        patterns = (
            "scripts/**",
            "scripts/*.py",
            "scripts/host_loop/*.py",
            "Packages/**",
            "Packages/Kit/Sources/*.swift",
            "AGENTS.md",
            "*.md",
            "a?c/x.py",
        )
        paths = (
            "scripts/check_pr_paths.py",
            "scripts/host_loop/worker.py",
            "scripts/host_loop/deep/nested.py",
            "Packages/Kit/Sources/File.swift",
            "Packages/Kit/Sources/Deep/File.swift",
            "AGENTS.md",
            "docs/AGENTS.md",
            "README.md",
            "abc/x.py",
            "ab/c/x.py",
        )
        for pattern in patterns:
            mine = check_pr_paths.glob_regex(pattern)
            theirs = test_agent_pr_workflow._glob_regex(pattern)
            for path in paths:
                with self.subTest(pattern=pattern, path=path):
                    self.assertEqual(
                        bool(mine.match(path)),
                        bool(theirs.match(path)),
                        f"glob dialects disagree on {pattern!r} vs {path!r}",
                    )

    # --- B-M4: the sensitive table sees case variants and the repository root ---

    def test_case_variants_of_sensitive_prefixes_are_sensitive(self):
        root = Path(tempfile.mkdtemp(prefix="check-pr-case-"))
        context = check_pr_paths.PullRequestContext(
            title="docs: governance update",
            body="",
            head_ref="agent/governance-update",
            base_oid=ZERO_OID,
            head_oid=ONE_OID,
        )
        for path in ("Scripts/x.py", ".GitHub/workflows/x.yml", "PACKAGES/A.swift"):
            with self.subTest(path=path):
                self.assert_error(
                    f"touches sensitive paths: {path}",
                    lambda path=path: check_pr_paths.check_paths(
                        root, context, (path,)
                    ),
                )

    def test_the_added_root_level_entries_are_sensitive(self):
        root = Path(tempfile.mkdtemp(prefix="check-pr-root-"))
        context = check_pr_paths.PullRequestContext(
            title="docs: governance update",
            body="",
            head_ref="agent/governance-update",
            base_oid=ZERO_OID,
            head_oid=ONE_OID,
        )
        for path in (
            "AGENTS.md",
            ".gitignore",
            ".python-version",
            "ArkDeck.xcodeproj/project.pbxproj",
        ):
            with self.subTest(path=path):
                self.assert_error(
                    f"touches sensitive paths: {path}",
                    lambda path=path: check_pr_paths.check_paths(
                        root, context, (path,)
                    ),
                )

    def test_the_governance_chain_stays_open_to_task_less_pull_requests(self):
        """openspec/** is deliberately absent from the table.

        propose, approval, verify and archive carriers all touch
        openspec/** without declaring a task; listing it would sever the
        chain, and the path it would protect is closed by base authority
        instead.
        """
        root = Path(tempfile.mkdtemp(prefix="check-pr-governance-"))
        result = check_pr_paths.check_paths(
            root,
            check_pr_paths.PullRequestContext(
                title="governance(CHG-2026-999): propose",
                body="",
                head_ref="agent/chg-999-propose",
                base_oid=ZERO_OID,
                head_oid=ONE_OID,
            ),
            (
                "openspec/changes/chg-999/proposal.md",
                "openspec/changes/chg-999/tasks.md",
                "docs/release/notes.md",
            ),
        )
        self.assertIsNone(result.task_id)

    def test_allowed_path_matching_stays_case_sensitive(self):
        # Loosening this side would widen a task's authorised surface, so it
        # must not follow the sensitive side into case insensitivity.
        self.assertFalse(
            check_pr_paths.path_matches("Scripts/x.py", ("scripts/**",))
        )
        self.assertTrue(check_pr_paths.path_matches("scripts/x.py", ("scripts/**",)))

    # --- B-M2 / B-M3: the declaration itself cannot be smuggled ---

    def test_a_task_line_separator_does_not_reach_across_a_newline(self):
        context = check_pr_paths.PullRequestContext(
            title="docs: governance update",
            body="Task:\nTASK-EVIL-002\n",
            head_ref="agent/governance-update",
            base_oid=ZERO_OID,
            head_oid=ONE_OID,
        )
        self.assertIsNone(check_pr_paths.resolve_task_declaration(context))
        bound = check_pr_paths.PullRequestContext(
            title="docs: governance update",
            body="Task: TASK-EVIL-002\n",
            head_ref="agent/governance-update",
            base_oid=ZERO_OID,
            head_oid=ONE_OID,
        )
        self.assertEqual(
            check_pr_paths.resolve_task_declaration(bound), "TASK-EVIL-002"
        )

    def test_a_confusable_title_token_is_an_error_not_a_silent_miss(self):
        # U+2011 non-breaking hyphen: renders as a declaration, matches no
        # token, so the ambiguity check never saw the disagreement.
        context = check_pr_paths.PullRequestContext(
            title="feat(TASK‑HLR-003): looks declared, matched nothing",
            body="Task: TASK-MECH-004\n",
            head_ref="agent/task-mech-004",
            base_oid=ZERO_OID,
            head_oid=ONE_OID,
        )
        self.assert_error(
            "confusable task token",
            lambda: check_pr_paths.resolve_task_declaration(context),
        )
        plain = check_pr_paths.PullRequestContext(
            title="feat(TASK-MECH-004): plain hyphens",
            body="Task: TASK-MECH-004\n",
            head_ref="agent/task-mech-004",
            base_oid=ZERO_OID,
            head_oid=ONE_OID,
        )
        self.assertEqual(
            check_pr_paths.resolve_task_declaration(plain), "TASK-MECH-004"
        )

    # --- B-M8: the read-back is a read-back ---

    def test_identity_only_prints_the_number_carried_by_the_api_response(self):
        temporary = tempfile.TemporaryDirectory(prefix="check-pr-identity-")
        self.addCleanup(temporary.cleanup)
        payload = Path(temporary.name) / "pull.json"
        pull_request = PullRequestPathTests.pull_request_api(
            PullRequestPathTests()
        )
        payload.write_text(json.dumps(pull_request), encoding="utf-8")
        argv = [
            "--repo-root",
            str(Path(__file__).resolve().parents[1]),
            "--pull-request",
            str(payload),
            "--identity-only",
            "--expected-repository",
            "ArkDeck/ArkDeck",
            "--expected-number",
            "483",
            "--expected-base-ref",
            "main",
            "--expected-head-ref",
            "agent/task-hlr-001a-auto-ci",
            "--expected-head-oid",
            ONE_OID,
            "--expected-author",
            "github-actions[bot]",
        ]
        completed = subprocess.run(
            [sys.executable, str(Path(__file__).resolve()).replace(
                "test_check_pr_paths.py", "check_pr_paths.py"
            ), *argv],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(completed.stdout.strip(), "483")

        # Mismatched payload: the value printed must come from the response,
        # so a disagreement is a rejection rather than a confirming echo.
        pull_request["number"] = 484
        payload.write_text(json.dumps(pull_request), encoding="utf-8")
        completed = subprocess.run(
            [sys.executable, str(Path(__file__).resolve()).replace(
                "test_check_pr_paths.py", "check_pr_paths.py"
            ), *argv],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(completed.returncode, 1)
        self.assertIn("number does not match", completed.stderr)

    def test_identity_only_reads_the_number_back_rather_than_echoing_it(self):
        """Pins where the printed number comes from, not just its value.

        With identity validation in force the echo and the read-back always
        agree, so no black-box case can tell them apart — which is exactly
        how a guard becomes decorative. Suspending the comparison exposes
        the source: the echo would still print the expectation.
        """
        temporary = tempfile.TemporaryDirectory(prefix="check-pr-readback-")
        self.addCleanup(temporary.cleanup)
        payload = Path(temporary.name) / "pull.json"
        pull_request = PullRequestPathTests.pull_request_api(
            PullRequestPathTests(), number=901
        )
        payload.write_text(json.dumps(pull_request), encoding="utf-8")

        original = check_pr_paths.validate_pull_request_identity
        check_pr_paths.validate_pull_request_identity = (
            lambda pull_request, **expectations: (
                check_pr_paths.pull_request_context_from_object(pull_request)
            )
        )
        self.addCleanup(
            setattr, check_pr_paths, "validate_pull_request_identity", original
        )

        buffer = io.StringIO()
        with contextlib.redirect_stdout(buffer):
            exit_code = check_pr_paths.main(
                [
                    "--repo-root",
                    str(Path(__file__).resolve().parents[1]),
                    "--pull-request",
                    str(payload),
                    "--identity-only",
                    "--expected-repository",
                    "ArkDeck/ArkDeck",
                    "--expected-number",
                    "483",
                    "--expected-base-ref",
                    "main",
                    "--expected-head-ref",
                    "agent/task-hlr-001a-auto-ci",
                    "--expected-head-oid",
                    ONE_OID,
                    "--expected-author",
                    "github-actions[bot]",
                ]
            )
        self.assertEqual(exit_code, 0)
        self.assertEqual(buffer.getvalue().strip(), "901")


if __name__ == "__main__":
    unittest.main(verbosity=2)
