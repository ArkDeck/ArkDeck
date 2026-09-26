#!/usr/bin/env python3
"""Exercise the real local helper scripts with recording build/signing tools.

Fixture evidence only: no Keychain, real codesign, notarization or launchd.
The shared layout script is real; its tool dependencies only record calls.
"""
import json
import os
from pathlib import Path
import plistlib
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest

DISTRIBUTION = Path(__file__).resolve().parent
IDENTITY = "Developer ID Application: Fixture (8AQTYW5FKR)"
TEAM = "8AQTYW5FKR"


def tool(name, arguments):
    with open(os.environ["FIXTURE_LOG"], "a") as log:
        log.write(json.dumps([name, *arguments]) + "\n")
    failure = os.environ.get("FIXTURE_FAIL", "")
    if name == "security":
        if arguments == ["find-identity", "-v", "-p", "codesigning"]:
            if failure != "identity":
                print(IDENTITY)
            return 0
        if arguments[:3] == ["cms", "-D", "-i"]:
            sys.stdout.buffer.write(Path(arguments[3]).read_bytes())
            return 0
    elif name == "cargo":
        if arguments[0] == "metadata":
            print(json.dumps({"target_directory": os.environ["CARGO_TARGET_DIR"]}))
            return 0
        if arguments[0] == "build":
            return 17 if failure == "build" else 0
    elif name == "codesign":
        if failure == "sign" and "--force" in arguments:
            return 18
        if failure == "rollback" and arguments[-1] == os.environ["ARKDECK_ROLLBACK_HELPER"]:
            return 19
        return 0
    elif name == "lipo":
        print("x86_64" if failure == "architecture" else "arm64")
        return 0
    elif name == "ditto":
        shutil.copytree(arguments[0], arguments[1])
        return 0
    elif name == "swift":
        # A default invocation must still reach the Swift build, not Cargo.
        return 91
    raise RuntimeError(f"unexpected tool call: {name} {arguments}")


class LocalRustHelpers(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="local-rust-helpers-", dir="/private/tmp")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.bin = self.root / "tools"
        self.bin.mkdir()
        self.tmp = self.root / "tmp"
        self.tmp.mkdir()
        self.log = self.root / "calls.jsonl"
        self.output = self.root / "local output"
        self.target = self.root / "cargo target"
        binaries = self.target / "aarch64-apple-darwin/debug"
        binaries.mkdir(parents=True)
        for name in ["arkdeck", "arkdeck-agentd"]:
            path = binaries / name
            path.write_text(f"fixture Rust {name}\n")
            path.chmod(0o700)
        self.rollback = self.root / "current Swift.app"
        (self.rollback / "Contents/MacOS").mkdir(parents=True)
        shutil.copyfile(DISTRIBUTION / "ArkDeckAgent-Info.plist", self.rollback / "Contents/Info.plist")
        for name in ["arkdeck-agentd", "arkdeck-facade"]:
            path = self.rollback / "Contents/MacOS" / name
            path.write_text(f"fixture rollback {name}\n")
            path.chmod(0o700)
        self.env = {
            "PATH": f"{self.bin}:/usr/bin:/bin",
            "TMPDIR": str(self.tmp),
            "CARGO_TARGET_DIR": str(self.target),
            "FIXTURE_LOG": str(self.log),
            "ARKDECK_CODESIGN_IDENTITY": IDENTITY,
            "ARKDECK_HELPER_RUNTIME": "rust",
            "ARKDECK_ROLLBACK_HELPER": str(self.rollback),
            "ARKDECK_LOCAL_HELPER_OUTPUT": str(self.output),
        }
        for kind in ["cli", "daemon"]:
            identifier = "agentd" if kind == "daemon" else kind
            profile = self.root / f"{kind}.provisionprofile"
            profile.write_bytes(plistlib.dumps({"Entitlements": {
                "com.apple.developer.team-identifier": TEAM,
                "com.apple.application-identifier": f"{TEAM}.com.arkdeck.{identifier}",
                "keychain-access-groups": [f"{TEAM}.com.arkdeck.shared"],
            }}))
            self.env[f"ARKDECK_{kind.upper()}_PROVISIONING_PROFILE"] = str(profile)
        for name in ["security", "cargo", "codesign", "lipo", "ditto", "swift", "xcrun", "spctl", "launchctl"]:
            wrapper = self.bin / name
            wrapper.write_text("#!/bin/sh\nexec " + " ".join(map(shlex.quote, [
                sys.executable, str(Path(__file__).resolve()), "--tool", name,
            ])) + ' "$@"\n')
            wrapper.chmod(0o700)

    def run_build(self, expected):
        result = subprocess.run(
            ["/bin/bash", str(DISTRIBUTION / "build-local-helpers.sh")],
            env=self.env, capture_output=True, text=True, timeout=30,
        )
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        self.assertEqual(list(self.tmp.iterdir()), [], "temporary profile/staging roots leaked")
        if expected:
            self.assertFalse(self.output.exists(), "failed build published a helper")
        self.calls = [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []
        self.assertFalse(any(call[0] in ["xcrun", "spctl", "launchctl"] for call in self.calls))
        return result

    def test_rust_debug_pair_uses_shared_layout_and_keeps_rollback(self):
        result = self.run_build(0)
        cli = self.output / "ArkDeckCLI.app"
        daemon = cli / "Contents/Helpers/ArkDeckAgent.app"
        self.assertEqual(result.stdout.strip(), str(cli))
        self.assertIn("not for distribution", (self.output / "LOCAL-DEVELOPMENT-BUILD.txt").read_text())
        for program, bundle in [("arkdeck", cli), ("arkdeck-agentd", daemon)]:
            self.assertEqual((bundle / f"Contents/MacOS/{program}").read_bytes(),
                             (self.target / f"aarch64-apple-darwin/debug/{program}").read_bytes())
        self.assertFalse((daemon / "Contents/MacOS/arkdeck-facade").exists())
        for path in self.rollback.rglob("*"):
            if path.is_file():
                self.assertEqual(path.read_bytes(), (self.output / "rollback/ArkDeckAgent.app" / path.relative_to(self.rollback)).read_bytes())
        builds = [call for call in self.calls if call[:2] == ["cargo", "build"]]
        self.assertEqual(builds, [["cargo", "build", "--locked", "--target", "aarch64-apple-darwin",
                                  "-p", "arkdeck-cli", "-p", "arkdeck-agentd", "--bins"]])
        signatures = [call for call in self.calls if call[:2] == ["codesign", "--force"]]
        self.assertEqual(len(signatures), 2)
        for call in signatures:
            self.assertIn("--timestamp=none", call)
            self.assertIn(IDENTITY, call)
            self.assertIn("--entitlements", call)
        self.assertFalse(any(call[0] == "swift" for call in self.calls))

    def test_default_still_builds_swift(self):
        del self.env["ARKDECK_HELPER_RUNTIME"]
        del self.env["ARKDECK_ROLLBACK_HELPER"]
        self.run_build(91)
        self.assertTrue(any(call[0] == "swift" for call in self.calls))
        self.assertFalse(any(call[0] == "cargo" for call in self.calls))

    def test_invalid_mode_stops_before_tools(self):
        self.env["ARKDECK_HELPER_RUNTIME"] = "unknown"
        self.run_build(64)
        self.assertEqual(self.calls, [])

    def test_missing_rollback_stops_before_tools(self):
        del self.env["ARKDECK_ROLLBACK_HELPER"]
        self.run_build(64)
        self.assertEqual(self.calls, [])

    def test_symlink_rollback_stops_before_tools(self):
        link = self.root / "alias.app"
        link.symlink_to(self.rollback, target_is_directory=True)
        self.env["ARKDECK_ROLLBACK_HELPER"] = str(link)
        self.run_build(64)
        self.assertEqual(self.calls, [])

    def test_wrong_profile_identity_stops_before_cargo(self):
        path = Path(self.env["ARKDECK_DAEMON_PROVISIONING_PROFILE"])
        profile = plistlib.loads(path.read_bytes())
        profile["Entitlements"]["com.apple.application-identifier"] = f"{TEAM}.wrong"
        path.write_bytes(plistlib.dumps(profile))
        self.run_build(78)
        self.assertFalse(any(call[0] == "cargo" for call in self.calls))

    def test_missing_signing_identity_stops_before_cargo(self):
        self.env["FIXTURE_FAIL"] = "identity"
        self.run_build(78)
        self.assertFalse(any(call[0] == "cargo" for call in self.calls))

    def test_build_failure_publishes_nothing(self):
        self.env["FIXTURE_FAIL"] = "build"
        self.run_build(17)

    def test_signing_failure_publishes_nothing(self):
        self.env["FIXTURE_FAIL"] = "sign"
        self.run_build(18)

    def test_rollback_signature_failure_publishes_nothing(self):
        self.env["FIXTURE_FAIL"] = "rollback"
        self.run_build(19)

    def test_wrong_architecture_publishes_nothing(self):
        self.env["FIXTURE_FAIL"] = "architecture"
        self.run_build(65)


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--tool":
        sys.exit(tool(sys.argv[2], sys.argv[3:]))
    unittest.main()
