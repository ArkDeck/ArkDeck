#!/usr/bin/env python3
"""Offline contract tests for TASK-HLR-001 PR envelope v1."""

from __future__ import annotations

import ast
import sys
import tempfile
import unittest
from dataclasses import replace
from pathlib import Path


SCRIPT_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPT_ROOT))

import check_pr_paths
import pr_envelope


BASE_OID = "1" * 40
HEAD_OID = "2" * 40
CHANGE_ID = "CHG-2026-030-host-loop-runtime"
TASK_ID = "TASK-HLR-001"


class EnvelopeContractTests(unittest.TestCase):
    def envelope(self, **overrides) -> pr_envelope.Envelope:
        values = {
            "pr_type": "implementation",
            "change": CHANGE_ID,
            "task": TASK_ID,
            "base_oid": BASE_OID,
            "head_oid": HEAD_OID,
            "decision_grade": "D1",
            "depends_on": "#385",
            "evidence": (
                "openspec/changes/chg-2026-030-host-loop-runtime/evidence/run.md",
            ),
            "producer": "arkdeck-host",
            "run": "run-envelope-contract-001",
        }
        values.update(overrides)
        return pr_envelope.Envelope(**values)

    def body(self, **overrides) -> str:
        return pr_envelope.render_envelope(self.envelope(**overrides))

    def assert_error(self, expected: str, callback) -> None:
        with self.assertRaises(pr_envelope.EnvelopeError) as caught:
            callback()
        self.assertIn(expected, str(caught.exception))

    def make_repo(
        self,
        *,
        change_id: str = CHANGE_ID,
        task_id: str = TASK_ID,
        second_change: tuple[str, str] | None = None,
    ) -> tuple[tempfile.TemporaryDirectory, Path]:
        temporary = tempfile.TemporaryDirectory(prefix="hlr-envelope-")
        root = Path(temporary.name)

        def write_change(directory: str, proposal_id: str, task: str) -> None:
            change = root / "openspec" / "changes" / directory
            change.mkdir(parents=True)
            (change / "proposal.md").write_text(
                f"---\nid: {proposal_id}\nstatus: approved\n---\n",
                encoding="utf-8",
            )
            (change / "tasks.md").write_text(
                f"## {task} — fixture\n- Allowed paths:`scripts/host_loop/**`\n",
                encoding="utf-8",
            )

        write_change("chg-main", change_id, task_id)
        if second_change is not None:
            write_change("chg-second", second_change[0], second_change[1])
        return temporary, root

    def mutate_scalar(self, body: str, field: str, value: str) -> str:
        prefix = f"{field}: "
        lines = body.splitlines()
        index = next(i for i, line in enumerate(lines) if line.startswith(prefix))
        lines[index] = prefix + value
        return "\n".join(lines) + "\n"

    def remove_field(self, body: str, field: str) -> str:
        lines = body.splitlines()
        header = next(
            i
            for i, line in enumerate(lines)
            if line == f"{field}:" or line.startswith(f"{field}: ")
        )
        del lines[header]
        while header < len(lines) and lines[header].startswith("  - "):
            del lines[header]
        return "\n".join(lines) + "\n"

    def test_complete_task_round_trip_and_mech004_compatibility(self):
        envelope = self.envelope()
        body = pr_envelope.render_envelope(envelope)
        self.assertEqual(pr_envelope.parse_envelope(body), envelope)
        context = check_pr_paths.PullRequestContext(
            title="feat: envelope contract",
            body=body,
            head_ref="agent/task-hlr-001-envelope-r2",
            base_oid=BASE_OID,
            head_oid=HEAD_OID,
        )
        self.assertEqual(
            check_pr_paths.resolve_task_declaration(context),
            TASK_ID,
        )
        temporary, root = self.make_repo()
        self.addCleanup(temporary.cleanup)
        result = check_pr_paths.check_paths(
            root,
            context,
            ("scripts/host_loop/pr_envelope.py",),
        )
        self.assertEqual(result.task_id, TASK_ID)

    def test_change_bound_types_render_task_none_without_mech004_declaration(self):
        for pr_type in sorted(pr_envelope.CHANGE_BOUND_TYPES):
            with self.subTest(pr_type=pr_type):
                body = self.body(
                    pr_type=pr_type,
                    task="none",
                    evidence=("none: status carrier has no run evidence",),
                )
                parsed = pr_envelope.parse_envelope(body)
                self.assertEqual(parsed.task, "none")
                context = check_pr_paths.PullRequestContext(
                    title=f"{pr_type}: fixture",
                    body=body,
                    head_ref=f"agent/{pr_type}-fixture",
                    base_oid=BASE_OID,
                    head_oid=HEAD_OID,
                )
                self.assertIsNone(check_pr_paths.resolve_task_declaration(context))

    def test_all_seven_type_mappings_are_binary(self):
        for pr_type in sorted(pr_envelope.PR_TYPES):
            task = TASK_ID if pr_type in pr_envelope.TASK_BOUND_TYPES else "none"
            with self.subTest(pr_type=pr_type):
                parsed = pr_envelope.parse_envelope(self.body(pr_type=pr_type, task=task))
                self.assertEqual(parsed.pr_type, pr_type)

        for pr_type, task in (("implementation", "none"), ("proposal", TASK_ID)):
            with self.subTest(pr_type=pr_type, task=task):
                self.assert_error(
                    "requires Task:",
                    lambda pr_type=pr_type, task=task: pr_envelope.render_envelope(
                        self.envelope(pr_type=pr_type, task=task)
                    ),
                )

    def test_each_required_field_missing_is_named(self):
        body = self.body()
        for definition in pr_envelope.FIELD_DEFINITIONS:
            with self.subTest(field=definition.name):
                missing = self.remove_field(body, definition.name)
                self.assert_error(
                    f"missing envelope field: {definition.name}",
                    lambda missing=missing: pr_envelope.parse_envelope(missing),
                )

    def test_marker_missing_duplicate_and_reversed_fail(self):
        body = self.body()
        cases = {
            "missing": body.replace(pr_envelope.OPEN_MARKER + "\n", "", 1),
            "duplicate": pr_envelope.OPEN_MARKER + "\n" + body,
            "reversed": (
                pr_envelope.CLOSE_MARKER
                + "\n"
                + body.replace(pr_envelope.CLOSE_MARKER, pr_envelope.OPEN_MARKER)
            ),
        }
        for label, candidate in cases.items():
            with self.subTest(label=label):
                self.assert_error(
                    "marker",
                    lambda candidate=candidate: pr_envelope.parse_envelope(candidate),
                )

    def test_duplicate_unknown_and_out_of_order_fields_fail(self):
        body = self.body()
        duplicate = body.replace(
            "Task: TASK-HLR-001\n",
            "Task: TASK-HLR-001\nTask: TASK-HLR-001\n",
        )
        unknown = body.replace(
            "Task: TASK-HLR-001\n",
            "Task: TASK-HLR-001\nMystery: value\n",
        )
        reversed_fields = body.replace(
            "PR-Type: implementation\nChange: " + CHANGE_ID,
            "Change: " + CHANGE_ID + "\nPR-Type: implementation",
        )
        self.assert_error("duplicate envelope field: Task", lambda: pr_envelope.parse_envelope(duplicate))
        self.assert_error("unknown envelope field: Mystery", lambda: pr_envelope.parse_envelope(unknown))
        self.assert_error("field order", lambda: pr_envelope.parse_envelope(reversed_fields))

    def test_non_utf8_cr_and_ambiguous_whitespace_fail(self):
        self.assert_error("not UTF-8", lambda: pr_envelope.parse_envelope(b"\xff"))
        self.assert_error(
            "LF line endings",
            lambda: pr_envelope.parse_envelope(self.body().replace("\n", "\r\n")),
        )
        trailing = self.body().replace("Decision-Grade: D1", "Decision-Grade: D1 ")
        self.assert_error("trimmed single line", lambda: pr_envelope.parse_envelope(trailing))
        prefixed = "not-machine-content\n" + self.body()
        self.assert_error("first non-empty line", lambda: pr_envelope.parse_envelope(prefixed))

    def test_short_uppercase_and_same_oids_fail(self):
        for field, value, expected in (
            ("base_oid", "abc", "Base-OID"),
            ("head_oid", "A" * 40, "Head-OID"),
            ("head_oid", BASE_OID, "must differ"),
        ):
            with self.subTest(field=field, value=value):
                self.assert_error(
                    expected,
                    lambda field=field, value=value: pr_envelope.render_envelope(
                        replace(self.envelope(), **{field: value})
                    ),
                )

    def test_unknown_grade_and_multiple_task_lines_fail(self):
        self.assert_error(
            "Decision-Grade is unknown",
            lambda: pr_envelope.render_envelope(
                self.envelope(decision_grade="D3")
            ),
        )
        multiple = self.body().replace(
            "Task: TASK-HLR-001\n",
            "Task: TASK-HLR-001\nTask: TASK-HLR-002\n",
        )
        self.assert_error(
            "duplicate envelope field: Task",
            lambda: pr_envelope.parse_envelope(multiple),
        )

    def test_dependency_accepts_only_none_or_positive_pr(self):
        for accepted in ("none", "#1", "#385"):
            with self.subTest(accepted=accepted):
                parsed = pr_envelope.parse_envelope(
                    self.body(depends_on=accepted)
                )
                self.assertEqual(parsed.depends_on, accepted)
        for rejected in ("", "#0", "#-1", "385", "#1,#2", "https://example.invalid/1"):
            with self.subTest(rejected=rejected):
                self.assert_error(
                    "Depends-On",
                    lambda rejected=rejected: pr_envelope.render_envelope(
                        self.envelope(depends_on=rejected)
                    ),
                )

    def test_evidence_none_reason_is_exclusive_and_nonempty(self):
        accepted = self.body(evidence=("none: readiness has no run artifact",))
        self.assertEqual(
            pr_envelope.parse_envelope(accepted).evidence,
            ("none: readiness has no run artifact",),
        )
        for rejected in (
            ("none:",),
            ("none: ",),
            ("none: no run", "evidence/run.md"),
            (),
        ):
            with self.subTest(rejected=rejected):
                self.assert_error(
                    "Evidence",
                    lambda rejected=rejected: pr_envelope.render_envelope(
                        self.envelope(evidence=rejected)
                    ),
                )

    def test_evidence_rejects_absolute_traversal_url_and_empty_item(self):
        for rejected in (
            "/tmp/run.md",
            "../run.md",
            "evidence/../run.md",
            "https://example.invalid/run",
            "",
        ):
            with self.subTest(rejected=rejected):
                self.assert_error(
                    "Evidence",
                    lambda rejected=rejected: pr_envelope.render_envelope(
                        self.envelope(evidence=(rejected,))
                    ),
                )

    def test_configured_attribution_and_provider_sentinel_regression(self):
        parsed = pr_envelope.parse_envelope(
            self.body(producer="macos-host-01", run="opaque/01")
        )
        self.assertEqual(parsed.producer, "macos-host-01")
        self.assertEqual(parsed.run, "opaque/01")
        sentinel = "HARDCODED_PROVIDER_SENTINEL"
        self.assert_error(
            "explicitly configured",
            lambda: pr_envelope.render_envelope(
                self.envelope(producer=sentinel)
            ),
        )

        production = Path(pr_envelope.__file__).read_text(encoding="utf-8")
        template = (
            SCRIPT_ROOT.parent / "openspec" / "templates" / "agent-pr-body.md"
        ).read_text(encoding="utf-8")
        for forbidden in ("Clau" + "de", "Open" + "AI"):
            self.assertNotIn(forbidden, production)
            self.assertNotIn(forbidden, template)

    def test_human_notes_after_marker_cannot_override_machine_values(self):
        body = pr_envelope.render_envelope(
            self.envelope(),
            "Human summary.\nTask: TASK-HLR-999\nDecision-Grade: D2",
        )
        parsed = pr_envelope.parse_envelope(body)
        self.assertEqual(parsed.task, TASK_ID)
        self.assertEqual(parsed.decision_grade, "D1")
        self.assert_error(
            "must not contain envelope markers",
            lambda: pr_envelope.render_envelope(
                self.envelope(),
                f"Do not repeat {pr_envelope.OPEN_MARKER}",
            ),
        )

    def test_attribution_missing_duplicate_unknown_and_runtime_fail(self):
        body = self.body()
        missing = body.replace("  - run: run-envelope-contract-001\n", "")
        duplicate = body.replace(
            "  - run: run-envelope-contract-001\n",
            "  - run: run-envelope-contract-001\n  - run: duplicate\n",
        )
        unknown = body.replace(
            "  - run: run-envelope-contract-001\n",
            "  - provider: hidden-default\n",
        )
        runtime = body.replace(
            "  - runtime: host-loop/1",
            "  - runtime: host-loop/2",
        )
        for candidate, expected in (
            (missing, "exactly once"),
            (duplicate, "exactly once"),
            (unknown, "ordered"),
            (runtime, "runtime must be"),
        ):
            with self.subTest(expected=expected):
                self.assert_error(
                    expected,
                    lambda candidate=candidate: pr_envelope.parse_envelope(candidate),
                )

    def test_repository_scope_accepts_unique_active_change_and_task(self):
        temporary, root = self.make_repo()
        self.addCleanup(temporary.cleanup)
        envelope = pr_envelope.parse_envelope(self.body())
        self.assertEqual(
            pr_envelope.validate_repository_scope(envelope, root),
            envelope,
        )

    def test_repository_scope_rejects_zero_and_multiple_task_hits(self):
        missing_temp, missing_root = self.make_repo(task_id="TASK-HLR-999")
        self.addCleanup(missing_temp.cleanup)
        self.assert_error(
            "exactly one active task",
            lambda: pr_envelope.validate_repository_scope(
                self.envelope(), missing_root
            ),
        )

        duplicate_temp, duplicate_root = self.make_repo(
            second_change=("CHG-2026-999-other", TASK_ID)
        )
        self.addCleanup(duplicate_temp.cleanup)
        self.assert_error(
            "exactly one active task",
            lambda: pr_envelope.validate_repository_scope(
                self.envelope(), duplicate_root
            ),
        )

    def test_repository_scope_rejects_zero_multiple_and_mismatched_change(self):
        missing_temp, missing_root = self.make_repo(
            change_id="CHG-2026-999-other"
        )
        self.addCleanup(missing_temp.cleanup)
        self.assert_error(
            "exactly one active proposal",
            lambda: pr_envelope.validate_repository_scope(
                self.envelope(), missing_root
            ),
        )

        duplicate_temp, duplicate_root = self.make_repo(
            second_change=(CHANGE_ID, "TASK-HLR-999")
        )
        self.addCleanup(duplicate_temp.cleanup)
        self.assert_error(
            "exactly one active proposal",
            lambda: pr_envelope.validate_repository_scope(
                self.envelope(), duplicate_root
            ),
        )

        mismatch_temp, mismatch_root = self.make_repo(
            task_id="TASK-HLR-999",
            second_change=("CHG-2026-999-other", TASK_ID),
        )
        self.addCleanup(mismatch_temp.cleanup)
        self.assert_error(
            "does not belong",
            lambda: pr_envelope.validate_repository_scope(
                self.envelope(), mismatch_root
            ),
        )

    def test_parser_and_renderer_share_one_field_definition(self):
        source = Path(pr_envelope.__file__).read_text(encoding="utf-8")
        tree = ast.parse(source)
        assignments = [
            node
            for node in ast.walk(tree)
            if isinstance(node, (ast.Assign, ast.AnnAssign))
            and any(
                isinstance(target, ast.Name) and target.id == "FIELD_DEFINITIONS"
                for target in (
                    node.targets if isinstance(node, ast.Assign) else [node.target]
                )
            )
        ]
        self.assertEqual(len(assignments), 1)
        rendered_names = [
            line.split(":", 1)[0]
            for line in self.body().splitlines()
            if pr_envelope.FIELD_HEADER_RE.match(line)
        ]
        self.assertEqual(
            rendered_names,
            [definition.name for definition in pr_envelope.FIELD_DEFINITIONS],
        )

    def test_runtime_module_has_no_network_subprocess_or_shell_surface(self):
        source = Path(pr_envelope.__file__).read_text(encoding="utf-8")
        tree = ast.parse(source)
        imports = {
            alias.name
            for node in ast.walk(tree)
            if isinstance(node, (ast.Import, ast.ImportFrom))
            for alias in node.names
        }
        for forbidden in {"subprocess", "socket", "urllib", "http", "requests"}:
            self.assertNotIn(forbidden, imports)
        self.assertNotIn("os.system", source)
        self.assertNotIn("shell=True", source)

    def test_template_declares_v1_fields_in_canonical_order(self):
        template = (
            SCRIPT_ROOT.parent / "openspec" / "templates" / "agent-pr-body.md"
        ).read_text(encoding="utf-8")
        self.assertEqual(template.count(pr_envelope.OPEN_MARKER), 1)
        self.assertEqual(template.count(pr_envelope.CLOSE_MARKER), 1)
        positions = [
            template.index(f"{definition.name}:")
            for definition in pr_envelope.FIELD_DEFINITIONS
        ]
        self.assertEqual(positions, sorted(positions))


if __name__ == "__main__":
    unittest.main()
