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
from dataclasses import dataclass, replace
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

# A task whose implementation edits the loop's own code becomes a ready host-only
# task the moment its readiness merges. Claiming it would open a PR against work a
# human is already implementing, and for the navigation tasks it would additionally
# let the loop rewrite the gate that decides what it may claim. Discovery therefore
# excludes these roots unconditionally. Widening this set is a governance change,
# not a configuration tweak: every entry is authorised by that task's own readiness
# (TASK-HLR-003 r2; TASK-NAV-001 / TASK-NAV-002 r1, contract item 4;
# TASK-DEC-001..008 r1, CHG-2026-040 — every task in that change edits this
# loop's own code, tests or CI, and DEC-005/DEC-007 edit the claim gate itself).
NEVER_CLAIM_ROOTS = frozenset({
    "TASK-HLR-003", "TASK-NAV-001", "TASK-NAV-002",
    "TASK-DEC-001", "TASK-DEC-002", "TASK-DEC-003", "TASK-DEC-004",
    "TASK-DEC-005", "TASK-DEC-006", "TASK-DEC-007", "TASK-DEC-008",
})

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


def is_ready(status: str) -> bool:
    """The single reading of the Status field every claim gate agrees on.

    Extracted because two places tested readiness and only one of them was
    right: `rejection_reasons` used this prefix test while the never-claim
    branch of `select()` tested nothing at all, so a done never-claim task was
    still announced as "ready". One predicate cannot disagree with itself.
    """
    return isinstance(status, str) and status.startswith("ready")


@dataclass(frozen=True)
class TaskCandidate:
    task_id: str
    status: str
    decision_grade: str
    hardware_required: bool
    dependencies: tuple[str, ...]
    allowed_paths: tuple[str, ...]
    base_pin: str | None
    # Which change declared this task. A repo-wide round aggregates candidates
    # from every active change, and approval is a per-change fact, so the gate
    # needs to know which proposal to consult. Defaulted because a single-change
    # round (and every existing fixture) passes the scope label separately.
    change_id: str = ""


GATED_GRADE_REASON = "decision grade {grade} is human-gated (D1/D2)"


def rejection_reasons(
    candidate: "TaskCandidate", *, done: frozenset[str] | set[str], main_oid: str
) -> tuple[str, ...]:
    """Every reason this candidate is not claimable, in gate order.

    Empty means claimable. This is the SINGLE implementation of the gate set:
    Worker.select() consumes it to pick a task and Worker.explain() consumes it
    to describe why nothing was picked. A second, independent copy for the
    reporting side would drift from the deciding side, and the receipt would then
    describe gates the round does not actually apply — the same
    "two implementations of one contract" failure this module has already been
    bitten by.

    Every gate is evaluated, not short-circuited, because a candidate blocked for
    three reasons and a candidate blocked for one are different situations and
    the operator needs to see both.
    """
    reasons: list[str] = []
    if is_never_claim(candidate.task_id):
        reasons.append("never-claim: the readiness forbids claiming this task")
    if not is_ready(candidate.status):
        reasons.append(f"status {candidate.status!r} is not ready")
    if candidate.hardware_required:
        reasons.append("hardware required: device work is never host-loop work")
    missing = sorted(d for d in candidate.dependencies if d not in done)
    if missing:
        reasons.append(f"dependencies not done: {missing}")
    if not candidate.allowed_paths:
        reasons.append("no declared allowed paths")
    if candidate.base_pin is not None and candidate.base_pin != main_oid:
        reasons.append(
            f"base pin {candidate.base_pin} does not match main {main_oid}")
    if candidate.decision_grade in GATED_GRADES:
        reasons.append(GATED_GRADE_REASON.format(grade=candidate.decision_grade))
    elif candidate.decision_grade not in DISPATCHABLE_GRADES:
        reasons.append(
            f"decision grade {candidate.decision_grade!r} is not dispatchable")
    return tuple(reasons)


def classify_no_claim(
    candidates: "list[TaskCandidate]", *, done: frozenset[str] | set[str],
    main_oid: str,
) -> tuple[SelectionOutcome, str]:
    """Say why nothing was claimable. One implementation, two callers.

    `Worker.select()` calls it to label a round and the repo-wide navigator calls
    it to label an idle scan across every active change. A second copy would let
    the round and the log it prints disagree about the same candidate set — the
    "two implementations of one contract" shape this module has already been
    bitten by twice.

    The never-claim branch filters on `ready`, which is the defect this function
    was extracted to fix. It previously asked only `is_never_claim(task_id)`, so
    once TASK-HLR-003 went `done` the loop still reported
    `only never-claim tasks are ready (['TASK-HLR-003'])` — naming a task that was
    neither ready nor the reason the round found nothing. Measured on the audit
    base: 31 consecutive rounds carried that sentence.
    """
    gated = [
        c.task_id for c in candidates
        if rejection_reasons(c, done=done, main_oid=main_oid)
        == (GATED_GRADE_REASON.format(grade=c.decision_grade),)
    ]
    if gated:
        return (SelectionOutcome.ONLY_GATED_READY,
                f"only gated tasks are ready ({sorted(gated)}); a D1/D2 gate is "
                "not confirmed, so the worker records the block and starts nothing")
    excluded = sorted(c.task_id for c in candidates
                      if is_never_claim(c.task_id) and is_ready(c.status))
    if excluded:
        return (SelectionOutcome.ONLY_NEVER_CLAIM_READY,
                f"only never-claim tasks are ready ({excluded}); discovery "
                "excludes this task's own implementation by readiness rule")
    return SelectionOutcome.NOTHING_READY, "no ready host-only task"


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
    def explain(
        self, candidates: list[TaskCandidate], change_id: str, main_oid: str
    ) -> tuple[bool, list[tuple[str, tuple[str, ...]]]]:
        """Per-candidate, per-gate verdict for the `--explain` dry run.

        Returns (change_approved, [(task_id, reasons), ...]) where an empty
        reasons tuple means claimable. Reads nothing but the same inputs select()
        reads and performs no network call, so it is safe to run before any
        credential exists.

        This exists because the r3 readiness requires a receipt to carry a
        per-gate enumeration, and `exit 10` alone cannot supply it: that one code
        covers "no candidates", "all candidates rejected" and "only never-claim
        tasks are ready", which are different facts with different consequences.
        """
        done = self._done_tasks()
        rows = [(c.task_id, rejection_reasons(c, done=done, main_oid=main_oid))
                for c in candidates]
        return self._change_approved(change_id), rows

    def select(
        self, candidates: list[TaskCandidate], change_id: str, main_oid: str
    ) -> tuple[TaskCandidate | None, SelectionOutcome, str]:
        """Pick at most one claimable task, or explain why none is claimable.

        At most one, whether the caller passed one change's candidates or every
        active change's: the loop returns on the first clean candidate, so
        aggregating the input cannot aggregate the claims.

        Approval is evaluated per change rather than once for the round, because
        a repo-wide scan mixes approved and unapproved changes and a single
        verdict would either dispatch out of an unapproved change or let one
        unapproved change stop every other. A candidate with no change id falls
        back to the round's scope label, which is what a single-change round
        passes and what every pre-existing caller relies on.
        """
        approved: dict[str, bool] = {}

        def change_approved(cid: str) -> bool:
            if cid not in approved:
                approved[cid] = self._change_approved(cid)
            return approved[cid]

        scope_ids = sorted({c.change_id or change_id for c in candidates}
                           or {change_id})
        approved_ids = {cid for cid in scope_ids if change_approved(cid)}
        if not approved_ids:
            detail = (f"change {change_id} is not approved; zero dispatch"
                      if scope_ids == [change_id] else
                      f"no approved change among {scope_ids}; zero dispatch")
            return None, SelectionOutcome.CHANGE_NOT_APPROVED, detail

        scoped = [c for c in candidates
                  if (c.change_id or change_id) in approved_ids]
        done = self._done_tasks()
        for candidate in scoped:
            if not rejection_reasons(candidate, done=done, main_oid=main_oid):
                return candidate, SelectionOutcome.CLAIMABLE, "claimable"

        outcome, detail = classify_no_claim(scoped, done=done, main_oid=main_oid)
        return None, outcome, detail

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
        self._corrections: list[str] = []
        try:
            result = self._round(candidates, change_id, main_oid, cursor_state,
                                 truth)
            # The corrections list is the ONLY compensating control for having
            # made cache staleness non-fatal: without it every cache/Truth
            # divergence is silent, and a genuine anomaly looks like a clean
            # round. It was computed and discarded, which is the same
            # "written but never bound" shape flagged twice in review.
            return self._with_corrections(result)
        except (FenceLost, LeaseError, ReconcileRequired, CursorError,
                TransportError) as error:
            # Every ambiguity funnels here. No retry, no second PR, no dispatch.
            return self._with_corrections(
                RoundResult(WorkerState.RECONCILE_REQUIRED, None, str(error)))
        except Exception as error:  # noqa: BLE001
            # An unexpected shape must fail closed too. Listing only the five
            # known types meant a malformed payload (base: null, say) crashed the
            # process instead of stopping the lane.
            return self._with_corrections(RoundResult(
                WorkerState.RECONCILE_REQUIRED, None,
                f"unexpected {type(error).__name__} in round: {error}; "
                "treated as reconcile-required",
            ))

    def _with_corrections(self, result: RoundResult) -> RoundResult:
        """Attach this round's cursor corrections to whatever it returned.

        Reconcile ran before the failure and may already have persisted the
        corrected cursor, so dropping the list on the error paths meant the
        write happened and its explanation did not — on precisely the rounds an
        operator reads. Both handlers built their result from str(error) alone.
        """
        if not self._corrections:
            return result
        joined = "; ".join(self._corrections)
        return replace(
            result, detail=f"{result.detail} [cursor reconciled: {joined}]")

    def _round(
        self,
        candidates: list[TaskCandidate],
        change_id: str,
        main_oid: str,
        cursor_state: CursorState,
        truth: Truth,
    ) -> RoundResult:
        from .cursor import reconcile

        # The cursor is a cache: reconcile it against truth and KEEP the
        # reconciled value. Discarding it left the cache permanently stale, so
        # the next round conflicted against state it had never written.
        cursor_state, self._corrections = reconcile(cursor_state, truth)

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

        # _prepare_branch pushes refs/heads/agent/host-loop/tasks/<task>, which
        # is the round's FIRST external write and the ref a rival's PR head points
        # at. The gate used to sit on the line after it, so a worker that had
        # already lost its fence still moved the shared branch.
        self._leases.assert_still_held(held, self._read_lease_record)
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

        # The last external write of the round. It needs the same gate as every
        # other one: when the required checks are already green the dispatch
        # branch above is skipped entirely, and its gate went with it — so a
        # worker whose fence had been taken still wrote the shared cursor Issue,
        # stamping its own stale lease OID over the real holder's and wedging
        # the next round.
        self._leases.assert_still_held(held, self._read_lease_record)
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
        # record_lease_write used to run here first. It was a no-op at this one
        # call site: _persist_cursor's record_round() rewrites every field it had
        # just set, with the same values, and validates them itself. Two tests
        # covered it, which made the dead step look load-bearing — the same
        # "written but never bound" shape flagged twice before.
        #
        # The lease already knows the PR on the adopt and renew paths, and
        # record_round replaces every navigation field rather than merging, so
        # omitting it there stamped `pr_number: null` over a real open PR until
        # the round-end write restored it. The shared Issue asserted something
        # untrue for the width of the round, and a reader arriving mid-round saw
        # a claimed task with no PR. Fall back to what the lease holds.
        if pr_number is None:
            pr_number = held.record.pr_number
        return self._persist_cursor(cursor_state, main_oid, task_id,
                                    lease_ref(held.record.task_id), held.ref_oid,
                                    pr_number=pr_number, pr_head=pr_head)

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


# Conclusions that mean "this check did not execute". On a REQUIRED name they
# never satisfy the gate; on a non-required name they are benign.
BENIGN_NON_EXECUTION = frozenset({"skipped", "neutral"})


def _run_state(run: dict) -> str:
    """Classify ONE check run: 'failed' | 'blocking' | 'benign' | 'success'.

    Single classifier for both the required and the non-required side. They used
    to classify independently, and the two drifted: the non-required side kept a
    separate `pending` accumulator while the required side collapsed each name to
    one value with no way back from "success". That drift WAS the asymmetry —
    requiring a check made the gate laxer, which is the opposite of the point.

      failed    completed, and the conclusion says it ran and did not pass.
      blocking  not completed yet, or completed with no conclusion at all. The
                first is in flight; the second is malformed. Neither is a
                failure, and neither may read as satisfied.
      benign    completed as `skipped` or `neutral` — it deliberately did not
                execute. Not a failure, but it satisfies nothing either.
      success   completed with conclusion `success`.
    """
    if run.get("status") != "completed":
        return "blocking"
    conclusion = run.get("conclusion")
    if conclusion is None:
        return "blocking"
    if conclusion in BENIGN_NON_EXECUTION:
        return "benign"
    return "success" if conclusion == "success" else "failed"


def required_verdicts(check_runs: list[dict]) -> dict[str, str]:
    """Single source of truth for required-check state.

    One of "success" | "failed" | "pending" per name in REQUIRED_PR_CHECKS, over
    a three-tier lattice: FAILED > PENDING > SUCCESS. Every run for the name is
    scanned to exhaustion before deciding, so the verdict cannot depend on
    arrival order.

    A required name carries SEVERAL runs: `guard` is published by both the push
    suite and the `pull_request` suite, because sdd-guard.yml's guard job carries
    no event condition. This function has now been wrong three times, each time
    by letting one run's outcome speak for the name:

      r1  presence was decided by name alone and `skipped` counted as success, so
          a required check that never ran read as green.
      v3  `success` was made absorbing per name, so an executed failure on the
          same name was swallowed.
      v4  `success` was still terminal for the name, so a sibling that had not
          finished yet contributed nothing: [guard success (push), guard
          in_progress (edited)] read as GREEN with nothing unsatisfied, which
          also suppressed re-dispatch. That is the ordinary steady state right
          after a dispatch, because the edited `allowed-paths` job returns fast
          while the edited `guard` job runs the whole of check-sdd.sh — and the
          still-running run is precisely the one that can differ from the push
          run, since a pull_request checkout resolves the merge ref.

    Hence: a name is satisfied only when at least one of its runs executed
    successfully AND none of its runs is still blocking.
    """
    seen: dict[str, set[str]] = {name: set() for name in REQUIRED_PR_CHECKS}
    for run in check_runs:
        name = run.get("name")
        if name not in seen:
            continue
        seen[name].add(_run_state(run))

    verdicts: dict[str, str] = {}
    for name, states in seen.items():
        if "failed" in states:
            verdicts[name] = "failed"
        elif "blocking" in states or "success" not in states:
            verdicts[name] = "pending"
        else:
            verdicts[name] = "success"
    return verdicts


def unsatisfied_required_checks(check_runs: list[dict]) -> tuple[str, ...]:
    """Required names that have not yet executed successfully."""
    return tuple(sorted(
        name for name, verdict in required_verdicts(check_runs).items()
        if verdict != "success"
    ))


def _non_required_outcome(check_runs: list[dict], required: set[str]) -> str:
    """'ok' | 'pending' | 'failed' for runs outside REQUIRED_PR_CHECKS.

    Scanned to exhaustion before deciding, so a still-running run that happens
    to be listed before a failed one cannot downgrade the failure to pending.
    """
    states = {_run_state(run) for run in check_runs
              if run.get("name") not in required}
    if "failed" in states:
        return "failed"
    return "pending" if "blocking" in states else "ok"


def classify_checks(check_runs: list[dict]) -> str:
    """'green' | 'pending' | 'failed', derived from that one mapping.

    Green requires every REQUIRED name to have executed successfully. Runs
    outside REQUIRED_PR_CHECKS can still fail or delay the round, but a skipped
    or neutral conclusion on one of them is not a failure. Requiring a check may
    only ever make the gate stricter, never laxer.
    """
    verdicts = required_verdicts(check_runs)
    if "failed" in verdicts.values():
        return "failed"
    outside = _non_required_outcome(check_runs, set(verdicts))
    if outside == "failed":
        return "failed"
    if outside == "pending" or any(v == "pending" for v in verdicts.values()):
        return "pending"
    return "green"
