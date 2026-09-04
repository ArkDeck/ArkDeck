"""Clock discipline for the benchmark harness.

`openspec/specs/workflow-journal-recovery/spec.md` REQ-NFR-001 separates three
clocks and the harness SHALL keep them apart:

* audit time is wall-clock UTC;
* an overall deadline or timeout uses the *continuous* monotonic clock, which
  keeps advancing while the machine sleeps;
* an active-work duration, a throughput sample or an ETA uses the *awake-work*
  monotonic clock, which pauses while the machine sleeps.

Folding sleep time into a latency sample is exactly the mistake that clause
forbids, so every percentile in a baseline document is taken from the
awake-work clock and every wait budget from the continuous one.  A monotonic
instant is never persisted or compared across processes: a baseline document
carries durations plus the UTC timestamp they were taken at.

The POSIX names differ per platform, which REQ-NFR-001 explicitly allows
("平台 API 名称可以不同，但语义 SHALL 一致").  On Darwin `CLOCK_MONOTONIC`
continues across sleep and `CLOCK_UPTIME_RAW` does not; on Linux the roles are
carried by `CLOCK_BOOTTIME` and `CLOCK_MONOTONIC`.  Resolution is by semantics,
never by name, and the resolved names are recorded in the baseline document so
a later reader can tell which clock produced a number.
"""

from __future__ import annotations

import datetime
import time

# (attribute name, ...) in preference order.  The first attribute that this
# interpreter actually exposes wins; the harness fails closed if none does,
# because silently falling back to a clock with the wrong sleep semantics would
# produce numbers that look valid and are not.
_CONTINUOUS_CANDIDATES = ("CLOCK_BOOTTIME", "CLOCK_MONOTONIC")
_AWAKE_CANDIDATES = ("CLOCK_UPTIME_RAW", "CLOCK_MONOTONIC_RAW", "CLOCK_MONOTONIC")


class ClockUnavailable(RuntimeError):
    """No clock with the required sleep semantics is available."""


def _resolve(candidates: tuple[str, ...], role: str) -> str:
    for name in candidates:
        if hasattr(time, name):
            return name
    raise ClockUnavailable(
        f"no {role} monotonic clock among {', '.join(candidates)}; "
        "refusing to measure with unknown sleep semantics"
    )


def _continuous_name() -> str:
    # Darwin exposes no CLOCK_BOOTTIME; its CLOCK_MONOTONIC is the continuous
    # clock.  Linux exposes both, and there CLOCK_MONOTONIC is the awake-work
    # clock, so CLOCK_BOOTTIME must be preferred.
    return _resolve(_CONTINUOUS_CANDIDATES, "continuous")


def _awake_name() -> str:
    return _resolve(_AWAKE_CANDIDATES, "awake-work")


def elapsed_seconds() -> float:
    """Continuous monotonic reading, for deadlines and timeouts only."""

    return time.clock_gettime(getattr(time, _continuous_name()))


def awake_seconds() -> float:
    """Awake-work monotonic reading, for durations and throughput samples."""

    return time.clock_gettime(getattr(time, _awake_name()))


def clock_identity() -> dict[str, str]:
    """Resolved clock names, recorded in every baseline document."""

    return {
        "continuousClock": _continuous_name(),
        "awakeWorkClock": _awake_name(),
    }


def utc_now() -> str:
    """Audit timestamp.  Never used to measure a duration."""

    return (
        datetime.datetime.now(datetime.UTC)
        .replace(microsecond=0)
        .strftime("%Y-%m-%dT%H:%M:%SZ")
    )


class Deadline:
    """A wait budget on the continuous clock.

    Only the accumulated duration and the configured budget are ever
    persisted; the monotonic origin stays inside this process, as
    REQ-NFR-001 requires of cross-process checkpoints.
    """

    def __init__(self, budget_seconds: float) -> None:
        if budget_seconds <= 0:
            raise ValueError("deadline budget must be positive")
        self.budget_seconds = float(budget_seconds)
        self._origin = elapsed_seconds()

    def consumed_seconds(self) -> float:
        return elapsed_seconds() - self._origin

    def remaining_seconds(self) -> float:
        return self.budget_seconds - self.consumed_seconds()

    def expired(self) -> bool:
        return self.remaining_seconds() <= 0
