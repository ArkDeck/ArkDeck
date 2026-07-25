"""Remote fenced lease for the host-loop worker (TASK-HLR-003 draft).

design §3: one lease ref per task,
`refs/heads/agent/host-loop/leases/<task-id>`, whose commit carries only the
lease record. acquire is a remote create; renew/release/takeover are
compare-and-swap against an explicit old remote OID. Two workers therefore
cannot hold the same fence.

Rules encoded here that fault injection must not be able to bypass:

* the fence is strictly monotonic per task; a write carrying a fence <= the
  observed remote fence is refused;
* before every external PR/Issue/branch write the lease ref is re-read and
  task / owner / fence / expiry / expected OID are all re-confirmed;
* expiry is judged from an injected trusted clock, never the local wall clock
  of a possibly-stalled owner;
* takeover requires the original ref's exact OID to still match AND the stable
  PR identity to have been re-queried;
* a losing or ambiguous write never falls back to "create a second PR".
"""

from __future__ import annotations

import json
from dataclasses import dataclass, replace
from typing import Callable

from .transport import OID_RE, RefPort, Refused, TransportError

LEASE_REF_PREFIX = "refs/heads/agent/host-loop/leases/"
TASK_BRANCH_PREFIX = "refs/heads/agent/host-loop/tasks/"
LEASE_SCHEMA = "arkdeck-host-loop-lease/v1"


_KEEP = object()


class LeaseError(RuntimeError):
    """Fence violation, expiry ambiguity, or malformed lease record."""


class FenceLost(LeaseError):
    """Another owner holds the fence. The caller must stop, not retry."""


def lease_ref(task_id: str) -> str:
    return f"{LEASE_REF_PREFIX}{task_id}"


def task_branch(task_id: str) -> str:
    return f"{TASK_BRANCH_PREFIX}{task_id}"


@dataclass(frozen=True)
class LeaseRecord:
    task_id: str
    base_oid: str
    owner_run: str
    fence: int
    expires_at: int          # epoch seconds, trusted clock
    pr_branch: str
    pr_number: int | None    # None until the PR exists
    create_attempted: bool   # set BEFORE the create call, so a timed-out
                             # create can never be replayed as a second PR
    checks_dispatched_head: str | None  # head OID a check dispatch was issued
                             # for; persisted so a round running before the
                             # check-run objects materialise does not re-fire it
    previous_lease_oid: str | None

    def serialize(self) -> str:
        """Canonical, deterministic. Same convention as the governance receipts."""
        return json.dumps(
            {
                "schema": LEASE_SCHEMA,
                "task_id": self.task_id,
                "base_oid": self.base_oid,
                "owner_run": self.owner_run,
                "fence": self.fence,
                "expires_at": self.expires_at,
                "pr_branch": self.pr_branch,
                "pr_number": self.pr_number,
                "create_attempted": self.create_attempted,
                "checks_dispatched_head": self.checks_dispatched_head,
                "previous_lease_oid": self.previous_lease_oid,
            },
            sort_keys=True,
            separators=(",", ":"),
        )

    @staticmethod
    def parse(text: str) -> "LeaseRecord":
        try:
            raw = json.loads(text)
        except (ValueError, TypeError) as error:
            raise LeaseError(f"unparsable lease record: {error}") from error
        if not isinstance(raw, dict) or raw.get("schema") != LEASE_SCHEMA:
            raise LeaseError("lease record schema mismatch")
        try:
            record = LeaseRecord(
                task_id=raw["task_id"],
                base_oid=raw["base_oid"],
                owner_run=raw["owner_run"],
                fence=raw["fence"],
                expires_at=raw["expires_at"],
                pr_branch=raw["pr_branch"],
                pr_number=raw["pr_number"],
                create_attempted=raw["create_attempted"],
                checks_dispatched_head=raw["checks_dispatched_head"],
                previous_lease_oid=raw["previous_lease_oid"],
            )
        except KeyError as error:
            raise LeaseError(f"lease record missing field {error}") from error
        record.validate()
        return record

    def validate(self) -> None:
        # bool is a subclass of int and True >= 1, so a plain isinstance check
        # accepts `"fence": true` as fence 1. That record then compares equal to
        # a real fence of 1 and increments to 2, which makes a type confusion
        # into a fence collision. Excluded explicitly, here and below.
        if (not isinstance(self.fence, int) or isinstance(self.fence, bool)
                or self.fence < 1):
            raise LeaseError("fence must be a positive integer")
        if not isinstance(self.expires_at, int) or isinstance(self.expires_at, bool):
            raise LeaseError("expires_at must be epoch seconds")
        if not OID_RE.match(self.base_oid):
            raise LeaseError("base_oid must be lowercase full 40-hex")
        if self.pr_branch != task_branch(self.task_id):
            raise LeaseError("pr_branch must be the stable task branch for this task")
        if self.previous_lease_oid is not None and not OID_RE.match(self.previous_lease_oid):
            raise LeaseError("previous_lease_oid must be lowercase full 40-hex or null")
        if self.pr_number is not None and (
            not isinstance(self.pr_number, int) or isinstance(self.pr_number, bool)
            or self.pr_number < 1
        ):
            raise LeaseError("pr_number must be a positive integer or null")
        if not isinstance(self.create_attempted, bool):
            raise LeaseError("create_attempted must be a boolean")
        if self.pr_number is not None and not self.create_attempted:
            raise LeaseError("pr_number present without a recorded create attempt")
        if self.checks_dispatched_head is not None and not OID_RE.match(
            self.checks_dispatched_head
        ):
            raise LeaseError(
                "checks_dispatched_head must be lowercase full 40-hex or null"
            )


@dataclass(frozen=True)
class HeldLease:
    """A lease this run believes it owns, pinned to the exact remote OID."""

    record: LeaseRecord
    ref_oid: str


class LeaseManager:
    """Owns fence arithmetic and the pre-write re-confirmation gate.

    `commit_writer(record_text, parent_oid) -> new_commit_oid` creates the local
    commit object carrying the record; the caller injects it so the fence logic
    stays offline-testable.
    """

    def __init__(
        self,
        refs: RefPort,
        *,
        owner_run: str,
        now: Callable[[], int],
        commit_writer: Callable[[str, str | None], str],
        ttl_seconds: int = 900,
    ) -> None:
        self._refs = refs
        self._owner_run = owner_run
        self._now = now
        self._write_commit = commit_writer
        self._ttl = ttl_seconds

    @property
    def owner_run(self) -> str:
        """The single source of truth for this worker's lease identity.

        Worker reads it from here instead of carrying its own copy: two
        independently-supplied strings that merely had to be equal produced a
        silent deadlock when they were not — round one acquired the lease and
        every later round reported `idle` ("held by a live owner") forever,
        which is not an alarming state.
        """
        return self._owner_run

    # -- observation ------------------------------------------------------
    def observe(self, task_id: str, read_record: Callable[[str], str]) -> tuple[LeaseRecord, str] | None:
        """Return (record, ref_oid) or None when the lease is absent."""
        ref = lease_ref(task_id)
        oid = self._refs.read(ref)
        if oid is None:
            return None
        record = LeaseRecord.parse(read_record(oid))
        if record.task_id != task_id:
            raise LeaseError(
                f"lease ref {ref} carries task {record.task_id!r}; refusing to act"
            )
        return record, oid

    def is_expired(self, record: LeaseRecord) -> bool:
        return self._now() >= record.expires_at

    # -- acquisition ------------------------------------------------------
    def acquire(self, task_id: str, base_oid: str) -> HeldLease:
        """Create-only acquisition. A concurrent winner surfaces as FenceLost."""
        record = LeaseRecord(
            task_id=task_id,
            base_oid=base_oid,
            owner_run=self._owner_run,
            fence=1,
            expires_at=self._now() + self._ttl,
            pr_branch=task_branch(task_id),
            pr_number=None,
            create_attempted=False,
            checks_dispatched_head=None,
            previous_lease_oid=None,
        )
        record.validate()
        oid = self._write_commit(record.serialize(), None)
        try:
            self._refs.create(lease_ref(task_id), oid)
        except Refused as error:
            raise FenceLost(f"acquire lost for {task_id}: {error}") from error
        except TransportError as error:
            # Ambiguous: the ref may exist now. Never downgrade to "lost".
            raise LeaseError(
                f"acquire ambiguous for {task_id}; reconcile the lease ref "
                f"before any further action: {error}"
            ) from error
        return HeldLease(record, oid)

    def renew(self, held: HeldLease) -> HeldLease:
        """Heartbeat. Bumps the fence via CAS on the exact previous ref OID."""
        return self._advance(
            held,
            pr_number=held.record.pr_number,
            create_attempted=held.record.create_attempted,
        )

    def mark_create_attempted(self, held: HeldLease) -> HeldLease:
        """Durably record create intent BEFORE calling pr-create.

        design §5: after a create timeout the new owner adopts the unique
        existing PR and stops on 0 or >1. Without this marker a create whose
        response was lost is indistinguishable from one never issued, and the
        lane would open a second PR.
        """
        return self._advance(held, pr_number=held.record.pr_number, create_attempted=True)

    def attach_pull(self, held: HeldLease, pr_number: int) -> HeldLease:
        """Record the adopted/created PR number under the same fence discipline."""
        if pr_number < 1:
            raise LeaseError("pr_number must be positive")
        return self._advance(held, pr_number=pr_number, create_attempted=True)

    def record_dispatch(self, held: HeldLease, head_oid: str) -> HeldLease:
        """Durably record that a check dispatch was issued for this head."""
        return self._advance(
            held, pr_number=held.record.pr_number,
            create_attempted=held.record.create_attempted,
            checks_dispatched_head=head_oid,
        )

    def _advance(
        self, held: HeldLease, *, pr_number: int | None, create_attempted: bool,
        checks_dispatched_head: object = _KEEP,
    ) -> HeldLease:
        nxt = replace(
            held.record,
            fence=held.record.fence + 1,
            expires_at=self._now() + self._ttl,
            pr_number=pr_number,
            create_attempted=create_attempted,
            checks_dispatched_head=(
                held.record.checks_dispatched_head
                if checks_dispatched_head is _KEEP
                else checks_dispatched_head
            ),
            previous_lease_oid=held.ref_oid,
            owner_run=self._owner_run,
        )
        nxt.validate()
        if nxt.fence <= held.record.fence:
            raise LeaseError("fence must strictly increase")
        new_oid = self._write_commit(nxt.serialize(), held.ref_oid)
        try:
            self._refs.compare_and_swap(lease_ref(nxt.task_id), held.ref_oid, new_oid)
        except Refused as error:
            raise FenceLost(f"renew lost for {nxt.task_id}: {error}") from error
        except TransportError as error:
            raise LeaseError(
                f"renew ambiguous for {nxt.task_id}; reconcile before retrying: {error}"
            ) from error
        return HeldLease(nxt, new_oid)

    def takeover(
        self,
        task_id: str,
        observed: LeaseRecord,
        observed_oid: str,
        *,
        pr_identity_requeried: bool,
        read_record: Callable[[str], str],
    ) -> HeldLease:
        """Adopt an expired lease. Every precondition is mandatory."""
        if not self.is_expired(observed):
            raise FenceLost(f"lease for {task_id} has not expired; no takeover")
        if not pr_identity_requeried:
            raise LeaseError("takeover requires the stable PR identity to be re-queried")
        # The exact OID must still match at takeover time, re-read now.
        current = self.observe(task_id, read_record)
        if current is None:
            raise LeaseError("lease vanished during takeover; reconcile required")
        current_record, current_oid = current
        if current_oid != observed_oid:
            raise FenceLost(
                f"lease for {task_id} advanced during takeover "
                f"({observed_oid} -> {current_oid}); another owner is live"
            )
        if current_record.fence != observed.fence:
            raise FenceLost("observed fence no longer matches; reconcile required")
        nxt = replace(
            current_record,
            fence=current_record.fence + 1,
            owner_run=self._owner_run,
            expires_at=self._now() + self._ttl,
            previous_lease_oid=current_oid,
        )
        nxt.validate()
        new_oid = self._write_commit(nxt.serialize(), current_oid)
        try:
            self._refs.compare_and_swap(lease_ref(task_id), current_oid, new_oid)
        except Refused as error:
            raise FenceLost(f"takeover lost for {task_id}: {error}") from error
        except TransportError as error:
            raise LeaseError(
                f"takeover ambiguous for {task_id}; reconcile before retrying: {error}"
            ) from error
        return HeldLease(nxt, new_oid)

    def release(self, held: HeldLease) -> None:
        try:
            self._refs.delete(lease_ref(held.record.task_id), held.ref_oid)
        except Refused as error:
            raise FenceLost(f"release lost for {held.record.task_id}: {error}") from error
        except TransportError as error:
            raise LeaseError(
                f"release ambiguous for {held.record.task_id}; the lease may still "
                f"exist, reconcile before acting: {error}"
            ) from error

    # -- the pre-write gate ----------------------------------------------
    def assert_still_held(
        self, held: HeldLease, read_record: Callable[[str], str]
    ) -> None:
        """Re-confirm ownership immediately before any external write.

        design §3: task, owner, fence, expiry and expected OID must all match.
        Any mismatch stops the lane; it never downgrades to a fresh create.
        """
        current = self.observe(held.record.task_id, read_record)
        if current is None:
            raise FenceLost("lease ref disappeared; another owner released or took over")
        record, oid = current
        if oid != held.ref_oid:
            raise FenceLost(f"lease OID moved {held.ref_oid} -> {oid}")
        if record.owner_run != self._owner_run:
            raise FenceLost(f"lease owner is now {record.owner_run!r}")
        if record.fence != held.record.fence:
            raise FenceLost(
                f"fence moved {held.record.fence} -> {record.fence}"
            )
        if record.task_id != held.record.task_id:
            raise FenceLost("lease task identity changed")
        if self.is_expired(record):
            raise FenceLost("lease expired before the write; re-acquire or hand off")
