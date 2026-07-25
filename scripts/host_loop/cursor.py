"""Issue cursor as a rebuildable cache (TASK-HLR-003 draft).

design §3: each host-loop queue uses one named GitHub Issue for navigation. Its
machine block caches only: cursor main OID, candidate task, lease ref/OID, PR
number/head, review run, last observed time. On start or recovery the runtime
MUST rebuild and validate it against protected main, the active `tasks.md` and
GitHub PR metadata. A missing Issue, an unparsable machine block, or any
conflict with those facts yields `blocked/reconcile-required`.

The Issue is explicitly NOT authority, approval, task status, or a single source
of truth. Nothing here may be used to justify a write; it only saves work.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, replace
from typing import Callable

from .transport import OID_RE, ApiPort, TransportError

OPEN_MARKER = "<!-- arkdeck-host-loop-cursor:v1 -->"
CLOSE_MARKER = "<!-- /arkdeck-host-loop-cursor -->"
CURSOR_SCHEMA = "arkdeck-host-loop-cursor/v1"

# Exactly the fields design §3 permits the cursor to cache. Anything else is a
# conflict: a wider cache would start to look like a source of truth.
CURSOR_FIELDS = (
    "cursor_main_oid",
    "candidate_task",
    "lease_ref",
    "lease_oid",
    "pr_number",
    "pr_head",
    "review_run",
    "last_observed_at",
)


class CursorError(RuntimeError):
    """Missing Issue, unparsable block, or a cache/truth conflict."""


@dataclass(frozen=True)
class CursorState:
    cursor_main_oid: str
    candidate_task: str | None
    lease_ref: str | None
    lease_oid: str | None
    pr_number: int | None
    pr_head: str | None
    review_run: str | None
    last_observed_at: int

    def validate(self) -> None:
        if not OID_RE.match(self.cursor_main_oid):
            raise CursorError("cursor_main_oid must be lowercase full 40-hex")
        for name in ("lease_oid", "pr_head"):
            value = getattr(self, name)
            if value is not None and not OID_RE.match(value):
                raise CursorError(f"{name} must be lowercase full 40-hex or null")
        if self.pr_number is not None and (
            not isinstance(self.pr_number, int) or self.pr_number < 1
        ):
            raise CursorError("pr_number must be a positive integer or null")
        if not isinstance(self.last_observed_at, int):
            raise CursorError("last_observed_at must be epoch seconds")
        if (self.lease_ref is None) != (self.lease_oid is None):
            raise CursorError("lease_ref and lease_oid must be set together")

    def render(self) -> str:
        payload = {"schema": CURSOR_SCHEMA}
        payload.update({name: getattr(self, name) for name in CURSOR_FIELDS})
        body = json.dumps(payload, sort_keys=True, separators=(",", ":"))
        return f"{OPEN_MARKER}\n{body}\n{CLOSE_MARKER}\n"


def parse_machine_block(body: str) -> CursorState:
    """Strict parse. Any deviation is reconcile-required, never a silent reset."""
    if body.count(OPEN_MARKER) != 1 or body.count(CLOSE_MARKER) != 1:
        raise CursorError("cursor machine block markers are missing or duplicated")
    start = body.index(OPEN_MARKER) + len(OPEN_MARKER)
    end = body.index(CLOSE_MARKER)
    if end < start:
        raise CursorError("cursor machine block markers are inverted")
    try:
        raw = json.loads(body[start:end].strip())
    except (ValueError, TypeError) as error:
        raise CursorError(f"unparsable cursor machine block: {error}") from error
    if not isinstance(raw, dict) or raw.get("schema") != CURSOR_SCHEMA:
        raise CursorError("cursor schema mismatch")
    unknown = set(raw) - {"schema", *CURSOR_FIELDS}
    if unknown:
        raise CursorError(f"cursor carries non-cacheable fields {sorted(unknown)}")
    missing = set(CURSOR_FIELDS) - set(raw)
    if missing:
        raise CursorError(f"cursor missing fields {sorted(missing)}")
    state = CursorState(**{name: raw[name] for name in CURSOR_FIELDS})
    state.validate()
    return state


@dataclass(frozen=True)
class Truth:
    """Authoritative facts the cursor is checked against. Never derived from it."""

    main_oid: str
    ready_tasks: frozenset[str]
    open_pr_numbers: frozenset[int]
    lease_oid_by_ref: dict[str, str]


def rebuild_and_validate(state: CursorState, truth: Truth) -> CursorState:
    """Reconcile the cache against truth, or refuse.

    A stale `cursor_main_oid` is normal — main advances constantly — so it is
    refreshed, not treated as a conflict. Everything the cursor claims about
    leases, PRs and candidate tasks must still match observed reality.
    """
    conflicts: list[str] = []

    if state.candidate_task is not None and state.candidate_task not in truth.ready_tasks:
        conflicts.append(
            f"cursor candidate {state.candidate_task!r} is not a currently ready task"
        )
    if state.pr_number is not None and state.pr_number not in truth.open_pr_numbers:
        conflicts.append(
            f"cursor PR #{state.pr_number} is not among the observed open PRs"
        )
    if state.lease_ref is not None:
        observed = truth.lease_oid_by_ref.get(state.lease_ref)
        if observed is None:
            conflicts.append(f"cursor lease ref {state.lease_ref} does not exist")
        elif observed != state.lease_oid:
            conflicts.append(
                f"cursor lease OID {state.lease_oid} != observed {observed}"
            )
    if conflicts:
        raise CursorError("; ".join(conflicts))

    return replace(state, cursor_main_oid=truth.main_oid)


def load(api: ApiPort, issue_number: int) -> tuple[CursorState, dict]:
    """Read and parse the cursor Issue. A missing Issue is reconcile-required.

    The cursor Issue is created once during authorized activation, never
    auto-created here: silently minting a fresh cursor would erase exactly the
    state a crash recovery needs to detect.
    """
    try:
        issue = api.get_issue(issue_number)
    except TransportError as error:
        raise CursorError(f"cursor Issue {issue_number} unreadable: {error}") from error
    if issue.get("state") != "open":
        raise CursorError(f"cursor Issue {issue_number} is not open")
    return parse_machine_block(issue.get("body") or ""), issue


def store(
    api: ApiPort,
    issue_number: int,
    state: CursorState,
    *,
    previous_body: str,
    human_prefix: str = "",
) -> bool:
    """Write the cursor back. Returns False when the canonical bytes are unchanged.

    design §2's rule for envelopes applies here too: regenerate the whole block
    and write only when the canonical bytes actually change, so heartbeats do
    not produce a stream of no-op edits.
    """
    state.validate()
    block = state.render()
    body = f"{human_prefix}{block}" if human_prefix else block
    if previous_body == body:
        return False
    api.update_issue(issue_number, body=body)
    return True


def record_lease_write(
    state: CursorState, lease_ref: str, lease_oid: str, observed_at: int
) -> CursorState:
    """design §3: every lease write updates the cursor with the new ref OID."""
    if not OID_RE.match(lease_oid):
        raise CursorError("lease_oid must be lowercase full 40-hex")
    return replace(
        state, lease_ref=lease_ref, lease_oid=lease_oid, last_observed_at=observed_at
    )
