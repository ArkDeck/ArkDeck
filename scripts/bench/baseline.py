"""Baseline document: percentiles, stability verdict and the output-side gate.

Section I.3 of `docs/design/cross-platform/rust-core-cross-platform-architecture.md`
defines SPK-1 in terms this module implements literally:

* every metric needs at least three independent runs reporting p50/p95/p99
  (or a resource count);
* the spike *fails* when p95 moves more than 30% between those runs, because
  that means the measurement is tracking host load rather than the product;
* a metric that cannot be measured is not a failure — it is recorded as a
  design gap, and stays visible instead of quietly disappearing from the table.

Budgets are derived, not invented: `budget = min(baseline p95 x 1.5, product
ceiling)`.  Regression thresholds compare against the *median* of the archived
baseline, +20% for the PR micro-benchmark lane and +10% for the nightly lane.
"""

from __future__ import annotations

import json
import math
import os
import re

from . import clocks

SCHEMA = "arkdeck-perf-baseline-1.1.0"
CHANGE_ID = "CHG-2026-074-shared-rust-runtime-core"
TASK_ID = "TASK-XPA-023"
SPIKE_ID = "SPK-1"

MINIMUM_RUNS = 3
# Section I.3: three runs whose p95 spread exceeds 30% mean the method, not the
# product, is being measured.
MAXIMUM_P95_SPREAD_RATIO = 0.30
# Section I.2: budget = min(baseline p95 x 1.5, product ceiling).
BUDGET_HEADROOM = 1.5

STATUS_MEASURED = "MEASURED"
STATUS_NOT_MEASURED = "NOT_MEASURED"


class BaselineError(RuntimeError):
    """A baseline document could not be assembled or would leak host identity."""


def percentile(samples: list[float], quantile: float) -> float:
    """Nearest-rank percentile.

    Nearest-rank avoids the interpolation-variant ambiguity that makes two
    tools disagree on the same samples; a baseline is only useful if a later
    comparison computes it the same way.
    """

    if not samples:
        raise BaselineError("cannot take a percentile of an empty sample set")
    if not 0.0 < quantile <= 1.0:
        raise BaselineError(f"quantile {quantile} is out of range")
    ordered = sorted(samples)
    rank = max(1, math.ceil(quantile * len(ordered)))
    return ordered[rank - 1]


def median(values: list[float]) -> float:
    if not values:
        raise BaselineError("cannot take a median of no values")
    ordered = sorted(values)
    middle = len(ordered) // 2
    if len(ordered) % 2 == 1:
        return ordered[middle]
    return (ordered[middle - 1] + ordered[middle]) / 2.0


def summarize_run(samples: list[float]) -> dict[str, float | int]:
    return {
        "count": len(samples),
        "min": min(samples),
        "p50": percentile(samples, 0.50),
        "p95": percentile(samples, 0.95),
        "p99": percentile(samples, 0.99),
        "max": max(samples),
    }


def spread_ratio(values: list[float]) -> float:
    """Relative spread of a value across runs.

    Runs that agree exactly have no spread, whatever the magnitude: an idle
    daemon whose CPU share reads 0.0 in every run is the most reproducible
    result there is, not an undefined one.  Only values that genuinely differ
    around a zero median have no relative scale to be expressed on, and that is
    a measurement defect rather than a product one, so it is reported as an
    infinite spread instead of dividing by zero.
    """

    span = max(values) - min(values)
    if span == 0:
        return 0.0
    centre = median(values)
    if centre == 0:
        return math.inf
    return span / centre


class MetricResult:
    """One metric across every run."""

    def __init__(
        self,
        metric_id: str,
        unit: str,
        design_row: str,
        description: str,
    ) -> None:
        self.metric_id = metric_id
        self.unit = unit
        self.design_row = design_row
        self.description = description
        self.runs: list[dict[str, float | int]] = []
        self.scales: list[dict[str, object]] = []

    def add_run(self, samples: list[float], scale: dict[str, object] | None = None) -> None:
        self.runs.append(summarize_run(samples))
        self.scales.append(dict(scale or {}))

    def as_document(self) -> dict[str, object]:
        p95_values = [float(run["p95"]) for run in self.runs]
        p50_values = [float(run["p50"]) for run in self.runs]
        p99_values = [float(run["p99"]) for run in self.runs]
        spread = spread_ratio(p95_values)
        stable = spread <= MAXIMUM_P95_SPREAD_RATIO and len(self.runs) >= MINIMUM_RUNS
        aggregate_p95 = median(p95_values)
        # A budget only holds at the scale it was measured at, so the scale is
        # carried on the metric.  Runs that disagree keep every value, because a
        # silently averaged scale would make the per-row arithmetic wrong.
        consistent = all(scale == self.scales[0] for scale in self.scales)
        return {
            "status": STATUS_MEASURED,
            "scale": self.scales[0] if consistent else self.scales,
            "scaleConsistentAcrossRuns": consistent,
            "unit": self.unit,
            "designRow": self.design_row,
            "description": self.description,
            "runCount": len(self.runs),
            "runs": self.runs,
            "aggregate": {
                "p50": median(p50_values),
                "p95": aggregate_p95,
                "p99": median(p99_values),
            },
            "p95SpreadRatio": None if math.isinf(spread) else round(spread, 6),
            "stable": stable,
            "derivedBudget": aggregate_p95 * BUDGET_HEADROOM,
        }


class Gap:
    """A design-table row that this host cannot measure.

    Section I.3 requires an unmeasurable metric to be recorded as a design gap
    and carried into the acceptance criteria of whichever task owns it, rather
    than dropped from the table.
    """

    def __init__(self, metric_id: str, design_row: str, reason: str, blocked_by: str):
        self.metric_id = metric_id
        self.design_row = design_row
        self.reason = reason
        self.blocked_by = blocked_by

    def as_document(self) -> dict[str, object]:
        return {
            "status": STATUS_NOT_MEASURED,
            "designRow": self.design_row,
            "reason": self.reason,
            "blockedBy": self.blocked_by,
        }


def _identity_patterns() -> list[tuple[str, re.Pattern[str]]]:
    patterns: list[tuple[str, re.Pattern[str]]] = []
    home = os.path.expanduser("~")
    if home and home != "~":
        patterns.append(("home directory", re.compile(re.escape(home))))
        user = os.path.basename(home)
        if user:
            patterns.append(("user name", re.compile(rf"\b{re.escape(user)}\b")))
    patterns.append(("home path prefix", re.compile(r"/Users/[^/\"\\ ]+")))
    patterns.append(("home path prefix", re.compile(r"/home/[^/\"\\ ]+")))
    return patterns


def assert_no_host_identity(serialized: str) -> None:
    """Refuse to write a document that carries host or user identity.

    A baseline file is committed, so the check runs on the serialized bytes
    immediately before they are written, the same output-side gate the trace
    and M0B capture harnesses use.
    """

    for label, pattern in _identity_patterns():
        match = pattern.search(serialized)
        if match:
            raise BaselineError(
                f"baseline document would leak the {label}: {match.group(0)!r}"
            )


def build_document(
    *,
    host: dict[str, object],
    toolchain: dict[str, object],
    runs: list[dict[str, object]],
    metrics: dict[str, MetricResult],
    gaps: dict[str, Gap],
    baseline_eligible: bool,
    eligibility_reason: str,
) -> dict[str, object]:
    measured = {name: metric.as_document() for name, metric in metrics.items()}
    unmeasured = {name: gap.as_document() for name, gap in gaps.items()}
    overlap = sorted(set(measured) & set(unmeasured))
    if overlap:
        raise BaselineError(
            "a metric cannot be both measured and a gap: " + ", ".join(overlap)
        )
    combined = dict(sorted({**measured, **unmeasured}.items()))
    unstable = sorted(
        name
        for name, entry in measured.items()
        if not entry["stable"]
    )
    return {
        "schema": SCHEMA,
        "change": CHANGE_ID,
        "task": TASK_ID,
        "spike": SPIKE_ID,
        "generatedAtUtc": clocks.utc_now(),
        "host": host,
        "clocks": clocks.clock_identity(),
        "toolchain": toolchain,
        "runs": runs,
        "metrics": combined,
        "measuredMetricCount": len(measured),
        "gapCount": len(unmeasured),
        "unstableMetrics": unstable,
        "spikeVerdict": "PASS" if not unstable and measured else "UNSTABLE",
        "baselineEligible": baseline_eligible and not unstable,
        "eligibilityReason": (
            eligibility_reason
            if not unstable
            else (
                f"{eligibility_reason}; p95 moved more than "
                f"{MAXIMUM_P95_SPREAD_RATIO:.0%} between runs for "
                + ", ".join(unstable)
            )
        ),
        "selfCheckPassed": True,
    }


def serialize(document: dict[str, object]) -> str:
    serialized = json.dumps(document, indent=2, sort_keys=True) + "\n"
    assert_no_host_identity(serialized)
    return serialized
