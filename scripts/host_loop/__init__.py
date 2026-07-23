"""Pure host-loop contracts.

Networked worker/reviewer coordination is intentionally introduced by later
CHG-2026-030 tasks.  TASK-HLR-001 only owns deterministic, offline metadata
contracts.
"""

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

__all__ = [
    "CLOSE_MARKER",
    "OPEN_MARKER",
    "Envelope",
    "EnvelopeError",
    "ParsedEnvelope",
    "parse_and_validate",
    "parse_envelope",
    "render_envelope",
    "validate_envelope",
]
