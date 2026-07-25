"""Stable PR identity and adoption (TASK-HLR-003 draft).

design §3: PR identity is the stable head branch
`agent/host-loop/tasks/<task-id>` plus the envelope `Task:` and `Base-OID` —
never the title. After a create timeout or a crash the new owner searches by
that identity and adopts the unique existing PR; 0 or more than 1 result stops
the lane and never opens a second PR.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Callable, Literal

from .transport import OID_RE, ApiPort, TransportError


class ReconcileRequired(RuntimeError):
    """Ambiguous PR identity. The lane stops; no dispatch, no second PR."""


@dataclass(frozen=True)
class PRIdentity:
    task_id: str
    base_oid: str
    head_branch: str

    def __post_init__(self) -> None:
        if not OID_RE.match(self.base_oid):
            raise ValueError("base_oid must be lowercase full 40-hex")


@dataclass(frozen=True)
class Resolution:
    action: Literal["adopt", "create"]
    pull: dict | None
    reason: str


# envelope_reader(body) -> (task, base_oid) or None when the body carries no
# parseable envelope. Injected so this stays offline-testable.
EnvelopeReader = Callable[[str], tuple[str, str] | None]


def _matches(pull: dict, identity: PRIdentity, read_envelope: EnvelopeReader) -> bool:
    head = (pull.get("head") or {}).get("ref")
    if head != identity.head_branch:
        return False
    if (pull.get("base") or {}).get("ref") != "main":
        return False
    parsed = read_envelope(pull.get("body") or "")
    if parsed is None:
        return False
    task, base_oid = parsed
    return task == identity.task_id and base_oid == identity.base_oid


def resolve_pull(
    api: ApiPort,
    identity: PRIdentity,
    read_envelope: EnvelopeReader,
    *,
    create_attempted: bool,
) -> Resolution:
    """Decide whether to adopt an existing PR or open the first one.

    `create_attempted` comes from the durable lease record, set before the
    create call. When it is true, a zero-result lookup is ambiguous — the create
    may have landed and the PR may since have been closed — so the lane stops
    rather than risk a duplicate.
    """
    candidates = api.list_open_pulls_for_head(identity.head_branch)
    matching = [pull for pull in candidates if _matches(pull, identity, read_envelope)]

    if len(matching) > 1:
        numbers = sorted(pull.get("number") for pull in matching)
        raise ReconcileRequired(
            f"{len(matching)} open PRs share the identity for {identity.task_id}: "
            f"{numbers}; refusing to act"
        )

    if len(matching) == 1:
        return Resolution("adopt", matching[0], "adopted the unique identity-matching PR")

    # Zero identity matches. Distinguish "nothing was ever created" from
    # "a create may have landed": the latter is never re-created.
    if create_attempted:
        raise ReconcileRequired(
            f"a create was already attempted for {identity.task_id} but no open PR "
            "matches the identity; a landed-then-closed PR cannot be distinguished "
            "from a lost create — human reconciliation required"
        )

    if candidates:
        # The branch has an open PR that does not match the envelope identity.
        # Opening a second PR on the same head is exactly what design §5 forbids.
        raise ReconcileRequired(
            f"head {identity.head_branch} already has {len(candidates)} open PR(s) "
            "whose envelope identity does not match; refusing to open another"
        )

    return Resolution("create", None, "no PR exists for this identity yet")


def confirm_created_pull(
    api: ApiPort,
    identity: PRIdentity,
    read_envelope: EnvelopeReader,
    *,
    expected_head_oid: str,
) -> dict:
    """Read back the freshly created PR and re-confirm every identity field."""
    resolution = resolve_pull(api, identity, read_envelope, create_attempted=True)
    if resolution.action != "adopt" or resolution.pull is None:
        raise ReconcileRequired("create read-back did not yield a unique PR")
    pull = api.get_pull(int(resolution.pull["number"]))
    head = pull.get("head") or {}
    if head.get("ref") != identity.head_branch:
        raise ReconcileRequired("read-back head branch mismatch")
    if head.get("sha") != expected_head_oid:
        raise ReconcileRequired(
            f"read-back head OID {head.get('sha')} != expected {expected_head_oid}"
        )
    if (pull.get("base") or {}).get("ref") != "main":
        raise ReconcileRequired("read-back base is not main")
    if pull.get("merged"):
        raise ReconcileRequired("a freshly created PR reports merged; reconcile")
    if pull.get("auto_merge") is not None:
        raise ReconcileRequired("auto_merge is set on the worker PR; reconcile")
    return pull


def confirm_merge(
    pull: dict, main_history_contains: Callable[[str], bool]
) -> str:
    """Cross-confirm a merge from GitHub metadata AND protected-main history.

    design §5: branch deletion, elapsed time, an Issue comment or a green CI run
    are all insufficient. `merge_commit_sha` may also be null on an
    already-merged PR (observed on #507), so a null is never an OID.
    """
    if not pull.get("merged"):
        raise ReconcileRequired("PR does not report merged")
    oid = pull.get("merge_commit_sha")
    if not isinstance(oid, str) or not OID_RE.match(oid):
        raise ReconcileRequired(
            "merge metadata carries no usable full merge OID (nullable observed); "
            "cannot advance the cursor on this evidence alone"
        )
    if not main_history_contains(oid):
        raise ReconcileRequired(
            f"merge OID {oid} is not present in protected-main history"
        )
    return oid
