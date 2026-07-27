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
from host_loop.lease import LeaseManager, LeaseRecord, lease_ref, task_branch
from host_loop.test_fault_matrix import BASE, FakeApi, FakeRemote, HEAD, TASK, api_port, envelope_reader, manager, pull
from host_loop.transport import RefPort, RouteViolation
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

    def test_render_is_canonical_across_construction_order(self):
        """Two states built differently but equal must render identical bytes.

        Comparing one pure call with another of itself asserted nothing. This
        pins the actual canonicality property: sorted keys, compact separators,
        and no dependence on how the object was assembled.
        """
        import json
        from dataclasses import replace as dc_replace

        direct = state(candidate_task=TASK, pr_number=7, pr_head=HEAD)
        stepwise = dc_replace(
            dc_replace(dc_replace(state(), pr_head=HEAD), pr_number=7),
            candidate_task=TASK)
        self.assertEqual(direct, stepwise)
        self.assertEqual(direct.render(), stepwise.render())

        payload = direct.render().split(cursor_mod.OPEN_MARKER)[1]
        payload = payload.split(cursor_mod.CLOSE_MARKER)[0].strip()
        self.assertEqual(
            payload,
            json.dumps(json.loads(payload), sort_keys=True, separators=(",", ":")),
            "the machine block must be canonical JSON")
        self.assertNotIn(", ", payload, "compact separators only")

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

    def test_candidate_not_ready_is_reconciled_not_fatal(self):
        """Staleness in a cache is not corruption.

        The previous version asserted the wedge as the contract: it required a
        stale candidate to abort the round, and since reconciliation runs before
        any cursor write, the cache could never catch up.
        """
        out = rebuild_and_validate(state(candidate_task="TASK-GONE-001"), truth())
        self.assertIsNone(out.candidate_task)

    def test_pr_not_open_is_reconciled_not_fatal(self):
        out = rebuild_and_validate(state(pr_number=999, pr_head=HEAD), truth())
        self.assertIsNone(out.pr_number)
        self.assertIsNone(out.pr_head)

    def test_an_absent_lease_ref_is_cleared_not_fatal(self):
        cur = state(lease_ref=lease_ref(TASK), lease_oid="1" * 40)
        out = rebuild_and_validate(cur, truth())
        self.assertIsNone(out.lease_ref)
        self.assertIsNone(out.lease_oid)

    def test_a_lease_oid_behind_the_ref_is_refreshed_not_fatal(self):
        """This is the shape one dropped cursor write leaves behind.

        A transient 502 on a single cursor PATCH, or the process dying between a
        ref write and its matching cursor write, used to wedge the task for ever.
        """
        cur = state(lease_ref=lease_ref(TASK), lease_oid="1" * 40)
        t = truth(lease_oid_by_ref={lease_ref(TASK): "2" * 40})
        self.assertEqual(rebuild_and_validate(cur, t).lease_oid, "2" * 40)

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
        """A closed Issue must never be adopted as the cursor.

        This test used to assign `serve` to `fake.__call__` as an INSTANCE
        attribute. Python resolves `__call__` on the type, so `serve` was never
        invoked: the assertion passed only because FakeApi had no
        `GET /issues/{n}` route at all and its `{}` fallthrough happened to fail
        the same "not open" check. It asserted nothing about a closed Issue.
        TASK-DEC-009 added the route, which exposed it. It now stages the closed
        payload through the fake's own surface and proves the fake was actually
        consulted.
        """
        fake = FakeApi()
        fake.pulls = []
        fake.issues[7] = {"number": 7, "state": "closed", "title": "",
                          "body": state().render(), "pull_request": None}
        with self.assertRaisesRegex(CursorError, r"not open"):
            cursor_mod.load(api_port(fake), 7)
        lookups = [call for call in fake.calls
                   if call[0] == "GET" and "/issues/" in call[1]]
        self.assertEqual(len(lookups), 1, "the Issue lookup never happened")

    def test_the_staged_issue_is_what_load_actually_reads(self):
        """Positive control for the test above, and the reason it is trustworthy.

        Counting the lookup is not enough: FakeApi records every call before it
        routes, so the count is identical whether the staged payload was served
        or the `{}` fallthrough was. This case fails outright unless the staged
        Issue really reaches load(), so the refusal above is a statement about a
        CLOSED Issue rather than about an empty one.
        """
        fake = FakeApi()
        fake.pulls = []
        fake.issues[7] = {"number": 7, "state": "open", "title": "",
                          "body": state().render(), "pull_request": None}
        loaded, issue = cursor_mod.load(api_port(fake), 7)
        self.assertEqual(issue["state"], "open")
        self.assertEqual(loaded, state())

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
        wrote = cursor_mod.store(api.bound_to_issue(7), 7, state(candidate_task=TASK),
                                 previous_body=state().render())
        self.assertTrue(wrote)
        self.assertTrue([c for c in fake.calls if c[0] == "PATCH"])

    def test_a_malformed_lease_oid_cannot_enter_the_cursor(self):
        """Re-pointed from record_lease_write, which was dead at its call site.

        The property is worth keeping; asserting it against a function nothing
        calls is not. record_round is the one the round actually goes through.
        """
        for bad in ("", "deadbeef", "A" * 40, "g" * 40, "1" * 39, "1" * 41):
            with self.subTest(bad=bad):
                with self.assertRaises(CursorError):
                    cursor_mod.record_round(
                        state(), main_oid=MAIN, candidate_task=TASK,
                        lease_ref_name=lease_ref(TASK), lease_oid=bad,
                        pr_number=None, pr_head=None, observed_at=2000)

    def test_a_lease_write_is_recorded_in_the_cursor(self):
        updated = cursor_mod.record_round(
            state(), main_oid=MAIN, candidate_task=TASK,
            lease_ref_name=lease_ref(TASK), lease_oid="3" * 40,
            pr_number=None, pr_head=None, observed_at=2000)
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
        picked, _outcome, reason = w.select([candidate()], "CHG-X", MAIN)
        self.assertIsNone(picked)
        self.assertIn("not approved", reason)

    def test_non_ready_status_is_skipped(self):
        picked, _outcome, _reason = self.worker.select([candidate(status="blocked")], "CHG-X", MAIN)
        self.assertIsNone(picked)

    def test_hardware_task_is_never_dispatchable(self):
        picked, _outcome, _reason = self.worker.select([candidate(hardware_required=True)], "CHG-X", MAIN)
        self.assertIsNone(picked)

    def test_unmet_dependency_is_skipped(self):
        picked, _outcome, _reason = self.worker.select(
            [candidate(dependencies=("TASK-DEP-001",))], "CHG-X", MAIN)
        self.assertIsNone(picked)

    def test_met_dependency_is_claimable(self):
        w = build_worker(FakeRemote(), api_port(FakeApi()), done=frozenset({"TASK-DEP-001"}))
        picked, _outcome, _reason = w.select([candidate(dependencies=("TASK-DEP-001",))], "CHG-X", MAIN)
        self.assertIsNotNone(picked)

    def test_missing_allowed_paths_is_skipped(self):
        picked, _outcome, _reason = self.worker.select([candidate(allowed_paths=())], "CHG-X", MAIN)
        self.assertIsNone(picked)

    def test_drifted_base_pin_is_skipped(self):
        picked, _outcome, _reason = self.worker.select([candidate(base_pin="0" * 40)], "CHG-X", MAIN)
        self.assertIsNone(picked)

    def test_matching_base_pin_is_claimable(self):
        picked, _outcome, _reason = self.worker.select([candidate(base_pin=MAIN)], "CHG-X", MAIN)
        self.assertIsNotNone(picked)

    def test_d1_and_d2_are_recorded_not_started(self):
        for grade in ("D1", "D2"):
            with self.subTest(grade=grade):
                picked, _outcome, reason = self.worker.select(
                    [candidate(decision_grade=grade)], "CHG-X", MAIN)
                self.assertIsNone(picked)
                self.assertIn("gate is not confirmed", reason)

    def test_unknown_decision_grade_is_never_claimed(self):
        """An unrecognised grade must fail closed, not fall through as claimable."""
        for grade in ("D3", "", "d0", "UNKNOWN"):
            with self.subTest(grade=grade):
                picked, _outcome, _reason = self.worker.select(
                    [candidate(decision_grade=grade)], "CHG-X", MAIN)
                self.assertIsNone(picked)

    def test_only_d0_is_claimed(self):
        picked, _outcome, _reason = self.worker.select([candidate(decision_grade="D0")], "CHG-X", MAIN)
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

    def test_a_stale_cursor_does_not_stop_the_round(self):
        """The cursor must never be why a round cannot proceed."""
        w = build_worker(FakeRemote(), api_port(FakeApi(pulls=[pull(21)])))
        result = w.run_once([candidate()], "CHG-X", MAIN,
                            state(pr_number=999, pr_head=HEAD), truth())
        self.assertNotEqual(result.state, WorkerState.RECONCILE_REQUIRED,
                            f"stale cache must reconcile, not abort: {result.detail}")

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

    def test_observed_state_set_matches_the_hlr003_scope(self):
        """Drive every branch and compare the observed state set.

        Replaces a source grep plus assertTrue on a literal set, which asserted
        nothing at all.
        """
        observed = set()
        w = build_worker(FakeRemote(), api_port(FakeApi()))
        observed.add(w.run_once([], "CHG-X", MAIN, state(),
                                truth(ready_tasks=frozenset())).state)
        w = build_worker(FakeRemote(), api_port(FakeApi()))
        observed.add(w.run_once([candidate(decision_grade="D2")], "CHG-X", MAIN,
                                state(), truth(ready_tasks=frozenset())).state)
        w = build_worker(FakeRemote(), api_port(FakeApi()))
        observed.add(w.run_once([candidate()], "CHG-X", MAIN,
                                state(pr_number=999), truth()).state)
        w = build_worker(FakeRemote(), api_port(FakeApi(pulls=[pull(21)])))
        observed.add(w.run_once([candidate()], "CHG-X", MAIN, state(), truth()).state)
        fake = FakeApi(pulls=[pull(21)])
        fake.check_runs = [{"name": "guard", "status": "completed", "conclusion": "success"},
                           {"name": "allowed-paths", "status": "completed",
                            "conclusion": "failure"}]
        observed.add(build_worker(FakeRemote(), api_port(fake)).run_once(
            [candidate()], "CHG-X", MAIN, state(), truth()).state)
        fake = FakeApi(pulls=[pull(21)])
        fake.check_runs = [{"name": "guard", "status": "completed", "conclusion": "success"},
                           {"name": "allowed-paths", "status": "completed",
                            "conclusion": "success"}]
        observed.add(build_worker(FakeRemote(), api_port(fake)).run_once(
            [candidate()], "CHG-X", MAIN, state(), truth()).state)
        self.assertEqual(observed, {
            WorkerState.IDLE, WorkerState.BLOCKED_RECORDED,
            WorkerState.RECONCILE_REQUIRED, WorkerState.PR_OPEN,
            WorkerState.WORKER_PAUSED, WorkerState.CHECKS_GREEN})

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

    def test_executed_checks_do_not_re_fire_the_dispatch(self):
        """Required checks that have genuinely executed need no dispatch.

        Note the distinction the previous version missed: "present" is not
        "executed". A skipped run named allowed-paths is present and does NOT
        satisfy the gate; only a completed success does.
        """
        remote = FakeRemote()
        fake = FakeApi(pulls=[pull(21)])
        fake.check_runs = [
            {"name": "guard", "status": "completed", "conclusion": "success"},
            {"name": "allowed-paths", "status": "completed", "conclusion": "success"},
        ]
        w = self._worker(remote, fake)
        result = w.run_once([candidate()], "CHG-X", MAIN, state(), truth())
        patches = [c for c in fake.calls if c[0] == "PATCH" and "/pulls/" in c[1]]
        self.assertEqual(patches, [], "an executed-green head needs no dispatch")
        self.assertEqual(result.state, WorkerState.CHECKS_GREEN)

    def test_a_skipped_stub_still_triggers_exactly_one_dispatch(self):
        """The push run's skipped stub must not be mistaken for an executed check."""
        remote = FakeRemote()
        fake = FakeApi(pulls=[pull(21)])
        fake.check_runs = [
            {"name": "guard", "status": "completed", "conclusion": "success"},
            {"name": "allowed-paths", "status": "completed", "conclusion": "skipped"},
        ]
        first = self._worker(remote, fake).run_once(
            [candidate()], "CHG-X", MAIN, state(), truth())
        self.assertEqual(first.state, WorkerState.PR_OPEN)
        patches = [c for c in fake.calls if c[0] == "PATCH" and "/pulls/" in c[1]]
        self.assertEqual(len(patches), 1, "the edited run must be triggered once")
        # a later round, runs still queued: no second dispatch
        second = self._worker(remote, fake).run_once(
            [candidate()], "CHG-X", MAIN, state(),
            truth(lease_oid_by_ref=dict(remote.refs)))
        patches = [c for c in fake.calls if c[0] == "PATCH" and "/pulls/" in c[1]]
        self.assertEqual(len(patches), 1, f"no re-fire while runs queue: {second.detail}")

    def test_checks_still_absent_after_dispatch_stays_prOpen(self):
        """Never call a PR green when the required checks never appeared."""
        remote = FakeRemote()
        fake = FakeApi(pulls=[pull(21)])
        fake.check_runs = []  # dispatch fires, still nothing shows up
        w = self._worker(remote, fake)
        result = w.run_once([candidate()], "CHG-X", MAIN, state(), truth())
        self.assertEqual(result.state, WorkerState.PR_OPEN)
        self.assertIn("not yet executed successfully", result.detail)

    def test_dispatch_does_not_write_after_the_fence_is_lost(self):
        """Behavioural: steal the lease mid-round and assert zero PR writes.

        The previous version grepped worker.py for the gate's source text and
        asserted a non-zero string index, so it could not tell a deleted gate
        from a reformatted one.
        """
        remote = FakeRemote()
        fake = FakeApi(pulls=[pull(21)])
        fake.check_runs = [{"name": "guard", "status": "completed",
                            "conclusion": "success"}]
        w = self._worker(remote, fake)
        original_prepare = w._prepare_branch

        def prepare_then_steal(cand, base):
            observed = w._leases.observe(cand.task_id, remote.read_record)
            assert observed
            record, _oid = observed
            remote.refs[lease_ref(cand.task_id)] = remote.write_commit(
                record.serialize(), None)
            return original_prepare(cand, base)

        w._prepare_branch = prepare_then_steal
        result = w.run_once([candidate()], "CHG-X", MAIN, state(), truth())
        self.assertEqual(result.state, WorkerState.RECONCILE_REQUIRED)
        self.assertIn("lease OID moved", result.detail)
        writes = [c for c in fake.calls if c[0] in ("POST", "PATCH")]
        self.assertEqual(writes, [], f"no write may occur after fence loss; {writes}")

    def test_fence_is_reconfirmed_immediately_before_the_dispatch_write(self):
        """Steal the lease between the PR lookup and the dispatch.

        An earlier version of this test stole it during branch preparation, which
        the pre-lookup gate catches — so deleting the pre-dispatch gate went
        undetected. The steal now lands inside list_check_runs, which runs after
        the PR is resolved and immediately before the dispatch decision.
        """
        remote = FakeRemote()
        fake = FakeApi(pulls=[pull(21)])
        w = self._worker(remote, fake)
        stolen = {"done": False}
        original = fake.__class__.__call__

        def steal_on_checks(self_fake, method, path, body):
            if method == "GET" and "/check-runs" in path and not stolen["done"]:
                observed = w._leases.observe(TASK, remote.read_record)
                assert observed
                record, _oid = observed
                remote.refs[lease_ref(TASK)] = remote.write_commit(
                    record.serialize(), None)
                stolen["done"] = True
            return original(self_fake, method, path, body)

        fake.__class__.__call__ = steal_on_checks
        try:
            result = w.run_once([candidate()], "CHG-X", MAIN, state(), truth())
        finally:
            fake.__class__.__call__ = original
        self.assertTrue(stolen["done"], "the steal must have happened")
        self.assertEqual(result.state, WorkerState.RECONCILE_REQUIRED)
        patches = [c for c in fake.calls if c[0] == "PATCH" and "/pulls/" in c[1]]
        self.assertEqual(patches, [], "no dispatch write may follow a lost fence")

    def test_two_dispatches_in_the_same_second_render_distinct_bodies(self):
        """A second-granularity token collides, and GitHub emits no `edited`."""
        remote = FakeRemote()
        fake = FakeApi(pulls=[pull(21)])
        w = self._worker(remote, fake)
        bodies = set()
        for _ in range(2):
            token = w._dispatch_token()
            bodies.add(f"ENVELOPE\n{worker_mod.DISPATCH_MARKER}: {token}\n")
        self.assertEqual(len(bodies), 2,
                         "same-second dispatches must still change the bytes")

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
        picked, _outcome, reason = self.worker.select([own], "CHG-X", MAIN)
        self.assertIsNone(picked)
        self.assertIn("never-claim", reason)

    def test_own_task_is_skipped_even_when_otherwise_perfect(self):
        own = candidate(task_id="TASK-HLR-003", status="ready",
                        decision_grade="D0", hardware_required=False,
                        dependencies=(), base_pin=MAIN)
        self.assertIsNone(self.worker.select([own], "CHG-X", MAIN)[0])

    def test_a_claimable_peer_is_still_selected_alongside_it(self):
        picked, _outcome, _reason = self.worker.select(
            [candidate(task_id="TASK-HLR-003"), candidate()], "CHG-X", MAIN)
        self.assertIsNotNone(picked)
        self.assertNotEqual(picked.task_id, "TASK-HLR-003")

    def test_suffixed_and_denormalised_siblings_are_also_excluded(self):
        """Exact-string matching let TASK-HLR-003A through; the grammar admits it."""
        for variant in ("TASK-HLR-003", "TASK-HLR-003A", "TASK-HLR-003R",
                        "task-hlr-003", " TASK-HLR-003 "):
            with self.subTest(variant=variant):
                self.assertTrue(worker_mod.is_never_claim(variant))
        for other in ("TASK-HLR-004", "TASK-HLR-0031", "TASK-DEMO-001"):
            with self.subTest(other=other):
                self.assertFalse(worker_mod.is_never_claim(other))

    def test_a_never_claim_variant_is_skipped_by_discovery(self):
        picked, outcome, _ = self.worker.select(
            [candidate(task_id="TASK-HLR-003A")], "CHG-X", MAIN)
        self.assertIsNone(picked)
        self.assertEqual(outcome, worker_mod.SelectionOutcome.ONLY_NEVER_CLAIM_READY)

    def test_round_with_only_own_task_does_not_dispatch(self):
        w = build_worker(FakeRemote(), api_port(FakeApi()))
        result = w.run_once([candidate(task_id="TASK-HLR-003")], "CHG-X", MAIN,
                            state(), truth(ready_tasks=frozenset()))
        self.assertFalse(result.dispatched)


class OwnerIdentityIsSingleSourced(unittest.TestCase):
    """Worker must not carry its own copy of the lease identity."""

    def test_worker_has_no_owner_run_parameter(self):
        import inspect
        self.assertNotIn("owner_run",
                         inspect.signature(Worker.__init__).parameters,
                         "a second copy of the identity could silently disagree")

    def test_worker_identity_equals_the_lease_managers(self):
        remote = FakeRemote()
        for name in ("run-1", "host-loop/other", "whatever"):
            mgr = LeaseManager(RefPort(remote="origin", _run=remote.run),
                               owner_run=name, now=lambda: 1000,
                               commit_writer=remote.write_commit)
            w = Worker(api_port(FakeApi()), mgr, change_approved=lambda c: True,
                       done_tasks=lambda: frozenset(),
                       read_envelope=envelope_reader(base=MAIN),
                       read_lease_record=remote.read_record,
                       prepare_branch=lambda c, b: HEAD,
                       render_body=lambda c, b, h: "ENVELOPE", now=lambda: 1000)
            self.assertEqual(w._owner_run, name)

    def test_the_legacy_helper_now_progresses_across_rounds(self):
        """The helper 22 tests share used to deadlock at `idle` from round two."""
        remote = FakeRemote()
        fake = FakeApi(pulls=[pull(21)])
        cand = candidate()
        states = []
        for _ in range(3):
            w = build_worker(remote, api_port(fake))
            states.append(w.run_once([cand], "CHG-X", MAIN, state(),
                                     truth(lease_oid_by_ref=dict(remote.refs))).state)
        self.assertNotIn(WorkerState.IDLE, states,
                         f"a mismatched identity would idle forever: {states}")


class MultiRoundLifecycle(unittest.TestCase):
    """The runtime must actually progress across `--once` rounds (finding 3).

    The previous suite only ever ran one round and reached the adopt/takeover
    paths by calling functions directly, so it never saw that round two always
    collided with the lease ref round one had created.
    """

    def _rig(self):
        remote = FakeRemote()
        fake = FakeApi(pulls=[pull(21)])
        clock = {"t": 1000}
        mgr = LeaseManager(
            RefPort(remote="origin", _run=remote.run), owner_run="host-loop/worker",
            now=lambda: clock["t"], commit_writer=remote.write_commit, ttl_seconds=900)

        def build(**kw):
            return Worker(
                api_port(fake), mgr, change_approved=lambda c: True,
                done_tasks=lambda: frozenset(),
                read_envelope=envelope_reader(base=MAIN),
                read_lease_record=remote.read_record,
                prepare_branch=lambda c, b: HEAD,
                render_body=lambda c, b, h: "ENVELOPE",
                now=lambda: clock["t"], **kw)

        def tr():
            return Truth(main_oid=MAIN, ready_tasks=frozenset({TASK}),
                         open_pr_numbers=frozenset({21}),
                         lease_oid_by_ref=dict(remote.refs))
        return remote, fake, clock, mgr, build, tr

    def test_three_consecutive_rounds_progress(self):
        remote, fake, _clock, _mgr, build, tr = self._rig()
        r1 = build().run_once([candidate()], "CHG-X", MAIN, state(), tr())
        self.assertEqual(r1.state, WorkerState.PR_OPEN)
        r2 = build().run_once([candidate()], "CHG-X", MAIN, state(), tr())
        self.assertNotEqual(r2.state, WorkerState.RECONCILE_REQUIRED,
                            f"round two must not collide with its own lease: {r2.detail}")
        self.assertEqual(r2.state, WorkerState.PR_OPEN)
        fake.check_runs = [
            {"name": "guard", "status": "completed", "conclusion": "success"},
            {"name": "allowed-paths", "status": "completed", "conclusion": "success"}]
        r3 = build().run_once([candidate()], "CHG-X", MAIN, state(), tr())
        self.assertEqual(r3.state, WorkerState.CHECKS_GREEN)

    def test_dispatch_fires_once_across_rounds(self):
        _remote, fake, _clock, _mgr, build, tr = self._rig()
        for _ in range(3):
            build().run_once([candidate()], "CHG-X", MAIN, state(), tr())
        patches = [c for c in fake.calls if c[0] == "PATCH" and "/pulls/" in c[1]]
        self.assertEqual(len(patches), 1,
                         f"dispatch must not re-fire while runs queue; got {len(patches)}")

    def test_fence_increases_monotonically_across_rounds(self):
        remote, _fake, _clock, mgr, build, tr = self._rig()
        fences = []
        for _ in range(3):
            build().run_once([candidate()], "CHG-X", MAIN, state(), tr())
            fences.append(mgr.observe(TASK, remote.read_record)[0].fence)
        self.assertEqual(fences, sorted(set(fences)), f"fence must advance: {fences}")

    def test_lease_is_retained_while_the_pr_is_unmerged(self):
        remote, _fake, _clock, _mgr, build, tr = self._rig()
        build().run_once([candidate()], "CHG-X", MAIN, state(), tr())
        self.assertIn(lease_ref(TASK), remote.refs,
                      "design §4 releases the lease only after mergeOIDConfirmed")

    def test_a_live_foreign_lease_blocks_dispatch_without_stealing(self):
        remote, fake, clock, _mgr, build, tr = self._rig()
        rival = LeaseManager(RefPort(remote="origin", _run=remote.run),
                             owner_run="host-loop/rival", now=lambda: clock["t"],
                             commit_writer=remote.write_commit, ttl_seconds=900)
        rival.acquire(TASK, MAIN)
        before = dict(remote.refs)
        result = build().run_once([candidate()], "CHG-X", MAIN, state(), tr())
        self.assertEqual(result.state, WorkerState.IDLE)
        self.assertIn("live owner", result.detail)
        self.assertEqual(remote.refs, before, "must not touch a live foreign lease")
        self.assertEqual([c for c in fake.calls if c[0] in ("POST", "PATCH")], [])

    def test_an_expired_foreign_lease_is_taken_over(self):
        remote, _fake, clock, mgr, build, tr = self._rig()
        rival = LeaseManager(RefPort(remote="origin", _run=remote.run),
                             owner_run="host-loop/rival", now=lambda: clock["t"],
                             commit_writer=remote.write_commit, ttl_seconds=60)
        rival.acquire(TASK, MAIN)
        clock["t"] += 3600
        result = build().run_once([candidate()], "CHG-X", MAIN, state(), tr())
        self.assertNotEqual(result.state, WorkerState.IDLE)
        self.assertEqual(mgr.observe(TASK, remote.read_record)[0].owner_run,
                         "host-loop/worker")

    def test_a_stale_cursor_main_oid_is_refreshed_before_persisting(self):
        """The reconciled cursor must be the one written, not the input."""
        remote, fake, _clock, _mgr, build, tr = self._rig()
        stale = state(cursor_main_oid="0" * 40)
        build(cursor_issue=7, cursor_body="").run_once(
            [candidate()], "CHG-X", MAIN, stale, tr())
        issue_patches = [c for c in fake.calls if c[0] == "PATCH" and "/issues/" in c[1]]
        self.assertTrue(issue_patches)
        body = issue_patches[-1][2]["body"]
        self.assertIn(MAIN, body, "the refreshed main OID must be persisted")
        self.assertNotIn("0" * 40, body, "the stale OID must not survive")

    def test_an_unexpected_exception_becomes_reconcile_required(self):
        """A TypeError from a malformed payload must stop the lane, not crash."""
        remote, fake, _clock, _mgr, build, tr = self._rig()
        w = build()

        def exploding_prepare(cand, base):
            raise TypeError("simulated malformed payload")

        w._prepare_branch = exploding_prepare
        result = w.run_once([candidate()], "CHG-X", MAIN, state(), tr())
        self.assertEqual(result.state, WorkerState.RECONCILE_REQUIRED)
        self.assertIn("unexpected TypeError", result.detail)

    def test_cursor_is_written_back_with_the_lease_oid(self):
        remote, fake, _clock, _mgr, build, tr = self._rig()
        build(cursor_issue=7, cursor_body="").run_once(
            [candidate()], "CHG-X", MAIN, state(), tr())
        issue_patches = [c for c in fake.calls if c[0] == "PATCH" and "/issues/" in c[1]]
        self.assertTrue(issue_patches, "the cursor must be persisted, not read-only")
        body = issue_patches[-1][2]["body"]
        self.assertIn(remote.refs[lease_ref(TASK)], body)
        self.assertIn(TASK, body)


class AuditRegressions(unittest.TestCase):
    """Regressions for the four findings the unbound-guard audit confirmed."""

    def _rig(self, checks):
        remote = FakeRemote()
        fake = FakeApi(pulls=[pull(21)], check_runs=list(checks))
        clock = {"t": 1000}
        mgr = LeaseManager(RefPort(remote="origin", _run=remote.run),
                           owner_run="host-loop/worker", now=lambda: clock["t"],
                           commit_writer=remote.write_commit, ttl_seconds=900)
        build = lambda **kw: Worker(
            api_port(fake), mgr, change_approved=lambda c: True,
            done_tasks=lambda: frozenset(), read_envelope=envelope_reader(base=MAIN),
            read_lease_record=remote.read_record, prepare_branch=lambda c, b: HEAD,
            render_body=lambda c, b, h: "ENVELOPE", now=lambda: clock["t"], **kw)
        tr = lambda m=MAIN: Truth(main_oid=m, ready_tasks=frozenset({TASK}),
                                  open_pr_numbers=frozenset({21}),
                                  lease_oid_by_ref=dict(remote.refs))
        return remote, fake, clock, mgr, build, tr

    # --- A: status must be consulted, not just the conclusion ---------------
    def test_a_required_run_still_in_progress_is_pending(self):
        """Only a COMPLETED run can satisfy a required name.

        Dropping the status check leaves a conclusion-only test, which an
        in-flight run carrying a stale success conclusion would satisfy.
        """
        runs = [{"name": "guard", "status": "completed", "conclusion": "success"},
                {"name": "allowed-paths", "status": "in_progress",
                 "conclusion": "success"}]
        self.assertEqual(worker_mod.required_verdicts(runs)["allowed-paths"],
                         "pending")
        self.assertEqual(classify_checks(runs), "pending")

    def test_a_queued_required_run_is_pending_not_failed(self):
        runs = [{"name": "guard", "status": "queued", "conclusion": None},
                {"name": "allowed-paths", "status": "completed",
                 "conclusion": "success"}]
        self.assertEqual(worker_mod.required_verdicts(runs)["guard"], "pending")

    # --- C: a foreign lease OID must never enter the cursor -----------------
    def test_a_live_foreign_lease_is_not_cached_in_the_cursor(self):
        """Caching the other owner's ref OID wedged the lane on their next renew.

        The cursor has no owner field, so it cannot express "someone else's
        lease", and rebuild_and_validate demands byte equality.
        """
        remote, fake, clock, _mgr, build, tr = self._rig([])
        rival = LeaseManager(RefPort(remote="origin", _run=remote.run),
                             owner_run="host-loop/rival", now=lambda: clock["t"],
                             commit_writer=remote.write_commit, ttl_seconds=900)
        rival.acquire(TASK, MAIN)
        result = build(cursor_issue=7, cursor_body="").run_once(
            [candidate()], "CHG-X", MAIN, state(), tr())
        self.assertEqual(result.state, WorkerState.IDLE)
        writes = [c for c in fake.calls if c[0] == "PATCH" and "/issues/" in c[1]]
        self.assertTrue(writes)
        persisted = cursor_mod.parse_machine_block(writes[-1][2]["body"])
        self.assertIsNone(persisted.lease_oid,
                          "a foreign lease OID must not be cached as ours")
        self.assertIsNone(persisted.lease_ref)

    def test_a_cached_foreign_oid_recovers_on_the_next_round(self):
        """v3 stopped caching a foreign OID, but a cursor already holding one
        still had to recover — the fix cannot retroactively clean the Issue."""
        remote, _fake, clock, _mgr, _build, tr = self._rig([])
        rival = LeaseManager(RefPort(remote="origin", _run=remote.run),
                             owner_run="host-loop/rival", now=lambda: clock["t"],
                             commit_writer=remote.write_commit, ttl_seconds=900)
        held = rival.acquire(TASK, MAIN)
        poisoned = state(candidate_task=TASK, lease_ref=lease_ref(TASK),
                         lease_oid=held.ref_oid)
        rival.renew(held)
        out = rebuild_and_validate(poisoned, tr())
        self.assertEqual(out.lease_oid, remote.refs[lease_ref(TASK)])

    def test_the_round_survives_main_advancing(self):
        """main drifts several times an hour here; identity must not follow it."""
        remote, _fake, _clock, _mgr, build, tr = self._rig(
            [{"name": "guard", "status": "completed", "conclusion": "success"},
             {"name": "allowed-paths", "status": "completed", "conclusion": "skipped"}])
        first = build().run_once([candidate()], "CHG-X", MAIN, state(), tr())
        self.assertEqual(first.state, WorkerState.PR_OPEN)
        advanced = "e" * 40
        second = build().run_once([candidate()], "CHG-X", advanced, state(),
                                  tr(advanced))
        self.assertNotEqual(second.state, WorkerState.RECONCILE_REQUIRED,
                            f"identity must use the frozen base: {second.detail}")
        self.assertEqual(second.state, WorkerState.PR_OPEN)

    def test_identity_base_comes_from_the_lease_record(self):
        remote, _fake, _clock, mgr, build, tr = self._rig([])
        build().run_once([candidate()], "CHG-X", MAIN, state(), tr())
        record, _oid = mgr.observe(TASK, remote.read_record)
        self.assertEqual(record.base_oid, MAIN)
        # a later round at a different main must still resolve against MAIN
        advanced = "e" * 40
        build().run_once([candidate()], "CHG-X", advanced, state(), tr(advanced))
        record2, _ = mgr.observe(TASK, remote.read_record)
        self.assertEqual(record2.base_oid, MAIN,
                         "the frozen base must not be rewritten by a later round")

    # --- B: cursor written per lease write ---------------------------------
    def test_every_lease_ref_oid_appears_in_the_cursor_writes(self):
        """design §3: every lease write updates the cursor with the new ref OID.

        Asserting merely "more than one write happened" was too weak — removing
        any single call site left the others plus the terminal persist, so the
        count stayed above one. This compares the exact sequence of OIDs the ref
        passed through against the OIDs the cursor recorded, so dropping any one
        call site is detected.
        """
        remote, fake, _clock, _mgr, build, tr = self._rig([])
        build(cursor_issue=7, cursor_body="").run_once(
            [candidate()], "CHG-X", MAIN, state(), tr())

        ref = lease_ref(TASK)
        pushed_oids = []
        for argv in remote.pushes:
            refspec = argv[-1]
            source, _, target = refspec.partition(":")
            if target == ref and source:
                pushed_oids.append(source)
        self.assertTrue(pushed_oids, "the round must have advanced the lease ref")

        recorded = []
        for call in fake.calls:
            if call[0] == "PATCH" and "/issues/" in call[1]:
                parsed = cursor_mod.parse_machine_block(call[2]["body"])
                if parsed.lease_oid:
                    recorded.append(parsed.lease_oid)

        missing = [oid for oid in pushed_oids if oid not in recorded]
        self.assertEqual(missing, [],
                         f"lease OIDs never written to the cursor: {missing}; "
                         f"pushed={pushed_oids} recorded={recorded}")
        self.assertEqual(recorded[-1], remote.refs[ref],
                         "the cursor must end level with the ref")


class CheckClassification(unittest.TestCase):
    def test_empty_check_set_is_pending_not_green(self):
        self.assertEqual(classify_checks([]), "pending")
        self.assertEqual(worker_mod.unsatisfied_required_checks([]),
                         ("allowed-paths", "guard"))

    def test_incomplete_run_is_pending(self):
        self.assertEqual(
            classify_checks([{"name": "guard", "status": "in_progress",
                              "conclusion": None}]), "pending")

    def test_failure_is_failed(self):
        self.assertEqual(classify_checks(
            [{"name": "guard", "status": "completed", "conclusion": "failure"}]),
            "failed")

    def test_skipped_required_check_is_pending_not_green(self):
        """The exact set sdd-guard.yml leaves on a host-loop push head.

        Recorded in this change's own evidence (d2-identity-staging.md:161):
        allowed-paths is `skipped` on push and only `success` on the `edited`
        run. The previous assertion locked in the opposite — it asserted that a
        skipped conclusion counts as green — which is how a head whose MECH-004
        path contract was never evaluated could be handed back as CHECKS_GREEN.
        """
        push_only = [
            {"name": "guard", "status": "completed", "conclusion": "success"},
            {"name": "allowed-paths", "status": "completed", "conclusion": "skipped"},
        ]
        self.assertEqual(classify_checks(push_only), "pending")
        self.assertEqual(worker_mod.unsatisfied_required_checks(push_only),
                         ("allowed-paths",))
        self.assertEqual(worker_mod.required_verdicts(push_only),
                         {"guard": "success", "allowed-paths": "pending"})

    def test_an_executed_success_on_the_edited_run_promotes_to_green(self):
        both_runs = [
            {"name": "guard", "status": "completed", "conclusion": "success"},
            {"name": "allowed-paths", "status": "completed", "conclusion": "skipped"},
            {"name": "allowed-paths", "status": "completed", "conclusion": "success"},
        ]
        self.assertEqual(classify_checks(both_runs), "green")
        self.assertEqual(worker_mod.unsatisfied_required_checks(both_runs), ())

    def test_neutral_on_a_required_name_is_also_pending(self):
        runs = [{"name": "guard", "status": "completed", "conclusion": "success"},
                {"name": "allowed-paths", "status": "completed", "conclusion": "neutral"}]
        self.assertEqual(classify_checks(runs), "pending")

    def test_skipped_on_a_NON_required_run_is_not_a_failure(self):
        runs = [{"name": "guard", "status": "completed", "conclusion": "success"},
                {"name": "allowed-paths", "status": "completed", "conclusion": "success"},
                {"name": "swift", "status": "completed", "conclusion": "skipped"}]
        self.assertEqual(classify_checks(runs), "green")

    def test_a_failing_non_required_run_fails_the_round(self):
        """Swift CI is not in REQUIRED_PR_CHECKS but must still be able to fail.

        Folding unknown names into the required mapping would make them skip the
        non-required failure scan, silently ignoring a red Swift run.
        """
        runs = [{"name": "guard", "status": "completed", "conclusion": "success"},
                {"name": "allowed-paths", "status": "completed", "conclusion": "success"},
                {"name": "swift", "status": "completed", "conclusion": "failure"}]
        self.assertEqual(classify_checks(runs), "failed")
        self.assertEqual(worker_mod.unsatisfied_required_checks(runs), ())

    def test_a_pending_non_required_run_keeps_the_round_pending(self):
        runs = [{"name": "guard", "status": "completed", "conclusion": "success"},
                {"name": "allowed-paths", "status": "completed", "conclusion": "success"},
                {"name": "swift", "status": "in_progress", "conclusion": None}]
        self.assertEqual(classify_checks(runs), "pending")

    def test_an_unknown_extra_run_cannot_contribute_greenness(self):
        runs = [{"name": "guard", "status": "completed", "conclusion": "success"},
                {"name": "some-other-check", "status": "completed",
                 "conclusion": "success"}]
        self.assertEqual(worker_mod.unsatisfied_required_checks(runs),
                         ("allowed-paths",))
        self.assertEqual(classify_checks(runs), "pending")

    def test_mixed_pending_wins_over_success(self):
        self.assertEqual(classify_checks([
            {"name": "guard", "status": "completed", "conclusion": "success"},
            {"name": "allowed-paths", "status": "queued", "conclusion": None},
        ]), "pending")

    def test_action_required_is_failed(self):
        self.assertEqual(classify_checks(
            [{"name": "guard", "status": "completed",
              "conclusion": "action_required"}]), "failed")


if __name__ == "__main__":
    unittest.main(verbosity=2)
