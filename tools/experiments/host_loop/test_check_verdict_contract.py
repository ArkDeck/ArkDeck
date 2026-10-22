#!/usr/bin/env python3
"""Exhaustive contract for the required-check verdict (TASK-HLR-003).

This function has now been wrong twice in governance-relevant directions:

  r1  presence was decided by name alone and `skipped` counted as success, so a
      required check that never ran read as green and the check dispatch never
      fired in production;
  v3  the fix made `success` an absorbing state per name, so an executed
      failure on the same required name was swallowed — the exact
      `pull_request: edited` run the r1 fix exists to trigger could never fail
      a round.

Patching points is what produced that oscillation, so the verdict is specified
here as a table instead: every (status x conclusion) pair, every multiplicity,
and the required/non-required split. The table is the contract; the
implementation has to satisfy it.

Two invariants the table exists to protect:

  1. FAILURE DOMINATES. For a required name, one executed failure decides the
     verdict no matter what any sibling run says or what order the runs arrive.
  2. NO ASYMMETRY. Listing a check as required may only ever make the gate
     stricter. It must never be possible for the same pair of conclusions to be
     green on a required name and failed on a non-required one.
"""

from __future__ import annotations

import itertools
import sys
import unittest
from pathlib import Path

HOST_LOOP_DIR = Path(__file__).resolve().parent
SCRIPTS_DIR = HOST_LOOP_DIR.parent
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

from host_loop import worker as worker_mod  # noqa: E402
from host_loop.worker import (  # noqa: E402
    REQUIRED_PR_CHECKS,
    classify_checks,
    required_verdicts,
    unsatisfied_required_checks,
)

# Production requires exactly one name since CHG-2026-077 retired the
# `allowed-paths` check. The table below is a contract over the verdict
# FUNCTION, and its multi-name invariants (an absent sibling is pending, green
# needs every name, no asymmetry across names) only mean something with at
# least two required names — so every table class runs under a two-name
# fixture set patched into the module, and ProductionRequiredSet pins the real
# one. The functions read REQUIRED_PR_CHECKS at call time, which is what makes
# the patch effective.
REQUIRED = "guard"
OTHER_REQUIRED = "other-required"
FIXTURE_REQUIRED_SET = (REQUIRED, OTHER_REQUIRED)
NON_REQUIRED = "swift"

# GitHub's documented conclusion values, plus the absent case.
EXECUTED_OK = ("success",)
EXECUTED_BAD = ("failure", "cancelled", "timed_out", "action_required", "stale")
NOT_EXECUTED = ("skipped", "neutral", None)
ALL_CONCLUSIONS = EXECUTED_OK + EXECUTED_BAD + NOT_EXECUTED


def run(name, status="completed", conclusion="success"):
    return {"name": name, "status": status, "conclusion": conclusion}


def _satisfied(runs, name=REQUIRED):
    return required_verdicts(runs)[name]


class _TwoNameTable(unittest.TestCase):
    """Runs the verdict functions under FIXTURE_REQUIRED_SET."""

    def setUp(self):
        self._production_set = worker_mod.REQUIRED_PR_CHECKS
        worker_mod.REQUIRED_PR_CHECKS = FIXTURE_REQUIRED_SET

    def tearDown(self):
        worker_mod.REQUIRED_PR_CHECKS = self._production_set


class SingleRunTable(_TwoNameTable):
    """One run per required name: the verdict is decided by status+conclusion."""

    def test_completed_success_is_the_only_satisfying_shape(self):
        for conclusion in ALL_CONCLUSIONS:
            with self.subTest(conclusion=conclusion):
                runs = [run(REQUIRED, conclusion=conclusion),
                        run(OTHER_REQUIRED)]
                expected = "success" if conclusion in EXECUTED_OK else (
                    "failed" if conclusion in EXECUTED_BAD else "pending")
                self.assertEqual(_satisfied(runs), expected)

    def test_any_non_completed_status_is_pending_regardless_of_conclusion(self):
        for status in ("queued", "in_progress", "waiting", "requested", "pending"):
            for conclusion in ALL_CONCLUSIONS:
                with self.subTest(status=status, conclusion=conclusion):
                    runs = [run(REQUIRED, status=status, conclusion=conclusion),
                            run(OTHER_REQUIRED)]
                    self.assertEqual(_satisfied(runs), "pending")

    def test_an_absent_required_name_is_pending(self):
        self.assertEqual(required_verdicts([run(OTHER_REQUIRED)])[REQUIRED],
                         "pending")

    def test_an_empty_set_leaves_every_required_name_pending(self):
        self.assertEqual(set(required_verdicts([]).values()), {"pending"})
        self.assertEqual(unsatisfied_required_checks([]),
                         tuple(sorted(FIXTURE_REQUIRED_SET)))


class FailureDominatesTable(_TwoNameTable):
    """Invariant 1: one executed failure on a required name decides the verdict.

    This is the direction v3 got wrong. `guard` runs in BOTH suites — sdd-guard's
    guard job carries no `if:` — so success-from-push paired with
    failure-from-pull_request is the ordinary shape, not a corner case.
    """

    def test_success_never_absorbs_a_sibling_failure(self):
        for bad in EXECUTED_BAD:
            for order in ((("success",), (bad,)), ((bad,), ("success",))):
                first, second = order
                with self.subTest(bad=bad, first=first[0]):
                    runs = [run(REQUIRED, conclusion=first[0]),
                            run(REQUIRED, conclusion=second[0]),
                            run(OTHER_REQUIRED)]
                    self.assertEqual(_satisfied(runs), "failed")
                    self.assertEqual(classify_checks(runs), "failed")

    def test_a_not_executed_sibling_does_not_rescue_a_failure(self):
        for benign in NOT_EXECUTED:
            with self.subTest(benign=benign):
                runs = [run(REQUIRED, conclusion="failure"),
                        run(REQUIRED, conclusion=benign),
                        run(OTHER_REQUIRED)]
                self.assertEqual(_satisfied(runs), "failed")

    def test_a_benign_sibling_does_not_disturb_a_success(self):
        """`skipped`/`neutral` mean the run deliberately did not execute."""
        for benign in ("skipped", "neutral"):
            with self.subTest(benign=benign):
                runs = [run(REQUIRED, conclusion="success"),
                        run(REQUIRED, conclusion=benign),
                        run(OTHER_REQUIRED)]
                self.assertEqual(_satisfied(runs), "success")

    def test_a_malformed_sibling_blocks_despite_a_success(self):
        """A completed run with no conclusion is malformed, not benign.

        The previous version of this test asserted "success" for this pair. That
        froze an ASYMMETRY into the contract: the identical pair on a
        non-required name is pending, via _non_required_outcome's separate
        accumulator. Requiring a check was therefore LAXER, the exact property
        the docstring claims is impossible.
        """
        runs = [run(REQUIRED, conclusion="success"),
                run(REQUIRED, conclusion=None),
                run(OTHER_REQUIRED)]
        self.assertEqual(_satisfied(runs), "pending")

    def test_an_inflight_sibling_blocks_despite_a_success(self):
        """The third defect in this function, after r1 and v3.

        `guard` is published by BOTH the push suite and the pull_request suite.
        The edited `allowed-paths` job finishes fast; the edited `guard` job runs
        the whole of check-sdd.sh. So [guard success (push), guard in_progress
        (edited)] is the ORDINARY steady state after a dispatch — and it read as
        green, with unsatisfied_required_checks() empty, which also suppressed
        re-dispatch. The still-running run is the one that can differ from the
        push run, because a pull_request checkout resolves the merge ref.
        """
        for status in ("queued", "in_progress", "waiting", "requested", "pending"):
            with self.subTest(status=status):
                runs = [run(REQUIRED, conclusion="success"),
                        run(REQUIRED, status=status, conclusion=None),
                        run(OTHER_REQUIRED)]
                self.assertEqual(_satisfied(runs), "pending")
                self.assertIn(REQUIRED, unsatisfied_required_checks(runs))
                self.assertEqual(classify_checks(runs), "pending")

    def test_an_inflight_sibling_still_loses_to_a_failure(self):
        """Ordering of the lattice: failed > pending > success."""
        runs = [run(REQUIRED, conclusion="success"),
                run(REQUIRED, status="in_progress", conclusion=None),
                run(REQUIRED, conclusion="failure"),
                run(OTHER_REQUIRED)]
        self.assertEqual(_satisfied(runs), "failed")

    def test_three_runs_with_one_failure_still_fail(self):
        runs = [run(REQUIRED, conclusion="success"),
                run(REQUIRED, conclusion="skipped"),
                run(REQUIRED, conclusion="failure"),
                run(OTHER_REQUIRED)]
        self.assertEqual(_satisfied(runs), "failed")

    def test_verdict_is_order_independent_over_every_permutation(self):
        base = [run(REQUIRED, conclusion="success"),
                run(REQUIRED, conclusion="failure"),
                run(REQUIRED, status="in_progress", conclusion=None),
                run(OTHER_REQUIRED)]
        seen = {classify_checks(list(order)) for order in itertools.permutations(base)}
        self.assertEqual(seen, {"failed"},
                         "the verdict must not depend on arrival order")


class NoAsymmetryTable(_TwoNameTable):
    """Invariant 2: requiring a check may only ever make the gate stricter."""

    def test_the_same_pair_is_not_green_on_required_and_failed_on_non_required(self):
        for bad in EXECUTED_BAD:
            with self.subTest(bad=bad):
                on_required = [run(REQUIRED, conclusion="success"),
                               run(REQUIRED, conclusion=bad),
                               run(OTHER_REQUIRED)]
                on_other = [run(REQUIRED), run(OTHER_REQUIRED),
                            run(NON_REQUIRED, conclusion="success"),
                            run(NON_REQUIRED, conclusion=bad)]
                self.assertEqual(classify_checks(on_required),
                                 classify_checks(on_other),
                                 "required must not be laxer than non-required")

    def test_no_asymmetry_over_every_sibling_pair(self):
        """The cross-product the single-run version could not see.

        For every ordered pair of run shapes, promoting the name to required
        must be at least as strict as leaving it non-required. The previous
        NoAsymmetryTable only varied one run per name plus multiplicity over
        EXECUTED_BAD, so it was structurally blind to the not-executed and
        non-completed siblings — which is where the divergence actually was.
        """
        shapes = [("completed", c) for c in ALL_CONCLUSIONS]
        shapes += [(s, None) for s in ("queued", "in_progress", "waiting")]
        strictness = {"green": 0, "pending": 1, "failed": 2}
        for first in shapes:
            for second in shapes:
                with self.subTest(first=first, second=second):
                    as_required = classify_checks([
                        run(REQUIRED, status=first[0], conclusion=first[1]),
                        run(REQUIRED, status=second[0], conclusion=second[1]),
                        run(OTHER_REQUIRED)])
                    as_non_required = classify_checks([
                        run(REQUIRED), run(OTHER_REQUIRED),
                        run(NON_REQUIRED, status=first[0], conclusion=first[1]),
                        run(NON_REQUIRED, status=second[0], conclusion=second[1])])
                    self.assertGreaterEqual(
                        strictness[as_required], strictness[as_non_required],
                        f"required is laxer for {first} + {second}")

    def test_promoting_a_name_to_required_never_loosens_a_verdict(self):
        """For every conclusion set, required must be at least as strict."""
        for conclusion in ALL_CONCLUSIONS:
            with self.subTest(conclusion=conclusion):
                as_required = classify_checks([
                    run(REQUIRED, conclusion=conclusion), run(OTHER_REQUIRED)])
                as_non_required = classify_checks([
                    run(REQUIRED), run(OTHER_REQUIRED),
                    run(NON_REQUIRED, conclusion=conclusion)])
                strictness = {"green": 0, "pending": 1, "failed": 2}
                self.assertGreaterEqual(strictness[as_required],
                                        strictness[as_non_required])


class NonRequiredTable(_TwoNameTable):
    """Non-required runs can fail or delay a round, order-independently."""

    def test_a_failed_non_required_run_fails_the_round_in_any_position(self):
        base = [run(REQUIRED), run(OTHER_REQUIRED),
                run(NON_REQUIRED, conclusion="failure"),
                run("extra", status="in_progress", conclusion=None)]
        seen = {classify_checks(list(order)) for order in itertools.permutations(base)}
        self.assertEqual(seen, {"failed"},
                         "a pending sibling must not downgrade a failure")

    def test_a_pending_non_required_run_keeps_the_round_pending(self):
        runs = [run(REQUIRED), run(OTHER_REQUIRED),
                run(NON_REQUIRED, status="queued", conclusion=None)]
        self.assertEqual(classify_checks(runs), "pending")

    def test_skipped_or_neutral_non_required_runs_are_not_failures(self):
        for benign in ("skipped", "neutral"):
            with self.subTest(benign=benign):
                runs = [run(REQUIRED), run(OTHER_REQUIRED),
                        run(NON_REQUIRED, conclusion=benign)]
                self.assertEqual(classify_checks(runs), "green")

    def test_an_unknown_extra_success_cannot_satisfy_a_required_name(self):
        runs = [run(REQUIRED), run("something-else", conclusion="success")]
        self.assertEqual(unsatisfied_required_checks(runs), (OTHER_REQUIRED,))
        self.assertEqual(classify_checks(runs), "pending")


class GreenIsExactlyAllRequiredExecutedSuccessfully(_TwoNameTable):
    def test_green_requires_every_required_name(self):
        self.assertEqual(classify_checks([run(REQUIRED)]), "pending")
        self.assertEqual(
            classify_checks([run(REQUIRED), run(OTHER_REQUIRED)]), "green")

    def test_a_push_only_head_under_the_fixture_set_is_pending(self):
        """Under two names a head that executed only one of them is pending."""
        runs = [run(REQUIRED, conclusion="success"),
                run(OTHER_REQUIRED, conclusion="skipped")]
        self.assertEqual(classify_checks(runs), "pending")
        self.assertEqual(unsatisfied_required_checks(runs), (OTHER_REQUIRED,))

    def test_an_executed_success_on_the_edited_run_promotes_to_green(self):
        runs = [run(REQUIRED, conclusion="success"),
                run(REQUIRED, conclusion="success"),
                run(OTHER_REQUIRED, conclusion="skipped"),
                run(OTHER_REQUIRED, conclusion="success"),
                run("swift", conclusion="success")]
        self.assertEqual(classify_checks(runs), "green")


class ProductionRequiredSet(unittest.TestCase):
    """The real required set, unpatched: exactly `guard` since CHG-2026-077."""

    def test_production_requires_exactly_guard(self):
        self.assertEqual(REQUIRED_PR_CHECKS, ("guard",))
        self.assertEqual(worker_mod.REQUIRED_PR_CHECKS, ("guard",))

    def test_a_push_head_with_an_executed_guard_is_green(self):
        """No second name means no dispatch is needed for a green head."""
        runs = [run("guard", conclusion="success")]
        self.assertEqual(classify_checks(runs), "green")
        self.assertEqual(unsatisfied_required_checks(runs), ())
        self.assertEqual(required_verdicts(runs), {"guard": "success"})

    def test_the_edited_guard_run_can_still_fail_the_round(self):
        """The whole point of the r1 fix: the merge-ref run must be able to fail."""
        runs = [run("guard", conclusion="success"),      # push suite
                run("guard", conclusion="failure")]      # pull_request suite
        self.assertEqual(classify_checks(runs), "failed")

    def test_an_inflight_edited_guard_run_keeps_the_round_pending(self):
        runs = [run("guard", conclusion="success"),
                run("guard", status="in_progress", conclusion=None)]
        self.assertEqual(classify_checks(runs), "pending")
        self.assertEqual(unsatisfied_required_checks(runs), ("guard",))

    def test_a_run_under_the_retired_name_is_an_ordinary_non_required_run(self):
        """A head cut before the retirement may still carry `allowed-paths`
        runs: they satisfy nothing, a skipped one is benign and a failed one
        fails the round like any other non-required failure."""
        self.assertEqual(unsatisfied_required_checks([run("allowed-paths")]),
                         ("guard",))
        self.assertEqual(classify_checks(
            [run("guard"), run("allowed-paths", conclusion="skipped")]), "green")
        self.assertEqual(classify_checks(
            [run("guard"), run("allowed-paths", conclusion="failure")]), "failed")


class VerdictSurfaceIsTotal(_TwoNameTable):
    def test_every_required_name_appears_in_the_mapping(self):
        for runs in ([], [run(REQUIRED)], [run("unrelated")]):
            with self.subTest(runs=len(runs)):
                self.assertEqual(set(required_verdicts(runs)),
                                 set(FIXTURE_REQUIRED_SET))

    def test_only_three_verdict_values_are_possible(self):
        for conclusion in ALL_CONCLUSIONS:
            for status in ("completed", "queued", "in_progress"):
                verdicts = required_verdicts(
                    [run(REQUIRED, status=status, conclusion=conclusion)])
                self.assertLessEqual(set(verdicts.values()),
                                     {"success", "failed", "pending"})

    def test_unsatisfied_is_exactly_the_non_success_names(self):
        runs = [run(REQUIRED, conclusion="failure"), run(OTHER_REQUIRED)]
        verdicts = required_verdicts(runs)
        self.assertEqual(
            set(unsatisfied_required_checks(runs)),
            {name for name, verdict in verdicts.items() if verdict != "success"})

    def test_a_malformed_run_entry_cannot_satisfy_anything(self):
        for junk in ({}, {"name": None}, {"name": REQUIRED},
                     {"name": REQUIRED, "status": "completed"}):
            with self.subTest(junk=junk):
                self.assertNotEqual(
                    required_verdicts([junk, run(OTHER_REQUIRED)])[REQUIRED],
                    "success")


if __name__ == "__main__":
    unittest.main(verbosity=2)
