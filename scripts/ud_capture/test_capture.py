"""Offline contract tests for TASK-UD-CAPTURE-HARNESS-001.

No test invokes HDC, a device, or the network. Capture-pipeline tests inject a
fake runner; subprocess-runner tests execute only the current Python
interpreter. The suite pins the full allowlist, runbook/README argv parity,
placeholder validation, same-session target provenance, stream accounting,
redaction, deterministic manifests, output controls, and AST safety properties.
"""

from __future__ import annotations

import ast
import contextlib
import hashlib
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
import unicodedata
import unittest
import unittest.mock

import capture


_MODULE_DIR = os.path.dirname(os.path.abspath(capture.__file__))
_REPO_ROOT = os.path.dirname(os.path.dirname(_MODULE_DIR))
_RUNBOOK = os.path.join(
    _REPO_ROOT,
    "openspec",
    "changes",
    "chg-2026-008-ui-dump-hidumper-wrapper",
    "capture-runbook.md",
)


def _stream(
    data=b"",
    *,
    truncated=False,
    drain_incomplete=False,
    total_bytes=None,
    whole_bytes=None,
):
    total = len(data) if total_bytes is None else total_bytes
    digest_source = data if whole_bytes is None else whole_bytes
    return capture.CapturedStream.from_bytes(
        data,
        truncated=truncated,
        total_bytes=total,
        sha256=hashlib.sha256(digest_source).hexdigest(),
        drain_incomplete=drain_incomplete,
    )


def _result(
    exit_code=0,
    out=b"",
    err=b"",
    *,
    timed_out=False,
    stdout=None,
    stderr=None,
    duration_ms=5,
):
    return capture.RunnerResult(
        exit_code=exit_code,
        timed_out=timed_out,
        stdout=_stream(out) if stdout is None else stdout,
        stderr=_stream(err) if stderr is None else stderr,
        duration_ms=duration_ms,
    )


def _fake_runner(result=None):
    calls = []
    outcome = _result() if result is None else result

    def runner(argv, timeout):
        calls.append((list(argv), timeout))
        return outcome

    return runner, calls


def _fake_hdc(directory):
    path = os.path.join(directory, "hdc")
    with open(path, "wb") as handle:
        handle.write(b"fake hdc bytes\n")
    os.chmod(path, 0o700)
    return path


def _read(path):
    with open(path, encoding="utf-8") as handle:
        return handle.read()


def _verbose_target_row(key):
    """Mirror the merged M0B `list targets -v` row structure for one target."""
    return key + "\t\tUSB\tConnected\tlocalhost\n"


def _seed_hp(tmp, out_dir, hdc, key="SERIAL123", ident="HP-1"):
    runner, _ = _fake_runner(_result(out=_verbose_target_row(key).encode("ascii")))
    return capture.capture_command(
        hdc_path=hdc,
        out_dir=out_dir,
        spec=capture.SPECS_BY_ID[ident],
        runner=runner,
        home=tmp,
    )


def _arguments_for(spec, tmp, out_dir):
    arguments = {}
    if capture.CONNECT_KEY in spec.placeholders:
        arguments["connect_key"] = "SERIAL123"
    if capture.WINDOW_ID in spec.placeholders:
        arguments["window_id"] = "123"
    if capture.LOCAL_HAP_PATH in spec.placeholders:
        hap = os.path.join(tmp, "entry-default-signed.hap")
        with open(hap, "wb") as handle:
            handle.write(b"synthetic fixture")
        arguments["local_hap_path"] = hap
    if capture.LOCAL_SIDECAR_DEST in spec.placeholders:
        sequence = capture._next_sequence(out_dir)
        arguments["local_sidecar_dest"] = os.path.join(
            out_dir, f"{sequence:02d}-{spec.ident}.sidecar"
        )
    return arguments


def _approved_literal(spec):
    rendered = []
    for token in spec.tokens:
        if token in {
            capture.CONNECT_KEY,
            capture.LOCAL_HAP_PATH,
            capture.LOCAL_SIDECAR_DEST,
        }:
            rendered.append(token)
        else:
            rendered.append(json.dumps(token))
    return "[HDC, " + ", ".join(rendered) + "]"


class AllowlistContractTests(unittest.TestCase):
    EXPECTED = {
        "HP-0": ("version",),
        "HP-1": ("list", "targets", "-v"),
        "HP-2": ("list", "targets", "-v"),
        "INV-1": (
            "-t", "CONNECT_KEY", "shell", "hidumper", "-s",
            "WindowManagerService", "-a", "-a",
        ),
        "R1": (
            "-t", "CONNECT_KEY", "shell", "hidumper", "-s",
            "WindowManagerService", "-a", "-w WINDOW_ID -default",
        ),
        "R2": (
            "-t", "CONNECT_KEY", "shell", "hidumper", "-s",
            "WindowManagerService", "-a", "-w WINDOW_ID -element -c",
        ),
        "R3": (
            "-t", "CONNECT_KEY", "shell", "hidumper", "-s",
            "WindowManagerService", "-a", "-w WINDOW_ID -default -all",
        ),
        "SC-1": (
            "-t", "CONNECT_KEY", "shell", "ls", "-l", capture.REMOTE_SIDECAR,
        ),
        "SC-2": (
            "-t", "CONNECT_KEY", "file", "recv", capture.REMOTE_SIDECAR,
            "LOCAL_SIDECAR_DEST",
        ),
        "SC-3": (
            "-t", "CONNECT_KEY", "shell", "rm", capture.REMOTE_SIDECAR,
        ),
        "FX-1": ("-t", "CONNECT_KEY", "install", "LOCAL_HAP_PATH"),
        "FX-2": (
            "-t", "CONNECT_KEY", "shell", "aa", "start", "-b",
            "com.example.waterflowdemo", "-a", "EntryAbility",
        ),
        "FX-3": (
            "-t", "CONNECT_KEY", "shell", "aa", "force-stop",
            "com.example.waterflowdemo",
        ),
        "FX-4": ("-t", "CONNECT_KEY", "uninstall", "com.example.waterflowdemo"),
    }

    def test_allowlist_snapshot_pins_every_id_and_token(self):
        actual = {spec.ident: spec.tokens for spec in capture.COMMAND_SPECS}
        self.assertEqual(actual, self.EXPECTED)

    def test_r4_is_not_smuggled_into_the_approved_closed_list(self):
        self.assertNotIn("R4", capture.SPECS_BY_ID)

    def test_readme_table_matches_allowlist(self):
        readme = _read(os.path.join(_MODULE_DIR, "README.md"))
        ids = set(re.findall(r"^\| `([A-Z0-9-]+)` \|", readme, re.MULTILINE))
        self.assertEqual(ids, set(capture.SPECS_BY_ID))
        for spec in capture.COMMAND_SPECS:
            self.assertIn(_approved_literal(spec), readme)

    def test_runbook_literals_match_allowlist(self):
        runbook = _read(_RUNBOOK)
        self.assertIn("`hdc version`", runbook)
        self.assertGreaterEqual(runbook.count("`hdc list targets -v`"), 2)
        self.assertEqual(runbook.count("`hdc list targets`"), 0)
        for spec in capture.COMMAND_SPECS:
            if spec.ident not in {"HP-0", "HP-1", "HP-2"}:
                self.assertIn(_approved_literal(spec), runbook, spec.ident)

    def test_build_argv_rejects_forged_known_id(self):
        forged = capture.CommandSpec("HP-1", ("shell", "reboot"), "forged")
        with self.assertRaises(capture.CaptureError):
            capture.build_argv("/opt/hdc", forged, {})

    def test_build_argv_keeps_recipe_payload_one_element(self):
        values = {capture.CONNECT_KEY: "SERIAL123", capture.WINDOW_ID: "42"}
        for ident, payload in (
            ("R1", "-w 42 -default"),
            ("R2", "-w 42 -element -c"),
            ("R3", "-w 42 -default -all"),
        ):
            argv = capture.build_argv("/opt/hdc", capture.SPECS_BY_ID[ident], values)
            self.assertEqual(argv[-1], payload)
            self.assertEqual(argv.count(payload), 1)

    def test_missing_placeholder_is_rejected(self):
        for spec in capture.COMMAND_SPECS:
            if spec.placeholders:
                with self.subTest(spec=spec.ident):
                    with self.assertRaises(capture.CaptureError):
                        capture.build_argv("/opt/hdc", spec, {})


class InputValidationTests(unittest.TestCase):
    def test_window_id_accepts_ascii_decimal_only(self):
        for good in ("0", "7", "00042", "1234567890"):
            self.assertEqual(capture._validate_window_id(good), good)
        for bad in ("", " 1", "1 ", "+1", "-1", "１", "1\n", "1 -all", "1;rm"):
            with self.subTest(value=bad):
                with self.assertRaises(capture.CaptureError):
                    capture._validate_window_id(bad)

    def test_connect_key_rejects_option_whitespace_and_shell_injection(self):
        for good in ("SERIAL123", "192.0.2.1:8710", "[2001:db8::1]:8710"):
            self.assertEqual(capture._validate_connect_key(good), good)
        for bad in ("", "-t", "SERIAL 123", "SERIAL;rm", "SERIAL$(id)", "bad\nkey"):
            with self.subTest(value=bad):
                with self.assertRaises(capture.CaptureError):
                    capture._validate_connect_key(bad)

    def test_targeted_command_requires_latest_same_session_hp_token(self):
        with tempfile.TemporaryDirectory() as tmp:
            out_dir = os.path.join(tmp, "session")
            hdc = _fake_hdc(tmp)
            os.mkdir(out_dir, 0o700)
            runner, _ = _fake_runner()
            with self.assertRaises(capture.CaptureError):
                capture.capture_command(
                    hdc_path=hdc,
                    out_dir=out_dir,
                    spec=capture.SPECS_BY_ID["R1"],
                    connect_key="SERIAL123",
                    window_id="1",
                    runner=runner,
                    home=tmp,
                )

    def test_connect_key_must_be_exact_token_not_substring(self):
        with tempfile.TemporaryDirectory() as tmp:
            out_dir = os.path.join(tmp, "session")
            hdc = _fake_hdc(tmp)
            _seed_hp(tmp, out_dir, hdc, key="SERIAL1234")
            runner, _ = _fake_runner()
            with self.assertRaises(capture.CaptureError):
                capture.capture_command(
                    hdc_path=hdc,
                    out_dir=out_dir,
                    spec=capture.SPECS_BY_ID["R1"],
                    connect_key="SERIAL123",
                    window_id="1",
                    runner=runner,
                    home=tmp,
                )

    def test_status_word_or_disconnected_target_is_not_a_connect_key(self):
        for supplied, line in (
            ("Connected", "SERIAL123\t\tUSB\tConnected\tlocalhost"),
            ("SERIAL123", "SERIAL123\t\tUSB\tOffline\tlocalhost"),
        ):
            with self.subTest(supplied=supplied, line=line):
                with tempfile.TemporaryDirectory() as tmp:
                    out_dir = os.path.join(tmp, "session")
                    hdc = _fake_hdc(tmp)
                    runner, _ = _fake_runner(_result(out=(line + "\n").encode("ascii")))
                    capture.capture_command(
                        hdc_path=hdc,
                        out_dir=out_dir,
                        spec=capture.SPECS_BY_ID["HP-1"],
                        runner=runner,
                        home=tmp,
                    )
                    with self.assertRaises(capture.CaptureError):
                        capture._require_same_session_connect_key(
                            out_dir,
                            supplied,
                            os.path.realpath(hdc),
                            capture._sha256_file(hdc)[0],
                        )

    def test_m0b_plain_serial_only_hp_output_fails_target_binding(self):
        # Merged M0B evidence (chg-2026-006 TASK-M0B-001): plain `list targets`
        # returns only the 32-char serial + newline with no state column. Such
        # output must leave every targeted command fail-closed.
        key = "AB12CD34EF56AB78CD90EF12AB34CD56"
        self.assertEqual(len(key), 32)
        with tempfile.TemporaryDirectory() as tmp:
            out_dir = os.path.join(tmp, "session")
            hdc = _fake_hdc(tmp)
            payload = (key + "\n").encode("ascii")
            self.assertEqual(len(payload), 33)
            runner, _ = _fake_runner(_result(out=payload))
            capture.capture_command(
                hdc_path=hdc,
                out_dir=out_dir,
                spec=capture.SPECS_BY_ID["HP-1"],
                runner=runner,
                home=tmp,
            )
            with self.assertRaises(capture.CaptureError):
                capture._require_same_session_connect_key(
                    out_dir,
                    key,
                    os.path.realpath(hdc),
                    capture._sha256_file(hdc)[0],
                )

    def test_m0b_verbose_connected_row_shape_binds_the_target(self):
        # Byte-for-byte shape of the merged M0B `list targets -v` capture:
        # 32-char key, double tab, USB, Connected, localhost, newline = 58 bytes.
        key = "AB12CD34EF56AB78CD90EF12AB34CD56"
        payload = _verbose_target_row(key).encode("ascii")
        self.assertEqual(len(payload), 58)
        with tempfile.TemporaryDirectory() as tmp:
            out_dir = os.path.join(tmp, "session")
            hdc = _fake_hdc(tmp)
            runner, _ = _fake_runner(_result(out=payload))
            capture.capture_command(
                hdc_path=hdc,
                out_dir=out_dir,
                spec=capture.SPECS_BY_ID["HP-1"],
                runner=runner,
                home=tmp,
            )
            sequence = capture._require_same_session_connect_key(
                out_dir,
                key,
                os.path.realpath(hdc),
                capture._sha256_file(hdc)[0],
            )
            self.assertEqual(sequence, 0)

    def test_latest_hp_recheck_supersedes_older_inventory(self):
        with tempfile.TemporaryDirectory() as tmp:
            out_dir = os.path.join(tmp, "session")
            hdc = _fake_hdc(tmp)
            _seed_hp(tmp, out_dir, hdc, key="SERIAL123", ident="HP-1")
            _seed_hp(tmp, out_dir, hdc, key="DRIFTED", ident="HP-2")
            runner, _ = _fake_runner()
            with self.assertRaises(capture.CaptureError):
                capture.capture_command(
                    hdc_path=hdc,
                    out_dir=out_dir,
                    spec=capture.SPECS_BY_ID["SC-1"],
                    connect_key="SERIAL123",
                    runner=runner,
                    home=tmp,
                )

    def test_corrupt_hp_stream_hash_fails_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            out_dir = os.path.join(tmp, "session")
            hdc = _fake_hdc(tmp)
            hp = _seed_hp(tmp, out_dir, hdc)
            with open(os.path.join(out_dir, hp["streams"]["stdout"]["file"]), "ab") as handle:
                handle.write(b"tamper")
            with self.assertRaises(capture.CaptureError):
                capture._require_same_session_connect_key(
                    out_dir,
                    "SERIAL123",
                    os.path.realpath(hdc),
                    capture._sha256_file(hdc)[0],
                )

    def test_targeted_command_rejects_drain_incomplete_hp_capture(self):
        with tempfile.TemporaryDirectory() as tmp:
            out_dir = os.path.join(tmp, "session")
            hdc = _fake_hdc(tmp)
            incomplete = _stream(
                _verbose_target_row("SERIAL123").encode("ascii"),
                drain_incomplete=True,
            )
            runner, _ = _fake_runner(_result(stdout=incomplete))
            capture.capture_command(
                hdc_path=hdc,
                out_dir=out_dir,
                spec=capture.SPECS_BY_ID["HP-1"],
                runner=runner,
                home=tmp,
            )
            targeted_runner, calls = _fake_runner()
            with self.assertRaises(capture.CaptureError):
                capture.capture_command(
                    hdc_path=hdc,
                    out_dir=out_dir,
                    spec=capture.SPECS_BY_ID["R1"],
                    connect_key="SERIAL123",
                    window_id="1",
                    runner=targeted_runner,
                    home=tmp,
                )
            self.assertEqual(calls, [])

    def test_targeted_command_rejects_different_hdc_identity(self):
        with tempfile.TemporaryDirectory() as tmp:
            out_dir = os.path.join(tmp, "session")
            hdc = _fake_hdc(tmp)
            _seed_hp(tmp, out_dir, hdc)
            other = os.path.join(tmp, "other-hdc")
            with open(other, "wb") as handle:
                handle.write(b"different fake hdc bytes\n")
            os.chmod(other, 0o700)
            runner, _ = _fake_runner()
            with self.assertRaises(capture.CaptureError):
                capture.capture_command(
                    hdc_path=other,
                    out_dir=out_dir,
                    spec=capture.SPECS_BY_ID["R1"],
                    connect_key="SERIAL123",
                    window_id="1",
                    runner=runner,
                    home=tmp,
                )

    def test_hap_must_exist_and_stay_outside_repo(self):
        with tempfile.TemporaryDirectory() as tmp:
            missing = os.path.join(tmp, "missing.hap")
            with self.assertRaises(capture.CaptureError):
                capture._validate_hap_path(missing)
        with self.assertRaises(capture.CaptureError):
            capture._validate_hap_path(os.path.join(_REPO_ROOT, "README.md"))

    def test_sidecar_dest_must_be_new_and_inside_session(self):
        with tempfile.TemporaryDirectory() as tmp:
            session = os.path.join(tmp, "session")
            os.mkdir(session, 0o700)
            outside = os.path.join(tmp, "outside.dump")
            with self.assertRaises(capture.CaptureError):
                capture._validate_sidecar_dest(outside, session, "01-SC-2.sidecar")
            existing = os.path.join(session, "existing.dump")
            with open(existing, "wb") as handle:
                handle.write(b"x")
            with self.assertRaises(capture.CaptureError):
                capture._validate_sidecar_dest(existing, session, "01-SC-2.sidecar")
            fresh = os.path.join(session, "01-SC-2.sidecar")
            resolved, metadata = capture._validate_sidecar_dest(
                fresh, session, "01-SC-2.sidecar"
            )
            self.assertEqual(resolved, os.path.realpath(fresh))
            self.assertTrue(metadata["exclusiveCreatedByHarness"])
            self.assertTrue(os.path.isfile(resolved))
            self.assertEqual(stat.S_IMODE(os.stat(resolved).st_mode) & 0o077, 0)

    def test_unused_inputs_are_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            runner, _ = _fake_runner()
            with self.assertRaises(capture.CaptureError):
                capture.capture_command(
                    hdc_path=_fake_hdc(tmp),
                    out_dir=os.path.join(tmp, "session"),
                    spec=capture.SPECS_BY_ID["HP-0"],
                    connect_key="SERIAL123",
                    runner=runner,
                    home=tmp,
                )


class OutputLocationTests(unittest.TestCase):
    def test_refuses_output_inside_repo_and_symlink_to_repo(self):
        with self.assertRaises(capture.CaptureError):
            capture.assert_outside_repository(os.path.join(_REPO_ROOT, "captures"))
        with tempfile.TemporaryDirectory() as tmp:
            link = os.path.join(tmp, "repo-link")
            os.symlink(_REPO_ROOT, link)
            with self.assertRaises(capture.CaptureError):
                capture.assert_outside_repository(os.path.join(link, "captures"))

    def test_existing_outdir_must_be_owner_only(self):
        with tempfile.TemporaryDirectory() as tmp:
            out_dir = os.path.join(tmp, "session")
            os.mkdir(out_dir, 0o755)
            os.chmod(out_dir, 0o755)
            with self.assertRaises(capture.CaptureError):
                capture._ensure_controlled_directory(out_dir)

    def test_symlinked_outdir_is_refused_even_outside_repo(self):
        with tempfile.TemporaryDirectory() as tmp:
            real = os.path.join(tmp, "real")
            os.mkdir(real, 0o700)
            link = os.path.join(tmp, "link")
            os.symlink(real, link)
            with self.assertRaises(capture.CaptureError):
                capture._ensure_controlled_directory(link)


class FakeRunnerMatrixTests(unittest.TestCase):
    def _capture(self, spec, result):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        out_dir = os.path.join(tmp.name, "session")
        hdc = _fake_hdc(tmp.name)
        if capture.CONNECT_KEY in spec.placeholders:
            _seed_hp(tmp.name, out_dir, hdc)
        runner, calls = _fake_runner(result)
        manifest = capture.capture_command(
            hdc_path=hdc,
            out_dir=out_dir,
            spec=spec,
            runner=runner,
            home=tmp.name,
            **_arguments_for(spec, tmp.name, out_dir),
        )
        return manifest, out_dir, calls

    def test_every_command_id_positive_fake_path(self):
        for spec in capture.COMMAND_SPECS:
            with self.subTest(spec=spec.ident):
                manifest, _out_dir, calls = self._capture(
                    spec, _result(out=b"stdout", err=b"stderr")
                )
                self.assertEqual(manifest["commandId"], spec.ident)
                self.assertTrue(manifest["captureComplete"])
                self.assertTrue(manifest["selfCheckPassed"])
                self.assertEqual(len(calls), 1)
                self.assertEqual(calls[0][1], capture.DEFAULT_TIMEOUT_SECONDS)

    def test_every_command_id_negative_timeout_path(self):
        for spec in capture.COMMAND_SPECS:
            with self.subTest(spec=spec.ident):
                manifest, _out_dir, _calls = self._capture(
                    spec, _result(exit_code=None, timed_out=True)
                )
                self.assertTrue(manifest["timedOut"])
                self.assertIsNone(manifest["exitCode"])
                self.assertFalse(manifest["captureComplete"])

    def test_runner_receives_only_registered_argv(self):
        spec = capture.SPECS_BY_ID["R2"]
        _manifest, _out_dir, calls = self._capture(spec, _result())
        self.assertEqual(
            calls[0][0][1:],
            [
                "-t", "SERIAL123", "shell", "hidumper", "-s",
                "WindowManagerService", "-a", "-w 123 -element -c",
            ],
        )

    def test_runner_oserror_becomes_harness_error(self):
        def failing_runner(_argv, _timeout):
            raise OSError(8, "Exec format error")

        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(capture.CaptureError):
                capture.capture_command(
                    hdc_path=_fake_hdc(tmp),
                    out_dir=os.path.join(tmp, "session"),
                    spec=capture.SPECS_BY_ID["HP-0"],
                    runner=failing_runner,
                    home=tmp,
                )


class StreamAndManifestTests(unittest.TestCase):
    def test_separate_stream_bytes_hashes_modes_and_summary(self):
        with tempfile.TemporaryDirectory() as tmp:
            runner, _ = _fake_runner(_result(exit_code=7, out=b"out\x00bytes", err=b"err"))
            out_dir = os.path.join(tmp, "session")
            manifest = capture.capture_command(
                hdc_path=_fake_hdc(tmp),
                out_dir=out_dir,
                spec=capture.SPECS_BY_ID["HP-0"],
                runner=runner,
                home=tmp,
            )
            stdout = manifest["streams"]["stdout"]
            stderr = manifest["streams"]["stderr"]
            self.assertNotEqual(stdout["file"], stderr["file"])
            self.assertEqual(stdout["sha256"], hashlib.sha256(b"out\x00bytes").hexdigest())
            with open(os.path.join(out_dir, stdout["file"]), "rb") as handle:
                self.assertEqual(handle.read(), b"out\x00bytes")
            for name in (stdout["file"], stderr["file"]):
                mode = stat.S_IMODE(os.stat(os.path.join(out_dir, name)).st_mode)
                self.assertEqual(mode & 0o077, 0)
            summary = _read(os.path.join(out_dir, "capture-hashes.md"))
            self.assertIn(stdout["sha256"], summary)
            self.assertIn(stderr["sha256"], summary)
            self.assertFalse(stdout["drainIncomplete"])
            self.assertEqual(stdout["sha256Scope"], "wholeStream")
            self.assertEqual(manifest["exitCode"], 7)
            self.assertTrue(manifest["captureComplete"])

    def test_truncated_stream_records_whole_and_retained_hashes_and_fails_scan(self):
        whole = b"xy"
        truncated = _stream(
            b"x", truncated=True, total_bytes=len(whole), whole_bytes=whole
        )
        with tempfile.TemporaryDirectory() as tmp:
            runner, _ = _fake_runner(_result(stdout=truncated))
            out_dir = os.path.join(tmp, "session")
            manifest = capture.capture_command(
                hdc_path=_fake_hdc(tmp),
                out_dir=out_dir,
                spec=capture.SPECS_BY_ID["HP-0"],
                runner=runner,
                home=tmp,
            )
            record = manifest["streams"]["stdout"]
            self.assertEqual(record["sha256"], hashlib.sha256(whole).hexdigest())
            self.assertEqual(record["retainedSha256"], hashlib.sha256(b"x").hexdigest())
            self.assertTrue(record["truncated"])
            self.assertFalse(manifest["captureComplete"])
            self.assertFalse(manifest["selfCheckPassed"])

    def test_drain_incomplete_is_explicit_and_fails_capture_and_scan(self):
        incomplete = _stream(b"observed", drain_incomplete=True)
        with tempfile.TemporaryDirectory() as tmp:
            runner, _ = _fake_runner(_result(stdout=incomplete))
            out_dir = os.path.join(tmp, "session")
            manifest = capture.capture_command(
                hdc_path=_fake_hdc(tmp),
                out_dir=out_dir,
                spec=capture.SPECS_BY_ID["HP-0"],
                runner=runner,
                home=tmp,
            )
            record = manifest["streams"]["stdout"]
            self.assertTrue(record["drainIncomplete"])
            self.assertEqual(record["sha256Scope"], "observedBeforeDrainCutoff")
            self.assertFalse(record["truncated"])
            self.assertFalse(manifest["captureComplete"])
            self.assertFalse(manifest["selfCheckPassed"])
            summary = _read(os.path.join(out_dir, "capture-hashes.md"))
            self.assertIn("observedBeforeDrainCutoff", summary)
            self.assertIn("`true`", summary)

    def test_inconsistent_fake_stream_metadata_is_rejected(self):
        bad = capture.CapturedStream(
            data=b"x",
            total_bytes=1,
            sha256="0" * 64,
            truncated=False,
        )
        with tempfile.TemporaryDirectory() as tmp:
            runner, _ = _fake_runner(_result(stdout=bad))
            with self.assertRaises(capture.CaptureError):
                capture.capture_command(
                    hdc_path=_fake_hdc(tmp),
                    out_dir=os.path.join(tmp, "session"),
                    spec=capture.SPECS_BY_ID["HP-0"],
                    runner=runner,
                    home=tmp,
                )

    def test_sc2_sidecar_is_separate_hashed_origin(self):
        with tempfile.TemporaryDirectory() as tmp:
            out_dir = os.path.join(tmp, "session")
            hdc = _fake_hdc(tmp)
            _seed_hp(tmp, out_dir, hdc)
            destination = os.path.join(out_dir, "01-SC-2.sidecar")

            def runner(_argv, _timeout):
                with open(destination, "wb") as handle:
                    handle.write(b"sidecar-bytes")
                return _result(out=b"recv complete")

            manifest = capture.capture_command(
                hdc_path=hdc,
                out_dir=out_dir,
                spec=capture.SPECS_BY_ID["SC-2"],
                connect_key="SERIAL123",
                local_sidecar_dest=destination,
                runner=runner,
                home=tmp,
            )
            sidecar = manifest["streams"]["sidecar"]
            self.assertEqual(sidecar["file"], "01-SC-2.sidecar")
            self.assertEqual(sidecar["origin"], "remoteSidecar")
            self.assertEqual(sidecar["sha256"], hashlib.sha256(b"sidecar-bytes").hexdigest())
            self.assertFalse(sidecar["possiblyPartial"])
            sidecar_check = manifest["selfCheck"]["sidecar"]
            self.assertTrue(sidecar_check["completeStreamScanned"])
            self.assertTrue(sidecar_check["passed"])
            self.assertTrue(manifest["selfCheckPassed"])
            summary = _read(os.path.join(out_dir, "capture-hashes.md"))
            self.assertIn("01-SC-2.sidecar", summary)
            self.assertIn(sidecar["sha256"], summary)

    def test_sc2_sidecar_sensitive_bytes_fail_the_self_check(self):
        with tempfile.TemporaryDirectory() as tmp:
            out_dir = os.path.join(tmp, "session")
            hdc = _fake_hdc(tmp)
            _seed_hp(tmp, out_dir, hdc)
            destination = os.path.join(out_dir, "01-SC-2.sidecar")

            def runner(_argv, _timeout):
                with open(destination, "wb") as handle:
                    handle.write(b"dump with -----BEGIN PRIVATE KEY----- inside")
                return _result(out=b"recv complete")

            manifest = capture.capture_command(
                hdc_path=hdc,
                out_dir=out_dir,
                spec=capture.SPECS_BY_ID["SC-2"],
                connect_key="SERIAL123",
                local_sidecar_dest=destination,
                runner=runner,
                home=tmp,
            )
            sidecar_check = manifest["selfCheck"]["sidecar"]
            self.assertTrue(sidecar_check["keyMaterialFound"])
            self.assertFalse(sidecar_check["passed"])
            self.assertFalse(manifest["selfCheckPassed"])
            self.assertTrue(manifest["captureComplete"])

    def test_exclusive_create_refuses_collision(self):
        with tempfile.TemporaryDirectory() as tmp:
            out_dir = os.path.join(tmp, "session")
            os.mkdir(out_dir, 0o700)
            path = os.path.join(out_dir, "00-HP-0.stdout")
            with open(path, "wb") as handle:
                handle.write(b"existing")
            runner, _ = _fake_runner(_result(out=b"new"))
            with unittest.mock.patch.object(capture, "_next_sequence", lambda _path: 0):
                with self.assertRaises(capture.CaptureError):
                    capture.capture_command(
                        hdc_path=_fake_hdc(tmp),
                        out_dir=out_dir,
                        spec=capture.SPECS_BY_ID["HP-0"],
                        runner=runner,
                        home=tmp,
                    )
            with open(path, "rb") as handle:
                self.assertEqual(handle.read(), b"existing")

    def test_manifest_is_per_command_and_deterministically_serialized(self):
        with tempfile.TemporaryDirectory() as tmp:
            runner, _ = _fake_runner(_result())
            out_dir = os.path.join(tmp, "session")
            manifest = capture.capture_command(
                hdc_path=_fake_hdc(tmp),
                out_dir=out_dir,
                spec=capture.SPECS_BY_ID["HP-0"],
                runner=runner,
                home=tmp,
            )
            redacted_path = os.path.join(out_dir, "00-HP-0.redacted-manifest.json")
            with open(redacted_path, "rb") as handle:
                redacted_bytes = handle.read()
            redacted = json.loads(redacted_bytes)
            self.assertEqual(redacted["schema"], capture.REDACTED_SCHEMA)
            self.assertEqual(redacted_bytes, capture._json_bytes(redacted))
            self.assertEqual(manifest["evidenceClass"], "controlledHumanCapture")

    def test_hash_summary_wraps_missing_sequence_as_capture_error(self):
        with tempfile.TemporaryDirectory() as tmp:
            stray = os.path.join(tmp, "99-HP-0.redacted-manifest.json")
            with open(stray, "wb") as handle:
                handle.write(capture._json_bytes({"schema": capture.REDACTED_SCHEMA}))
            with self.assertRaisesRegex(capture.CaptureError, "missing sequence"):
                capture._capture_hashes_bytes(tmp)


class ExactLocalHapEchoPolicyTests(unittest.TestCase):
    def _capture_fx1(self, tmp, hap_path, result):
        out_dir = os.path.join(tmp, "session")
        hdc = _fake_hdc(tmp)
        _seed_hp(tmp, out_dir, hdc)
        runner, _ = _fake_runner(result)
        manifest = capture.capture_command(
            hdc_path=hdc,
            out_dir=out_dir,
            spec=capture.SPECS_BY_ID["FX-1"],
            connect_key="SERIAL123",
            local_hap_path=hap_path,
            runner=runner,
            home=tmp,
        )
        return manifest, out_dir

    def _new_hap(self, tmp, name="entry-default-signed.hap"):
        path = os.path.join(tmp, name)
        with open(path, "wb") as handle:
            handle.write(b"synthetic fixture")
        return path

    def test_exact_user_path_spans_are_the_only_allowed_user_path_matches(self):
        path = "/Users/alice/fixtures/entry-default-signed.hap"
        payload = f"installing {path}\ninstalled {path}\n".encode()
        result = capture._stream_self_check(
            payload,
            None,
            (path,),
            spec=capture.SPECS_BY_ID["FX-1"],
            stream_name="stdout",
            complete=True,
            timed_out=False,
            expected_local_hap_path=path,
        )
        self.assertEqual(result["policyId"], capture.FX1_LOCAL_HAP_ECHO_POLICY)
        self.assertTrue(result["userPathFound"])
        self.assertTrue(result["localInputPathFound"])
        self.assertTrue(result["expectedLocalInputEchoFound"])
        self.assertFalse(result["unexpectedUserPathFound"])
        self.assertFalse(result["unexpectedLocalInputPathFound"])
        self.assertTrue(result["passed"])

    def test_fx1_stdout_exact_echo_passes_and_redacted_bytes_are_deterministic(self):
        with tempfile.TemporaryDirectory() as tmp:
            hap = self._new_hap(tmp)
            resolved = os.path.realpath(hap)
            payload = f"installing {resolved}\ninstalled {resolved}\n".encode()
            manifest, out_dir = self._capture_fx1(tmp, hap, _result(out=payload))
            check = manifest["selfCheck"]["stdout"]
            self.assertEqual(manifest["schema"], "arkdeck-ud-capture-manifest-1.1.0")
            self.assertEqual(check["policyId"], capture.FX1_LOCAL_HAP_ECHO_POLICY)
            self.assertTrue(check["expectedLocalInputEchoFound"])
            self.assertFalse(check["unexpectedUserPathFound"])
            self.assertFalse(check["unexpectedLocalInputPathFound"])
            self.assertTrue(manifest["selfCheckPassed"])
            redacted_path = os.path.join(
                out_dir, "01-FX-1.redacted-manifest.json"
            )
            with open(redacted_path, "rb") as handle:
                redacted_bytes = handle.read()
            redacted = json.loads(redacted_bytes)
            self.assertEqual(
                redacted["schema"], "arkdeck-ud-capture-redacted-1.1.0"
            )
            self.assertEqual(redacted_bytes, capture._json_bytes(redacted))
            self.assertNotIn(resolved.encode(), redacted_bytes)
            self.assertIn(b"<local-hap-path>", redacted_bytes)

    def test_fx1_exact_echo_plus_second_user_path_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            hap = self._new_hap(tmp)
            payload = os.path.realpath(hap).encode() + b"\n/Users/mallory/secret\n"
            manifest, _ = self._capture_fx1(tmp, hap, _result(out=payload))
            check = manifest["selfCheck"]["stdout"]
            self.assertTrue(check["expectedLocalInputEchoFound"])
            self.assertTrue(check["unexpectedUserPathFound"])
            self.assertFalse(check["passed"])

    def test_fx1_path_variants_never_match_the_allowance(self):
        variants = {
            "dirname": lambda path: os.path.dirname(path),
            "prefix": lambda path: path.removesuffix(".hap"),
            "sibling": lambda path: os.path.join(os.path.dirname(path), "other.hap"),
            "suffix": lambda path: path + ".backup",
            "case": lambda path: path.swapcase(),
            "unicode": lambda path: unicodedata.normalize("NFD", path),
        }
        for name, variant in variants.items():
            with self.subTest(variant=name), tempfile.TemporaryDirectory() as tmp:
                hap = self._new_hap(tmp, "café.hap")
                payload = (variant(os.path.realpath(hap)) + "\n").encode("utf-8")
                manifest, _ = self._capture_fx1(tmp, hap, _result(out=payload))
                check = manifest["selfCheck"]["stdout"]
                self.assertFalse(check["expectedLocalInputEchoFound"])
                self.assertTrue(check["unexpectedLocalInputPathFound"])
                self.assertFalse(check["passed"])

    @unittest.skipUnless(hasattr(os, "symlink"), "symlink support required")
    def test_supplied_symlink_alias_is_sensitive_but_never_allowed(self):
        with tempfile.TemporaryDirectory() as tmp:
            real_hap = self._new_hap(tmp, "real.hap")
            alias = os.path.join(tmp, "alias.hap")
            os.symlink(real_hap, alias)
            manifest, _ = self._capture_fx1(
                tmp, alias, _result(out=(alias + "\n").encode())
            )
            check = manifest["selfCheck"]["stdout"]
            self.assertTrue(check["localInputPathFound"])
            self.assertFalse(check["expectedLocalInputEchoFound"])
            self.assertTrue(check["unexpectedLocalInputPathFound"])
            self.assertFalse(check["passed"])

    def test_fx1_stderr_echo_uses_strict_policy_and_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            hap = self._new_hap(tmp)
            manifest, _ = self._capture_fx1(
                tmp, hap, _result(out=b"install complete\n", err=hap.encode())
            )
            check = manifest["selfCheck"]["stderr"]
            self.assertEqual(check["policyId"], capture.STRICT_SELF_CHECK_POLICY)
            self.assertTrue(check["unexpectedLocalInputPathFound"])
            self.assertFalse(check["passed"])

    def test_non_fx1_identity_cannot_select_the_echo_policy(self):
        path = "/Users/alice/fixture.hap"
        result = capture._stream_self_check(
            path.encode(),
            None,
            (path,),
            spec=capture.SPECS_BY_ID["HP-0"],
            stream_name="stdout",
            complete=True,
            timed_out=False,
            expected_local_hap_path=path,
        )
        self.assertEqual(result["policyId"], capture.STRICT_SELF_CHECK_POLICY)
        self.assertTrue(result["unexpectedUserPathFound"])
        self.assertFalse(result["passed"])

    def test_key_material_still_fails_beside_an_exact_echo(self):
        with tempfile.TemporaryDirectory() as tmp:
            hap = self._new_hap(tmp)
            payload = os.path.realpath(hap).encode() + b"\n-----BEGIN PRIVATE KEY-----\n"
            manifest, _ = self._capture_fx1(tmp, hap, _result(out=payload))
            check = manifest["selfCheck"]["stdout"]
            self.assertTrue(check["expectedLocalInputEchoFound"])
            self.assertTrue(check["keyMaterialFound"])
            self.assertFalse(check["passed"])

    def test_truncation_drain_and_timeout_disable_the_echo_policy(self):
        for condition in ("truncated", "drain", "timeout"):
            with self.subTest(condition=condition), tempfile.TemporaryDirectory() as tmp:
                hap = self._new_hap(tmp)
                payload = hap.encode()
                if condition == "truncated":
                    stream = _stream(
                        payload,
                        truncated=True,
                        total_bytes=len(payload) + 1,
                        whole_bytes=payload + b"x",
                    )
                    result = _result(stdout=stream)
                elif condition == "drain":
                    result = _result(stdout=_stream(payload, drain_incomplete=True))
                else:
                    result = _result(out=payload, timed_out=True, exit_code=None)
                manifest, _ = self._capture_fx1(tmp, hap, result)
                check = manifest["selfCheck"]["stdout"]
                self.assertEqual(check["policyId"], capture.STRICT_SELF_CHECK_POLICY)
                self.assertFalse(check["expectedLocalInputEchoFound"])
                self.assertFalse(check["passed"])
                self.assertFalse(manifest["captureComplete"])

    def test_fx1_echo_does_not_weaken_repository_redaction_gate(self):
        with tempfile.TemporaryDirectory() as tmp:
            hap = self._new_hap(tmp)
            out_dir = os.path.join(tmp, "session")
            hdc = _fake_hdc(tmp)
            _seed_hp(tmp, out_dir, hdc)
            runner, _ = _fake_runner(_result(out=os.path.realpath(hap).encode()))

            def broken(manifest, _prepared, _argv, _home):
                redacted = dict(manifest)
                redacted["schema"] = capture.REDACTED_SCHEMA
                return redacted

            with unittest.mock.patch.object(capture, "_redacted_manifest", broken):
                with self.assertRaises(capture.StopRequired):
                    capture.capture_command(
                        hdc_path=hdc,
                        out_dir=out_dir,
                        spec=capture.SPECS_BY_ID["FX-1"],
                        connect_key="SERIAL123",
                        local_hap_path=hap,
                        runner=runner,
                        home=tmp,
                    )
            self.assertTrue(os.path.exists(os.path.join(out_dir, "01-FX-1.manifest.json")))
            self.assertFalse(
                os.path.exists(os.path.join(out_dir, "01-FX-1.redacted-manifest.json"))
            )

    def test_schema_and_policy_documentation_match_runbook(self):
        readme = _read(os.path.join(_MODULE_DIR, "README.md"))
        runbook = _read(_RUNBOOK)
        for value in (capture.MANIFEST_SCHEMA, capture.REDACTED_SCHEMA):
            self.assertIn(value, readme)
        self.assertIn(capture.REDACTED_SCHEMA, runbook)
        self.assertIn(capture.FX1_LOCAL_HAP_ECHO_POLICY, readme)
        self.assertIn("_assert_redacted_clean", readme)
        self.assertIn("_assert_redacted_clean", runbook)


class SensitiveBoundaryTests(unittest.TestCase):
    def test_stream_user_path_key_and_local_path_fail_closed(self):
        for payload, local_paths in (
            (b"/Users/alice/secret", ()),
            (b"-----BEGIN PRIVATE KEY-----", ()),
            (b"failed /private/tmp/fixture.hap", ("/private/tmp/fixture.hap",)),
        ):
            with self.subTest(payload=payload):
                result = capture.self_check(payload, None, local_paths)
                self.assertFalse(result["passed"])

    def test_connect_key_in_controlled_raw_is_recorded_but_not_failed(self):
        result = capture.self_check(b"SERIAL123\tConnected", "SERIAL123")
        self.assertTrue(result["serialPresent"])
        self.assertTrue(result["passed"])

    def test_redacted_recipe_manifest_masks_home_target_and_window(self):
        with tempfile.TemporaryDirectory() as tmp:
            out_dir = os.path.join(tmp, "session")
            hdc = _fake_hdc(tmp)
            _seed_hp(tmp, out_dir, hdc)
            runner, _ = _fake_runner(_result())
            capture.capture_command(
                hdc_path=hdc,
                out_dir=out_dir,
                spec=capture.SPECS_BY_ID["R1"],
                connect_key="SERIAL123",
                window_id="9876",
                runner=runner,
                home=tmp,
            )
            text = _read(os.path.join(out_dir, "01-R1.redacted-manifest.json"))
            self.assertNotIn(tmp, text)
            self.assertNotIn("SERIAL123", text)
            self.assertNotIn("-w 9876", text)
            self.assertIn("<connectkey>", text)
            self.assertIn("<window-id>", text)

    def test_redacted_hap_manifest_masks_path_but_keeps_hash(self):
        with tempfile.TemporaryDirectory() as tmp:
            out_dir = os.path.join(tmp, "session")
            hdc = _fake_hdc(tmp)
            _seed_hp(tmp, out_dir, hdc)
            hap = os.path.join(tmp, "entry-default-signed.hap")
            content = b"synthetic fixture"
            with open(hap, "wb") as handle:
                handle.write(content)
            runner, _ = _fake_runner(_result())
            capture.capture_command(
                hdc_path=hdc,
                out_dir=out_dir,
                spec=capture.SPECS_BY_ID["FX-1"],
                connect_key="SERIAL123",
                local_hap_path=hap,
                runner=runner,
                home=tmp,
            )
            text = _read(os.path.join(out_dir, "01-FX-1.redacted-manifest.json"))
            self.assertNotIn(hap, text)
            self.assertIn("<local-hap-path>", text)
            self.assertIn(hashlib.sha256(content).hexdigest(), text)

    def test_broken_redaction_withholds_repo_facing_outputs(self):
        with tempfile.TemporaryDirectory() as tmp:
            out_dir = os.path.join(tmp, "session")
            hdc = _fake_hdc(tmp)
            _seed_hp(tmp, out_dir, hdc)
            runner, _ = _fake_runner(_result())

            def broken(manifest, _prepared, _argv, _home):
                redacted = dict(manifest)
                redacted["schema"] = capture.REDACTED_SCHEMA
                return redacted

            with unittest.mock.patch.object(capture, "_redacted_manifest", broken):
                with self.assertRaises(capture.StopRequired):
                    capture.capture_command(
                        hdc_path=hdc,
                        out_dir=out_dir,
                        spec=capture.SPECS_BY_ID["R1"],
                        connect_key="SERIAL123",
                        window_id="9876",
                        runner=runner,
                        home=tmp,
                    )
            self.assertTrue(os.path.exists(os.path.join(out_dir, "01-R1.manifest.json")))
            self.assertFalse(
                os.path.exists(os.path.join(out_dir, "01-R1.redacted-manifest.json"))
            )


class SubprocessRunnerTests(unittest.TestCase):
    def test_records_verbatim_exit_streams_and_whole_hash(self):
        result = capture.subprocess_runner(
            [
                sys.executable,
                "-c",
                "import sys;sys.stdout.buffer.write(b'out');"
                "sys.stderr.buffer.write(b'err');sys.exit(3)",
            ],
            10,
        )
        self.assertEqual(result.exit_code, 3)
        self.assertFalse(result.timed_out)
        self.assertEqual(result.stdout.data, b"out")
        self.assertEqual(result.stderr.data, b"err")
        self.assertEqual(result.stdout.sha256, hashlib.sha256(b"out").hexdigest())
        self.assertFalse(result.stdout.drain_incomplete)
        self.assertFalse(result.stderr.drain_incomplete)

    def test_signal_death_is_not_timeout(self):
        result = capture.subprocess_runner(
            [sys.executable, "-c", "import os,signal;os.kill(os.getpid(),signal.SIGHUP)"],
            10,
        )
        self.assertEqual(result.exit_code, -signal.SIGHUP)
        self.assertFalse(result.timed_out)

    def test_timeout_is_separate_null_exit_channel(self):
        result = capture.subprocess_runner(
            [sys.executable, "-c", "import time;time.sleep(30)"], 1
        )
        self.assertTrue(result.timed_out)
        self.assertIsNone(result.exit_code)

    def test_retained_cap_and_whole_stream_hash(self):
        count = capture.MAX_STREAM_BYTES + 1
        script = f"import sys;sys.stdout.buffer.write(b'x'*{count})"
        result = capture.subprocess_runner([sys.executable, "-c", script], 30)
        self.assertEqual(len(result.stdout.data), capture.MAX_STREAM_BYTES)
        self.assertEqual(result.stdout.total_bytes, count)
        self.assertTrue(result.stdout.truncated)
        self.assertEqual(
            result.stdout.sha256, hashlib.sha256(b"x" * count).hexdigest()
        )

    @unittest.skipUnless(hasattr(os, "fork"), "fork required for inherited-pipe test")
    def test_daemonized_child_does_not_stall(self):
        script = (
            "import os,sys\n"
            "if os.fork()==0:\n"
            " import time;time.sleep(30);os._exit(0)\n"
            "sys.stdout.write('client-done');sys.stdout.flush()\n"
        )
        started = time.monotonic()
        result = capture.subprocess_runner([sys.executable, "-c", script], 20)
        elapsed = time.monotonic() - started
        self.assertEqual(result.exit_code, 0)
        self.assertIn(b"client-done", result.stdout.data)
        self.assertTrue(result.stdout.drain_incomplete)
        self.assertTrue(result.stderr.drain_incomplete)
        self.assertLess(elapsed, 10)


class StaticSafetyTests(unittest.TestCase):
    def test_ast_has_no_shell_execution_or_network_imports(self):
        tree = ast.parse(_read(os.path.join(_MODULE_DIR, "capture.py")))
        banned_imports = {"socket", "urllib", "http", "ftplib", "requests", "asyncio"}
        banned_os_calls = {
            "system", "popen", "spawnl", "spawnle", "spawnlp", "spawnlpe",
            "spawnv", "spawnve", "spawnvp", "spawnvpe",
        }
        for node in ast.walk(tree):
            if isinstance(node, ast.Import):
                for alias in node.names:
                    self.assertNotIn(alias.name.split(".")[0], banned_imports)
            elif isinstance(node, ast.ImportFrom):
                self.assertNotIn((node.module or "").split(".")[0], banned_imports)
            elif isinstance(node, ast.Call):
                for keyword in node.keywords:
                    self.assertNotEqual(keyword.arg, "shell")
                if (
                    isinstance(node.func, ast.Attribute)
                    and isinstance(node.func.value, ast.Name)
                    and node.func.value.id == "os"
                ):
                    self.assertNotIn(node.func.attr, banned_os_calls)

    def test_only_subprocess_popen_is_used_for_process_execution(self):
        tree = ast.parse(_read(os.path.join(_MODULE_DIR, "capture.py")))
        subprocess_calls = []
        for node in ast.walk(tree):
            if (
                isinstance(node, ast.Call)
                and isinstance(node.func, ast.Attribute)
                and isinstance(node.func.value, ast.Name)
                and node.func.value.id == "subprocess"
            ):
                subprocess_calls.append(node.func.attr)
        self.assertEqual(subprocess_calls, ["Popen"])


class CliAndSerializerTests(unittest.TestCase):
    def test_cli_distinguishes_post_dispatch_stop_from_harness_refusal(self):
        argv = ["--hdc", "/x", "--out-dir", "/y", "--command", "HP-0"]
        with unittest.mock.patch.object(
            capture, "capture_command", side_effect=capture.StopRequired("redaction leak")
        ):
            stderr = io.StringIO()
            with contextlib.redirect_stderr(stderr):
                self.assertEqual(capture.main(argv), 1)
            self.assertIn("capture stop required", stderr.getvalue())
        with unittest.mock.patch.object(
            capture, "capture_command", side_effect=capture.CaptureError("bad input")
        ):
            with contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(capture.main(argv), 2)

    def test_cli_default_timeout_is_120_and_nonpositive_is_rejected(self):
        parser = capture.build_arg_parser()
        args = parser.parse_args(
            ["--hdc", "/x", "--out-dir", "/y", "--command", "HP-0"]
        )
        self.assertEqual(args.timeout, 120)
        for bad in ("0", "-1", "abc"):
            with self.subTest(value=bad):
                with self.assertRaises(SystemExit):
                    with contextlib.redirect_stderr(io.StringIO()):
                        parser.parse_args(
                            [
                                "--hdc", "/x", "--out-dir", "/y", "--command", "HP-0",
                                "--timeout", bad,
                            ]
                        )

    def test_json_bytes_matches_archive_characterization_serializer(self):
        path = os.path.join(_REPO_ROOT, "scripts", "archive_characterization", "scan.py")
        module_spec = importlib.util.spec_from_file_location("_ud_scan_parity", path)
        scan = importlib.util.module_from_spec(module_spec)
        sys.modules[module_spec.name] = scan
        try:
            module_spec.loader.exec_module(scan)
            sample = {"b": [1, 2], "a": "文", "nested": {"y": None, "x": True}}
            self.assertEqual(capture._json_bytes(sample), scan._serialize(sample))
        finally:
            del sys.modules[module_spec.name]


if __name__ == "__main__":
    unittest.main()
