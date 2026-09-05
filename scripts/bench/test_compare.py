"""Branch-complete tests for the regression comparison."""

from __future__ import annotations

import unittest

from bench import baseline, compare


REFERENCE_HOST = {"os": "Darwin", "arch": "arm64", "cpuCount": 8}


def document(host: dict | None = None, unit: str = "milliseconds", **metrics: float) -> dict:
    return {
        "generatedAtUtc": "2026-09-04T00:00:00Z",
        "host": dict(REFERENCE_HOST if host is None else host),
        "metrics": {
            name: {
                "status": baseline.STATUS_MEASURED,
                "unit": unit,
                "aggregate": {"p50": value, "p95": value, "p99": value},
            }
            for name, value in metrics.items()
        },
    }


class AbsoluteComparisonTests(unittest.TestCase):
    def test_unchanged_metrics_pass(self) -> None:
        result = compare.compare(document(a=10.0), document(a=10.0), threshold=0.10)
        self.assertTrue(result["passed"])
        self.assertEqual(result["regressions"], [])

    def test_drift_below_the_threshold_passes(self) -> None:
        result = compare.compare(document(a=10.0), document(a=10.9), threshold=0.10)
        self.assertTrue(result["passed"])

    def test_drift_exactly_at_the_threshold_passes(self) -> None:
        result = compare.compare(document(a=10.0), document(a=11.0), threshold=0.10)
        self.assertTrue(result["passed"])

    def test_drift_above_the_threshold_regresses(self) -> None:
        result = compare.compare(document(a=10.0), document(a=11.5), threshold=0.10)
        self.assertFalse(result["passed"])
        self.assertEqual(result["regressions"][0]["metric"], "a")

    def test_an_improvement_never_regresses(self) -> None:
        result = compare.compare(document(a=10.0), document(a=1.0), threshold=0.10)
        self.assertTrue(result["passed"])

    def test_pr_and_nightly_thresholds_are_the_documented_values(self) -> None:
        self.assertEqual(compare.PR_THRESHOLD, 0.20)
        self.assertEqual(compare.NIGHTLY_THRESHOLD, 0.10)


class CoverageTests(unittest.TestCase):
    def test_a_metric_missing_from_the_candidate_fails(self) -> None:
        result = compare.compare(document(a=1.0, b=2.0), document(a=1.0))
        self.assertFalse(result["passed"])
        self.assertEqual(result["missingFromCandidate"], ["b"])

    def test_a_new_metric_is_reported_without_failing(self) -> None:
        result = compare.compare(document(a=1.0), document(a=1.0, b=2.0))
        self.assertTrue(result["passed"])
        self.assertEqual(result["newInCandidate"], ["b"])

    def test_a_gap_entry_is_not_compared(self) -> None:
        committed = document(a=1.0)
        committed["metrics"]["ui"] = {"status": baseline.STATUS_NOT_MEASURED}
        candidate = document(a=1.0)
        candidate["metrics"]["ui"] = {"status": baseline.STATUS_NOT_MEASURED}
        result = compare.compare(committed, candidate)
        self.assertTrue(result["passed"])
        self.assertEqual([entry["metric"] for entry in result["comparisons"]], ["a"])

    def test_a_zero_reference_without_a_budget_fails_closed(self) -> None:
        # Before this test the entry was reported as incomparable and the
        # comparison still passed, so a metric with a zero reference could not
        # regress at all; a candidate of 100 sailed through.
        result = compare.compare(document(a=0.0), document(a=100.0))
        entry = result["comparisons"][0]
        self.assertFalse(entry["comparable"])
        self.assertEqual([item["metric"] for item in result["incomparable"]], ["a"])
        self.assertFalse(result["passed"])
        self.assertIn("!! a:", compare.render(result))


IDLE_CPU = "daemon.idleCpuPercent"


def with_calibration(doc: dict, value: float = 1.0) -> dict:
    doc["metrics"][compare.CALIBRATION_METRIC] = {
        "status": baseline.STATUS_MEASURED,
        "unit": "milliseconds",
        "aggregate": {"p50": value, "p95": value, "p99": value},
    }
    return doc


class ZeroReferenceBudgetTests(unittest.TestCase):
    def test_the_documented_idle_cpu_budget_is_half_a_percent(self) -> None:
        # Design section I.2 keeps the product ceiling when the measurement sits
        # on the instrument floor; 0.5% is that ceiling.
        self.assertEqual(compare.ABSOLUTE_BUDGETS[IDLE_CPU], 0.5)

    def test_a_candidate_within_the_budget_passes(self) -> None:
        result = compare.compare(
            document(unit="percent", **{IDLE_CPU: 0.0}),
            document(unit="percent", **{IDLE_CPU: 0.3}),
        )
        entry = result["comparisons"][0]
        self.assertTrue(entry["comparable"])
        self.assertEqual(entry["basis"], "absoluteBudget")
        self.assertEqual(entry["budget"], 0.5)
        self.assertFalse(entry["regressed"])
        self.assertTrue(result["passed"])
        self.assertIn("absolute budget", compare.render(result))

    def test_a_candidate_over_the_budget_regresses(self) -> None:
        result = compare.compare(
            document(unit="percent", **{IDLE_CPU: 0.0}),
            document(unit="percent", **{IDLE_CPU: 100.0}),
        )
        self.assertTrue(result["comparisons"][0]["regressed"])
        self.assertEqual([item["metric"] for item in result["regressions"]], [IDLE_CPU])
        self.assertFalse(result["passed"])

    def test_the_budget_also_applies_in_ratio_mode(self) -> None:
        # The ratio lane normalises durations by the calibration workload; a
        # percentage is not a duration and the budget is absolute either way.
        result = compare.compare(
            with_calibration(document(unit="percent", **{IDLE_CPU: 0.0})),
            with_calibration(document(unit="percent", **{IDLE_CPU: 100.0}), value=2.0),
            mode=compare.MODE_RATIO,
            threshold=compare.PR_THRESHOLD,
        )
        self.assertFalse(result["passed"])
        self.assertEqual(result["comparisons"][0]["candidate"], 100.0)


WORKLOAD = {
    "seedSeconds": 6,
    "seedJobsPerCycle": 10,
    "seedRestartIntervalSeconds": 1,
    "jobListPageSize": 50,
    "jobStoreRowCount": 30,
}


def scaled(doc: dict, scale: object) -> dict:
    for entry in doc["metrics"].values():
        entry["scale"] = scale
    return doc


class WorkloadScaleTests(unittest.TestCase):
    def test_matching_workload_scales_compare(self) -> None:
        result = compare.compare(
            scaled(document(a=10.0), dict(WORKLOAD)),
            scaled(document(a=10.5), dict(WORKLOAD)),
        )
        self.assertTrue(result["comparisons"][0]["comparable"])
        self.assertTrue(result["passed"])

    def test_a_smaller_candidate_workload_is_incomparable_and_fails(self) -> None:
        # The same p95 over one row instead of thirty is not the same result;
        # before this test the comparison passed regardless of scale.
        smaller = dict(WORKLOAD, jobStoreRowCount=1)
        result = compare.compare(
            scaled(document(a=10.0), dict(WORKLOAD)),
            scaled(document(a=10.0), smaller),
        )
        entry = result["comparisons"][0]
        self.assertFalse(entry["comparable"])
        self.assertIn("jobStoreRowCount: 30 vs 1", entry["reason"])
        self.assertFalse(result["passed"])

    def test_a_different_seed_duration_is_incomparable(self) -> None:
        result = compare.compare(
            scaled(document(a=10.0), dict(WORKLOAD)),
            scaled(document(a=10.0), dict(WORKLOAD, seedSeconds=4)),
        )
        self.assertIn("seedSeconds: 6 vs 4", result["comparisons"][0]["reason"])
        self.assertFalse(result["passed"])

    def test_release_observations_may_differ_between_runs(self) -> None:
        # A document whose runs disagree only on the resident-set release
        # observation keeps every scale as a list; the workload is still one.
        runs = [
            dict(WORKLOAD, residentSetReleaseAtSeconds=82, residentSetReleaseObserved=True),
            dict(WORKLOAD, residentSetReleaseAtSeconds=16, residentSetReleaseObserved=True),
        ]
        result = compare.compare(
            scaled(document(a=10.0), runs),
            scaled(document(a=10.0), dict(WORKLOAD, residentSetReleaseAtSeconds=40)),
        )
        self.assertTrue(result["comparisons"][0]["comparable"])
        self.assertTrue(result["passed"])

    def test_a_scale_missing_on_one_side_is_incomparable(self) -> None:
        result = compare.compare(
            scaled(document(a=10.0), dict(WORKLOAD)),
            document(a=10.0),
        )
        self.assertFalse(result["comparisons"][0]["comparable"])
        self.assertFalse(result["passed"])

    def test_documents_without_any_scale_still_compare(self) -> None:
        # Synthetic and pre-1.1.0 documents carry no scale at all; that is a
        # known state, not a drift between two measurements.
        result = compare.compare(document(a=10.0), document(a=10.0))
        self.assertTrue(result["passed"])

    def test_runs_disagreeing_on_workload_within_a_document_are_refused(self) -> None:
        runs = [dict(WORKLOAD), dict(WORKLOAD, jobStoreRowCount=20)]
        with self.assertRaises(compare.ComparisonError):
            compare.compare(scaled(document(a=10.0), runs), scaled(document(a=10.0), dict(WORKLOAD)))


class RatioComparisonTests(unittest.TestCase):
    def test_a_uniformly_slower_runner_is_not_a_regression(self) -> None:
        committed = document(**{"ipc.health": 1.0, compare.CALIBRATION_METRIC: 2.0})
        # Every number doubled: a slower machine, not a slower product.
        candidate = document(**{"ipc.health": 2.0, compare.CALIBRATION_METRIC: 4.0})
        absolute = compare.compare(committed, candidate, threshold=0.20)
        self.assertFalse(absolute["passed"])
        ratio = compare.compare(
            committed, candidate, mode=compare.MODE_RATIO, threshold=0.20
        )
        self.assertTrue(ratio["passed"])

    def test_a_real_regression_still_fails_under_ratio_mode(self) -> None:
        committed = document(**{"ipc.health": 1.0, compare.CALIBRATION_METRIC: 2.0})
        candidate = document(**{"ipc.health": 4.0, compare.CALIBRATION_METRIC: 4.0})
        result = compare.compare(
            committed, candidate, mode=compare.MODE_RATIO, threshold=0.20
        )
        self.assertFalse(result["passed"])

    def test_the_calibration_metric_is_not_compared_against_itself(self) -> None:
        committed = document(**{"a": 1.0, compare.CALIBRATION_METRIC: 2.0})
        candidate = document(**{"a": 1.0, compare.CALIBRATION_METRIC: 2.0})
        result = compare.compare(committed, candidate, mode=compare.MODE_RATIO)
        self.assertEqual([entry["metric"] for entry in result["comparisons"]], ["a"])

    def test_a_missing_calibration_metric_is_refused(self) -> None:
        with self.assertRaises(compare.ComparisonError):
            compare.compare(document(a=1.0), document(a=1.0), mode=compare.MODE_RATIO)

    def test_a_zero_calibration_is_refused(self) -> None:
        committed = document(**{"a": 1.0, compare.CALIBRATION_METRIC: 0.0})
        with self.assertRaises(compare.ComparisonError):
            compare.compare(committed, committed, mode=compare.MODE_RATIO)


class InputValidationTests(unittest.TestCase):
    def test_an_unknown_mode_is_refused(self) -> None:
        with self.assertRaises(compare.ComparisonError):
            compare.compare(document(a=1.0), document(a=1.0), mode="guess")

    def test_a_negative_threshold_is_refused(self) -> None:
        with self.assertRaises(compare.ComparisonError):
            compare.compare(document(a=1.0), document(a=1.0), threshold=-0.1)

    def test_a_document_without_metrics_is_refused(self) -> None:
        with self.assertRaises(compare.ComparisonError):
            compare.compare({}, document(a=1.0))

    def test_a_metric_without_an_aggregate_is_refused(self) -> None:
        broken = {"metrics": {"a": {"status": baseline.STATUS_MEASURED}}}
        with self.assertRaises(compare.ComparisonError):
            compare.compare(broken, document(a=1.0))


class HostIdentityTests(unittest.TestCase):
    def test_matching_hosts_report_no_mismatch(self) -> None:
        self.assertEqual(compare.host_mismatch(document(a=1.0), document(a=1.0)), [])

    def test_a_different_core_count_is_a_mismatch(self) -> None:
        other = dict(REFERENCE_HOST, cpuCount=3)
        mismatch = compare.host_mismatch(document(a=1.0), document(other, a=1.0))
        self.assertEqual(len(mismatch), 1)
        self.assertIn("cpuCount", mismatch[0])

    def test_absolute_mode_refuses_a_different_host(self) -> None:
        other = dict(REFERENCE_HOST, cpuCount=3)
        with self.assertRaises(compare.ComparisonError) as raised:
            compare.compare(document(a=1.0), document(other, a=1.0))
        self.assertIn("--on-host-mismatch skip", str(raised.exception))

    def test_ratio_mode_also_refuses_a_different_host(self) -> None:
        # A ratio against a CPU-bound calibration does not survive a change of
        # machine either: IPC latency is dominated by scheduling, not CPU.
        other = dict(REFERENCE_HOST, cpuCount=3)
        committed = document(**{"a": 1.0, compare.CALIBRATION_METRIC: 2.0})
        candidate = document(other, **{"a": 2.0, compare.CALIBRATION_METRIC: 4.0})
        with self.assertRaises(compare.ComparisonError):
            compare.compare(committed, candidate, mode=compare.MODE_RATIO)

    def test_skip_policy_archives_without_comparing_and_says_so(self) -> None:
        other = dict(REFERENCE_HOST, cpuCount=3)
        result = compare.compare(
            document(a=1.0),
            document(other, a=99.0),
            on_host_mismatch=compare.ON_MISMATCH_SKIP,
        )
        self.assertTrue(result["skipped"])
        self.assertTrue(result["passed"])
        self.assertEqual(result["comparisons"], [])
        self.assertIn("gates once one exists", compare.render(result))

    def test_an_unknown_mismatch_policy_is_refused(self) -> None:
        with self.assertRaises(compare.ComparisonError):
            compare.compare(document(a=1.0), document(a=1.0), on_host_mismatch="maybe")

    def test_a_same_host_comparison_is_not_marked_skipped(self) -> None:
        result = compare.compare(document(a=1.0), document(a=1.0))
        self.assertFalse(result["skipped"])

    def test_absolute_mode_still_works_on_the_same_host(self) -> None:
        result = compare.compare(document(a=1.0), document(a=1.0))
        self.assertTrue(result["passed"])
        self.assertEqual(result["hostMismatch"], [])

    def test_a_missing_host_block_counts_as_a_mismatch(self) -> None:
        candidate = document(a=1.0)
        del candidate["host"]
        with self.assertRaises(compare.ComparisonError):
            compare.compare(document(a=1.0), candidate)


class RatioUnitTests(unittest.TestCase):
    """Only time-unit metrics are normalised by the calibration workload."""

    def _pair(self, unit: str) -> tuple[dict, dict]:
        committed = document(unit=unit, **{"m": 100.0})
        committed["metrics"][compare.CALIBRATION_METRIC] = {
            "status": baseline.STATUS_MEASURED,
            "unit": "milliseconds",
            "aggregate": {"p50": 2.0, "p95": 2.0, "p99": 2.0},
        }
        candidate = document(unit=unit, **{"m": 100.0})
        candidate["metrics"][compare.CALIBRATION_METRIC] = {
            "status": baseline.STATUS_MEASURED,
            "unit": "milliseconds",
            "aggregate": {"p50": 4.0, "p95": 4.0, "p99": 4.0},
        }
        return committed, candidate

    def test_a_duration_is_divided_by_the_calibration(self) -> None:
        committed, candidate = self._pair("milliseconds")
        entry = compare.compare(
            committed, candidate, mode=compare.MODE_RATIO
        )["comparisons"][0]
        self.assertEqual(entry["committed"], 50.0)
        self.assertEqual(entry["candidate"], 25.0)

    def test_bytes_are_compared_directly(self) -> None:
        # Dividing a resident set by a duration has no interpretation, and it
        # would move whenever the calibration moved.
        committed, candidate = self._pair("bytes")
        entry = compare.compare(
            committed, candidate, mode=compare.MODE_RATIO
        )["comparisons"][0]
        self.assertEqual(entry["committed"], 100.0)
        self.assertEqual(entry["candidate"], 100.0)
        self.assertEqual(entry["deltaRatio"], 0.0)

    def test_counts_are_compared_directly(self) -> None:
        committed, candidate = self._pair("count")
        entry = compare.compare(
            committed, candidate, mode=compare.MODE_RATIO
        )["comparisons"][0]
        self.assertEqual(entry["committed"], entry["candidate"])

    def test_the_normalisable_units_are_pinned(self) -> None:
        self.assertEqual(compare.NORMALISABLE_UNITS, ("milliseconds", "seconds"))


class RenderTests(unittest.TestCase):
    def test_render_names_every_regression_and_ends_with_a_verdict(self) -> None:
        result = compare.compare(document(a=10.0, b=1.0), document(a=20.0, b=1.0))
        rendered = compare.render(result)
        self.assertIn("!! a", rendered)
        self.assertIn("ok b", rendered)
        self.assertTrue(rendered.endswith("FAIL"))

    def test_render_reports_a_missing_metric(self) -> None:
        rendered = compare.render(compare.compare(document(a=1.0, b=1.0), document(a=1.0)))
        self.assertIn("absent here", rendered)


if __name__ == "__main__":
    unittest.main(verbosity=2)
