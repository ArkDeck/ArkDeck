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

    def test_a_zero_reference_is_incomparable_rather_than_a_pass(self) -> None:
        result = compare.compare(document(a=0.0), document(a=5.0))
        entry = result["comparisons"][0]
        self.assertFalse(entry["comparable"])
        self.assertTrue(result["passed"])


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
