#!/usr/bin/env python3
"""Contract for merge-OID recovery and restart decisions (TASK-HLR-004).

HLR-RECOVERY-001's four never-sufficient negatives each get a named test:
branch deletion, elapsed time, an Issue claiming merged, and green CI. The
sha-null metadata degradation measured on this repository (merge_commit_sha
can become null later while merged=true stays) drives the fallback cases.
"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

HOST_LOOP_DIR = Path(__file__).resolve().parent
SCRIPTS_DIR = HOST_LOOP_DIR.parent
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

from host_loop.recovery import (  # noqa: E402
    MergeConfirmation,
    RestartAction,
    RestartObservation,
    RestartWindow,
    advance_allowed,
    confirm_merged,
)

MAIN = "f" * 40
MERGE = "e" * 40
OTHER = "d" * 40
PR = 42


class ScriptedGit:
    """A git runner scripted per (subcommand) with recorded argv."""

    def __init__(self, *, ancestor=True, subject=f"fix things (#{PR})",
                 log_lines=None, fail=()):
        self.ancestor, self.subject = ancestor, subject
        self.log_lines = log_lines if log_lines is not None else []
        self.fail = set(fail)
        self.calls = []

    def __call__(self, argv):
        self.calls.append(list(argv))
        sub = argv[1]
        if sub in self.fail:
            return 128, "", "scripted failure"
        if sub == "merge-base":
            return (0 if self.ancestor else 1), "", ""
        if sub == "show":
            return 0, self.subject + "\n", ""
        if sub == "log":
            return 0, "\n".join(self.log_lines) + ("\n" if self.log_lines else ""), ""
        raise AssertionError(f"unexpected git subcommand {sub}")


def merged_pr(sha=MERGE, merged=True, **extra):
    pr = {"merged": merged, "merge_commit_sha": sha, "merged_at": "2026-07-26T00:00:00Z"}
    pr.update(extra)
    return pr


class MetadataSide(unittest.TestCase):
    def test_not_merged_is_a_plain_negative(self):
        confirmation = confirm_merged({"merged": False}, PR, MAIN, ScriptedGit())
        self.assertFalse(confirmation.confirmed)
        self.assertFalse(confirmation.ambiguous)

    def test_missing_merged_key_is_a_plain_negative(self):
        confirmation = confirm_merged({}, PR, MAIN, ScriptedGit())
        self.assertFalse(confirmation.confirmed)
        self.assertFalse(confirmation.ambiguous)

    def test_truthy_non_boolean_merged_is_ambiguous(self):
        """A truthy 1/"true" must NOT ride the sha path to a confirmation.

        The PR deliberately carries a perfectly confirmable sha: a mutant that
        reads truthiness (`not merged`) would sail through ancestry+subject and
        return confirmed, so the assertion pins the ambiguity to the flag's
        SHAPE, not to a downstream accident.
        """
        for shape in (1, "true", "yes"):
            with self.subTest(shape=shape):
                confirmation = confirm_merged(merged_pr(merged=shape), PR, MAIN,
                                              ScriptedGit())
                self.assertFalse(confirmation.confirmed)
                self.assertTrue(confirmation.ambiguous)
                self.assertIn("non-boolean", confirmation.detail)

    def test_malformed_sha_is_ambiguous(self):
        confirmation = confirm_merged(merged_pr(sha="deadbeef"), PR, MAIN,
                                      ScriptedGit())
        self.assertTrue(confirmation.ambiguous)

    def test_bad_main_oid_is_ambiguous(self):
        confirmation = confirm_merged(merged_pr(), PR, "not-an-oid", ScriptedGit())
        self.assertTrue(confirmation.ambiguous)

    def test_bool_pr_number_is_ambiguous(self):
        confirmation = confirm_merged(merged_pr(), True, MAIN, ScriptedGit())
        self.assertTrue(confirmation.ambiguous)


class CrossConfirmation(unittest.TestCase):
    def test_sha_plus_ancestry_plus_subject_confirms(self):
        confirmation = confirm_merged(merged_pr(), PR, MAIN, ScriptedGit())
        self.assertTrue(confirmation.confirmed)
        self.assertEqual(confirmation.merge_oid, MERGE)

    def test_sha_not_ancestor_is_ambiguous_not_confirmed(self):
        confirmation = confirm_merged(merged_pr(), PR, MAIN,
                                      ScriptedGit(ancestor=False))
        self.assertFalse(confirmation.confirmed)
        self.assertTrue(confirmation.ambiguous)

    def test_sha_with_foreign_subject_is_ambiguous(self):
        confirmation = confirm_merged(merged_pr(), PR, MAIN,
                                      ScriptedGit(subject="fix things (#43)"))
        self.assertTrue(confirmation.ambiguous)

    def test_git_failure_is_ambiguous_never_a_default(self):
        for sub in ("merge-base", "show"):
            with self.subTest(fails=sub):
                confirmation = confirm_merged(merged_pr(), PR, MAIN,
                                              ScriptedGit(fail={sub}))
                self.assertTrue(confirmation.ambiguous)


class ShaNullFallback(unittest.TestCase):
    def test_unique_subject_match_confirms_with_the_located_oid(self):
        git = ScriptedGit(log_lines=[f"{MERGE}\tfeat one (#{PR})",
                                     f"{OTHER}\tother (#7)"])
        confirmation = confirm_merged(merged_pr(sha=None), PR, MAIN, git)
        self.assertTrue(confirmation.confirmed)
        self.assertEqual(confirmation.merge_oid, MERGE)

    def test_zero_matches_is_ambiguous(self):
        git = ScriptedGit(log_lines=[f"{OTHER}\tother (#7)"])
        confirmation = confirm_merged(merged_pr(sha=None), PR, MAIN, git)
        self.assertTrue(confirmation.ambiguous)

    def test_multiple_matches_are_ambiguous(self):
        git = ScriptedGit(log_lines=[f"{MERGE}\tfeat (#{PR})",
                                     f"{OTHER}\trevert feat (#{PR})"])
        confirmation = confirm_merged(merged_pr(sha=None), PR, MAIN, git)
        self.assertTrue(confirmation.ambiguous)

    def test_log_failure_is_ambiguous(self):
        confirmation = confirm_merged(merged_pr(sha=None), PR, MAIN,
                                      ScriptedGit(fail={"log"}))
        self.assertTrue(confirmation.ambiguous)


class NeverSufficientNegatives(unittest.TestCase):
    """The four HLR-RECOVERY-001 negatives, each by name."""

    def test_branch_deletion_is_never_sufficient(self):
        pr = {"merged": False, "state": "closed", "head": {"ref": None},
              "note": "head branch deleted"}
        confirmation = confirm_merged(pr, PR, MAIN, ScriptedGit())
        self.assertFalse(confirmation.confirmed)
        self.assertFalse(advance_allowed(confirmation))

    def test_elapsed_time_is_never_sufficient(self):
        pr = {"merged": False, "merged_at": None,
              "updated_at": "2020-01-01T00:00:00Z"}
        confirmation = confirm_merged(pr, PR, MAIN, ScriptedGit())
        self.assertFalse(advance_allowed(confirmation))

    def test_an_issue_claim_is_never_sufficient(self):
        pr = {"merged": False, "issue_comment": "this was merged, trust me"}
        confirmation = confirm_merged(pr, PR, MAIN, ScriptedGit())
        self.assertFalse(advance_allowed(confirmation))

    def test_green_ci_is_never_sufficient(self):
        pr = {"merged": False, "checks": "all green"}
        confirmation = confirm_merged(pr, PR, MAIN, ScriptedGit())
        self.assertFalse(advance_allowed(confirmation))

    def test_advance_requires_exactly_a_confirmation(self):
        self.assertTrue(advance_allowed(
            MergeConfirmation(True, False, MERGE, "ok")))
        self.assertFalse(advance_allowed(
            MergeConfirmation(False, True, None, "ambiguous")))


class RestartWindows(unittest.TestCase):
    def test_after_acquire_needs_the_fence(self):
        action, _ = RestartWindow.AFTER_ACQUIRE, None
        act, _ = restart(RestartWindow.AFTER_ACQUIRE, fence_intact=True)
        self.assertIs(act, RestartAction.RESUME)
        act, _ = restart(RestartWindow.AFTER_ACQUIRE, fence_intact=False)
        self.assertIs(act, RestartAction.STOP)

    def test_create_timeout_adopts_exactly_one(self):
        act, _ = restart(RestartWindow.PR_CREATE_TIMEOUT, fence_intact=True,
                         open_pr_count=1)
        self.assertIs(act, RestartAction.ADOPT_EXISTING_PR)

    def test_create_timeout_zero_and_two_both_stop(self):
        for count in (0, 2, None):
            with self.subTest(count=count):
                act, _ = restart(RestartWindow.PR_CREATE_TIMEOUT,
                                 fence_intact=True, open_pr_count=count)
                self.assertIs(act, RestartAction.STOP)

    def test_create_timeout_without_fence_stops_even_with_one_pr(self):
        act, _ = restart(RestartWindow.PR_CREATE_TIMEOUT, fence_intact=False,
                         open_pr_count=1)
        self.assertIs(act, RestartAction.STOP)

    def test_body_update_needs_fence_and_unique_pr(self):
        act, _ = restart(RestartWindow.BODY_UPDATE, fence_intact=True,
                         open_pr_count=1)
        self.assertIs(act, RestartAction.RESUME)
        act, _ = restart(RestartWindow.BODY_UPDATE, fence_intact=True,
                         open_pr_count=2)
        self.assertIs(act, RestartAction.STOP)

    def test_heartbeat_loss_never_shortcuts_takeover(self):
        act, detail = restart(RestartWindow.HEARTBEAT, fence_intact=False)
        self.assertIs(act, RestartAction.STOP)
        self.assertIn("takeover", detail)

    def test_review_dispatch_re_requests_only_on_the_same_head(self):
        act, _ = restart(RestartWindow.REVIEW_DISPATCH, head_matches=True)
        self.assertIs(act, RestartAction.RESUME)
        act, _ = restart(RestartWindow.REVIEW_DISPATCH, head_matches=False)
        self.assertIs(act, RestartAction.DISCARD_REVIEW)

    def test_review_dispatch_with_recorded_result_resumes(self):
        act, _ = restart(RestartWindow.REVIEW_DISPATCH, review_recorded=True)
        self.assertIs(act, RestartAction.RESUME)

    def test_merge_observation_advances_only_on_confirmation(self):
        act, _ = restart(RestartWindow.MERGE_OBSERVATION,
                         merge=MergeConfirmation(True, False, MERGE, "ok"))
        self.assertIs(act, RestartAction.RELEASE_AND_ADVANCE)

    def test_merge_observation_ambiguity_stops(self):
        act, _ = restart(RestartWindow.MERGE_OBSERVATION,
                         merge=MergeConfirmation(False, True, None, "two sources"))
        self.assertIs(act, RestartAction.STOP)

    def test_merge_observation_not_merged_keeps_observing(self):
        act, _ = restart(RestartWindow.MERGE_OBSERVATION,
                         merge=MergeConfirmation(False, False, None, "not yet"))
        self.assertIs(act, RestartAction.RESUME)

    def test_merge_observation_without_observation_stops(self):
        act, _ = restart(RestartWindow.MERGE_OBSERVATION)
        self.assertIs(act, RestartAction.STOP)


def restart(window, **fields):
    from host_loop.recovery import restart_decision
    return restart_decision(window, RestartObservation(**fields))


if __name__ == "__main__":
    unittest.main()
