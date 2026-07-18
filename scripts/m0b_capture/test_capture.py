"""Tests for the M0B capture harness. These NEVER invoke real hdc: every test
injects a fake runner. They prove the safety-critical logic — closed allowlist,
per-stream hashing, sensitive-content self-check, connectkey/home masking, and
the outside-repository output gate — without a device.
"""

from __future__ import annotations

import io
import json
import os
import stat
import tempfile
import unittest

import capture


def _fake_runner(outputs):
    """Return a runner that yields queued (exit, stdout, stderr) per call."""
    calls = {"argv": []}

    def runner(argv, timeout):
        calls["argv"].append(argv)
        exit_code, out, err = outputs[len(calls["argv"]) - 1]
        return (exit_code, out, err, 5)

    return runner, calls


def _fake_hdc(directory):
    path = os.path.join(directory, "hdc")
    with open(path, "wb") as handle:
        handle.write(b"#!/bin/sh\nexit 0\n")
    os.chmod(path, 0o755)
    return path


class AllowlistTests(unittest.TestCase):
    def test_allowlist_contains_only_read_only_verbs(self):
        banned = {
            "install", "uninstall", "file", "send", "recv", "reboot", "boot",
            "tmode", "tconn", "kill", "start", "killall-sub", "flash", "format",
            "erase", "fastboot", "upgrade_tool",
        }
        for spec in capture.COMMAND_SPECS:
            self.assertFalse(
                set(spec.tokens) & banned, f"{spec.ident} contains a mutating verb")

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

    def test_selection_rejects_unknown_command_id(self):
        with self.assertRaises(capture.CaptureError):
            capture._select("hdc-version-flag,evil-reboot")

    def test_selection_all_returns_every_spec(self):
        self.assertEqual(len(capture._select("all")), len(capture.COMMAND_SPECS))

    def test_no_shell_true_in_source(self):
        source = _read_source("capture.py")
        self.assertNotIn("shell=True", source)


class SelfCheckTests(unittest.TestCase):
    def test_user_path_fails_self_check(self):
        result = capture.self_check(b"leaked /Users/alice/secret/key.pem here", None)
        self.assertTrue(result["userPathFound"])
        self.assertFalse(result["passed"])

    def test_key_material_fails_self_check(self):
        result = capture.self_check(b"-----BEGIN OPENSSH PRIVATE KEY-----", None)
        self.assertTrue(result["keyMaterialFound"])
        self.assertFalse(result["passed"])

    def test_serial_alone_passes_but_is_recorded(self):
        result = capture.self_check(b"[Empty]\nSERIAL123\tConnected", "SERIAL123")
        self.assertTrue(result["serialPresent"])
        self.assertFalse(result["userPathFound"])
        self.assertFalse(result["keyMaterialFound"])
        self.assertTrue(result["passed"])

    def test_ordinary_device_path_does_not_trip_user_path(self):
        result = capture.self_check(b"/data/local/tmp/output present", None)
        self.assertTrue(result["passed"])


class OutputLocationTests(unittest.TestCase):
    def test_refuses_output_inside_git_repository(self):
        with tempfile.TemporaryDirectory() as tmp:
            os.mkdir(os.path.join(tmp, ".git"))
            nested = os.path.join(tmp, "captures")
            with self.assertRaises(capture.CaptureError):
                capture.assert_outside_repository(nested)

    def test_allows_output_outside_repository(self):
        with tempfile.TemporaryDirectory() as tmp:
            capture.assert_outside_repository(os.path.join(tmp, "captures"))


class CapturePipelineTests(unittest.TestCase):
    def _run(self, tmp, outputs, target=None, commands=None):
        selected = commands or [
            capture.SPECS_BY_ID["hdc-list-targets"],
            capture.SPECS_BY_ID["hidumper-help"],
        ]
        runner, calls = _fake_runner(outputs)
        out_dir = os.path.join(tmp, "captures")
        manifest = capture.capture(
            hdc_path=_fake_hdc(tmp), out_dir=out_dir, selected=selected, target=target,
            runner=runner, home="/Users/tester")
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

    def test_stream_files_are_owner_only(self):
        with tempfile.TemporaryDirectory() as tmp:
            manifest, out_dir, _ = self._run(tmp, [(0, b"a", b""), (0, b"b", b"")])
            for command in manifest["commands"]:
                mode = os.stat(os.path.join(out_dir, command["stdout"]["file"])).st_mode
                self.assertEqual(stat.S_IMODE(mode) & 0o077, 0)

    def test_redacted_manifest_masks_connectkey_and_home(self):
        with tempfile.TemporaryDirectory() as tmp:
            manifest, out_dir, _ = self._run(
                tmp, [(0, b"ok", b""), (0, b"ok", b"")], target="SERIAL123")
            with open(os.path.join(out_dir, "redacted-manifest.json"), encoding="utf-8") as handle:
                redacted = json.load(handle)
            blob = json.dumps(redacted)
            self.assertNotIn("SERIAL123", blob)
            self.assertNotIn("/Users/tester", blob)
            # The full manifest keeps the real values for the controlled location.
            with open(os.path.join(out_dir, "manifest.json"), encoding="utf-8") as handle:
                self.assertIn("SERIAL123", handle.read())

    def test_self_check_failure_propagates_to_manifest(self):
        with tempfile.TemporaryDirectory() as tmp:
            outputs = [(0, b"/Users/victim/id_rsa", b""), (0, b"ok", b"")]
            manifest, _, _ = self._run(tmp, outputs)
            self.assertFalse(manifest["selfCheckPassed"])
            self.assertFalse(manifest["commands"][0]["selfCheck"]["passed"])
            self.assertTrue(manifest["commands"][0]["selfCheck"]["stdout"]["userPathFound"])

    def test_timeout_is_recorded_not_raised(self):
        with tempfile.TemporaryDirectory() as tmp:
            manifest, _, _ = self._run(tmp, [(-1, b"", b""), (0, b"ok", b"")])
            self.assertTrue(manifest["commands"][0]["timedOut"])
            self.assertEqual(manifest["commands"][0]["exitCode"], -1)

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

    def test_existing_stream_file_is_not_overwritten(self):
        with tempfile.TemporaryDirectory() as tmp:
            out_dir = os.path.join(tmp, "captures")
            os.makedirs(out_dir)
            with open(os.path.join(out_dir, "00-hdc-version-flag.stdout"), "wb") as handle:
                handle.write(b"existing")
            runner, _ = _fake_runner([(0, b"new", b"")])
            with self.assertRaises(FileExistsError):
                capture.capture(
                    hdc_path=_fake_hdc(tmp), out_dir=out_dir,
                    selected=[capture.SPECS_BY_ID["hdc-version-flag"]], target=None,
                    runner=runner, home="/Users/tester")


def _read_source(name: str) -> str:
    path = os.path.join(os.path.dirname(os.path.abspath(capture.__file__)), name)
    with io.open(path, encoding="utf-8") as handle:
        return handle.read()


if __name__ == "__main__":
    unittest.main()
