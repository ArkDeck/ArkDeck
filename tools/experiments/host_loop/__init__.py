"""Host-loop contracts and fenced worker runtime.

TASK-HLR-001 owns the deterministic offline metadata contract
(`pr_envelope`). TASK-HLR-003 adds the coordination runtime: a typed GitHub
transport, a remote fenced lease, stable PR identity, the Issue cursor cache
and the `--once` worker state machine.

Network access is confined to `transport`: `ApiPort` speaks only PR/Issue/
check-run routes over the integration identity, and `RefPort` performs
`agent/host-loop/**` ref operations over the TASK-BAP-003 Deploy Key. No
module exposes a generic request method, and no review, merge, auto-merge,
branch-update or administration route is constructible.
"""

from .cursor import CursorError, CursorState, Truth
from .identity import PRIdentity, ReconcileRequired, Resolution
from .lease import FenceLost, HeldLease, LeaseError, LeaseManager, LeaseRecord
from .pr_envelope import (
    CLOSE_MARKER,
    OPEN_MARKER,
    Envelope,
    EnvelopeError,
    ParsedEnvelope,
    parse_and_validate,
    parse_envelope,
    render_envelope,
    validate_envelope,
)
from .transport import (
    ALLOWED_ROUTES,
    ApiPort,
    RefPort,
    Refused,
    Route,
    RouteViolation,
    TransportError,
    forbidden_capability_count,
    route_inventory,
)
from .worker import RoundResult, TaskCandidate, Worker, WorkerState

__all__ = [
    "ALLOWED_ROUTES",
    "CLOSE_MARKER",
    "OPEN_MARKER",
    "ApiPort",
    "CursorError",
    "CursorState",
    "Envelope",
    "EnvelopeError",
    "FenceLost",
    "HeldLease",
    "LeaseError",
    "LeaseManager",
    "LeaseRecord",
    "PRIdentity",
    "ParsedEnvelope",
    "ReconcileRequired",
    "RefPort",
    "Refused",
    "Resolution",
    "RoundResult",
    "Route",
    "RouteViolation",
    "TaskCandidate",
    "TransportError",
    "Truth",
    "Worker",
    "WorkerState",
    "forbidden_capability_count",
    "parse_and_validate",
    "parse_envelope",
    "render_envelope",
    "route_inventory",
    "validate_envelope",
]
