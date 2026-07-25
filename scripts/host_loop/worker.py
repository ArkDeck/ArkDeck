"""Host-loop worker `--once` state machine (TASK-HLR-003 draft).

design §4:

    discover -> leaseHeld -> branchPrepared -> prOpen -> checksGreen
              -> reviewRequested -> ... (TASK-HLR-004 owns everything past checksGreen)

    any uncertainty/fence mismatch/API ambiguity -> reconcileRequired (no next dispatch)
    review REQUEST_CHANGES/BLOCKED                -> workerPaused

Hard rules encoded here:

* only approved + `ready` + host-only tasks are claimed, and only after
  dependencies, allowed paths, base pin and decision grade all validate;
* a D1/D2 task is never started — the worker writes a factual blocking record
  and stops, rather than doing gated work to stay busy;
* green CI is never merge permission and never advances anything by itself;
* the lease is re-confirmed immediately before every external write;
* `reconcileRequired` terminates the round with no further dispatch.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from enum import Enum
from typing import Callable

from .cursor import CursorError, CursorState, Truth
from .identity import PRIdentity, ReconcileRequired, resolve_pull
from .lease import FenceLost, HeldLease, LeaseError, LeaseManager, lease_ref, task_branch
from .transport import ApiPort, TransportError


class SelectionOutcome(str, Enum):
    """Why discovery did or did not pick a task. Machine-checkable on purpose.

    The round used to branch on substrings of a human-readable reason, so
    rewording a message silently changed the resulting state.
    """

    CLAIMABLE = "claimable"
    CHANGE_NOT_APPROVED = "changeNotApproved"
    ONLY_GATED_READY = "onlyGatedReady"
    ONLY_NEVER_CLAIM_READY = "onlyNeverClaimReady"
    NOTHING_READY = "nothingReady"


class WorkerState(str, Enum):
    DISCOVER = "discover"
    LEASE_HELD = "leaseHeld"
    BRANCH_PREPARED = "branchPrepared"
    PR_OPEN = "prOpen"
    CHECKS_GREEN = "checksGreen"
    RECONCILE_REQUIRED = "reconcileRequired"
    WORKER_PAUSED = "workerPaused"
    IDLE = "idle"
    BLOCKED_RECORDED = "blockedRecorded"


# States that terminate a round without dispatching anything further.
TERMINAL_NO_DISPATCH = frozenset(
    {WorkerState.RECONCILE_REQUIRED, WorkerState.WORKER_PAUSED,
     WorkerState.BLOCKED_RECORDED, WorkerState.IDLE}
)

# Checks that must exist on a task PR head before the round may call them green.
# `allowed-paths` is the MECH-004 path contract; `guard` is the SDD consistency
# check. Both are produced by sdd-guard.yml.
REQUIRED_PR_CHECKS = ("guard", "allowed-paths")

# Marker appended to the human-text half of the envelope body to make a check
# dispatch update a real byte change. It never appears inside the machine block.
DISPATCH_MARKER = "Check-Dispatch"

DISPATCHABLE_GRADES = frozenset({"D0"})
GATED_GRADES = frozenset({"D1", "D2"})

# The TASK-HLR-003 readiness makes this task itself a ready host-only task the
# moment it merges. Claiming it would open a PR against work a human is already
# implementing, so discovery excludes it unconditionally. Widening this set is a
# governance change, not a configuration tweak.
NEVER_CLAIM_ROOTS = frozenset({"TASK-HLR-003"})

# Matched after normalisation so a suffixed sibling cannot slip through. The
# repo's grammar (and this PR's parity test) admits TASK-HLR-003A and
# TASK-HLR-003R, and an exact-string frozenset would have claimed both.
_NEVER_CLAIM_RE = re.compile(
    r"\A(?:" + "|".join(re.escape(r) for r in sorted(NEVER_CLAIM_ROOTS)) + r")[A-Z]?\Z"
)


def is_never_claim(task_id: str) -> bool:
    """True when discovery must skip this task regardless of its status."""
    if not isinstance(task_id, str):
        return True
    return bool(_NEVER_CLAIM_RE.match(task_id.strip().upper()))


@dataclass(frozen=True)
class TaskCandidate:
    task_id: str
    status: str
    decision_grade: str
    hardware_required: bool
    dependencies: tuple[str, ...]
    allowed_paths: tuple[str, ...]
    base_pin: str | None


@dataclass(frozen=True)
class RoundResult:
    state: WorkerState
    task_id: str | None
    detail: str
    pr_number: int | None = None
    outcome: SelectionOutcome | None = None

    @property
    def dispatched(self) -> bool:
        return self.state not in TERMINAL_NO_DISPATCH


class Worker:
    """One `--once` round. Construct fresh per round; hold no cross-round state."""

    def __init__(
        self,
        api: ApiPort,
        leases: LeaseManager,
        *,
        change_approved: Callable[[str], bool],
        done_tasks: Callable[[], frozenset[str]],
        read_envelope,
        read_lease_record,
        prepare_branch: Callable[[TaskCandidate, str], str],
        render_body: Callable[[TaskCandidate, str, str], str],
        now: Callable[[], int],
        dispatch_token: Callable[[], str] | None = None,
        cursor_issue: int | None = None,
        cursor_body: str | None = None,
    ) -> None:
        self._api = api
        self._leases = leases
        self._change_approved = change_approved
        self._done_tasks = done_tasks
        self._read_envelope = read_envelope
        self._read_lease_record = read_lease_record
        self._prepare_branch = prepare_branch
        self._render_body = render_body
        self._now = now
        # A per-second token is not enough: two rounds in the same second render
        # byte-identical bodies, GitHub emits no `edited`, and allowed-paths never
        # runs. The counter guarantees a distinct body per dispatch.
        self._dispatch_counter = 0
        self._dispatch_token = dispatch_token or self._default_dispatch_token
        # Derived, never supplied: the lease manager owns this identity. A
        # second independently-passed copy could disagree with it and the
        # mismatch was silent.
        self._owner_run = leases.owner_run
        self._cursor_issue = cursor_issue
        self._cursor_body = cursor_body

    def _default_dispatch_token(self) -> str:
        self._dispatch_counter += 1
        return f"{self._now()}-{self._dispatch_counter}"

    # -- discovery --------------------------------------------------------
    def select(
        self, candidates: list[TaskCandidate], change_id: str, main_oid: str
    ) -> tuple[TaskCandidate | None, SelectionOutcome, str]:
        """Pick at most one claimable task, or explain why none is claimable."""
        if not self._change_approved(change_id):
            return (None, SelectionOutcome.CHANGE_NOT_APPROVED,
                    f"change {change_id} is not approved; zero dispatch")

        done = self._done_tasks()
        gated: list[str] = []
        for candidate in candidates:
            if is_never_claim(candidate.task_id):
                continue  # readiness self-claim stop
            if not candidate.status.startswith("ready"):
                continue
            if candidate.hardware_required:
                continue  # device work is never host-loop dispatchable
            missing = [d for d in candidate.dependencies if d not in done]
            if missing:
                continue
            if not candidate.allowed_paths:
                continue  # a task with no declared allowed paths is never claimed
            if candidate.base_pin is not None and candidate.base_pin != main_oid:
                continue  # base pin drifted; re-readiness, not a claim
            if candidate.decision_grade in GATED_GRADES:
                gated.append(candidate.task_id)
                continue
            if candidate.decision_grade not in DISPATCHABLE_GRADES:
                continue
            return candidate, SelectionOutcome.CLAIMABLE, "claimable"

        if gated:
            return (None, SelectionOutcome.ONLY_GATED_READY,
                    f"only gated tasks are ready ({sorted(gated)}); a D1/D2 gate is "
                    "not confirmed, so the worker records the block and starts nothing")
        if any(is_never_claim(c.task_id) for c in candidates):
            excluded = sorted(c.task_id for c in candidates if is_never_claim(c.task_id))
            return (None, SelectionOutcome.ONLY_NEVER_CLAIM_READY,
                    f"only never-claim tasks are ready ({excluded}); discovery "
                    "excludes this task's own implementation by readiness rule")
        return None, SelectionOutcome.NOTHING_READY, "no ready host-only task"

    # -- the round --------------------------------------------------------
    def _dispatch_checks(self, number, candidate, base_oid, head_oid):
        """Regenerate the whole body with a dispatch marker to fire `edited`.

        design §2 requires a body update to regenerate the entire template and to
        write only when the canonical bytes change. The machine block is
        regenerated unchanged; the marker lands in the human-text half, so the
        bytes do change exactly once per dispatch and the envelope stays
        canonical.
        """
        body = self._render_body(candidate, base_oid, head_oid)
        marker = f"{DISPATCH_MARKER}: {self._dispatch_token()}"
        if DISPATCH_MARKER in body:
            raise ReconcileRequired(
                "rendered envelope already contains a dispatch marker; refusing "
                "to nest markers"
            )
        # Bind to exactly this PR before mutating it. Without the binding the
        # port refuses, so the ownership guard is now on the production path
        # rather than only in its own tests.
        self._api.bound_to_pull(number).update_pull(number, body=f"{body}\n{marker}\n")

    def run_once(
        self,
        candidates: list[TaskCandidate],
        change_id: str,
        main_oid: str,
        cursor_state: CursorState,
        truth: Truth,
    ) -> RoundResult:
        try:
            return self._round(candidates, change_id, main_oid, cursor_state, truth)
        except (FenceLost, LeaseError, ReconcileRequired, CursorError,
                TransportError) as error:
            # Every ambiguity funnels here. No retry, no second PR, no dispatch.
            return RoundResult(WorkerState.RECONCILE_REQUIRED, None, str(error))
        except Exception as error:  # noqa: BLE001
            # An unexpected shape must fail closed too. Listing only the five
            # known types meant a malformed payload (base: null, say) crashed the
            # process instead of stopping the lane.
            return RoundResult(
                WorkerState.RECONCILE_REQUIRED, None,
                f"unexpected {type(error).__name__} in round: {error}; "
                "treated as reconcile-required",
            )

    def _round(
        self,
        candidates: list[TaskCandidate],
        change_id: str,
        main_oid: str,
        cursor_state: CursorState,
        truth: Truth,
    ) -> RoundResult:
        from .cursor import rebuild_and_validate

        # The cursor is a cache: reconcile it against truth and KEEP the
        # reconciled value. Discarding it left the cache permanently stale, so
        # the next round conflicted against state it had never written.
        cursor_state = rebuild_and_validate(cursor_state, truth)

        candidate, outcome, reason = self.select(candidates, change_id, main_oid)
        if candidate is None:
            state = (
                WorkerState.BLOCKED_RECORDED
                if outcome in (SelectionOutcome.ONLY_GATED_READY,
                               SelectionOutcome.CHANGE_NOT_APPROVED)
                else WorkerState.IDLE
            )
            self._persist_cursor(cursor_state, main_oid, None, None, None)
            return RoundResult(state, None, reason, outcome=outcome)

        # --- lease acquisition / adoption / takeover -------------------------
        # The lease record is the single source of truth for the FROZEN base OID.
        # Rebuilding PR identity from whatever main happens to be now made the
        # worker stop recognising its own PR the moment main advanced — which in
        # this repository happens several times an hour — leaving the lane in
        # permanent reconcileRequired with create_attempted already set.
        observed = self._leases.observe(candidate.task_id, self._read_lease_record)
        frozen_base = main_oid if observed is None else observed[0].base_oid
        identity = PRIdentity(
            task_id=candidate.task_id,
            base_oid=frozen_base,
            head_branch=task_branch(candidate.task_id).removeprefix("refs/heads/"),
        )
        if observed is None:
            held = self._leases.acquire(candidate.task_id, main_oid)
            cursor_state = self._after_lease_write(
                cursor_state, main_oid, candidate.task_id, held)
        else:
            record, ref_oid = observed
            if record.owner_run == self._owner_run:
                # Our own lease from an earlier `--once` round. Adopt it by
                # bumping the fence; this is what makes round two progress
                # instead of colliding with the ref round one created.
                held = self._leases.renew(HeldLease(record, ref_oid))
                cursor_state = self._after_lease_write(
                    cursor_state, main_oid, candidate.task_id, held)
            elif not self._leases.is_expired(record):
                # Record that we hold nothing. Persisting the FOREIGN ref OID
                # wedged the lane: the cursor has no owner field, so it could not
                # express "someone else's lease", and rebuild_and_validate demands
                # byte equality — the moment that owner renewed, every later round
                # failed cursor validation instead of simply yielding.
                self._persist_cursor(cursor_state, main_oid, candidate.task_id,
                                     None, None)
                return RoundResult(
                    WorkerState.IDLE, candidate.task_id,
                    f"lease for {candidate.task_id} is held by live owner "
                    f"{record.owner_run!r}; no dispatch",
                    outcome=outcome,
                )
            else:
                # Expired foreign lease: re-query the stable PR identity first,
                # which is a mandatory takeover precondition.
                resolve_pull(self._api, identity, self._read_envelope,
                             create_attempted=record.create_attempted)
                held = self._leases.takeover(
                    candidate.task_id, record, ref_oid,
                    pr_identity_requeried=True,
                    read_record=self._read_lease_record,
                )
                cursor_state = self._after_lease_write(
                    cursor_state, main_oid, candidate.task_id, held)

        head_oid = self._prepare_branch(candidate, frozen_base)

        self._leases.assert_still_held(held, self._read_lease_record)
        resolution = resolve_pull(
            self._api, identity, self._read_envelope,
            create_attempted=held.record.create_attempted,
        )

        if resolution.action == "adopt":
            pull = resolution.pull
            assert pull is not None
            if held.record.pr_number != int(pull["number"]):
                held = self._leases.attach_pull(held, int(pull["number"]))
                cursor_state = self._after_lease_write(
                    cursor_state, main_oid, candidate.task_id, held,
                    pr_number=int(pull["number"]))
        else:
            held = self._leases.mark_create_attempted(held)
            cursor_state = self._after_lease_write(
                cursor_state, main_oid, candidate.task_id, held)
            self._leases.assert_still_held(held, self._read_lease_record)
            body = self._render_body(candidate, frozen_base, head_oid)
            self._api.create_pull(
                head=identity.head_branch, base="main",
                title=f"{candidate.task_id}: host-loop dispatch", body=body,
            )
            from .identity import confirm_created_pull

            pull = confirm_created_pull(
                self._api, identity, self._read_envelope, expected_head_oid=head_oid
            )
            held = self._leases.attach_pull(held, int(pull["number"]))
            cursor_state = self._after_lease_write(
                cursor_state, main_oid, candidate.task_id, held,
                pr_number=int(pull["number"]))

        number = int(pull["number"])

        # --- required checks, guarded by a persisted dispatch fact -----------
        # --- required checks -------------------------------------------------
        # Gated on the DURABLE fact, not on a name being absent. Absence was the
        # wrong trigger: the push run already publishes a `skipped` run named
        # `allowed-paths`, so nothing ever looked absent and the
        # `pull_request: edited` run that actually executes allowed-paths never
        # fired in production.
        checks = self._api.list_check_runs(head_oid)
        if (unsatisfied_required_checks(checks)
                and held.record.checks_dispatched_head != head_oid):
            self._leases.assert_still_held(held, self._read_lease_record)
            self._dispatch_checks(number, candidate, frozen_base, head_oid)
            held = self._leases.record_dispatch(held, head_oid)
            cursor_state = self._after_lease_write(
                cursor_state, main_oid, candidate.task_id, held,
                pr_number=number, pr_head=head_oid)
            checks = self._api.list_check_runs(head_oid)

        self._persist_cursor(cursor_state, main_oid, candidate.task_id,
                             lease_ref(candidate.task_id), held.ref_oid,
                             pr_number=number, pr_head=head_oid)

        verdict = classify_checks(checks)
        unsatisfied = unsatisfied_required_checks(checks)
        if verdict != "failed" and unsatisfied:
            return RoundResult(
                WorkerState.PR_OPEN, candidate.task_id,
                f"PR open; required checks not yet executed successfully: "
                f"{list(unsatisfied)}", number, outcome=outcome,
            )
        if verdict == "pending":
            return RoundResult(WorkerState.PR_OPEN, candidate.task_id,
                               "PR open; checks not yet terminal", number,
                               outcome=outcome)
        if verdict == "failed":
            return RoundResult(WorkerState.WORKER_PAUSED, candidate.task_id,
                               "checks failed; worker paused, no dispatch", number,
                               outcome=outcome)
        # The lease is deliberately NOT released here. design §4 releases it only
        # after mergeOIDConfirmed, which belongs to TASK-HLR-004; a task whose
        # checks are green is still unmerged and must keep its fence.
        return RoundResult(
            WorkerState.CHECKS_GREEN, candidate.task_id,
            "checks green — this is NOT merge permission; the maintainer merges",
            number, outcome=outcome,
        )

    def _after_lease_write(self, cursor_state, main_oid, task_id, held,
                           *, pr_number=None, pr_head=None):
        """design §3: every lease write updates the cursor with the new ref OID.

        Persisting only at round exit left the cursor behind the ref whenever a
        round aborted mid-way, and since rebuild_and_validate runs first and
        demands equality, the lane then wedged permanently. store() skips a
        no-op write, so calling this after each advance is cheap.
        """
        from .cursor import record_lease_write, store

        nxt = record_lease_write(cursor_state, lease_ref(held.record.task_id),
                                 held.ref_oid, self._now())
        nxt = self._persist_cursor(nxt, main_oid, task_id,
                                   lease_ref(held.record.task_id), held.ref_oid,
                                   pr_number=pr_number, pr_head=pr_head)
        return nxt

    def _persist_cursor(self, cursor_state, main_oid, task_id, lease_ref_name,
                        lease_oid, *, pr_number=None, pr_head=None):
        """Write the reconciled cursor back. store() skips a no-op write."""
        from .cursor import record_round, store

        nxt = record_round(
            cursor_state, main_oid=main_oid, candidate_task=task_id,
            lease_ref_name=lease_ref_name, lease_oid=lease_oid,
            pr_number=pr_number, pr_head=pr_head, observed_at=self._now(),
        )
        if self._cursor_issue is not None:
            store(self._api.bound_to_issue(self._cursor_issue), self._cursor_issue,
                  nxt, previous_body=self._cursor_body or "")
        return nxt


# Conclusions meaning "this check did not execute". On a REQUIRED name they must
# never count as success: sdd-guard.yml publishes an `allowed-paths` run with
# conclusion `skipped` on every push to agent/**, so accepting them returned
# CHECKS_GREEN on a head whose MECH-004 path contract was never evaluated. And
# because presence was decided by name alone, the same stub also meant the check
# dispatch never fired in production at all.
NON_EXECUTED_CONCLUSIONS = frozenset({"skipped", "neutral", None})


def required_verdicts(check_runs: list[dict]) -> dict[str, str]:
    """Single source of truth for required-check state.

    One of "success" | "failed" | "pending" per name in REQUIRED_PR_CHECKS,
    seeded to "pending" so an absent name — or a name whose only run did not
    execute — cannot read as satisfied. Several runs may share a name (the push
    run and the `pull_request` run both publish `guard`), and an executed
    success anywhere wins over a non-executed sibling.
    """
    verdicts = {name: "pending" for name in REQUIRED_PR_CHECKS}
    for run in check_runs:
        name = run.get("name")
        if name not in verdicts:
            continue
        if run.get("status") != "completed":
            continue
        conclusion = run.get("conclusion")
        if conclusion in NON_EXECUTED_CONCLUSIONS:
            continue
        if conclusion == "success":
            verdicts[name] = "success"
        elif verdicts[name] != "success":
            verdicts[name] = "failed"
    return verdicts


def unsatisfied_required_checks(check_runs: list[dict]) -> tuple[str, ...]:
    """Required names that have not yet executed successfully."""
    return tuple(sorted(
        name for name, verdict in required_verdicts(check_runs).items()
        if verdict != "success"
    ))


def classify_checks(check_runs: list[dict]) -> str:
    """'green' | 'pending' | 'failed', derived from that one mapping.

    Green requires every REQUIRED name to have executed successfully. Runs
    outside REQUIRED_PR_CHECKS (Swift CI, say) can still fail the round, but a
    skipped or neutral conclusion on a non-required run is not a failure.
    """
    verdicts = required_verdicts(check_runs)
    if "failed" in verdicts.values():
        return "failed"
    for run in check_runs:
        if run.get("name") in verdicts:
            continue
        if run.get("status") != "completed":
            return "pending"
        if run.get("conclusion") not in ("success", "neutral", "skipped"):
            return "failed"
    if any(v == "pending" for v in verdicts.values()):
        return "pending"
    return "green"
