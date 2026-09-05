"""Branch-complete tests for the baseline document assembler."""

from __future__ import annotations

import json
import math
import pathlib
import os
import unittest

from bench import __main__ as main
from bench import baseline


class PercentileTests(unittest.TestCase):
    def test_nearest_rank_uses_an_observed_sample(self) -> None:
        samples = [1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0]
        self.assertEqual(baseline.percentile(samples, 0.50), 5.0)
        self.assertEqual(baseline.percentile(samples, 0.95), 10.0)
        self.assertEqual(baseline.percentile(samples, 0.99), 10.0)

    def test_single_sample_is_every_percentile(self) -> None:
        for quantile in (0.5, 0.95, 0.99, 1.0):
            self.assertEqual(baseline.percentile([4.2], quantile), 4.2)

    def test_unsorted_input_is_ordered_first(self) -> None:
        self.assertEqual(baseline.percentile([9.0, 1.0, 5.0], 0.5), 5.0)

    def test_empty_samples_are_refused(self) -> None:
        with self.assertRaises(baseline.BaselineError):
            baseline.percentile([], 0.5)

    def test_out_of_range_quantiles_are_refused(self) -> None:
        for quantile in (0.0, -0.1, 1.1):
            with self.assertRaises(baseline.BaselineError):
                baseline.percentile([1.0], quantile)


class MedianTests(unittest.TestCase):
    def test_odd_length(self) -> None:
        self.assertEqual(baseline.median([3.0, 1.0, 2.0]), 2.0)

    def test_even_length_averages_the_middle_pair(self) -> None:
        self.assertEqual(baseline.median([1.0, 2.0, 3.0, 4.0]), 2.5)

    def test_empty_is_refused(self) -> None:
        with self.assertRaises(baseline.BaselineError):
            baseline.median([])


class SpreadTests(unittest.TestCase):
    def test_identical_runs_have_no_spread(self) -> None:
        self.assertEqual(baseline.spread_ratio([2.0, 2.0, 2.0]), 0.0)

    def test_spread_is_relative_to_the_median(self) -> None:
        self.assertAlmostEqual(baseline.spread_ratio([9.0, 10.0, 11.0]), 0.2)

    def test_identical_runs_at_zero_are_reproducible_not_undefined(self) -> None:
        # An idle daemon reads 0.0% CPU in every run; that is the most
        # reproducible result there is, and must not be scored as unstable.
        self.assertEqual(baseline.spread_ratio([0.0, 0.0, 0.0]), 0.0)

    def test_differing_values_around_a_zero_median_are_undefined(self) -> None:
        self.assertTrue(math.isinf(baseline.spread_ratio([-1.0, 0.0, 1.0])))

    def test_a_zero_median_with_differing_values_is_infinite(self) -> None:
        self.assertTrue(math.isinf(baseline.spread_ratio([0.0, 0.0, 4.0])))


class MetricResultTests(unittest.TestCase):
    def _metric(self) -> baseline.MetricResult:
        return baseline.MetricResult("ipc.health", "milliseconds", "I.2 row 4", "d")

    def test_stable_metric_passes_the_thirty_percent_rule(self) -> None:
        metric = self._metric()
        for offset in (0.0, 0.01, 0.02):
            metric.add_run([1.0 + offset] * 10)
        document = metric.as_document()
        self.assertTrue(document["stable"])
        self.assertEqual(document["status"], baseline.STATUS_MEASURED)
        self.assertLess(document["p95SpreadRatio"], baseline.MAXIMUM_P95_SPREAD_RATIO)

    def test_unstable_metric_fails_the_thirty_percent_rule(self) -> None:
        metric = self._metric()
        for value in (1.0, 1.5, 2.0):
            metric.add_run([value] * 10)
        self.assertFalse(metric.as_document()["stable"])

    def test_fewer_than_three_runs_is_never_stable(self) -> None:
        metric = self._metric()
        metric.add_run([1.0] * 10)
        metric.add_run([1.0] * 10)
        self.assertFalse(metric.as_document()["stable"])

    def test_a_metric_that_reads_zero_in_every_run_is_stable(self) -> None:
        metric = baseline.MetricResult("daemon.idleCpuPercent", "percent", "r", "d")
        for _ in range(3):
            metric.add_run([0.0] * 10)
        document = metric.as_document()
        self.assertTrue(document["stable"])
        self.assertEqual(document["p95SpreadRatio"], 0.0)

    def test_an_undefined_spread_is_reported_as_null_and_unstable(self) -> None:
        metric = baseline.MetricResult("m", "percent", "r", "d")
        for values in ([0.0] * 10, [0.0] * 10, [4.0] * 10):
            metric.add_run(values)
        document = metric.as_document()
        self.assertIsNone(document["p95SpreadRatio"])
        self.assertFalse(document["stable"])

    def test_a_metric_carries_the_scale_it_was_measured_at(self) -> None:
        metric = self._metric()
        scale = {"jobStoreRowCount": 30, "jobListPageSize": 50}
        for _ in range(3):
            metric.add_run([1.0] * 10, scale)
        document = metric.as_document()
        self.assertEqual(document["scale"], scale)
        self.assertTrue(document["scaleConsistentAcrossRuns"])

    def test_runs_measured_at_different_scales_keep_every_scale(self) -> None:
        metric = self._metric()
        for rows in (20, 30, 40):
            metric.add_run([1.0] * 10, {"jobStoreRowCount": rows})
        document = metric.as_document()
        self.assertFalse(document["scaleConsistentAcrossRuns"])
        self.assertEqual(
            [entry["jobStoreRowCount"] for entry in document["scale"]], [20, 30, 40]
        )

    def test_a_metric_without_a_scale_still_records_one(self) -> None:
        metric = self._metric()
        for _ in range(3):
            metric.add_run([1.0] * 10)
        self.assertEqual(metric.as_document()["scale"], {})

    def test_derived_budget_applies_the_documented_headroom(self) -> None:
        metric = self._metric()
        for _ in range(3):
            metric.add_run([2.0] * 10)
        document = metric.as_document()
        self.assertEqual(
            document["derivedBudget"], 2.0 * baseline.BUDGET_HEADROOM
        )


class GapTests(unittest.TestCase):
    def test_gap_records_a_reason_and_an_owner(self) -> None:
        gap = baseline.Gap("ui.frameResponse", "I.2 row 11", "needs UI", "UI lane")
        document = gap.as_document()
        self.assertEqual(document["status"], baseline.STATUS_NOT_MEASURED)
        self.assertEqual(document["blockedBy"], "UI lane")
        self.assertEqual(document["reason"], "needs UI")


class DocumentTests(unittest.TestCase):
    def _stable_metric(self, name: str = "ipc.health") -> baseline.MetricResult:
        metric = baseline.MetricResult(name, "milliseconds", "I.2 row 4", "d")
        for _ in range(3):
            metric.add_run([1.0] * 10)
        return metric

    def _build(self, **overrides: object) -> dict:
        arguments: dict = {
            "host": {"os": "Darwin"},
            "toolchain": {"buildConfiguration": "release"},
            "runs": [{"index": 0}],
            "metrics": {"ipc.health": self._stable_metric()},
            "gaps": {"ui.frameResponse": baseline.Gap("ui.frameResponse", "r", "x", "y")},
            "baseline_eligible": True,
            "eligibility_reason": "quiet",
        }
        arguments.update(overrides)
        return baseline.build_document(**arguments)

    def test_document_carries_the_schema_change_and_task(self) -> None:
        document = self._build()
        self.assertEqual(document["schema"], baseline.SCHEMA)
        self.assertEqual(document["change"], baseline.CHANGE_ID)
        self.assertEqual(document["task"], baseline.TASK_ID)
        self.assertEqual(document["spike"], baseline.SPIKE_ID)

    def test_gaps_and_metrics_share_one_sorted_table(self) -> None:
        document = self._build()
        self.assertEqual(list(document["metrics"]), ["ipc.health", "ui.frameResponse"])
        self.assertEqual(document["measuredMetricCount"], 1)
        self.assertEqual(document["gapCount"], 1)

    def test_a_metric_cannot_be_both_measured_and_a_gap(self) -> None:
        with self.assertRaises(baseline.BaselineError):
            self._build(
                gaps={"ipc.health": baseline.Gap("ipc.health", "r", "x", "y")}
            )

    def test_an_unstable_metric_fails_the_spike_and_the_eligibility(self) -> None:
        unstable = baseline.MetricResult("ipc.health", "milliseconds", "r", "d")
        for value in (1.0, 2.0, 3.0):
            unstable.add_run([value] * 10)
        document = self._build(metrics={"ipc.health": unstable})
        self.assertEqual(document["spikeVerdict"], "UNSTABLE")
        self.assertEqual(document["unstableMetrics"], ["ipc.health"])
        self.assertFalse(document["baselineEligible"])

    def test_a_declared_ineligible_run_stays_ineligible_when_stable(self) -> None:
        document = self._build(baseline_eligible=False, eligibility_reason="debug")
        self.assertEqual(document["spikeVerdict"], "PASS")
        self.assertFalse(document["baselineEligible"])
        self.assertEqual(document["eligibilityReason"], "debug")


class RedactionTests(unittest.TestCase):
    def test_home_directory_is_refused(self) -> None:
        home = os.path.expanduser("~")
        with self.assertRaises(baseline.BaselineError):
            baseline.assert_no_host_identity(json.dumps({"path": home}))

    def test_any_user_home_prefix_is_refused(self) -> None:
        with self.assertRaises(baseline.BaselineError):
            baseline.assert_no_host_identity('{"path": "/Users/someoneelse/x"}')
        with self.assertRaises(baseline.BaselineError):
            baseline.assert_no_host_identity('{"path": "/home/someoneelse/x"}')

    def test_a_clean_document_passes(self) -> None:
        baseline.assert_no_host_identity('{"os": "Darwin", "arch": "arm64"}')

    def test_serialize_runs_the_gate_before_returning_bytes(self) -> None:
        with self.assertRaises(baseline.BaselineError):
            baseline.serialize({"path": os.path.expanduser("~")})

    def test_serialize_is_deterministic_and_newline_terminated(self) -> None:
        serialized = baseline.serialize({"b": 1, "a": 2})
        self.assertEqual(serialized, '{\n  "a": 2,\n  "b": 1\n}\n')


class AdvisoryDeclarationTests(unittest.TestCase):
    """`--allow-loaded-host` must disqualify unconditionally.

    A shared runner is often quiet when a run starts and busy while it runs,
    which the start-of-run guard cannot see.  If the flag only disqualified
    when the guard tripped, such a capture would be treated as baseline-quality
    and its expected instability would fail the step.
    """

    def test_the_flag_is_wired_to_disqualify_before_any_run(self) -> None:
        source = (
            pathlib.Path(main.__file__).read_text(encoding="utf-8")
        )
        declaration = source.index("if arguments.allow_loaded_host:")
        loop = source.index("for index in range(arguments.runs):")
        self.assertLess(declaration, loop)


class CaptureExitCodeTests(unittest.TestCase):
    def test_a_clean_eligible_capture_succeeds(self) -> None:
        self.assertEqual(main.capture_exit_code([], []), 0)

    def test_an_unstable_eligible_capture_fails_the_spike(self) -> None:
        self.assertEqual(main.capture_exit_code(["ipc.health"], []), 2)

    def test_an_unstable_advisory_capture_is_not_an_error(self) -> None:
        # A shared CI runner is noisy by definition; failing here would kill the
        # step before the ratio comparison that actually gates that lane.
        self.assertEqual(
            main.capture_exit_code(["ipc.health"], ["loaded host"]), 0
        )

    def test_a_clean_advisory_capture_succeeds(self) -> None:
        self.assertEqual(main.capture_exit_code([], ["debug build"]), 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
