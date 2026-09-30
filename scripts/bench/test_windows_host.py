"""Windows capture (TASK-XPA-025, WM6): the Windows counterparts and the
capture-only rule.  The first class runs on every host; the second reads the
Windows APIs themselves and skips elsewhere."""

from __future__ import annotations

import json
import os
import pathlib
import tempfile
import threading
import unittest
from unittest import mock

from bench import __main__ as cli
from bench import baseline, harness, metrics, windows_host

ENDPOINT = ("\\\\.\\pipe\\arkdeck-agentd-dev-S-1-5-5-0-123456-"
            "00000000deadbeef-0123456789abcdef0123456789abcdef")


class PortableRulesTests(unittest.TestCase):
    def test_busy_fraction_counts_kernel_time_net_of_idle(self):
        # idle, kernel (includes idle), user
        self.assertEqual(windows_host.busy_fraction((0, 0, 0), (60, 100, 20)), 0.5)
        self.assertEqual(windows_host.busy_fraction((5, 5, 5), (5, 5, 5)), 0.0)

    def test_the_stop_event_is_named_after_the_root_in_the_pipe_name(self):
        self.assertEqual(windows_host.root_identity(ENDPOINT),
                         "00000000deadbeef-0123456789abcdef0123456789abcdef")
        self.assertEqual(
            windows_host.stop_event_name("S-1-5-21-1", ENDPOINT, 42),
            "Local\\ArkDeck.Agentd.Dev.S-1-5-21-1."
            "00000000deadbeef-0123456789abcdef0123456789abcdef.Stop.42")
        for foreign in ("\\\\.\\pipe\\arkdeck-agentd-S-1-5-5-0-1", ENDPOINT.upper()):
            with self.assertRaises(ValueError):
                windows_host.root_identity(foreign)

    def test_macos_definitions_and_gaps_are_unchanged(self):
        self.assertIs(metrics.metric_definitions(False), metrics.METRIC_DEFINITIONS)
        self.assertEqual(set(metrics.gap_definitions("rust")),
                         set(metrics.gap_definitions("rust", windows=False)))

    def test_windows_rows_replace_their_unix_counterparts_without_dropping_a_row(self):
        definitions = metrics.metric_definitions(True)
        gaps = metrics.gap_definitions("rust", windows=True)
        for name in ("ipc.namedPipe", "daemon.idleHandleCount", "daemon.idlePrivateBytes"):
            self.assertIn(name, definitions)
            self.assertNotIn(name, gaps)
        for name in ("ipc.health", "daemon.idleOpenFileDescriptorCount"):
            self.assertNotIn(name, definitions)
            self.assertIn(name, gaps)
        for name in ("ipc.jobList", "ipc.jobStatus", "daemon.warmStartRecovery"):
            self.assertIn("G01", gaps[name].reason)
        unix_rows = set(metrics.METRIC_DEFINITIONS) | set(metrics.gap_definitions("rust"))
        self.assertLessEqual(unix_rows, set(definitions) | set(gaps))

    def test_windows_refuses_the_job_store_legs_up_front(self):
        common = dict(daemon_executable=pathlib.Path("d"), soak_executable=pathlib.Path("s"),
                      cold_start_samples=1, ipc_samples=1, idle_seconds=1,
                      calibration_samples=1, seed_seconds=1, seed_jobs_per_cycle=1)
        with mock.patch.object(harness, "on_windows", return_value=True):
            for extra in ({"runtime_kind": "swift"},
                          {"runtime_kind": "rust", "recovery_samples": 1},
                          {"runtime_kind": "rust", "journal_samples": 1},
                          {"runtime_kind": "rust", "artifact_samples": 1}):
                with self.assertRaises(ValueError):
                    metrics.RunContext(**common, **extra)
            metrics.RunContext(**common, runtime_kind="rust")

    def test_windows_host_facts_carry_a_host_tag(self):
        with mock.patch.object(harness, "on_windows", return_value=True), \
                mock.patch.object(windows_host, "os_version", return_value="10.0.26200"), \
                mock.patch("platform.machine", return_value="AMD64"):
            facts = harness.host_facts()
        self.assertEqual(facts["hostTag"], "windows-amd64")
        self.assertEqual(facts["osVersion"], "10.0.26200")
        self.assertEqual(facts["loadSource"], windows_host.LOAD_SOURCE)
        with mock.patch.object(harness, "on_windows", return_value=False):
            self.assertNotIn("hostTag", harness.host_facts())

    def test_a_capture_only_document_is_never_compared_or_selected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            only = {"captureOnly": True, "toolchain": {"runtimeKind": "rust"}}
            (root / "perf-baseline-2026-09-30.json").write_text(json.dumps(only))
            candidate = root / "candidate.json"
            candidate.write_text(json.dumps({"toolchain": {"runtimeKind": "rust"}}))
            windows = root / "windows.json"
            windows.write_text(json.dumps(only))
            with mock.patch("sys.stderr"):
                self.assertEqual(cli.main(["select-baseline", "--candidate", str(windows),
                                           "--directory", str(root)]), 1)
                # A committed capture-only document is not a reference either.
                self.assertEqual(cli.main(["select-baseline", "--candidate", str(candidate),
                                           "--directory", str(root)]), 1)
                self.assertEqual(cli.main(["compare", "--committed", str(candidate),
                                           "--candidate", str(windows)]), 1)
                self.assertEqual(cli.main(["compare", "--committed", str(windows),
                                           "--candidate", str(candidate)]), 1)

    def test_a_failed_windows_start_keeps_the_daemon_s_redacted_words(self):
        root = pathlib.Path(tempfile.gettempdir()) / "adkb.redact"
        runtime = harness.IsolatedRuntime.__new__(harness.IsolatedRuntime)
        runtime.state_directory = root
        runtime.start_diagnostics = {}
        runtime._output = tempfile.TemporaryFile()
        runtime._output.write(
            f"arkdeck-agentd: the owner lock of {root} is unusable; pipe "
            "\\\\.\\pipe\\arkdeck-agentd-dev-S-1-5-5-0-881154-00ff\n".encode())
        said = runtime._daemon_output()
        runtime._close_output()
        self.assertIn("<state-root>", said)
        self.assertIn("<sid>", said)
        self.assertNotIn(str(root), said)
        self.assertNotIn("S-1-5", said)
        self.assertEqual(runtime.start_diagnostics["daemonOutput"].split(), said.split())

    def test_a_windows_profile_path_never_reaches_a_document(self):
        for text in ('"C:\\\\Users\\\\someone\\\\AppData"', "D:\\Users\\someone\\x"):
            with self.assertRaises(baseline.BaselineError):
                baseline.assert_no_host_identity(text)


@unittest.skipUnless(windows_host.IS_WINDOWS, "reads Windows APIs")
class WindowsApiTests(unittest.TestCase):
    def test_clocks_are_named_and_advance(self):
        from bench import clocks
        self.assertEqual(clocks.clock_identity(), {
            "continuousClock": "QueryInterruptTimePrecise",
            "awakeWorkClock": "QueryUnbiasedInterruptTimePrecise"})
        first = (clocks.elapsed_seconds(), clocks.awake_seconds())
        self.assertLessEqual(first[0], clocks.elapsed_seconds())
        self.assertLessEqual(first[1], clocks.awake_seconds())

    def test_this_process_reports_every_counter(self):
        facts = windows_host.process_resources(os.getpid())
        self.assertGreater(facts["workingSetBytes"], 0)
        self.assertGreater(facts["privateBytes"], 0)
        self.assertGreater(facts["handleCount"], 0)
        self.assertGreaterEqual(facts["threadCount"], 1)
        self.assertGreaterEqual(facts["cpuPercent"], 0.0)
        sample = harness.sample_process_resources(os.getpid())
        self.assertEqual(sample.resident_set_bytes is None, False)
        self.assertIsNone(sample.open_file_descriptor_count)
        self.assertIn("openFileDescriptorCount", sample.unmeasured)

    def test_conflicting_processes_are_found_by_image_and_python_arguments(self):
        seen = []
        own = windows_host.conflicting_command(
            lambda stem, arguments: seen.append((stem, arguments)) or (
                stem.startswith("python") and "unittest" in arguments))
        self.assertTrue(own and own.startswith("python"), own)
        self.assertIsNone(windows_host.conflicting_command(lambda stem, arguments: False))
        self.assertTrue(all(arguments == "" for stem, arguments in seen
                            if not stem.startswith("python")))

    def test_a_pipe_round_trip_checks_the_server_process(self):
        import _winapi
        name = f"\\\\.\\pipe\\arkdeck-bench-test-{os.getpid()}-{threading.get_ident()}"
        self.assertFalse(windows_host.pipe_exists(name))

        def serve(reply):
            # One client: connect, optionally answer one frame, close.
            pipe = _winapi.CreateNamedPipe(
                name, _winapi.PIPE_ACCESS_DUPLEX, _winapi.PIPE_WAIT, 1, 65536, 65536, 0,
                _winapi.NULL)
            ready.set()
            try:
                try:
                    _winapi.ConnectNamedPipe(pipe, False)
                except OSError:
                    pass  # ERROR_PIPE_CONNECTED: the client was first
                if reply is not None:
                    data, _ = _winapi.ReadFile(pipe, 65536)
                    _winapi.WriteFile(pipe, reply(data))
                    try:
                        _winapi.ReadFile(pipe, 1)  # until the client closes
                    except OSError:
                        pass
            finally:
                _winapi.CloseHandle(pipe)

        ready = threading.Event()
        server = threading.Thread(target=serve, args=(lambda data: data.upper(),))
        server.start()
        ready.wait(5)
        self.assertTrue(windows_host.pipe_exists(name))
        stream = windows_host.PipeStream(name, 5.0, os.getpid())
        try:
            stream.sendall(b"ping\n")
            self.assertEqual(stream.recv(65536), b"PING\n")
        finally:
            stream.close()
            server.join(10)

        ready.clear()
        server = threading.Thread(target=serve, args=(None,))
        server.start()
        ready.wait(5)
        with self.assertRaises(ConnectionRefusedError):
            windows_host.PipeStream(name, 5.0, os.getpid() + 1)
        server.join(10)


if __name__ == "__main__":
    unittest.main()
