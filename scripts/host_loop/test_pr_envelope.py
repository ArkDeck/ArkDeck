#!/usr/bin/env python3
"""Offline contract tests for TASK-HLR-001 PR envelope v1."""

from __future__ import annotations

import ast
import subprocess
import sys
import tempfile
import unittest
from dataclasses import replace
from pathlib import Path


HOST_LOOP_DIR = Path(__file__).resolve().parent
SCRIPTS_DIR = HOST_LOOP_DIR.parent
REPO_ROOT = SCRIPTS_DIR.parent
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

import check_pr_paths  # noqa: E402
from host_loop import pr_envelope  # noqa: E402


# A synthetic base worked here only while check_pr_paths read its allowlist
# from the working tree; it now resolves the base tree out of git
# (TASK-DEC-004), so a fabricated base is a fail-closed error rather than an
# unused string. HEAD stays the one commit guaranteed to exist even in the
# depth-1 clone CI checks out. The head OID is never resolved and must
# differ from the base, which the envelope contract requires.
BASE_OID = subprocess.run(
    ["git", "-C", str(REPO_ROOT), "rev-parse", "HEAD"],
    check=True,
    capture_output=True,
    text=True,
).stdout.strip()
HEAD_OID = "b" * 40
# Dynamically sampled: parse_and_validate binds Change to an ACTIVE
# change directory by design, so a pinned sample breaks on archive
# (TASK-NAV-002).
from host_loop.test_support import first_task_id, live_sample_change  # noqa: E402

CHANGE_ID = live_sample_change(REPO_ROOT)


def _task_with_literal_allowed_path() -> tuple[str, str]:
    """A sampled task plus one wildcard-free allowed path of its own.

    The MECH-004 end-to-end below runs check_paths against the real repo,
    so the changed file must fall inside the sampled task's declared
    surface; a literal beats synthesising a name from a glob.
    """
    definitions = check_pr_paths.load_task_definitions(REPO_ROOT)
    for task_id in sorted(definitions):
        task = definitions[task_id]
        if not task.tasks_file.match(f"*/{CHANGE_ID.lower()}/tasks.md"):
            continue
        patterns = check_pr_paths.extract_allowed_patterns(REPO_ROOT, task)
        literals = [p for p in patterns if "*" not in p]
        if literals:
            return task_id, literals[0]
    raise AssertionError(f"{CHANGE_ID} offers no task with a literal allowed path")


TASK_ID, TASK_LITERAL_PATH = _task_with_literal_allowed_path()


class EnvelopeContractTests(unittest.TestCase):
    def envelope(self, **overrides: object) -> pr_envelope.Envelope:
        values: dict[str, object] = {
            "pr_type": "implementation",
            "change": CHANGE_ID,
            "task": TASK_ID,
            "base_oid": BASE_OID,
            "head_oid": HEAD_OID,
            "decision_grade": "D0",
            "depends_on": "none",
            "evidence": (
                f"openspec/changes/{CHANGE_ID.lower()}/evidence/"
                f"runs/{TASK_ID}/run.md",
            ),
            "producer": "macos-host-01",
            "run": "run-001",
        }
        values.update(overrides)
        return pr_envelope.Envelope(**values)  # type: ignore[arg-type]

    def render(
        self,
        envelope: pr_envelope.Envelope | None = None,
        *,
        human_text: str = "",
    ) -> str:
        return pr_envelope.render_envelope(
            envelope or self.envelope(),
            REPO_ROOT,
            human_text=human_text,
        )

    def assert_contract_error(self, expected: str, callback) -> None:
        with self.assertRaises(pr_envelope.EnvelopeError) as caught:
            callback()
        self.assertIn(expected, str(caught.exception))

    def temporary_repo(
        self,
        *,
        change_id: str = CHANGE_ID,
        tasks: str = f"## {TASK_ID} — fixture\n- Status:ready\n",
        duplicate_change: bool = False,
    ) -> tuple[tempfile.TemporaryDirectory, Path]:
        temporary = tempfile.TemporaryDirectory(prefix="hlr-envelope-")
        root = Path(temporary.name)
        change = root / "openspec" / "changes" / "chg-one"
        change.mkdir(parents=True)
        (change / "proposal.md").write_text(
            f"---\nid: {change_id}\nstatus: approved\n---\n",
            encoding="utf-8",
        )
        (change / "tasks.md").write_text(tasks, encoding="utf-8")
        if duplicate_change:
            duplicate = root / "openspec" / "changes" / "chg-two"
            duplicate.mkdir(parents=True)
            (duplicate / "proposal.md").write_text(
                f"---\nid: {change_id}\nstatus: approved\n---\n",
                encoding="utf-8",
            )
            (duplicate / "tasks.md").write_text(tasks, encoding="utf-8")
        self.addCleanup(temporary.cleanup)
        return temporary, root

    def remove_field(self, rendered: str, field_name: str) -> str:
        lines = rendered.splitlines()
        start = next(
            index
            for index, line in enumerate(lines)
            if line == f"{field_name}:" or line.startswith(f"{field_name}: ")
        )
        end = start + 1
        if lines[start] == f"{field_name}:":
            while end < len(lines) and lines[end].startswith("  - "):
                end += 1
        return "\n".join((*lines[:start], *lines[end:])) + "\n"

    def replace_line(self, rendered: str, prefix: str, replacement: str) -> str:
        lines = rendered.splitlines()
        index = next(i for i, line in enumerate(lines) if line.startswith(prefix))
        lines[index] = replacement
        return "\n".join(lines) + "\n"

    def test_task_envelope_round_trip_is_canonical(self):
        rendered = self.render(human_text="Human summary after the machine block.")
        parsed = pr_envelope.parse_and_validate(rendered.encode("utf-8"), REPO_ROOT)
        self.assertEqual(parsed.envelope, self.envelope())
        self.assertEqual(parsed.human_text, "\nHuman summary after the machine block.")
        self.assertTrue(rendered.startswith(f"{pr_envelope.OPEN_MARKER}\n"))
        self.assertTrue(rendered.endswith("\n"))
        self.assertNotIn("\r", rendered)
        self.assertEqual(rendered.count(pr_envelope.OPEN_MARKER), 1)
        self.assertEqual(rendered.count(pr_envelope.CLOSE_MARKER), 1)

    def test_all_seven_pr_types_have_binary_task_mapping(self):
        for pr_type in sorted(pr_envelope.TASK_BOUND_TYPES):
            with self.subTest(pr_type=pr_type):
                parsed = pr_envelope.parse_and_validate(
                    self.render(self.envelope(pr_type=pr_type)),
                    REPO_ROOT,
                )
                self.assertEqual(parsed.envelope.task, TASK_ID)

        for pr_type in sorted(pr_envelope.CHANGE_BOUND_TYPES):
            with self.subTest(pr_type=pr_type):
                envelope = self.envelope(
                    pr_type=pr_type,
                    task="none",
                    decision_grade="D1",
                    evidence=("none: no task evidence exists at this gate",),
                )
                parsed = pr_envelope.parse_and_validate(self.render(envelope), REPO_ROOT)
                self.assertEqual(parsed.envelope.task, "none")

    def test_type_task_mismatches_fail(self):
        for pr_type in sorted(pr_envelope.TASK_BOUND_TYPES):
            with self.subTest(pr_type=pr_type):
                self.assert_contract_error(
                    "requires Task: TASK-*",
                    lambda pr_type=pr_type: self.render(
                        self.envelope(pr_type=pr_type, task="none")
                    ),
                )
        for pr_type in sorted(pr_envelope.CHANGE_BOUND_TYPES):
            with self.subTest(pr_type=pr_type):
                self.assert_contract_error(
                    "requires Task: none",
                    lambda pr_type=pr_type: self.render(
                        self.envelope(pr_type=pr_type, task=TASK_ID)
                    ),
                )

    def test_each_required_field_missing_fails_by_name(self):
        rendered = self.render()
        for field_name in pr_envelope.FIELD_NAMES:
            with self.subTest(field=field_name):
                malformed = self.remove_field(rendered, field_name)
                self.assert_contract_error(
                    field_name,
                    lambda malformed=malformed: pr_envelope.parse_envelope(malformed),
                )

    def test_markers_missing_duplicate_and_reversed_fail(self):
        rendered = self.render()
        without_open = rendered.replace(f"{pr_envelope.OPEN_MARKER}\n", "", 1)
        without_close = rendered.replace(f"{pr_envelope.CLOSE_MARKER}\n", "", 1)
        duplicate_open = f"{pr_envelope.OPEN_MARKER}\n{rendered}"
        duplicate_close = rendered + f"{pr_envelope.CLOSE_MARKER}\n"
        reversed_markers = rendered.replace(
            pr_envelope.OPEN_MARKER,
            "TEMP",
            1,
        ).replace(
            pr_envelope.CLOSE_MARKER,
            pr_envelope.OPEN_MARKER,
            1,
        ).replace("TEMP", pr_envelope.CLOSE_MARKER, 1)
        cases = (
            ("opening marker", without_open),
            ("closing marker", without_close),
            ("opening marker", duplicate_open),
            ("closing marker", duplicate_close),
            ("reversed", reversed_markers),
        )
        for expected, malformed in cases:
            with self.subTest(expected=expected):
                self.assert_contract_error(
                    expected,
                    lambda malformed=malformed: pr_envelope.parse_envelope(malformed),
                )

    def test_duplicate_unknown_out_of_order_and_free_text_fail(self):
        rendered = self.render()
        duplicate = rendered.replace(
            "PR-Type: implementation\n",
            "PR-Type: implementation\nPR-Type: implementation\n",
            1,
        )
        unknown = rendered.replace(
            "PR-Type: implementation\n",
            "PR-Type: implementation\nSurprise: no\n",
            1,
        )
        out_of_order = rendered.replace(
            f"PR-Type: implementation\nChange: {CHANGE_ID}\n",
            f"Change: {CHANGE_ID}\nPR-Type: implementation\n",
            1,
        )
        free_text = rendered.replace(
            "PR-Type: implementation\n",
            "PR-Type: implementation\nfree text\n",
            1,
        )
        for expected, malformed in (
            ("duplicate field", duplicate),
            ("unknown", unknown),
            ("out-of-order", out_of_order),
            ("unknown", free_text),
        ):
            with self.subTest(expected=expected):
                self.assert_contract_error(
                    expected,
                    lambda malformed=malformed: pr_envelope.parse_envelope(malformed),
                )

    def test_multiple_task_lines_and_inconsistent_task_identity_fail(self):
        rendered = self.render()
        duplicate_task = rendered.replace(
            f"Task: {TASK_ID}\n",
            f"Task: {TASK_ID}\nTask: {TASK_ID}\n",
            1,
        )
        self.assert_contract_error(
            "duplicate field Task",
            lambda: pr_envelope.parse_envelope(duplicate_task),
        )

        other_task = self.replace_line(rendered, "Task:", "Task: TASK-HLR-999")
        parsed = pr_envelope.parse_envelope(other_task)
        self.assert_contract_error(
            "found 0",
            lambda: pr_envelope.validate_envelope(parsed.envelope, REPO_ROOT),
        )

    def test_non_utf8_cr_and_ambiguous_whitespace_fail(self):
        rendered = self.render()
        trailing_scalar = rendered.replace(
            "Decision-Grade: D0\n",
            "Decision-Grade: D0 \n",
            1,
        )
        trailing_list = rendered.replace(
            "  - producer: macos-host-01\n",
            "  - producer: macos-host-01 \n",
            1,
        )
        cases: tuple[tuple[str, bytes | str], ...] = (
            ("valid UTF-8", b"\xff"),
            ("LF line endings", rendered.replace("\n", "\r\n")),
            ("ambiguous whitespace", trailing_scalar),
            ("ambiguous", trailing_list),
        )
        for expected, malformed in cases:
            with self.subTest(expected=expected):
                self.assert_contract_error(
                    expected,
                    lambda malformed=malformed: pr_envelope.parse_envelope(malformed),
                )

    def test_oid_grade_and_dependency_validation_is_fail_closed(self):
        invalid_values = (
            ("Base-OID", "short", "lowercase full 40-hex"),
            ("Base-OID", "A" * 40, "lowercase full 40-hex"),
            ("Head-OID", "B" * 40, "lowercase full 40-hex"),
            ("Decision-Grade", "D3", "D0, D1, or D2"),
            ("Depends-On", "#0", "positive decimal"),
            ("Depends-On", "#01", "positive decimal"),
            ("Depends-On", "400", "positive decimal"),
            ("Depends-On", "#1,#2", "positive decimal"),
        )
        rendered = self.render()
        for field_name, value, expected in invalid_values:
            with self.subTest(field=field_name, value=value):
                malformed = self.replace_line(
                    rendered,
                    f"{field_name}:",
                    f"{field_name}: {value}",
                )
                self.assert_contract_error(
                    expected,
                    lambda malformed=malformed: pr_envelope.parse_envelope(malformed),
                )

        same = replace(self.envelope(), head_oid=BASE_OID)
        self.assert_contract_error(
            "must differ",
            lambda: self.render(same),
        )

    def test_evidence_accepts_paths_or_one_reason_and_rejects_ambiguity(self):
        reason = self.envelope(
            pr_type="proposal",
            task="none",
            decision_grade="D1",
            evidence=("none: proposal registration has no task run",),
        )
        parsed = pr_envelope.parse_and_validate(self.render(reason), REPO_ROOT)
        self.assertEqual(parsed.envelope.evidence, reason.evidence)

        invalid_evidence = (
            ((), "must not be empty"),
            (("none:",), "non-empty reason"),
            (("none: ",), "non-empty reason"),
            (("none: reason", "README.md"), "only Evidence item"),
            (("/tmp/evidence.md",), "repository-relative"),
            (("C:/tmp/evidence.md",), "repository-relative"),
            (("../evidence.md",), "traverse"),
            (("./evidence.md",), "repository-relative"),
            (("https://example.invalid/evidence",), "repository-relative"),
            (("folder\\evidence.md",), "repository-relative"),
        )
        for evidence, expected in invalid_evidence:
            with self.subTest(evidence=evidence):
                self.assert_contract_error(
                    expected,
                    lambda evidence=evidence: self.render(
                        self.envelope(evidence=evidence)
                    ),
                )

    def test_attribution_is_configured_ordered_and_provider_neutral(self):
        rendered = self.render()
        invalid_payloads = (
            (
                rendered.replace("  - runtime: host-loop/1\n", "", 1),
                "producer, runtime, and run",
            ),
            (
                rendered.replace(
                    "  - producer: macos-host-01\n  - runtime: host-loop/1\n",
                    "  - runtime: host-loop/1\n  - producer: macos-host-01\n",
                    1,
                ),
                "ordered",
            ),
            (
                rendered.replace("  - runtime: host-loop/1\n", "  - runtime: host-loop/2\n", 1),
                "host-loop/1",
            ),
            (
                rendered.replace("  - run: run-001\n", "  - run: \n", 1),
                "empty or ambiguous",
            ),
        )
        for malformed, expected in invalid_payloads:
            with self.subTest(expected=expected):
                self.assert_contract_error(
                    expected,
                    lambda malformed=malformed: pr_envelope.parse_envelope(malformed),
                )

        self.assert_contract_error(
            "configured host",
            lambda: self.render(self.envelope(producer="provider:sentinel")),
        )
        self.assert_contract_error(
            "stable identifier",
            lambda: self.render(self.envelope(producer="host with spaces")),
        )

    def test_human_text_cannot_override_parsed_values(self):
        rendered = self.render()
        manually_extended = rendered + "\nTask: TASK-OTHER-999\n"
        parsed = pr_envelope.parse_envelope(manually_extended)
        self.assertEqual(parsed.envelope.task, TASK_ID)
        self.assertIn("TASK-OTHER-999", parsed.human_text)

        self.assert_contract_error(
            "field-like lines",
            lambda: self.render(human_text="Task: TASK-OTHER-999"),
        )
        self.assert_contract_error(
            "markers",
            lambda: self.render(human_text=pr_envelope.CLOSE_MARKER),
        )

    def test_change_and_task_bind_to_unique_active_repository_state(self):
        _, missing_change_root = self.temporary_repo(change_id="CHG-OTHER-001")
        self.assert_contract_error(
            "found 0",
            lambda: pr_envelope.validate_envelope(self.envelope(), missing_change_root),
        )

        _, duplicate_change_root = self.temporary_repo(duplicate_change=True)
        self.assert_contract_error(
            "found 2",
            lambda: pr_envelope.validate_envelope(self.envelope(), duplicate_change_root),
        )

        _, missing_task_root = self.temporary_repo(tasks="## TASK-HLR-999 — other\n")
        self.assert_contract_error(
            "found 0",
            lambda: pr_envelope.validate_envelope(self.envelope(), missing_task_root),
        )

        duplicate_tasks = (
            f"## {TASK_ID} — first\n- Status:ready\n\n"
            f"## {TASK_ID} — duplicate\n- Status:ready\n"
        )
        _, duplicate_task_root = self.temporary_repo(tasks=duplicate_tasks)
        self.assert_contract_error(
            "found 2",
            lambda: pr_envelope.validate_envelope(self.envelope(), duplicate_task_root),
        )

    def test_change_id_is_read_only_from_closed_front_matter(self):
        temporary = tempfile.TemporaryDirectory(prefix="hlr-envelope-frontmatter-")
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        change = root / "openspec" / "changes" / "chg-one"
        change.mkdir(parents=True)
        (change / "tasks.md").write_text(f"## {TASK_ID} — fixture\n", encoding="utf-8")

        proposal = change / "proposal.md"
        proposal.write_text(
            f"# no front matter\nid: {CHANGE_ID}\n",
            encoding="utf-8",
        )
        self.assert_contract_error(
            "must start with YAML front matter",
            lambda: pr_envelope.validate_envelope(self.envelope(), root),
        )

        proposal.write_text(
            f"---\nid: {CHANGE_ID}\n# missing close\n",
            encoding="utf-8",
        )
        self.assert_contract_error(
            "front matter is not closed",
            lambda: pr_envelope.validate_envelope(self.envelope(), root),
        )

        proposal.write_text(
            f"---\nid: {CHANGE_ID}\nid: {CHANGE_ID}\n---\n",
            encoding="utf-8",
        )
        self.assert_contract_error(
            "exactly one front-matter id",
            lambda: pr_envelope.validate_envelope(self.envelope(), root),
        )

    def test_mech_004_reads_task_and_allowed_paths_from_complete_envelope(self):
        rendered = self.render()
        context = check_pr_paths.PullRequestContext(
            title="feat: implement envelope contract",
            body=rendered,
            head_ref="agent/hlr-envelope-contract",
            base_oid=BASE_OID,
            head_oid=HEAD_OID,
        )
        self.assertEqual(check_pr_paths.resolve_task_declaration(context), TASK_ID)
        changed = (TASK_LITERAL_PATH,)
        result = check_pr_paths.check_paths(REPO_ROOT, context, changed)
        self.assertEqual(result.task_id, TASK_ID)
        self.assertEqual(result.changed_paths, changed)

        proposal = self.envelope(
            pr_type="proposal",
            task="none",
            decision_grade="D1",
            evidence=("none: proposal registration has no task run",),
        )
        proposal_context = check_pr_paths.PullRequestContext(
            title="docs: propose change",
            body=self.render(proposal),
            head_ref="agent/propose-change",
            base_oid=BASE_OID,
            head_oid=HEAD_OID,
        )
        self.assertIsNone(check_pr_paths.resolve_task_declaration(proposal_context))

    def test_template_has_exact_order_and_no_provider_attribution(self):
        template = (
            REPO_ROOT / "openspec" / "templates" / "agent-pr-body.md"
        ).read_text(encoding="utf-8")
        self.assertEqual(template.count(pr_envelope.OPEN_MARKER), 1)
        self.assertEqual(template.count(pr_envelope.CLOSE_MARKER), 1)
        positions = [template.index(f"{name}:") for name in pr_envelope.FIELD_NAMES]
        self.assertEqual(positions, sorted(positions))
        self.assertIn("producer: {{CONFIGURED_PRODUCER_ID}}", template)
        self.assertIn("runtime: host-loop/1", template)
        for provider_brand in ("claude", "openai", "anthropic", "gemini", "copilot"):
            self.assertNotIn(provider_brand, template.lower())

    def test_runtime_module_is_standard_library_only_and_has_no_command_surface(self):
        source_path = HOST_LOOP_DIR / "pr_envelope.py"
        source = source_path.read_text(encoding="utf-8")
        tree = ast.parse(source)
        imported_roots: set[str] = set()
        forbidden_calls: list[str] = []
        for node in ast.walk(tree):
            if isinstance(node, ast.Import):
                imported_roots.update(alias.name.split(".", 1)[0] for alias in node.names)
            elif isinstance(node, ast.ImportFrom) and node.module:
                imported_roots.add(node.module.split(".", 1)[0])
            elif isinstance(node, ast.Call):
                if isinstance(node.func, ast.Attribute) and node.func.attr in (
                    "system",
                    "popen",
                    "run",
                    "Popen",
                    "check_call",
                    "check_output",
                ):
                    forbidden_calls.append(node.func.attr)
        forbidden_imports = {
            "http",
            "requests",
            "socket",
            "subprocess",
            "urllib",
        }
        self.assertEqual(imported_roots & forbidden_imports, set())
        self.assertEqual(forbidden_calls, [])
        for provider_brand in ("claude", "openai", "anthropic", "gemini", "copilot"):
            self.assertNotIn(provider_brand, source.lower())


# ------------- DEC-REV-001: field separators must not reach across a newline

class GovernedFileRegexesStayOnTheirLine(unittest.TestCase):
    """`\\s` includes the newline, the repo's recurring separator defect.

    A bare `##` followed by a line opening with a task token counted as a
    heading, so "the Task appears exactly once in tasks.md" could be satisfied
    by prose or double-counted against a real heading. The same shape let the
    front-matter id match across a line break. These modules exist to refuse
    malformed governed files, so a parser that invents structure in them is the
    defect, not a nuisance.
    """

    def test_a_bare_hash_pair_does_not_borrow_the_next_line(self):
        self.assertEqual(
            pr_envelope.TASK_HEADER_RE.findall("##\nTASK-HLR-001 only-in-prose"),
            [], "a phantom heading was minted from the following line")

    def test_a_real_heading_is_still_matched(self):
        self.assertEqual(
            pr_envelope.TASK_HEADER_RE.findall("## TASK-HLR-001 — real"),
            ["TASK-HLR-001"])

    def test_extra_horizontal_space_is_still_a_heading(self):
        self.assertEqual(
            pr_envelope.TASK_HEADER_RE.findall("##\t  TASK-HLR-001 — real"),
            ["TASK-HLR-001"])

    def test_a_heading_at_end_of_input_is_matched(self):
        self.assertEqual(
            pr_envelope.TASK_HEADER_RE.findall("## TASK-HLR-001"),
            ["TASK-HLR-001"])

    def test_the_front_matter_id_does_not_reach_across_the_break(self):
        self.assertIsNone(
            pr_envelope.FRONTMATTER_ID_RE.search("id:\nCHG-2026-030-host-loop"),
            "the id was read from the line below the key")

    def test_the_front_matter_id_is_still_read_from_its_own_line(self):
        match = pr_envelope.FRONTMATTER_ID_RE.search(
            "---\nid: CHG-2026-030-host-loop-runtime\nstatus: verified\n---\n")
        self.assertIsNotNone(match)
        self.assertEqual(match.group(1), "CHG-2026-030-host-loop-runtime")

    def test_no_governed_regex_in_this_module_still_uses_a_newline_class(self):
        """Structural sweep, so the next one added is caught here.

        AST rather than a text grep: a grep finds the pattern inside this very
        docstring, which is how the sibling sweep in the navigation contract
        first reported itself.
        """
        source = Path(pr_envelope.__file__).read_text(encoding="utf-8")
        module = ast.parse(source)
        offenders = []
        for node in ast.walk(module):
            if isinstance(node, ast.Constant) and isinstance(node.value, str):
                if r"\s*" in node.value or r"\s+" in node.value:
                    offenders.append(node.value[:60])
        self.assertEqual(offenders, [], f"whitespace class spans lines: {offenders}")


# ------------------ DEC-HL-001 r2: the evidence path branch is a path branch

class EvidenceIsAPathOrADeclaration(unittest.TestCase):
    """The path branch accepted any prose that was not a `none:` line.

    "this is just a sentence" validated as a repository-relative path, and the
    one production renderer leaned on it: it declared "no evidence" with an
    em-dash, missing the strict none grammar and falling through to the path
    branch. That renderer now emits `none:`, so the branch can require
    something path-shaped -- while the em-dash bodies already merged must keep
    parsing, which is why the legacy spelling is recognised on read only.
    """

    def _validate(self, *items):
        pr_envelope._validate_evidence(tuple(items))

    def test_prose_is_no_longer_a_path(self):
        with self.assertRaises(pr_envelope.EnvelopeError):
            self._validate("this is just a sentence, not a path")

    def test_a_real_path_still_validates(self):
        self._validate("openspec/changes/chg-x/evidence/runs/T/run.md")

    def test_several_real_paths_still_validate(self):
        self._validate("a/b.md", "c/d.md")

    def test_the_current_none_declaration_validates(self):
        self._validate("none: host-loop dispatch carries no evidence file")

    def test_the_legacy_none_declaration_still_parses(self):
        """Persisted in merged pull request bodies; read-only compatibility."""
        self._validate("none — host-loop dispatch carries no evidence file")

    def test_the_legacy_form_still_needs_a_reason(self):
        with self.assertRaises(pr_envelope.EnvelopeError):
            self._validate("none — ")

    def test_the_legacy_form_cannot_be_one_of_several(self):
        with self.assertRaises(pr_envelope.EnvelopeError):
            self._validate("none — no evidence", "a/b.md")

    def test_the_renderer_emits_only_the_current_form(self):
        source = Path(
            Path(pr_envelope.__file__).parent / "backends.py").read_text()
        self.assertIn('"none: ', source)
        self.assertNotIn('"none — ', source)


if __name__ == "__main__":
    unittest.main(verbosity=2)
