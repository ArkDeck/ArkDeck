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
    "observations.py",
    "recovery.py",
)
STDLIB_ONLY = {
    # Standard-library Windows facilities used for held no-follow file reads.
    "_winapi",
    "argparse",
    "ast",
    "ctypes",
    "datetime",
    "hashlib",
    "json",
    "math",
    "msvcrt",
    "os",
    "pathlib",
    "platform",
    "re",
    "shutil",
    "socket",
    "stat",
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


class QuietWaitTests(unittest.TestCase):
    """The bounded wait for a quiet host before each run."""

    def _wait(self, loads: list[float], budget: float, poll: float = 5.0):
        clock = {"now": 100.0}
        sleeps: list[float] = []
        readings = iter(loads)

        def fake_sleep(seconds: float) -> None:
            sleeps.append(seconds)
            clock["now"] += seconds

        patches = (
            mock.patch.object(harness, "cpu_count", return_value=8),
            mock.patch.object(
                harness, "load_average", side_effect=lambda: (next(readings), 0.0, 0.0)
            ),
            mock.patch.object(
                harness.clocks, "elapsed_seconds", side_effect=lambda: clock["now"]
            ),
            mock.patch.object(harness.time, "sleep", side_effect=fake_sleep),
        )
        with patches[0], patches[1], patches[2], patches[3]:
            try:
                return harness.wait_for_quiet_host(budget, poll), sleeps
            except harness.HostTooBusy as error:
                return error, sleeps

    def test_a_quiet_host_starts_at_once(self) -> None:
        result, sleeps = self._wait([1.0], budget=600)
        self.assertEqual(result, (1.0, 0.0))
        self.assertEqual(sleeps, [])

    def test_without_a_budget_a_loaded_host_is_refused_at_once(self) -> None:
        result, sleeps = self._wait([4.1], budget=0)
        self.assertIsInstance(result, harness.HostTooBusy)
        self.assertEqual(sleeps, [])

    def test_a_loaded_host_is_waited_for_until_it_goes_quiet(self) -> None:
        result, sleeps = self._wait([5.0, 4.5, 3.9], budget=600)
        self.assertEqual(result, (3.9, 10.0))
        self.assertEqual(sleeps, [5.0, 5.0])

    def test_the_ceiling_itself_counts_as_quiet(self) -> None:
        result, _ = self._wait([4.0], budget=0)
        self.assertEqual(result, (4.0, 0.0))

    def test_the_wait_is_bounded_and_then_refuses(self) -> None:
        result, sleeps = self._wait([9.0] * 10, budget=12)
        self.assertIsInstance(result, harness.HostTooBusy)
        self.assertEqual(sleeps, [5.0, 5.0])

    def test_nonsense_budgets_are_refused(self) -> None:
        with self.assertRaises(ValueError):
            harness.wait_for_quiet_host(-1)
        with self.assertRaises(ValueError):
            harness.wait_for_quiet_host(10, poll_seconds=0)


class SocketPathTests(unittest.TestCase):
    def test_unknown_runtime_is_refused_before_spawn(self) -> None:
        with self.assertRaises(ValueError):
            harness.IsolatedRuntime(pathlib.Path("/bin/true"), pathlib.Path("/tmp/a"),
                                    runtime_kind="guess")

    def test_launch_configuration_is_isolated_for_both_runtimes(self) -> None:
        inherited = {"PATH": "/usr/bin", "ARKDECK_SWIFT_DAEMON": "/unexpected",
                     "ARKDECK_ENDPOINT": "/installed.sock",
                     "ARKDECK_DEVELOPMENT_HDC_PATH": "/fixture",
                     "ARKDECK_HDC_PATH": "/hdc",
                     "ARKDECK_ANALYZER_PATH": "/analyzer"}
        for kind in ("swift", "rust"):
            with self.subTest(kind=kind), mock.patch.dict(os.environ, inherited, clear=True), \
                    mock.patch.object(harness.subprocess, "Popen") as spawn:
                spawn.return_value.poll.return_value = 1
                runtime = harness.IsolatedRuntime(pathlib.Path("/daemon"),
                                                  pathlib.Path("/tmp/private"),
                                                  runtime_kind=kind)
                with self.assertRaises(harness.DaemonStartFailed):
                    runtime.start()
                args, kwargs = spawn.call_args
                expected = ["/daemon"] if kind == "rust" else ["/daemon", "--state-dir", "/tmp/private"]
                self.assertEqual(args[0], expected)
                environment = kwargs["env"]
                self.assertEqual(environment["PATH"], "/usr/bin")
                arkdeck = {k: v for k, v in environment.items() if k.startswith("ARKDECK_")}
                self.assertEqual(arkdeck, {
                    "ARKDECK_DEVELOPMENT_STATE_ROOT": "/tmp/private",
                    "ARKDECK_ENDPOINT": "/tmp/private/agentd.sock",
                } if kind == "rust" else {})

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
    def test_failed_contract_verification_closes_the_connection(self) -> None:
        client = control.ControlClient("fixture")
        with mock.patch.object(client, "connect"), \
                mock.patch.object(client, "verify_contract", side_effect=control.ControlError("old")), \
                mock.patch.object(client, "close") as close:
            with self.assertRaises(control.ControlError):
                with client:
                    self.fail("unverified client entered")
            close.assert_called_once()

    def test_a_call_before_contract_verification_is_refused(self) -> None:
        client = control.ControlClient("/nonexistent.sock")
        with self.assertRaises(control.ControlError):
            client.call("health")

    def test_connecting_to_a_missing_socket_reports_the_path(self) -> None:
        client = control.ControlClient("/nonexistent/agentd.sock")
        with self.assertRaises(control.ControlError) as raised:
            client.connect()
        self.assertIn("agentd.sock", str(raised.exception))

    def test_current_contract_is_loaded_from_the_generated_registry(self) -> None:
        self.assertEqual(control.CURRENT_VERSION, "1.0.0")
        self.assertEqual(len(control.CONTRACT_IDENTITY), 64)
        self.assertNotIn("protocol.negotiate", control._REGISTRY["methods"])

    def test_same_version_old_health_cannot_enable_business_requests(self) -> None:
        class OldClient(control.ControlClient):
            def _exchange(self, frame):
                self.seen = frame
                return {"id": frame["id"], "ok": True,
                        "result": {"status": "ok", "protocolVersion": "1.0.0",
                                   "catalogDigest": "a" * 64, "providers": []}}
        client = OldClient("fixture")
        with self.assertRaises(control.ControlError):
            client.verify_contract()
        self.assertEqual(client.seen["method"], "health")
        with self.assertRaises(control.ControlError):
            client.call("job.list")
        self.assertEqual(client.seen["method"], "health")


class MetricTableTests(unittest.TestCase):
    def test_every_measured_metric_names_its_design_row(self) -> None:
        for name, (unit, design_row, description) in metrics.METRIC_DEFINITIONS.items():
            self.assertTrue(unit, name)
            self.assertTrue(design_row, name)
            self.assertTrue(description, name)

    def test_every_gap_names_a_reason_and_what_blocks_it(self) -> None:
        for kind in metrics.RUNTIME_KINDS:
            for name, gap in metrics.gap_definitions(kind).items():
                self.assertEqual(gap.metric_id, name)
                self.assertTrue(gap.reason, name)
                self.assertTrue(gap.blocked_by, name)

    def test_no_metric_is_both_measured_and_a_gap(self) -> None:
        for kind in metrics.RUNTIME_KINDS:
            self.assertEqual(
                set(metrics.METRIC_DEFINITIONS) & set(metrics.gap_definitions(kind)),
                set(),
            )

    def test_the_twelve_design_rows_are_all_accounted_for(self) -> None:
        for kind in metrics.RUNTIME_KINDS:
            rows = {
                entry[1].split("(")[0].strip()
                for entry in metrics.METRIC_DEFINITIONS.values()
            } | {
                gap.design_row.split("(")[0].strip()
                for gap in metrics.gap_definitions(kind).values()
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
                kind,
            )

    def test_both_compositions_declare_the_same_gaps(self) -> None:
        def documents(gaps: dict) -> dict:
            return {name: gap.as_document() for name, gap in gaps.items()}

        self.assertEqual(
            documents(metrics.gap_definitions()),
            documents(metrics.gap_definitions("swift")),
        )
        self.assertEqual(
            set(metrics.gap_definitions("swift")), set(metrics.gap_definitions("rust"))
        )

    def test_the_legs_the_spk_1_report_found_undeclared_are_declared(self) -> None:
        # docs/design/cross-platform/spk-1-macos-performance-baseline.md: the
        # document under-reported its gaps by the XPC leg and the job.events page.
        for kind in metrics.RUNTIME_KINDS:
            gaps = metrics.gap_definitions(kind)
            self.assertIn("ipc.xpc", gaps)
            self.assertIn("job.eventsPage", gaps)
            # Design row "Job event/log stream throughput" budgets three things:
            # the durable append, the 1,000-row page and the wait's idle CPU.
            self.assertIn("job.journalAppend", gaps)
            self.assertIn("job.eventsWait", gaps)
            # Design row "idle/busy CPU, RSS, threads, fd/handle" notes the busy
            # Golden Journey loop as unmeasured; the idle window is not it.
            self.assertIn("daemon.busyResources", gaps)

    def test_rust_gaps_name_the_rust_blockers(self) -> None:
        gaps = metrics.gap_definitions("rust")
        recovery = gaps["daemon.warmStartRecovery"]
        self.assertIn("--recovery-samples", recovery.reason)
        self.assertIn("timed Rust 10k", recovery.blocked_by)
        self.assertNotIn("L.1 item 13", recovery.reason)
        self.assertNotIn("L.1 item 13", recovery.blocked_by)
        self.assertIn("job.reconcile", gaps["job.cancelReconcile"].reason)
        self.assertNotIn("refuses job.reconcile", gaps["job.cancelReconcile"].reason)
        self.assertIn("does not measure", gaps["ipc.namedPipe"].reason)
        self.assertIn("ARKDECK_APP_INGRESS", gaps["ipc.xpc"].reason)
        swift = metrics.gap_definitions("swift")
        self.assertNotIn("L.1 item 13", swift["daemon.warmStartRecovery"].reason)
        self.assertNotIn("job.reconcile", swift["job.cancelReconcile"].reason)

    def test_no_gap_repeats_the_retired_protocol_split(self) -> None:
        # Single v1 publishes job.cancel and job.reconcile; a reason saying a
        # 2.x client cannot reach them would be false in a committed document.
        for kind in metrics.RUNTIME_KINDS:
            for gap in metrics.gap_definitions(kind).values():
                for retired in ("1.x", "2.x", "2.1.0"):
                    self.assertNotIn(retired, gap.reason + gap.blocked_by, gap.metric_id)

    def test_an_unknown_composition_has_no_gap_table(self) -> None:
        with self.assertRaises(ValueError):
            metrics.gap_definitions("guess")

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
        self.assertEqual(steady, [])

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
            self.assertEqual(steady, [])

    def test_the_release_fraction_is_pinned(self) -> None:
        self.assertEqual(metrics.RESIDENT_SET_RELEASE_FRACTION, 0.25)

    def test_both_resident_set_levels_are_declared_metrics(self) -> None:
        self.assertIn("daemon.residentSetPlateau", metrics.METRIC_DEFINITIONS)
        self.assertIn("daemon.residentSetSteady", metrics.METRIC_DEFINITIONS)
        self.assertNotIn("daemon.idleResidentSetBytes", metrics.METRIC_DEFINITIONS)


class RuntimeCompositionTests(unittest.TestCase):
    def test_capture_uses_selected_composition_for_every_phase(self) -> None:
        for kind in ("swift", "rust"):
            context = metrics.RunContext(
                daemon_executable=pathlib.Path("/daemon"),
                soak_executable=pathlib.Path("/soak"), cold_start_samples=2,
                ipc_samples=65, idle_seconds=1, calibration_samples=0,
                seed_seconds=1, seed_jobs_per_cycle=10, runtime_kind=kind)
            with mock.patch.object(harness, "seed_state_directory") as seed, \
                 mock.patch.object(harness, "IsolatedRuntime") as runtime_class, \
                 mock.patch.object(metrics.observations, "seed_metrics"), \
                 mock.patch.object(clocks, "Deadline") as deadline:
                seed.return_value.returncode = 0
                runtime = runtime_class.return_value
                runtime.start.return_value = 0.1
                client = runtime.client.return_value.__enter__.return_value
                client.call.return_value = {"items": [{"jobId": "job-one"}]}
                client.timed_call.return_value = ({}, 0.01)
                deadline.return_value.expired.return_value = True
                samples, scale = metrics.execute_run(context, pathlib.Path("/state"))
                runtime_class.assert_called_once_with(
                    pathlib.Path("/daemon"), pathlib.Path("/state"), runtime_kind=kind)
                self.assertEqual(runtime.start.call_count, 4)
                self.assertEqual(len(samples["daemon.coldStart"]), 2)
                self.assertEqual(scale["jobStoreRowCount"], 1)
                self.assertEqual(len(samples["ipc.jobStatus"]), 65)
                self.assertEqual(client.close.call_count, 2)
                self.assertEqual(client.connect.call_count, 2)
                self.assertEqual(client.verify_contract.call_count, 2)
                self.assertEqual(client.timed_call.call_count, 65 * 3)


    def test_empty_or_incompatible_seed_is_not_measured_as_a_fast_store(self) -> None:
        context = metrics.RunContext(
            daemon_executable=pathlib.Path("/daemon"),
            soak_executable=pathlib.Path("/soak"), cold_start_samples=1,
            ipc_samples=1, idle_seconds=1, calibration_samples=0,
            seed_seconds=1, seed_jobs_per_cycle=10, runtime_kind="rust")
        with mock.patch.object(harness, "seed_state_directory") as seed, \
             mock.patch.object(metrics.observations, "seed_metrics"), \
             mock.patch.object(harness, "IsolatedRuntime") as runtime_class:
            seed.return_value.returncode = 0
            runtime = runtime_class.return_value
            runtime.start.return_value = 0.1
            client = runtime.client.return_value.__enter__.return_value
            client.call.return_value = {"items": []}
            with self.assertRaisesRegex(metrics.RunFailed, "cannot read the soak seed"):
                metrics.execute_run(context, pathlib.Path("/state"))
            client.timed_call.assert_not_called()
            self.assertEqual(runtime.stop.call_count, 2)


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

    def test_windows_stdlib_is_allowed_but_external_aliases_and_nested_imports_are_not(self) -> None:
        with mock.patch.object(pathlib.Path, "read_text", return_value=(
            "import ctypes, msvcrt\nfrom ctypes import wintypes\n"
            "def native_read():\n    import _winapi\n"
        )):
            native = self._imports("fixture.py")
        self.assertEqual(native, {"ctypes", "msvcrt", "_winapi"})
        self.assertLessEqual(native, STDLIB_ONLY)
        for source in ("import requests as ctypes", "from third_party import _winapi",
                       "def native_read():\n    import numpy.linalg as msvcrt\n"):
            with self.subTest(source=source), mock.patch.object(pathlib.Path, "read_text", return_value=source):
                self.assertFalse(self._imports("fixture.py") <= STDLIB_ONLY)

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


class CaptureTraceTests(unittest.TestCase):
    def context(self, **extra):
        return metrics.RunContext(
            daemon_executable=pathlib.Path('/daemon'), soak_executable=pathlib.Path('/soak'),
            cold_start_samples=0, ipc_samples=0, idle_seconds=5, calibration_samples=0,
            seed_seconds=1, seed_jobs_per_cycle=1, **extra)

    def test_release_time_uses_elapsed_clock_and_raw_series_is_preserved(self):
        recorder = mock.Mock()
        values = []
        for rss in (100, 40):
            resource = harness.ProcessResources()
            resource.resident_set_bytes = rss
            values.append(resource)
        with mock.patch.object(harness, 'seed_state_directory') as seed, \
             mock.patch.object(harness, 'IsolatedRuntime') as runtime_class, \
             mock.patch.object(harness, 'sample_process_resources', side_effect=values), \
             mock.patch.object(clocks, 'awake_seconds', side_effect=[100, 101.25, 101.5, 103.5, 103.75]), \
             mock.patch.object(clocks, 'Deadline') as deadline, \
             mock.patch.object(metrics.time, 'sleep'):
            seed.return_value.returncode = 0
            runtime_class.return_value.process.pid = 123
            runtime_class.return_value.process.poll.return_value = None
            runtime_class.return_value.start_diagnostics = {}
            runtime_class.return_value.client.return_value.__enter__.return_value.call.return_value = {
                'items': [{'jobId': 'job-one'}]}
            deadline.return_value.expired.side_effect = [False, False, True]
            samples, scale = metrics.execute_run(self.context(capture_recorder=recorder), pathlib.Path('/state'))
        self.assertEqual(scale['residentSetReleaseAtSeconds'], 3.5)
        self.assertEqual(scale['residentSetRawSamples'], [
            {'elapsedSeconds': 1.25, 'bytes': 100.0}, {'elapsedSeconds': 3.5, 'bytes': 40.0}])
        self.assertEqual(samples['daemon.residentSetSteady'], [40.0])
        idle = [call.args[0] for call in recorder.call_args_list if call.args[0]['kind'] == 'idleResources']
        self.assertEqual(len(idle), 2)
        self.assertEqual(idle[-1]['finishedAtSeconds'], 3.75)

    def test_guard_failure_after_start_keeps_sample_and_stops_daemon(self):
        recorder = mock.Mock()
        context = self.context(capture_recorder=recorder, require_quiet=True)
        context.cold_start_samples = 1
        with mock.patch.object(harness, 'seed_state_directory') as seed, \
             mock.patch.object(harness, 'IsolatedRuntime') as runtime_class, \
             mock.patch.object(metrics.recovery, 'assert_quiet_host',
                               side_effect=[{}, {}, harness.HostTooBusy('busy')]):
            seed.return_value.returncode = 0
            runtime = runtime_class.return_value
            runtime.start.return_value = .1
            runtime.start_diagnostics = {'healthySeconds': .1}
            with self.assertRaises(harness.HostTooBusy):
                metrics.execute_run(context, pathlib.Path('/state'))
            self.assertGreaterEqual(runtime.stop.call_count, 1)
        observations = [call.args[0] for call in recorder.call_args_list]
        cold = [entry for entry in observations if entry['kind'] == 'coldStart']
        self.assertEqual(len(cold), 1)
        self.assertEqual(cold[0]['milliseconds'], 100)


class StartupObservationTests(unittest.TestCase):
    def setup_start(self, polls, sleeps, clients):
        clock = {'awake': 100., 'continuous': 1000.}
        def advance(seconds):
            clock['awake'] += seconds
            clock['continuous'] += seconds
        process = mock.Mock()
        process.poll.return_value = None
        def spawn(*args, **kwargs):
            advance(.002)
            return process
        polls, sleeps = iter(polls), iter(sleeps)
        def exists():
            present, duration = next(polls)
            advance(duration)
            return present
        requested = []
        def sleep(seconds):
            requested.append(seconds)
            duration, error = next(sleeps)
            advance(duration)
            if error:
                raise error
        for target, name, replacement in (
            (clocks, 'awake_seconds', lambda: clock['awake']),
            (clocks, 'elapsed_seconds', lambda: clock['continuous']),
            (harness.subprocess, 'Popen', spawn),
            (pathlib.Path, 'exists', exists),
            (harness.time, 'sleep', sleep),
        ):
            patcher = mock.patch.object(target,name,side_effect=replacement)
            patcher.start()
            self.addCleanup(patcher.stop)
        factory = mock.patch.object(control,'ControlClient',side_effect=clients)
        factory.start()
        self.addCleanup(factory.stop)
        runtime = harness.IsolatedRuntime(pathlib.Path('/daemon'),pathlib.Path('/state'),runtime_kind='rust')
        return runtime, clock, advance, requested, process

    def test_overshoot_connect_and_both_health_calls_remain_in_total(self):
        client = mock.Mock()
        runtime, clock, advance, sleeps, _ = self.setup_start(
            [(False,.003),(False,.004),(True,.001)],[(.007,None),(.011,None)],[client])
        order = []
        def step(name, duration):
            def act(*args):
                order.append(name)
                advance(duration)
            return act
        client.connect.side_effect = step('connect',.002)
        client.verify_contract.side_effect = step('contract-health',.013)
        client.call.side_effect = step('explicit-health',.003)
        client.close.side_effect = step('close',.005)
        elapsed = runtime.start()
        d = runtime.start_diagnostics
        self.assertAlmostEqual(elapsed,.046)
        self.assertAlmostEqual(clock['awake']-100.,.051)  # Close stays outside the endpoint.
        self.assertEqual(d['observationVersion'],'startup-observation-v2')
        self.assertEqual(d['socketPollCount'],3)
        self.assertEqual(d['pollSleepCount'],2)
        for key,value in [('pollSleepTotalSeconds',.018),('pollSleepMaxSeconds',.011),
                          ('lastSocketNegativeSeconds',.016),('spawnReturnedSeconds',.002),
                          ('socketObservedSeconds',.028),('connectReturnedSeconds',.030),
                          ('contractVerifiedSeconds',.043),('healthySeconds',.046)]:
            self.assertAlmostEqual(d[key],value)
        self.assertEqual(sleeps,[.001,.001])
        self.assertEqual(order,['connect','contract-health','explicit-health','close'])
        client.call.assert_called_once_with('health')
        client.close.assert_called_once()

    def test_failed_contract_closes_and_retry_does_not_mix_phases(self):
        first,second = mock.Mock(),mock.Mock()
        runtime,_,advance,_,_ = self.setup_start(
            [(True,0),(True,0)],[(.01,None),(.01,None)],[first,second])
        first.connect.side_effect = lambda: advance(.002)
        first.verify_contract.side_effect = control.ControlError('wrong contract')
        second.connect.side_effect = OSError('refused')
        with self.assertRaises(harness.DaemonStartFailed):
            runtime.start(budget_seconds=.015)
        d = runtime.start_diagnostics
        self.assertEqual(d['connectionAttempts'],2)
        self.assertEqual(d['connectionFailures'],2)
        self.assertEqual(d['lastConnectionFailure']['attempt'],2)
        self.assertEqual(d['lastConnectionFailure']['phase'],'connect')
        self.assertEqual(d['lastConnectionFailure']['errorType'],'OSError')
        for key in ('connectReturnedSeconds','contractVerifiedSeconds','healthySeconds'):
            self.assertNotIn(key,d)
        self.assertIsNone(d['lastSocketNegativeSeconds'])
        for client in (first,second):
            client.close.assert_called_once()
            client.call.assert_not_called()

    def test_missing_socket_timeout_keeps_observed_sleep_without_connection(self):
        runtime,_,_,sleeps,_ = self.setup_start([(False,.003)],[(.02,None)],[])
        with self.assertRaises(harness.DaemonStartFailed):
            runtime.start(budget_seconds=.01)
        d = runtime.start_diagnostics
        self.assertEqual(d['socketPollCount'],1)
        self.assertEqual(d['connectionAttempts'],0)
        self.assertAlmostEqual(d['lastSocketNegativeSeconds'],.005)
        self.assertAlmostEqual(d['pollSleepTotalSeconds'],.02)
        self.assertNotIn('healthySeconds',d)
        self.assertEqual(sleeps,[.001])

    def test_interrupted_sleep_records_elapsed_and_preserves_failure(self):
        runtime,_,_,_,_ = self.setup_start([(False,0)],[(.007,InterruptedError('stop'))],[])
        with self.assertRaises(InterruptedError):
            runtime.start()
        self.assertEqual(runtime.start_diagnostics['pollSleepCount'],1)
        self.assertAlmostEqual(runtime.start_diagnostics['pollSleepMaxSeconds'],.007)
        self.assertNotIn('healthySeconds',runtime.start_diagnostics)

    def test_daemon_exit_has_no_fabricated_poll_or_completion(self):
        runtime,_,_,sleeps,process = self.setup_start([],[],[])
        process.poll.return_value = process.returncode = 9
        with self.assertRaisesRegex(harness.DaemonStartFailed,'status 9'):
            runtime.start()
        self.assertEqual(runtime.start_diagnostics['socketPollCount'],0)
        self.assertEqual(runtime.start_diagnostics['pollSleepCount'],0)
        self.assertEqual(sleeps,[])
        self.assertNotIn('socketObservedSeconds',runtime.start_diagnostics)

    def test_capture_failure_records_final_diagnostics_once_and_stops(self):
        recorder = mock.Mock()
        context = metrics.RunContext(
            daemon_executable=pathlib.Path('/daemon'),soak_executable=pathlib.Path('/soak'),
            cold_start_samples=1,ipc_samples=0,idle_seconds=1,calibration_samples=0,
            seed_seconds=1,seed_jobs_per_cycle=1,capture_recorder=recorder)
        diagnostics = {'observationVersion':'startup-observation-v2','socketPollCount':4,
                       'pollSleepTotalSeconds':.123}
        with mock.patch.object(harness,'seed_state_directory') as seed, \
             mock.patch.object(harness,'IsolatedRuntime') as factory:
            seed.return_value.returncode = 0
            runtime = factory.return_value
            runtime.start_diagnostics = diagnostics
            def fail():
                self.assertFalse(any(call.args[0]['kind'] == 'coldStart' for call in recorder.call_args_list))
                raise harness.DaemonStartFailed('budget')
            runtime.start.side_effect = fail
            with self.assertRaises(harness.DaemonStartFailed):
                metrics.execute_run(context,pathlib.Path('/state'))
            runtime.stop.assert_called_once()
        cold = [call.args[0] for call in recorder.call_args_list if call.args[0]['kind'] == 'coldStart']
        self.assertEqual(len(cold), 1)
        entry = cold[0]
        self.assertEqual(entry['status'],'FAILED')
        self.assertEqual(entry['sampleIndex'],0)
        self.assertEqual(entry['diagnostics'],diagnostics)

    def test_retry_success_preserves_prior_failure_without_skipping_health(self):
        first,second = mock.Mock(),mock.Mock()
        runtime,_,advance,sleeps,_ = self.setup_start(
            [(True,0),(True,0)],[(.006,None)],[first,second])
        first.connect.side_effect = OSError('not ready')
        second.connect.side_effect = lambda: advance(.003)
        second.verify_contract.side_effect = lambda: advance(.004)
        second.call.side_effect = lambda *_: advance(.005)
        elapsed = runtime.start()
        d = runtime.start_diagnostics
        self.assertAlmostEqual(elapsed,.020)
        self.assertEqual(d['connectionAttempts'],2)
        self.assertEqual(d['connectionFailures'],1)
        self.assertEqual(d['lastConnectionFailure']['attempt'],1)
        self.assertAlmostEqual(d['connectReturnedSeconds'],.011)
        self.assertAlmostEqual(d['contractVerifiedSeconds'],.015)
        self.assertEqual(sleeps,[.001])
        second.call.assert_called_once_with('health')
        for client in (first,second):
            client.close.assert_called_once()

    def test_unexpected_verification_error_closes_without_retry_or_success(self):
        client = mock.Mock()
        runtime,_,_,sleeps,_ = self.setup_start([(True,0)],[],[client])
        client.verify_contract.side_effect = ValueError('bad decoder')
        with self.assertRaises(ValueError):
            runtime.start()
        client.close.assert_called_once()
        self.assertEqual(sleeps,[])
        self.assertNotIn('healthySeconds',runtime.start_diagnostics)
        client.call.assert_not_called()

    def test_close_error_retains_close_phase_and_cannot_be_measured_success(self):
        client = mock.Mock()
        runtime,_,_,_,_ = self.setup_start([(True,0)],[(.02,None)],[client])
        client.close.side_effect = OSError('close failed')
        with self.assertRaises(harness.DaemonStartFailed):
            runtime.start(budget_seconds=.01)
        self.assertEqual(runtime.start_diagnostics['connectionFailures'],1)
        self.assertEqual(runtime.start_diagnostics['lastConnectionFailure']['phase'],'close')
        client.call.assert_called_once_with('health')
