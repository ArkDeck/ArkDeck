#!/usr/bin/env python3
"""Exercise the real release entry with recording build, signing and notary tools.

Fixture evidence only: no Keychain, no real signature, nothing sent to Apple,
no launchd. The release script, build-helpers.sh (Rust mode),
package-rust-helpers.sh and the version tool are the real ones; the tools they
call record each call and answer as the real ones would. One test also builds
and mounts an unsigned DMG with the real hdiutil when it is available.
"""

from __future__ import annotations

import hashlib
import json
import os
import plistlib
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

RELEASE = Path(__file__).resolve().parent
REPO = RELEASE.parents[1]
SCRIPT = RELEASE / "build_macos_release.py"
sys.path.insert(0, str(RELEASE))
import release_version  # noqa: E402

IDENTITY = "Developer ID Application: Fixture (8AQTYW5FKR)"
TEAM = "8AQTYW5FKR"
SOURCE_HEAD = "f" * 40
PIN = re.search(r'ArkForge\.git", rev = "([0-9a-f]{40})"', (REPO / "rust/Cargo.toml").read_text()).group(1)
VERSIONS = release_version.load()
DARWIN = sys.platform == "darwin"
# A 64-bit little-endian Mach-O magic: the release's nested-code check finds
# code by its magic, so fixture executables start with one.
MACH_O = bytes.fromhex("cffaedfe0c000001")
# Stand-ins for an App Store Connect API key: the key bytes must never leave
# the key file, and the ID and issuer never reach the script's output.
KEY_MATERIAL = "-----BEGIN PRIVATE KEY-----\nFIXTURE-NOTARY-KEY-MATERIAL\n-----END PRIVATE KEY-----\n"
KEY_ID = "FIXTUREKEY1"
ISSUER = "00000000-fixture-issuer-0000-000000000000"
NESTED_FAILURES = {
    "nested-adhoc": "is not signed with a Developer ID identity",
    "nested-no-runtime": "lacks the hardened runtime",
    "nested-no-timestamp": "lacks a secure timestamp",
    "nested-get-task-allow": "carries com.apple.security.get-task-allow",
    "nested-unsigned": "is not signed",
}


def log_call(name: str, arguments: list[str]) -> None:
    with open(os.environ["FIXTURE_LOG"], "a") as log:
        log.write(json.dumps([name, *arguments]) + "\n")


def option(arguments: list[str], flag: str) -> str:
    return arguments[arguments.index(flag) + 1]


def write_app(app: Path, version: str, build: str) -> None:
    (app / "Contents/MacOS").mkdir(parents=True)
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": "com.arkdeck.desktop",
        "CFBundleExecutable": "ArkDeck",
        "CFBundleShortVersionString": version,
        "CFBundleVersion": build,
    }))
    for name in ("ArkDeck", "trace_streamer"):
        executable = app / "Contents/MacOS" / name
        executable.write_bytes(MACH_O + f"fixture App {name}\n".encode())
        executable.chmod(0o755)


def make_arkforge_bundle(bundle: Path, extra: bool = False) -> None:
    members = []
    for path, role, profile, mode in (
        ("Contents/MacOS/arkforge", "cli", None, 0o700),
        ("Contents/MacOS/arkforged", "daemon", None, 0o700),
        ("Contents/Resources/profiles/dayu200.yaml", "profile", "org.openharmony.dayu200", 0o600),
    ):
        target = bundle / path
        target.parent.mkdir(parents=True, exist_ok=True)
        prefix = MACH_O if role in ("cli", "daemon") else b""
        target.write_bytes(prefix + f"fixture {path}\n".encode())
        target.chmod(mode)
        member = {"bytes": target.stat().st_size, "path": path, "role": role,
                  "sha256": hashlib.sha256(target.read_bytes()).hexdigest()}
        if profile:
            member["profileId"] = profile
        members.append(member)
    (bundle / "Contents/Resources/arkforge-bundle.json").write_text(json.dumps({
        "members": members, "schema": "arkforge.release-bundle/v1", "version": "0.1.0",
    }))
    if extra:
        (bundle / "Contents/Resources/.DS_Store").write_text("finder\n")


def display_signature(path: Path, failure: str, entitlements: bool) -> int:
    """`codesign --display` as the real one answers for a Developer ID
    signature; the App's nested trace_streamer is the one a failure spoils."""
    spoiled = failure if path.name == "trace_streamer" and failure in NESTED_FAILURES else ""
    if spoiled == "nested-unsigned":
        print(f"{path}: code object is not signed at all", file=sys.stderr)
        return 1
    if entitlements:
        granted = {"com.apple.security.app-sandbox": True}
        if spoiled == "nested-get-task-allow":
            granted["com.apple.security.get-task-allow"] = True
        print(f"Executable={path}", file=sys.stderr)
        sys.stdout.buffer.write(plistlib.dumps(granted, fmt=plistlib.FMT_XML))
        return 0
    adhoc = spoiled == "nested-adhoc"
    flags = "0x2(adhoc)" if adhoc else ("0x0(none)" if spoiled == "nested-no-runtime" else "0x10000(runtime)")
    lines = [
        f"Executable={path}",
        f"Identifier=fixture.{path.name}",
        "Format=Mach-O thin (arm64)",
        f"CodeDirectory v=20500 size=512 flags={flags} hashes=8+7 location=embedded",
    ]
    if adhoc:
        lines += ["Signature=adhoc", "TeamIdentifier=not set"]
    else:
        lines += [f"Authority={IDENTITY}", "Authority=Developer ID Certification Authority",
                  "Authority=Apple Root CA"]
        lines.append("Signed Time=Sep 28, 2026 at 12:00:00" if spoiled == "nested-no-timestamp"
                     else "Timestamp=Sep 28, 2026 at 12:00:00")
        lines.append(f"TeamIdentifier={TEAM}")
    print("\n".join(lines), file=sys.stderr)
    return 0


def tool(name: str, arguments: list[str]) -> int:
    log_call(name, arguments)
    failure = os.environ.get("FIXTURE_FAIL", "")
    state = Path(os.environ["FIXTURE_STATE"])
    if name == "git":
        repository, command = arguments[1], arguments[2:]
        forge = repository == os.environ.get("FIXTURE_ARKFORGE_CHECKOUT")
        if command == ["rev-parse", "HEAD"]:
            print(os.environ["FIXTURE_ARKFORGE_HEAD"] if forge else SOURCE_HEAD)
            return 0
        if command[0] == "status":
            dirty = failure == ("forge-dirty" if forge else "source-dirty")
            print(" M changed.rs" if dirty else "", end="")
            return 0
    elif name == "security":
        if arguments[:4] == ["find-identity", "-v", "-p", "codesigning"] and len(arguments) <= 5:
            print(f'  1) ABCDEF "{IDENTITY}"')
            return 0
        if arguments == ["list-keychains", "-d", "user"]:
            for keychain in os.environ.get("FIXTURE_SEARCH_LIST", "").split(":"):
                if keychain:
                    print(f'    "{keychain}"')
            return 0
        if arguments[:3] == ["cms", "-D", "-i"]:
            sys.stdout.buffer.write(Path(arguments[3]).read_bytes())
            return 0
    elif name == "cargo":
        if arguments[0] == "metadata":
            print(json.dumps({"target_directory": os.environ["CARGO_TARGET_DIR"]}))
            return 0
        if arguments[0] == "build":
            return 0
    elif name == "lipo":
        print("arm64")
        return 0
    elif name == "codesign":
        if "--display" in arguments:
            return display_signature(Path(arguments[-1]), failure, "--entitlements" in arguments)
        if failure == "dmg-sign" and "--force" in arguments and arguments[-1].endswith(".dmg"):
            return 1
        return 0
    elif name == "spctl":
        return 0
    elif name == "ditto":
        if arguments[:2] == ["-c", "-k"]:
            Path(arguments[-1]).write_text("fixture zip\n")
        else:
            source, destination = arguments[-2], arguments[-1]
            shutil.copytree(source, destination, symlinks=True)
        return 0
    elif name == "xcodebuild":
        if arguments[-1] == "archive":
            app = Path(option(arguments, "-archivePath")) / "Products/Applications/ArkDeck.app"
            write_app(app, VERSIONS["version"], os.environ.get("FIXTURE_APP_BUILD", VERSIONS["build"]))
            return 0
        if "-exportArchive" in arguments:
            source = Path(option(arguments, "-archivePath")) / "Products/Applications/ArkDeck.app"
            shutil.copytree(source, Path(option(arguments, "-exportPath")) / "ArkDeck.app", symlinks=True)
            return 0
    elif name == "xcrun":
        if arguments[0] == "notarytool":
            if arguments[1] == "history":
                print("{}")
                return 0
            if arguments[1] == "submit":
                subject = Path(arguments[2]).name
                status = "Invalid" if failure == "notary-dmg" and subject.endswith(".dmg") else "Accepted"
                print(json.dumps({"id": f"fixture-{subject}", "status": status}))
                return 0
            if arguments[1] == "log":
                Path(arguments[3]).write_text(json.dumps({"jobId": arguments[2]}))
                return 0
        if arguments[0] == "stapler":
            return 0
    elif name == "hdiutil":
        if arguments[0] == "create":
            dmg = Path(arguments[-1])
            key = hashlib.sha256(str(dmg).encode()).hexdigest()
            shutil.copytree(option(arguments, "-srcfolder"), state / key, symlinks=True)
            dmg.write_text(f"fixture dmg {key}\n")
            return 0
        if arguments[0] == "attach":
            key = Path(arguments[-1]).read_text().split()[-1]
            mountpoint = option(arguments, "-mountpoint")
            shutil.copytree(state / key, mountpoint, symlinks=True, dirs_exist_ok=True)
            sys.stdout.buffer.write(plistlib.dumps({"system-entities": [
                {"dev-entry": "/dev/disk99s1", "mount-point": mountpoint},
            ]}))
            return 0
        if arguments[0] in ("detach", "verify"):
            return 0
    raise RuntimeError(f"unexpected tool call: {name} {arguments}")


class Fixture(unittest.TestCase):
    TOOLS = ["git", "security", "cargo", "lipo", "codesign", "spctl", "ditto", "xcodebuild",
             "xcrun", "hdiutil", "swift", "launchctl"]

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="arkdeck-release-test-", dir="/private/tmp")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.bin = self.root / "tools"
        self.bin.mkdir()
        self.tmp = self.root / "tmp"
        self.tmp.mkdir()
        (self.root / "state").mkdir()
        self.log = self.root / "calls.jsonl"
        self.output = self.root / "release output"
        self.target = self.root / "cargo target"
        binaries = self.target / "aarch64-apple-darwin/release"
        binaries.mkdir(parents=True)
        for program in ("arkdeck", "arkdeck-agentd"):
            (binaries / program).write_bytes(MACH_O + f"fixture Rust {program}\n".encode())
            (binaries / program).chmod(0o700)
        self.forge = self.root / "ArkForge checkout"
        packaging = self.forge / "packaging/macos"
        packaging.mkdir(parents=True)
        (packaging / "package-arkforge.sh").write_text(
            "#!/bin/bash\nset -eu\nexec " + " ".join(map(shlex.quote, [
                sys.executable, str(Path(__file__).resolve()), "--package-arkforge",
            ])) + "\n"
        )
        self.env = {
            "PATH": f"{self.bin}:/usr/bin:/bin",
            "TMPDIR": str(self.tmp),
            "CARGO_TARGET_DIR": str(self.target),
            "FIXTURE_LOG": str(self.log),
            "FIXTURE_STATE": str(self.root / "state"),
            "FIXTURE_ARKFORGE_CHECKOUT": str(self.forge),
            "FIXTURE_ARKFORGE_HEAD": PIN,
            "ARKDECK_CODESIGN_IDENTITY": IDENTITY,
            "ARKDECK_NOTARY_KEYCHAIN_PROFILE": "fixture-notary",
        }
        for kind in ("cli", "daemon"):
            identifier = "agentd" if kind == "daemon" else kind
            profile = self.root / f"{kind}.provisionprofile"
            profile.write_bytes(plistlib.dumps({"Entitlements": {
                "com.apple.developer.team-identifier": TEAM,
                "com.apple.application-identifier": f"{TEAM}.com.arkdeck.{identifier}",
                "keychain-access-groups": [f"{TEAM}.com.arkdeck.shared"],
            }}))
            self.env[f"ARKDECK_{kind.upper()}_PROVISIONING_PROFILE"] = str(profile)

    def install_tools(self, names: list[str]) -> None:
        for name in names:
            wrapper = self.bin / name
            wrapper.write_text("#!/bin/sh\nexec " + " ".join(map(shlex.quote, [
                sys.executable, str(Path(__file__).resolve()), "--tool", name,
            ])) + ' "$@"\n')
            wrapper.chmod(0o700)

    def run_script(self, arguments: list[str], expected: int) -> subprocess.CompletedProcess:
        result = subprocess.run(
            [sys.executable, str(SCRIPT), *arguments],
            env=self.env, capture_output=True, text=True, timeout=120,
        )
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        self.assertEqual(list(self.tmp.iterdir()), [], "temporary work roots leaked")
        if expected:
            self.assertFalse(self.output.exists(), "a failed build published an output")
        self.calls = [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []
        self.assertFalse(any(call[0] in ("launchctl", "swift") for call in self.calls))
        attaches = sum(1 for call in self.calls if call[:2] == ["hdiutil", "attach"])
        detaches = sum(1 for call in self.calls if call[:2] == ["hdiutil", "detach"])
        self.assertEqual(attaches, detaches, "a mounted DMG was left attached")
        return result

    def called(self, *prefix: str) -> list[list[str]]:
        return [call for call in self.calls if call[:len(prefix)] == list(prefix)]


@unittest.skipUnless(DARWIN, "build-helpers.sh reads profiles with PlistBuddy and plutil")
class Release(Fixture):
    def setUp(self) -> None:
        super().setUp()
        self.install_tools(self.TOOLS)
        self.arguments = ["release", "--output", str(self.output), "--arkforge-checkout", str(self.forge)]

    def test_release_builds_notarizes_staples_and_verifies_one_dmg(self):
        result = self.run_script(self.arguments, 0)
        name = f"ArkDeck-{VERSIONS['version']}-{VERSIONS['build']}.dmg"
        self.assertEqual(result.stdout.strip(), str(self.output / name))
        self.assertEqual(sorted(item.name for item in self.output.iterdir()),
                         sorted([name, "release-receipt.json", "notary-log-app.json", "notary-log-dmg.json"]))
        receipt = json.loads((self.output / "release-receipt.json").read_text())
        self.assertEqual(receipt["schema"], "arkdeck.macos-release-receipt/1")
        self.assertEqual(receipt["mode"], "release")
        self.assertEqual((receipt["version"], receipt["build"]), (VERSIONS["version"], VERSIONS["build"]))
        self.assertEqual(receipt["source"], {"revision": SOURCE_HEAD, "clean": True})
        self.assertEqual(receipt["arkforge"]["pinnedRevision"], PIN)
        self.assertEqual(receipt["arkforge"]["builtRevision"], PIN)
        self.assertEqual(receipt["dmg"]["sha256"],
                         hashlib.sha256((self.output / name).read_bytes()).hexdigest())
        self.assertEqual(receipt["dmg"]["entries"],
                         sorted(["ArkDeck.app", "ArkDeckCLI.app", "ArkForge.bundle", "INSTALL.md"]))
        self.assertEqual(receipt["notarization"], {
            "app": {"submissionId": "fixture-ArkDeck-notarization.zip", "status": "Accepted"},
            "dmg": {"submissionId": f"fixture-{name}", "status": "Accepted"},
        })
        cli = receipt["components"]["ArkDeckCLI.app"]
        self.assertEqual(cli["daemon"]["bundleIdentifier"], "com.arkdeck.agentd")
        self.assertEqual(cli["daemon"]["executableSHA256"], hashlib.sha256(
            (self.target / "aarch64-apple-darwin/release/arkdeck-agentd").read_bytes()).hexdigest())

        # Credentials and identity are checked before anything is built.
        first_build = min(index for index, call in enumerate(self.calls) if call[0] in ("cargo", "xcodebuild"))
        for preflight in (["security", "find-identity"], ["xcrun", "notarytool", "history"]):
            self.assertLess(self.calls.index(next(call for call in self.calls
                                                  if call[:len(preflight)] == preflight)), first_build)
        # The helper pair is the Rust release of build-helpers.sh, retaining no Swift helper.
        self.assertEqual(self.called("cargo", "build"), [[
            "cargo", "build", "--locked", "--release", "--target", "aarch64-apple-darwin",
            "-p", "arkdeck-cli", "-p", "arkdeck-agentd", "--bins"]])
        # Three notarizations: the helper pair, the App, the DMG; each stapled.
        submitted = [Path(call[3]).name for call in self.called("xcrun", "notarytool", "submit")]
        self.assertEqual(submitted, ["ArkDeckCLI-notarization.zip", "ArkDeck-notarization.zip", name])
        self.assertEqual([Path(call[3]).name for call in self.called("xcrun", "stapler", "staple")],
                         ["ArkDeckCLI.app", "ArkDeck.app", name])
        for call in self.called("xcrun", "notarytool", "submit")[1:]:
            self.assertEqual(call[4:], ["--keychain-profile", "fixture-notary", "--wait", "--output-format", "json"])
        # The App is exported for Developer ID with the committed options.
        export = self.called("xcodebuild", "-exportArchive")
        self.assertEqual(option(export[0], "-exportOptionsPlist"), str(RELEASE / "ExportOptions.plist"))
        # The DMG is signed with a secure timestamp, assessed, and its contents verified mounted.
        dmg_path = str(self.output / name)
        self.assertIn(["codesign", "--force", "--sign", IDENTITY, "--timestamp"],
                      [call[:5] for call in self.calls if call[-1].endswith(name)])
        self.assertTrue(any(call[:4] == ["spctl", "--assess", "--type", "open"] for call in self.calls))
        requirements = [option(call, "-R") for call in self.called("codesign", "--verify") if "-R" in call]
        self.assertIn(
            f'=anchor apple generic and certificate leaf[subject.OU] = "{TEAM}" and identifier '
            f'"com.arkdeck.agentd" and '
            f'info[CFBundleShortVersionString] = "{VERSIONS["version"]}" and '
            f'info[CFBundleVersion] = "{VERSIONS["build"]}"', requirements)
        self.assertEqual(len([call for call in self.called("spctl", "--assess", "--type", "execute")
                              if "/mount/" in call[-1]]), 2)
        self.assertNotIn(dmg_path, [call[-1] for call in self.called("hdiutil", "attach")])
        # Every Mach-O of every component is checked for what notarization
        # requires, the App's nested trace_streamer before the App is uploaded.
        displayed = [call[-1] for call in self.called("codesign", "--display", "--verbose=4")]
        exported = [path for path in displayed if "/export/ArkDeck.app/" in path]
        self.assertEqual(sorted(Path(path).name for path in exported), ["ArkDeck", "trace_streamer"])
        app_upload = self.calls.index(next(call for call in self.called("xcrun", "notarytool", "submit")
                                           if call[3].endswith("ArkDeck-notarization.zip")))
        for path in exported:
            self.assertLess(self.calls.index(["codesign", "--display", "--verbose=4", path]), app_upload)
        mounted = sorted(path.split("/mount/", 1)[1] for path in displayed if "/mount/" in path)
        self.assertEqual(mounted, sorted([
            "ArkDeck.app/Contents/MacOS/ArkDeck", "ArkDeck.app/Contents/MacOS/trace_streamer",
            "ArkDeckCLI.app/Contents/MacOS/arkdeck",
            "ArkDeckCLI.app/Contents/Helpers/ArkDeckAgent.app/Contents/MacOS/arkdeck-agentd",
            "ArkForge.bundle/Contents/MacOS/arkforge", "ArkForge.bundle/Contents/MacOS/arkforged",
        ]))
        # ArkForge was packaged by its own script, with the release identity.
        forged = self.root / "arkforge-package.json"
        self.assertEqual(json.loads(forged.read_text())["identity"], IDENTITY)

    def test_nested_code_notarization_would_reject_stops_before_the_app_upload(self):
        for failure, message in NESTED_FAILURES.items():
            with self.subTest(failure):
                self.log.unlink(missing_ok=True)
                self.env["FIXTURE_FAIL"] = failure
                result = self.run_script(self.arguments, 1)
                self.assertIn("nested code notarization would reject: ArkDeck.app/Contents/MacOS/trace_streamer "
                              + message, result.stderr)
                self.assertNotIn("ArkDeck.app/Contents/MacOS/ArkDeck ", result.stderr)
                submitted = [Path(call[3]).name for call in self.called("xcrun", "notarytool", "submit")]
                self.assertEqual(submitted, ["ArkDeckCLI-notarization.zip"])
                self.assertEqual(self.called("hdiutil", "create"), [])

    def test_arkforge_head_other_than_the_pin_stops_before_any_build(self):
        self.env["FIXTURE_ARKFORGE_HEAD"] = "0" * 40
        result = self.run_script(self.arguments, 1)
        self.assertIn("is not the revision rust/Cargo.toml pins", result.stderr)
        self.assertFalse(any(call[0] in ("cargo", "xcodebuild", "xcrun", "security") for call in self.calls))

    def test_dirty_arkforge_checkout_stops_before_any_build(self):
        self.env["FIXTURE_FAIL"] = "forge-dirty"
        result = self.run_script(self.arguments, 1)
        self.assertIn("ArkForge checkout has local changes", result.stderr)
        self.assertFalse(any(call[0] in ("cargo", "xcodebuild") for call in self.calls))

    def test_dirty_source_checkout_stops_before_any_build(self):
        self.env["FIXTURE_FAIL"] = "source-dirty"
        result = self.run_script(self.arguments, 1)
        self.assertIn("clean checkout", result.stderr)
        self.assertFalse(any(call[0] in ("cargo", "xcodebuild") for call in self.calls))

    def test_missing_notary_profile_stops_before_tools_that_build(self):
        del self.env["ARKDECK_NOTARY_KEYCHAIN_PROFILE"]
        result = self.run_script(self.arguments, 1)
        self.assertIn("ARKDECK_NOTARY_KEYCHAIN_PROFILE", result.stderr)
        self.assertFalse(any(call[0] in ("cargo", "xcodebuild", "xcrun", "security") for call in self.calls))

    def use_api_key(self) -> Path:
        """Notary credentials as the release-rc workflow gives them."""
        self.env.pop("ARKDECK_NOTARY_KEYCHAIN_PROFILE", None)
        key = self.root / "AuthKey_FIXTURE.p8"
        key.write_text(KEY_MATERIAL)
        key.chmod(0o600)
        self.env.update({
            "ARKDECK_NOTARY_API_KEY_PATH": str(key),
            "ARKDECK_NOTARY_API_KEY_ID": KEY_ID,
            "ARKDECK_NOTARY_API_ISSUER_ID": ISSUER,
        })
        return key

    def test_api_key_notarizes_every_submission_without_a_keychain_profile(self):
        key = self.use_api_key()
        result = self.run_script(self.arguments, 0)
        credentials = ["--key", str(key), "--key-id", KEY_ID, "--issuer", ISSUER]
        self.assertEqual([call[2] for call in self.called("xcrun", "notarytool")],
                         ["history", "submit", "submit", "log", "submit", "log"])
        self.assertEqual(self.called("xcrun", "notarytool", "history")[0][3:],
                         credentials + ["--output-format", "json"])
        submits = self.called("xcrun", "notarytool", "submit")
        # build-helpers.sh submits the helper pair; the script the App and the DMG.
        self.assertEqual(submits[0][4:], credentials + ["--wait"])
        for call in submits[1:]:
            self.assertEqual(call[4:], credentials + ["--wait", "--output-format", "json"])
        for call in self.called("xcrun", "notarytool", "log"):
            self.assertEqual(call[5:], credentials)
        self.assertFalse(any("--keychain-profile" in call for call in self.calls))
        # The key's bytes stay in its file; its ID and issuer stay out of the output.
        self.assertNotIn("FIXTURE-NOTARY-KEY-MATERIAL", self.log.read_text())
        for secret in ("FIXTURE-NOTARY-KEY-MATERIAL", KEY_ID, ISSUER):
            self.assertNotIn(secret, result.stdout + result.stderr)

    def test_notary_credentials_must_be_exactly_one_kind(self):
        cases = (
            ("both", "not both", {"ARKDECK_NOTARY_KEYCHAIN_PROFILE": "fixture-notary"}, ()),
            ("neither", "release needs notary credentials", {},
             ("ARKDECK_NOTARY_API_KEY_PATH", "ARKDECK_NOTARY_API_KEY_ID", "ARKDECK_NOTARY_API_ISSUER_ID")),
            ("partial", "the notary API key also needs ARKDECK_NOTARY_API_ISSUER_ID", {},
             ("ARKDECK_NOTARY_API_ISSUER_ID",)),
            ("relative key", "must be an absolute path to the .p8 key file",
             {"ARKDECK_NOTARY_API_KEY_PATH": "AuthKey_FIXTURE.p8"}, ()),
            ("key with a notary keychain", "an API key has none",
             {"ARKDECK_NOTARY_KEYCHAIN": "/fixture/notary.keychain-db"}, ()),
        )
        for case, message, added, removed in cases:
            with self.subTest(case):
                self.log.unlink(missing_ok=True)
                self.env.pop("ARKDECK_NOTARY_KEYCHAIN", None)
                self.use_api_key()
                self.env.update(added)
                for name in removed:
                    del self.env[name]
                result = self.run_script(self.arguments, 1)
                self.assertIn(message, result.stderr)
                for secret in ("FIXTURE-NOTARY-KEY-MATERIAL", KEY_ID, ISSUER):
                    self.assertNotIn(secret, result.stderr)
                self.assertFalse(any(call[0] in ("cargo", "xcodebuild", "xcrun", "security")
                                     for call in self.calls))

    def test_build_helpers_refuses_both_or_neither_notary_credential(self):
        output = self.root / "helpers"
        self.use_api_key()
        api_key = dict(self.env, ARKDECK_HELPER_OUTPUT=str(output))
        both = dict(api_key, ARKDECK_NOTARY_KEYCHAIN_PROFILE="fixture-notary")
        partial = {name: value for name, value in api_key.items() if name != "ARKDECK_NOTARY_API_ISSUER_ID"}
        neither = {name: value for name, value in api_key.items() if not name.startswith("ARKDECK_NOTARY_")}
        for case, environment, message in (
            ("both", both, "not both"),
            ("neither", neither, "notary credentials are required"),
            ("partial", partial, "notary credentials are required"),
        ):
            with self.subTest(case):
                result = subprocess.run(["/bin/bash", str(release_version.DISTRIBUTION / "build-helpers.sh")],
                                        env=environment, capture_output=True, text=True, timeout=60)
                self.assertEqual(result.returncode, 64, result.stderr)
                self.assertIn(message, result.stderr)
                self.assertFalse(self.log.exists(), "a refused helper build ran a tool")
                self.assertFalse(output.exists())

    def test_codesign_keychain_reaches_every_signature_this_repository_makes(self):
        keychain = self.root / "arkdeck-release.keychain-db"
        keychain.write_bytes(b"fixture keychain\n")
        self.env["ARKDECK_CODESIGN_KEYCHAIN"] = str(keychain)
        self.env["FIXTURE_SEARCH_LIST"] = f"{keychain}:/Users/fixture/Library/Keychains/login.keychain-db"
        self.run_script(self.arguments, 0)
        self.assertEqual(self.called("security", "find-identity"),
                         [["security", "find-identity", "-v", "-p", "codesigning", str(keychain)]])
        # The daemon and the CLI (package-rust-helpers.sh), then the DMG.
        signatures = self.called("codesign", "--force", "--sign")
        self.assertEqual(len(signatures), 3)
        for call in signatures:
            self.assertEqual(option(call, "--keychain"), str(keychain))
        archive = self.called("xcodebuild", "-project")
        self.assertEqual(len(archive), 1)
        self.assertIn(f"OTHER_CODE_SIGN_FLAGS=--timestamp --keychain {keychain}", archive[0])
        self.assertEqual(archive[0][-1], "archive")

    def test_codesign_keychain_off_the_search_list_is_refused(self):
        keychain = self.root / "arkdeck-release.keychain-db"
        keychain.write_bytes(b"fixture keychain\n")
        self.env["ARKDECK_CODESIGN_KEYCHAIN"] = str(keychain)
        self.env["FIXTURE_SEARCH_LIST"] = "/Users/fixture/Library/Keychains/login.keychain-db"
        result = self.run_script(self.arguments, 1)
        self.assertIn("not on the user keychain search list", result.stderr)
        self.assertFalse(any(call[0] in ("cargo", "xcodebuild") for call in self.calls))

    def test_rejected_dmg_notarization_publishes_nothing(self):
        self.env["FIXTURE_FAIL"] = "notary-dmg"
        result = self.run_script(self.arguments, 1)
        self.assertIn("'Invalid'", result.stderr)
        self.assertEqual(self.called("xcrun", "stapler", "staple")[-1][-1].endswith(".dmg"), False)

    def test_dmg_signing_failure_publishes_nothing(self):
        self.env["FIXTURE_FAIL"] = "dmg-sign"
        self.run_script(self.arguments, 1)
        self.assertEqual(self.called("hdiutil", "attach"), [])

    def test_app_from_another_build_is_refused(self):
        self.env["FIXTURE_APP_BUILD"] = str(int(VERSIONS["build"]) + 1)
        result = self.run_script(self.arguments, 1)
        self.assertIn("ArkDeck.app carries version", result.stderr)
        self.assertEqual(self.called("hdiutil", "create"), [])


class Unsigned(Fixture):
    def setUp(self) -> None:
        super().setUp()
        self.app = self.root / "inputs/ArkDeck.app"
        write_app(self.app, VERSIONS["version"], VERSIONS["build"])
        self.helpers = self.root / "inputs/helpers"
        cli = self.helpers / "ArkDeckCLI.app"
        daemon = cli / "Contents/Helpers/ArkDeckAgent.app"
        for bundle, info, program in (
            (cli, "ArkDeckCLI-Info.plist", "arkdeck"), (daemon, "ArkDeckAgent-Info.plist", "arkdeck-agentd"),
        ):
            (bundle / "Contents/MacOS").mkdir(parents=True)
            shutil.copyfile(release_version.DISTRIBUTION / info, bundle / "Contents/Info.plist")
            (bundle / "Contents/MacOS" / program).write_text(f"fixture {program}\n")
            (bundle / "Contents/MacOS" / program).chmod(0o700)
        (self.helpers / "UNSIGNED-STRUCTURE-CHECK-ONLY.txt").write_text("marker\n")
        self.forge_bundle = self.root / "inputs/ArkForge.bundle"
        make_arkforge_bundle(self.forge_bundle)
        self.arguments = ["unsigned", "--output", str(self.output), "--app", str(self.app),
                          "--helpers", str(self.helpers), "--arkforge-bundle", str(self.forge_bundle)]

    def assert_unsigned_output(self, result: subprocess.CompletedProcess) -> dict:
        name = f"ArkDeck-{VERSIONS['version']}-{VERSIONS['build']}-unsigned.dmg"
        self.assertEqual(result.stdout.strip(), str(self.output / name))
        self.assertIn("not for distribution", result.stderr)
        self.assertEqual(sorted(item.name for item in self.output.iterdir()),
                         sorted([name, "release-receipt.json", "UNSIGNED-STRUCTURE-CHECK-ONLY.txt"]))
        receipt = json.loads((self.output / "release-receipt.json").read_text())
        self.assertEqual(receipt["mode"], "unsigned-structure-check")
        self.assertIsNone(receipt["notarization"])
        self.assertFalse(receipt["dmg"]["signed"])
        self.assertIn("UNSIGNED-STRUCTURE-CHECK-ONLY.txt", receipt["dmg"]["entries"])
        self.assertIsNone(receipt["arkforge"]["builtRevision"])
        # Nothing is signed and nothing reaches Apple.
        self.assertFalse(any(call[0] in ("codesign", "xcrun", "spctl", "security", "xcodebuild", "cargo")
                             for call in self.calls))
        return receipt

    def test_unsigned_structure_check_with_recording_hdiutil(self):
        self.install_tools(self.TOOLS)
        self.assert_unsigned_output(self.run_script(self.arguments, 0))
        self.assertEqual(len(self.called("hdiutil", "create")), 1)

    @unittest.skipUnless(DARWIN and shutil.which("hdiutil"), "needs the real hdiutil")
    def test_unsigned_structure_check_with_the_real_hdiutil(self):
        self.install_tools([name for name in self.TOOLS if name not in ("hdiutil", "ditto", "git")])
        receipt = self.assert_unsigned_output(self.run_script(self.arguments, 0))
        self.assertEqual(receipt["source"]["revision"],
                         subprocess.run(["git", "-C", str(REPO), "rev-parse", "HEAD"],
                                        capture_output=True, text=True, check=True).stdout.strip())

    def test_undeclared_arkforge_member_is_refused(self):
        self.install_tools(self.TOOLS)
        (self.forge_bundle / "Contents/Resources/.DS_Store").write_text("finder\n")
        result = self.run_script(self.arguments, 1)
        self.assertIn("which its manifest does not declare", result.stderr)

    def test_daemon_with_a_facade_is_refused(self):
        self.install_tools(self.TOOLS)
        facade = self.helpers / "ArkDeckCLI.app/Contents/Helpers/ArkDeckAgent.app/Contents/MacOS/arkdeck-facade"
        facade.write_text("facade\n")
        result = self.run_script(self.arguments, 1)
        self.assertIn("Swift facade", result.stderr)

    def test_arkforge_nested_in_an_app_is_refused(self):
        self.install_tools(self.TOOLS)
        make_arkforge_bundle(self.app / "Contents/Resources/ArkForge.bundle")
        result = self.run_script(self.arguments, 1)
        self.assertIn("must not carry ArkForge.bundle", result.stderr)

    def test_existing_output_is_never_overwritten(self):
        self.install_tools(self.TOOLS)
        self.output.mkdir()
        result = subprocess.run([sys.executable, str(SCRIPT), *self.arguments], env=self.env,
                                capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, 1)
        self.assertIn("output already exists", result.stderr)
        self.assertEqual(list(self.output.iterdir()), [])


class Versions(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="arkdeck-version-test-", dir="/private/tmp")
        self.addCleanup(self.temporary.cleanup)
        self.repo = Path(self.temporary.name)
        for path in (release_version.SOURCE, release_version.PROJECT, release_version.APP_INFO,
                     *release_version.HELPER_INFOS):
            target = self.repo / path.relative_to(REPO)
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(path, target)

    def test_repository_copies_are_in_lockstep(self):
        self.assertEqual(release_version.drift(), [])

    def test_bump_build_rewrites_every_copy_and_nothing_else(self):
        project = (self.repo / "ArkDeck.xcodeproj/project.pbxproj").read_text()
        self.assertEqual(release_version.main(["bump-build"], self.repo), 0)
        bumped = str(int(VERSIONS["build"]) + 1)
        self.assertEqual(release_version.load(self.repo), {"version": VERSIONS["version"], "build": bumped})
        self.assertEqual(release_version.drift(self.repo), [])
        after = (self.repo / "ArkDeck.xcodeproj/project.pbxproj").read_text()
        self.assertEqual(after.replace(f"CURRENT_PROJECT_VERSION = {bumped};",
                                       f"CURRENT_PROJECT_VERSION = {VERSIONS['build']};"), project)
        for info in release_version.HELPER_INFOS:
            values = plistlib.loads((self.repo / info.relative_to(REPO)).read_bytes())
            self.assertEqual(values["CFBundleVersion"], bumped)

    def test_set_rejects_what_the_app_requirement_cannot_carry(self):
        for version, build in (("0.1", "1a"), ("v0.2.0", "2"), ("0.1.0", "1.2.3.4"), ("0.1.0", "")):
            self.assertEqual(release_version.main(["set", version, build], self.repo), 1)
        self.assertEqual(release_version.load(self.repo), VERSIONS)

    def test_a_hand_edited_copy_is_drift(self):
        info = self.repo / release_version.HELPER_INFOS[1].relative_to(REPO)
        info.write_text(info.read_text().replace(
            f"<string>{VERSIONS['build']}</string>\n\t<key>LSBackgroundOnly",
            "<string>99</string>\n\t<key>LSBackgroundOnly"))
        self.assertEqual(release_version.drift(self.repo),
                         [f"ArkDeckAgent-Info.plist CFBundleVersion '99' != {VERSIONS['build']}"])
        self.assertEqual(release_version.main(["check"], self.repo), 1)


def package_arkforge() -> int:
    """Stand-in for ArkForge's packaging/macos/package-arkforge.sh."""
    output = Path(os.environ["ARKFORGE_PACKAGE_OUTPUT"])
    make_arkforge_bundle(output)
    Path(os.environ["FIXTURE_LOG"]).parent.joinpath("arkforge-package.json").write_text(
        json.dumps({"identity": os.environ["ARKFORGE_CODESIGN_IDENTITY"], "cwd": os.getcwd()}))
    return 0


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--tool":
        sys.exit(tool(sys.argv[2], sys.argv[3:]))
    if len(sys.argv) > 1 and sys.argv[1] == "--package-arkforge":
        sys.exit(package_arkforge())
    unittest.main()
