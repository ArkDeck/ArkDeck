#!/usr/bin/env python3
"""Safety tests for host harness orchestration; never Mach/hardware evidence."""
import argparse
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import MagicMock, patch

SPEC = importlib.util.spec_from_file_location(
    "smoke", Path(__file__).with_name("macos-app-rust-smoke.py"))
smoke = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(smoke)


class SmokeSafetyTests(unittest.TestCase):
    def test_installed_launch_agent_refuses_before_any_command(self):
        with tempfile.TemporaryDirectory() as root:
            installed = Path(root) / "Library/LaunchAgents/com.arkdeck.agentd.plist"
            installed.parent.mkdir(parents=True)
            installed.write_text("existing installed service")
            with patch.object(smoke.sys, "platform", "darwin"), patch.object(smoke.os, "getuid", return_value=501), patch.object(smoke.Path, "home", return_value=Path(root)), patch.object(smoke, "command") as command:
                with self.assertRaisesRegex(RuntimeError, "installed LaunchAgent"):
                    smoke.require_free_domain()
                command.assert_not_called()
            self.assertEqual(installed.read_text(), "existing installed service")

    def test_service_with_other_label_still_refuses_without_mutation(self):
        with tempfile.TemporaryDirectory() as root:
            reply = subprocess.CompletedProcess([], 0, b"services = { com.arkdeck.agentd => some-other-label }", b"")
            with patch.object(smoke.sys, "platform", "darwin"), patch.object(smoke.os, "getuid", return_value=501), patch.object(smoke.Path, "home", return_value=Path(root)), patch.object(smoke, "command", return_value=reply) as command:
                with self.assertRaisesRegex(RuntimeError, "already registered"):
                    smoke.require_free_domain()
                self.assertEqual(command.call_args.args, ("/bin/launchctl", "print", "gui/501"))

    def exercise_failure(self, bootstrap_fails):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            daemon = root / "daemon"
            daemon.write_bytes(b"not executable: test fixture only")
            app = root / "app"
            app.write_bytes(b"not executable: test fixture only")
            args = argparse.Namespace(output=root / "run", daemon=daemon, sign_identity="test")
            calls = []

            def command(*argv, **kwargs):
                calls.append(argv)
                if bootstrap_fails and argv[:2] == ("/bin/launchctl", "bootstrap"):
                    raise subprocess.CalledProcessError(5, argv)
                return subprocess.CompletedProcess(argv, 0, b"", b"")

            process = MagicMock()
            process.stdin.close.side_effect = BrokenPipeError()
            with patch.object(smoke, "require_free_domain", return_value="gui/501"), patch.object(smoke, "command", side_effect=command), patch.object(smoke.subprocess, "Popen", return_value=process), patch.object(smoke, "next_report", side_effect=[{"connected": False}, RuntimeError("App read failed")]):
                with self.assertRaises((RuntimeError, subprocess.CalledProcessError)):
                    smoke.execute(args, "gui/501", {"CFBundleShortVersionString": "0.1", "CFBundleVersion": "1"}, app)
            bootouts = [call for call in calls if call[:2] == ("/bin/launchctl", "bootout")]
            if bootstrap_fails:
                self.assertEqual(bootouts, [], "failed bootstrap never grants cleanup ownership")
            else:
                self.assertEqual(len(bootouts), 1)
                owned_plist = Path(bootouts[0][3])
                self.assertEqual(owned_plist.parent, (root / "run").resolve())
                self.assertTrue(owned_plist.name.startswith("com.arkdeck.ipc-smoke."))
                self.assertNotEqual(owned_plist.name, "com.arkdeck.agentd.plist")

    def test_app_failure_cleans_only_our_registered_service_even_with_broken_stdin(self):
        self.exercise_failure(bootstrap_fails=False)

    def test_failed_bootstrap_never_boots_out_foreign_service(self):
        self.exercise_failure(bootstrap_fails=True)


if __name__ == "__main__":
    unittest.main()
