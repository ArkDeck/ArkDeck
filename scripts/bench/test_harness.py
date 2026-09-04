"""Tests for the clocks, the transport client and the host guards.

Includes the static import audit this repository's harnesses carry: the
measurement modules must stay stdlib-only and must not reach for a device
transport, a shell string or the installed daemon's state directory.
"""

from __future__ import annotations

import ast
import os
import pathlib
import time
import unittest
from unittest import mock

from bench import baseline, clocks, control, harness, metrics

PACKAGE = pathlib.Path(__file__).resolve().parent
MODULES = (
    "__init__.py",
    "__main__.py",
    "baseline.py",
    "clocks.py",
    "compare.py",
    "harness.py",
    "metrics.py",
)
STDLIB_ONLY = {
    "argparse",
    "ast",
    "datetime",
    "json",
    "math",
    "os",
    "pathlib",
    "platform",
    "re",
    "shutil",
    "socket",
    "subprocess",
    "sys",
    "tempfile",
    "time",
    "unittest",
    "uuid",
    "__future__",
}


class ClockTests(unittest.TestCase):
    def test_both_clocks_resolve_to_a_real_attribute(self) -> None:
        identity = clocks.clock_identity()
        for name in identity.values():
            self.assertTrue(hasattr(time, name), name)

    def test_the_two_roles_do_not_collapse_onto_one_clock_on_darwin(self) -> None:
        if os.uname().sysname != "Darwin":
            self.skipTest("clock role mapping is asserted per platform")
        identity = clocks.clock_identity()
        self.assertEqual(identity["continuousClock"], "CLOCK_MONOTONIC")
        self.assertEqual(identity["awakeWorkClock"], "CLOCK_UPTIME_RAW")

    def test_readings_advance_and_never_go_backwards(self) -> None:
        for reader in (clocks.elapsed_seconds, clocks.awake_seconds):
            first = reader()
            second = reader()
            self.assertGreaterEqual(second, first)

    def test_missing_clocks_fail_closed_rather_than_substituting(self) -> None:
        with mock.patch.object(clocks, "_CONTINUOUS_CANDIDATES", ("CLOCK_NOPE",)):
            with self.assertRaises(clocks.ClockUnavailable):
                clocks._continuous_name()
        with mock.patch.object(clocks, "_AWAKE_CANDIDATES", ("CLOCK_NOPE",)):
            with self.assertRaises(clocks.ClockUnavailable):
                clocks._awake_name()

    def test_utc_now_is_an_audit_timestamp(self) -> None:
        stamp = clocks.utc_now()
        self.assertRegex(stamp, r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")

    def test_deadline_reports_consumption_without_exposing_its_origin(self) -> None:
        deadline = clocks.Deadline(10.0)
        self.assertFalse(deadline.expired())
        self.assertGreaterEqual(deadline.consumed_seconds(), 0.0)
        self.assertLessEqual(deadline.remaining_seconds(), 10.0)
        self.assertFalse(hasattr(deadline, "origin"))

    def test_a_non_positive_budget_is_refused(self) -> None:
        for budget in (0.0, -1.0):
            with self.assertRaises(ValueError):
                clocks.Deadline(budget)

    def test_an_expired_deadline_reports_expiry(self) -> None:
        deadline = clocks.Deadline(0.001)
        time.sleep(0.01)
        self.assertTrue(deadline.expired())


class HostGuardTests(unittest.TestCase):
    def test_a_quiet_host_is_accepted(self) -> None:
        with mock.patch.object(harness, "load_average", return_value=(0.1, 0.1, 0.1)):
            self.assertEqual(harness.assert_host_is_quiet(), 0.1)

    def test_a_loaded_host_is_refused_with_an_actionable_message(self) -> None:
        busy = harness.quiet_load_ceiling() + 10.0
        with mock.patch.object(harness, "load_average", return_value=(busy, busy, busy)):
            with self.assertRaises(harness.HostTooBusy) as raised:
                harness.assert_host_is_quiet()
        self.assertIn("--allow-loaded-host", str(raised.exception))

    def test_the_ceiling_follows_the_cpu_count(self) -> None:
        with mock.patch.object(harness, "cpu_count", return_value=8):
            self.assertEqual(harness.quiet_load_ceiling(), 8 * harness.QUIET_LOAD_RATIO)

    def test_host_facts_carry_no_host_or_user_identity(self) -> None:
        # The gate that guards the committed document must accept these facts.
        baseline.assert_no_host_identity(str(harness.host_facts()))
        self.assertEqual(
            set(harness.host_facts()),
            {"os", "osVersion", "arch", "cpuCount", "python"},
        )


class SocketPathTests(unittest.TestCase):
    def test_an_over_long_socket_path_is_refused_before_spawning(self) -> None:
        long_directory = pathlib.Path("/tmp/" + "d" * 200)
        with self.assertRaises(ValueError):
            harness.IsolatedRuntime(pathlib.Path("/bin/true"), long_directory)

    def test_a_short_temporary_directory_fits(self) -> None:
        directory = harness.temporary_state_directory()
        try:
            runtime = harness.IsolatedRuntime(pathlib.Path("/bin/true"), directory)
            self.assertEqual(runtime.socket_path.name, harness.SOCKET_NAME)
            self.assertLessEqual(
                len(str(runtime.socket_path).encode()),
                harness.MAXIMUM_SOCKET_PATH_BYTES,
            )
        finally:
            directory.rmdir()


class ResourceSampleTests(unittest.TestCase):
    def test_an_unmeasurable_field_is_none_with_a_reason_never_zero(self) -> None:
        sample = harness.ProcessResources()
        document = sample.as_document()
        for field in (
            "residentSetBytes",
            "cpuPercent",
            "threadCount",
            "openFileDescriptorCount",
        ):
            self.assertIsNone(document[field])

    def test_this_process_reports_a_plausible_resident_set(self) -> None:
        sample = harness.sample_process_resources(os.getpid())
        self.assertIsNotNone(sample.resident_set_bytes)
        self.assertGreater(sample.resident_set_bytes, 0)


class ControlClientTests(unittest.TestCase):
    def test_a_call_before_negotiation_is_refused(self) -> None:
        client = control.ControlClient("/nonexistent.sock")
        with self.assertRaises(control.ControlError):
            client.call("health")

    def test_connecting_to_a_missing_socket_reports_the_path(self) -> None:
        client = control.ControlClient("/nonexistent/agentd.sock")
        with self.assertRaises(control.ControlError) as raised:
            client.connect()
        self.assertIn("agentd.sock", str(raised.exception))

    def test_the_supported_versions_match_the_generated_contract(self) -> None:
        self.assertEqual(control.SUPPORTED_EXACT_VERSIONS, ("2.0.0", "1.0.0"))
        self.assertEqual(control.BOOTSTRAP_METHOD, "protocol.negotiate")
        self.assertEqual(control.BOOTSTRAP_VERSION, "arkdeck.control.negotiation/1")


class MetricTableTests(unittest.TestCase):
    def test_every_measured_metric_names_its_design_row(self) -> None:
        for name, (unit, design_row, description) in metrics.METRIC_DEFINITIONS.items():
            self.assertTrue(unit, name)
            self.assertTrue(design_row, name)
            self.assertTrue(description, name)

    def test_every_gap_names_a_reason_and_what_blocks_it(self) -> None:
        for name, gap in metrics.gap_definitions().items():
            self.assertEqual(gap.metric_id, name)
            self.assertTrue(gap.reason, name)
            self.assertTrue(gap.blocked_by, name)

    def test_no_metric_is_both_measured_and_a_gap(self) -> None:
        self.assertEqual(
            set(metrics.METRIC_DEFINITIONS) & set(metrics.gap_definitions()), set()
        )

    def test_the_twelve_design_rows_are_all_accounted_for(self) -> None:
        rows = {
            entry[1].split("(")[0].strip()
            for entry in metrics.METRIC_DEFINITIONS.values()
        } | {
            gap.design_row.split("(")[0].strip()
            for gap in metrics.gap_definitions().values()
        }
        numbered = {row for row in rows if row.startswith("I.2 row")}
        self.assertEqual(
            numbered,
            {
                "I.2 row 1",
                "I.2 rows 2 and 7",
                "I.2 row 3",
                "I.2 row 4",
                "I.2 row 5",
                "I.2 row 6",
                "I.2 row 8",
                "I.2 row 9",
                "I.2 row 10",
                "I.2 row 11",
                "I.2 row 12",
            },
        )

    def test_the_seed_restart_interval_is_pinned(self) -> None:
        # The soak fixture completes one cycle per restart interval, so this
        # constant — not jobs-per-cycle alone — decides the store size every
        # per-row figure divides by.
        self.assertEqual(metrics.SEED_RESTART_INTERVAL_SECONDS, 1)
        self.assertEqual(metrics.JOB_LIST_PAGE_SIZE, 50)

    def test_the_resource_window_runs_on_a_freshly_started_daemon(self) -> None:
        # A behavioural assertion needs a real daemon, so this pins the source
        # order instead: the IPC session must be stopped and a new daemon
        # started before the resource sampling loop.
        source = (PACKAGE / "metrics.py").read_text(encoding="utf-8")
        ipc = source.index("with runtime.client() as client:")
        sampling = source.index("harness.sample_process_resources(pid)")
        between = source[ipc:sampling]
        self.assertIn("runtime.stop()", between)
        self.assertIn("runtime.start()", between.split("runtime.stop()", 1)[1])

    def test_execute_run_returns_samples_and_the_scale(self) -> None:
        tree = ast.parse((PACKAGE / "metrics.py").read_text(encoding="utf-8"))
        function = next(
            node
            for node in ast.walk(tree)
            if isinstance(node, ast.FunctionDef) and node.name == "execute_run"
        )
        returns = [n for n in ast.walk(function) if isinstance(n, ast.Return)]
        self.assertTrue(returns)
        self.assertIsInstance(returns[-1].value, ast.Tuple)
        self.assertEqual(len(returns[-1].value.elts), 2)

    def test_the_calibration_workload_returns_a_positive_duration(self) -> None:
        self.assertGreater(metrics.calibration_sample(), 0.0)


class ResidentSetSplitTests(unittest.TestCase):
    def test_a_two_level_series_splits_at_the_release(self) -> None:
        series = [73.5] * 10 + [21.4] * 20
        plateau, steady, index = metrics.split_at_release(series)
        self.assertEqual(index, 10)
        self.assertEqual(plateau, [73.5] * 10)
        self.assertEqual(steady, [21.4] * 20)

    def test_a_flat_series_reports_no_release_and_one_level(self) -> None:
        series = [50.0] * 30
        plateau, steady, index = metrics.split_at_release(series)
        self.assertIsNone(index)
        self.assertEqual(plateau, series)
        self.assertEqual(steady, series)

    def test_small_wobble_is_not_a_release(self) -> None:
        series = [50.0, 49.5, 50.2, 49.8, 50.1]
        _, _, index = metrics.split_at_release(series)
        self.assertIsNone(index)

    def test_the_largest_qualifying_step_wins(self) -> None:
        series = [100.0, 70.0, 70.0, 10.0, 10.0]
        plateau, steady, index = metrics.split_at_release(series)
        self.assertEqual(index, 3)
        self.assertEqual(steady, [10.0, 10.0])

    def test_an_empty_or_single_sample_series_is_safe(self) -> None:
        for series in ([], [42.0]):
            plateau, steady, index = metrics.split_at_release(series)
            self.assertIsNone(index)
            self.assertEqual(plateau, series)
            self.assertEqual(steady, series)

    def test_the_release_fraction_is_pinned(self) -> None:
        self.assertEqual(metrics.RESIDENT_SET_RELEASE_FRACTION, 0.25)

    def test_both_resident_set_levels_are_declared_metrics(self) -> None:
        self.assertIn("daemon.residentSetPlateau", metrics.METRIC_DEFINITIONS)
        self.assertIn("daemon.residentSetSteady", metrics.METRIC_DEFINITIONS)
        self.assertNotIn("daemon.idleResidentSetBytes", metrics.METRIC_DEFINITIONS)


class StaticImportAudit(unittest.TestCase):
    """The harness stays stdlib-only and never reaches a device."""

    def _imports(self, module: str) -> set[str]:
        tree = ast.parse((PACKAGE / module).read_text(encoding="utf-8"))
        names: set[str] = set()
        for node in ast.walk(tree):
            if isinstance(node, ast.Import):
                names.update(alias.name.split(".")[0] for alias in node.names)
            elif isinstance(node, ast.ImportFrom) and node.level == 0 and node.module:
                names.add(node.module.split(".")[0])
        return names

    def test_only_the_standard_library_is_imported(self) -> None:
        for module in MODULES:
            self.assertLessEqual(self._imports(module), STDLIB_ONLY, module)

    @staticmethod
    def _dotted_name(node: ast.expr) -> str:
        parts: list[str] = []
        while isinstance(node, ast.Attribute):
            parts.append(node.attr)
            node = node.value
        if isinstance(node, ast.Name):
            parts.append(node.id)
        return ".".join(reversed(parts))

    def test_no_module_shells_out_through_a_string_command(self) -> None:
        # POL-WORKFLOW-001 requires an executable plus an argument array; a
        # shell string is forbidden even in host-only measurement tooling.
        for module in MODULES:
            tree = ast.parse((PACKAGE / module).read_text(encoding="utf-8"))
            for node in ast.walk(tree):
                if not isinstance(node, ast.Call):
                    continue
                dotted = self._dotted_name(node.func)
                self.assertNotIn(dotted, {"os.system", "os.popen"}, module)
                if dotted.rsplit(".", 1)[-1] in {"run", "Popen", "check_output"}:
                    for keyword in node.keywords:
                        if keyword.arg == "shell":
                            self.fail(f"{module} passes shell= to subprocess")

    def test_every_subprocess_call_passes_an_argument_list(self) -> None:
        for module in MODULES:
            tree = ast.parse((PACKAGE / module).read_text(encoding="utf-8"))
            for node in ast.walk(tree):
                if not isinstance(node, ast.Call):
                    continue
                dotted = self._dotted_name(node.func)
                if dotted not in {"subprocess.run", "subprocess.Popen"}:
                    continue
                self.assertTrue(node.args, f"{module}: {dotted} with no argv")
                first = node.args[0]
                self.assertIsInstance(
                    first,
                    (ast.List, ast.Name),
                    f"{module}: {dotted} must take an argument list",
                )

    def test_no_module_names_a_device_transport_or_the_installed_state(self) -> None:
        forbidden = ("hdc", "rockusb", "connectKey", "Application Support")
        for module in MODULES:
            source = (PACKAGE / module).read_text(encoding="utf-8")
            for token in forbidden:
                if token == "hdc" and module == "harness.py":
                    # harness.py clears ARKDECK_HDC_PATH from the child
                    # environment; that is the opposite of using it.
                    continue
                self.assertNotIn(token, source, f"{module} names {token}")


if __name__ == "__main__":
    unittest.main(verbosity=2)
