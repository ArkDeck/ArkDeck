#!/usr/bin/env python3
"""Contract for repo-wide navigation and a truthful idle verdict (TASK-NAV-001).

Three measured defects on the audit base, each pinned by a case below.

  scope       `--change` defaulted to the literal `CHG-2026-030-host-loop-runtime`
              and the scheduled unit's plist passes no `--change`, so once every
              task in that change reached done the loop scanned a finished change
              and reported idle — 31 consecutive rounds, none of which could ever
              have claimed anything, while ready work sat in other changes.
  idle truth  `select()`'s never-claim branch asked `is_never_claim(task_id)` and
              nothing else, so a never-claim task that had since gone `done` still
              produced `only never-claim tasks are ready (['TASK-HLR-003'])`. The
              sentence named a task that was neither ready nor the reason nothing
              was claimed, and it was the operator's only diagnostic.
  log         the round's single output line carried neither a timestamp nor any
              statement of how much of the repository the verdict covered.

Two rules this file keeps, both learned here the hard way:

  * The live-repository cases assert *relations* that stay true as statuses
    change — the reported change set equals the directory set, per-change
    discovery agrees with repo-wide discovery — never "task X is ready today".
    A time-point assertion is what #552 broke and #555 had to make stale-proof.
  * Widening the input must not widen what is claimable. Every aggregation case
    therefore also asserts the gate that used to be evaluated once per round is
    still evaluated, per change.
"""

from __future__ import annotations

import ast
import os
import re
import subprocess
import sys
import tempfile
import unittest
import unittest.mock
from pathlib import Path

HOST_LOOP_DIR = Path(__file__).resolve().parent
SCRIPTS_DIR = HOST_LOOP_DIR.parent
REPO_ROOT = SCRIPTS_DIR.parent
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

from host_loop import __main__ as main_mod  # noqa: E402
from host_loop import worker as worker_mod  # noqa: E402
from host_loop.__main__ import (  # noqa: E402
    SCOPE_ALL,
    _candidate_body_renderer,
    _round_line,
    _utc_stamp,
    active_change_ids,
    canonical_change_id,
    discover_all,
    discover_candidates,
    parse_args,
)
from host_loop.backends import BackendError  # noqa: E402
from host_loop.cursor import CursorError  # noqa: E402
from host_loop.identity import ReconcileRequired  # noqa: E402
from host_loop.lease import LeaseError  # noqa: E402
from host_loop.pr_envelope import (  # noqa: E402
    CHANGE_RE,
    _active_change_directories,
)
from host_loop.transport import TransportError  # noqa: E402
from host_loop.worker import (  # noqa: E402
    NEVER_CLAIM_ROOTS,
    RoundResult,
    SelectionOutcome,
    TaskCandidate,
    Worker,
    WorkerState,
    classify_no_claim,
    is_never_claim,
    is_ready,
)

MAIN = "a" * 40


# ------------------------------------------------------------------ fixtures

TASK_TEMPLATE = """## {task_id} — fixture

- Status:{status}
- Depends on:{depends}
- Allowed paths:`scripts/host_loop/**`
- Hardware required:no。
{grade_line}
### Deliverables

- nothing
"""


def task_block(task_id: str, *, status: str = "ready（r1）", grade: str | None = "D0",
               depends: str = "none") -> str:
    grade_line = f"- Decision-Grade:{grade}。\n" if grade else ""
    return TASK_TEMPLATE.format(task_id=task_id, status=status, depends=depends,
                                grade_line=grade_line)


def write_change(root: Path, change_id: str, *, approved: bool = True,
                 tasks: str = "", archived: bool = False) -> Path:
    parent = root / "openspec" / "changes"
    directory = parent / ("archive" if archived else "") / change_id
    directory.mkdir(parents=True, exist_ok=True)
    status = "approved" if approved else "proposed"
    (directory / "proposal.md").write_text(
        f"---\nid: {change_id.upper()}\nrevision: 1\nstatus: {status}\n---\n\n# f\n",
        encoding="utf-8")
    (directory / "tasks.md").write_text(f"# Tasks — {change_id}\n\n{tasks}",
                                        encoding="utf-8")
    return directory


class _NoLeases:
    """Enough of a LeaseManager to construct a Worker, and no more.

    `select()` reads neither the API port nor the lease manager; a real manager
    here would only add a way for these cases to fail for a reason that has
    nothing to do with navigation.
    """

    owner_run = "navigation-contract"


def build_worker(repo_root: Path, *, done=frozenset()) -> Worker:
    """A worker whose only live wiring is the two readers select() consults."""
    from host_loop.__main__ import _change_is_approved

    return Worker(
        None, _NoLeases(),
        change_approved=lambda change_id: _change_is_approved(repo_root, change_id),
        done_tasks=lambda: done,
        read_envelope=lambda body: None,
        read_lease_record=lambda ref: None,
        prepare_branch=lambda candidate, base: "b" * 40,
        render_body=lambda candidate, base, head: "",
        now=lambda: 0,
    )


def candidate(**over) -> TaskCandidate:
    base = dict(task_id="TASK-DEMO-001", status="ready", decision_grade="D0",
                hardware_required=False, dependencies=(),
                allowed_paths=("scripts/host_loop/**",), base_pin=None)
    base.update(over)
    return TaskCandidate(**base)


# ------------------------------------------------------- NAV-DISC-001: scope

class DefaultScopeIsTheWholeRepository(unittest.TestCase):
    """The round no longer navigates by a literal that can go stale."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self.addCleanup(self._tmp.cleanup)

    def test_every_active_change_is_enumerated_in_lexicographic_order(self):
        for change_id in ("chg-b", "chg-a", "chg-c"):
            write_change(self.root, change_id, tasks=task_block("TASK-X-001"))
        self.assertEqual(active_change_ids(self.root), ["chg-a", "chg-b", "chg-c"])

    def test_an_archived_change_is_not_an_active_change(self):
        write_change(self.root, "chg-live", tasks=task_block("TASK-X-001"))
        write_change(self.root, "2026-01-01-chg-gone", archived=True,
                     tasks=task_block("TASK-Y-001"))
        self.assertEqual(active_change_ids(self.root), ["chg-live"])

    def test_a_directory_without_tasks_md_is_not_a_change(self):
        write_change(self.root, "chg-real", tasks=task_block("TASK-X-001"))
        (self.root / "openspec" / "changes" / "chg-empty").mkdir()
        self.assertEqual(active_change_ids(self.root), ["chg-real"])

    def test_every_candidate_carries_the_change_that_declared_it(self):
        write_change(self.root, "chg-a", tasks=task_block("TASK-A-001"))
        write_change(self.root, "chg-b", tasks=task_block("TASK-B-001"))
        found = discover_all(self.root, active_change_ids(self.root))
        self.assertEqual({c.task_id: c.change_id for c in found},
                         {"TASK-A-001": "chg-a", "TASK-B-001": "chg-b"})

    def test_the_scope_label_is_never_mistaken_for_a_change_id(self):
        """It labels the round; the approval gate must read the candidate's id."""
        self.assertNotIn(SCOPE_ALL, active_change_ids(REPO_ROOT))
        self.assertFalse((REPO_ROOT / "openspec" / "changes" / SCOPE_ALL).exists())


class OmittingTheFlagMeansEveryChange(unittest.TestCase):
    """The default itself, not just the machinery the default reaches.

    Written after a mutation run: restoring the old
    `default="CHG-2026-030-host-loop-runtime"` left the whole suite green,
    because every other case here calls `active_change_ids`/`discover_all`
    directly. The defect being fixed lives in the DEFAULT — the deployed plist
    passes no `--change` — so the default is what has to be pinned.
    """

    def test_the_change_flag_has_no_default_change_id(self):
        args = parse_args(["--explain", "--repo-dir", str(REPO_ROOT)])
        self.assertIsNone(args.change,
                          "a literal default silently re-narrows the round")

    def test_an_explicit_flag_is_still_honoured(self):
        args = parse_args(["--once", "--repo-dir", str(REPO_ROOT),
                           "--change", "chg-x"])
        self.assertEqual(args.change, "chg-x")

    def _explain(self, *extra):
        return subprocess.run(
            [sys.executable, "-m", "host_loop", "--explain",
             "--repo-dir", str(REPO_ROOT), *extra],
            capture_output=True, text=True, timeout=120, cwd=str(REPO_ROOT),
            env={**os.environ, "PYTHONPATH": str(SCRIPTS_DIR),
                 "ARKDECK_HOST_LOOP_TOKEN": "", "ARKDECK_HOST_LOOP_TOKEN_FILE": ""},
        )

    def test_the_default_dry_run_reports_every_active_change(self):
        expected = active_change_ids(REPO_ROOT)
        done = self._explain()
        self.assertIn(done.returncode, (0, 10), done.stderr)
        reported = re.findall(r"(?m)^change=(\S+) ", done.stdout)
        self.assertEqual(reported, expected)
        self.assertIn(f"scanned changes={len(expected)}", done.stdout)

    def test_the_default_dry_run_covers_more_than_the_old_default_change(self):
        """Stated as a relation (reported == every active change) so that a
        change archiving — including the old default itself — cannot stale
        it (TASK-NAV-002 follow-up)."""
        done = self._explain()
        reported = set(re.findall(r"(?m)^change=(\S+) ", done.stdout))
        self.assertEqual(reported, set(active_change_ids(REPO_ROOT)))
        self.assertGreater(len(reported), 1,
                           "the old default was one change; this must be all of them")

    def test_an_explicit_change_still_reports_only_that_change(self):
        from host_loop.test_support import live_sample_change

        sample = live_sample_change(REPO_ROOT).lower()
        done = self._explain("--change", sample)
        reported = re.findall(r"(?m)^change=(\S+) ", done.stdout)
        self.assertEqual(reported, [sample])
        self.assertNotIn("scanned changes=", done.stdout)


class TheLiveRepositoryIsScannedWhole(unittest.TestCase):
    """Live assertions, stated as relations so a status flip cannot stale them.

    #552 flipped a task to done and broke a test that had pinned the state of
    that one task; #555 had to make the replacement stale-proof. These cases
    therefore compare two views of the repository against each other rather than
    against a remembered value.
    """

    def test_the_scanned_change_set_equals_the_directory_set(self):
        on_disk = sorted(
            path.parent.name
            for path in (REPO_ROOT / "openspec" / "changes").glob("chg-*/tasks.md"))
        self.assertEqual(active_change_ids(REPO_ROOT), on_disk)
        self.assertGreater(len(on_disk), 1,
                           "a one-change repository would make this vacuous")

    def test_repo_wide_discovery_is_exactly_the_union_of_the_per_change_reads(self):
        change_ids = active_change_ids(REPO_ROOT)
        union = [c.task_id
                 for change_id in change_ids
                 for c in discover_candidates(REPO_ROOT, change_id)]
        self.assertEqual([c.task_id for c in discover_all(REPO_ROOT, change_ids)],
                         union)
        self.assertGreater(len(union), 1)

    def test_the_change_that_used_to_be_the_only_one_scanned_is_still_scanned(self):
        """Widening the default must not have replaced one blind spot with
        another. Both worlds are contract bites: while the old default change
        is active it must be scanned; once archived it must not be — archived
        changes are not active (TASK-NAV-002 follow-up)."""
        old_default = "chg-2026-030-host-loop-runtime"
        active_dir = REPO_ROOT / "openspec" / "changes" / old_default
        if active_dir.is_dir():
            self.assertIn(old_default, active_change_ids(REPO_ROOT))
        else:
            self.assertNotIn(old_default, active_change_ids(REPO_ROOT))

    def test_a_gated_task_outside_the_old_default_change_is_now_visible(self):
        """The measured symptom: ready work in another change was unreachable.

        Asserted as "some candidate exists outside the old default change",
        which stays true however individual statuses move.
        """
        outside = [c for c in discover_all(REPO_ROOT, active_change_ids(REPO_ROOT))
                   if c.change_id != "chg-2026-030-host-loop-runtime"]
        self.assertTrue(outside)


# --------------------------------------------- NAV-DISC-001: aggregation gates

class AggregationDoesNotWidenWhatIsClaimable(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self.addCleanup(self._tmp.cleanup)

    def _select(self, done=frozenset()):
        change_ids = active_change_ids(self.root)
        candidates = discover_all(self.root, change_ids)
        return build_worker(self.root, done=done).select(candidates, SCOPE_ALL, MAIN)

    def test_at_most_one_task_is_claimed_however_many_are_claimable(self):
        write_change(self.root, "chg-a", tasks=task_block("TASK-A-001"))
        write_change(self.root, "chg-b", tasks=task_block("TASK-B-001"))
        picked, outcome, _detail = self._select()
        self.assertEqual(outcome, SelectionOutcome.CLAIMABLE)
        self.assertIsNotNone(picked)
        # A single return value cannot be two tasks; the assertion that matters
        # is that the OTHER claimable task was left alone.
        self.assertIn(picked.task_id, {"TASK-A-001", "TASK-B-001"})

    def test_the_first_change_in_order_wins_so_a_round_is_reproducible(self):
        write_change(self.root, "chg-b", tasks=task_block("TASK-B-001"))
        write_change(self.root, "chg-a", tasks=task_block("TASK-A-001"))
        picked, _outcome, _detail = self._select()
        self.assertEqual(picked.task_id, "TASK-A-001")

    def test_an_unapproved_change_contributes_nothing(self):
        write_change(self.root, "chg-a", approved=False,
                     tasks=task_block("TASK-A-001"))
        picked, outcome, _detail = self._select()
        self.assertIsNone(picked)
        self.assertEqual(outcome, SelectionOutcome.CHANGE_NOT_APPROVED)

    def test_one_unapproved_change_does_not_stop_the_approved_ones(self):
        """The gate is per change; a single verdict for the round would either
        dispatch out of an unapproved change or let one block every other."""
        write_change(self.root, "chg-a", approved=False,
                     tasks=task_block("TASK-A-001"))
        write_change(self.root, "chg-b", tasks=task_block("TASK-B-001"))
        picked, outcome, _detail = self._select()
        self.assertEqual(outcome, SelectionOutcome.CLAIMABLE)
        self.assertEqual(picked.task_id, "TASK-B-001")

    def test_a_claimable_task_inside_an_unapproved_change_is_still_refused(self):
        write_change(self.root, "chg-a", approved=False,
                     tasks=task_block("TASK-A-001"))
        write_change(self.root, "chg-b", tasks=task_block("TASK-B-001",
                                                          status="blocked"))
        picked, _outcome, _detail = self._select()
        self.assertIsNone(picked)

    def test_every_pre_existing_gate_still_applies_across_changes(self):
        write_change(self.root, "chg-a", tasks=(
            task_block("TASK-A-001", status="blocked")
            + task_block("TASK-A-002", grade=None)
            + task_block("TASK-A-003", grade="D1")
            + task_block("TASK-A-004", depends="`TASK-MISSING-001`")))
        write_change(self.root, "chg-b", tasks=task_block("TASK-HLR-003"))
        picked, _outcome, _detail = self._select()
        self.assertIsNone(picked, "no gate may be skipped just because the "
                                  "candidate came from another change")

    def test_a_single_change_round_keeps_its_own_scope(self):
        write_change(self.root, "chg-a", tasks=task_block("TASK-A-001"))
        write_change(self.root, "chg-b", tasks=task_block("TASK-B-001"))
        only_b = discover_candidates(self.root, "chg-b")
        picked, _outcome, _detail = build_worker(self.root).select(
            only_b, "chg-b", MAIN)
        self.assertEqual(picked.task_id, "TASK-B-001")

    def test_a_candidate_without_a_change_id_falls_back_to_the_round_scope(self):
        """Every pre-existing caller passes the change as the scope argument."""
        write_change(self.root, "chg-a", tasks=task_block("TASK-A-001"))
        picked, _outcome, _detail = build_worker(self.root).select(
            [candidate()], "chg-a", MAIN)
        self.assertIsNotNone(picked)
        picked, outcome, _detail = build_worker(self.root).select(
            [candidate()], "chg-does-not-exist", MAIN)
        self.assertIsNone(picked)
        self.assertEqual(outcome, SelectionOutcome.CHANGE_NOT_APPROVED)


# ------------------------------------------------- NAV-TRUTH-001: idle verdict

class TheIdleVerdictNamesOnlyReadyTasks(unittest.TestCase):
    """The regression the readiness measured on the audit base.

    Mutation gate: delete `and is_ready(c.status)` from `classify_no_claim` and
    `test_a_done_never_claim_task_is_not_reported_as_ready` goes red.
    """

    def test_a_done_never_claim_task_is_not_reported_as_ready(self):
        done = candidate(task_id="TASK-HLR-003", status="done（2026-07-25）")
        outcome, detail = classify_no_claim([done], done=frozenset(), main_oid=MAIN)
        self.assertEqual(outcome, SelectionOutcome.NOTHING_READY)
        self.assertNotIn("TASK-HLR-003", detail)
        self.assertNotIn("are ready", detail)

    def test_a_ready_never_claim_task_is_still_reported(self):
        """Positive control: the branch must narrow, not disappear."""
        ready = candidate(task_id="TASK-HLR-003", status="ready")
        outcome, detail = classify_no_claim([ready], done=frozenset(), main_oid=MAIN)
        self.assertEqual(outcome, SelectionOutcome.ONLY_NEVER_CLAIM_READY)
        self.assertIn("TASK-HLR-003", detail)

    def test_the_same_narrowing_holds_through_select(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write_change(root, "chg-a",
                         tasks=task_block("TASK-HLR-003", status="done（2026-07-25）"))
            candidates = discover_all(root, active_change_ids(root))
            _picked, outcome, detail = build_worker(root).select(
                candidates, SCOPE_ALL, MAIN)
            self.assertEqual(outcome, SelectionOutcome.NOTHING_READY)
            self.assertNotIn("TASK-HLR-003", detail)

    def test_a_gated_task_still_outranks_the_never_claim_verdict(self):
        gated = candidate(task_id="TASK-DEMO-001", decision_grade="D1")
        never = candidate(task_id="TASK-HLR-003", status="ready")
        outcome, _detail = classify_no_claim([gated, never], done=frozenset(),
                                             main_oid=MAIN)
        self.assertEqual(outcome, SelectionOutcome.ONLY_GATED_READY)

    def test_an_empty_candidate_set_is_nothing_ready_not_a_never_claim_story(self):
        outcome, detail = classify_no_claim([], done=frozenset(), main_oid=MAIN)
        self.assertEqual(outcome, SelectionOutcome.NOTHING_READY)
        self.assertEqual(detail, "no ready host-only task")

    def test_readiness_is_one_predicate_not_two(self):
        """`rejection_reasons` and the idle classifier must not disagree."""
        for status, expected in (("ready", True), ("ready（r1）", True),
                                 ("done（2026-07-25）", False), ("blocked", False),
                                 ("", False)):
            with self.subTest(status=status):
                self.assertEqual(is_ready(status), expected)
                reasons = worker_mod.rejection_reasons(
                    candidate(status=status), done=frozenset(), main_oid=MAIN)
                self.assertEqual(
                    expected, not any("is not ready" in r for r in reasons))


# ------------------------------------------- NAV-TRUTH-001: never-claim roots

class NeverClaimRootsArePinnedByContent(unittest.TestCase):
    """Pinned by content, not by length: a set of the right size can be wrong."""

    def test_the_exact_root_set(self):
        self.assertEqual(
            NEVER_CLAIM_ROOTS,
            frozenset({
                "TASK-HLR-003", "TASK-NAV-001", "TASK-NAV-002",
                "TASK-DEC-001", "TASK-DEC-002", "TASK-DEC-003", "TASK-DEC-004",
                "TASK-DEC-005", "TASK-DEC-006", "TASK-DEC-007", "TASK-DEC-008",
                "TASK-CM7-001",
            }))

    def test_each_root_and_its_suffixed_siblings_are_excluded(self):
        for root in sorted(NEVER_CLAIM_ROOTS):
            for variant in (root, root + "A", root.lower(), f" {root} "):
                with self.subTest(variant=variant):
                    self.assertTrue(is_never_claim(variant))

    def test_every_task_of_this_change_is_excluded(self):
        """CHG-2026-040 declares all eight DEC tasks session-implemented.

        Before this test existed the declaration lived only in tasks.md prose
        while the machine gate was this frozenset, so a Decision-Grade line was
        the only thing standing between the loop and claiming work that edits
        the gate itself. Enumerated rather than derived from NEVER_CLAIM_ROOTS:
        deriving it would pass even if every DEC root were dropped.
        """
        for number in range(1, 9):
            task = f"TASK-DEC-{number:03d}"
            with self.subTest(task=task):
                self.assertTrue(is_never_claim(task))

    def test_cm7_root_and_suffix_are_excluded(self):
        """The task that changes discovery cannot be claimed by discovery."""
        for task in ("TASK-CM7-001", "TASK-CM7-001A", "TASK-CM7-001R"):
            with self.subTest(task=task):
                self.assertTrue(is_never_claim(task))

    def test_neighbours_are_not_excluded(self):
        for other in ("TASK-NAV-003", "TASK-NAV-0011", "TASK-HLR-004",
                      "TASK-CM7-002", "TASK-CM7-0011", "TASK-DEMO-001"):
            with self.subTest(other=other):
                self.assertFalse(is_never_claim(other))

    def test_the_loop_cannot_claim_the_task_that_rewrites_its_own_gate(self):
        """NAV-001 edits worker.py; a self-claim would let it widen this set."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write_change(root, "chg-nav", tasks=(task_block("TASK-NAV-001")
                                                 + task_block("TASK-NAV-002")))
            candidates = discover_all(root, active_change_ids(root))
            picked, _outcome, _detail = build_worker(root).select(
                candidates, SCOPE_ALL, MAIN)
            self.assertIsNone(picked)

    def test_the_repository_declares_every_root(self):
        """A root pinned against a task that does not exist protects nothing.

        Searched across active AND archived changes: a root stays meaningful
        after its change is filed away, and pinning only the active tree would
        make this case fail the day chg-2026-039 is archived — the time-point
        assertion #552 broke and #555 had to replace.
        """
        declared = set()
        for tasks_file in (REPO_ROOT / "openspec" / "changes").rglob("tasks.md"):
            declared.update(re.findall(r"(?m)^##\s+(TASK-[A-Z0-9-]+)",
                                       tasks_file.read_text(encoding="utf-8")))
        for root in NEVER_CLAIM_ROOTS:
            with self.subTest(root=root):
                self.assertIn(root, declared)


# --------------------------------------------------- NAV-TRUTH-001: log format

class TheEnvelopeNamesTheTasksOwnChange(unittest.TestCase):
    """A directory name is not a change id, and the envelope wants the id.

    Found by mutation: stamping the envelope with the round's scope label left
    the suite green. It would also have failed at claim time, because the
    validator resolves `Change` against each active proposal's front-matter
    `id:` — and `chg-2026-026-macos-rockchip-flash-ui` declares `CHG-2026-026`.
    The single-change round never met the difference: the one change it was
    pinned to is one where the directory and the id happen to agree.
    """

    def test_the_two_identifiers_really_do_differ_in_this_repository(self):
        """If they never differed, everything below would be vacuous."""
        differing = [d for d in active_change_ids(REPO_ROOT)
                     if canonical_change_id(REPO_ROOT, d).lower() != d]
        self.assertTrue(differing,
                        "expected at least one change whose id is not its directory")

    def test_every_active_change_yields_an_id_the_envelope_accepts(self):
        for change_dir in active_change_ids(REPO_ROOT):
            with self.subTest(change=change_dir):
                change_id = canonical_change_id(REPO_ROOT, change_dir)
                self.assertTrue(CHANGE_RE.fullmatch(change_id), change_id)
                self.assertEqual(
                    _active_change_directories(REPO_ROOT, change_id),
                    (REPO_ROOT / "openspec" / "changes" / change_dir,))

    def test_the_renderer_uses_the_candidates_change_not_the_round_scope(self):
        rendered: dict[str, str] = {}

        def fake_body_renderer(repo_root, *, change_id, producer, run_id):
            def render(candidate, base_oid, head_oid):
                rendered["change"] = change_id
                return "body"
            return render

        with unittest.mock.patch.object(main_mod, "body_renderer",
                                        fake_body_renderer):
            change_dir = next(d for d in active_change_ids(REPO_ROOT)
                              if canonical_change_id(REPO_ROOT, d).lower() != d)
            render = _candidate_body_renderer(
                str(REPO_ROOT), fallback_change=SCOPE_ALL, producer="p",
                run_id="r")
            render(candidate(change_id=change_dir), "a" * 40, "b" * 40)
        self.assertEqual(rendered["change"],
                         canonical_change_id(REPO_ROOT, change_dir))
        self.assertNotEqual(rendered["change"], SCOPE_ALL)
        self.assertNotEqual(rendered["change"], change_dir)

    def test_a_candidate_without_a_change_falls_back_to_the_round_scope(self):
        rendered: dict[str, str] = {}

        def fake_body_renderer(repo_root, *, change_id, producer, run_id):
            def render(candidate, base_oid, head_oid):
                rendered["change"] = change_id
                return "body"
            return render

        from host_loop.test_support import live_sample_change

        sample = live_sample_change(REPO_ROOT).lower()
        with unittest.mock.patch.object(main_mod, "body_renderer",
                                        fake_body_renderer):
            render = _candidate_body_renderer(
                str(REPO_ROOT), fallback_change=sample,
                producer="p", run_id="r")
            render(candidate(), "a" * 40, "b" * 40)
        self.assertEqual(rendered["change"],
                         canonical_change_id(REPO_ROOT, sample))


class TheRoundLineSaysWhenAndHowMuch(unittest.TestCase):
    ISO_Z = re.compile(r"\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\Z")

    def test_the_stamp_is_utc_iso_8601_with_an_explicit_zone(self):
        self.assertTrue(self.ISO_Z.match(_utc_stamp(0)), _utc_stamp(0))
        self.assertEqual(_utc_stamp(0), "1970-01-01T00:00:00Z")
        self.assertEqual(_utc_stamp(1769472000), "2026-01-27T00:00:00Z")

    def test_the_stamp_does_not_drift_with_the_host_timezone(self):
        """A local-time stamp in a log read on another machine is a wrong fact."""
        self.assertEqual(_utc_stamp(1769472000), "2026-01-27T00:00:00Z")
        self.assertTrue(_utc_stamp(1769472000).endswith("Z"))

    def _line(self, state=WorkerState.IDLE, **over):
        args = dict(changes=12, candidates=38,
                    result=RoundResult(state, None, "no ready host-only task"))
        args.update(over)
        return _round_line("2026-07-27T01:02:03Z", **args)

    def test_an_idle_line_carries_the_stamp_and_the_scanned_scope(self):
        line = self._line()
        self.assertIn("2026-07-27T01:02:03Z", line)
        self.assertIn("scope=changes:12,candidates:38", line)
        self.assertIn("idle", line)

    def test_a_claim_line_carries_the_same_stamp_and_scope(self):
        line = self._line(state=WorkerState.PR_OPEN)
        self.assertIn("2026-07-27T01:02:03Z", line)
        self.assertIn("scope=changes:12,candidates:38", line)

    def test_the_scope_distinguishes_two_otherwise_identical_idle_rounds(self):
        """31 identical idle lines were indistinguishable from one repeated line."""
        self.assertNotEqual(self._line(), self._line(changes=1, candidates=8))

    def test_the_line_still_carries_everything_it_used_to(self):
        line = self._line()
        for field in ("host-loop:", "task=", "pr=", " :: "):
            with self.subTest(field=field):
                self.assertIn(field, line)


# ------------------- DEC-NAV-001: continuation lists versus surrounding prose

class GovernedFieldsReadListsNotProse(unittest.TestCase):
    """`Depends on` and `Allowed paths` are legitimately written empty-valued
    with an indented list underneath, so the region after the colon cannot be
    discarded. It also cannot be swallowed whole: the prose that follows a task
    field is where authors put the options they rejected, and scraping it turned
    "曾考虑 `some/other/**` 但未批准" into a declared allowed path.
    """

    def _candidates(self, section: str):
        temporary = tempfile.TemporaryDirectory(prefix="dec007-fields-")
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        change = root / "openspec" / "changes" / "chg-2026-900-probe"
        change.mkdir(parents=True)
        (change / "tasks.md").write_text(section, encoding="utf-8")
        (change / "proposal.md").write_text(
            "---\nid: CHG-2026-900-probe\nstatus: approved\n---\n", encoding="utf-8")
        return discover_candidates(root, "chg-2026-900-probe")

    _HEAD = ("## TASK-PROBE-001 — probe\n"
             "- Status:ready\n"
             "- Hardware required:no\n"
             "- Decision-Grade:D0\n")

    def test_an_indented_list_continuation_is_the_value(self):
        found = self._candidates(
            self._HEAD
            + "- Depends on:none\n"
            + "- Allowed paths:\n"
            + "  - `scripts/probe/**`(采集脚本)\n"
            + "  - `docs/probe.md`\n"
            + "- Risk:low\n")
        self.assertEqual(len(found), 1)
        self.assertEqual(found[0].allowed_paths,
                         ("scripts/probe/**", "docs/probe.md"))

    def test_prose_after_an_empty_value_never_becomes_a_path(self):
        found = self._candidates(
            self._HEAD
            + "- Depends on:none\n"
            + "- Allowed paths:\n"
            + "  注：曾考虑 `some/other/**` 但未批准\n"
            + "- Risk:low\n")
        self.assertEqual(found, [], "prose donated a path and made a candidate")

    def test_prose_after_an_empty_depends_never_becomes_a_dependency(self):
        found = self._candidates(
            self._HEAD
            + "- Depends on:\n"
            + "  这一段解释了为什么 TASK-OTHER-002 曾被考虑\n"
            + "- Allowed paths:`x/**`\n"
            + "- Risk:low\n")
        self.assertEqual(found, [], "an empty Depends read as 'nothing blocks me'")

    def test_prose_below_a_real_list_is_still_excluded(self):
        found = self._candidates(
            self._HEAD
            + "- Depends on:none\n"
            + "- Allowed paths:\n"
            + "  - `scripts/probe/**`\n"
            + "  说明：`docs/rejected.md` 不在授权内\n"
            + "- Risk:low\n")
        self.assertEqual(len(found), 1)
        self.assertEqual(found[0].allowed_paths, ("scripts/probe/**",))

    def test_an_inline_value_still_works(self):
        found = self._candidates(
            self._HEAD
            + "- Depends on:TASK-OTHER-002\n"
            + "- Allowed paths:`scripts/probe/**`\n"
            + "- Risk:low\n")
        self.assertEqual(len(found), 1)
        self.assertEqual(found[0].dependencies, ("TASK-OTHER-002",))
        self.assertEqual(found[0].allowed_paths, ("scripts/probe/**",))


class TaskFieldColonParityTests(unittest.TestCase):
    """Both governed discovery fields use the same closed colon grammar."""

    _HEAD = ("## TASK-PROBE-001 — colon parity\n"
             "- Status:ready\n"
             "- Hardware required:no\n"
             "- Decision-Grade:D0\n")

    def _candidates(self, depends: str, allowed: str):
        temporary = tempfile.TemporaryDirectory(prefix="cm7-colons-")
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        write_change(
            root,
            "chg-2026-901-colon-parity",
            tasks=self._HEAD + depends + allowed + "- Risk:low\n",
        )
        return discover_candidates(root, "chg-2026-901-colon-parity")

    def _one(self, depends: str, allowed: str) -> TaskCandidate:
        found = self._candidates(depends, allowed)
        self.assertEqual(len(found), 1)
        return found[0]

    def test_full_width_depends_colon_matches_ascii(self):
        ascii_candidate = self._one(
            "- Depends on:TASK-OTHER-002\n",
            "- Allowed paths:`scripts/probe/**`\n",
        )
        full_width_candidate = self._one(
            "- Depends on：TASK-OTHER-002\n",
            "- Allowed paths:`scripts/probe/**`\n",
        )
        self.assertEqual(full_width_candidate, ascii_candidate)

    def test_full_width_allowed_paths_colon_matches_ascii(self):
        ascii_candidate = self._one(
            "- Depends on:none\n",
            "- Allowed paths:`scripts/probe/**`\n",
        )
        full_width_candidate = self._one(
            "- Depends on:none\n",
            "- Allowed paths：`scripts/probe/**`\n",
        )
        self.assertEqual(full_width_candidate, ascii_candidate)

    def test_list_continuations_are_equivalent_for_both_colons(self):
        ascii_candidate = self._one(
            "- Depends on:\n  - TASK-OTHER-002\n",
            "- Allowed paths:\n  - `scripts/probe/**`\n  - `docs/probe.md`\n",
        )
        full_width_candidate = self._one(
            "- Depends on：\n  - TASK-OTHER-002\n",
            "- Allowed paths：\n  - `scripts/probe/**`\n  - `docs/probe.md`\n",
        )
        self.assertEqual(full_width_candidate, ascii_candidate)

    def test_separators_outside_the_closed_set_fail_closed(self):
        self.assertEqual(
            self._candidates(
                "- Depends on;none\n",
                "- Allowed paths:`scripts/probe/**`\n",
            ),
            [],
        )
        self.assertEqual(
            self._candidates(
                "- Depends on:none\n",
                "- Allowed paths；`scripts/probe/**`\n",
            ),
            [],
        )

    def test_full_width_empty_fields_and_prose_still_fail_closed(self):
        self.assertEqual(
            self._candidates(
                "- Depends on：\n"
                "  这一段只提到 TASK-OTHER-002，不是合法列表\n",
                "- Allowed paths：`scripts/probe/**`\n",
            ),
            [],
        )
        self.assertEqual(
            self._candidates(
                "- Depends on：none\n",
                "- Allowed paths：\n"
                "  注：`scripts/rejected/**` 只是散文\n",
            ),
            [],
        )


class TheLiveCorpusKeepsParsing(unittest.TestCase):
    """The fix tightens a parser against files it does not own.

    Every empty-valued `Depends on` / `Allowed paths` in the live tree is the
    same legitimate shape, so a naive "empty means omit" would have silently
    dropped dozens of real tasks. This asserts the count relationship rather
    than a fixed roster so ordinary governance edits do not break it.
    """

    def test_every_task_with_an_empty_valued_field_still_yields_its_value(self):
        root = Path(__file__).resolve().parents[2]
        empty_field = re.compile(
            r"^-[ \t]*(?:Depends on|Allowed paths)[ \t]*:[ \t]*$")
        owners = set()
        for tasks in sorted((root / "openspec" / "changes").glob("chg-*/tasks.md")):
            current = None
            for line in tasks.read_text(encoding="utf-8").splitlines():
                header = re.match(r"^## (TASK-[A-Z0-9-]+)", line)
                if header:
                    current = header.group(1)
                elif current and empty_field.match(line):
                    owners.add(current)
        self.assertTrue(owners, "no live sample of the empty-valued shape")

        discovered = {}
        for change_id in active_change_ids(root):
            for candidate in discover_candidates(root, change_id):
                discovered[candidate.task_id] = candidate

        for task_id in sorted(owners & set(discovered)):
            with self.subTest(task=task_id):
                self.assertTrue(
                    discovered[task_id].allowed_paths,
                    "an empty-valued field collapsed to no declared paths")


# --------------------------- DEC-NAV-001: exit codes and suite self-collection

class CursorTroubleIsReconcileNotSetupError(unittest.TestCase):
    """Exit 1 says "transient, retry"; exit 20 says "stop, a human looks".

    cursor.py calls a missing Issue, an unparsable machine block and any
    conflict reconcile-required, and the identical CursorError raised inside
    run_once already exits 20. Raised during setup it exited 1, so the one case
    the design singles out as human-mandatory was the case the scheduler was
    told to retry.
    """

    def _classify(self, error):
        """Drive main()'s real handler with a controlled setup-phase failure.

        Raised from inside the try block rather than simulated, so the test
        measures the classification main() actually performs. read_token is
        stubbed because the handler under test sits after port construction and
        this run must not require the staged credential or the network.
        """
        argv = ["--once", "--repo-dir", str(REPO_ROOT)]
        with unittest.mock.patch.object(main_mod, "read_token",
                                        return_value="probe-token"), \
             unittest.mock.patch.object(main_mod, "discover_all",
                                        side_effect=error):
            return main_mod.main(argv)

    def test_cursor_error_is_reconcile_required(self):
        self.assertEqual(self._classify(CursorError("machine block unparsable")),
                         main_mod.EXIT_RECONCILE)

    def test_reconcile_required_is_reconcile_required(self):
        self.assertEqual(self._classify(ReconcileRequired("ambiguous identity")),
                         main_mod.EXIT_RECONCILE)

    def test_infrastructure_failures_remain_setup_errors(self):
        for error in (BackendError("git missing"),
                      TransportError("api unreachable"),
                      LeaseError("ref write ambiguous")):
            with self.subTest(error=type(error).__name__):
                self.assertEqual(self._classify(error), main_mod.EXIT_ERROR)

    def test_the_two_classes_are_distinguishable(self):
        self.assertNotEqual(main_mod.EXIT_RECONCILE, main_mod.EXIT_ERROR)


class EverySuiteCollectsAllOfItself(unittest.TestCase):
    """test_discovery_contract carried `unittest.main()` in its middle.

    Running it the way its shebang invites executed 19 of its 34 tests and
    reported OK, silently skipping the four classes that cover the fail-open
    regressions. Asserted for every suite in the package so the next file to
    grow a stray main block is caught here.
    """

    @staticmethod
    def _classes_after_main_guard(path: Path) -> bool:
        """Structural, not textual.

        A first attempt scanned for the literal `if __name__ ==` and found the
        copy inside this very helper, reporting this file against itself. Source
        text cannot tell a guard from a string that spells one; the AST can.
        """
        module = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
        guard_line = None
        for node in module.body:
            if isinstance(node, ast.If) and any(
                isinstance(sub, ast.Name) and sub.id == "__name__"
                for sub in ast.walk(node.test)
            ):
                guard_line = node.lineno
                break
        if guard_line is None:
            return False
        return any(isinstance(node, ast.ClassDef) and node.lineno > guard_line
                   for node in module.body)

    def test_no_module_ends_its_own_collection_early(self):
        directory = Path(__file__).resolve().parent
        for path in sorted(directory.glob("test_*.py")):
            with self.subTest(module=path.name):
                self.assertFalse(
                    self._classes_after_main_guard(path),
                    f"{path.name} defines test classes after unittest.main(); "
                    "running it directly would skip them")


class CorrectionsSurviveTheRoundsThatFail(unittest.TestCase):
    """reconcile runs first and may already have persisted a corrected cursor.

    The corrections list is the stated compensating control for making cache
    staleness non-fatal, yet both error handlers rebuilt the result from
    str(error) alone -- so on a reconcile-required round the write happened and
    its explanation did not, on exactly the round an operator reads.
    """

    def _worker(self):
        return Worker.__new__(Worker)

    def test_a_clean_round_still_reports_them(self):
        worker = self._worker()
        worker._corrections = ["pr_number 21 is not open; cleared"]
        result = worker._with_corrections(
            RoundResult(WorkerState.IDLE, None, "nothing claimable"))
        self.assertIn("cursor reconciled", result.detail)
        self.assertIn("pr_number 21", result.detail)

    def test_a_failing_round_reports_them_too(self):
        worker = self._worker()
        worker._corrections = ["lease fence rewound; cleared"]
        result = worker._with_corrections(
            RoundResult(WorkerState.RECONCILE_REQUIRED, None, "fence lost"))
        self.assertIn("fence lost", result.detail)
        self.assertIn("lease fence rewound", result.detail)

    def test_no_corrections_leaves_the_detail_untouched(self):
        worker = self._worker()
        worker._corrections = []
        original = RoundResult(WorkerState.IDLE, None, "nothing claimable")
        self.assertEqual(worker._with_corrections(original), original)


class AMisconfiguredCursorStopsInsteadOfDisablingItself(unittest.TestCase):
    """Setting the variable is the operator stating intent to use a cursor.

    A typo collapsed to None, which skipped load, validation and every write
    while exiting like a healthy round -- the design's "MUST rebuild and
    validate" bypassed with no diagnostic anywhere.
    """

    def test_an_unset_variable_is_still_simply_absent(self):
        with unittest.mock.patch.dict(os.environ, {}, clear=False):
            os.environ.pop("DEC007_PROBE_ISSUE", None)
            self.assertIsNone(main_mod._int_env("DEC007_PROBE_ISSUE"))

    def test_a_blank_variable_is_still_simply_absent(self):
        with unittest.mock.patch.dict(os.environ, {"DEC007_PROBE_ISSUE": "  "}):
            self.assertIsNone(main_mod._int_env("DEC007_PROBE_ISSUE"))

    def test_a_valid_value_is_returned(self):
        with unittest.mock.patch.dict(os.environ, {"DEC007_PROBE_ISSUE": "42"}):
            self.assertEqual(main_mod._int_env("DEC007_PROBE_ISSUE"), 42)

    def test_an_unparsable_value_refuses_instead_of_returning_none(self):
        with unittest.mock.patch.dict(os.environ, {"DEC007_PROBE_ISSUE": "12a"}):
            with self.assertRaises(BackendError) as caught:
                main_mod._int_env("DEC007_PROBE_ISSUE")
        self.assertIn("DEC007_PROBE_ISSUE", str(caught.exception))


class ApprovalIsNotLostToPunctuation(unittest.TestCase):
    """`(\\S+)` ran to whitespace, so `approved（注）` made an approved change
    read as unapprovable -- the same trap the task fields were fixed for."""

    def _approved(self, status_line: str) -> bool:
        temporary = tempfile.TemporaryDirectory(prefix="dec007-approval-")
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        change = root / "openspec" / "changes" / "chg-2026-900-probe"
        change.mkdir(parents=True)
        (change / "proposal.md").write_text(
            f"---\nid: CHG-2026-900-probe\n{status_line}\n---\n", encoding="utf-8")
        return main_mod._change_is_approved(root, "chg-2026-900-probe")

    def test_a_plain_value_is_approved(self):
        self.assertTrue(self._approved("status: approved"))

    def test_a_trailing_full_width_parenthetical_is_still_approved(self):
        self.assertTrue(self._approved("status:approved（2026-07-27 lvye）"))

    def test_a_trailing_comment_is_still_verified(self):
        self.assertTrue(self._approved("status: verified # ratified"))

    def test_an_unapproved_status_stays_unapproved(self):
        for status in ("proposed", "archived", "rejected"):
            with self.subTest(status=status):
                self.assertFalse(self._approved(f"status: {status}"))


class TruthObservesEveryCandidateNotOnlyTheReadyOnes(unittest.TestCase):
    """reconcile treats open_pr_numbers as total and clears what it omits.

    Building it from `ready` alone meant a task that flipped to blocked or done
    with its PR still open produced "pr_number N is not open; cleared" -- a
    falsehood in the only log that explains cache divergence, written by the
    same function whose lease half refuses to build an incomplete view.
    """

    class _Api:
        def __init__(self):
            self.heads = []

        def list_open_pulls_for_head(self, head):
            self.heads.append(head)
            return [{"number": 21}] if head.endswith("TASK-STALE-001") else []

    @staticmethod
    def _runner(argv):
        return 0, "", ""

    def _build(self, candidates):
        api = self._Api()
        truth = main_mod.build_truth(api, self._runner, Path("/unused"),
                                     "chg-probe", MAIN, candidates)
        return api, truth

    def test_a_blocked_task_with_an_open_pr_is_still_observed(self):
        api, truth = self._build([
            candidate(task_id="TASK-STALE-001", status="blocked"),
            candidate(task_id="TASK-LIVE-001", status="ready"),
        ])
        self.assertIn("agent/host-loop/tasks/TASK-STALE-001", api.heads)
        self.assertIn(21, truth.open_pr_numbers,
                      "the open PR of a non-ready task was dropped from Truth")

    def test_a_done_task_with_an_open_pr_is_still_observed(self):
        _api, truth = self._build([
            candidate(task_id="TASK-STALE-001", status="done"),
        ])
        self.assertIn(21, truth.open_pr_numbers)

    def test_ready_tasks_are_unaffected(self):
        _api, truth = self._build([
            candidate(task_id="TASK-STALE-001", status="ready"),
        ])
        self.assertEqual(truth.ready_tasks, frozenset({"TASK-STALE-001"}))
        self.assertIn(21, truth.open_pr_numbers)

    def test_each_head_is_queried_once(self):
        api, _truth = self._build([
            candidate(task_id="TASK-LIVE-001", status="ready"),
            candidate(task_id="TASK-LIVE-001", status="ready"),
        ])
        self.assertEqual(len(api.heads), len(set(api.heads)))


class ALeaseWriteNeverBlanksTheKnownPullRequest(unittest.TestCase):
    """record_round replaces every navigation field rather than merging it.

    The adopt and renew paths knew the PR from the lease and passed nothing, so
    each steady-state round stamped `pr_number: null` over a real open PR and
    only restored it at round end -- a window in which the shared Issue asserted
    a claimed task had no PR.
    """

    class _Held:
        def __init__(self, pr_number):
            self.record = type("R", (), {"task_id": "TASK-DEMO-001",
                                         "pr_number": pr_number})()
            self.ref_oid = "b" * 40

    def _captured(self, held, **kwargs):
        worker = Worker.__new__(Worker)
        seen = {}

        def fake_persist(cursor_state, main_oid, task_id, ref_name, lease_oid,
                         *, pr_number=None, pr_head=None):
            seen.update(pr_number=pr_number, pr_head=pr_head)
            return cursor_state

        worker._persist_cursor = fake_persist
        worker._after_lease_write(None, MAIN, "TASK-DEMO-001", held, **kwargs)
        return seen

    def test_the_lease_supplies_the_pr_when_the_caller_does_not(self):
        self.assertEqual(self._captured(self._Held(21))["pr_number"], 21)

    def test_an_explicit_pr_still_wins(self):
        self.assertEqual(
            self._captured(self._Held(21), pr_number=99)["pr_number"], 99)

    def test_a_lease_with_no_pr_still_records_none(self):
        self.assertIsNone(self._captured(self._Held(None))["pr_number"])


# ------------- DEC-LEFT-001: the base OID must come from protected main itself

class ObservedMainCannotBeImpersonated(unittest.TestCase):
    """`git ls-remote <remote> refs/heads/main` also selects any ref whose name
    ENDS that way at a `/` boundary, so `refs/backup/refs/heads/main` matches.

    Reading `out.split()[0]` took the first whitespace token of a multi-line
    reply, and a shadow sorts ahead of the real ref -- so the round's base OID
    came from the shadow. Everything downstream trusts it: it is the base a task
    branch is cut from and the value a fence is reasoned about. RefPort.read was
    fixed for the identical reason; this is the half that sat outside that
    task's allowed paths.
    """

    REAL = "a" * 40
    SHADOW = "6" * 40

    def _observe(self, output):
        return main_mod.observed_main(lambda argv: (0, output, ""))

    def test_a_shadow_ref_sorted_first_cannot_supply_the_base(self):
        with self.assertRaises(BackendError) as caught:
            self._observe(f"{self.SHADOW}\trefs/backup/refs/heads/main\n"
                          f"{self.REAL}\trefs/heads/main\n")
        self.assertIn("ambiguous", str(caught.exception))

    def test_a_lone_wrong_refname_is_refused(self):
        with self.assertRaises(BackendError) as caught:
            self._observe(f"{self.SHADOW}\trefs/backup/refs/heads/main\n")
        self.assertIn("not refs/heads/main", str(caught.exception))

    def test_the_exact_ref_still_supplies_the_base(self):
        self.assertEqual(self._observe(f"{self.REAL}\trefs/heads/main\n"),
                         self.REAL)

    def test_trailing_blank_lines_do_not_make_it_ambiguous(self):
        self.assertEqual(self._observe(f"{self.REAL}\trefs/heads/main\n\n"),
                         self.REAL)

    def test_a_malformed_line_is_still_unparsable(self):
        with self.assertRaises(BackendError):
            self._observe("not-an-oid\trefs/heads/main\n")

    def test_an_empty_reply_is_still_refused(self):
        with self.assertRaises(BackendError):
            self._observe("")


if __name__ == "__main__":
    unittest.main()
