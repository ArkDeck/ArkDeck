#!/usr/bin/env python3
"""Contract for tasks.md discovery (TASK-HLR-003).

The merged parser was validated against invented fixtures, never against the
real openspec/changes/*/tasks.md. This file's absolute rule is therefore: every
case is either taken from the real file's shapes or asserted against the real
file directly. A discovery test that only reads fixtures the same author
invented proves nothing about whether the loop can run.

Measured by running the merged regexes against the real file. These numbers
replace an earlier, wrong summary of this same measurement, which reported one
status value "for all eight tasks" and two independently fatal defects:

    eight tasks, SIX distinct status values — 'done（2026-07-23',
    'done（2026-07-24', 'done（2026-07-25', 'blocked（r7', 'blocked（前置：①',
    'ready（r2' — and grade='unknown' for all eight.

Exactly ONE of the three defects below was independently fatal, and it is the
one this reader must not fix.

  status/grade value  `(\\S+)` is greedy to whitespace and the real file writes
                      `Status:ready（r2 …` with no space before the paren, so
                      the captured value was `ready（r2`. This blocked NOTHING:
                      both live gates are prefix tests — worker.py's
                      `candidate.status.startswith("ready")` and done_task_ids'
                      `.startswith("done")` — and every truncated value still
                      satisfied the right one. A latent hazard (any exact
                      comparison would break, and the value a human reads is
                      wrong), not an outage. Fixed so the value means what it
                      says.
  Decision-Grade      absent from tasks.md entirely — 0 occurrences against 8
                      tasks — so every grade parsed as "unknown", which is not
                      dispatchable. THE fatal one: nothing was claimable. The
                      parser cannot fix it, because declaring a task's decision
                      grade is a human judgement, not a parse.
  Hardware required   absence produced hardware_required=False, and
                      `.lower().startswith("yes")` read `是`/`必需` as no. A
                      permissive default on the field that decides whether an
                      unattended loop may touch a task, contradicting the
                      function's own docstring. The one fail-OPEN of the three,
                      latent only because all eight values read `no。` today.
"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

HOST_LOOP_DIR = Path(__file__).resolve().parent
SCRIPTS_DIR = HOST_LOOP_DIR.parent
REPO_ROOT = SCRIPTS_DIR.parent
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

from host_loop.__main__ import (  # noqa: E402
    _without_code_fences,
    discover_candidates,
    done_task_ids,
)
from host_loop.worker import DISPATCHABLE_GRADES  # noqa: E402

CHANGE_ID = "CHG-2026-030-host-loop-runtime"
# The frozen live sample: chg-2026-030 is done, so its file's shapes are
# stable forever wherever the change lives (active today, archive after the
# mv). change_tasks_path resolves either location; the fallback keeps the
# skip-if-absent semantics for trees that carry neither (TASK-NAV-002).
from host_loop.test_support import change_tasks_path, live_sample_change  # noqa: E402

try:
    REAL_TASKS = change_tasks_path(REPO_ROOT, CHANGE_ID)
except AssertionError:
    REAL_TASKS = (REPO_ROOT / "openspec" / "changes" / CHANGE_ID.lower() / "tasks.md")


def write_tasks(tmp: Path, body: str) -> Path:
    target = tmp / "openspec" / "changes" / CHANGE_ID.lower()
    target.mkdir(parents=True, exist_ok=True)
    (target / "tasks.md").write_text(body, encoding="utf-8")
    return tmp


# The exact punctuation shapes the real file uses after a field value.
REAL_SHAPES = [
    "- Status:ready（r2 corrective readiness；仅在维护者 review 后生效）",
    "- Status:done（2026-07-25 D0 completion）",
    "- Status:blocked（前置：① 本 change approval）",
    "- Status: ready",
    "- Status:ready。",
    "- Status:ready，其余略",
    "- Status:ready；其余略",
    "- Status:ready(ascii paren)",
]


class ValuesAreNotTruncatedByPunctuation(unittest.TestCase):
    """`(\\S+)` captured `ready（r2` instead of `ready`.

    Not "the reason no task read as ready" — an earlier version of this line
    said that, and it was wrong: the live gates are prefix tests, which the
    truncated value satisfied. See the module docstring.
    """

    def _status_of(self, line):
        import tempfile

        with tempfile.TemporaryDirectory() as raw:
            root = write_tasks(Path(raw), f"""## TASK-DEMO-001 — demo

{line}
- Hardware required:no。
- Decision-Grade:D0。
- Allowed paths:`scripts/host_loop/**`
- Depends on:none
""")
            found = discover_candidates(root, CHANGE_ID)
        self.assertEqual(len(found), 1, "the task must be discovered at all")
        return found[0].status

    def test_every_real_punctuation_shape_yields_a_bare_status(self):
        import re

        for line in REAL_SHAPES:
            with self.subTest(line=line):
                # The expected value is the leading word of the field, computed
                # independently of the parser under test.
                expected = re.match(r"[a-z-]+",
                                    line.split(":", 1)[1].strip()).group(0)
                self.assertEqual(
                    self._status_of(line), expected,
                    f"{line!r} must not leak punctuation into the value")

    def test_the_parsed_value_is_the_bare_gate_word(self):
        """So that any comparison means what it says.

        Note what this does NOT claim: the live gates are prefix tests
        (`status.startswith("ready")`), which the truncated `ready（r2` already
        satisfied. An earlier version of this docstring asserted a
        `status == "ready"` gate that exists nowhere, and used it to call the
        truncation fatal. It was not fatal; it was wrong.
        """
        self.assertEqual(
            self._status_of("- Status:ready（r2 corrective readiness）"), "ready")

    def test_a_grade_carrying_trailing_prose_is_still_D0(self):
        import tempfile

        with tempfile.TemporaryDirectory() as raw:
            root = write_tasks(Path(raw), """## TASK-DEMO-001 — demo

- Status:ready
- Hardware required:no。
- Decision-Grade:D0（host-only，machine-decidable）
- Allowed paths:`scripts/host_loop/**`
- Depends on:none
""")
            found = discover_candidates(root, CHANGE_ID)
        self.assertEqual(found[0].decision_grade, "D0")
        self.assertIn(found[0].decision_grade, DISPATCHABLE_GRADES)


class AbsenceNeverWidensWhatIsClaimable(unittest.TestCase):
    """The docstring promised this; hardware_required did not honour it."""

    def _candidates(self, section):
        import tempfile

        with tempfile.TemporaryDirectory() as raw:
            root = write_tasks(Path(raw), f"## TASK-DEMO-001 — demo\n\n{section}")
            return discover_candidates(root, CHANGE_ID)

    FULL = """- Status:ready
- Hardware required:no。
- Decision-Grade:D0。
- Allowed paths:`scripts/host_loop/**`
- Depends on:none
"""

    def test_the_complete_shape_is_discovered(self):
        """Control: the omissions below must be caused by the omission."""
        found = self._candidates(self.FULL)
        self.assertEqual(len(found), 1)
        self.assertFalse(found[0].hardware_required)

    def test_a_missing_hardware_line_omits_the_task(self):
        section = "\n".join(l for l in self.FULL.splitlines()
                            if "Hardware" not in l) + "\n"
        self.assertEqual(
            self._candidates(section), [],
            "absence of a safety field must not default to the permissive value")

    def test_an_unrecognised_hardware_value_omits_the_task(self):
        """A value outside the closed vocabulary is undecidable, so it omits.

        `是` and `必需` are NOT here: they are recognised affirmatives, so they
        produce a candidate that the worker's own host-only gate then refuses.
        Recognising them is strictly better than omitting, and strictly better
        than the old `startswith("yes")` which read them as "no hardware".
        """
        for value in ("maybe", "TBD", "unknown", "pending", "n/a", "0"):
            with self.subTest(value=value):
                section = self.FULL.replace("Hardware required:no。",
                                            f"Hardware required:{value}")
                self.assertEqual(
                    self._candidates(section), [],
                    f"{value!r} is not a decidable no; it must omit the task")

    def test_the_affirmative_spellings_are_read_as_hardware_required(self):
        for value in ("yes", "Yes", "YES", "yes。", "yes（DAYU200）", "true",
                      "是", "必需", "需要", "required"):
            with self.subTest(value=value):
                section = self.FULL.replace("Hardware required:no。",
                                            f"Hardware required:{value}")
                found = self._candidates(section)
                self.assertEqual(len(found), 1, f"{value!r} must still parse")
                self.assertTrue(found[0].hardware_required,
                                f"{value!r} must mean hardware IS required")

    def test_the_negative_spellings_are_read_as_host_only(self):
        for value in ("no", "No", "no。", "no（host-only）", "false", "none"):
            with self.subTest(value=value):
                section = self.FULL.replace("Hardware required:no。",
                                            f"Hardware required:{value}")
                found = self._candidates(section)
                self.assertEqual(len(found), 1, f"{value!r} must still parse")
                self.assertFalse(found[0].hardware_required)

    def test_a_missing_grade_line_yields_an_undispatchable_grade(self):
        """The parser must not invent a grade. It stays fail-closed."""
        section = "\n".join(l for l in self.FULL.splitlines()
                            if "Decision-Grade" not in l) + "\n"
        found = self._candidates(section)
        self.assertEqual(len(found), 1)
        self.assertNotIn(found[0].decision_grade, DISPATCHABLE_GRADES)

    def test_a_missing_status_line_omits_the_task(self):
        section = "\n".join(l for l in self.FULL.splitlines()
                            if "Status" not in l) + "\n"
        self.assertEqual(self._candidates(section), [])

    def test_a_missing_allowed_paths_line_omits_the_task(self):
        section = "\n".join(l for l in self.FULL.splitlines()
                            if "Allowed paths" not in l) + "\n"
        self.assertEqual(self._candidates(section), [])

    def test_a_historical_status_line_cannot_supply_the_status(self):
        """The real file carries 18 `Historical Status:` lines and 8 `Status:`.

        Matching the wrong one would read a superseded state as current.
        """
        section = self.FULL.replace("- Status:ready",
                                    "- Historical Status:ready")
        self.assertEqual(self._candidates(section), [])


class AgainstTheRealFile(unittest.TestCase):
    """Asserted against the committed tasks.md, not against a fixture.

    This is the class that would have caught all three defects on the day the
    parser was merged.
    """

    @classmethod
    def setUpClass(cls):
        if not REAL_TASKS.is_file():
            raise unittest.SkipTest(f"{REAL_TASKS} absent in this tree")
        # discover_candidates is an active-changes API by design (archived
        # changes must never mint candidates), so the discovery half of this
        # class samples a live change dynamically instead of pinning one
        # that will someday archive (TASK-NAV-002).
        cls.sample_change = live_sample_change(REPO_ROOT)
        cls.sample_tasks = change_tasks_path(REPO_ROOT, cls.sample_change)
        cls.found = discover_candidates(REPO_ROOT, cls.sample_change)

    def test_the_real_file_yields_the_tasks_it_declares(self):
        headers = self.sample_tasks.read_text(encoding="utf-8").count("\n## TASK-")
        self.assertEqual(len(self.found), headers,
                         "every declared task must be discovered")

    def test_no_status_value_carries_punctuation_or_prose(self):
        for candidate in self.found:
            with self.subTest(task=candidate.task_id):
                self.assertRegex(candidate.status, r"^[a-z][a-z-]*$",
                                 f"{candidate.status!r} is not a bare status word")

    def test_the_statuses_are_the_vocabulary_the_change_uses(self):
        self.assertLessEqual({c.status for c in self.found},
                             {"ready", "done", "blocked", "in-progress"})

    def test_statuses_equal_an_independent_minimal_extraction(self):
        """Parser output must equal a second, simpler extraction of the file.

        The point-in-time form is retired: this test used to pin
        `TASK-HLR-003 == ready`, which the #552 done flip legitimately broke —
        the parser was right and the assertion was stale (recorded in the
        TASK-HLR-004 r1 readiness). Comparing against an independently
        extracted value keeps the original purpose — a truncated or
        prose-bearing value such as `ready（r2` must still fail loudly — while
        freezing no task's current state into the suite.
        """
        import re as _re

        text = _without_code_fences(self.sample_tasks.read_text(encoding="utf-8"))
        independent: dict[str, str] = {}
        for section in _re.split(r"(?m)^##\s+", text)[1:]:
            header = _re.match(
                r"^(TASK-[A-Z0-9]+(?:-[A-Z0-9]+)*-[0-9]{3}[A-Z]?)", section)
            status = _re.search(r"^-[ \t]*Status[:：][ \t]*([a-z][a-z-]*)",
                                section, _re.MULTILINE)
            if header and status:
                independent[header.group(1)] = status.group(1)
        self.assertGreaterEqual(len(independent), 1,
                                "the independent extraction must see the file")
        self.assertEqual({c.task_id: c.status for c in self.found}, independent)

    def test_hlr_003_is_done_and_no_longer_ready(self):
        """#552 flipped TASK-HLR-003 to done; done is terminal, so both facts
        are stable forever. The candidate half used to read the task through
        discovery, which stops resolving the change once it archives, so the
        status now comes from an independent minimal extraction of the frozen
        file itself (TASK-NAV-002)."""
        import re as _re

        self.assertIn("TASK-HLR-003", done_task_ids(REPO_ROOT))
        text = _without_code_fences(REAL_TASKS.read_text(encoding="utf-8"))
        statuses = {}
        for chunk in _re.split(r"(?m)^##\s+", text)[1:]:
            header = _re.match(
                r"^(TASK-[A-Z0-9]+(?:-[A-Z0-9]+)*-[0-9]{3}[A-Z]?)", chunk)
            status = _re.search(
                r"^-[ \t]*Status[:\uff1a][ \t]*([a-z][a-z-]*)",
                chunk, _re.MULTILINE)
            if header and status:
                statuses[header.group(1)] = status.group(1)
        self.assertEqual(statuses.get("TASK-HLR-003"), "done")

    def test_every_task_declares_a_decidable_hardware_value(self):
        """No task may be omitted for an undecidable safety field."""
        declared = self.sample_tasks.read_text(encoding="utf-8").count(
            "\n- Hardware required:")
        self.assertEqual(len(self.found), declared)

    @unittest.expectedFailure
    def test_whether_any_task_is_claimable_at_all(self):
        """The loop's reason for existing: at least one D0 candidate.

        Recorded rather than hidden. The original form pinned chg-2026-030,
        whose grade gap the #577/#591 maintainer seedings have since
        settled; the sampled live change now carries the fact forward: its
        tasks are all human-gated (D1/D2) or ungraded, so the loop can
        claim nothing from it. Declaring a grade stays a human judgement,
        and defaulting it here would be this reader granting itself
        authority it is written not to have. So the assertion states the
        truth and keeps the expected-failure marker — the moment a maintainer adds the
        field this reports "unexpected success", which forces the marker off
        instead of letting a stale skip hide the fix.
        """
        grades = {c.task_id: c.decision_grade for c in self.found}
        dispatchable = [t for t, g in grades.items() if g in DISPATCHABLE_GRADES]
        self.assertTrue(
            dispatchable,
            "no task carries a dispatchable Decision-Grade, so the loop can "
            f"claim nothing. Parsed grades: {grades}. tasks.md needs a "
            "maintainer-authored `- Decision-Grade:` line per task.")


class FieldsDoNotReachAcrossLines(unittest.TestCase):
    """`_VALUE` was preceded by `\s*`, and `\s` matches a newline.

    A field written with an empty value therefore did not read as absent: the
    parser stepped over the line break and captured the first token of the
    following prose. For `Decision-Grade` that manufactures a dispatchable D0
    out of ordinary explanatory text — the one value this reader is explicitly
    not allowed to invent.
    """

    def _candidates(self, section):
        import tempfile

        with tempfile.TemporaryDirectory() as raw:
            root = write_tasks(Path(raw), f"## TASK-DEMO-001 — demo\n\n{section}")
            return discover_candidates(root, CHANGE_ID)

    BODY = """- Status:ready
- Hardware required:no。
- Decision-Grade:{grade}
- Allowed paths:`scripts/host_loop/**`
- Depends on:none
"""

    def test_a_blank_grade_does_not_borrow_the_next_line(self):
        found = self._candidates(self.BODY.format(
            grade="\n  D0 is prose explaining the grade, not the grade"))
        self.assertEqual(len(found), 1)
        self.assertNotIn(found[0].decision_grade, DISPATCHABLE_GRADES,
                         "an empty field must read as absent, not as the prose "
                         "that follows it")

    def test_a_blank_status_omits_the_task(self):
        section = self.BODY.format(grade="D0").replace(
            "- Status:ready", "- Status:\n  ready when the readiness merges")
        self.assertEqual(self._candidates(section), [])

    def test_a_blank_hardware_value_omits_the_task(self):
        section = self.BODY.format(grade="D0").replace(
            "- Hardware required:no。", "- Hardware required:\n  no device needed")
        self.assertEqual(self._candidates(section), [])

    def test_a_value_on_the_same_line_after_tabs_still_parses(self):
        section = self.BODY.format(grade="D0").replace(
            "- Status:ready", "- Status:\t ready")
        found = self._candidates(section)
        self.assertEqual(len(found), 1)
        self.assertEqual(found[0].status, "ready")


class DependenciesAreDeclaredNotAssumed(unittest.TestCase):
    """The one field left whose absence silently meant "nothing blocks me".

    status, hardware and allowed-paths all omit the task when unparsable, but a
    missing `- Depends on:` collapsed to (), making the worker's dependency gate
    vacuous — the exact fail-open the docstring says cannot happen.
    """

    def _candidates(self, section):
        import tempfile

        with tempfile.TemporaryDirectory() as raw:
            root = write_tasks(Path(raw), f"## TASK-DEMO-001 — demo\n\n{section}")
            return discover_candidates(root, CHANGE_ID)

    FULL = """- Status:ready
- Hardware required:no。
- Decision-Grade:D0。
- Allowed paths:`scripts/host_loop/**`
- Depends on:none
"""

    def test_the_complete_shape_is_discovered(self):
        self.assertEqual(len(self._candidates(self.FULL)), 1)

    def test_a_missing_depends_on_line_omits_the_task(self):
        section = "\n".join(l for l in self.FULL.splitlines()
                             if "Depends on" not in l) + "\n"
        self.assertEqual(
            self._candidates(section), [],
            "an undeclared dependency set must not read as no dependencies")

    def test_an_explicit_none_is_no_dependencies(self):
        found = self._candidates(self.FULL)
        self.assertEqual(found[0].dependencies, ())

    def test_declared_dependencies_are_parsed(self):
        section = self.FULL.replace(
            "- Depends on:none", "- Depends on:TASK-HLR-002 done、TASK-HLR-001")
        found = self._candidates(section)
        self.assertEqual(found[0].dependencies,
                         ("TASK-HLR-001", "TASK-HLR-002"))

    def test_the_real_file_declares_dependencies_for_every_task(self):
        if not REAL_TASKS.is_file():
            self.skipTest("real tasks.md absent")
        sample = live_sample_change(REPO_ROOT)
        declared = change_tasks_path(REPO_ROOT, sample).read_text(
            encoding="utf-8").count("\n- Depends on:")
        self.assertEqual(len(discover_candidates(REPO_ROOT, sample)), declared)


class CodeFencesCannotMintTasks(unittest.TestCase):
    """Section splitting was fence-unaware.

    A `## TASK-…` line quoted inside a fenced block became a real section. In
    discover_candidates that invents a candidate; in done_task_ids it injects a
    fabricated id into the set of tasks considered DONE, which is what the
    dependency gate consults.
    """

    FENCED = """## TASK-REAL-001 — the actual task

- Status:ready
- Hardware required:no。
- Decision-Grade:D0。
- Allowed paths:`scripts/host_loop/**`
- Depends on:none

Example of the shape a task takes:

```markdown
## TASK-FAKE-002 — illustrative only

- Status:done
- Hardware required:no。
- Decision-Grade:D0。
- Allowed paths:`x/**`
- Depends on:none
```
"""

    def test_a_fenced_header_does_not_become_a_candidate(self):
        import tempfile

        with tempfile.TemporaryDirectory() as raw:
            root = write_tasks(Path(raw), self.FENCED)
            ids = {c.task_id for c in discover_candidates(root, CHANGE_ID)}
        self.assertEqual(ids, {"TASK-REAL-001"},
                         "a task header inside a code fence is documentation")

    def test_a_fenced_header_does_not_become_a_done_task(self):
        import tempfile

        from host_loop.__main__ import done_task_ids

        with tempfile.TemporaryDirectory() as raw:
            root = write_tasks(Path(raw), self.FENCED)
            done = done_task_ids(root)
        self.assertNotIn("TASK-FAKE-002", done,
                         "a fabricated done id would satisfy a real dependency")

    def test_the_real_file_is_unaffected(self):
        """Fence-blanking neither mints nor loses a task on a real file:
        discovery output equals the fence-blanked header set exactly."""
        import re as _re

        if not REAL_TASKS.is_file():
            self.skipTest("real tasks.md absent")
        sample = live_sample_change(REPO_ROOT)
        ids = {c.task_id for c in discover_candidates(REPO_ROOT, sample)}
        text = _without_code_fences(
            change_tasks_path(REPO_ROOT, sample).read_text(encoding="utf-8"))
        declared = set(_re.findall(
            r"(?m)^##\s+(TASK-[A-Z0-9]+(?:-[A-Z0-9]+)*-[0-9]{3}[A-Z]?)", text))
        self.assertEqual(ids, declared)
        self.assertGreater(len(ids), 0)


class TruthIsNeverBuiltFromAnIncompleteObservation(unittest.TestCase):
    """A failed lease ls-remote used to leave the lease map simply empty.

    Combined with reconciliation, that is a fail-open: reconcile clears a
    lease_ref that Truth does not list, so one flaky read said "the lease is
    gone" and dropped the fence from the cache. The PR half of build_truth
    already re-raised for exactly this reason; the lease half did not.
    """

    @staticmethod
    def _api():
        def send(method, path, body):
            return 200, []

        from host_loop.transport import ApiPort

        return ApiPort(owner="ArkDeck", repo="ArkDeck", _send=send)

    def _build(self, code, out):
        from host_loop.__main__ import build_truth

        def runner(argv):
            return code, out, "" if code == 0 else "fatal: could not read from remote"

        return build_truth(self._api(), runner, REPO_ROOT, CHANGE_ID, "f" * 40, [])

    def test_a_failed_ls_remote_refuses_rather_than_reporting_no_leases(self):
        from host_loop.backends import BackendError

        with self.assertRaisesRegex(BackendError, "lease"):
            self._build(128, "")

    def test_a_successful_empty_read_is_a_legitimate_empty_lease_map(self):
        """The refusal must be about the failure, not about emptiness."""
        self.assertEqual(self._build(0, "").lease_oid_by_ref, {})

    def test_a_successful_read_is_parsed(self):
        ref = "refs/heads/agent/host-loop/leases/TASK-DEMO-001"
        truth = self._build(0, f"{'a' * 40}\t{ref}\n")
        self.assertEqual(truth.lease_oid_by_ref, {ref: "a" * 40})


if __name__ == "__main__":
    unittest.main(verbosity=2)
