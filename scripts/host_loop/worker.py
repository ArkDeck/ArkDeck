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

from dataclasses import dataclass
from enum import Enum
from typing import Callable

from .cursor import CursorError, CursorState, Truth
from .identity import PRIdentity, ReconcileRequired, resolve_pull
from .lease import FenceLost, HeldLease, LeaseError, LeaseManager, lease_ref, task_branch
from .transport import ApiPort, TransportError


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
NEVER_CLAIM = frozenset({"TASK-HLR-003"})


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
        self._dispatch_token = dispatch_token or (lambda: str(now()))

    # -- discovery --------------------------------------------------------
    def select(
        self, candidates: list[TaskCandidate], change_id: str, main_oid: str
    ) -> tuple[TaskCandidate | None, str]:
        """Pick at most one claimable task, or explain why none is claimable."""
        if not self._change_approved(change_id):
            return None, f"change {change_id} is not approved; zero dispatch"

        done = self._done_tasks()
        gated: list[str] = []
        for candidate in candidates:
            if candidate.task_id in NEVER_CLAIM:
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
            return candidate, "claimable"

        if any(c.task_id in NEVER_CLAIM for c in candidates):
            excluded = sorted(c.task_id for c in candidates if c.task_id in NEVER_CLAIM)
            if not gated:
                return None, (
                    f"only never-claim tasks are ready ({excluded}); discovery "
                    "excludes this task's own implementation by readiness rule"
                )
        if gated:
            return None, (
                f"only gated tasks are ready ({sorted(gated)}); a D1/D2 gate is not "
                "confirmed, so the worker records the block and starts nothing"
            )
        return None, "no ready host-only task"

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
        self._api.update_pull(number, body=f"{body}\n{marker}\n")

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
        except (FenceLost, LeaseError, ReconcileRequired, CursorError, TransportError) as error:
            # Every ambiguity funnels here. No retry, no second PR, no dispatch.
            return RoundResult(WorkerState.RECONCILE_REQUIRED, None, str(error))

    def _round(
        self,
        candidates: list[TaskCandidate],
        change_id: str,
        main_oid: str,
        cursor_state: CursorState,
        truth: Truth,
    ) -> RoundResult:
        # The cursor is a cache: validate it against truth before trusting it.
        from .cursor import rebuild_and_validate

        rebuild_and_validate(cursor_state, truth)

        candidate, reason = self.select(candidates, change_id, main_oid)
        if candidate is None:
            state = (
                WorkerState.BLOCKED_RECORDED
                if "gated" in reason or "not approved" in reason
                else WorkerState.IDLE
            )
            return RoundResult(state, None, reason)

        held = self._leases.acquire(candidate.task_id, main_oid)

        # Branch preparation is a local git operation; it produces the head OID.
        head_oid = self._prepare_branch(candidate, main_oid)

        identity = PRIdentity(
            task_id=candidate.task_id,
            base_oid=main_oid,
            head_branch=task_branch(candidate.task_id).removeprefix("refs/heads/"),
        )

        # Re-confirm the fence immediately before the first external write.
        self._leases.assert_still_held(held, self._read_lease_record)

        resolution = resolve_pull(
            self._api,
            identity,
            self._read_envelope,
            create_attempted=held.record.create_attempted,
        )

        if resolution.action == "adopt":
            pull = resolution.pull
            assert pull is not None
            held = self._leases.attach_pull(held, int(pull["number"]))
        else:
            # Record create intent durably BEFORE the create call, then
            # re-confirm the fence, then create exactly once.
            held = self._leases.mark_create_attempted(held)
            self._leases.assert_still_held(held, self._read_lease_record)
            body = self._render_body(candidate, main_oid, head_oid)
            created = self._api.create_pull(
                head=identity.head_branch,
                base="main",
                title=f"{candidate.task_id}: host-loop dispatch",
                body=body,
            )
            from .identity import confirm_created_pull

            pull = confirm_created_pull(
                self._api, identity, self._read_envelope, expected_head_oid=head_oid
            )
            held = self._leases.attach_pull(held, int(pull["number"]))

        number = int(pull["number"])

        # A reserved-namespace PR gets no `allowed-paths` job from its `opened`
        # event: agent-pr.yml is push-scoped and excludes agent/host-loop/**, and
        # sdd-guard.yml's allowed-paths job only runs on pull_request types
        # [reopened, edited]. One deliberate body update fires `edited`, which
        # produces both required checks. TASK-HLR-002's D2 run proved the
        # mechanism live: allowed-paths was skipped on push and success on the
        # edited run. The update is issued only when a required check is actually
        # missing, so recovery rounds do not re-fire it.
        checks = self._api.list_check_runs(head_oid)
        if missing_required_checks(checks):
            self._leases.assert_still_held(held, self._read_lease_record)
            self._dispatch_checks(number, candidate, main_oid, head_oid)
            checks = self._api.list_check_runs(head_oid)

        verdict = classify_checks(checks)
        still_missing = missing_required_checks(checks)
        if still_missing:
            return RoundResult(
                WorkerState.PR_OPEN, candidate.task_id,
                f"PR open; required checks still absent after dispatch: "
                f"{list(still_missing)}", number,
            )
        if verdict == "pending":
            return RoundResult(
                WorkerState.PR_OPEN, candidate.task_id,
                "PR open; checks not yet terminal", number,
            )
        if verdict == "failed":
            return RoundResult(
                WorkerState.WORKER_PAUSED, candidate.task_id,
                "checks failed; worker paused, no dispatch", number,
            )
        return RoundResult(
            WorkerState.CHECKS_GREEN, candidate.task_id,
            "checks green — this is NOT merge permission; the maintainer merges",
            number,
        )


def missing_required_checks(check_runs: list[dict]) -> tuple[str, ...]:
    """Required check names absent from the head. Empty means all present."""
    present = {run.get("name") for run in check_runs}
    return tuple(name for name in REQUIRED_PR_CHECKS if name not in present)


def classify_checks(check_runs: list[dict]) -> str:
    """'green' | 'pending' | 'failed'. An empty set is pending, never green.

    An absent check set must not read as success: the reserved-namespace
    `pull_request` coverage gap (F1) means "no checks" is exactly the state a
    misconfigured lane produces.
    """
    if not check_runs:
        return "pending"
    for run in check_runs:
        if run.get("status") != "completed":
            return "pending"
    for run in check_runs:
        if run.get("conclusion") not in ("success", "neutral", "skipped"):
            return "failed"
    return "green"
