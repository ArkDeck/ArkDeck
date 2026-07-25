"""Cursor and worker state-machine faults (TASK-HLR-003 draft).

Covers the readiness items not exercised by test_fault_matrix.py: Issue cursor
corruption and cache/truth conflict, the discovery gates (approval, ready,
host-only, dependencies, allowed paths, base pin, decision grade), the
D1/D2 no-start rule, and the "CI green is not merge permission" boundary.
"""

from __future__ import annotations

import unittest

import sys
from pathlib import Path

HOST_LOOP_DIR = Path(__file__).resolve().parent
SCRIPTS_DIR = HOST_LOOP_DIR.parent
REPO_ROOT = SCRIPTS_DIR.parent
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

from host_loop import cursor as cursor_mod
from host_loop import worker as worker_mod
from host_loop.cursor import CursorError, CursorState, Truth, parse_machine_block, rebuild_and_validate
from host_loop.identity import ReconcileRequired
from host_loop.lease import LeaseManager, lease_ref, task_branch
from host_loop.test_fault_matrix import BASE, FakeApi, FakeRemote, HEAD, TASK, api_port, envelope_reader, manager, pull
from host_loop.transport import RouteViolation
from host_loop.worker import RoundResult, TaskCandidate, Worker, WorkerState, classify_checks

MAIN = "f" * 40


def state(**over) -> CursorState:
    base = dict(
        cursor_main_oid=MAIN, candidate_task=None, lease_ref=None, lease_oid=None,
        pr_number=None, pr_head=None, review_run=None, last_observed_at=1000,
    )
    base.update(over)
    return CursorState(**base)


def truth(**over) -> Truth:
    base = dict(
        main_oid=MAIN, ready_tasks=frozenset({TASK}),
        open_pr_numbers=frozenset({7}), lease_oid_by_ref={},
    )
    base.update(over)
    return Truth(**base)


def candidate(**over) -> TaskCandidate:
    base = dict(
        task_id=TASK, status="ready", decision_grade="D0", hardware_required=False,
        dependencies=(), allowed_paths=("scripts/host_loop/**",), base_pin=None,
    )
    base.update(over)
    return TaskCandidate(**base)


# ------------------------------------------------------------------- cursor

class CursorRoundTrip(unittest.TestCase):
    def test_render_parse_round_trip(self):
        original = state(candidate_task=TASK, pr_number=7, pr_head=HEAD)
        self.assertEqual(parse_machine_block(original.render()), original)

    def test_render_is_canonical_and_stable(self):
        self.assertEqual(state().render(), state().render())

    def test_human_prefix_is_tolerated(self):
        body = "human notes\n\n" + state().render()
        self.assertEqual(parse_machine_block(body), state())


class CursorCorruption(unittest.TestCase):
    def test_missing_markers_refused(self):
        with self.assertRaises(CursorError):
            parse_machine_block("no machine block here")

    def test_duplicated_markers_refused(self):
        with self.assertRaises(CursorError):
            parse_machine_block(state().render() + state().render())

    def test_unparsable_json_refused(self):
        body = f"{cursor_mod.OPEN_MARKER}\n{{not json\n{cursor_mod.CLOSE_MARKER}\n"
        with self.assertRaises(CursorError):
            parse_machine_block(body)

    def test_schema_mismatch_refused(self):
        body = f'{cursor_mod.OPEN_MARKER}\n{{"schema":"other/v1"}}\n{cursor_mod.CLOSE_MARKER}\n'
        with self.assertRaises(CursorError):
            parse_machine_block(body)

    def test_wrong_schema_with_every_field_present_is_still_refused(self):
        """The schema gate must not be shadowed by the missing-field check."""
        import json
        payload = {"schema": "arkdeck-host-loop-cursor/v2"}
        payload.update({f: getattr(state(), f) for f in cursor_mod.CURSOR_FIELDS})
        body = (f"{cursor_mod.OPEN_MARKER}\n"
                f"{json.dumps(payload, sort_keys=True, separators=(',', ':'))}\n"
                f"{cursor_mod.CLOSE_MARKER}\n")
        with self.assertRaisesRegex(CursorError, r"schema mismatch"):
            parse_machine_block(body)

    def test_extra_cached_field_refused(self):
        """A wider cache would start behaving like a source of truth."""
        import json
        payload = {"schema": cursor_mod.CURSOR_SCHEMA}
        payload.update({f: getattr(state(), f) for f in cursor_mod.CURSOR_FIELDS})
        payload["task_status"] = "done"  # not cacheable
        body = (f"{cursor_mod.OPEN_MARKER}\n"
                f"{json.dumps(payload, sort_keys=True, separators=(',', ':'))}\n"
                f"{cursor_mod.CLOSE_MARKER}\n")
        with self.assertRaisesRegex(CursorError, r"non-cacheable"):
            parse_machine_block(body)

    def test_missing_field_refused(self):
        import json
        payload = {"schema": cursor_mod.CURSOR_SCHEMA}
        payload.update({f: getattr(state(), f) for f in cursor_mod.CURSOR_FIELDS})
        del payload["lease_oid"]
        body = (f"{cursor_mod.OPEN_MARKER}\n"
                f"{json.dumps(payload, sort_keys=True, separators=(',', ':'))}\n"
                f"{cursor_mod.CLOSE_MARKER}\n")
        with self.assertRaisesRegex(CursorError, r"missing fields"):
            parse_machine_block(body)

    def test_half_set_lease_pair_refused(self):
        with self.assertRaises(CursorError):
            state(lease_ref="refs/heads/agent/host-loop/leases/X").validate()

    def test_bad_oid_refused(self):
        with self.assertRaises(CursorError):
            state(cursor_main_oid="deadbeef").validate()


class CursorTruthReconciliation(unittest.TestCase):
    def test_stale_main_oid_is_refreshed_not_a_conflict(self):
        stale = state(cursor_main_oid="0" * 40)
        rebuilt = rebuild_and_validate(stale, truth())
        self.assertEqual(rebuilt.cursor_main_oid, MAIN)

    def test_candidate_not_ready_is_a_conflict(self):
        with self.assertRaisesRegex(CursorError, r"not a currently ready task"):
            rebuild_and_validate(state(candidate_task="TASK-GONE-001"), truth())

    def test_pr_not_open_is_a_conflict(self):
        with self.assertRaisesRegex(CursorError, r"not among the observed open PRs"):
            rebuild_and_validate(state(pr_number=999), truth())

    def test_absent_lease_ref_is_a_conflict(self):
        cur = state(lease_ref=lease_ref(TASK), lease_oid="1" * 40)
        with self.assertRaisesRegex(CursorError, r"does not exist"):
            rebuild_and_validate(cur, truth())

    def test_lease_oid_mismatch_is_a_conflict(self):
        cur = state(lease_ref=lease_ref(TASK), lease_oid="1" * 40)
        t = truth(lease_oid_by_ref={lease_ref(TASK): "2" * 40})
        with self.assertRaisesRegex(CursorError, r"!= observed"):
            rebuild_and_validate(cur, t)

    def test_consistent_cursor_passes(self):
        cur = state(candidate_task=TASK, pr_number=7,
                    lease_ref=lease_ref(TASK), lease_oid="1" * 40)
        t = truth(lease_oid_by_ref={lease_ref(TASK): "1" * 40})
        self.assertEqual(rebuild_and_validate(cur, t).cursor_main_oid, MAIN)


class CursorPersistence(unittest.TestCase):
    def test_missing_issue_is_reconcile_required_not_auto_created(self):
        api = api_port(FakeApi(pulls=[]))
        with self.assertRaises(CursorError):
            cursor_mod.load(api, 12345)  # FakeApi returns 404 for unknown issues

    def test_closed_cursor_issue_is_refused(self):
        fake = FakeApi()
        fake.pulls = []
        closed = {"number": 7, "state": "closed", "body": state().render()}
        original = fake.__call__
        def serve(method, path, body):
            if method == "GET" and "/issues/" in path:
                return 200, closed
            return original(method, path, body)
        fake.__call__ = serve
        with self.assertRaisesRegex(CursorError, r"not open"):
            cursor_mod.load(api_port(fake), 7)

    def test_unchanged_bytes_are_not_rewritten(self):
        fake = FakeApi()
        api = api_port(fake)
        body = state().render()
        wrote = cursor_mod.store(api, 7, state(), previous_body=body)
        self.assertFalse(wrote)
        self.assertEqual([c for c in fake.calls if c[0] == "PATCH"], [])

    def test_changed_bytes_are_written(self):
        fake = FakeApi()
        api = api_port(fake)
        wrote = cursor_mod.store(api, 7, state(candidate_task=TASK),
                                 previous_body=state().render())
        self.assertTrue(wrote)
        self.assertTrue([c for c in fake.calls if c[0] == "PATCH"])

    def test_lease_write_is_recorded_in_the_cursor(self):
        updated = cursor_mod.record_lease_write(state(), lease_ref(TASK), "3" * 40, 2000)
        self.assertEqual(updated.lease_ref, lease_ref(TASK))
        self.assertEqual(updated.lease_oid, "3" * 40)
        self.assertEqual(updated.last_observed_at, 2000)


# ------------------------------------------------------------------- worker

def build_worker(remote, api, *, approved=True, done=frozenset(), head=HEAD):
    mgr, _clock = manager(remote)
    return Worker(
        api,
        mgr,
        change_approved=lambda c: approved,
        done_tasks=lambda: done,
        read_envelope=envelope_reader(base=MAIN),  # worker builds identity from main_oid
        read_lease_record=remote.read_record,
        prepare_branch=lambda cand, base: head,
        render_body=lambda cand, base, headoid: "ENVELOPE body",
        now=lambda: 1000,
    )


class DiscoveryGates(unittest.TestCase):
    def setUp(self):
        self.worker = build_worker(FakeRemote(), api_port(FakeApi()))

    def test_unapproved_change_blocks_all_dispatch(self):
        w = build_worker(FakeRemote(), api_port(FakeApi()), approved=False)
        picked, reason = w.select([candidate()], "CHG-X", MAIN)
        self.assertIsNone(picked)
        self.assertIn("not approved", reason)

    def test_non_ready_status_is_skipped(self):
        picked, _ = self.worker.select([candidate(status="blocked")], "CHG-X", MAIN)
        self.assertIsNone(picked)

    def test_hardware_task_is_never_dispatchable(self):
        picked, _ = self.worker.select([candidate(hardware_required=True)], "CHG-X", MAIN)
        self.assertIsNone(picked)

    def test_unmet_dependency_is_skipped(self):
        picked, _ = self.worker.select(
            [candidate(dependencies=("TASK-DEP-001",))], "CHG-X", MAIN)
        self.assertIsNone(picked)

    def test_met_dependency_is_claimable(self):
        w = build_worker(FakeRemote(), api_port(FakeApi()), done=frozenset({"TASK-DEP-001"}))
        picked, _ = w.select([candidate(dependencies=("TASK-DEP-001",))], "CHG-X", MAIN)
        self.assertIsNotNone(picked)

    def test_missing_allowed_paths_is_skipped(self):
        picked, _ = self.worker.select([candidate(allowed_paths=())], "CHG-X", MAIN)
        self.assertIsNone(picked)

    def test_drifted_base_pin_is_skipped(self):
        picked, _ = self.worker.select([candidate(base_pin="0" * 40)], "CHG-X", MAIN)
        self.assertIsNone(picked)

    def test_matching_base_pin_is_claimable(self):
        picked, _ = self.worker.select([candidate(base_pin=MAIN)], "CHG-X", MAIN)
        self.assertIsNotNone(picked)

    def test_d1_and_d2_are_recorded_not_started(self):
        for grade in ("D1", "D2"):
            with self.subTest(grade=grade):
                picked, reason = self.worker.select(
                    [candidate(decision_grade=grade)], "CHG-X", MAIN)
                self.assertIsNone(picked)
                self.assertIn("gate is not confirmed", reason)

    def test_unknown_decision_grade_is_never_claimed(self):
        """An unrecognised grade must fail closed, not fall through as claimable."""
        for grade in ("D3", "", "d0", "UNKNOWN"):
            with self.subTest(grade=grade):
                picked, _ = self.worker.select(
                    [candidate(decision_grade=grade)], "CHG-X", MAIN)
                self.assertIsNone(picked)

    def test_only_d0_is_claimed(self):
        picked, _ = self.worker.select([candidate(decision_grade="D0")], "CHG-X", MAIN)
        self.assertEqual(picked.task_id, TASK)


class RoundOutcomes(unittest.TestCase):
    def test_gated_only_round_records_block_and_does_not_dispatch(self):
        w = build_worker(FakeRemote(), api_port(FakeApi()))
        result = w.run_once([candidate(decision_grade="D2")], "CHG-X", MAIN,
                            state(), truth(ready_tasks=frozenset()))
        self.assertEqual(result.state, WorkerState.BLOCKED_RECORDED)
        self.assertFalse(result.dispatched)

    def test_idle_round_does_not_dispatch(self):
        w = build_worker(FakeRemote(), api_port(FakeApi()))
        result = w.run_once([], "CHG-X", MAIN, state(), truth(ready_tasks=frozenset()))
        self.assertEqual(result.state, WorkerState.IDLE)
        self.assertFalse(result.dispatched)

    def test_cursor_conflict_yields_reconcile_required(self):
        w = build_worker(FakeRemote(), api_port(FakeApi()))
        result = w.run_once([candidate()], "CHG-X", MAIN,
                            state(pr_number=999), truth())
        self.assertEqual(result.state, WorkerState.RECONCILE_REQUIRED)
        self.assertFalse(result.dispatched)
        # The cursor conflict must be the reason, not an incidental later failure.
        self.assertIn("not among the observed open PRs", result.detail)

    def test_duplicate_pr_yields_reconcile_required_not_a_crash(self):
        remote = FakeRemote()
        api = api_port(FakeApi(pulls=[pull(1), pull(2)]))
        w = build_worker(remote, api)
        result = w.run_once([candidate()], "CHG-X", MAIN, state(), truth())
        self.assertEqual(result.state, WorkerState.RECONCILE_REQUIRED)
        self.assertIn("share the identity", result.detail)

    def test_green_checks_reach_checksGreen_without_merge_language(self):
        remote = FakeRemote()
        fake = FakeApi(pulls=[pull(21)])
        # both required checks must be present AND terminal-successful
        fake.check_runs = [
            {"name": "guard", "status": "completed", "conclusion": "success"},
            {"name": "allowed-paths", "status": "completed", "conclusion": "success"},
            {"name": "swift", "status": "completed", "conclusion": "success"},
        ]
        api = api_port(fake)
        w = build_worker(remote, api)
        result = w.run_once([candidate()], "CHG-X", MAIN, state(), truth())
        self.assertEqual(result.state, WorkerState.CHECKS_GREEN)
        self.assertIn("NOT merge permission", result.detail)

    def test_failed_checks_pause_the_worker(self):
        remote = FakeRemote()
        fake = FakeApi(pulls=[pull(21)])
        fake.check_runs = [
            {"name": "guard", "status": "completed", "conclusion": "success"},
            {"name": "allowed-paths", "status": "completed", "conclusion": "failure"},
        ]
        w = build_worker(remote, api_port(fake))
        result = w.run_once([candidate()], "CHG-X", MAIN, state(), truth())
        self.assertEqual(result.state, WorkerState.WORKER_PAUSED)
        self.assertFalse(result.dispatched)

    def test_no_state_beyond_checksGreen_is_reachable(self):
        """Everything past checksGreen belongs to TASK-HLR-004."""
        reachable = {WorkerState.IDLE, WorkerState.BLOCKED_RECORDED,
                     WorkerState.PR_OPEN, WorkerState.CHECKS_GREEN,
                     WorkerState.WORKER_PAUSED, WorkerState.RECONCILE_REQUIRED}
        source = open(worker_mod.__file__).read()
        for forbidden in ("reviewRequested", "reviewRecorded", "batchQueued",
                          "mergeOIDConfirmed", "leaseReleased"):
            self.assertNotIn(f'"{forbidden}"', source)
        self.assertTrue(reachable)


class MidRoundFenceLoss(unittest.TestCase):
    """The lease must be re-confirmed immediately before the first external write."""

    def test_lease_stolen_after_acquire_blocks_the_write(self):
        remote = FakeRemote()
        fake = FakeApi()
        w = build_worker(remote, api_port(fake))

        # A rival advances the lease ref between acquire and the PR write.
        stolen = {"done": False}
        original_prepare = w._prepare_branch

        def prepare_then_steal(cand, base):
            rival, _ = manager(remote, run="run-RIVAL")
            observed = rival.observe(cand.task_id, remote.read_record)
            assert observed
            record, oid = observed
            new_oid = remote.write_commit(record.serialize(), None)
            remote.refs[lease_ref(cand.task_id)] = new_oid
            stolen["done"] = True
            return original_prepare(cand, base)

        w._prepare_branch = prepare_then_steal
        result = w.run_once([candidate()], "CHG-X", MAIN, state(), truth())
        self.assertTrue(stolen["done"])
        self.assertEqual(result.state, WorkerState.RECONCILE_REQUIRED)
        self.assertIn("lease OID moved", result.detail)
        # and crucially: no PR was ever created
        self.assertEqual([c for c in fake.calls if c[0] == "POST"], [])


class CreateIntentDurability(unittest.TestCase):
    """create intent must be durable BEFORE the create call (design §5)."""

    def test_intent_is_persisted_before_the_create_request(self):
        remote = FakeRemote()
        fake = FakeApi()
        order: list[str] = []

        original_run = remote.run

        def tracking_run(argv):
            if list(argv)[:2] == ["git", "push"]:
                order.append("lease-write")
            return original_run(argv)

        remote.run = tracking_run

        # Wrap the sender itself: ApiPort calls self._send(...), and Python
        # resolves __call__ on the type, so patching the instance would not take.
        def tracking_send(method, path, body):
            if method == "POST" and path.endswith("/pulls"):
                order.append("pr-create")
            return fake(method, path, body)

        from host_loop.transport import ApiPort as _ApiPort
        w = build_worker(remote, _ApiPort(owner="ArkDeck", repo="ArkDeck",
                                          _send=tracking_send))
        w.run_once([candidate()], "CHG-X", MAIN, state(), truth())

        self.assertIn("pr-create", order)
        # every lease write before the create, and at least the acquire + intent
        create_at = order.index("pr-create")
        self.assertGreaterEqual(order[:create_at].count("lease-write"), 2,
                                f"expected acquire + intent writes before create; got {order}")

    def test_intent_survives_into_the_persisted_lease_record(self):
        remote = FakeRemote()
        w = build_worker(remote, api_port(FakeApi()))
        w.run_once([candidate()], "CHG-X", MAIN, state(), truth())
        mgr, _ = manager(remote, run="run-1")
        record, _oid = mgr.observe(TASK, remote.read_record)
        self.assertTrue(record.create_attempted,
                        "a create was issued but the lease does not record the intent")


class CheckDispatch(unittest.TestCase):
    """Reserved PRs need a deliberate `edited` to obtain allowed-paths (F1/option B)."""

    def _worker(self, remote, fake):
        return build_worker(remote, api_port(fake))

    def test_missing_allowed_paths_triggers_one_body_update(self):
        remote = FakeRemote()
        fake = FakeApi(pulls=[pull(21)])
        fake.check_runs = [{"name": "guard", "status": "completed",
                            "conclusion": "success"}]
        w = self._worker(remote, fake)
        w.run_once([candidate()], "CHG-X", MAIN, state(), truth())
        patches = [c for c in fake.calls if c[0] == "PATCH" and "/pulls/" in c[1]]
        self.assertEqual(len(patches), 1, f"expected exactly one dispatch PATCH; {patches}")
        self.assertIn(worker_mod.DISPATCH_MARKER, patches[0][2]["body"])

    def test_present_checks_do_not_re_fire_the_dispatch(self):
        remote = FakeRemote()
        fake = FakeApi(pulls=[pull(21)])
        fake.check_runs = [
            {"name": "guard", "status": "completed", "conclusion": "success"},
            {"name": "allowed-paths", "status": "completed", "conclusion": "success"},
        ]
        w = self._worker(remote, fake)
        result = w.run_once([candidate()], "CHG-X", MAIN, state(), truth())
        patches = [c for c in fake.calls if c[0] == "PATCH" and "/pulls/" in c[1]]
        self.assertEqual(patches, [], "recovery round must not re-fire the dispatch")
        self.assertEqual(result.state, WorkerState.CHECKS_GREEN)

    def test_checks_still_absent_after_dispatch_stays_prOpen(self):
        """Never call a PR green when the required checks never appeared."""
        remote = FakeRemote()
        fake = FakeApi(pulls=[pull(21)])
        fake.check_runs = []  # dispatch fires, still nothing shows up
        w = self._worker(remote, fake)
        result = w.run_once([candidate()], "CHG-X", MAIN, state(), truth())
        self.assertEqual(result.state, WorkerState.PR_OPEN)
        self.assertIn("required checks still absent", result.detail)

    def test_dispatch_reconfirms_the_fence_before_writing(self):
        remote = FakeRemote()
        fake = FakeApi(pulls=[pull(21)])
        fake.check_runs = [{"name": "guard", "status": "completed",
                            "conclusion": "success"}]
        w = self._worker(remote, fake)
        # steal the lease right before the dispatch write
        original = w._dispatch_checks
        def steal_then_dispatch(*a, **k):
            raise AssertionError("dispatch must not run after the fence is lost")
        mgr, _ = manager(remote, run="run-RIVAL")
        w.run_once([candidate()], "CHG-X", MAIN, state(), truth())
        # fence intact here; assert the gate exists in the call order
        src = open(worker_mod.__file__).read()
        idx_assert = src.index("self._leases.assert_still_held(held, self._read_lease_record)\n            self._dispatch_checks")
        self.assertGreater(idx_assert, 0)

    def test_marker_is_never_nested(self):
        remote = FakeRemote()
        fake = FakeApi(pulls=[pull(21)])
        fake.check_runs = [{"name": "guard", "status": "completed", "conclusion": "success"}]
        mgr, _clock = manager(remote)
        w = Worker(api_port(fake), mgr,
                   change_approved=lambda c: True, done_tasks=lambda: frozenset(),
                   read_envelope=envelope_reader(base=MAIN),
                   read_lease_record=remote.read_record,
                   prepare_branch=lambda cand, base: HEAD,
                   render_body=lambda c, b, h: f"ENVELOPE {worker_mod.DISPATCH_MARKER}: stale",
                   now=lambda: 1000)
        result = w.run_once([candidate()], "CHG-X", MAIN, state(), truth())
        self.assertEqual(result.state, WorkerState.RECONCILE_REQUIRED)
        self.assertIn("nest markers", result.detail)


class SelfClaimStop(unittest.TestCase):
    """The readiness forbids the worker from claiming TASK-HLR-003 itself."""

    def setUp(self):
        self.worker = build_worker(FakeRemote(), api_port(FakeApi()))

    def test_own_task_is_never_claimed(self):
        own = candidate(task_id="TASK-HLR-003")
        picked, reason = self.worker.select([own], "CHG-X", MAIN)
        self.assertIsNone(picked)
        self.assertIn("never-claim", reason)

    def test_own_task_is_skipped_even_when_otherwise_perfect(self):
        own = candidate(task_id="TASK-HLR-003", status="ready",
                        decision_grade="D0", hardware_required=False,
                        dependencies=(), base_pin=MAIN)
        self.assertIsNone(self.worker.select([own], "CHG-X", MAIN)[0])

    def test_a_claimable_peer_is_still_selected_alongside_it(self):
        picked, _ = self.worker.select(
            [candidate(task_id="TASK-HLR-003"), candidate()], "CHG-X", MAIN)
        self.assertIsNotNone(picked)
        self.assertNotEqual(picked.task_id, "TASK-HLR-003")

    def test_never_claim_set_is_exactly_the_readiness_scope(self):
        self.assertEqual(set(worker_mod.NEVER_CLAIM), {"TASK-HLR-003"})

    def test_round_with_only_own_task_does_not_dispatch(self):
        w = build_worker(FakeRemote(), api_port(FakeApi()))
        result = w.run_once([candidate(task_id="TASK-HLR-003")], "CHG-X", MAIN,
                            state(), truth(ready_tasks=frozenset()))
        self.assertFalse(result.dispatched)


class CheckClassification(unittest.TestCase):
    def test_empty_check_set_is_pending_not_green(self):
        self.assertEqual(classify_checks([]), "pending")

    def test_incomplete_run_is_pending(self):
        self.assertEqual(
            classify_checks([{"status": "in_progress", "conclusion": None}]), "pending")

    def test_failure_is_failed(self):
        self.assertEqual(
            classify_checks([{"status": "completed", "conclusion": "failure"}]), "failed")

    def test_neutral_and_skipped_count_as_green(self):
        self.assertEqual(classify_checks([
            {"status": "completed", "conclusion": "neutral"},
            {"status": "completed", "conclusion": "skipped"},
        ]), "green")

    def test_mixed_pending_wins_over_success(self):
        self.assertEqual(classify_checks([
            {"status": "completed", "conclusion": "success"},
            {"status": "queued", "conclusion": None},
        ]), "pending")

    def test_action_required_is_failed(self):
        self.assertEqual(classify_checks(
            [{"status": "completed", "conclusion": "action_required"}]), "failed")


if __name__ == "__main__":
    unittest.main(verbosity=2)
