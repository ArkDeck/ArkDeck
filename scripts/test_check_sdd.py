#!/usr/bin/env python3
"""Offline contract tests for check_sdd change-level validation."""

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

    def test_real_baseline_has_active_covered_scope_and_main_passes(self):
        changes_dir = check_sdd.OPENSPEC / "changes"
        scoped_changes = {
            path.parent.name for path in changes_dir.glob("chg-*/scope.yaml")
        }
        self.assertEqual(
            scoped_changes,
            {
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


class RevisionConsistencyTests(unittest.TestCase):
    def make_change(
        self,
        root: Path,
        name: str,
        proposal_revision: int | None = 1,
        acceptance_revision: int | None = 1,
        verification_revision: int | None = 1,
        *,
        include_acceptance: bool = True,
        verification_header: str | None = None,
    ) -> Path:
        change = root / name
        change.mkdir(parents=True)
        change_id = name.upper()
        proposal = {
            "id": change_id,
            "status": "approved",
            "class": "implementation-only",
        }
        if proposal_revision is not None:
            proposal["revision"] = proposal_revision
        (change / "proposal.md").write_text(
            "---\n"
            + yaml.safe_dump(proposal, sort_keys=False)
            + "---\n\n# Proposal\n",
            encoding="utf-8",
        )
        if include_acceptance:
            acceptance = {"change_id": change_id, "cases": []}
            if acceptance_revision is not None:
                acceptance["change_revision"] = acceptance_revision
            (change / "acceptance-cases.yaml").write_text(
                yaml.safe_dump(acceptance, sort_keys=False), encoding="utf-8"
            )
        if verification_header is None and verification_revision is not None:
            verification_header = (
                f"> Change:{change_id}@r{verification_revision}"
            )
        verification_lines = ["# Verification"]
        if verification_header is not None:
            verification_lines.extend(["", verification_header])
        (change / "verification.md").write_text(
            "\n".join(verification_lines) + "\n", encoding="utf-8"
        )
        return change

    def revision_errors(self, changes_dir: Path) -> list[str]:
        start = len(check_sdd.errors)
        try:
            check_sdd.check_change_revision_consistency(changes_dir)
            return list(check_sdd.errors[start:])
        finally:
            del check_sdd.errors[start:]

    def test_matching_three_way_and_two_way_fixtures_pass(self):
        with tempfile.TemporaryDirectory(prefix="check-sdd-revision-match-") as temp:
            root = Path(temp)
            self.make_change(root, "chg-three-way")
            self.make_change(root, "chg-two-way", include_acceptance=False)
            self.assertEqual(self.revision_errors(root), [])

    def test_each_single_carrier_drift_emits_one_error_with_all_values(self):
        cases = (
            ("proposal", 2, 1, 1),
            ("acceptance", 1, 2, 1),
            ("verification", 1, 1, 2),
        )
        for label, proposal, acceptance, verification in cases:
            with self.subTest(label=label), tempfile.TemporaryDirectory(
                prefix=f"check-sdd-revision-{label}-"
            ) as temp:
                root = Path(temp)
                self.make_change(
                    root,
                    f"chg-{label}",
                    proposal_revision=proposal,
                    acceptance_revision=acceptance,
                    verification_revision=verification,
                )
                failures = self.revision_errors(root)
                self.assertEqual(len(failures), 1)
                self.assertIn("revision consistency failed", failures[0])
                self.assertIn(f"proposal revision={proposal}", failures[0])
                self.assertIn(
                    f"acceptance change_revision={acceptance}", failures[0]
                )
                self.assertIn(f"verification @r={verification}", failures[0])

    def test_missing_and_unparseable_verification_headers_fail_closed(self):
        cases = (
            ("missing", None, "<missing>"),
            ("unparseable", "> Change:CHG-BAD@rx", "<unparseable>"),
        )
        for label, header, expected in cases:
            with self.subTest(label=label), tempfile.TemporaryDirectory(
                prefix=f"check-sdd-revision-header-{label}-"
            ) as temp:
                root = Path(temp)
                self.make_change(
                    root,
                    f"chg-{label}",
                    verification_revision=None,
                    verification_header=header,
                )
                failures = self.revision_errors(root)
                self.assertEqual(len(failures), 1)
                self.assertIn(f"verification @r={expected}", failures[0])

    def test_missing_structured_revision_fields_fail_closed(self):
        cases = (
            ("proposal", None, 1, "proposal revision=<missing>"),
            (
                "acceptance",
                1,
                None,
                "acceptance change_revision=<missing>",
            ),
        )
        for label, proposal, acceptance, expected in cases:
            with self.subTest(label=label), tempfile.TemporaryDirectory(
                prefix=f"check-sdd-revision-field-{label}-"
            ) as temp:
                root = Path(temp)
                self.make_change(
                    root,
                    f"chg-{label}",
                    proposal_revision=proposal,
                    acceptance_revision=acceptance,
                )
                failures = self.revision_errors(root)
                self.assertEqual(len(failures), 1)
                self.assertIn(expected, failures[0])

    def test_two_way_mismatch_names_absent_acceptance_carrier(self):
        with tempfile.TemporaryDirectory(prefix="check-sdd-revision-two-way-") as temp:
            root = Path(temp)
            self.make_change(
                root,
                "chg-two-way-drift",
                verification_revision=2,
                include_acceptance=False,
            )
            failures = self.revision_errors(root)
            self.assertEqual(len(failures), 1)
            self.assertIn("acceptance change_revision=<not-present>", failures[0])
            self.assertIn("proposal revision=1", failures[0])
            self.assertIn("verification @r=2", failures[0])

    def test_archived_fixture_is_skipped(self):
        with tempfile.TemporaryDirectory(prefix="check-sdd-revision-archive-") as temp:
            root = Path(temp)
            self.make_change(
                root / "archive",
                "chg-archived-drift",
                proposal_revision=3,
                acceptance_revision=2,
                verification_revision=1,
            )
            self.assertEqual(self.revision_errors(root), [])


class StructuredPinsTests(unittest.TestCase):
    def write_document(
        self,
        root: Path,
        change_name: str,
        text: str,
        filename: str = "tasks.md",
    ) -> Path:
        change = root / change_name
        change.mkdir(parents=True, exist_ok=True)
        path = change / filename
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
        return path

    def pins_errors(self, changes_dir: Path) -> list[str]:
        start = len(check_sdd.errors)
        try:
            check_sdd.check_structured_pins(changes_dir)
            return list(check_sdd.errors[start:])
        finally:
            del check_sdd.errors[start:]

    @staticmethod
    def carrier(body: str) -> str:
        return f"# Fixture\n\n  ```yaml pins   \n{body}\n  ```   \n"

    def test_legal_blob_commit_and_sha256_pass(self):
        body = (
            "  - path: Packages/One.swift\n"
            f"    blob: {'aA' * 20}\n"
            "  - artifact: openspec/contracts/example.yaml\n"
            f"    commit: {'B' * 40}\n"
            f"    sha256: {'c' * 64}"
        )
        with tempfile.TemporaryDirectory(prefix="check-sdd-pins-valid-") as temp:
            root = Path(temp)
            self.write_document(root, "chg-valid", self.carrier(body))
            self.assertEqual(self.pins_errors(root), [])

    def test_schema_and_digest_failures_are_one_named_error_per_block(self):
        valid_blob = "a" * 40
        cases = (
            ("blob-39", f"- path: one\n  blob: {'a' * 39}", "blob must be a 40-hex string"),
            ("blob-41", f"- path: one\n  blob: {'a' * 41}", "blob must be a 40-hex string"),
            ("sha-63", f"- artifact: one\n  sha256: {'a' * 63}", "sha256 must be a 64-hex string"),
            ("placeholder", "- path: one\n  blob: <40-hex git OID>", "blob must be a 40-hex string"),
            ("unknown", f"- path: one\n  blob: {valid_blob}\n  owner: agent", "unknown key 'owner'"),
            ("duplicate", f"- blob: {valid_blob}\n  blob: {'b' * 40}", "YAML parse failed: duplicate mapping key"),
            ("mapping-top", f"path: one\nblob: {valid_blob}", "top-level must be a non-empty sequence"),
            ("scalar-top", "not-a-sequence", "top-level must be a non-empty sequence"),
            ("empty-sequence", "[]", "top-level must be a non-empty sequence"),
            ("scalar-item", "- not-a-mapping", "item 1 must be a mapping"),
            ("empty-path", f"- path: '   '\n  blob: {valid_blob}", "path must be a non-empty string"),
            ("bad-artifact", f"- artifact: 7\n  blob: {valid_blob}", "artifact must be a non-empty string"),
            ("bad-scalar", "- path: one\n  blob: 123", "blob must be a 40-hex string"),
            ("no-digest", "- path: one", "item 1 must contain a digest key"),
            ("empty-block", "", "top-level must be a non-empty sequence"),
            ("non-yaml", "- path: [", "YAML parse failed:"),
        )
        for label, body, expected in cases:
            with self.subTest(label=label), tempfile.TemporaryDirectory(
                prefix=f"check-sdd-pins-{label}-"
            ) as temp:
                root = Path(temp)
                path = self.write_document(
                    root, f"chg-{label}", self.carrier(body)
                )
                failures = self.pins_errors(root)
                self.assertEqual(len(failures), 1, failures)
                self.assertIn(f"ERROR {check_sdd.rel(path)}:", failures[0])
                self.assertIn("pins block at opening line 3 invalid:", failures[0])
                self.assertIn(expected, failures[0])

    def test_multiple_reasons_are_sorted_inside_one_error(self):
        body = "- owner: agent\n  path: ''\n  blob: short"
        with tempfile.TemporaryDirectory(prefix="check-sdd-pins-reasons-") as temp:
            root = Path(temp)
            self.write_document(root, "chg-reasons", self.carrier(body))
            failures = self.pins_errors(root)
            self.assertEqual(len(failures), 1)
            self.assertTrue(
                failures[0].endswith(
                    "item 1 blob must be a 40-hex string; "
                    "item 1 has unknown key 'owner'; "
                    "item 1 path must be a non-empty string"
                ),
                failures[0],
            )

    def test_unterminated_carrier_is_one_named_error(self):
        with tempfile.TemporaryDirectory(prefix="check-sdd-pins-open-") as temp:
            root = Path(temp)
            path = self.write_document(
                root,
                "chg-open",
                "# Fixture\n```yaml pins\n- path: one\n  blob: " + "a" * 40 + "\n",
            )
            failures = self.pins_errors(root)
            self.assertEqual(len(failures), 1)
            self.assertIn(f"ERROR {check_sdd.rel(path)}:", failures[0])
            self.assertIn("opening line 2 invalid: unterminated fence", failures[0])

    def test_noncarriers_documents_without_carriers_and_archive_are_skipped(self):
        invalid_body = "- path: one\n  blob: <placeholder>"
        with tempfile.TemporaryDirectory(prefix="check-sdd-pins-skip-") as temp:
            root = Path(temp)
            self.write_document(
                root,
                "chg-example",
                f"```yaml pin-example\n{invalid_body}\n```\n",
            )
            self.write_document(
                root,
                "chg-extra-info",
                f"```yaml pins extra\n{invalid_body}\n```\n",
            )
            self.write_document(
                root,
                "chg-no-carrier",
                "# Pins\n\nblob: <placeholder>\n",
            )
            self.write_document(
                root / "archive",
                "chg-archived",
                f"```yaml pins\n{invalid_body}\n```\n",
            )
            self.assertEqual(self.pins_errors(root), [])

    def test_real_baseline_and_template_contract_pass(self):
        self.assertEqual(
            self.pins_errors(check_sdd.OPENSPEC / "changes"), []
        )
        template = (
            check_sdd.OPENSPEC / "templates" / "change" / "tasks.md"
        ).read_text(encoding="utf-8")
        self.assertIn("```yaml pin-example", template)
        self.assertIn("info string 改为 `yaml pins`", template)
        self.assertIn("完整、真实的 40-hex Git OID 或 64-hex sha256", template)


class ClaimSurfaceEndsWithItsTask(unittest.TestCase):
    """A-H1. The scan stopped only at the next top-level bullet, so non-bullet
    lines were skipped rather than ending the surface — and an indented line
    under a LATER `## TASK-` heading was appended to the previous task's claim.
    An acceptance ID mentioned in one task's prose therefore counted as claimed
    by the task before it, in the check the governance model leans on hardest.
    """

    def _errors(self, tasks_text, acceptance):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            change = root / "chg-2026-900-probe"
            change.mkdir(parents=True)
            (change / "scope.yaml").write_text(
                yaml.safe_dump({"schema": "arkdeck-change-scope-1",
                                "change_id": "chg-2026-900-probe", "revision": 1,
                                "requirements": [], "acceptance": acceptance},
                               sort_keys=False), encoding="utf-8")
            (change / "tasks.md").write_text(tasks_text, encoding="utf-8")
            check_sdd.errors.clear()
            check_sdd.check_change_scope_coverage(root)
            return list(check_sdd.errors)

    UNCLAIMED = """## TASK-X-001
- Requirements/AC:REQ-X-001

## TASK-X-002 narrative
    AC-X-002-01 appears only in indented prose here
- Status:ready
"""

    CLAIMED = """## TASK-X-001
- Requirements/AC:
  - AC-X-002-01
- Status:ready
"""

    def test_prose_under_a_later_task_is_not_a_claim(self):
        self.assertEqual(len(self._errors(self.UNCLAIMED, ["AC-X-002-01"])), 1)

    def test_a_real_indented_claim_still_counts(self):
        self.assertEqual(self._errors(self.CLAIMED, ["AC-X-002-01"]), [])

    def test_a_heading_of_any_level_ends_the_surface(self):
        text = ("## TASK-X-001\n- Requirements/AC:REQ-X-001\n\n"
                "### Deliverables\n    AC-X-002-01 in a deliverables note\n")
        self.assertEqual(len(self._errors(text, ["AC-X-002-01"])), 1)


class EmptyGovernanceDocumentsAreRefused(unittest.TestCase):
    """A-H2 / A-M3. An empty file, a comments-only file and a literal `null`
    all parse to None without raising, and every caller wrote
    `if not data: return` — so a truncated governance file skipped its whole
    check while the run still exited 0."""

    def _scope_errors(self, scope_text):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            change = root / "chg-2026-900-probe"
            change.mkdir(parents=True)
            (change / "scope.yaml").write_text(scope_text, encoding="utf-8")
            (change / "tasks.md").write_text("## TASK-X-001\n- Status:ready\n",
                                             encoding="utf-8")
            check_sdd.errors.clear()
            check_sdd.check_change_scope_coverage(root)
            return list(check_sdd.errors)

    def test_a_comments_only_scope_is_an_error(self):
        self.assertTrue(self._scope_errors("# just a comment\n"))

    def test_an_empty_scope_is_an_error(self):
        self.assertTrue(self._scope_errors(""))

    def test_a_literal_null_scope_is_an_error(self):
        self.assertTrue(self._scope_errors("null\n"))

    def test_a_real_scope_is_not(self):
        good = yaml.safe_dump({"schema": "arkdeck-change-scope-1",
                               "change_id": "chg-2026-900-probe", "revision": 1,
                               "requirements": [], "acceptance": []},
                              sort_keys=False)
        self.assertEqual(self._scope_errors(good), [])


class StatusLinesArePairedWithTheirTask(unittest.TestCase):
    """A-M1. Two totals were compared, so a task with two status-looking lines
    paid for a task with none; and the vocabulary had no trailing boundary, so
    `- Status:readyish` counted as legal."""

    def _errors(self, tasks_text):
        """Drives check_changes() itself.

        A first version of this helper re-implemented the pairing loop inside
        the test, so it asserted its own copy of the logic: the mutation that
        disabled the production check survived untouched. That is the
        tautological-assertion shape this repository has been bitten by
        repeatedly, and the mutation harness is what exposed it.
        """
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            change = root / "changes" / "chg-2026-900-probe"
            change.mkdir(parents=True)
            (root / "changes" / "archive").mkdir(exist_ok=True)
            (root / "changes" / "README.md").write_text("", encoding="utf-8")
            (change / "proposal.md").write_text(
                "---\nid: CHG-2026-900-probe\nstatus: approved\n"
                "class: implementation-only\n---\n", encoding="utf-8")
            (change / "verification.md").write_text("", encoding="utf-8")
            (change / "tasks.md").write_text(tasks_text, encoding="utf-8")
            check_sdd.errors.clear()
            original, check_sdd.OPENSPEC = check_sdd.OPENSPEC, root
            try:
                check_sdd.check_changes()
            finally:
                check_sdd.OPENSPEC = original
            return [e for e in check_sdd.errors if "Status lines" in e]

    def test_a_task_with_no_status_is_caught_even_when_another_has_two(self):
        text = ("## TASK-A-001\n- Status:ready\n- Status:done\n"
                "## TASK-B-001\n- Risk:low\n")
        self.assertEqual(len(self._errors(text)), 2)

    def test_one_status_per_task_is_clean(self):
        text = "## TASK-A-001\n- Status:ready\n## TASK-B-001\n- Status:done\n"
        self.assertEqual(self._errors(text), [])

    def test_the_vocabulary_has_a_trailing_boundary(self):
        for bad in ("- Status:readyish", "- Status:done_later", "- Status:blockedX"):
            with self.subTest(line=bad):
                self.assertIsNone(check_sdd.TASK_STATUS_RE.match(bad))

    def test_the_real_punctuation_shapes_still_match(self):
        for good in ("- Status:ready", "- Status: done",
                     "- Status:blocked（前置：①）", "- Status：ready"):
            with self.subTest(line=good):
                self.assertIsNotNone(check_sdd.TASK_STATUS_RE.match(good))


class DuplicateCapabilityIdsAreReported(unittest.TestCase):
    """A-M2. A dict comprehension kept the last entry, so the first entry's
    fields were never validated and the 1:1 comparison could not see it."""

    def _errors(self, capabilities):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            (root / "contracts").mkdir(parents=True)
            (root / "specs" / "nav").mkdir(parents=True)
            (root / "specs" / "nav" / "spec.md").write_text("", encoding="utf-8")
            (root / "contracts" / "capability-registry.yaml").write_text(
                yaml.safe_dump({"capabilities": capabilities}, sort_keys=False),
                encoding="utf-8")
            check_sdd.errors.clear()
            original, check_sdd.OPENSPEC = check_sdd.OPENSPEC, root
            try:
                check_sdd.check_capability_registry()
            finally:
                check_sdd.OPENSPEC = original
            return list(check_sdd.errors)

    def test_a_duplicate_id_is_an_error(self):
        errors = self._errors([{"id": "nav", "release": "required"},
                               {"id": "nav", "release": "bogus"}])
        self.assertTrue(any("duplicate capability id" in e for e in errors))

    def test_a_clean_registry_has_no_duplicate_error(self):
        errors = self._errors([{"id": "nav", "release": "required"}])
        self.assertFalse(any("duplicate capability id" in e for e in errors))


class PresentButNullFieldsDoNotCrashTheRun(unittest.TestCase):
    """A-M4. `data.get(k, [])` returns None for a key present with a null
    value, so `None + []` and `for x in None` aborted the whole run at the
    first bad file — every later check went unreported."""

    def test_a_null_profiles_key_is_reported_not_raised(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            (root / "platforms").mkdir(parents=True)
            (root / "integrations").mkdir(parents=True)
            (root / "verification").mkdir(parents=True)
            (root / "platforms" / "PLATFORM-PROFILES.lock.yaml").write_text(
                "profiles:\ncatalogs:\n", encoding="utf-8")
            (root / "integrations" / "INTEGRATION-PROFILES.lock.yaml").write_text(
                "profiles: []\n", encoding="utf-8")
            (root / "verification" / "core-conformance.yaml").write_text(
                "safety_coverage:\n", encoding="utf-8")
            check_sdd.errors.clear()
            original, check_sdd.OPENSPEC = check_sdd.OPENSPEC, root
            try:
                check_sdd.check_locks_and_conformance(set())
            finally:
                check_sdd.OPENSPEC = original

    def test_non_mapping_front_matter_is_reported_not_raised(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            change = root / "changes" / "chg-2026-900-probe"
            change.mkdir(parents=True)
            (change / "proposal.md").write_text("---\njust a string\n---\n",
                                                encoding="utf-8")
            for name in ("tasks.md", "verification.md"):
                (change / name).write_text("## TASK-X-001\n- Status:ready\n",
                                           encoding="utf-8")
            check_sdd.errors.clear()
            original, check_sdd.OPENSPEC = check_sdd.OPENSPEC, root
            try:
                check_sdd.check_changes()
            finally:
                check_sdd.OPENSPEC = original
            self.assertTrue(
                any("front matter must be a mapping" in e for e in check_sdd.errors))


class StrayEntriesUnderChangesAreReported(unittest.TestCase):
    """A-L5. Anything not matching chg-*/archive/README was unvalidated,
    including a name differing only in case on a case-sensitive filesystem."""

    def _errors(self, extra_names):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            (root / "changes" / "archive").mkdir(parents=True)
            (root / "changes" / "README.md").write_text("", encoding="utf-8")
            for name in extra_names:
                (root / "changes" / name).mkdir()
            check_sdd.errors.clear()
            original, check_sdd.OPENSPEC = check_sdd.OPENSPEC, root
            try:
                check_sdd.check_changes()
            finally:
                check_sdd.OPENSPEC = original
            return [e for e in check_sdd.errors if "unexpected entry" in e]

    def test_an_uppercase_change_directory_is_reported(self):
        self.assertTrue(self._errors(["CHG-2026-099-shouting"]))

    def test_a_stray_directory_is_reported(self):
        self.assertTrue(self._errors(["scratch"]))

    def test_the_expected_entries_are_not_reported(self):
        self.assertEqual(self._errors([]), [])


class BothSuitesRunInCI(unittest.TestCase):
    """A-H3. Neither this suite nor the host-loop suite was executed by any
    workflow, so their properties held only when someone remembered."""

    WORKFLOW = Path(__file__).resolve().parent.parent / ".github" / "workflows" / "sdd-guard.yml"

    def test_this_suite_is_wired_in(self):
        self.assertIn("scripts/test_check_sdd.py",
                      self.WORKFLOW.read_text(encoding="utf-8"))

    def test_the_host_loop_suite_runs_via_discover(self):
        text = self.WORKFLOW.read_text(encoding="utf-8")
        self.assertIn("unittest discover -s host_loop", text,
                      "running a suite file directly collects only what its "
                      "module-level unittest.main() has seen so far")

    def test_the_guard_job_gained_no_permission_or_secret(self):
        text = self.WORKFLOW.read_text(encoding="utf-8")
        self.assertNotIn("secrets.", text)
        self.assertNotIn("pull_request_target", text)
        self.assertNotIn("contents: write", text)


if __name__ == "__main__":
    unittest.main(verbosity=2)
