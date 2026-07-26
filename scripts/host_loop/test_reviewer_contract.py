#!/usr/bin/env python3
"""Contract for the independent reviewer loop and batch gate (TASK-HLR-004).

Every failure-matrix row of the r1 readiness has a test here, plus the three
credential/identity properties HLR-REVIEW-001 names:

* the same session cannot review its own work — refused at dispatch AND at
  result intake;
* the reviewer receives no integration credential — the adapter constructor
  is credential-free by signature, and the loop performs zero GitHub writes,
  proven by driving it against a port whose write methods raise;
* an APPROVE is never a GitHub approval — every serialized result and every
  rendered batch entry carries the declaration.
"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

HOST_LOOP_DIR = Path(__file__).resolve().parent
SCRIPTS_DIR = HOST_LOOP_DIR.parent
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

from host_loop.reviewer import (  # noqa: E402
    AdapterFailure,
    BATCH_DECLARATION,
    BatchEntry,
    BatchNotEligible,
    NOT_GITHUB_APPROVAL,
    ReviewContractError,
    ReviewPhase,
    ReviewRequest,
    ReviewResult,
    ReviewState,
    ReviewerLoop,
    SubprocessReviewerAdapter,
    adapter_is_credential_free,
    checks_digest,
    queue_for_batch,
    render_batch_issue,
)
from host_loop.transport import ALLOWED_ROUTES  # noqa: E402

HEAD = "a" * 40
BASE = "b" * 40
OTHER = "c" * 40

GREEN_RUNS = [
    {"name": "guard", "status": "completed", "conclusion": "success"},
    {"name": "allowed-paths", "status": "completed", "conclusion": "success"},
]
PENDING_RUNS = [
    {"name": "guard", "status": "in_progress", "conclusion": None},
    {"name": "allowed-paths", "status": "completed", "conclusion": "success"},
]


def make_pr(number=7, head=HEAD, base_sha=BASE, state="open", merged=False,
            body="PR-Type: implementation\nTask: TASK-X-001\n"):
    return {
        "number": number, "state": state, "merged": merged, "body": body,
        "head": {"sha": head}, "base": {"ref": "main", "sha": base_sha},
    }


def make_request(**overrides):
    fields = dict(change="CHG-X", task="TASK-X-001", pr_number=7,
                  head_oid=HEAD, base_oid=BASE, checks_digest="d" * 8,
                  requested_by_run="worker-run")
    fields.update(overrides)
    return ReviewRequest(**fields)


def make_result(verdict="APPROVE", reviewer_run="reviewer-run", head=HEAD):
    return ReviewResult(verdict=verdict, reviewer_run=reviewer_run,
                        head_oid=head, recorded_at=1, reasons=())


class FixedPort:
    """A reviewer port that returns a prepared result (or raises)."""

    def __init__(self, result=None, error=None):
        self.result, self.error, self.calls = result, error, 0

    def request_review(self, request):
        self.calls += 1
        if self.error is not None:
            raise self.error
        return self.result


class RequestAndResultShape(unittest.TestCase):
    def test_request_is_immutable(self):
        request = make_request()
        with self.assertRaises(Exception):
            request.head_oid = OTHER  # type: ignore[misc]

    def test_result_is_immutable(self):
        result = make_result()
        with self.assertRaises(Exception):
            result.verdict = "BLOCKED"  # type: ignore[misc]

    def test_request_rejects_short_oids(self):
        with self.assertRaises(ReviewContractError):
            make_request(head_oid="deadbeef")

    def test_request_rejects_bool_pr_number(self):
        with self.assertRaises(ReviewContractError):
            make_request(pr_number=True)

    def test_result_rejects_a_foreign_verdict(self):
        with self.assertRaises(ReviewContractError):
            make_result(verdict="LGTM")

    def test_result_rejects_bool_recorded_at(self):
        with self.assertRaises(ReviewContractError):
            ReviewResult(verdict="APPROVE", reviewer_run="r", head_oid=HEAD,
                         recorded_at=True)

    def test_serialization_always_disclaims_github_approval(self):
        doc = make_result().serialize()
        self.assertIs(doc["github_approval"], False)
        self.assertEqual(doc["declaration"], NOT_GITHUB_APPROVAL)
        self.assertIn("NOT a GitHub approval", doc["declaration"])

    def test_checks_digest_is_order_independent_and_content_sensitive(self):
        one = checks_digest(GREEN_RUNS)
        two = checks_digest(list(reversed(GREEN_RUNS)))
        self.assertEqual(one, two)
        self.assertNotEqual(one, checks_digest(PENDING_RUNS))


class AdapterContract(unittest.TestCase):
    def _adapter(self, runner, run_id="reviewer-run"):
        return SubprocessReviewerAdapter(
            executable="claude", run_id_factory=lambda: run_id, runner=runner)

    def test_constructor_is_credential_free(self):
        self.assertTrue(adapter_is_credential_free())

    def test_availability_probe_ok(self):
        ok, version = SubprocessReviewerAdapter.availability_probe(
            "claude", runner=lambda argv, timeout, cwd: (0, "2.1.220 (Claude Code)\n", ""))
        self.assertTrue(ok)
        self.assertEqual(version, "2.1.220 (Claude Code)")

    def test_availability_probe_fails_closed_on_nonzero_or_empty(self):
        ok, _ = SubprocessReviewerAdapter.availability_probe(
            "claude", runner=lambda argv, timeout, cwd: (1, "", "not found"))
        self.assertFalse(ok)
        ok, _ = SubprocessReviewerAdapter.availability_probe(
            "claude", runner=lambda argv, timeout, cwd: (0, "", ""))
        self.assertFalse(ok)

    def test_argv_is_executable_print_prompt_only(self):
        adapter = self._adapter(runner=None.__class__)
        argv = adapter.build_argv(make_request())
        self.assertEqual(argv[0], "claude")
        self.assertEqual(argv[1], "-p")
        self.assertEqual(len(argv), 3)
        self.assertIn(HEAD, argv[2])
        self.assertIn("VERDICT: APPROVE", argv[2])
        self.assertIn("NOT a GitHub approval", argv[2])

    def test_parses_the_last_verdict_line(self):
        out = "REASON: fine\nVERDICT: REQUEST_CHANGES\nREASON: later\nVERDICT: APPROVE\n"
        adapter = self._adapter(runner=lambda argv, timeout, cwd: (0, out, ""))
        result = adapter.request_review(make_request())
        self.assertEqual(result.verdict, "APPROVE")
        self.assertEqual(result.reasons, ("fine", "later"))
        self.assertEqual(result.head_oid, HEAD)

    def test_nonzero_exit_is_an_adapter_failure(self):
        adapter = self._adapter(runner=lambda argv, timeout, cwd: (2, "", "boom"))
        with self.assertRaises(AdapterFailure):
            adapter.request_review(make_request())

    def test_missing_verdict_is_an_adapter_failure(self):
        adapter = self._adapter(runner=lambda argv, timeout, cwd: (0, "chatty\n", ""))
        with self.assertRaises(AdapterFailure):
            adapter.request_review(make_request())

    def test_same_session_dispatch_is_refused(self):
        adapter = self._adapter(
            runner=lambda argv, timeout, cwd: (0, "VERDICT: APPROVE\n", ""),
            run_id="worker-run")
        with self.assertRaises(ReviewContractError):
            adapter.request_review(make_request(requested_by_run="worker-run"))


class PhaseFailureMatrix(unittest.TestCase):
    def _run(self, port, pr=None, runs=None):
        # `runs or GREEN_RUNS` would swallow an EMPTY runs list into green —
        # the exact falsy-default class the missing-checks row exists to test.
        phase = ReviewPhase(port, now=lambda: 1)
        return phase.run(make_pr() if pr is None else pr,
                         GREEN_RUNS if runs is None else runs,
                         change="CHG-X", task="TASK-X-001",
                         requested_by_run="worker-run")

    def test_row1_adapter_crash_is_reconcile(self):
        state, result, detail = self._run(FixedPort(error=AdapterFailure("t/o")))
        self.assertIs(state, ReviewState.RECONCILE_REQUIRED)
        self.assertIsNone(result)
        self.assertIn("adapter failed", detail)

    def test_row1_unexpected_exception_is_reconcile(self):
        state, _, detail = self._run(FixedPort(error=ValueError("shape")))
        self.assertIs(state, ReviewState.RECONCILE_REQUIRED)
        self.assertIn("unexpected ValueError", detail)

    def test_row2_stale_head_is_discarded_to_discover(self):
        port = FixedPort(result=make_result(head=OTHER))
        phase = ReviewPhase(port, now=lambda: 1)
        state, result, detail = phase.run(
            make_pr(), GREEN_RUNS, change="CHG-X", task="TASK-X-001",
            requested_by_run="worker-run")
        self.assertIs(state, ReviewState.DISCOVER)
        self.assertIsNone(result)
        self.assertIn("stale", detail)
        self.assertEqual(phase._recorded, {}, "a stale result must not be recorded")

    def test_row3_contract_error_is_reconcile(self):
        state, _, _ = self._run(FixedPort(error=ReviewContractError("bad verdict")))
        self.assertIs(state, ReviewState.RECONCILE_REQUIRED)

    def test_row4_same_session_result_is_refused(self):
        port = FixedPort(result=make_result(reviewer_run="worker-run"))
        state, result, detail = self._run(port)
        self.assertIs(state, ReviewState.RECONCILE_REQUIRED)
        self.assertIsNone(result)
        self.assertIn("HLR-REVIEW-001", detail)

    def test_row5_request_changes_pauses_the_worker(self):
        state, result, _ = self._run(
            FixedPort(result=make_result(verdict="REQUEST_CHANGES")))
        self.assertIs(state, ReviewState.WORKER_PAUSED)
        self.assertEqual(result.verdict, "REQUEST_CHANGES")

    def test_row5_blocked_pauses_the_worker(self):
        state, _, _ = self._run(FixedPort(result=make_result(verdict="BLOCKED")))
        self.assertIs(state, ReviewState.WORKER_PAUSED)

    def test_row6_pending_checks_never_dispatch_the_reviewer(self):
        port = FixedPort(result=make_result())
        state, result, detail = self._run(port, runs=PENDING_RUNS)
        self.assertIs(state, ReviewState.NOT_ELIGIBLE)
        self.assertIsNone(result)
        self.assertEqual(port.calls, 0, "an ineligible candidate must not reach "
                                        "the reviewer at all")
        self.assertIn("pending", detail)

    def test_row6_missing_checks_never_dispatch_the_reviewer(self):
        port = FixedPort(result=make_result())
        state, _, _ = self._run(port, runs=[])
        self.assertIs(state, ReviewState.NOT_ELIGIBLE)
        self.assertEqual(port.calls, 0)

    def test_row6_closed_pr_is_not_eligible(self):
        port = FixedPort(result=make_result())
        state, _, _ = self._run(port, pr=make_pr(state="closed"))
        self.assertIs(state, ReviewState.NOT_ELIGIBLE)
        self.assertEqual(port.calls, 0)

    def test_row6_empty_body_is_incomplete_metadata(self):
        state, _, detail = self._run(FixedPort(result=make_result()),
                                     pr=make_pr(body="  "))
        self.assertIs(state, ReviewState.NOT_ELIGIBLE)
        self.assertIn("envelope", detail)

    def test_row6_non_main_base_is_not_eligible(self):
        pr = make_pr()
        pr["base"]["ref"] = "develop"
        state, _, _ = self._run(FixedPort(result=make_result()), pr=pr)
        self.assertIs(state, ReviewState.NOT_ELIGIBLE)

    def test_row7_duplicate_result_is_refused_and_first_stands(self):
        port = FixedPort(result=make_result())
        phase = ReviewPhase(port, now=lambda: 1)
        first = phase.run(make_pr(), GREEN_RUNS, change="CHG-X",
                          task="TASK-X-001", requested_by_run="worker-run")
        self.assertIs(first[0], ReviewState.REVIEW_RECORDED)
        port.result = make_result(verdict="BLOCKED")
        state, result, detail = phase.run(
            make_pr(), GREEN_RUNS, change="CHG-X", task="TASK-X-001",
            requested_by_run="worker-run")
        self.assertIs(state, ReviewState.REVIEW_RECORDED)
        self.assertEqual(result.verdict, "APPROVE",
                         "the FIRST recorded result must stand")
        self.assertIn("duplicate", detail)
        self.assertEqual(port.calls, 1, "the duplicate must not re-dispatch")

    def test_foreign_result_object_is_reconcile(self):
        state, _, detail = self._run(FixedPort(result={"verdict": "APPROVE"}))
        self.assertIs(state, ReviewState.RECONCILE_REQUIRED)
        self.assertIn("foreign object", detail)

    def test_approve_records_and_says_not_github_approval(self):
        state, result, detail = self._run(FixedPort(result=make_result()))
        self.assertIs(state, ReviewState.REVIEW_RECORDED)
        self.assertEqual(result.verdict, "APPROVE")
        self.assertIn("not a GitHub approval", detail)


class WriteLessApiPort:
    """Lookup methods answer; every write method raises. Driving the loop to
    completion against this port PROVES the loop is read-only."""

    def __init__(self, pulls, pr, runs):
        self._pulls, self._pr, self._runs = pulls, pr, runs
        self.write_calls = 0

    def list_open_pulls_for_head(self, head_branch):
        return self._pulls

    def get_pull(self, number):
        return self._pr

    def list_check_runs(self, oid):
        return self._runs

    def _write(self, *a, **k):
        self.write_calls += 1
        raise AssertionError("the reviewer loop must never write")

    create_pull = update_pull = create_issue = update_issue = close_issue = _write


class LoopReadOnly(unittest.TestCase):
    def _loop(self, api):
        phase = ReviewPhase(FixedPort(result=make_result()), now=lambda: 1)
        return ReviewerLoop(api, phase, change="CHG-X", worker_run="worker-run")

    def test_full_pass_performs_zero_writes(self):
        api = WriteLessApiPort([{"number": 7}], make_pr(), GREEN_RUNS)
        outcomes = self._loop(api).review_once(["TASK-X-001"])
        self.assertEqual(outcomes[0][1], ReviewState.REVIEW_RECORDED)
        self.assertEqual(api.write_calls, 0)

    def test_no_open_pr_is_not_eligible(self):
        api = WriteLessApiPort([], make_pr(), GREEN_RUNS)
        outcomes = self._loop(api).review_once(["TASK-X-001"])
        self.assertEqual(outcomes[0][1], ReviewState.NOT_ELIGIBLE)

    def test_two_prs_on_one_head_is_reconcile(self):
        api = WriteLessApiPort([{"number": 7}, {"number": 8}], make_pr(), GREEN_RUNS)
        outcomes = self._loop(api).review_once(["TASK-X-001"])
        self.assertEqual(outcomes[0][1], ReviewState.RECONCILE_REQUIRED)

    def test_non_int_pr_number_is_reconcile(self):
        api = WriteLessApiPort([{"number": "7"}], make_pr(), GREEN_RUNS)
        outcomes = self._loop(api).review_once(["TASK-X-001"])
        self.assertEqual(outcomes[0][1], ReviewState.RECONCILE_REQUIRED)

    def test_module_adds_no_transport_route(self):
        """The frozen allowlist is untouched by importing/using this module.

        8 after TASK-TAS-001 removed the two zero-callsite bare-list entries.
        """
        self.assertEqual(len(ALLOWED_ROUTES), 8)


class BatchGate(unittest.TestCase):
    def _entry(self, **overrides):
        fields = dict(grade="D0", change="CHG-X", task="TASK-X-001",
                      summary="does one thing", base_oid=BASE, head_oid=HEAD,
                      files_readback=("a.py",), risk="low; deterministic",
                      evidence_ptr="evidence/runs/TASK-X-001/run.md",
                      pr_number=7, title="one thing")
        fields.update(overrides)
        return BatchEntry(**fields)

    def test_gate3_missing_fields_each_fail(self):
        for name, bad in [("summary", " "), ("risk", ""), ("evidence_ptr", ""),
                          ("title", " "), ("files_readback", ()),
                          ("head_oid", "short"), ("grade", "P0")]:
            with self.subTest(field=name):
                with self.assertRaises(BatchNotEligible):
                    self._entry(**{name: bad})

    def test_gate1_checks_not_green_refused(self):
        with self.assertRaises(BatchNotEligible) as caught:
            queue_for_batch(self._entry(), checks_state="pending",
                            review=make_result())
        self.assertIn("not green", str(caught.exception))

    def test_gate2_non_approve_refused(self):
        with self.assertRaises(BatchNotEligible):
            queue_for_batch(self._entry(), checks_state="green",
                            review=make_result(verdict="REQUEST_CHANGES"))

    def test_gate2_head_move_invalidates_the_old_approve(self):
        with self.assertRaises(BatchNotEligible) as caught:
            queue_for_batch(self._entry(), checks_state="green",
                            review=make_result(head=OTHER))
        self.assertIn("head move", str(caught.exception))

    def test_all_gates_pass_renders_the_template_fields(self):
        section = queue_for_batch(self._entry(), checks_state="green",
                                  review=make_result())
        for label in ("| Grade |", "| Change/Task |", "| 内容 |",
                      "| Base/Head OID |", "| Files read-back |",
                      "| 风险与影响面 |", "| Evidence/测试指针 |"):
            self.assertIn(label, section)
        self.assertIn(BASE, section)
        self.assertIn(HEAD, section)
        self.assertIn("NOT a GitHub approval", section)

    def test_issue_render_carries_the_declaration_verbatim(self):
        section = queue_for_batch(self._entry(), checks_state="green",
                                  review=make_result())
        body = render_batch_issue([section])
        self.assertIn(BATCH_DECLARATION, body)
        self.assertIn("仅是导航", body)
        self.assertIn("CI 绿 ≠ 批准", body)
        self.assertIn("### 项 1：PR #7", body)


if __name__ == "__main__":
    unittest.main()
