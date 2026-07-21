"""Contract tests for the TR-001 trace capture harness. Stdlib-only; a fake
runner replaces subprocess so no real hdc/device is ever touched. The suite
asserts the safety properties (closed allowlist identity, probe-only default,
help-anchored capture gate, out-of-repo output, redaction gates, no shell) as
behavior, not documentation."""

from __future__ import annotations

import ast
import importlib.util
import json
import os
import shutil
import stat
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import capture  # noqa: E402


def _load_m0b_module():
    path = os.path.join(HERE, "..", "m0b_capture", "capture.py")
    spec = importlib.util.spec_from_file_location("m0b_capture_module", path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def fake_runner_factory(
    stdout: bytes = b"ok\n", stderr: bytes = b"", exit_code: int = 0,
    write_recv_bytes: bytes | None = None,
):
    """A fake runner. When ``write_recv_bytes`` is not None and the argv looks
    like a recv command, the fake writes the local destination file the way a
    real `hdc file recv` would."""

    calls: list[list[str]] = []

    def runner(argv: list[str], timeout: int) -> capture.RunnerResult:
        calls.append(list(argv))
        if write_recv_bytes is not None and "recv" in argv:
            with open(argv[-1], "wb") as handle:
                handle.write(write_recv_bytes)
        return capture.RunnerResult(
            exit_code=exit_code, timed_out=False, stdout=stdout, stderr=stderr,
            stdout_truncated=False, stderr_truncated=False, duration_ms=1)

    runner.calls = calls
    return runner


class HarnessTestCase(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp(prefix="trace-capture-test-")
        self.addCleanup(shutil.rmtree, self.root, True)
        self.hdc = os.path.join(self.root, "fake-hdc")
        with open(self.hdc, "w", encoding="utf-8") as handle:
            handle.write("#!/bin/sh\nexit 0\n")
        os.chmod(self.hdc, 0o755)

    def out_dir(self, name="out"):
        return os.path.join(self.root, name)

    def gate_dir_with(self, help_bytes: bytes, tag_bytes: bytes) -> str:
        gate = os.path.join(self.root, "probe-run")
        os.makedirs(gate, exist_ok=True)
        with open(os.path.join(gate, "02-hitrace-help-long.stdout"), "wb") as handle:
            handle.write(help_bytes)
        with open(os.path.join(gate, "04-hitrace-tag-list.stdout"), "wb") as handle:
            handle.write(tag_bytes)
        return gate

    def passing_gate_dir(self) -> str:
        return self.gate_dir_with(
            b"usage: hitrace [-t time] [-b size] [-o path] tags...\n",
            b"sched - scheduler events\nfreq - cpu frequency\n")

    # --- allowlist identity and argv construction ---

    def test_lookalike_spec_is_refused_by_identity(self):
        lookalike = capture.CommandSpec(
            "hitrace-help-long", ("shell", "rm", "-rf", "/"), True, False, False, "evil")
        with self.assertRaises(capture.CaptureError):
            capture.build_argv(self.hdc, lookalike, "KEY")

    def test_probe_argv_places_connectkey_in_fixed_slot(self):
        spec = capture.SPECS_BY_ID["hitrace-tag-list"]
        argv = capture.build_argv("/bin/hdc", spec, "KEY123")
        self.assertEqual(argv, ["/bin/hdc", "-t", "KEY123", "shell", "hitrace", "-l"])

    def test_recv_argv_appends_harness_supplied_local_path_only(self):
        spec = capture.SPECS_BY_ID["trace-recv-minimal"]
        argv = capture.build_argv("/bin/hdc", spec, "KEY", recv_local_path="/tmp/x/minimal.ftrace")
        self.assertEqual(argv[-1], "/tmp/x/minimal.ftrace")
        self.assertEqual(argv[-2], capture.REMOTE_TRACE_FILE)
        with self.assertRaises(capture.CaptureError):
            capture.build_argv("/bin/hdc", spec, "KEY")

    def test_capture_sequence_ids_exist_and_cover_all_device_write_specs(self):
        for ident in capture.CAPTURE_SEQUENCE:
            self.assertIn(ident, capture.SPECS_BY_ID)
        sequence_writes = {
            ident for ident in capture.CAPTURE_SEQUENCE
            if capture.SPECS_BY_ID[ident].device_write}
        self.assertEqual(sequence_writes, set(capture.CAPTURE_COMMAND_IDS))

    def test_remote_surface_is_fixed_literals_without_wildcards(self):
        for spec in capture.COMMAND_SPECS:
            for token in spec.tokens:
                self.assertNotIn("*", token)
                self.assertNotIn("..", token)
        rm_spec = capture.SPECS_BY_ID["trace-remote-rm"]
        self.assertEqual(rm_spec.tokens[-1], capture.REMOTE_TRACE_FILE)
        self.assertNotIn("-r", rm_spec.tokens)
        rmdir_spec = capture.SPECS_BY_ID["trace-remote-rmdir"]
        self.assertEqual(rmdir_spec.tokens[-1], capture.REMOTE_TRACE_DIR)

    # --- probe-only default and capture gates ---

    def test_device_write_spec_refused_without_flag(self):
        with self.assertRaises(capture.CaptureError) as context:
            capture.capture(
                self.hdc, self.out_dir(), [capture.SPECS_BY_ID["trace-remote-mkdir"]],
                "KEY", runner=fake_runner_factory(), home="/Users/tester")
        self.assertIn("--allow-device-write", str(context.exception))

    def test_device_write_spec_refused_without_gate_dir(self):
        with self.assertRaises(capture.CaptureError) as context:
            capture.capture(
                self.hdc, self.out_dir(), [capture.SPECS_BY_ID["trace-remote-mkdir"]],
                "KEY", runner=fake_runner_factory(), home="/Users/tester",
                allow_device_write=True)
        self.assertIn("--gate-dir", str(context.exception))

    def test_capture_gate_requires_help_evidence(self):
        gate = self.gate_dir_with(b"", b"sched\n")
        with self.assertRaises(capture.CaptureError) as context:
            capture.assert_capture_gate(gate)
        self.assertIn("help", str(context.exception))

    def test_capture_gate_requires_every_flag_token(self):
        gate = self.gate_dir_with(b"usage: hitrace [-t time] [-o path]\n", b"sched\n")
        with self.assertRaises(capture.CaptureError) as context:
            capture.assert_capture_gate(gate)
        self.assertIn("-b", str(context.exception))

    def test_capture_gate_requires_sched_tag(self):
        gate = self.gate_dir_with(
            b"usage: hitrace [-t time] [-b size] [-o path]\n", b"freq only\n")
        with self.assertRaises(capture.CaptureError) as context:
            capture.assert_capture_gate(gate)
        self.assertIn("sched", str(context.exception))

    def test_capture_gate_passes_and_records_facts(self):
        facts = capture.assert_capture_gate(self.passing_gate_dir())
        self.assertEqual(facts["helpTokensEvidenced"], ["-t", "-b", "-o"])
        self.assertEqual(facts["tagEvidenced"], "sched")

    def test_capture_phase_requires_target(self):
        with self.assertRaises(capture.CaptureError) as context:
            capture.capture(
                self.hdc, self.out_dir(), [capture.SPECS_BY_ID["trace-remote-mkdir"]],
                None, runner=fake_runner_factory(), home="/Users/tester",
                allow_device_write=True, gate_dir=self.passing_gate_dir())
        self.assertIn("--target", str(context.exception))

    def test_full_capture_sequence_runs_with_gate_and_manifest_records_gate(self):
        selected = [capture.SPECS_BY_ID[ident] for ident in capture.CAPTURE_SEQUENCE]
        runner = fake_runner_factory(write_recv_bytes=b"# tracer: nop\ntrace data\n")
        manifest = capture.capture(
            self.hdc, self.out_dir(), selected, "KEY", runner=runner,
            home="/Users/tester", allow_device_write=True,
            gate_dir=self.passing_gate_dir())
        self.assertTrue(manifest["deviceWriteEnabled"])
        self.assertTrue(manifest["captureGate"]["helpTokensEvidenced"])
        self.assertTrue(manifest["selfCheckPassed"])
        recv_entries = [
            entry for entry in manifest["commands"] if "receivedFile" in entry]
        self.assertEqual(len(recv_entries), 1)
        received = recv_entries[0]["receivedFile"]
        self.assertTrue(received["present"])
        self.assertEqual(received["bytes"], len(b"# tracer: nop\ntrace data\n"))
        local = os.path.join(self.out_dir(), capture.RECV_LOCAL_NAME)
        self.assertTrue(os.path.isfile(local))
        mode = stat.S_IMODE(os.stat(local).st_mode)
        self.assertEqual(mode, 0o600)

    def test_recv_absent_file_recorded_honestly(self):
        manifest = capture.capture(
            self.hdc, self.out_dir(), [capture.SPECS_BY_ID["trace-recv-minimal"]],
            "KEY", runner=fake_runner_factory(write_recv_bytes=None),
            home="/Users/tester", allow_device_write=True,
            gate_dir=self.passing_gate_dir())
        received = manifest["commands"][0]["receivedFile"]
        self.assertFalse(received["present"])

    def test_received_file_with_host_user_path_fails_self_check(self):
        manifest = capture.capture(
            self.hdc, self.out_dir(), [capture.SPECS_BY_ID["trace-recv-minimal"]],
            "KEY",
            runner=fake_runner_factory(write_recv_bytes=b"path /Users/alice/secret\n"),
            home="/Users/tester", allow_device_write=True,
            gate_dir=self.passing_gate_dir())
        self.assertFalse(manifest["selfCheckPassed"])

    def test_existing_recv_destination_is_refused(self):
        out = self.out_dir()
        os.makedirs(out, mode=0o700)
        with open(os.path.join(out, capture.RECV_LOCAL_NAME), "wb") as handle:
            handle.write(b"stale")
        with self.assertRaises(capture.CaptureError):
            capture.capture(
                self.hdc, out, [capture.SPECS_BY_ID["trace-recv-minimal"]],
                "KEY", runner=fake_runner_factory(write_recv_bytes=b"x"),
                home="/Users/tester", allow_device_write=True,
                gate_dir=self.passing_gate_dir())

    # --- probe pipeline, self-check, redaction ---

    def test_probe_run_produces_manifests_and_streams(self):
        selected = [
            capture.SPECS_BY_ID["hitrace-help-long"],
            capture.SPECS_BY_ID["hitrace-tag-list"],
        ]
        manifest = capture.capture(
            self.hdc, self.out_dir(), selected, "KEY",
            runner=fake_runner_factory(stdout=b"usage\n"), home="/Users/tester")
        self.assertFalse(manifest["deviceWriteEnabled"])
        self.assertIsNone(manifest["captureGate"])
        out = self.out_dir()
        self.assertTrue(os.path.isfile(os.path.join(out, "manifest.json")))
        self.assertTrue(os.path.isfile(os.path.join(out, "redacted-manifest.json")))
        self.assertTrue(
            os.path.isfile(os.path.join(out, "00-hitrace-help-long.stdout")))

    def test_self_check_matrix(self):
        self.assertFalse(capture.self_check(b"/Users/alice/x", None)["passed"])
        self.assertFalse(capture.self_check(b"see /home/bob", None)["passed"])
        self.assertFalse(capture.self_check(b"-----BEGIN KEY", None)["passed"])
        clean = capture.self_check(b"/data/local/tmp ok comm=render", "KEY1")
        self.assertTrue(clean["passed"])
        self.assertFalse(clean["serialPresent"])
        with_serial = capture.self_check(b"device KEY1 Connected", "KEY1")
        self.assertTrue(with_serial["passed"])
        self.assertTrue(with_serial["serialPresent"])
        self.assertIsNone(capture.self_check(b"x", None)["serialPresent"])

    def test_redacted_manifest_masks_connectkey_home_and_gate_dir(self):
        gate = self.passing_gate_dir()
        manifest = capture.capture(
            self.hdc, self.out_dir(), [capture.SPECS_BY_ID["trace-remote-mkdir"]],
            "SERIAL9", runner=fake_runner_factory(), home=self.root,
            allow_device_write=True, gate_dir=gate)
        with open(os.path.join(self.out_dir(), "redacted-manifest.json"), "rb") as handle:
            redacted_text = handle.read().decode("utf-8")
        self.assertNotIn("SERIAL9", redacted_text)
        self.assertNotIn(self.root, redacted_text)
        redacted = json.loads(redacted_text)
        self.assertEqual(redacted["schema"], capture.REDACTED_SCHEMA)
        self.assertIn("<connectkey>", json.dumps(redacted["commands"][0]["argv"]))
        self.assertEqual(manifest["schema"], capture.MANIFEST_SCHEMA)

    def test_redaction_gate_raises_on_planted_leak(self):
        with self.assertRaises(capture.CaptureError):
            capture._assert_redacted_clean(
                "argv includes /Users/alice/leak", "/Users/tester", None)

    def test_output_inside_git_repository_is_refused(self):
        repo_like = os.path.join(self.root, "repo")
        os.makedirs(os.path.join(repo_like, ".git"))
        nested = os.path.join(repo_like, "captures")
        with self.assertRaises(capture.CaptureError):
            capture.assert_outside_repository(nested)

    def test_unknown_command_id_exits_2(self):
        code = capture.main(
            ["--hdc", self.hdc, "--out-dir", self.out_dir(), "--commands", "evil-cmd"])
        self.assertEqual(code, 2)

    def test_selection_aliases(self):
        probes = capture._select("probe")
        self.assertTrue(probes)
        self.assertTrue(all(not spec.device_write for spec in probes))
        sequence = capture._select("capture")
        self.assertEqual(
            [spec.ident for spec in sequence], list(capture.CAPTURE_SEQUENCE))

    # --- meta: no shell, serializer parity ---

    def test_ast_contains_no_shell_or_system_call(self):
        with open(os.path.join(HERE, "capture.py"), "r", encoding="utf-8") as handle:
            tree = ast.parse(handle.read())
        for node in ast.walk(tree):
            if isinstance(node, ast.keyword) and node.arg == "shell":
                self.fail("subprocess call with shell keyword found")
            if (
                isinstance(node, ast.Attribute)
                and node.attr in ("system", "popen")
                and isinstance(node.value, ast.Name)
                and node.value.id == "os"
            ):
                self.fail(f"forbidden os.{node.attr} usage found")

    def test_json_bytes_parity_with_m0b_serializer(self):
        m0b = _load_m0b_module()
        sample = {"b": [1, 2], "a": {"nested": "值"}}
        self.assertEqual(capture._json_bytes(sample), m0b._json_bytes(sample))


if __name__ == "__main__":
    unittest.main()
