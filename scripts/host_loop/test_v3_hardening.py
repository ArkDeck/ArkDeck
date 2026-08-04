#!/usr/bin/env python3
"""Regression cover for the v3 review's findings (TASK-HLR-003).

Everything here exists because a mutation survived or a defect was found by
reading rather than by a failing test. Each class names the specific thing that
was not caught, so a future reader can tell what the test is load-bearing for.

The check-verdict and cursor-consistency contracts live in their own files
(test_check_verdict_contract.py, test_cursor_contract.py) because they are
state tables rather than regressions.
"""

from __future__ import annotations

import json
import sys
import unittest
from pathlib import Path

HOST_LOOP_DIR = Path(__file__).resolve().parent
SCRIPTS_DIR = HOST_LOOP_DIR.parent
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

from host_loop import cursor as cursor_mod  # noqa: E402
from host_loop.cursor import CursorError, surrounding_human_text  # noqa: E402
from host_loop.identity import (  # noqa: E402
    PRIdentity,
    ReconcileRequired,
    resolve_pull,
)
from host_loop.lease import (  # noqa: E402
    FenceLost,
    LEASE_SCHEMA,
    LeaseError,
    LeaseRecord,
    lease_ref,
    task_branch,
)
from host_loop.test_fault_matrix import (  # noqa: E402
    FakeApi,
    FakeRemote,
    HEAD,
    TASK,
    api_port,
    envelope_reader,
    manager,
    pull,
)
from host_loop.test_worker_cursor import (  # noqa: E402
    MAIN,
    candidate,
    state,
    truth,
)
from host_loop.transport import (  # noqa: E402
    ApiPort,
    PolicyRefused,
    RefPort,
    Refused,
    TransportError,
)
from host_loop import worker as worker_mod  # noqa: E402
from host_loop.worker import Worker, WorkerState  # noqa: E402

GREEN = [{"name": "guard", "status": "completed", "conclusion": "success"},
         {"name": "allowed-paths", "status": "completed", "conclusion": "success"}]


# ------------------------------------------------- HIGH (3): terminal fence

class TheTerminalCursorWriteIsFenced(unittest.TestCase):
    """The round's last external write had no fence gate.

    Every other write was gated, but the terminal cursor write inherited its
    protection from the dispatch branch immediately above it — and that branch
    is skipped entirely when the required checks are already green. A worker
    whose fence had been taken therefore still wrote the shared cursor Issue,
    stamping its own stale lease OID over the real holder's.
    """

    def _worker(self, remote, fake, *, cursor_issue, cursor_body):
        mgr, _clock = manager(remote, run="host-loop/worker")
        return Worker(
            api_port(fake), mgr, change_approved=lambda c: True,
            done_tasks=lambda: frozenset(),
            read_envelope=envelope_reader(base=MAIN),
            read_lease_record=remote.read_record,
            prepare_branch=lambda c, b: HEAD,
            render_body=lambda c, b, h: "ENVELOPE",
            now=lambda: 1000,
            cursor_issue=cursor_issue, cursor_body=cursor_body)

    def _steal_on_checks(self, worker, remote, fake):
        """Take the lease over during the check-runs read.

        That read is the last thing before the terminal write, and with green
        checks the dispatch branch in between does not execute — so this is the
        only steal window that reaches the write under test.
        """
        stolen = {"done": False, "at": None}
        original = fake.__class__.__call__

        def hook(self_fake, method, path, body):
            if method == "GET" and "/check-runs" in path and not stolen["done"]:
                observed = worker._leases.observe(TASK, remote.read_record)
                assert observed, "the lease must exist to be stolen"
                record, _oid = observed
                remote.refs[lease_ref(TASK)] = remote.write_commit(
                    record.serialize(), None)
                stolen["done"] = True
                # Writes before this point were made while the fence was held
                # and are legitimate; only what follows is under test.
                stolen["at"] = len(self_fake.calls)
            return original(self_fake, method, path, body)

        fake.__class__.__call__ = hook
        return stolen, original

    def test_green_checks_still_gate_the_cursor_write(self):
        remote = FakeRemote()
        fake = FakeApi(pulls=[pull(21)], check_runs=list(GREEN))
        worker = self._worker(remote, fake, cursor_issue=7,
                              cursor_body=state().render())
        stolen, original = self._steal_on_checks(worker, remote, fake)
        try:
            result = worker.run_once([candidate()], "CHG-X", MAIN, state(),
                                     truth(open_pr_numbers=frozenset({21})))
        finally:
            fake.__class__.__call__ = original

        self.assertTrue(stolen["done"], "the steal must have happened")
        self.assertEqual(result.state, WorkerState.RECONCILE_REQUIRED,
                         f"a lost fence must stop the lane: {result.detail}")
        after = [c for c in fake.calls[stolen["at"]:]
                 if c[0] == "PATCH" and "/issues/" in c[1]]
        self.assertEqual(after, [],
                         f"no cursor write may follow a lost fence; {after}")
        # The terminal write is the one carrying pr_head; it must not exist at
        # all, which is what distinguishes this from the earlier gated writes.
        terminal = [c for c in fake.calls
                    if c[0] == "PATCH" and "/issues/" in c[1]
                    and f'"pr_head":"{HEAD}"' in (c[2] or {}).get("body", "")]
        self.assertEqual(terminal, [], "the terminal cursor write must not land")

    def test_the_same_round_does_write_the_cursor_when_the_fence_holds(self):
        """The negative test above is only meaningful if the write normally happens."""
        remote = FakeRemote()
        fake = FakeApi(pulls=[pull(21)], check_runs=list(GREEN))
        worker = self._worker(remote, fake, cursor_issue=7,
                              cursor_body=state().render())
        result = worker.run_once([candidate()], "CHG-X", MAIN, state(),
                                 truth(open_pr_numbers=frozenset({21})))
        self.assertEqual(result.state, WorkerState.CHECKS_GREEN, result.detail)
        terminal = [c for c in fake.calls
                    if c[0] == "PATCH" and "/issues/" in c[1]
                    and f'"pr_head":"{HEAD}"' in (c[2] or {}).get("body", "")]
        self.assertTrue(terminal,
                        "the guarded write must occur on the happy path, "
                        "or the fence test above proves nothing")


# ------------------------------------------- HIGH (4): surviving mutants

class AdoptionComparesTheWholeEnvelope(unittest.TestCase):
    """`_matches` dropping its Task comparison survived mutation.

    Branch name plus base ref is not identity: a stale branch left by an earlier
    task, or a rebased one, can carry the right ref and the wrong envelope.
    Adopting it would attach this task's lease to another task's PR.
    """

    @staticmethod
    def _reader(body):
        """A reader that actually reads the envelope.

        The shared `envelope_reader` in test_fault_matrix is a stub: it returns a
        fixed (task, base) whenever the literal string "ENVELOPE" appears. That
        is why the mutant deleting the Task comparison survived — the double
        could not express the distinction the code under test makes. Same class
        of gap as the fake that omitted total_count.
        """
        task = base = None
        for line in body.splitlines():
            if line.startswith("Task: "):
                task = line[len("Task: "):].strip()
            elif line.startswith("Base: "):
                base = line[len("Base: "):].strip()
        return None if task is None or base is None else (task, base)

    def _resolve(self, body):
        identity = PRIdentity(task_id=TASK,
                              head_branch=task_branch(TASK).removeprefix("refs/heads/"),
                              base_oid=MAIN)
        candidate_pull = {"number": 21, "state": "open",
                          "head": {"ref": identity.head_branch, "sha": HEAD},
                          "base": {"ref": "main"}, "body": body}
        fake = FakeApi(pulls=[candidate_pull])
        return resolve_pull(api_port(fake), identity, self._reader,
                            create_attempted=False)

    def test_a_matching_envelope_is_adopted(self):
        self.assertEqual(self._resolve(f"Task: {TASK}\nBase: {MAIN}").action, "adopt")

    def test_a_foreign_task_in_the_envelope_stops_the_lane(self):
        """Not merely "do not adopt" — it must not open a second PR either.

        The head already carries an open PR, so creating another would be the
        duplicate-PR hazard. Refusing is the only safe action, and it needs a
        human to look at why a foreign envelope is sitting on this branch.
        """
        with self.assertRaisesRegex(ReconcileRequired, "envelope identity"):
            self._resolve(f"Task: TASK-OTHER-002\nBase: {MAIN}")

    def test_a_foreign_base_oid_in_the_envelope_stops_the_lane(self):
        """The base pin is part of identity, not decoration."""
        with self.assertRaisesRegex(ReconcileRequired, "envelope identity"):
            self._resolve(f"Task: {TASK}\nBase: {'a' * 40}")

    def test_an_unreadable_envelope_stops_the_lane(self):
        with self.assertRaisesRegex(ReconcileRequired, "envelope identity"):
            self._resolve("no envelope here")


class LeaseRecordParseRefusesWhatItCannotTrust(unittest.TestCase):
    """Both the schema gate and the trailing `validate()` survived mutation.

    The lease record is the fence. Accepting one whose schema is unknown, or
    whose fields are structurally wrong, means fencing against a record this
    code does not actually understand.
    """

    def _payload(self, **over):
        base = dict(schema=LEASE_SCHEMA, task_id=TASK, base_oid=MAIN,
                    owner_run="host-loop/worker", fence=1, expires_at=2000,
                    pr_branch=task_branch(TASK), pr_number=None,
                    create_attempted=False, checks_dispatched_head=None,
                    previous_lease_oid=None)
        base.update(over)
        return json.dumps(base)

    def test_a_well_formed_record_parses(self):
        self.assertEqual(LeaseRecord.parse(self._payload()).fence, 1)

    def test_an_unknown_schema_is_refused(self):
        with self.assertRaisesRegex(LeaseError, "schema"):
            LeaseRecord.parse(self._payload(schema="arkdeck-host-loop-lease/v99"))

    def test_a_missing_schema_is_refused(self):
        payload = json.loads(self._payload())
        del payload["schema"]
        with self.assertRaisesRegex(LeaseError, "schema"):
            LeaseRecord.parse(json.dumps(payload))

    def test_a_non_object_payload_is_refused(self):
        for text in ("[]", '"string"', "42", "null"):
            with self.subTest(text=text):
                with self.assertRaises(LeaseError):
                    LeaseRecord.parse(text)

    def test_parse_runs_validate_on_the_fence(self):
        """Dropping the trailing validate() call must not go unnoticed."""
        for bad_fence in (0, -1, "1", 1.5, True, None):
            with self.subTest(fence=bad_fence):
                with self.assertRaises(LeaseError):
                    LeaseRecord.parse(self._payload(fence=bad_fence))

    def test_parse_runs_validate_on_the_base_oid(self):
        for bad in ("deadbeef", "", "G" * 40, MAIN.upper()):
            with self.subTest(oid=bad):
                with self.assertRaises(LeaseError):
                    LeaseRecord.parse(self._payload(base_oid=bad))

    def test_parse_runs_validate_on_the_expiry(self):
        for bad in ("2000", None, 20.5):
            with self.subTest(expires_at=bad):
                with self.assertRaises(LeaseError):
                    LeaseRecord.parse(self._payload(expires_at=bad))

    def test_a_missing_field_is_refused_by_name(self):
        for field in ("task_id", "owner_run", "fence", "expires_at", "pr_branch",
                      "pr_number", "create_attempted", "checks_dispatched_head",
                      "previous_lease_oid"):
            with self.subTest(field=field):
                payload = json.loads(self._payload())
                del payload[field]
                with self.assertRaisesRegex(LeaseError, "missing field"):
                    LeaseRecord.parse(json.dumps(payload))


class SuccessIsAnAllowlist(unittest.TestCase):
    """Widening SUCCESS_STATUSES survived mutation.

    A 204 or a 3xx is not a completed mutation. Treating one as success is how
    `{"message": "Moved Permanently"}` previously read as an applied update.
    """

    def _port(self, status):
        calls = []

        def send(method, path, body):
            calls.append((method, path, body))
            return status, {"number": 21}

        return ApiPort(owner="ArkDeck", repo="ArkDeck", _send=send)

    def test_200_and_201_are_the_only_accepted_statuses(self):
        for status in (200, 201):
            with self.subTest(status=status):
                port = self._port(status).bound_to_pull(21)
                self.assertEqual(port.update_pull(21, body="x")["number"], 21)

    def test_every_other_2xx_or_3xx_is_refused(self):
        for status in (202, 203, 204, 205, 206, 301, 302, 303, 307, 308):
            with self.subTest(status=status):
                port = self._port(status).bound_to_pull(21)
                with self.assertRaises(TransportError):
                    port.update_pull(21, body="x")


# ------------------------------------------------------ LOW: check-runs paging

class CheckRunsAreReadToExhaustion(unittest.TestCase):
    """Only page one was read, so any red check past the thirtieth was invisible.

    GitHub caps this endpoint's page at 30 by default. A PR with several suites
    reaches that easily, and the failure mode is a false green — the worst
    available direction.
    """

    def _port(self, pages, *, total=None):
        """pages: list of per-page run lists. total defaults to the real sum."""
        self.requests = []
        resolved = sum(len(p) for p in pages) if total is None else total

        def send(method, path, body):
            self.requests.append(path)
            page = 1
            for item in path.split("?", 1)[-1].split("&"):
                if item.startswith("page="):
                    page = int(item[len("page="):])
            runs = pages[page - 1] if page - 1 < len(pages) else []
            return 200, {"total_count": resolved, "check_runs": runs}

        return ApiPort(owner="ArkDeck", repo="ArkDeck", _send=send)

    @staticmethod
    def _runs(count, prefix):
        return [{"name": f"{prefix}-{i}", "status": "completed",
                 "conclusion": "success"} for i in range(count)]

    def test_a_single_short_page_takes_one_request(self):
        port = self._port([self._runs(3, "a")])
        self.assertEqual(len(port.list_check_runs(MAIN)), 3)
        self.assertEqual(len(self.requests), 1)

    def test_a_second_page_is_fetched_and_appended_in_order(self):
        port = self._port([self._runs(100, "a"), self._runs(7, "b")])
        collected = port.list_check_runs(MAIN)
        self.assertEqual(len(collected), 107)
        self.assertEqual(collected[0]["name"], "a-0")
        self.assertEqual(collected[-1]["name"], "b-6")
        self.assertEqual(len(self.requests), 2)

    def test_an_exactly_full_page_does_not_need_a_second_request(self):
        """total_count says 100, so the walk is complete without probing page 2."""
        port = self._port([self._runs(100, "a")], total=100)
        self.assertEqual(len(port.list_check_runs(MAIN)), 100)
        self.assertEqual(len(self.requests), 1)

    def test_a_red_check_on_page_two_is_visible(self):
        """The concrete governance consequence of reading one page."""
        red = [{"name": "guard", "status": "completed", "conclusion": "failure"}]
        port = self._port([self._runs(100, "a"), red])
        names = {(r["name"], r["conclusion"]) for r in port.list_check_runs(MAIN)}
        self.assertIn(("guard", "failure"), names)

    def test_a_truncated_view_is_refused_rather_than_reported_green(self):
        port = self._port([self._runs(100, "a"), []], total=150)
        with self.assertRaisesRegex(TransportError, "incomplete check-run view"):
            port.list_check_runs(MAIN)

    # The two assertions below pin the SPECIFIC message, not just the substring
    # "total_count". A mutation that deleted the type gate still raised — the
    # completeness check downstream compares len(collected) against None and its
    # message also mentions total_count — so a loose regex passed for the wrong
    # reason and the mutant survived. Same weak-assertion trap as an earlier
    # `len(writes) > 1`.
    MISSING = "missing a usable total_count"

    def test_a_missing_total_count_is_refused_by_the_type_gate(self):
        def send(method, path, body):
            return 200, {"check_runs": []}

        port = ApiPort(owner="ArkDeck", repo="ArkDeck", _send=send)
        with self.assertRaisesRegex(TransportError, self.MISSING):
            port.list_check_runs(MAIN)

    def test_a_non_integer_total_count_is_refused_by_the_type_gate(self):
        for bogus in ("3", None, 3.5, True, -1, [], {}):
            with self.subTest(total_count=bogus):
                def send(method, path, body, bogus=bogus):
                    return 200, {"total_count": bogus, "check_runs": []}

                port = ApiPort(owner="ArkDeck", repo="ArkDeck", _send=send)
                with self.assertRaisesRegex(TransportError, self.MISSING):
                    port.list_check_runs(MAIN)

    def test_a_bool_total_count_cannot_pass_as_an_integer(self):
        """True == 1, so a bool would otherwise validate a one-run view."""
        def send(method, path, body):
            return 200, {"total_count": True,
                         "check_runs": [{"name": "guard", "status": "completed",
                                         "conclusion": "success"}]}

        port = ApiPort(owner="ArkDeck", repo="ArkDeck", _send=send)
        with self.assertRaisesRegex(TransportError, self.MISSING):
            port.list_check_runs(MAIN)

    def test_a_total_count_that_moves_mid_walk_is_refused(self):
        counts = iter([200, 201])

        def send(method, path, body):
            return 200, {"total_count": next(counts),
                         "check_runs": self._runs(100, "a")}

        port = ApiPort(owner="ArkDeck", repo="ArkDeck", _send=send)
        with self.assertRaisesRegex(TransportError, "not a consistent snapshot"):
            port.list_check_runs(MAIN)

    def test_an_unbounded_walk_is_refused_rather_than_looping(self):
        def send(method, path, body):
            return 200, {"total_count": 10_000, "check_runs": self._runs(100, "a")}

        port = ApiPort(owner="ArkDeck", repo="ArkDeck", _send=send)
        with self.assertRaisesRegex(TransportError, "pagination cap"):
            port.list_check_runs(MAIN)

    def test_a_missing_check_runs_key_is_refused(self):
        def send(method, path, body):
            return 200, {"total_count": 0}

        port = ApiPort(owner="ArkDeck", repo="ArkDeck", _send=send)
        with self.assertRaisesRegex(TransportError, "check_runs"):
            port.list_check_runs(MAIN)


# --------------------------------------------- LOW: race vs policy refusal

class ARefRaceIsFenceLossNotPolicy(unittest.TestCase):
    """Two workers racing were reported as a ref-policy refusal.

    That sent the operator to fix a policy that was never the problem, and it
    hid the thing that actually happened: someone else moved the ref. git only
    says "stale info" for a rejected --force-with-lease; a plain concurrent loss
    says "fetch first", and a contended ref says "cannot lock ref".
    """

    def _manager_over(self, stderr):
        def run(args, **kwargs):
            if args[:2] == ["git", "push"]:
                raise self.PushFailed(stderr)
            return ""

        class Remote(FakeRemote):
            pass

        remote = Remote()
        original = remote.run

        def routed(args, **kwargs):
            if args[:2] == ["git", "push"]:
                from host_loop.transport import TransportError as _TE
                raise _TE(stderr)
            return original(args, **kwargs)

        remote.run = routed
        return remote

    @staticmethod
    def _push_with_stderr(stderr):
        """Drive the real RefPort._push with a failing git and return the raise."""
        def run(argv, **kwargs):
            if argv[:2] == ["git", "push"]:
                return 1, "", stderr
            return 0, "", ""

        port = RefPort(remote="origin", _run=run)
        try:
            port.compare_and_swap(
                "refs/heads/agent/host-loop/leases/T", "a" * 40, "b" * 40)
        except BaseException as error:  # noqa: BLE001 - the classification IS the test
            return error
        raise AssertionError("a failing push must raise")

    def test_the_git_wordings_that_mean_someone_else_moved_the_ref(self):
        """Behavioural, not a source grep.

        The previous version of this test read transport.py's own source within
        +/-400 chars of "stale info". The comment above the branch also contains
        "fetch first", so deleting that clause from the CONDITION left the test
        green — the test could not distinguish the behaviour from the prose
        describing it. It now drives the real _push.
        """
        wordings = [
            "! [rejected] refs/heads/x -> refs/heads/x (stale info)",
            "! [rejected] refs/heads/x -> refs/heads/x (non-fast-forward)",
            "hint: Updates were rejected because the remote contains work that "
            "you do not have locally. fetch first",
            "error: cannot lock ref 'refs/heads/x': is at aaa but expected bbb",
        ]
        for stderr in wordings:
            with self.subTest(stderr=stderr[:40]):
                error = self._push_with_stderr(stderr)
                self.assertIsInstance(
                    error, Refused,
                    f"must be a clean fence-loss refusal, got {type(error).__name__}")
                self.assertNotIsInstance(error, PolicyRefused)

    def test_a_policy_refusal_is_not_reported_as_fence_loss(self):
        for stderr in [
            "! [remote rejected] refs/heads/x -> refs/heads/x (protected branch "
            "hook declined)",
            "remote: error: GH013: Repository rule violations found for "
            "refs/heads/x",
            "! [remote rejected] refs/heads/x -> refs/heads/x (declined)",
        ]:
            with self.subTest(stderr=stderr[:40]):
                self.assertIsInstance(self._push_with_stderr(stderr), PolicyRefused)

    def test_a_policy_refusal_that_also_mentions_a_lock_is_still_policy(self):
        """Precedence. A ruleset rejection whose text happens to contain the
        generic race wording must not be laundered into a fence loss, or the
        operator is sent hunting a concurrent worker that does not exist."""
        stderr = ("! [remote rejected] refs/heads/x -> refs/heads/x "
                  "(protected branch hook declined)\n"
                  "error: cannot lock ref 'refs/heads/x'")
        self.assertIsInstance(self._push_with_stderr(stderr), PolicyRefused)

    def test_the_lease_wording_outranks_a_policy_marker(self):
        """`stale info` is git's lease-specific wording and is definitive."""
        stderr = ("! [rejected] refs/heads/x -> refs/heads/x (stale info)\n"
                  "hint: some hook also said declined")
        error = self._push_with_stderr(stderr)
        self.assertIsInstance(error, Refused)
        self.assertNotIsInstance(error, PolicyRefused)

    def test_an_unrecognised_failure_stays_ambiguous(self):
        error = self._push_with_stderr("fatal: unable to access: timed out")
        self.assertIsInstance(error, TransportError)
        self.assertNotIsInstance(error, Refused)
        self.assertNotIsInstance(error, PolicyRefused)

    def test_a_policy_refusal_is_still_distinguishable(self):
        """The two must not be collapsed: the operator response differs."""
        self.assertTrue(issubclass(PolicyRefused, Exception))
        self.assertFalse(issubclass(PolicyRefused, FenceLost))
        self.assertFalse(issubclass(FenceLost, PolicyRefused))


# ------------------------------------- LOW: the cursor Issue is a shared surface

class HumanTextInTheCursorIssueSurvives(unittest.TestCase):
    """`human_prefix` existed but had zero call sites, so every write truncated.

    The maintainer reads this Issue. Replacing their text with a bare machine
    block on the first write is a governance loss, not a formatting one.
    """

    def _api(self):
        writes = []

        def send(method, path, body):
            writes.append((method, path, body))
            return 200, {"number": 7}

        return ApiPort(owner="ArkDeck", repo="ArkDeck", _send=send), writes

    def test_text_above_the_block_is_preserved(self):
        api, writes = self._api()
        previous = "## Host loop cursor\n\nMaintainer notes.\n\n" + state().render()
        cursor_mod.store(api.bound_to_issue(7), 7,
                         state(candidate_task=TASK), previous_body=previous)
        self.assertEqual(len(writes), 1)
        body = writes[0][2]["body"]
        self.assertTrue(body.startswith("## Host loop cursor"), body[:60])
        self.assertIn("Maintainer notes.", body)
        self.assertIn(TASK, body)

    def test_text_below_the_block_is_preserved(self):
        api, writes = self._api()
        previous = state().render() + "\nSee CHG-2026-030 for context.\n"
        cursor_mod.store(api.bound_to_issue(7), 7,
                         state(candidate_task=TASK), previous_body=previous)
        self.assertIn("See CHG-2026-030 for context.", writes[0][2]["body"])

    def test_a_no_op_write_is_still_skipped_when_human_text_is_present(self):
        api, writes = self._api()
        previous = "notes\n\n" + state().render()
        self.assertFalse(cursor_mod.store(api.bound_to_issue(7), 7, state(),
                                          previous_body=previous))
        self.assertEqual(writes, [])

    def test_a_body_with_no_block_yet_keeps_its_text(self):
        api, writes = self._api()
        cursor_mod.store(api.bound_to_issue(7), 7, state(),
                         previous_body="hand-written seed")
        body = writes[0][2]["body"]
        self.assertTrue(body.startswith("hand-written seed\n"), body[:40])
        self.assertIn(cursor_mod.OPEN_MARKER, body)

    def test_an_empty_body_yields_the_block_alone(self):
        self.assertEqual(surrounding_human_text(""), ("", ""))

    def test_a_duplicated_block_is_refused_rather_than_half_replaced(self):
        with self.assertRaisesRegex(CursorError, "duplicate"):
            surrounding_human_text(state().render() + state().render())

    def test_an_unterminated_block_is_refused(self):
        with self.assertRaisesRegex(CursorError, "no close"):
            surrounding_human_text(f"{cursor_mod.OPEN_MARKER}\n{{}}\n")

    def test_a_stray_close_marker_is_refused(self):
        with self.assertRaisesRegex(CursorError, "no open"):
            surrounding_human_text(f"notes\n{cursor_mod.CLOSE_MARKER}\n")

    def test_the_round_trip_is_stable_under_repeated_writes(self):
        """Preservation must not accumulate blank lines or drift."""
        body = "notes\n\n" + state().render()
        for _ in range(3):
            prefix, suffix = surrounding_human_text(body)
            body = f"{prefix}{state(candidate_task=TASK).render()}{suffix}"
        self.assertEqual(body.count(cursor_mod.OPEN_MARKER), 1)
        self.assertEqual(body, "notes\n\n" + state(candidate_task=TASK).render())




# ------------------------------- v4 review: confirmed findings, second round

class TheBranchPushIsFencedToo(unittest.TestCase):
    """The round's FIRST external write was ungated.

    _prepare_branch pushes refs/heads/agent/host-loop/tasks/<task>, and the
    first assert_still_held sat on the line AFTER it. So a worker that had
    already lost its fence still moved the shared task branch — which is what
    the rival's PR head points at.
    """

    def _rig(self):
        remote = FakeRemote()
        fake = FakeApi(pulls=[pull(21)], check_runs=list(GREEN))
        mgr, _clock = manager(remote, run="host-loop/worker")
        pushes = []

        def prepare(cand, base):
            pushes.append((cand.task_id, base))
            return HEAD

        worker = Worker(
            api_port(fake), mgr, change_approved=lambda c: True,
            done_tasks=lambda: frozenset(),
            read_envelope=envelope_reader(base=MAIN),
            read_lease_record=remote.read_record,
            prepare_branch=prepare,
            render_body=lambda c, b, h: "ENVELOPE",
            now=lambda: 1000)
        return remote, fake, worker, pushes

    def test_a_lost_fence_stops_the_round_before_the_branch_is_pushed(self):
        """Steal in the real window: after acquisition, before the first write.

        An earlier version of this test hooked the first FakeApi call, which is
        too late — the round acquires the lease and reaches the branch push
        before it talks to the API at all, so the steal never landed inside the
        window under test and the test failed for the wrong reason.
        """
        remote, _fake, worker, pushes = self._rig()
        stolen = {"done": False}
        real_acquire = worker._leases.acquire

        def acquire_then_steal(task_id, base_oid):
            held = real_acquire(task_id, base_oid)
            observed = worker._leases.observe(task_id, remote.read_record)
            assert observed, "the lease must exist to be stolen"
            record, _oid = observed
            remote.refs[lease_ref(task_id)] = remote.write_commit(
                record.serialize(), None)
            stolen["done"] = True
            return held

        worker._leases.acquire = acquire_then_steal
        result = worker.run_once([candidate()], "CHG-X", MAIN, state(), truth())

        self.assertTrue(stolen["done"], "the steal must have happened")
        self.assertEqual(result.state, WorkerState.RECONCILE_REQUIRED, result.detail)
        self.assertEqual(pushes, [],
                         f"the task branch must not be pushed after fence loss; {pushes}")

    def test_the_branch_is_pushed_when_the_fence_holds(self):
        """The negative test above must not be able to pass vacuously."""
        _remote, _fake, worker, pushes = self._rig()
        result = worker.run_once([candidate()], "CHG-X", MAIN, state(),
                                 truth(open_pr_numbers=frozenset({21})))
        self.assertNotEqual(result.state, WorkerState.RECONCILE_REQUIRED,
                            result.detail)
        self.assertEqual(len(pushes), 1, "the happy path must push the branch")

    def test_the_gate_precedes_the_branch_push_in_source_order(self):
        """Structural, because the steal window above is narrow.

        Reads the AST of _round and asserts the first assert_still_held call
        appears before the _prepare_branch call.
        """
        import ast

        source = Path(worker_mod.__file__).read_text()
        tree = ast.parse(source)
        target = None
        for node in ast.walk(tree):
            if isinstance(node, ast.FunctionDef) and node.name == "_round":
                target = node
        self.assertIsNotNone(target, "_round must exist")
        gate = prepare = None
        for node in ast.walk(target):
            if not isinstance(node, ast.Call):
                continue
            name = getattr(node.func, "attr", None)
            if name == "assert_still_held" and gate is None:
                gate = node.lineno
            if name == "_prepare_branch" and prepare is None:
                prepare = node.lineno
        self.assertIsNotNone(prepare, "_round must prepare the branch")
        self.assertIsNotNone(gate, "_round must gate on the fence")
        self.assertLess(gate, prepare,
                        "the fence must be re-confirmed BEFORE the branch push, "
                        "which is the round's first external write")


class ReconciliationIsObservable(unittest.TestCase):
    """The corrections list was the compensating control for relaxing the gate.

    It was discarded at its only production call site, so every cache/Truth
    divergence became silent — and the commit message claimed it was reported.
    """

    def test_the_round_reports_what_it_corrected(self):
        remote = FakeRemote()
        fake = FakeApi(pulls=[pull(21)], check_runs=list(GREEN))
        mgr, _clock = manager(remote, run="host-loop/worker")
        worker = Worker(
            api_port(fake), mgr, change_approved=lambda c: True,
            done_tasks=lambda: frozenset(),
            read_envelope=envelope_reader(base=MAIN),
            read_lease_record=remote.read_record,
            prepare_branch=lambda c, b: HEAD,
            render_body=lambda c, b, h: "ENVELOPE",
            now=lambda: 1000)
        stale = state(pr_number=999, pr_head="a" * 40)
        result = worker.run_once([candidate()], "CHG-X", MAIN, stale,
                                 truth(open_pr_numbers=frozenset({21})))
        self.assertIn("pr_number", result.detail,
                      f"a corrected cache fact must be visible: {result.detail!r}")

    def test_a_clean_cursor_adds_no_noise(self):
        remote = FakeRemote()
        fake = FakeApi(pulls=[pull(21)], check_runs=list(GREEN))
        mgr, _clock = manager(remote, run="host-loop/worker")
        worker = Worker(
            api_port(fake), mgr, change_approved=lambda c: True,
            done_tasks=lambda: frozenset(),
            read_envelope=envelope_reader(base=MAIN),
            read_lease_record=remote.read_record,
            prepare_branch=lambda c, b: HEAD,
            render_body=lambda c, b, h: "ENVELOPE",
            now=lambda: 1000)
        result = worker.run_once([candidate()], "CHG-X", MAIN, state(), truth())
        self.assertNotIn("reconciled", result.detail)


class CursorStateRejectsTypeConfusion(unittest.TestCase):
    """The bool guard added to LeaseRecord.validate was not applied here."""

    def test_a_bool_pr_number_is_refused(self):
        with self.assertRaises(CursorError):
            state(pr_number=True).validate()

    def test_a_bool_last_observed_at_is_refused(self):
        with self.assertRaises(CursorError):
            state(last_observed_at=True).validate()

    def test_the_string_fields_must_be_strings(self):
        for field, value in (("candidate_task", 1), ("lease_ref", 2)):
            with self.subTest(field=field):
                with self.assertRaises(CursorError):
                    state(**{field: value}).validate()


class CheckRunViewsAreDeduplicated(unittest.TestCase):
    """Completeness was judged by count alone.

    A page reordered between requests yields a view that duplicates one run and
    drops another, yet len(collected) == total_count, so it read as complete.
    """

    def test_a_duplicated_run_is_refused_rather_than_counted_as_complete(self):
        runs_a = [{"name": f"a-{i}", "status": "completed", "conclusion": "success",
                   "id": i} for i in range(100)]
        page_two = [dict(runs_a[0])]  # the reorder duplicates a-0 and drops a-100

        def send(method, path, body):
            page = 1
            for item in path.split("?", 1)[-1].split("&"):
                if item.startswith("page="):
                    page = int(item[len("page="):])
            return 200, {"total_count": 101,
                         "check_runs": runs_a if page == 1 else page_two}

        port = ApiPort(owner="ArkDeck", repo="ArkDeck", _send=send)
        with self.assertRaisesRegex(TransportError, "duplicate"):
            port.list_check_runs(MAIN)

    def test_distinct_runs_sharing_a_name_are_not_treated_as_duplicates(self):
        """`guard` legitimately appears twice with different ids."""
        def send(method, path, body):
            return 200, {"total_count": 2, "check_runs": [
                {"name": "guard", "status": "completed", "conclusion": "success",
                 "id": 1},
                {"name": "guard", "status": "completed", "conclusion": "failure",
                 "id": 2}]}

        port = ApiPort(owner="ArkDeck", repo="ArkDeck", _send=send)
        self.assertEqual(len(port.list_check_runs(MAIN)), 2)


if __name__ == "__main__":
    unittest.main(verbosity=2)
