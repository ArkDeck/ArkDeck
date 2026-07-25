"""Fault matrix for the host-loop worker draft (TASK-HLR-003).

Covers the readiness fault list: two workers acquiring, stale-fence write,
heartbeat loss, create timeout, cursor/record corruption, 0-or-2 PR lookup,
plus the adapter negative proof (no review/merge/admin route is constructible).

Every case asserts a *refusal*. Passing here is not evidence of live behaviour.
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

from host_loop import identity as identity_mod
from host_loop import lease as lease_mod
from host_loop import transport as transport_mod
from host_loop.identity import PRIdentity, ReconcileRequired, resolve_pull
from host_loop.lease import FenceLost, LeaseError, LeaseManager, LeaseRecord, lease_ref, task_branch
from host_loop.transport import ApiPort, RefPort, RouteViolation, TransportError

BASE = "a" * 40
HEAD = "b" * 40
TASK = "TASK-DEMO-001"  # neutral fixture; TASK-HLR-003 is NEVER_CLAIM


# ------------------------------------------------------------------ fake remote

class FakeRemote:
    """In-memory ref store with exact --force-with-lease semantics."""

    def __init__(self):
        self.refs: dict[str, str] = {}
        self.commits: dict[str, str] = {}
        self.pushes: list[list[str]] = []
        self.fail_next_with: str | None = None
        # Real git stderr shapes. The lease-loss wording and the policy-decline
        # wording both contain "rejected", which is why the classifier must key
        # on the lease-specific tokens instead.
        self.STALE = "! [rejected] x -> y (stale info)\n"
        self.NON_FF = "! [rejected] x -> y (non-fast-forward)\n"
        self.HOOK_DECLINED = ("! [remote rejected] abc -> "
                              "agent/host-loop/leases/T (pre-receive hook declined)\n")
        self.RULESET = ("remote: error: GH013: Repository rule violations found\n"
                        "! [remote rejected] abc -> refs/heads/agent/host-loop/leases/T "
                        "(push declined due to repository rule violations)\n")
        self.LOCALIZED_TIMEOUT = "fatal: 无法访问 remote: 连接超时\n"
        self._counter = 0

    def write_commit(self, text: str, _parent):
        self._counter += 1
        oid = f"{self._counter:040x}"
        self.commits[oid] = text
        return oid

    def read_record(self, oid: str) -> str:
        return self.commits[oid]

    def run(self, argv):
        argv = list(argv)
        if argv[:2] == ["git", "ls-remote"]:
            ref = argv[-1]
            if ref in self.refs:
                return 0, f"{self.refs[ref]}\t{ref}\n", ""
            return 2, "", ""
        if argv[:2] == ["git", "push"]:
            self.pushes.append(argv)
            if self.fail_next_with is not None:
                message, self.fail_next_with = self.fail_next_with, None
                return 1, "", message
            lease_arg = next(a for a in argv if a.startswith("--force-with-lease="))
            spec = lease_arg.split("=", 1)[1]
            ref, expected = spec.rsplit(":", 1)
            refspec = argv[-1]
            source = refspec.split(":", 1)[0]
            current = self.refs.get(ref)
            if (expected or None) != current:
                return 1, "", f"stale info: {ref}"
            if source == "":
                self.refs.pop(ref, None)
            else:
                self.refs[ref] = source
            return 0, "", ""
        raise AssertionError(f"unexpected git argv {argv}")


def manager(remote: FakeRemote, run="run-1", now=1000, ttl=900):
    refs = RefPort(remote="origin", _run=remote.run)
    clock = {"t": now}
    mgr = LeaseManager(
        refs,
        owner_run=run,
        now=lambda: clock["t"],
        commit_writer=remote.write_commit,
        ttl_seconds=ttl,
    )
    return mgr, clock


class FakeApi:
    def __init__(self, pulls=None, statuses=None, check_runs=None):
        self.pulls = pulls or []
        self.calls: list[tuple[str, str, dict | None]] = []
        self.statuses = statuses or {}
        self.check_runs = check_runs if check_runs is not None else []

    def __call__(self, method, path, body):
        self.calls.append((method, path, body))
        if method == "GET" and path.split("?", 1)[0].endswith("/pulls"):
            query = path.split("?", 1)[1] if "?" in path else ""
            wanted, page = None, 1
            for item in query.split("&"):
                if item.startswith("head="):
                    wanted = item[len("head="):].split(":", 1)[-1]
                if item.startswith("page="):
                    page = int(item[len("page="):])
            matching = [pr for pr in self.pulls
                        if wanted is None or (pr.get("head") or {}).get("ref") == wanted]
            return 200, (matching if page == 1 else [])
        if method == "GET" and "/pulls/" in path:
            number = int(path.rsplit("/", 1)[1])
            for pull in self.pulls:
                if pull.get("number") == number:
                    return 200, pull
            return 404, None
        if method == "POST" and path.endswith("/pulls"):
            return self.statuses.get("create", (201, {"number": 99}))
        if method == "PATCH":
            return 200, {"number": 99}
        if method == "POST" and path.endswith("/issues"):
            return 201, {"number": 7}
        if method == "GET" and "/check-runs" in path:
            # The real endpoint always sends total_count. A fake that omits a
            # field the API always sends is how the r1 `skipped` stub defect
            # stayed invisible, so the envelope is modelled, not simplified.
            return 200, {"total_count": len(self.check_runs),
                         "check_runs": self.check_runs}
        return 200, {}


def api_port(fake: FakeApi) -> ApiPort:
    return ApiPort(owner="ArkDeck", repo="ArkDeck", _send=fake)


def envelope_reader(task=TASK, base=BASE):
    def read(body: str):
        if "ENVELOPE" not in body:
            return None
        return task, base
    return read


def pull(number, *, head=None, body="ENVELOPE", base_ref="main", state="open", **extra):
    return {
        "number": number,
        "state": state,
        "head": {"ref": head or task_branch(TASK).removeprefix("refs/heads/"), "sha": HEAD},
        "base": {"ref": base_ref},
        "body": body,
        **extra,
    }


# ------------------------------------------------------------- adapter negative

class AdapterNegativeProof(unittest.TestCase):
    """review / merge / auto-merge / branch-update / admin route count == 0."""

    def test_forbidden_routes_are_not_constructible(self):
        for method, path in [
            ("POST", "/repos/ArkDeck/ArkDeck/pulls/1/reviews"),
            ("PUT", "/repos/ArkDeck/ArkDeck/pulls/1/merge"),
            ("PUT", "/repos/ArkDeck/ArkDeck/pulls/1/update-branch"),
            ("PATCH", "/repos/ArkDeck/ArkDeck/branches/main/protection"),
            ("POST", "/repos/ArkDeck/ArkDeck/rulesets"),
            ("PATCH", "/repos/ArkDeck/ArkDeck"),
            ("POST", "/repos/ArkDeck/ArkDeck/keys"),
            ("POST", "/graphql"),
            ("DELETE", "/repos/ArkDeck/ArkDeck/pulls/1"),
            ("POST", "/repos/ArkDeck/ArkDeck/pulls/1/requested_reviewers"),
        ]:
            with self.subTest(route=f"{method} {path}"):
                with self.assertRaises(RouteViolation):
                    transport_mod.assert_route_allowed(method, path)

    def test_no_generic_request_method_is_exposed(self):
        public = [n for n in dir(ApiPort) if not n.startswith("_")]
        for name in ("request", "send", "call", "api", "graphql", "raw"):
            self.assertNotIn(name, public)

    def test_route_inventory_has_zero_forbidden_capabilities(self):
        fake = FakeApi(pulls=[pull(5)])
        port = api_port(fake)
        port.list_open_pulls_for_head(task_branch(TASK).removeprefix("refs/heads/"))
        port.get_pull(5)
        port.create_pull(head="agent/host-loop/tasks/X", base="main", title="t", body="b")
        port.bound_to_pull(5).update_pull(5, title="t2")
        port.create_issue(title="t", body="b")
        port.bound_to_issue(7).update_issue(7, body="b")
        self.assertEqual(transport_mod.forbidden_capability_count(port), 0)
        self.assertTrue(transport_mod.route_inventory(port))

    def test_pr_update_cannot_retarget_or_close(self):
        port = api_port(FakeApi())
        for field in ({"base": "release"}, {"state": "closed"}, {"draft": True},
                      {"merge_method": "squash"}):
            with self.subTest(field=field):
                with self.assertRaises(RouteViolation):
                    port.update_pull(5, **field)

    def test_issue_update_fields_are_restricted(self):
        port = api_port(FakeApi())
        for field in ({"assignees": ["x"]}, {"labels": ["y"]}, {"milestone": 1},
                      {"repository": "other"}):
            with self.subTest(field=field):
                with self.assertRaises(RouteViolation):
                    port.update_issue(7, **field)
        # `state` is no longer allowed at all: the issues endpoint also serves
        # pull requests, so a state change here was a PR-close bypass.
        with self.assertRaises(RouteViolation):
            port.update_issue(7, state="closed")
        # And an unbound port refuses outright; binding is what permits the write.
        with self.assertRaisesRegex(RouteViolation, r"not bound to an Issue"):
            port.update_issue(7, body="machine block")
        port.bound_to_issue(7).update_issue(7, body="machine block")

    def test_pr_create_is_restricted_to_main(self):
        port = api_port(FakeApi())
        with self.assertRaises(TransportError):
            port.create_pull(head="agent/host-loop/tasks/X", base="release", title="t", body="b")

    def test_ref_port_refuses_non_reserved_refs(self):
        refs = RefPort(remote="origin", _run=FakeRemote().run)
        for ref in ("refs/heads/main", "refs/heads/agent/ordinary-branch",
                    "refs/heads/agentx/foo", "refs/heads/agent/host-loop/other/x"):
            with self.subTest(ref=ref):
                with self.assertRaises(RouteViolation):
                    refs.read(ref)

    def test_ambiguous_5xx_is_not_silently_swallowed(self):
        fake = FakeApi(statuses={"create": (502, None)})
        port = api_port(fake)
        with self.assertRaises(TransportError):
            port.create_pull(head="agent/host-loop/tasks/X", base="main", title="t", body="b")


# -------------------------------------------------------------- lease faults

class PolicyVersusFence(unittest.TestCase):
    """A policy decline must never be reported as a lost fence (review finding 2)."""

    def _refs(self, stderr):
        def runner(argv):
            if list(argv)[:2] == ["git", "ls-remote"]:
                return 0, "1" * 40 + "\trefs/heads/agent/host-loop/leases/T-001\n", ""
            return 1, "", stderr
        return RefPort(remote="origin", _run=runner)

    def _cas(self, stderr):
        return self._refs(stderr).compare_and_swap(
            "refs/heads/agent/host-loop/leases/T-001", "1" * 40, "2" * 40)

    def test_pre_receive_decline_is_policy_not_fence_loss(self):
        with self.assertRaises(transport_mod.PolicyRefused):
            self._cas(FakeRemote().HOOK_DECLINED)

    def test_ruleset_violation_is_policy_not_fence_loss(self):
        with self.assertRaises(transport_mod.PolicyRefused):
            self._cas(FakeRemote().RULESET)

    def test_stale_info_is_a_fence_loss(self):
        with self.assertRaises(transport_mod.Refused) as caught:
            self._cas(FakeRemote().STALE)
        self.assertNotIsInstance(caught.exception, transport_mod.PolicyRefused)

    def test_non_fast_forward_is_a_fence_loss(self):
        with self.assertRaises(transport_mod.Refused):
            self._cas(FakeRemote().NON_FF)

    def test_localized_timeout_stays_ambiguous(self):
        with self.assertRaises(transport_mod.TransportError) as caught:
            self._cas(FakeRemote().LOCALIZED_TIMEOUT)
        self.assertNotIsInstance(caught.exception, transport_mod.Refused)

    def test_policy_decline_is_not_FenceLost_at_the_lease_layer(self):
        remote = FakeRemote()
        mgr = LeaseManager(self._refs(remote.HOOK_DECLINED), owner_run="r",
                           now=lambda: 1000, commit_writer=remote.write_commit)
        with self.assertRaises(LeaseError) as caught:
            mgr.acquire("TASK-DEMO-001", BASE)
        self.assertNotIsInstance(caught.exception, FenceLost)


class OwnershipAndBypass(unittest.TestCase):
    """Effects confined by field and ownership guards, not by route shape."""

    def _port(self, **kw):
        return ApiPort(owner="ArkDeck", repo="ArkDeck", _send=FakeApi(), **kw)

    def test_issue_state_is_not_an_allowed_field(self):
        with self.assertRaises(RouteViolation):
            self._port().update_issue(524, state="closed")

    def test_close_issue_refuses_a_pull_request_number(self):
        class PRIssue(FakeApi):
            def __call__(self, method, path, body):
                if method == "GET" and "/issues/" in path:
                    return 200, {"number": 524, "pull_request": {"url": "x"}}
                return super().__call__(method, path, body)
        port = ApiPort(owner="ArkDeck", repo="ArkDeck", _send=PRIssue()
                       ).bound_to_issue(524)
        with self.assertRaisesRegex(RouteViolation, r"is a pull request"):
            port.close_issue(524)

    def test_close_issue_accepts_a_real_issue(self):
        class RealIssue(FakeApi):
            def __call__(self, method, path, body):
                if method == "GET" and "/issues/" in path:
                    return 200, {"number": 7, "state": "open"}
                return super().__call__(method, path, body)
        port = ApiPort(owner="ArkDeck", repo="ArkDeck", _send=RealIssue()
                       ).bound_to_issue(7)
        self.assertTrue(port.close_issue(7))

    def test_an_unbound_port_refuses_every_mutation(self):
        """Deny by default: the previous None-means-unrestricted default made
        this guard a no-op everywhere except its own tests."""
        port = self._port()
        self.assertIsNone(port.owned_pull)
        self.assertIsNone(port.owned_issue)
        with self.assertRaisesRegex(RouteViolation, r"not bound to a pull request"):
            port.update_pull(999, body="somebody else's PR")
        with self.assertRaisesRegex(RouteViolation, r"not bound to an Issue"):
            port.update_issue(999, body="x")
        with self.assertRaisesRegex(RouteViolation, r"not bound to an Issue"):
            port.close_issue(999)

    def test_binding_rejects_a_nonsense_number(self):
        for bad in (0, -1, None, "21", 3.0):
            with self.subTest(bad=bad):
                with self.assertRaises(RouteViolation):
                    self._port().bound_to_pull(bad)
                with self.assertRaises(RouteViolation):
                    self._port().bound_to_issue(bad)

    def test_a_bound_port_shares_the_route_log(self):
        """Binding must not fork the inventory, or the negative proof loses calls."""
        port = self._port()
        bound = port.bound_to_pull(21)
        self.assertIs(bound.route_log, port.route_log)
        bound.update_pull(21, body="x")
        self.assertTrue(port.route_log, "the parent must see the bound port's call")

    def test_close_issue_refuses_a_pull_html_url(self):
        class PullUrl(FakeApi):
            def __call__(self, method, path, body):
                if method == "GET" and "/issues/" in path:
                    return 200, {"number": 9, "state": "open",
                                 "html_url": "https://github.com/A/R/pull/9"}
                return super().__call__(method, path, body)
        port = ApiPort(owner="ArkDeck", repo="ArkDeck", _send=PullUrl()
                       ).bound_to_issue(9)
        with self.assertRaisesRegex(RouteViolation, r"pull-request html_url"):
            port.close_issue(9)

    def test_pr_update_is_confined_to_the_owned_number(self):
        port = self._port(owned_pull=21)
        port.update_pull(21, body="ok")
        with self.assertRaisesRegex(RouteViolation, r"confined to #21"):
            port.update_pull(999, body="somebody else's PR")

    def test_issue_update_is_confined_to_the_owned_number(self):
        port = self._port(owned_issue=7)
        port.update_issue(7, body="ok")
        with self.assertRaises(RouteViolation):
            port.update_issue(8, body="nope")

    def test_capability_counter_flags_a_route_outside_the_allowlist(self):
        port = self._port()
        port.route_log.append(transport_mod.Route(
            "PATCH", "/repos/{owner}/{repo}/branches/main/protection", "smuggled"))
        self.assertEqual(transport_mod.forbidden_capability_count(port), 1)

    def test_capability_counter_flags_a_route_with_no_forbidden_keyword(self):
        """The counter must key on the allowlist, not on suspicious words.

        A substring scan misses any route whose template contains none of the
        watch words, which is precisely how the previous implementation reported
        0 while an out-of-scope call had been made.
        """
        port = self._port()
        port.route_log.append(transport_mod.Route(
            "GET", "/repos/{owner}/{repo}/collaborators", "no watch word here"))
        self.assertEqual(transport_mod.forbidden_capability_count(port), 1)

    def test_non_success_status_is_not_treated_as_applied(self):
        class Redirect(FakeApi):
            def __call__(self, method, path, body):
                return 301, {"message": "Moved Permanently"}
        port = ApiPort(owner="ArkDeck", repo="ArkDeck", _send=Redirect())
        with self.assertRaises(TransportError):
            port.update_pull(1, body="x")


class PullLookupPagination(unittest.TestCase):
    """A truncated first page must never read as "no PR exists"."""

    def test_head_filter_and_pagination_are_used(self):
        fake = FakeApi(pulls=[pull(21)])
        found = api_port(fake).list_open_pulls_for_head(
            task_branch(TASK).removeprefix("refs/heads/"))
        self.assertEqual([p["number"] for p in found], [21])
        path = [c[1] for c in fake.calls if c[0] == "GET" and "/pulls" in c[1]][0]
        self.assertIn("head=ArkDeck:", path)
        self.assertIn("per_page=100", path)

    def test_target_beyond_the_first_page_is_still_found(self):
        head = task_branch(TASK).removeprefix("refs/heads/")
        filler = [pull(n, head="agent/host-loop/tasks/OTHER") for n in range(100, 200)]
        found = api_port(FakeApi(pulls=filler + [pull(21)])).list_open_pulls_for_head(head)
        self.assertEqual([p["number"] for p in found], [21],
                         "the server-side head filter must not depend on page position")

    def test_a_target_on_the_second_page_is_still_found(self):
        """A full first page must be followed, not truncated.

        The head filter alone is not enough: with more than per_page matching
        PRs the target sits on page two, and breaking after one page would
        report zero matches and open a duplicate.
        """
        head = task_branch(TASK).removeprefix("refs/heads/")

        class TwoPages(FakeApi):
            def __call__(self, method, path, body):
                if method == "GET" and path.split("?")[0].endswith("/pulls"):
                    page = 1
                    for item in path.split("?", 1)[1].split("&"):
                        if item.startswith("page="):
                            page = int(item[len("page="):])
                    if page == 1:
                        return 200, [pull(1000 + n, head=head) for n in range(100)]
                    if page == 2:
                        return 200, [pull(21, head=head)]
                    return 200, []
                return super().__call__(method, path, body)

        found = ApiPort(owner="ArkDeck", repo="ArkDeck", _send=TwoPages()
                        ).list_open_pulls_for_head(head)
        self.assertIn(21, [p["number"] for p in found],
                      "the second page must be fetched")
        self.assertEqual(len(found), 101)

    def test_a_foreign_head_in_the_result_set_is_refused(self):
        class Sloppy(FakeApi):
            def __call__(self, method, path, body):
                if method == "GET" and path.split("?")[0].endswith("/pulls"):
                    return 200, [pull(5, head="agent/host-loop/tasks/SOMETHING-ELSE")]
                return super().__call__(method, path, body)
        with self.assertRaisesRegex(TransportError, r"different head"):
            ApiPort(owner="ArkDeck", repo="ArkDeck", _send=Sloppy()
                    ).list_open_pulls_for_head("agent/host-loop/tasks/TASK-DEMO-001")


class TwoWorkersAcquire(unittest.TestCase):
    def test_second_acquire_loses_the_fence(self):
        remote = FakeRemote()
        first, _ = manager(remote, run="run-A")
        second, _ = manager(remote, run="run-B")
        held = first.acquire(TASK, BASE)
        self.assertEqual(remote.refs[lease_ref(TASK)], held.ref_oid)
        with self.assertRaises(FenceLost):
            second.acquire(TASK, BASE)
        # the winner's ref is untouched
        self.assertEqual(remote.refs[lease_ref(TASK)], held.ref_oid)

    def test_loser_cannot_write_after_losing(self):
        remote = FakeRemote()
        first, _ = manager(remote, run="run-A")
        second, _ = manager(remote, run="run-B")
        held_a = first.acquire(TASK, BASE)
        held_b_stale = lease_mod.HeldLease(held_a.record, held_a.ref_oid)
        first.renew(held_a)  # advances the ref
        with self.assertRaises(FenceLost):
            second.assert_still_held(held_b_stale, remote.read_record)


class StaleFenceWrite(unittest.TestCase):
    def test_cas_on_stale_oid_is_rejected(self):
        remote = FakeRemote()
        mgr, _ = manager(remote)
        held = mgr.acquire(TASK, BASE)
        fresh = mgr.renew(held)
        self.assertNotEqual(fresh.ref_oid, held.ref_oid)
        with self.assertRaises(FenceLost):
            mgr.renew(held)  # replay the stale handle

    def test_fence_is_strictly_monotonic(self):
        remote = FakeRemote()
        mgr, _ = manager(remote)
        held = mgr.acquire(TASK, BASE)
        second = mgr.renew(held)
        third = mgr.renew(second)
        self.assertEqual([held.record.fence, second.record.fence, third.record.fence],
                         [1, 2, 3])

    def test_pre_write_gate_detects_oid_move_with_same_owner_and_fence(self):
        """The exact-OID check must be load-bearing on its own.

        Owner and fence are deliberately identical here, so only the OID
        comparison can catch the replay (mutation: prewrite-oid-check-removed).
        """
        remote = FakeRemote()
        mgr, _ = manager(remote, run="run-A")
        held = mgr.acquire(TASK, BASE)
        replayed_oid = remote.write_commit(held.record.serialize(), None)
        self.assertNotEqual(replayed_oid, held.ref_oid)
        remote.refs[lease_ref(TASK)] = replayed_oid
        observed, oid = mgr.observe(TASK, remote.read_record)
        self.assertEqual(observed.owner_run, held.record.owner_run)
        self.assertEqual(observed.fence, held.record.fence)
        self.assertNotEqual(oid, held.ref_oid)
        with self.assertRaisesRegex(FenceLost, r"lease OID moved"):
            mgr.assert_still_held(held, remote.read_record)

    def test_takeover_detects_oid_move_with_unchanged_fence(self):
        """Fence equality must not be able to mask an OID move.

        (mutation: takeover-skips-oid-match)
        """
        remote = FakeRemote()
        owner_a, _ = manager(remote, run="run-A")
        owner_b, clock_b = manager(remote, run="run-B")
        held = owner_a.acquire(TASK, BASE)
        clock_b["t"] = held.record.expires_at + 1
        observed, observed_oid = owner_b.observe(TASK, remote.read_record)
        rewritten = remote.write_commit(observed.serialize(), None)
        remote.refs[lease_ref(TASK)] = rewritten
        self.assertNotEqual(rewritten, observed_oid)
        with self.assertRaisesRegex(FenceLost, r"advanced during takeover"):
            owner_b.takeover(TASK, observed, observed_oid,
                             pr_identity_requeried=True, read_record=remote.read_record)

    def test_pre_write_gate_detects_foreign_owner_at_identical_oid(self):
        """Owner check must be load-bearing where the OID has NOT moved.

        B inspects A's still-current handle: the ref OID matches exactly, so
        only the owner comparison can refuse (mutation:
        prewrite-owner-check-removed).
        """
        remote = FakeRemote()
        owner_a, _ = manager(remote, run="run-A")
        owner_b, _ = manager(remote, run="run-B")
        held_a = owner_a.acquire(TASK, BASE)
        self.assertEqual(remote.refs[lease_ref(TASK)], held_a.ref_oid)
        with self.assertRaisesRegex(FenceLost, r"lease owner is now"):
            owner_b.assert_still_held(held_a, remote.read_record)

    def test_takeover_rejects_a_fabricated_observed_fence(self):
        """Fence equality is checked against the freshly re-read record.

        The OID is correct here, so only the fence comparison can refuse
        (mutation: takeover-skips-fence-match).
        """
        remote = FakeRemote()
        owner_a, _ = manager(remote, run="run-A")
        owner_b, clock_b = manager(remote, run="run-B")
        held = owner_a.acquire(TASK, BASE)
        clock_b["t"] = held.record.expires_at + 1
        observed, observed_oid = owner_b.observe(TASK, remote.read_record)
        fabricated = lease_mod.replace(observed, fence=observed.fence + 5)
        with self.assertRaisesRegex(FenceLost, r"fence no longer matches"):
            owner_b.takeover(TASK, fabricated, observed_oid,
                             pr_identity_requeried=True, read_record=remote.read_record)

    def test_pre_write_gate_detects_owner_change(self):
        remote = FakeRemote()
        owner_a, _ = manager(remote, run="run-A")
        owner_b, clock_b = manager(remote, run="run-B")
        held = owner_a.acquire(TASK, BASE)
        # B takes over after expiry
        clock_b["t"] = held.record.expires_at + 1
        observed = owner_b.observe(TASK, remote.read_record)
        assert observed
        owner_b.takeover(TASK, observed[0], observed[1],
                         pr_identity_requeried=True, read_record=remote.read_record)
        with self.assertRaises(FenceLost):
            owner_a.assert_still_held(held, remote.read_record)


class CreatedPullReadback(unittest.TestCase):
    """confirm_created_pull re-confirms every identity field after create."""

    def setUp(self):
        self.ident = PRIdentity(TASK, BASE, task_branch(TASK).removeprefix("refs/heads/"))

    def test_head_oid_mismatch_is_refused(self):
        api = api_port(FakeApi(pulls=[pull(21)]))  # head sha == HEAD
        with self.assertRaisesRegex(ReconcileRequired, r"head OID"):
            identity_mod.confirm_created_pull(
                api, self.ident, envelope_reader(), expected_head_oid="e" * 40)

    def test_matching_readback_is_accepted(self):
        api = api_port(FakeApi(pulls=[pull(21)]))
        got = identity_mod.confirm_created_pull(
            api, self.ident, envelope_reader(), expected_head_oid=HEAD)
        self.assertEqual(got["number"], 21)

    def test_merged_readback_is_refused(self):
        api = api_port(FakeApi(pulls=[pull(21, merged=True)]))
        with self.assertRaisesRegex(ReconcileRequired, r"merged"):
            identity_mod.confirm_created_pull(
                api, self.ident, envelope_reader(), expected_head_oid=HEAD)

    def test_auto_merge_readback_is_refused(self):
        api = api_port(FakeApi(pulls=[pull(21, auto_merge={"enabled_by": "x"})]))
        with self.assertRaisesRegex(ReconcileRequired, r"auto_merge"):
            identity_mod.confirm_created_pull(
                api, self.ident, envelope_reader(), expected_head_oid=HEAD)

    def test_missing_pull_after_create_is_refused(self):
        api = api_port(FakeApi(pulls=[]))
        with self.assertRaises(ReconcileRequired):
            identity_mod.confirm_created_pull(
                api, self.ident, envelope_reader(), expected_head_oid=HEAD)


class HeartbeatLoss(unittest.TestCase):
    def test_expired_lease_blocks_writes_by_the_old_owner(self):
        remote = FakeRemote()
        mgr, clock = manager(remote)
        held = mgr.acquire(TASK, BASE)
        clock["t"] = held.record.expires_at + 1
        with self.assertRaises(FenceLost):
            mgr.assert_still_held(held, remote.read_record)

    def test_takeover_requires_expiry(self):
        remote = FakeRemote()
        owner_a, _ = manager(remote, run="run-A")
        owner_b, _ = manager(remote, run="run-B")
        owner_a.acquire(TASK, BASE)
        observed = owner_b.observe(TASK, remote.read_record)
        assert observed
        with self.assertRaises(FenceLost):
            owner_b.takeover(TASK, observed[0], observed[1],
                             pr_identity_requeried=True, read_record=remote.read_record)

    def test_takeover_requires_pr_identity_requery(self):
        remote = FakeRemote()
        owner_a, _ = manager(remote, run="run-A")
        owner_b, clock_b = manager(remote, run="run-B")
        held = owner_a.acquire(TASK, BASE)
        clock_b["t"] = held.record.expires_at + 1
        observed = owner_b.observe(TASK, remote.read_record)
        assert observed
        with self.assertRaises(LeaseError):
            owner_b.takeover(TASK, observed[0], observed[1],
                             pr_identity_requeried=False, read_record=remote.read_record)

    def test_takeover_refuses_when_ref_advanced_underneath(self):
        remote = FakeRemote()
        owner_a, _ = manager(remote, run="run-A")
        owner_b, clock_b = manager(remote, run="run-B")
        held = owner_a.acquire(TASK, BASE)
        clock_b["t"] = held.record.expires_at + 1
        observed = owner_b.observe(TASK, remote.read_record)
        assert observed
        owner_a.renew(held)  # original owner woke up and advanced the ref
        with self.assertRaises(FenceLost):
            owner_b.takeover(TASK, observed[0], observed[1],
                             pr_identity_requeried=True, read_record=remote.read_record)

    def test_expiry_uses_injected_clock_not_wall_clock(self):
        remote = FakeRemote()
        mgr, clock = manager(remote, now=5000, ttl=60)
        held = mgr.acquire(TASK, BASE)
        self.assertEqual(held.record.expires_at, 5060)
        clock["t"] = 5059
        self.assertFalse(mgr.is_expired(held.record))
        clock["t"] = 5060
        self.assertTrue(mgr.is_expired(held.record))


class RecordCorruption(unittest.TestCase):
    def test_unparsable_record_is_refused(self):
        remote = FakeRemote()
        mgr, _ = manager(remote)
        held = mgr.acquire(TASK, BASE)
        remote.commits[held.ref_oid] = "{not json"
        with self.assertRaises(LeaseError):
            mgr.observe(TASK, remote.read_record)

    def test_schema_mismatch_is_refused(self):
        with self.assertRaises(LeaseError):
            LeaseRecord.parse('{"schema":"other/v1"}')

    def test_task_mismatch_between_ref_and_record_is_refused(self):
        remote = FakeRemote()
        mgr, _ = manager(remote)
        held = mgr.acquire(TASK, BASE)
        other = LeaseRecord(task_id="TASK-OTHER-001", base_oid=BASE, owner_run="run-1",
                            fence=1, expires_at=9999,
                            pr_branch=task_branch("TASK-OTHER-001"), pr_number=None,
                            create_attempted=False, checks_dispatched_head=None, previous_lease_oid=None)
        remote.commits[held.ref_oid] = other.serialize()
        with self.assertRaises(LeaseError):
            mgr.observe(TASK, remote.read_record)

    def test_pr_number_without_create_intent_is_refused(self):
        with self.assertRaises(LeaseError):
            LeaseRecord(task_id=TASK, base_oid=BASE, owner_run="r", fence=1,
                        expires_at=1, pr_branch=task_branch(TASK), pr_number=5,
                        create_attempted=False, checks_dispatched_head=None, previous_lease_oid=None).validate()

    def test_pr_branch_must_match_task(self):
        with self.assertRaises(LeaseError):
            LeaseRecord(task_id=TASK, base_oid=BASE, owner_run="r", fence=1,
                        expires_at=1, pr_branch="refs/heads/agent/host-loop/tasks/OTHER",
                        pr_number=None, create_attempted=False,
                        checks_dispatched_head=None, previous_lease_oid=None).validate()


# ---------------------------------------------------------- PR identity faults

class PullLookupFaults(unittest.TestCase):
    def setUp(self):
        self.ident = PRIdentity(TASK, BASE, task_branch(TASK).removeprefix("refs/heads/"))

    def test_two_matching_pulls_stop_the_lane(self):
        api = api_port(FakeApi(pulls=[pull(1), pull(2)]))
        # Assert the *duplicate-identity* reason specifically: a generic refusal
        # from the non-matching-candidate fallback would let a removed
        # duplicate check pass unnoticed (mutation: duplicate-pr-allowed).
        with self.assertRaisesRegex(ReconcileRequired, r"2 open PRs share the identity"):
            resolve_pull(api, self.ident, envelope_reader(), create_attempted=False)

    def test_two_matching_pulls_stop_even_after_a_create_attempt(self):
        api = api_port(FakeApi(pulls=[pull(1), pull(2)]))
        with self.assertRaisesRegex(ReconcileRequired, r"share the identity"):
            resolve_pull(api, self.ident, envelope_reader(), create_attempted=True)

    def test_zero_pulls_after_create_attempt_stops(self):
        api = api_port(FakeApi(pulls=[]))
        with self.assertRaises(ReconcileRequired):
            resolve_pull(api, self.ident, envelope_reader(), create_attempted=True)

    def test_zero_pulls_without_create_attempt_creates(self):
        api = api_port(FakeApi(pulls=[]))
        res = resolve_pull(api, self.ident, envelope_reader(), create_attempted=False)
        self.assertEqual(res.action, "create")

    def test_single_match_is_adopted(self):
        api = api_port(FakeApi(pulls=[pull(11)]))
        res = resolve_pull(api, self.ident, envelope_reader(), create_attempted=True)
        self.assertEqual((res.action, res.pull["number"]), ("adopt", 11))

    def test_non_matching_envelope_on_same_head_refuses_second_pr(self):
        api = api_port(FakeApi(pulls=[pull(3, body="no envelope here")]))
        with self.assertRaises(ReconcileRequired):
            resolve_pull(api, self.ident, envelope_reader(), create_attempted=False)

    def test_identity_ignores_title_and_uses_task_plus_base_oid(self):
        api = api_port(FakeApi(pulls=[pull(4)]))
        wrong_base = envelope_reader(base="c" * 40)
        with self.assertRaises(ReconcileRequired):
            resolve_pull(api, self.ident, wrong_base, create_attempted=False)

    def test_wrong_base_ref_is_not_a_match(self):
        api = api_port(FakeApi(pulls=[pull(6, base_ref="release")]))
        with self.assertRaises(ReconcileRequired):
            resolve_pull(api, self.ident, envelope_reader(), create_attempted=True)


class MalformedPayloads(unittest.TestCase):
    """A null field must fail closed, not raise AttributeError."""

    def test_null_base_does_not_crash_the_matcher(self):
        ident = PRIdentity(TASK, BASE, task_branch(TASK).removeprefix("refs/heads/"))
        head = task_branch(TASK).removeprefix("refs/heads/")
        malformed = {"number": 9, "state": "open", "head": {"ref": head, "sha": HEAD},
                     "base": None, "body": "ENVELOPE"}

        class NullBase(FakeApi):
            def __call__(self, method, path, body):
                if method == "GET" and path.split("?")[0].endswith("/pulls"):
                    return 200, [malformed]
                return super().__call__(method, path, body)

        api = ApiPort(owner="ArkDeck", repo="ArkDeck", _send=NullBase())
        # No AttributeError: a null base simply fails the identity match, so the
        # lane sees "no identity match" rather than crashing.
        with self.assertRaises(ReconcileRequired):
            resolve_pull(api, ident, envelope_reader(), create_attempted=True)

    def test_null_head_does_not_crash_the_matcher(self):
        ident = PRIdentity(TASK, BASE, task_branch(TASK).removeprefix("refs/heads/"))
        malformed = {"number": 9, "state": "open", "head": None,
                     "base": {"ref": "main"}, "body": "ENVELOPE"}

        class NullHead(FakeApi):
            def __call__(self, method, path, body):
                if method == "GET" and path.split("?")[0].endswith("/pulls"):
                    return 200, [malformed]
                return super().__call__(method, path, body)

        with self.assertRaises(TransportError):
            ApiPort(owner="ArkDeck", repo="ArkDeck", _send=NullHead()
                    ).list_open_pulls_for_head(
                        task_branch(TASK).removeprefix("refs/heads/"))


class MergeConfirmation(unittest.TestCase):
    def test_nullable_merge_sha_cannot_advance_the_cursor(self):
        with self.assertRaises(ReconcileRequired):
            identity_mod.confirm_merge({"merged": True, "merge_commit_sha": None},
                                       lambda oid: True)

    def test_metadata_alone_is_insufficient(self):
        with self.assertRaises(ReconcileRequired):
            identity_mod.confirm_merge({"merged": True, "merge_commit_sha": "d" * 40},
                                       lambda oid: False)

    def test_both_sources_required(self):
        oid = identity_mod.confirm_merge(
            {"merged": True, "merge_commit_sha": "d" * 40}, lambda o: True)
        self.assertEqual(oid, "d" * 40)

    def test_unmerged_is_refused(self):
        with self.assertRaises(ReconcileRequired):
            identity_mod.confirm_merge({"merged": False, "merge_commit_sha": "d" * 40},
                                       lambda oid: True)


class CreateTimeout(unittest.TestCase):
    def test_intent_is_recorded_before_create(self):
        remote = FakeRemote()
        mgr, _ = manager(remote)
        held = mgr.acquire(TASK, BASE)
        self.assertFalse(held.record.create_attempted)
        marked = mgr.mark_create_attempted(held)
        self.assertTrue(marked.record.create_attempted)
        # durable: a fresh observation sees the intent
        record, _oid = mgr.observe(TASK, remote.read_record)
        self.assertTrue(record.create_attempted)

    def test_timed_out_create_never_becomes_a_second_pr(self):
        remote = FakeRemote()
        mgr, _ = manager(remote)
        held = mgr.mark_create_attempted(mgr.acquire(TASK, BASE))
        record, _ = mgr.observe(TASK, remote.read_record)
        api = api_port(FakeApi(pulls=[]))  # create response was lost
        ident = PRIdentity(TASK, BASE, task_branch(TASK).removeprefix("refs/heads/"))
        with self.assertRaises(ReconcileRequired):
            resolve_pull(api, ident, envelope_reader(),
                         create_attempted=record.create_attempted)

    def test_ambiguous_push_is_reported_not_retried(self):
        """An ambiguous push is NOT a fence loss (F4).

        The ref may or may not exist afterwards, so the lane must demand
        reconciliation rather than concluding another owner won. Reporting it as
        FenceLost would let a network fault masquerade as proof of fencing.
        """
        remote = FakeRemote()
        mgr, _ = manager(remote)
        remote.fail_next_with = "fatal: unable to access: timeout"
        with self.assertRaises(LeaseError) as caught:
            mgr.acquire(TASK, BASE)
        self.assertNotIsInstance(caught.exception, FenceLost)
        self.assertIn("reconcile", str(caught.exception))
        self.assertEqual(len(remote.pushes), 1, "must not blind-retry an ambiguous push")

    def test_clean_precondition_refusal_is_a_fence_loss(self):
        """A server precondition refusal IS admissible as fence-loss evidence."""
        remote = FakeRemote()
        first, _ = manager(remote, run="run-A")
        second, _ = manager(remote, run="run-B")
        first.acquire(TASK, BASE)
        with self.assertRaises(FenceLost):
            second.acquire(TASK, BASE)


class RefPortSemantics(unittest.TestCase):
    def test_create_uses_empty_lease_expectation(self):
        remote = FakeRemote()
        refs = RefPort(remote="origin", _run=remote.run)
        refs.create("refs/heads/agent/host-loop/leases/T-001", "1" * 40)
        argv = remote.pushes[-1]
        self.assertIn("--force-with-lease=refs/heads/agent/host-loop/leases/T-001:", argv)
        self.assertIn("--atomic", argv)

    def test_create_fails_when_ref_exists(self):
        remote = FakeRemote()
        refs = RefPort(remote="origin", _run=remote.run)
        refs.create("refs/heads/agent/host-loop/leases/T-001", "1" * 40)
        with self.assertRaises(TransportError):
            refs.create("refs/heads/agent/host-loop/leases/T-001", "2" * 40)

    def test_cas_requires_changed_oid(self):
        remote = FakeRemote()
        refs = RefPort(remote="origin", _run=remote.run)
        with self.assertRaises(TransportError):
            refs.compare_and_swap("refs/heads/agent/host-loop/leases/T-001",
                                  "1" * 40, "1" * 40)

    def test_delete_carries_expected_oid(self):
        remote = FakeRemote()
        refs = RefPort(remote="origin", _run=remote.run)
        ref = "refs/heads/agent/host-loop/leases/T-001"
        refs.create(ref, "1" * 40)
        refs.delete(ref, "1" * 40)
        self.assertNotIn(ref, remote.refs)
        self.assertIn(f"--force-with-lease={ref}:{'1' * 40}", remote.pushes[-1])

    def test_read_returns_none_for_absent_ref(self):
        remote = FakeRemote()
        refs = RefPort(remote="origin", _run=remote.run)
        self.assertIsNone(refs.read("refs/heads/agent/host-loop/leases/absent"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
