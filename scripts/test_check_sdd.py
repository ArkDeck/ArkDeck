#!/usr/bin/env python3
"""Offline tests for check_sdd per-change acceptance scope coverage."""

from __future__ import annotations

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import yaml

import check_sdd


class ScopeCoverageTests(unittest.TestCase):
    def make_change(
        self,
        root: Path,
        name: str,
        acceptance: list[str] | None,
        tasks_text: str = "",
    ) -> Path:
        change = root / name
        change.mkdir(parents=True)
        if acceptance is not None:
            scope = {
                "schema": "arkdeck-change-scope-1",
                "change_id": name,
                "revision": 1,
                "requirements": [],
                "acceptance": acceptance,
            }
            (change / "scope.yaml").write_text(
                yaml.safe_dump(scope, sort_keys=False), encoding="utf-8"
            )
        (change / "tasks.md").write_text(tasks_text, encoding="utf-8")
        return change

    def scope_errors(self, changes_dir: Path) -> list[str]:
        start = len(check_sdd.errors)
        try:
            check_sdd.check_change_scope_coverage(changes_dir)
            return list(check_sdd.errors[start:])
        finally:
            del check_sdd.errors[start:]

    def test_ac_mac_hw_delimiters_backticks_and_continuation(self):
        acceptance = [
            "AC-X-001-01",
            "MAC-X-PORT-001",
            "HW-X-DEVICE-001",
            "FUTURE-X-SPACE-001",
            "FUTURE-X-CONTINUATION-001",
            "FUTURE.X+REGEX-001",
        ]
        tasks = """\
- Requirements/AC:`AC-X-001-01`、MAC-X-PORT-001；HW-X-DEVICE-001; FUTURE-X-SPACE-001
  FUTURE-X-CONTINUATION-001; FUTURE.X+REGEX-001; AC-OUTSIDE-SCOPE-001
- Status:ready
"""
        with tempfile.TemporaryDirectory(prefix="check-sdd-positive-") as temp:
            root = Path(temp)
            self.make_change(root, "chg-positive", acceptance, tasks)
            self.assertEqual(self.scope_errors(root), [])

    def test_one_missing_id_emits_one_named_error_then_restores(self):
        acceptance_id = "AC-X-003-01"
        with tempfile.TemporaryDirectory(prefix="check-sdd-missing-") as temp:
            root = Path(temp)
            change = self.make_change(
                root,
                "chg-missing",
                [acceptance_id],
                "- Requirements/AC:REQ-X-003\n- Status:ready\n",
            )
            failures = self.scope_errors(root)
            self.assertEqual(len(failures), 1)
            self.assertIn(
                f"scope acceptance {acceptance_id} "
                "未被任何任务 Requirements/AC 行认领",
                failures[0],
            )

            (change / "tasks.md").write_text(
                f"- Requirements/AC:{acceptance_id}\n- Status:ready\n",
                encoding="utf-8",
            )
            self.assertEqual(self.scope_errors(root), [])

    def test_identifier_sticking_and_case_mismatch_are_rejected(self):
        acceptance_id = "AC-X-004-01"
        claims = (
            f"prefix{acceptance_id}",
            f"{acceptance_id}suffix",
            acceptance_id.lower(),
        )
        with tempfile.TemporaryDirectory(prefix="check-sdd-boundary-") as temp:
            root = Path(temp)
            for index, claim in enumerate(claims):
                with self.subTest(claim=claim):
                    case_root = root / f"case-{index}"
                    self.make_change(
                        case_root,
                        "chg-boundary",
                        [acceptance_id],
                        f"- Requirements/AC:{claim}\n- Status:ready\n",
                    )
                    failures = self.scope_errors(case_root)
                    self.assertEqual(len(failures), 1)
                    self.assertIn(acceptance_id, failures[0])

    def test_tokens_outside_claim_surfaces_are_ignored(self):
        acceptance_id = "AC-X-005-01"
        tasks = f"""\
# Narrative {acceptance_id}

- Notes:
  {acceptance_id}
- Requirements/AC:REQ-X-005
- Verification:{acceptance_id}
"""
        with tempfile.TemporaryDirectory(prefix="check-sdd-interference-") as temp:
            root = Path(temp)
            self.make_change(root, "chg-interference", [acceptance_id], tasks)
            failures = self.scope_errors(root)
            self.assertEqual(len(failures), 1)
            self.assertIn(acceptance_id, failures[0])

    def test_shorthand_does_not_claim_unwritten_ids(self):
        missing_ids = [
            "AC-X-001-02",
            "AC-X-002-01",
            "AC-X-003-02",
            "MAC-X-PORT-002",
        ]
        tasks = """\
- Requirements/AC:AC-X-001-01…03、AC-X-002-*; AC-X-003-01/02
  MAC-X-PORT-001 等
- Status:ready
"""
        with tempfile.TemporaryDirectory(prefix="check-sdd-shorthand-") as temp:
            root = Path(temp)
            self.make_change(root, "chg-shorthand", missing_ids, tasks)
            failures = self.scope_errors(root)
            self.assertEqual(len(failures), len(missing_ids))
            for acceptance_id in missing_ids:
                self.assertEqual(
                    sum(acceptance_id in failure for failure in failures), 1
                )

    def test_change_without_scope_is_skipped(self):
        with tempfile.TemporaryDirectory(prefix="check-sdd-no-scope-") as temp:
            root = Path(temp)
            self.make_change(
                root,
                "chg-no-scope",
                None,
                "- Requirements/AC:AC-X-999-01\n",
            )
            self.assertEqual(self.scope_errors(root), [])

    def test_real_baseline_has_four_covered_scopes_and_main_passes(self):
        changes_dir = check_sdd.OPENSPEC / "changes"
        scoped_changes = {
            path.parent.name for path in changes_dir.glob("chg-*/scope.yaml")
        }
        self.assertEqual(
            scoped_changes,
            {
                "chg-2026-001-macos-m0a",
                "chg-2026-002-macos-m1-infrastructure",
                "chg-2026-005-hdc-parser-golden-registration",
                "chg-2026-006-dayu200-m0b-bringup",
            },
        )
        self.assertEqual(self.scope_errors(changes_dir), [])

        completed = subprocess.run(
            [sys.executable, str(check_sdd.REPO / "scripts" / "check_sdd.py")],
            cwd=check_sdd.REPO,
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
        self.assertIn(
            "check_sdd: 0 error(s), 0 warning(s), 111 acceptance IDs",
            completed.stdout,
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
