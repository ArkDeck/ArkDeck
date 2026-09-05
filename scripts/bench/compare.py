"""Compare a captured baseline against the committed one.

Design section I.2 fixes the two thresholds this module applies: a PR
micro-benchmark may drift +20% and a nightly run +10%, both measured against
the *median* of the archived baseline rather than against its best run.

Two comparison modes exist because the two lanes have different noise floors:

* `absolute` compares the aggregate p95 directly, and belongs on a nightly lane
  that owns its runner;
* `ratio` first divides each metric by the calibration workload measured in the
  same run, so a PR runner that is uniformly slower does not read as a
  regression.  This is the design's own "ratio against a calibration load"
  prescription for the PR gate.

A metric that is missing from either document is reported, never skipped: a
silently dropped metric reads as a pass.

Two more cases fail closed rather than pass by default.  A committed reference
of zero has no relative scale, so such a metric is judged against the absolute
product budget from design section I.2, and fails when no budget is defined for
it: an unjudged metric would otherwise read as a pass.  And every metric carries
the workload scale it was measured at; a candidate taken at a different scale
(fewer seeded Jobs, another page size) is not comparable and fails, because a
smaller data set can hide a regression behind a smaller number.
"""

from __future__ import annotations

from . import baseline

PR_THRESHOLD = 0.20
NIGHTLY_THRESHOLD = 0.10
CALIBRATION_METRIC = "calibration.busyLoop"

MODE_ABSOLUTE = "absolute"
MODE_RATIO = "ratio"

# Absolute milliseconds and megabytes only mean the same thing on the same
# machine.  These are the host facts that have to match before an absolute
# comparison is worth anything; the reference hosts are pinned in design
# section I.2, and a CI runner is not one of them.
HOST_IDENTITY_FIELDS = ("os", "arch", "cpuCount")

# The calibration workload is a CPU-bound loop, so dividing by it only means
# something for metrics measured in the same kind of unit.  Dividing a resident
# set in bytes, or a descriptor count, by a duration produces a number with no
# interpretation, and it moves whenever the calibration moves — exactly the
# noise the ratio was meant to remove.
NORMALISABLE_UNITS = ("milliseconds", "seconds")

# Product ceilings from design section I.2 for metrics whose committed
# reference can sit on the instrument floor.  Idle CPU reads 0.0% on a quiet
# host, and a zero reference cannot express a relative change, so the absolute
# budget is the only thing such a metric can be judged against.  The budget is
# in the metric's own unit and applies in both modes; a ratio normalisation is
# never applied to it.
ABSOLUTE_BUDGETS: dict[str, float] = {
    # percent; design section I.2 row "idle/busy CPU、RSS、线程、fd/handle"
    "daemon.idleCpuPercent": 0.5,
}

# The recorded `scale` fields that define the workload the numbers were taken
# at.  The resident-set release fields also live under `scale`, but they are
# observations of one run rather than inputs and legitimately differ between
# runs, so they take no part in the comparability check.
WORKLOAD_SCALE_FIELDS = (
    "seedSeconds",
    "seedJobsPerCycle",
    "seedRestartIntervalSeconds",
    "jobListPageSize",
    "jobStoreRowCount",
)

ON_MISMATCH_FAIL = "fail"
ON_MISMATCH_SKIP = "skip"


class ComparisonError(RuntimeError):
    """A document could not be compared."""


def _measured_metrics(document: dict) -> dict[str, dict]:
    metrics = document.get("metrics")
    if not isinstance(metrics, dict):
        raise ComparisonError("document carries no metrics object")
    return {
        name: entry
        for name, entry in metrics.items()
        if isinstance(entry, dict) and entry.get("status") == baseline.STATUS_MEASURED
    }


def _aggregate_p95(entry: dict, name: str) -> float:
    aggregate = entry.get("aggregate")
    if not isinstance(aggregate, dict) or not isinstance(
        aggregate.get("p95"), (int, float)
    ):
        raise ComparisonError(f"metric {name} carries no aggregate p95")
    return float(aggregate["p95"])


def _calibration_p95(metrics: dict[str, dict], label: str) -> float:
    entry = metrics.get(CALIBRATION_METRIC)
    if entry is None:
        raise ComparisonError(
            f"the {label} document has no {CALIBRATION_METRIC} metric, so a "
            "ratio comparison cannot normalise it"
        )
    value = _aggregate_p95(entry, CALIBRATION_METRIC)
    if value <= 0:
        raise ComparisonError(
            f"the {label} calibration p95 is {value}, which cannot normalise"
        )
    return value


def _workload_scale(entry: dict, name: str, label: str) -> dict | None:
    """The workload fields of a metric's recorded scale, or None when absent.

    A document whose runs disagree on the workload has no single scale to be
    compared at, which is a malformed measurement rather than a comparison
    result, so it is refused outright.
    """

    scale = entry.get("scale")
    if scale is None:
        return None
    candidates = scale if isinstance(scale, list) else [scale]
    workloads = [
        {field: item.get(field) for field in WORKLOAD_SCALE_FIELDS}
        for item in candidates
        if isinstance(item, dict)
    ]
    if not workloads:
        raise ComparisonError(f"the {label} document's {name} scale is not an object")
    if any(workload != workloads[0] for workload in workloads):
        raise ComparisonError(
            f"the {label} document's {name} runs disagree on the workload scale, "
            "so it has no single scale to compare at"
        )
    return workloads[0]


def _scale_differences(left: dict | None, right: dict | None) -> list[str]:
    if left is None and right is None:
        return []
    if left is None or right is None:
        return ["one document records no workload scale for this metric"]
    return [
        f"{field}: {left.get(field)!r} vs {right.get(field)!r}"
        for field in WORKLOAD_SCALE_FIELDS
        if left.get(field) != right.get(field)
    ]


def host_mismatch(committed: dict, candidate: dict) -> list[str]:
    """Host identity fields on which the two documents disagree."""

    left = committed.get("host") or {}
    right = candidate.get("host") or {}
    return [
        f"{field}: {left.get(field)!r} vs {right.get(field)!r}"
        for field in HOST_IDENTITY_FIELDS
        if left.get(field) != right.get(field)
    ]


def compare(
    committed: dict,
    candidate: dict,
    *,
    mode: str = MODE_ABSOLUTE,
    threshold: float = NIGHTLY_THRESHOLD,
    on_host_mismatch: str = ON_MISMATCH_FAIL,
) -> dict:
    """Return a comparison document; the caller decides the exit code."""

    if mode not in (MODE_ABSOLUTE, MODE_RATIO):
        raise ComparisonError(f"unknown comparison mode {mode!r}")
    if threshold < 0:
        raise ComparisonError("threshold must not be negative")

    if on_host_mismatch not in (ON_MISMATCH_FAIL, ON_MISMATCH_SKIP):
        raise ComparisonError(f"unknown host-mismatch policy {on_host_mismatch!r}")

    # Neither mode survives a change of machine.  Absolute values obviously do
    # not, and a ratio against a CPU-bound calibration does not either: IPC
    # round-trip latency is dominated by scheduling and syscall cost rather than
    # CPU throughput, so the two sides move by different factors.  Design
    # section I.2 pins the budgets to a named reference host for this reason.
    mismatch = host_mismatch(committed, candidate)
    if mismatch:
        if on_host_mismatch == ON_MISMATCH_FAIL:
            raise ComparisonError(
                "a comparison needs the same host on both sides; these differ "
                "on " + ", ".join(mismatch) + ". Commit a baseline taken on the "
                "host being measured, or pass --on-host-mismatch skip to "
                "archive without comparing."
            )
        return {
            "schema": "arkdeck-perf-comparison-1.1.0",
            "mode": mode,
            "threshold": threshold,
            "hostMismatch": mismatch,
            "skipped": True,
            "committedGeneratedAtUtc": committed.get("generatedAtUtc"),
            "candidateGeneratedAtUtc": candidate.get("generatedAtUtc"),
            "comparisons": [],
            "regressions": [],
            "incomparable": [],
            "missingFromCandidate": [],
            "newInCandidate": [],
            "passed": True,
        }

    committed_metrics = _measured_metrics(committed)
    candidate_metrics = _measured_metrics(candidate)

    committed_calibration = 1.0
    candidate_calibration = 1.0
    if mode == MODE_RATIO:
        committed_calibration = _calibration_p95(committed_metrics, "committed")
        candidate_calibration = _calibration_p95(candidate_metrics, "candidate")

    regressions: list[dict] = []
    incomparable: list[dict] = []
    comparisons: list[dict] = []
    missing_from_candidate = sorted(set(committed_metrics) - set(candidate_metrics))
    new_in_candidate = sorted(set(candidate_metrics) - set(committed_metrics))

    for name in sorted(set(committed_metrics) & set(candidate_metrics)):
        if mode == MODE_RATIO and name == CALIBRATION_METRIC:
            continue
        scale_differences = _scale_differences(
            _workload_scale(committed_metrics[name], name, "committed"),
            _workload_scale(candidate_metrics[name], name, "candidate"),
        )
        if scale_differences:
            # The same p95 at a smaller workload is not the same result; a
            # candidate seeded with fewer Jobs would hide a regression.
            entry = {
                "metric": name,
                "comparable": False,
                "reason": "workload scale differs: " + ", ".join(scale_differences),
            }
            comparisons.append(entry)
            incomparable.append(entry)
            continue
        committed_value = _aggregate_p95(committed_metrics[name], name)
        candidate_value = _aggregate_p95(candidate_metrics[name], name)
        unit = committed_metrics[name].get("unit")
        if committed_value == 0:
            # A zero reference cannot express a relative change.  The absolute
            # product budget is the only judgement left; without one the metric
            # is unjudged, and an unjudged metric must not read as a pass.
            budget = ABSOLUTE_BUDGETS.get(name)
            if budget is None:
                entry = {
                    "metric": name,
                    "comparable": False,
                    "reason": (
                        "the committed reference value is zero and no absolute "
                        "budget is defined for this metric"
                    ),
                }
                comparisons.append(entry)
                incomparable.append(entry)
                continue
            entry = {
                "metric": name,
                "comparable": True,
                "basis": "absoluteBudget",
                "committed": committed_value,
                "candidate": candidate_value,
                "budget": budget,
                "threshold": threshold,
                "regressed": candidate_value > budget,
            }
            comparisons.append(entry)
            if entry["regressed"]:
                regressions.append(entry)
            continue
        if mode == MODE_RATIO and unit in NORMALISABLE_UNITS:
            committed_value /= committed_calibration
            candidate_value /= candidate_calibration
        delta = (candidate_value - committed_value) / committed_value
        entry = {
            "metric": name,
            "comparable": True,
            "basis": "relative",
            "committed": committed_value,
            "candidate": candidate_value,
            "deltaRatio": delta,
            "threshold": threshold,
            "regressed": delta > threshold,
        }
        comparisons.append(entry)
        if entry["regressed"]:
            regressions.append(entry)

    return {
        "schema": "arkdeck-perf-comparison-1.1.0",
        "mode": mode,
        "hostMismatch": mismatch,
        "skipped": False,
        "threshold": threshold,
        "committedGeneratedAtUtc": committed.get("generatedAtUtc"),
        "candidateGeneratedAtUtc": candidate.get("generatedAtUtc"),
        "comparisons": comparisons,
        "regressions": regressions,
        "incomparable": incomparable,
        "missingFromCandidate": missing_from_candidate,
        "newInCandidate": new_in_candidate,
        "passed": not regressions and not missing_from_candidate and not incomparable,
    }


def render(result: dict) -> str:
    """A short human summary for a workflow step summary."""

    lines = [
        f"mode={result['mode']} threshold=+{result['threshold'] * 100:.0f}%",
    ]
    for field in result.get("hostMismatch") or []:
        lines.append(f"  note: different host — {field}")
    if result.get("skipped"):
        lines.append(
            "  skipped: no committed baseline for this host; the measurement "
            "was archived, and this lane gates once one exists"
        )
        return "\n".join(lines)
    for entry in result["comparisons"]:
        if not entry.get("comparable"):
            lines.append(f"  !! {entry['metric']}: not comparable, {entry['reason']}")
            continue
        marker = "!!" if entry["regressed"] else "ok"
        if entry.get("basis") == "absoluteBudget":
            lines.append(
                f"  {marker} {entry['metric']}: zero reference; "
                f"{entry['candidate']:.4f} against the absolute budget "
                f"{entry['budget']:.4f}"
            )
            continue
        lines.append(
            f"  {marker} {entry['metric']}: "
            f"{entry['committed']:.4f} -> {entry['candidate']:.4f} "
            f"({entry['deltaRatio'] * 100:+.1f}%)"
        )
    for name in result["missingFromCandidate"]:
        lines.append(f"  !! {name}: present in the committed baseline, absent here")
    for name in result["newInCandidate"]:
        lines.append(f"  +  {name}: new metric, no committed reference")
    lines.append("PASS" if result["passed"] else "FAIL")
    return "\n".join(lines)
