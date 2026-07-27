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

from .instance import (
    CURSOR_CLOSE_MARKER as CLOSE_MARKER,
    CURSOR_OPEN_MARKER as OPEN_MARKER,
    CURSOR_SCHEMA,
)
from .transport import OID_RE, ApiPort, TransportError

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
        # bool is a subclass of int, so a plain isinstance check accepts True as
        # 1. The guard was added to LeaseRecord.validate and not here; the cursor
        # is parsed from an Issue body a human can edit, so it needs it more.
        if self.pr_number is not None and (
            not isinstance(self.pr_number, int) or isinstance(self.pr_number, bool)
            or self.pr_number < 1
        ):
            raise CursorError("pr_number must be a positive integer or null")
        if (not isinstance(self.last_observed_at, int)
                or isinstance(self.last_observed_at, bool)):
            raise CursorError("last_observed_at must be epoch seconds")
        for name in ("candidate_task", "lease_ref", "review_run"):
            value = getattr(self, name)
            if value is not None and not isinstance(value, str):
                raise CursorError(f"{name} must be a string or null")
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


def reconcile(state: CursorState, truth: Truth) -> tuple[CursorState, list[str]]:
    """Re-derive every cached navigation fact from Truth. Never raises.

    Staleness is not corruption. This Issue is a cache, so any field that no
    longer matches Truth is simply refreshed and the correction is reported for
    the round record. Treating divergence as fatal wedged the lane permanently:
    reconciliation is the first statement of a round and the cursor is written
    later, so a single dropped cursor write — one transient 502, or the process
    dying between a ref write and its matching cursor write — left the cache
    behind the ref for ever, with zero further cursor writes to catch up.

    Corruption is handled elsewhere and stays fatal: an unparsable body, a wrong
    schema, unknown or missing fields and malformed OIDs are refused by
    parse_machine_block and CursorState.validate, because acting on a misread
    cache is worse than stopping.
    """
    corrections: list[str] = []
    updates: dict[str, object] = {}

    if state.cursor_main_oid != truth.main_oid:
        corrections.append(
            f"cursor_main_oid {state.cursor_main_oid[:12]} -> {truth.main_oid[:12]}")
        updates["cursor_main_oid"] = truth.main_oid

    if state.candidate_task is not None and state.candidate_task not in truth.ready_tasks:
        corrections.append(
            f"candidate_task {state.candidate_task} is no longer ready; cleared")
        updates["candidate_task"] = None

    if state.pr_number is not None and state.pr_number not in truth.open_pr_numbers:
        corrections.append(f"pr_number {state.pr_number} is not open; cleared")
        updates["pr_number"] = None
        updates["pr_head"] = None

    if state.lease_ref is not None:
        observed = truth.lease_oid_by_ref.get(state.lease_ref)
        if observed is None:
            corrections.append(f"lease ref {state.lease_ref} is absent; cleared")
            updates["lease_ref"] = None
            updates["lease_oid"] = None
        elif observed != state.lease_oid:
            corrections.append(
                f"lease_oid {(state.lease_oid or '')[:12]} -> {observed[:12]}")
            updates["lease_oid"] = observed

    if not updates:
        return state, corrections
    reconciled = replace(state, **updates)
    reconciled.validate()
    return reconciled, corrections


def rebuild_and_validate(state: CursorState, truth: Truth) -> CursorState:
    """Reconcile against Truth and return the corrected cache.

    Retained as the name the round calls. It no longer refuses on staleness —
    see reconcile() for why that was a permanent wedge rather than a safety
    property.
    """
    reconciled, _corrections = reconcile(state, truth)
    return reconciled


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


def surrounding_human_text(previous_body: str) -> tuple[str, str]:
    """Split an existing cursor body into the text that is NOT the machine block.

    The Issue is a shared surface: the maintainer writes context above the block
    and the worker owns only what is between the markers. Preservation is derived
    here rather than passed in by the caller, because the earlier design took an
    opt-in `human_prefix` argument and its single call site never passed one —
    so every write silently truncated the Issue to the bare block. A parameter
    the caller has to remember is a parameter the caller forgets.
    """
    if not previous_body:
        return "", ""
    if previous_body.count(OPEN_MARKER) > 1 or previous_body.count(CLOSE_MARKER) > 1:
        raise CursorError("cursor body carries duplicate machine blocks")
    open_at = previous_body.find(OPEN_MARKER)
    if open_at < 0:
        if previous_body.count(CLOSE_MARKER):
            raise CursorError("cursor body has a closing marker with no open")
        # No block yet, so everything already present is human text.
        tail = "" if previous_body.endswith("\n") else "\n"
        return previous_body + tail, ""
    close_at = previous_body.find(CLOSE_MARKER, open_at)
    if close_at < 0:
        raise CursorError("cursor body has an opening marker with no close")
    end = close_at + len(CLOSE_MARKER)
    if previous_body[end:end + 1] == "\n":
        end += 1
    return previous_body[:open_at], previous_body[end:]


def store(
    api: ApiPort,
    issue_number: int,
    state: CursorState,
    *,
    previous_body: str,
) -> bool:
    """Write the cursor back. Returns False when the canonical bytes are unchanged.

    design §2's rule for envelopes applies here too: regenerate the whole block
    and write only when the canonical bytes actually change, so heartbeats do
    not produce a stream of no-op edits.
    """
    state.validate()
    prefix, suffix = surrounding_human_text(previous_body)
    body = f"{prefix}{state.render()}{suffix}"
    if previous_body == body:
        return False
    api.update_issue(issue_number, body=body)
    return True


def record_round(
    state: CursorState, *, main_oid: str, candidate_task: str | None,
    lease_ref_name: str | None, lease_oid: str | None, pr_number: int | None,
    pr_head: str | None, observed_at: int,
) -> CursorState:
    """Fold one completed round's navigation facts into the cache."""
    nxt = replace(
        state, cursor_main_oid=main_oid, candidate_task=candidate_task,
        lease_ref=lease_ref_name, lease_oid=lease_oid, pr_number=pr_number,
        pr_head=pr_head, last_observed_at=observed_at,
    )
    nxt.validate()
    return nxt
