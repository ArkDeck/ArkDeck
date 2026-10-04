#!/usr/bin/env python3
"""Host-only regression tests for the SPK-8 negative harness.

No Mach service, launchd, installed Runtime, signing identity or device is
touched: installed reads are mocked and the App is a recorded stand-in script.
"""
import importlib.util
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    "installed_spk8_negatives", Path(__file__).with_name("installed_spk8_negatives.py"))
subject = importlib.util.module_from_spec(spec)
spec.loader.exec_module(subject)

MISMATCH = ("ArkDeck Runtime is not reachable: Runtime release does not match this App (requires "
            "ArkDeck Runtime 0.1.0 build 2 signed by the ArkDeck team); run runtime service update")
IDENTITY = {"pid": 321, "version": "0.1.0", "build": "2", "daemonSHA256": "a" * 64}
SERVICE = {"pid": 654, "executable": "/x/ArkDeckAgent.app/Contents/MacOS/arkdeck-facade",
           "bundle": "/x/ArkDeckAgent.app", "version": "0.1.0", "build": "1", "executableSHA256": "b" * 64}


def report(connected=False, reason=MISMATCH):
    record = {"schemaVersion": "arkdeck.app-readonly-smoke/1", "connected": connected,
              "historyAvailable": connected, "filterAvailable": connected, "jobCount": 0,
              "hardwareAcceptance": False}
    if reason:
        record["unavailableReason"] = reason
    return record


def completed(returncode=0, stdout=b"", stderr=b""):
    return subprocess.CompletedProcess([], returncode, stdout, stderr)


class SwitchAndEvidenceTests(unittest.TestCase):
    def test_each_installed_case_skips_without_its_switch_and_touches_nothing(self):
        with tempfile.TemporaryDirectory() as root:
            for case in ("foreign-client", "version-mismatch"):
                target = Path(root) / case
                environment = {k: v for k, v in os.environ.items() if not k.startswith("ARKDECK_SPK8_")}
                with patch.dict(os.environ, environment, clear=True), \
                        patch.object(subject, "run") as run, patch.object(subject.ui, "run") as ui_run:
                    self.assertEqual(subject.main([case, str(target)]), subject.SKIPPED)
                    run.assert_not_called()
                    ui_run.assert_not_called()
                self.assertFalse(target.exists())

    def test_evidence_must_be_new_absolute_and_outside_installed_state(self):
        with tempfile.TemporaryDirectory() as root:
            home = Path(root)
            installed = home / "Library/Application Support/ArkDeck"
            installed.mkdir(parents=True)
            with patch.object(subject.Path, "home", return_value=home):
                for text in ("relative/evidence", str(installed / "spk8")):
                    with self.assertRaises(RuntimeError):
                        subject.evidence_directory(text)
                created = subject.evidence_directory(str(home / "spk8"))
                self.assertEqual(stat.S_IMODE(created.stat().st_mode), 0o700)
                with self.assertRaises(FileExistsError):
                    subject.evidence_directory(str(created))

    def test_release_requirement_pins_version_and_build(self):
        self.assertTrue(subject.release_requirement("X", "0.1.0", "2").endswith(
            'info[CFBundleShortVersionString] = "0.1.0" and info[CFBundleVersion] = "2"'))
        for version, build in (("0.1.0", ""), ('0.1"', "1"), ("0.1.0", "1 or true")):
            with self.assertRaises(RuntimeError):
                subject.release_requirement("X", version, build)


class ForeignClientTests(unittest.TestCase):
    SELF_TEST = {"schemaVersion": "arkdeck.spk8-foreign-client/1",
                 "refusing": {"outcome": "refused", "handlerEntries": 0},
                 "control": {"outcome": "answered", "handlerEntries": 1}}

    def test_self_test_must_show_refusal_and_a_detected_dispatch(self):
        subject.judge_self_test(self.SELF_TEST)
        for broken in ({**self.SELF_TEST, "refusing": {"outcome": "refused", "handlerEntries": 1}},
                       {**self.SELF_TEST, "refusing": {"outcome": "answered", "handlerEntries": 0}},
                       {**self.SELF_TEST, "control": {"outcome": "refused", "handlerEntries": 0}}):
            with self.assertRaises(RuntimeError):
                subject.judge_self_test(broken)

    def test_only_a_bounded_cut_off_without_frame_passes(self):
        refused = {"outcome": "refused", "replyError": "connectionInterrupted", "elapsedMs": 2.0}
        self.assertEqual(subject.judge_foreign(refused, IDENTITY, IDENTITY)[0], "PASS")
        cases = (({"outcome": "answered", "replyError": None, "elapsedMs": 1.0}, "FAIL"),
                 ({"outcome": "answeredMalformed", "replyError": None, "elapsedMs": 1.0}, "FAIL"),
                 ({"outcome": "serverRequirementUnmet", "replyError": "peerCodeSigningRequirement",
                   "elapsedMs": 1.0}, "BLOCKED"),
                 ({"outcome": "noAnswer", "replyError": None, "elapsedMs": None}, "FAIL"),
                 ({"outcome": "otherError", "replyError": "other", "elapsedMs": 1.0}, "FAIL"))
        for probe, status in cases:
            self.assertEqual(subject.judge_foreign(probe, IDENTITY, IDENTITY)[0], status)
        self.assertEqual(subject.judge_foreign(refused, IDENTITY, {**IDENTITY, "pid": 999})[0], "FAIL")

    def run_case(self, probe, after=IDENTITY):
        environment = {"ARKDECK_INSTALLED_RUST_APP": "/A.app", "ARKDECK_INSTALLED_RUST_CLI": "/cli",
                       "ARKDECK_INSTALLED_RUST_APP_SHA256": "1" * 64,
                       "ARKDECK_INSTALLED_RUST_CLI_SHA256": "2" * 64,
                       "ARKDECK_INSTALLED_RUST_DAEMON_SHA256": "3" * 64}
        with tempfile.TemporaryDirectory() as root, patch.dict(os.environ, environment), \
                patch.object(subject.ui, "inspect", side_effect=[IDENTITY, after]) as inspect, \
                patch.object(subject, "build_client", return_value=(Path(root) / "client", "c" * 64)), \
                patch.object(subject, "client_json", side_effect=[self.SELF_TEST, {"probe": probe}]) as call:
            result = subject.foreign_client(Path(root))
        self.assertEqual(inspect.call_count, 2)
        mode, frame, requirement = call.call_args_list[1].args[1:]
        self.assertEqual(mode, "probe")
        self.assertEqual(json.loads(frame)["method"], "health")
        self.assertIn('identifier "com.arkdeck.agentd"', requirement)
        self.assertIn('info[CFBundleVersion] = "2"', requirement)
        return result

    def test_orchestration_passes_on_refusal_and_fails_on_dispatch_or_restart(self):
        refused = {"outcome": "refused", "replyError": "connectionInvalid", "elapsedMs": 3.0}
        self.assertEqual(self.run_case(refused)["status"], "PASS")
        self.assertEqual(self.run_case({"outcome": "answered", "elapsedMs": 1.0})["status"], "FAIL")
        self.assertEqual(self.run_case(refused, after={**IDENTITY, "pid": 7})["status"], "FAIL")

    def test_client_must_be_ad_hoc_without_team_and_fail_the_app_requirement(self):
        signed = completed(stderr=b"Signature=adhoc\nTeamIdentifier=not set\n")
        teamed = completed(stderr=b"Authority=Developer ID Application\nTeamIdentifier=8AQTYW5FKR\n")
        with tempfile.TemporaryDirectory() as root:
            binary = Path(root) / "spk8-foreign-client"
            binary.write_bytes(b"client")
            for details, verify, ok in ((signed, completed(3), True), (teamed, completed(3), False),
                                        (signed, completed(0), False)):
                with patch.object(subject, "run", side_effect=[completed(), completed(), details, verify]):
                    if ok:
                        self.assertEqual(subject.build_client(Path(root))[0], binary)
                    else:
                        with self.assertRaises(RuntimeError):
                            subject.build_client(Path(root))


class VersionMismatchTests(unittest.TestCase):
    def fixture_app(self, root, body):
        """A recorded stand-in for `ArkDeck --runtime-readonly-smoke`."""
        path = Path(root) / "ArkDeck"
        path.write_text("#!/usr/bin/env python3\nimport json, sys\n" + body)
        path.chmod(0o700)
        return path

    def answering(self, root, record):
        return self.fixture_app(root, (
            "for line in sys.stdin:\n"
            "    assert line == 'refresh\\n' and sys.argv[1:] == ['--runtime-readonly-smoke']\n"
            f"    print('ARKDECK_IPC_SMOKE ' + json.dumps({record!r}), flush=True)\n"))

    def test_recorded_mismatch_report_passes_twice_and_exits(self):
        with tempfile.TemporaryDirectory() as root:
            reports, exited = subject.smoke_app(self.answering(root, report()), budget=10)
        self.assertTrue(exited)
        subject.judge_mismatch(reports, exited)
        self.assertTrue(all(r["elapsedSeconds"] < 10 for r in reports))

    def test_a_hanging_app_is_bounded_and_terminated(self):
        with tempfile.TemporaryDirectory() as root:
            app = self.fixture_app(root, "import time\ntime.sleep(60)\n")
            with self.assertRaisesRegex(RuntimeError, "timed out"):
                subject.smoke_app(app, budget=1)

    def test_accepting_or_unexplained_reports_fail(self):
        for bad in (report(connected=True, reason=None), report(reason=None),
                    report(reason="ArkDeck Runtime is not reachable: Runtime connection interrupted"),
                    report(reason=MISMATCH + " later")):
            with self.assertRaises(RuntimeError):
                subject.judge_mismatch([report(), bad], True)
        with self.assertRaises(RuntimeError):
            subject.judge_mismatch([report()], True)
        with self.assertRaises(RuntimeError):
            subject.judge_mismatch([report(), report()], False)

    def run_case(self, pinned_returncode, reports=None, service=SERVICE, live_error=None):
        info = {"CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "2"}
        environment = {"ARKDECK_SPK8_APP": "/Apps/ArkDeck.app", "ARKDECK_SPK8_APP_SHA256": "d" * 64}
        codesign = [completed(), completed(), completed(pinned_returncode)]
        with patch.dict(os.environ, environment), \
                patch.object(subject.smoke, "inspect_app", return_value=(info, Path("/Apps/ArkDeck"))), \
                patch.object(subject.ui, "pinned_hash"), \
                patch.object(subject, "installed_service", return_value=service), \
                patch.object(subject.ui, "verify_live_code", side_effect=live_error) as live, \
                patch.object(subject, "run", side_effect=codesign) as run, \
                patch.object(subject.ui, "app_processes", return_value=[]), \
                patch.object(subject, "smoke_app", return_value=(reports or [report(), report()], True)) as app:
            result = subject.version_mismatch(Path("/unused"))
        owner = run.call_args_list[1].args
        identity = (subject.LEGACY_FACADE_IDENTITY if service["executable"].endswith("arkdeck-facade")
                    else subject.SERVER_IDENTITY)
        self.assertEqual(owner[3], "=" + subject.release_requirement(identity, service["version"], service["build"]))
        self.assertEqual(owner[4], str(service["pid"]))
        pinned = run.call_args_list[2].args
        self.assertEqual(pinned[3], "=" + subject.release_requirement(identity, "0.1.0", "2"))
        self.assertEqual(pinned[4], str(service["pid"]))
        self.assertEqual(live.call_count, 2 if result["status"] == "PASS" else 1)
        return result, app

    def test_orchestration_requires_an_actual_release_mismatch(self):
        result, app = self.run_case(pinned_returncode=3)
        self.assertEqual(result["status"], "PASS")
        self.assertEqual(result["acceptanceScope"], "pre-cutover-legacy-facade")
        app.assert_called_once()
        result, app = self.run_case(pinned_returncode=0, service={**SERVICE, "build": "2"})
        self.assertEqual(result["status"], "BLOCKED")
        app.assert_not_called()

    def test_standalone_daemon_keeps_its_exact_identity_requirement(self):
        service = {**SERVICE, "executable": "/x/ArkDeckAgent.app/Contents/MacOS/arkdeck-agentd"}
        result, app = self.run_case(pinned_returncode=3, service=service)
        self.assertEqual(result["status"], "PASS")
        self.assertEqual(result["acceptanceScope"], "installed-daemon-release-mismatch")
        app.assert_called_once()

    def test_live_code_drift_and_unrecognized_owners_are_not_mismatches(self):
        with self.assertRaisesRegex(RuntimeError, "code drift"):
            self.run_case(pinned_returncode=3, live_error=RuntimeError("code drift"))
        with self.assertRaisesRegex(RuntimeError, "unrecognized"):
            self.run_case(pinned_returncode=3, service={**SERVICE, "executable": "/x/other"})

    def test_orchestration_fails_when_the_app_connects(self):
        with self.assertRaises(RuntimeError):
            self.run_case(pinned_returncode=3, reports=[report(connected=True, reason=None)] * 2)


if __name__ == "__main__":
    unittest.main()
