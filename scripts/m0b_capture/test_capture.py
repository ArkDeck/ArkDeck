"""Tests for the M0B capture harness. These NEVER invoke real hdc: pipeline
tests inject a fake runner, and the subprocess-runner tests spawn only the
current Python interpreter. They prove the safety-critical logic — closed
allowlist (snapshot-pinned, README-synced), per-stream hashing, truncation and
timeout as explicit runner channels, sensitive-content self-check, connectkey/
home masking with its output-side redaction gate, the outside-repository output
gate (including symlinked out-dirs), and byte-format parity with the
archive_characterization evidence serializer — without a device.
"""

from __future__ import annotations

import ast
import contextlib
import importlib.util
import io
import json
import os
import re
import signal
import stat
import sys
import tempfile
import time
import unittest
import unittest.mock

import capture

_MODULE_DIR = os.path.dirname(os.path.abspath(capture.__file__))


def _result(exit_code=0, out=b"", err=b"", timed_out=False,
            out_trunc=False, err_trunc=False, duration_ms=5):
    return capture.RunnerResult(
        exit_code=exit_code, timed_out=timed_out, stdout=out, stderr=err,
        stdout_truncated=out_trunc, stderr_truncated=err_trunc,
        duration_ms=duration_ms)


def _fake_runner(outputs):
    """Return a runner yielding queued results per call. Each queued item is a
    RunnerResult or a shorthand (exit, stdout, stderr) tuple."""
    calls = {"argv": []}

    def runner(argv, timeout):
        calls["argv"].append(argv)
        item = outputs[len(calls["argv"]) - 1]
        if isinstance(item, tuple):
            exit_code, out, err = item
            return _result(exit_code=exit_code, out=out, err=err)
        return item

    return runner, calls


def _fake_hdc(directory):
    path = os.path.join(directory, "hdc")
    with open(path, "wb") as handle:
        handle.write(b"#!/bin/sh\nexit 0\n")
    os.chmod(path, 0o755)
    return path


def _read_source(name: str) -> str:
    with io.open(os.path.join(_MODULE_DIR, name), encoding="utf-8") as handle:
        return handle.read()


class AllowlistTests(unittest.TestCase):
    def test_allowlist_snapshot_pins_ident_tokens_and_target_slot(self):
        # Any change to the closed allowlist must fail here and force the
        # design.md-first review the module docstring demands.
        expected = {
            ("hdc-version-flag", ("-v",), False),
            ("hdc-version-word", ("version",), False),
            ("hdc-checkserver", ("checkserver",), False),
            ("hdc-list-targets", ("list", "targets"), False),
            ("hdc-list-targets-verbose", ("list", "targets", "-v"), False),
            ("hidumper-help", ("shell", "hidumper", "--help"), True),
            ("hidumper-services", ("shell", "hidumper", "-ls"), True),
        }
        actual = {(s.ident, s.tokens, s.needs_target) for s in capture.COMMAND_SPECS}
        self.assertEqual(actual, expected)

    def test_allowlist_contains_only_read_only_verbs(self):
        banned = {
            "install", "uninstall", "file", "send", "recv", "reboot", "boot",
            "tmode", "tconn", "kill", "start", "killall-sub", "flash", "format",
            "erase", "fastboot", "upgrade_tool",
        }
        for spec in capture.COMMAND_SPECS:
            self.assertFalse(
                set(spec.tokens) & banned, f"{spec.ident} contains a mutating verb")

    def test_readme_command_table_matches_allowlist(self):
        readme = _read_source("README.md")
        table_ids = set(re.findall(r"^\s*\|\s*`([a-z0-9-]+)`\s*\|", readme, re.MULTILINE))
        self.assertEqual(table_ids, set(capture.SPECS_BY_ID))

    def test_build_argv_uses_only_fixed_tokens_plus_targeted_slot(self):
        hdc = "/opt/hdc"
        spec = capture.SPECS_BY_ID["hdc-list-targets-verbose"]
        self.assertEqual(capture.build_argv(hdc, spec, None), [hdc, "list", "targets", "-v"])
        # A target is ignored by a non-targeted spec.
        self.assertEqual(
            capture.build_argv(hdc, spec, "SERIAL123"), [hdc, "list", "targets", "-v"])

    def test_connectkey_only_lands_in_fixed_dash_t_slot(self):
        hdc = "/opt/hdc"
        spec = capture.SPECS_BY_ID["hidumper-help"]
        self.assertEqual(
            capture.build_argv(hdc, spec, "SERIAL123"),
            [hdc, "-t", "SERIAL123", "shell", "hidumper", "--help"])
        # The connectkey never fuses into another token.
        argv = capture.build_argv(hdc, spec, "SERIAL123")
        self.assertNotIn("hidumperSERIAL123", argv)
        self.assertEqual(argv.count("SERIAL123"), 1)

    def test_build_argv_rejects_forged_spec_with_known_ident(self):
        forged = capture.CommandSpec("hdc-list-targets", ("shell", "reboot"), False, "x")
        with self.assertRaises(capture.CaptureError):
            capture.build_argv("/opt/hdc", forged, None)

    def test_selection_rejects_unknown_command_id(self):
        with self.assertRaises(capture.CaptureError):
            capture._select("hdc-version-flag,evil-reboot")

    def test_selection_all_returns_every_spec(self):
        self.assertEqual(len(capture._select("all")), len(capture.COMMAND_SPECS))

    def test_no_shell_kwarg_in_any_call(self):
        # AST-level: no call in capture.py may pass a `shell` keyword at all
        # (catches shell=True, shell = True, shell=variable — not just the
        # literal substring).
        tree = ast.parse(_read_source("capture.py"))
        for node in ast.walk(tree):
            if isinstance(node, ast.Call):
                for keyword in node.keywords:
                    self.assertNotEqual(
                        keyword.arg, "shell",
                        f"call at line {node.lineno} passes a shell= keyword")


class SelfCheckTests(unittest.TestCase):
    def test_user_path_fails_self_check(self):
        result = capture.self_check(b"leaked /Users/alice/secret/key.pem here", None)
        self.assertTrue(result["userPathFound"])
        self.assertFalse(result["passed"])

    def test_bare_home_path_without_trailing_slash_fails(self):
        for payload in (
            b"HOME=/Users/alice\n",
            b"cannot open /Users/alice: denied",
            b"log written to /Users/alice",
        ):
            result = capture.self_check(payload, None)
            self.assertTrue(result["userPathFound"], payload)
            self.assertFalse(result["passed"], payload)

    def test_non_macos_home_paths_fail(self):
        for payload in (b"/home/alice/.ssh/id_rsa", b"/var/root/.profile"):
            self.assertFalse(capture.self_check(payload, None)["passed"], payload)

    def test_key_material_fails_self_check(self):
        result = capture.self_check(b"-----BEGIN OPENSSH PRIVATE KEY-----", None)
        self.assertTrue(result["keyMaterialFound"])
        self.assertFalse(result["passed"])

    def test_serial_alone_passes_but_is_recorded(self):
        result = capture.self_check(b"[Empty]\nSERIAL123\tConnected", "SERIAL123")
        self.assertIs(result["serialPresent"], True)
        self.assertFalse(result["userPathFound"])
        self.assertFalse(result["keyMaterialFound"])
        self.assertTrue(result["passed"])

    def test_serial_presence_is_none_without_connectkey(self):
        # Discovery runs have no --target; the serial cannot be checked for, so
        # the field must be None (unknown), never a false "absent".
        result = capture.self_check(b"List of targets:\nSERIAL123\n", None)
        self.assertIsNone(result["serialPresent"])
        self.assertTrue(result["passed"])

    def test_ordinary_device_path_does_not_trip_user_path(self):
        result = capture.self_check(b"/data/local/tmp/output present", None)
        self.assertTrue(result["passed"])


class RedactionTests(unittest.TestCase):
    def test_mask_home_masks_own_home(self):
        self.assertEqual(
            capture._mask_home("/Users/tester/sdk/hdc", "/Users/tester"), "~/sdk/hdc")
        self.assertEqual(capture._mask_home("/Users/tester", "/Users/tester"), "~")

    def test_mask_home_does_not_eat_sibling_user_prefix(self):
        masked = capture._mask_home("cp /Users/tester2/sdk/hdc failed", "/Users/tester")
        self.assertNotIn("tester", masked)
        self.assertIn("<redacted-user-dir>/sdk/hdc", masked)

    def test_mask_home_is_case_insensitive(self):
        # macOS filesystems are case-insensitive: a hand-typed lowercase path
        # resolves and must still be masked.
        self.assertEqual(
            capture._mask_home("/users/tester/sdk/hdc", "/Users/tester"), "~/sdk/hdc")

    def test_mask_home_with_root_home_does_not_garble(self):
        # HOME=/ must disable the home replacement (empty needle), not
        # interleave '~' between every character.
        self.assertEqual(capture._mask_home("/opt/hdc", "/"), "/opt/hdc")

    def test_mask_home_masks_foreign_user_dirs(self):
        masked = capture._mask_home("saw /home/alice and /var/root here", "/Users/tester")
        self.assertNotIn("/home/alice", masked)
        self.assertNotIn("/var/root", masked)

    def test_mask_connectkey_uses_constant_placeholder(self):
        argv = ["/opt/hdc", "-t", "SERIAL123", "shell", "hidumper", "--help"]
        masked = capture._mask_connectkey(argv, "SERIAL123")
        self.assertNotIn("SERIAL123", masked)
        self.assertIn("<connectkey>", masked)

    def test_redaction_gate_detects_survivors(self):
        with self.assertRaises(capture.CaptureError):
            capture._assert_redacted_clean(
                '{"path": "/Users/tester/sdk"}', "/Users/tester", None)
        with self.assertRaises(capture.CaptureError):
            capture._assert_redacted_clean('{"argv": "SERIAL123"}', "/x", "SERIAL123")
        capture._assert_redacted_clean('{"path": "~/sdk"}', "/Users/tester", "SERIAL123")


class OutputLocationTests(unittest.TestCase):
    def test_refuses_output_inside_git_repository(self):
        with tempfile.TemporaryDirectory() as tmp:
            os.mkdir(os.path.join(tmp, ".git"))
            nested = os.path.join(tmp, "captures")
            with self.assertRaises(capture.CaptureError):
                capture.assert_outside_repository(nested)

    def test_refuses_symlinked_outdir_pointing_into_repository(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = os.path.join(tmp, "repo")
            os.makedirs(os.path.join(repo, ".git"))
            os.makedirs(os.path.join(repo, "captures"))
            link = os.path.join(tmp, "outside-link")
            os.symlink(os.path.join(repo, "captures"), link)
            with self.assertRaises(capture.CaptureError):
                capture.assert_outside_repository(os.path.join(link, "run1"))

    def test_refuses_worktree_with_git_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            with open(os.path.join(tmp, ".git"), "w", encoding="utf-8") as handle:
                handle.write("gitdir: /somewhere/else\n")
            with self.assertRaises(capture.CaptureError):
                capture.assert_outside_repository(os.path.join(tmp, "captures"))

    def test_allows_output_outside_repository(self):
        with tempfile.TemporaryDirectory() as tmp:
            capture.assert_outside_repository(os.path.join(tmp, "captures"))


class CapturePipelineTests(unittest.TestCase):
    def _run(self, tmp, outputs, target=None, commands=None, home="/Users/tester"):
        selected = commands or [
            capture.SPECS_BY_ID["hdc-list-targets"],
            capture.SPECS_BY_ID["hidumper-help"],
        ]
        runner, calls = _fake_runner(outputs)
        out_dir = os.path.join(tmp, "captures")
        manifest = capture.capture(
            hdc_path=_fake_hdc(tmp), out_dir=out_dir, selected=selected, target=target,
            runner=runner, home=home)
        return manifest, out_dir, calls

    def test_per_stream_files_and_hashes_match(self):
        with tempfile.TemporaryDirectory() as tmp:
            outputs = [
                (0, b"List of targets:\nSERIAL123\n", b""),
                (0, b"usage: hidumper", b"warn: none"),
            ]
            manifest, out_dir, _ = self._run(tmp, outputs, target="SERIAL123")
            first = manifest["commands"][0]
            self.assertEqual(first["stdout"]["bytes"], len(outputs[0][1]))
            with open(os.path.join(out_dir, first["stdout"]["file"]), "rb") as handle:
                self.assertEqual(handle.read(), outputs[0][1])
            import hashlib

            self.assertEqual(
                first["stdout"]["sha256"], hashlib.sha256(outputs[0][1]).hexdigest())
            self.assertEqual(
                manifest["commands"][1]["stderr"]["sha256"],
                hashlib.sha256(outputs[1][2]).hexdigest())

    def test_stream_files_and_out_dir_are_owner_only(self):
        with tempfile.TemporaryDirectory() as tmp:
            manifest, out_dir, _ = self._run(tmp, [(0, b"a", b""), (0, b"b", b"")])
            self.assertEqual(stat.S_IMODE(os.stat(out_dir).st_mode) & 0o077, 0)
            for command in manifest["commands"]:
                mode = os.stat(os.path.join(out_dir, command["stdout"]["file"])).st_mode
                self.assertEqual(stat.S_IMODE(mode) & 0o077, 0)

    def test_redacted_manifest_masks_connectkey_and_home(self):
        with tempfile.TemporaryDirectory() as tmp:
            # Make the injected home the real parent of the hdc binary so the
            # home-masking assertion actually exercises _mask_home (a home that
            # appears nowhere in the manifest would make this test vacuous).
            home = os.path.realpath(tmp)
            manifest, out_dir, _ = self._run(
                tmp, [(0, b"ok", b""), (0, b"ok", b"")], target="SERIAL123", home=home)
            self.assertIn(home, json.dumps(manifest))
            with open(os.path.join(out_dir, "redacted-manifest.json"), encoding="utf-8") as handle:
                redacted = json.load(handle)
            blob = json.dumps(redacted)
            self.assertNotIn("SERIAL123", blob)
            self.assertNotIn(home, blob)
            self.assertIn("<connectkey>", blob)
            self.assertEqual(redacted["toolchain"]["hdcPath"], "~/hdc")
            # The full manifest keeps the real values for the controlled location.
            with open(os.path.join(out_dir, "manifest.json"), encoding="utf-8") as handle:
                full_text = handle.read()
            self.assertIn("SERIAL123", full_text)
            self.assertIn(home, full_text)

    def test_redaction_gate_blocks_write_when_masking_is_broken(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = os.path.realpath(tmp)
            runner, _ = _fake_runner([(0, b"ok", b"")])
            out_dir = os.path.join(tmp, "captures")
            with unittest.mock.patch.object(
                    capture, "_mask_home", lambda text, _home: text):
                with self.assertRaises(capture.CaptureError):
                    capture.capture(
                        hdc_path=_fake_hdc(tmp), out_dir=out_dir,
                        selected=[capture.SPECS_BY_ID["hdc-version-flag"]], target=None,
                        runner=runner, home=home)
            # Fail-safe: full manifest kept for investigation, redacted withheld.
            self.assertTrue(os.path.exists(os.path.join(out_dir, "manifest.json")))
            self.assertFalse(
                os.path.exists(os.path.join(out_dir, "redacted-manifest.json")))

    def test_self_check_failure_propagates_to_manifest(self):
        with tempfile.TemporaryDirectory() as tmp:
            outputs = [(0, b"/Users/victim/id_rsa", b""), (0, b"ok", b"")]
            manifest, _, _ = self._run(tmp, outputs)
            self.assertFalse(manifest["selfCheckPassed"])
            self.assertFalse(manifest["commands"][0]["selfCheck"]["passed"])
            self.assertTrue(manifest["commands"][0]["selfCheck"]["stdout"]["userPathFound"])

    def test_timeout_is_its_own_channel_with_null_exit_code(self):
        with tempfile.TemporaryDirectory() as tmp:
            outputs = [_result(exit_code=None, timed_out=True), (0, b"ok", b"")]
            manifest, _, _ = self._run(tmp, outputs)
            self.assertTrue(manifest["commands"][0]["timedOut"])
            self.assertIsNone(manifest["commands"][0]["exitCode"])

    def test_signal_death_is_not_recorded_as_timeout(self):
        with tempfile.TemporaryDirectory() as tmp:
            outputs = [_result(exit_code=-1), (0, b"ok", b"")]
            manifest, _, _ = self._run(tmp, outputs)
            self.assertFalse(manifest["commands"][0]["timedOut"])
            self.assertEqual(manifest["commands"][0]["exitCode"], -1)

    def test_truncation_flags_flow_from_runner_to_manifest(self):
        with tempfile.TemporaryDirectory() as tmp:
            outputs = [_result(out=b"x", out_trunc=True), (0, b"ok", b"")]
            manifest, _, _ = self._run(tmp, outputs)
            self.assertTrue(manifest["commands"][0]["stdout"]["truncated"])
            self.assertFalse(manifest["commands"][0]["stderr"]["truncated"])

    def test_runner_receives_only_allowlisted_argv(self):
        with tempfile.TemporaryDirectory() as tmp:
            _, _, calls = self._run(tmp, [(0, b"a", b""), (0, b"b", b"")], target="SERIAL123")
            self.assertEqual(calls["argv"][0][1:], ["list", "targets"])
            self.assertEqual(calls["argv"][1][1:], ["-t", "SERIAL123", "shell", "hidumper", "--help"])

    def test_capture_refuses_non_executable_hdc(self):
        with tempfile.TemporaryDirectory() as tmp:
            plain = os.path.join(tmp, "not-hdc")
            with open(plain, "wb") as handle:
                handle.write(b"x")
            os.chmod(plain, 0o600)
            runner, _ = _fake_runner([(0, b"", b"")])
            with self.assertRaises(capture.CaptureError):
                capture.capture(
                    hdc_path=plain, out_dir=os.path.join(tmp, "out"),
                    selected=[capture.SPECS_BY_ID["hdc-version-flag"]], target=None,
                    runner=runner)

    def test_exec_failure_becomes_capture_error(self):
        # Models --hdc pointing at a wrong-architecture or corrupt binary that
        # passes isfile+X_OK but fails to exec (OSError Errno 8).
        def runner(argv, timeout):
            raise OSError(8, "Exec format error")

        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(capture.CaptureError):
                capture.capture(
                    hdc_path=_fake_hdc(tmp), out_dir=os.path.join(tmp, "out"),
                    selected=[capture.SPECS_BY_ID["hdc-version-flag"]], target=None,
                    runner=runner, home="/Users/tester")

    def test_non_utf8_target_is_rejected_early(self):
        runner, _ = _fake_runner([(0, b"", b"")])
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(capture.CaptureError):
                capture.capture(
                    hdc_path=_fake_hdc(tmp), out_dir=os.path.join(tmp, "out"),
                    selected=[capture.SPECS_BY_ID["hidumper-help"]], target="bad\udcff",
                    runner=runner, home="/Users/tester")

    def test_nonpositive_timeout_is_rejected(self):
        runner, _ = _fake_runner([(0, b"", b"")])
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(capture.CaptureError):
                capture.capture(
                    hdc_path=_fake_hdc(tmp), out_dir=os.path.join(tmp, "out"),
                    selected=[capture.SPECS_BY_ID["hdc-version-flag"]], target=None,
                    runner=runner, timeout=0, home="/Users/tester")

    def test_existing_stream_file_refused_as_capture_error(self):
        with tempfile.TemporaryDirectory() as tmp:
            out_dir = os.path.join(tmp, "captures")
            os.makedirs(out_dir)
            with open(os.path.join(out_dir, "00-hdc-version-flag.stdout"), "wb") as handle:
                handle.write(b"existing")
            runner, _ = _fake_runner([(0, b"new", b"")])
            with self.assertRaises(capture.CaptureError):
                capture.capture(
                    hdc_path=_fake_hdc(tmp), out_dir=out_dir,
                    selected=[capture.SPECS_BY_ID["hdc-version-flag"]], target=None,
                    runner=runner, home="/Users/tester")
            # Never overwrite evidence.
            with open(os.path.join(out_dir, "00-hdc-version-flag.stdout"), "rb") as handle:
                self.assertEqual(handle.read(), b"existing")

    def test_manifest_is_labeled_controlled_human_capture(self):
        with tempfile.TemporaryDirectory() as tmp:
            manifest, _, _ = self._run(tmp, [(0, b"a", b""), (0, b"b", b"")])
            self.assertEqual(manifest["evidenceClass"], "controlledHumanCapture")
            self.assertNotIn("realHardware", json.dumps(manifest["evidenceClass"]))


class SubprocessRunnerTests(unittest.TestCase):
    """Real subprocess semantics, exercised with the current interpreter only."""

    def test_records_verbatim_exit_code_and_streams(self):
        result = capture.subprocess_runner(
            [sys.executable, "-c",
             "import sys; sys.stdout.write('out'); sys.stderr.write('err'); sys.exit(3)"],
            10)
        self.assertEqual(result.exit_code, 3)
        self.assertFalse(result.timed_out)
        self.assertEqual(result.stdout, b"out")
        self.assertEqual(result.stderr, b"err")
        self.assertFalse(result.stdout_truncated)

    def test_signal_death_keeps_negative_exit_code_and_no_timeout(self):
        result = capture.subprocess_runner(
            [sys.executable, "-c", "import os, signal; os.kill(os.getpid(), signal.SIGHUP)"],
            10)
        self.assertEqual(result.exit_code, -signal.SIGHUP)
        self.assertFalse(result.timed_out)

    def test_timeout_uses_its_own_channel(self):
        result = capture.subprocess_runner(
            [sys.executable, "-c", "import time; time.sleep(30)"], 1)
        self.assertTrue(result.timed_out)
        self.assertIsNone(result.exit_code)

    def test_exactly_max_bytes_is_not_flagged_truncated(self):
        script = "import sys; sys.stdout.buffer.write(b'x' * %d)" % capture.MAX_STREAM_BYTES
        result = capture.subprocess_runner([sys.executable, "-c", script], 30)
        self.assertEqual(len(result.stdout), capture.MAX_STREAM_BYTES)
        self.assertFalse(result.stdout_truncated)

    def test_overflow_is_capped_and_flagged(self):
        script = "import sys; sys.stdout.buffer.write(b'x' * %d)" % (
            capture.MAX_STREAM_BYTES + 1)
        result = capture.subprocess_runner([sys.executable, "-c", script], 30)
        self.assertEqual(len(result.stdout), capture.MAX_STREAM_BYTES)
        self.assertTrue(result.stdout_truncated)

    def test_daemonizing_child_does_not_stall_the_capture(self):
        # Models hdc's auto-started host server: a forked child inherits the
        # pipe write-ends and outlives the client. The runner must return the
        # client's real exit code within the drain grace, not burn the timeout.
        script = (
            "import os, sys\n"
            "if os.fork() == 0:\n"
            "    import time; time.sleep(30); os._exit(0)\n"
            "sys.stdout.write('client-done'); sys.stdout.flush()\n")
        started = time.monotonic()
        result = capture.subprocess_runner([sys.executable, "-c", script], 20)
        elapsed = time.monotonic() - started
        self.assertEqual(result.exit_code, 0)
        self.assertFalse(result.timed_out)
        self.assertIn(b"client-done", result.stdout)
        self.assertLess(elapsed, 10)


class CliTests(unittest.TestCase):
    def test_timeout_zero_or_negative_rejected_at_parse(self):
        parser = capture.build_arg_parser()
        for bad in ("0", "-5", "abc"):
            with self.assertRaises(SystemExit):
                with contextlib.redirect_stderr(io.StringIO()):
                    parser.parse_args(["--hdc", "/x", "--out-dir", "/y", "--timeout", bad])


class SerializerParityTests(unittest.TestCase):
    def test_json_bytes_matches_archive_characterization_serializer(self):
        # The repo's deterministic-evidence-bytes convention lives in
        # scripts/archive_characterization/scan.py::_serialize; this pin keeps
        # the two standalone harnesses byte-compatible.
        scan_path = os.path.join(
            os.path.dirname(os.path.dirname(_MODULE_DIR)),
            "scripts", "archive_characterization", "scan.py")
        self.assertTrue(os.path.isfile(scan_path), scan_path)
        spec = importlib.util.spec_from_file_location("_arkdeck_scan_parity", scan_path)
        scan = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = scan
        try:
            spec.loader.exec_module(scan)
            sample = {"b": [1, 2], "a": "文", "nested": {"y": None, "x": True}}
            self.assertEqual(capture._json_bytes(sample), scan._serialize(sample))
        finally:
            del sys.modules[spec.name]


if __name__ == "__main__":
    unittest.main()
