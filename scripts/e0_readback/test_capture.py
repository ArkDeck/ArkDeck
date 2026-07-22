"""Host-side tests for the E0 readback crib (CHG-2026-025 TASK-AIN-004).

Run: python3 -m unittest scripts/e0_readback/test_capture.py -v

No device required: a fake runner injects synthetic hdc output. The tests pin the
safety properties the crib enforces (closed allowlist, no-shell argv, serial-digest
verdict, out-of-repo refusal, redaction gate, exit-code mapping) so a regression
cannot ship silently.
"""

from __future__ import annotations

import ast
import hashlib
import importlib.util
import json
import os
import pathlib
import sys
import tempfile
import unittest

# Load the sibling capture.py by path so the suite runs from the repo root
# (`python3 -m unittest scripts/e0_readback/test_capture.py`), matching the
# m0b_capture / trace_capture precedent. The module is registered in sys.modules
# before exec so dataclasses can resolve its own annotations (Python 3.12+).
MODULE_PATH = pathlib.Path(__file__).with_name("capture.py")
_spec = importlib.util.spec_from_file_location("_e0_readback_capture", MODULE_PATH)
e0 = importlib.util.module_from_spec(_spec)
sys.modules[_spec.name] = e0
_spec.loader.exec_module(e0)
KNOWN_SERIAL = b"150100424a544434520325874bbf4900"


def fake_runner(discovery_stdout: bytes):
    """Return a runner that yields fixed stdout for list-targets and empty output
    for the version/checkserver probes."""

    def run(argv, timeout):
        stdout = discovery_stdout if argv[-2:] == ["list", "targets"] else b""
        return e0.RunnerResult(
            exit_code=0, timed_out=False, stdout=stdout, stderr=b"", duration_ms=1)

    return run


def loader_usb_reader() -> bytes:
    return json.dumps(
        {"SPUSBDataType": [{"_items": [{"vendor_id": "0x2207", "product_id": "0x350a"}]}]}
    ).encode()


class SerialDigestTests(unittest.TestCase):
    def test_pinned_preimage_digests_to_pin(self):
        self.assertEqual(e0.serial_digest(KNOWN_SERIAL), e0.PINNED_SERIAL_SHA256)
        # cross-check the pin is really SHA-256 of the M0B-recorded serial
        self.assertEqual(hashlib.sha256(KNOWN_SERIAL).hexdigest(), e0.PINNED_SERIAL_SHA256)

    def test_matching_device_is_true(self):
        verdict = e0.matches_pinned_serial(KNOWN_SERIAL + b"\tConnected\tlocalhost\n")
        self.assertTrue(verdict["matched"])
        self.assertEqual(verdict["serialTokenCount"], 1)

    def test_wrong_device_is_false(self):
        self.assertFalse(
            e0.matches_pinned_serial(b"deadbeefdeadbeefdeadbeefdeadbeef\n")["matched"])

    def test_empty_discovery_is_false(self):
        self.assertFalse(e0.matches_pinned_serial(b"[Empty]\n")["matched"])
        self.assertFalse(e0.matches_pinned_serial(b"")["matched"])

    def test_observed_digests_never_include_raw_serial(self):
        verdict = e0.matches_pinned_serial(KNOWN_SERIAL + b"\n")
        blob = json.dumps(verdict)
        self.assertNotIn(KNOWN_SERIAL.decode(), blob)
        self.assertIn(e0.PINNED_SERIAL_SHA256, verdict["observedDigests"])


class UsbModeTests(unittest.TestCase):
    def test_mode_classification(self):
        self.assertEqual(e0.classify_usb_mode(0x350A), "rockUsbLoader")
        self.assertEqual(e0.classify_usb_mode(0x0018), "normalSystemHdc")
        self.assertEqual(e0.classify_usb_mode(0x5000), "updaterHdc")
        self.assertEqual(e0.classify_usb_mode(0x1234), "unknown")

    def test_parse_finds_2207_devices(self):
        self.assertEqual(
            e0.parse_usb_identities(loader_usb_reader()),
            [{"vendorId": 0x2207, "productId": 0x350A, "mode": "rockUsbLoader"}])

    def test_parse_ignores_other_vendors(self):
        other = json.dumps(
            {"SPUSBDataType": [{"_items": [{"vendor_id": "0x05ac", "product_id": "0x1234"}]}]}
        ).encode()
        self.assertEqual(e0.parse_usb_identities(other), [])

    def test_parse_malformed_is_empty(self):
        self.assertEqual(e0.parse_usb_identities(b"not json"), [])
        self.assertEqual(e0.parse_usb_identities(b""), [])


class ArgvSafetyTests(unittest.TestCase):
    def test_closed_allowlist_refuses_lookalike(self):
        with self.assertRaises(e0.ReadbackError):
            e0.build_argv("/hdc", e0.CommandSpec("hdc-version", ("shell", "rm", "-rf"), "x"))

    def test_argv_is_fixed_tokens(self):
        self.assertEqual(
            e0.build_argv("/hdc", e0.SPECS_BY_ID["hdc-list-targets-verbose"]),
            ["/hdc", "list", "targets", "-v"])

    def test_allowlist_has_no_mutating_verb(self):
        forbidden = {"install", "uninstall", "file", "reboot", "flash", "tmode", "kill",
                     "shell", "rm", "send", "recv", "smode"}
        for spec in e0.COMMAND_SPECS:
            self.assertTrue(forbidden.isdisjoint(spec.tokens), spec.ident)

    def test_source_uses_no_shell(self):
        """AST check: no subprocess call passes shell=True."""
        tree = ast.parse(MODULE_PATH.read_text(encoding="utf-8"))
        for node in ast.walk(tree):
            if isinstance(node, ast.Call):
                for kw in node.keywords:
                    if kw.arg == "shell":
                        self.assertFalse(
                            isinstance(kw.value, ast.Constant) and kw.value.value is True,
                            "shell=True must never appear")


class OutputSafetyTests(unittest.TestCase):
    def test_refuses_output_inside_repo(self):
        with tempfile.TemporaryDirectory() as root:
            os.makedirs(os.path.join(root, ".git"))
            inside = os.path.join(root, "sub")
            with self.assertRaises(e0.ReadbackError):
                e0.assert_outside_repository(inside)

    def test_allows_output_outside_repo(self):
        with tempfile.TemporaryDirectory() as root:
            e0.assert_outside_repository(root)  # no .git anywhere up the tree

    def test_redaction_gate_catches_raw_serial(self):
        with self.assertRaises(e0.ReadbackError):
            e0._assert_redacted_clean(
                '{"x": "150100424a544434520325874bbf4900"}', "/Users/op",
                ["150100424a544434520325874bbf4900"])

    def test_redaction_gate_catches_user_path(self):
        with self.assertRaises(e0.ReadbackError):
            e0._assert_redacted_clean('{"p": "/Users/alice/x"}', "/Users/bob", [])


class ExitMappingTests(unittest.TestCase):
    def test_match_and_clean_is_zero(self):
        self.assertEqual(e0._exit_code(True, True), 0)

    def test_mismatch_is_one(self):
        self.assertEqual(e0._exit_code(False, True), 1)

    def test_sensitive_failure_is_one(self):
        self.assertEqual(e0._exit_code(True, False), 1)


class EndToEndTests(unittest.TestCase):
    """Full readback() against a fake runner + fake USB reader, writing to an
    out-of-repo temp dir."""

    def _run(self, discovery_stdout):
        tmp = tempfile.mkdtemp()  # system temp is outside any repo
        fake_hdc = os.path.join(tmp, "hdc")
        with open(fake_hdc, "wb") as handle:
            handle.write(b"#!/bin/sh\n")
        os.chmod(fake_hdc, 0o755)
        out_dir = os.path.join(tmp, "run-1")
        summary = e0.readback(
            hdc_path=fake_hdc, out_dir=out_dir,
            runner=fake_runner(discovery_stdout), usb_reader=loader_usb_reader,
            home="/Users/tester")
        return summary, out_dir

    def test_matching_device_summary_and_redaction(self):
        summary, out_dir = self._run(KNOWN_SERIAL + b"\tConnected\tlocalhost\n")
        self.assertTrue(summary["serialVerdict"]["matched"])
        self.assertEqual(summary["usbIdentities"][0]["mode"], "rockUsbLoader")
        # redacted summary exists and does NOT contain the raw serial
        redacted = pathlib.Path(out_dir, "redacted-summary.json").read_text()
        self.assertNotIn(KNOWN_SERIAL.decode(), redacted)
        self.assertIn(e0.PINNED_SERIAL_SHA256, redacted)

    def test_wrong_device_summary_not_matched(self):
        summary, _ = self._run(b"aaaabbbbccccddddeeeeffff00001111\n")
        self.assertFalse(summary["serialVerdict"]["matched"])

    def test_sensitive_byte_scan_flags_user_path(self):
        # discovery stdout is bytes; a user path in it must set the flag False
        # (regression guard for the str-pattern-on-bytes bug).
        summary, _ = self._run(b"HOME=/Users/leak " + KNOWN_SERIAL + b"\n")
        self.assertFalse(summary["sensitiveSelfCheckPassed"])

    def test_clean_discovery_passes_sensitive_scan(self):
        summary, _ = self._run(KNOWN_SERIAL + b"\tConnected\tlocalhost\n")
        self.assertTrue(summary["sensitiveSelfCheckPassed"])

    def test_refuses_to_overwrite_existing_output(self):
        summary, out_dir = self._run(KNOWN_SERIAL + b"\n")
        # a second readback into the same out-dir must refuse (never clobber evidence)
        fake_hdc = summary["toolchain"]["hdcPath"]
        with self.assertRaises(e0.ReadbackError):
            e0.readback(hdc_path=fake_hdc, out_dir=out_dir,
                        runner=fake_runner(KNOWN_SERIAL + b"\n"), usb_reader=loader_usb_reader,
                        home="/Users/tester")


class SelftestHostTests(unittest.TestCase):
    def test_selftest_host_passes(self):
        self.assertTrue(e0.selftest_host())


if __name__ == "__main__":
    unittest.main()
