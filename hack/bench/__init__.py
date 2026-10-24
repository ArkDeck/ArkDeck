"""Performance baseline and regression harness (SPK-1, TASK-XPA-023).

Offline, host-only measurement tooling; Python 3 stdlib only (repository-pinned
CPython, see `.python-version`).  Nothing here dispatches a device operation,
executes a raw HDC command or writes Runtime authority: every measurement is
taken against an isolated Runtime state directory that the harness itself
creates, seeds and destroys.
"""

__all__ = [
    "baseline",
    "clocks",
    "compare",
    "control",
    "harness",
    "metrics",
]
