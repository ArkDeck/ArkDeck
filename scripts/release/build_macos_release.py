#!/usr/bin/env python3
"""Build the ArkDeck macOS release candidate: one notarized, stapled DMG.

CHG-2026-074 TASK-XPA-017 (stage S, slice S5). The DMG holds, side by side:

  ArkDeck.app       the sandboxed App, Release archive exported for Developer ID
  ArkDeckCLI.app    the Rust CLI; Contents/Helpers/ArkDeckAgent.app is the Rust daemon
  ArkForge.bundle   built at the ArkForge revision rust/Cargo.toml pins
  INSTALL.md        docs/release/macos-install.md

ArkForge.bundle is its own DMG item and is never nested in an .app: its loader
refuses any file its manifest does not declare
(rust/crates/arkdeck-contract/src/arkforge_bundle.rs, reject_undeclared), and
signing an enclosing bundle would add one (`_CodeSignature`).

Two modes share one assembly and verification path:

release   (Developer ID identity, provisioning profiles, notary credentials:
          the maintainer's own Keychain, or the release-rc workflow's
          temporary keychain and App Store Connect API key) builds every
          component from a clean checkout:
          1. the Rust helper pair through
             Packages/ArkDeckKit/Distribution/macOS/build-helpers.sh, which
             signs, notarizes, staples and assesses the pair itself;
          2. ArkForge.bundle through the ArkForge checkout's
             packaging/macos/package-arkforge.sh, only when that checkout is
             clean and its HEAD equals the pin; the bundle is covered by the
             DMG's notarization (a bare bundle cannot carry a stapled ticket);
          3. the App: `xcodebuild archive` (Release) and `-exportArchive` with
             scripts/release/ExportOptions.plist, then notarized, stapled and
             assessed on its own so it passes Gatekeeper offline once copied
             out of the DMG;
          then assembles the DMG, signs it with a secure timestamp, notarizes
          it (`notarytool submit --wait`), staples and validates it, assesses
          it with spctl, mounts it and verifies what it carries: the trees
          byte for byte, strict signatures, the App's own requirement and the
          exact requirement the App holds the daemon to (identity, Team,
          CFBundleShortVersionString and CFBundleVersion), spctl on the
          mounted App and CLI, and the ArkForge executables' Team anchor.
          Every Mach-O in the App, the CLI and ArkForge.bundle (the App's
          nested trace_streamer included) must carry a Developer ID signature
          of this Team with hardened runtime and a secure timestamp and no
          get-task-allow; this is checked right after each component is built,
          before the App is uploaded, and again on the mounted DMG.

unsigned  (anyone, CI included; no identity, no credentials, nothing sent to
          Apple) takes already built components (--app, --helpers,
          --arkforge-bundle), runs the same component checks, assembles an
          unsigned DMG with the same layout, mounts it and compares the trees.
          It signs nothing, and its output says so in
          UNSIGNED-STRUCTURE-CHECK-ONLY.txt, inside the DMG and beside it.

Both write release-receipt.json beside the DMG: the source revision, the
version pair, the ArkForge revision, SHA-256 of the DMG, each component's
tree and main executable, the ArkForge manifest and members, and the notary
submission ids (release only).

Nothing is published unless every step passes: work happens in a temporary
directory and the output directory appears only at the end. The script never
installs anything, never runs `runtime service`, and never talks to a device.

Usage:
  build_macos_release.py release --output DIR --arkforge-checkout DIR
      env: ARKDECK_CLI_PROVISIONING_PROFILE, ARKDECK_DAEMON_PROVISIONING_PROFILE
           (required); notary credentials, exactly one of
             ARKDECK_NOTARY_KEYCHAIN_PROFILE [ARKDECK_NOTARY_KEYCHAIN]
             ARKDECK_NOTARY_API_KEY_PATH, ARKDECK_NOTARY_API_KEY_ID,
               ARKDECK_NOTARY_API_ISSUER_ID (an App Store Connect API key);
           ARKDECK_CODESIGN_IDENTITY, ARKDECK_CODESIGN_KEYCHAIN (optional; the
           keychain that holds the identity, which must also be on the user
           keychain search list)
  build_macos_release.py unsigned --output DIR --app APP --helpers DIR
      --arkforge-bundle DIR [--arkforge-checkout DIR]
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any, Mapping, Sequence

RELEASE = Path(__file__).resolve().parent
REPO = RELEASE.parents[1]
sys.path.insert(0, str(RELEASE))
import release_version  # noqa: E402

DISTRIBUTION = REPO / "Packages/ArkDeckKit/Distribution/macOS"
HELPER_BUILDER = DISTRIBUTION / "build-helpers.sh"
EXPORT_OPTIONS = RELEASE / "ExportOptions.plist"
INSTALL_GUIDE = REPO / "docs/release/macos-install.md"
PROJECT = REPO / "ArkDeck.xcodeproj"
CARGO_MANIFEST = REPO / "rust/Cargo.toml"

TEAM = "8AQTYW5FKR"
DEFAULT_IDENTITY = f"Developer ID Application: Hanfeng Fu ({TEAM})"
ANCHOR = f'anchor apple generic and certificate leaf[subject.OU] = "{TEAM}"'
APP = "ArkDeck.app"
CLI = "ArkDeckCLI.app"
DAEMON = "Contents/Helpers/ArkDeckAgent.app"
ARKFORGE = "ArkForge.bundle"
GUIDE = "INSTALL.md"
MARKER = "UNSIGNED-STRUCTURE-CHECK-ONLY.txt"
MARKER_TEXT = (
    "UNSIGNED STRUCTURE CHECK ONLY: nothing here is Developer ID signed, notarized or "
    "stapled. Never distribute or install it; releases come only from "
    "`build_macos_release.py release`.\n"
)
RECEIPT = "release-receipt.json"
RECEIPT_SCHEMA = "arkdeck.macos-release-receipt/1"
ARKFORGE_MANIFEST = "Contents/Resources/arkforge-bundle.json"
ARKFORGE_SCHEMA = "arkforge.release-bundle/v1"
ARKFORGE_EXECUTABLES = ("Contents/MacOS/arkforge", "Contents/MacOS/arkforged")
ARKFORGE_PIN = re.compile(
    r'^arkforge-[a-z-]+ = \{ git = "https://github\.com/ArkDeck/ArkForge\.git", '
    r'rev = "([0-9a-f]{40})" \}$',
    re.MULTILINE,
)
NOTARY_TIMEOUT = 3 * 60 * 60


class ReleaseError(RuntimeError):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ReleaseError(message)


# -- processes -----------------------------------------------------------------


def run(
    arguments: Sequence[str | Path],
    *,
    env: Mapping[str, str] | None = None,
    cwd: Path | None = None,
    capture: bool = True,
    timeout: float | None = None,
    merge_stderr: bool = False,
) -> str:
    argv = [str(argument) for argument in arguments]
    try:
        result = subprocess.run(
            argv,
            env=dict(env) if env is not None else None,
            cwd=cwd,
            # A build step's own output goes to stderr: stdout carries only
            # the DMG path this script prints at the end.
            stdout=subprocess.PIPE if capture else sys.stderr,
            stderr=(subprocess.STDOUT if merge_stderr else subprocess.PIPE) if capture else None,
            text=True,
            timeout=timeout,
            check=False,
        )
    except FileNotFoundError as error:
        raise ReleaseError(f"{argv[0]} is not available: {error}") from error
    if result.returncode != 0:
        diagnostics = result.stdout if merge_stderr else result.stderr
        detail = (diagnostics or "").strip().splitlines()[-5:] if capture else []
        raise ReleaseError(
            f"{' '.join(argv[:3])} exited {result.returncode}"
            + (": " + " | ".join(detail) if detail else "")
        )
    return result.stdout or ""


# -- digests and trees ---------------------------------------------------------

# `hdiutil create` fails with "Resource busy" when another process (on hosted
# runners, usually the malware scanner) still holds the freshly staged tree.
# Only that failure is retried, after removing any partial image; every other
# failure, and the last busy one, is reported as it is.
HDIUTIL_BUSY = "Resource busy"
HDIUTIL_ATTEMPTS = 5


def create_dmg(arguments: Sequence[str | Path], dmg: Path, environment: Mapping[str, str]) -> None:
    delay = float(environment.get("ARKDECK_HDIUTIL_RETRY_SECONDS", "15"))
    for attempt in range(1, HDIUTIL_ATTEMPTS + 1):
        try:
            run(arguments, env=environment)
            return
        except ReleaseError as error:
            if HDIUTIL_BUSY not in str(error) or attempt == HDIUTIL_ATTEMPTS:
                raise
            dmg.unlink(missing_ok=True)
            print(f"build_macos_release: hdiutil create busy (attempt {attempt}/{HDIUTIL_ATTEMPTS}); "
                  f"retrying in {delay * attempt:.0f} s", file=sys.stderr)
            time.sleep(delay * attempt)



def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def tree_sha256(root: Path) -> str:
    """Digest of a bundle's shape and bytes: every entry's relative path, kind,
    permission bits and content (link target for a link), in sorted order."""
    digest = hashlib.sha256()
    entries = []
    for directory, subdirectories, names in os.walk(root):
        for name in subdirectories + names:
            entries.append(Path(directory, name))
    for path in sorted(entries, key=lambda item: item.relative_to(root).as_posix()):
        relative = path.relative_to(root).as_posix()
        mode = path.lstat().st_mode
        if stat.S_ISLNK(mode):
            record = f"l {relative} {os.readlink(path)}"
        elif stat.S_ISDIR(mode):
            record = f"d {relative} {stat.S_IMODE(mode):o}"
        elif stat.S_ISREG(mode):
            record = f"f {relative} {stat.S_IMODE(mode):o} {sha256_file(path)}"
        else:
            raise ReleaseError(f"{root.name}/{relative} is neither a file, a directory nor a link")
        digest.update(record.encode() + b"\0")
    return digest.hexdigest()


def read_plist(path: Path) -> dict[str, Any]:
    try:
        value = plistlib.loads(path.read_bytes())
    except (OSError, plistlib.InvalidFileException, ValueError) as error:
        raise ReleaseError(f"cannot read {path}: {error}") from error
    require(isinstance(value, dict), f"{path} is not a dictionary")
    return value


# -- inputs --------------------------------------------------------------------


def arkforge_pin() -> str:
    pins = set(ARKFORGE_PIN.findall(CARGO_MANIFEST.read_text(encoding="utf-8")))
    require(len(pins) == 1, f"rust/Cargo.toml must pin ArkForge at exactly one revision, has {sorted(pins)}")
    return pins.pop()


def git(repository: Path, *arguments: str) -> str:
    return run(["git", "-C", repository, *arguments]).strip()


def source_facts() -> dict[str, Any]:
    return {
        "revision": git(REPO, "rev-parse", "HEAD"),
        "clean": git(REPO, "status", "--porcelain", "--untracked-files=normal") == "",
    }


def checked_arkforge_checkout(checkout: Path) -> str:
    """The checkout's HEAD, only when it is clean and equals the pin."""
    require(checkout.is_absolute() and checkout.is_dir(), "--arkforge-checkout must be an absolute directory")
    pin = arkforge_pin()
    head = git(checkout, "rev-parse", "HEAD")
    require(
        head == pin,
        f"ArkForge checkout HEAD {head} is not the revision rust/Cargo.toml pins ({pin}); "
        f"check out {pin} there first",
    )
    require(
        git(checkout, "status", "--porcelain", "--untracked-files=normal") == "",
        "ArkForge checkout has local changes; the bundle must be built from the pinned tree alone",
    )
    return head


def inspect_bundle(bundle: Path, identifier: str, versions: Mapping[str, str]) -> dict[str, Any]:
    require(bundle.is_dir() and not bundle.is_symlink(), f"{bundle} must be a bundle directory")
    info = read_plist(bundle / "Contents/Info.plist")
    require(
        info.get("CFBundleIdentifier") == identifier,
        f"{bundle.name} is {info.get('CFBundleIdentifier')!r}, expected {identifier}",
    )
    actual = (info.get("CFBundleShortVersionString"), info.get("CFBundleVersion"))
    require(
        actual == (versions["version"], versions["build"]),
        f"{bundle.name} carries version {actual[0]} ({actual[1]}), the release is "
        f"{versions['version']} ({versions['build']}); run scripts/release/release_version.py check",
    )
    executable_name = info.get("CFBundleExecutable")
    require(isinstance(executable_name, str) and executable_name, f"{bundle.name} names no executable")
    executable = bundle / "Contents/MacOS" / executable_name
    require(
        executable.is_file() and not executable.is_symlink() and os.access(executable, os.X_OK),
        f"{bundle.name} lacks its executable {executable_name}",
    )
    nested = [path for path in bundle.rglob("*.bundle") if path.name == ARKFORGE]
    require(not nested, f"{bundle.name} must not carry {ARKFORGE}; it ships beside the apps")
    return {
        "bundleIdentifier": identifier,
        "executable": f"Contents/MacOS/{executable_name}",
        "executableSHA256": sha256_file(executable),
        "treeSHA256": tree_sha256(bundle),
    }


def inspect_helpers(cli: Path, versions: Mapping[str, str]) -> dict[str, Any]:
    facts = inspect_bundle(cli, "com.arkdeck.cli", versions)
    daemon = cli / DAEMON
    daemon_facts = inspect_bundle(daemon, "com.arkdeck.agentd", versions)
    require(
        not (daemon / "Contents/MacOS/arkdeck-facade").exists(),
        "the daemon helper still carries the Swift facade; the release ships the Rust daemon alone",
    )
    facts["daemon"] = daemon_facts
    return facts


def inspect_arkforge(bundle: Path) -> dict[str, Any]:
    """The loader's own rules, checked before the bundle is shipped."""
    require(bundle.is_dir() and not bundle.is_symlink(), f"{bundle} must be a directory")
    manifest_path = bundle / ARKFORGE_MANIFEST
    try:
        manifest = json.loads(manifest_path.read_bytes())
    except (OSError, ValueError) as error:
        raise ReleaseError(f"ArkForge manifest is unreadable: {error}") from error
    require(manifest.get("schema") == ARKFORGE_SCHEMA, "ArkForge manifest schema is not " + ARKFORGE_SCHEMA)
    require(bool(manifest.get("version")), "ArkForge manifest version is empty")
    members = manifest.get("members")
    require(isinstance(members, list) and members, "ArkForge manifest declares no member")
    declared: dict[str, dict[str, Any]] = {}
    for member in members:
        path = member.get("path")
        require(isinstance(path, str) and path not in declared, f"ArkForge member path {path!r} is invalid or repeated")
        target = bundle / path
        require(target.is_file() and not target.is_symlink(), f"ArkForge member {path} is missing")
        require(
            target.stat().st_size == member.get("bytes") and sha256_file(target) == member.get("sha256"),
            f"ArkForge member {path} differs from its manifest",
        )
        declared[path] = member
    for executable in ARKFORGE_EXECUTABLES:
        require(executable in declared, f"ArkForge manifest does not declare {executable}")
    for directory, _, names in os.walk(bundle):
        for name in names:
            path = Path(directory, name)
            relative = path.relative_to(bundle).as_posix()
            require(not path.is_symlink(), f"ArkForge bundle carries a link: {relative}")
            require(
                relative == ARKFORGE_MANIFEST or relative in declared,
                f"ArkForge bundle carries {relative}, which its manifest does not declare; "
                "the loader refuses the whole bundle",
            )
    return {
        "manifestSHA256": sha256_file(manifest_path),
        "manifestVersion": manifest["version"],
        "members": sorted(
            ({"path": path, "role": member.get("role"), "sha256": member["sha256"]} for path, member in declared.items()),
            key=lambda item: item["path"],
        ),
        "treeSHA256": tree_sha256(bundle),
    }


# -- nested code ---------------------------------------------------------------

# Thin and fat Mach-O, both byte orders. ELF payloads (the device-side
# arkdeck-code-sign-enable the daemon carries as a resource) are not Mach-O and
# are left to the resource seal: notarization inspects Mach-O only.
MACH_O_MAGICS = frozenset(bytes.fromhex(magic) for magic in (
    "feedface", "cefaedfe", "feedfacf", "cffaedfe", "cafebabe", "bebafeca", "cafebabf", "bfbafeca",
))
GET_TASK_ALLOW = "com.apple.security.get-task-allow"


def mach_o_files(root: Path) -> list[Path]:
    found = []
    for directory, _, names in os.walk(root):
        for name in names:
            path = Path(directory, name)
            if path.is_symlink() or not path.is_file():
                continue
            with path.open("rb") as handle:
                if handle.read(4) in MACH_O_MAGICS:
                    found.append(path)
    return sorted(found)


def signature_problems(display: str, entitlements: str) -> list[str]:
    """What notarization would reject in one signature, from
    `codesign --display --verbose=4` and `--entitlements - --xml` output."""
    lines = display.splitlines()
    field = {line.split("=", 1)[0]: line.split("=", 1)[1] for line in lines if "=" in line}
    problems = []
    if "Signature=adhoc" in lines or "CodeDirectory v" not in field:
        problems.append("is not signed with a Developer ID identity (ad hoc or unsigned)")
    if field.get("TeamIdentifier") != TEAM:
        problems.append(f"is signed by Team {field.get('TeamIdentifier', 'none')}, not {TEAM}")
    flags = re.search(r"\bflags=0x[0-9a-f]+\(([^)]*)\)", field.get("CodeDirectory v", ""))
    if flags is None or "runtime" not in flags.group(1).split(","):
        problems.append("lacks the hardened runtime")
    if "Timestamp" not in field:
        problems.append("lacks a secure timestamp")
    if entitlements.strip():
        try:
            granted = plistlib.loads(entitlements.strip().encode())
        except (plistlib.InvalidFileException, ValueError):
            granted = None
        if not isinstance(granted, dict):
            problems.append("carries unreadable entitlements")
        elif granted.get(GET_TASK_ALLOW) is True:
            problems.append(f"carries {GET_TASK_ALLOW}")
    return problems


def verify_nested_code(root: Path, environment: Mapping[str, str]) -> None:
    """Every Mach-O under `root` — the main executables and anything nested,
    such as the App's trace_streamer — as notarization requires it: Developer
    ID of this Team, hardened runtime, secure timestamp, no get-task-allow.
    `codesign --verify --deep` accepts an ad hoc or untimestamped nested
    signature; this fails fast before an upload Apple would reject."""
    files = mach_o_files(root)
    require(bool(files), f"{root.name} carries no Mach-O code")
    rejected = []
    for path in files:
        relative = f"{root.name}/{path.relative_to(root).as_posix()}"
        try:
            display = run(["codesign", "--display", "--verbose=4", path], env=environment, merge_stderr=True)
        except ReleaseError:
            rejected.append(f"{relative} is not signed")
            continue
        entitlements = run(["codesign", "--display", "--entitlements", "-", "--xml", path], env=environment)
        rejected += [f"{relative} {problem}" for problem in signature_problems(display, entitlements)]
    require(not rejected, "nested code notarization would reject: " + "; ".join(rejected))


# -- release-only build steps --------------------------------------------------


NOTARY_PROFILE = "ARKDECK_NOTARY_KEYCHAIN_PROFILE"
NOTARY_API_KEY = ("ARKDECK_NOTARY_API_KEY_PATH", "ARKDECK_NOTARY_API_KEY_ID", "ARKDECK_NOTARY_API_ISSUER_ID")


def notary_arguments(environment: Mapping[str, str]) -> list[str]:
    """notarytool's credential options: a stored Keychain profile, or an App
    Store Connect API key (`--key --key-id --issuer`), exactly one of the two.
    Only the key's path reaches an argument, never its bytes, and `run` names
    no argument past the subcommand when a call fails."""
    profile = environment.get(NOTARY_PROFILE, "")
    api_key = {name: environment.get(name, "") for name in NOTARY_API_KEY}
    given = [name for name, value in api_key.items() if value]
    require(
        not (profile and given),
        f"notary credentials are {NOTARY_PROFILE} or the API key "
        f"({', '.join(NOTARY_API_KEY)}), not both",
    )
    if profile:
        arguments = ["--keychain-profile", profile]
        if environment.get("ARKDECK_NOTARY_KEYCHAIN"):
            arguments += ["--keychain", environment["ARKDECK_NOTARY_KEYCHAIN"]]
        return arguments
    require(
        bool(given),
        f"release needs notary credentials: {NOTARY_PROFILE}, or the API key "
        f"({', '.join(NOTARY_API_KEY)})",
    )
    missing = [name for name, value in api_key.items() if not value]
    require(not missing, "the notary API key also needs " + ", ".join(missing))
    require(
        not environment.get("ARKDECK_NOTARY_KEYCHAIN"),
        "ARKDECK_NOTARY_KEYCHAIN names where a Keychain profile is stored; an API key has none",
    )
    key = Path(api_key["ARKDECK_NOTARY_API_KEY_PATH"])
    require(
        key.is_absolute() and key.is_file() and not key.is_symlink(),
        "ARKDECK_NOTARY_API_KEY_PATH must be an absolute path to the .p8 key file",
    )
    return ["--key", str(key), "--key-id", api_key["ARKDECK_NOTARY_API_KEY_ID"],
            "--issuer", api_key["ARKDECK_NOTARY_API_ISSUER_ID"]]


def codesign_keychain(environment: Mapping[str, str]) -> str | None:
    """ARKDECK_CODESIGN_KEYCHAIN: the keychain that holds the identity, such
    as the release-rc workflow's temporary one. codesign calls this script
    and its helper builder make are given `--keychain`, and the App archive
    gets it through OTHER_CODE_SIGN_FLAGS; `xcodebuild -exportArchive` and
    ArkForge's packager take no keychain option and find the identity on the
    user search list, so the keychain must be on it."""
    keychain = environment.get("ARKDECK_CODESIGN_KEYCHAIN", "")
    if not keychain:
        return None
    path = Path(keychain)
    require(
        path.is_absolute() and path.is_file() and not re.search(r"\s", keychain),
        "ARKDECK_CODESIGN_KEYCHAIN must be an absolute keychain file path without whitespace",
    )
    return keychain


def keychain_arguments(environment: Mapping[str, str]) -> list[str]:
    keychain = codesign_keychain(environment)
    return ["--keychain", keychain] if keychain else []


def notarize(path: Path, environment: Mapping[str, str], log_path: Path) -> dict[str, str]:
    output = run(
        ["xcrun", "notarytool", "submit", path, *notary_arguments(environment),
         "--wait", "--output-format", "json"],
        env=environment, timeout=NOTARY_TIMEOUT,
    )
    try:
        submission = json.loads(output)
    except ValueError as error:
        raise ReleaseError(f"notarytool returned no JSON for {path.name}") from error
    identifier = str(submission.get("id") or "")
    require(bool(identifier), f"notarytool named no submission for {path.name}")
    run(["xcrun", "notarytool", "log", identifier, log_path, *notary_arguments(environment)], env=environment)
    require(
        submission.get("status") == "Accepted",
        f"{path.name} notarization {identifier} is {submission.get('status')!r}; see {log_path.name}",
    )
    return {"submissionId": identifier, "status": "Accepted"}


def preflight_release(environment: Mapping[str, str], identity: str) -> None:
    missing = [
        name for name in (
            "ARKDECK_CLI_PROVISIONING_PROFILE", "ARKDECK_DAEMON_PROVISIONING_PROFILE",
        ) if not environment.get(name)
    ]
    require(not missing, "release needs " + ", ".join(missing))
    notary = notary_arguments(environment)
    keychain = codesign_keychain(environment)
    if keychain is not None:
        search_list = run(["security", "list-keychains", "-d", "user"], env=environment)
        listed = {os.path.realpath(line.strip().strip('"')) for line in search_list.splitlines() if line.strip()}
        require(
            os.path.realpath(keychain) in listed,
            "ARKDECK_CODESIGN_KEYCHAIN is not on the user keychain search list; "
            "xcodebuild -exportArchive and ArkForge's packager find the identity only there",
        )
    identities = run(["security", "find-identity", "-v", "-p", "codesigning",
                      *([keychain] if keychain else [])], env=environment)
    require(identity in identities, f"signing identity {identity!r} is not in the keychain")
    # Credentials are checked before anything is built, not after an hour of it.
    run(["xcrun", "notarytool", "history", *notary, "--output-format", "json"],
        env=environment)


def build_helpers(work: Path, environment: Mapping[str, str], identity: str) -> Path:
    output = work / "helpers"
    helper_environment = dict(environment)
    helper_environment.update({
        "ARKDECK_HELPER_OUTPUT": str(output),
        "ARKDECK_CODESIGN_IDENTITY": identity,
    })
    run(["/bin/bash", HELPER_BUILDER], env=helper_environment, capture=False, timeout=NOTARY_TIMEOUT)
    require(sorted(item.name for item in output.iterdir()) == [CLI],
            f"build-helpers.sh must produce {CLI} alone")
    return output / CLI


def build_arkforge(work: Path, checkout: Path, environment: Mapping[str, str], identity: str) -> Path:
    output = work / ARKFORGE
    arkforge_environment = dict(environment)
    arkforge_environment.update({
        "ARKFORGE_CODESIGN_IDENTITY": identity,
        "ARKFORGE_PACKAGE_OUTPUT": str(output),
    })
    run(["/bin/bash", checkout / "packaging/macos/package-arkforge.sh"],
        env=arkforge_environment, cwd=checkout, capture=False)
    return output


def build_app(work: Path, environment: Mapping[str, str]) -> Path:
    archive = work / "ArkDeck.xcarchive"
    export = work / "export"
    keychain = codesign_keychain(environment)
    # A command-line setting replaces the project's, so the Release
    # configuration's own `--timestamp` is restated beside the keychain.
    signing = [f"OTHER_CODE_SIGN_FLAGS=--timestamp --keychain {keychain}"] if keychain else []
    run(["xcodebuild", "-project", PROJECT, "-scheme", "ArkDeck", "-configuration", "Release",
         "-destination", "generic/platform=macOS", "-derivedDataPath", work / "DerivedData",
         "-archivePath", archive, *signing, "archive"],
        env=environment, cwd=REPO, capture=False)
    run(["xcodebuild", "-exportArchive", "-archivePath", archive,
         "-exportOptionsPlist", EXPORT_OPTIONS, "-exportPath", export],
        env=environment, cwd=REPO, capture=False)
    app = export / APP
    require(app.is_dir(), f"the Developer ID export produced no {APP}")
    run(["codesign", "--verify", "--strict", "--deep", "--verbose=2", app], env=environment)
    return app


def notarize_app(work: Path, app: Path, environment: Mapping[str, str], logs: Path) -> dict[str, str]:
    archive = work / "ArkDeck-notarization.zip"
    run(["ditto", "-c", "-k", "--keepParent", app, archive], env=environment)
    result = notarize(archive, environment, logs / "notary-log-app.json")
    archive.unlink()
    run(["xcrun", "stapler", "staple", app], env=environment)
    run(["spctl", "--assess", "--type", "execute", "--verbose=2", app], env=environment)
    return result


# -- shared assembly and verification ------------------------------------------


def stage(root: Path, app: Path, cli: Path, arkforge: Path, unsigned: bool,
          environment: Mapping[str, str]) -> None:
    root.mkdir(mode=0o755)
    for source, name in ((app, APP), (cli, CLI), (arkforge, ARKFORGE)):
        run(["ditto", "--noqtn", source, root / name], env=environment)
    shutil.copyfile(INSTALL_GUIDE, root / GUIDE)
    os.chmod(root / GUIDE, 0o644)
    if unsigned:
        (root / MARKER).write_text(MARKER_TEXT)
        os.chmod(root / MARKER, 0o644)


def expected_entries(unsigned: bool) -> list[str]:
    return sorted([APP, CLI, ARKFORGE, GUIDE] + ([MARKER] if unsigned else []))


def attach(dmg: Path, mountpoint: Path, environment: Mapping[str, str]) -> str:
    output = run(["hdiutil", "attach", "-readonly", "-nobrowse", "-noautoopen",
                  "-mountpoint", mountpoint, "-plist", dmg], env=environment)
    try:
        entities = plistlib.loads(output.encode()).get("system-entities", [])
    except (plistlib.InvalidFileException, ValueError) as error:
        raise ReleaseError("hdiutil attach returned no plist") from error
    # hdiutil reports the mount point with symbolic links resolved (a runner's
    # TMPDIR is under /var/folders, reported as /private/var/folders), so both
    # sides are compared resolved.
    wanted = os.path.realpath(mountpoint)
    for entity in entities:
        if entity.get("mount-point") and entity.get("dev-entry") \
                and os.path.realpath(entity["mount-point"]) == wanted:
            return str(entity["dev-entry"])
    # Never leave an image attached that this script cannot account for.
    for entity in entities:
        if entity.get("dev-entry") and entity.get("mount-point"):
            try:
                run(["hdiutil", "detach", "-force", entity["dev-entry"]], env=environment)
            except ReleaseError:
                pass
    raise ReleaseError("hdiutil attach did not report the requested mount point")


def daemon_requirement(versions: Mapping[str, str]) -> str:
    """ArkDeckAgentXPC.serverCodeRequirement for this release's App."""
    return (
        f'{ANCHOR} and identifier "com.arkdeck.agentd" '
        f'and info[CFBundleShortVersionString] = "{versions["version"]}" '
        f'and info[CFBundleVersion] = "{versions["build"]}"'
    )


def verify_mounted(mount: Path, staged: Mapping[str, str], unsigned: bool, versions: Mapping[str, str],
                   environment: Mapping[str, str]) -> None:
    entries = sorted(item.name for item in mount.iterdir() if not item.name.startswith("."))
    require(entries == expected_entries(unsigned), f"the DMG holds {entries}, expected {expected_entries(unsigned)}")
    for name, digest in staged.items():
        require(tree_sha256(mount / name) == digest, f"{name} in the mounted DMG differs from what was staged")
    if unsigned:
        return
    app, cli = mount / APP, mount / CLI
    for bundle in (app, cli):
        run(["codesign", "--verify", "--strict", "--deep", "--verbose=2", bundle], env=environment)
        run(["spctl", "--assess", "--type", "execute", "--verbose=2", bundle], env=environment)
        run(["xcrun", "stapler", "validate", bundle], env=environment)
    run(["codesign", "--verify", "--strict", "-R", f'={ANCHOR} and identifier "com.arkdeck.desktop"', app],
        env=environment)
    run(["codesign", "--verify", "--strict", "-R", f'={ANCHOR} and identifier "com.arkdeck.cli"', cli],
        env=environment)
    run(["codesign", "--verify", "--strict", "-R", "=" + daemon_requirement(versions), cli / DAEMON],
        env=environment)
    for executable in ARKFORGE_EXECUTABLES:
        run(["codesign", "--verify", "--strict", "-R", f"={ANCHOR}", mount / ARKFORGE / executable],
            env=environment)
    for name in (APP, CLI, ARKFORGE):
        verify_nested_code(mount / name, environment)


def build(mode: str, arguments: argparse.Namespace, environment: Mapping[str, str]) -> Path:
    unsigned = mode == "unsigned"
    output: Path = arguments.output
    require(output.is_absolute(), "--output must be an absolute path")
    require(not output.exists() and not output.is_symlink(), f"output already exists: {output}")
    require(output.parent.is_dir(), f"the output's parent must exist: {output.parent}")
    problems = release_version.drift()
    require(not problems, "release version drift: " + "; ".join(problems))
    versions = release_version.load()
    source = source_facts()
    identity = environment.get("ARKDECK_CODESIGN_IDENTITY") or DEFAULT_IDENTITY
    arkforge_revision = None
    if arguments.arkforge_checkout is not None:
        arkforge_revision = checked_arkforge_checkout(arguments.arkforge_checkout)
    if not unsigned:
        require(source["clean"], "the release is built from a clean checkout; commit or remove local changes")
        require(arkforge_revision is not None, "release needs --arkforge-checkout")
        preflight_release(environment, identity)

    temporary = Path(tempfile.mkdtemp(prefix="arkdeck-release.", dir=environment.get("TMPDIR") or None))
    device: str | None = None
    try:
        work = temporary / "work"
        work.mkdir()
        publish = temporary / "output"
        publish.mkdir()
        notarization: dict[str, Any] | None = None
        if unsigned:
            app, cli, arkforge = arguments.app, arguments.helpers / CLI, arguments.arkforge_bundle
            for path, flag in ((app, "--app"), (arguments.helpers, "--helpers"), (arkforge, "--arkforge-bundle")):
                require(path.is_absolute(), f"{flag} must be an absolute path")
        else:
            cli = build_helpers(work, environment, identity)
            verify_nested_code(cli, environment)
            arkforge = build_arkforge(work, arguments.arkforge_checkout, environment, identity)
            verify_nested_code(arkforge, environment)
            app = build_app(work, environment)
            # Before the upload: an exported App whose nested helper lost its
            # hardened runtime or timestamp fails here, not at Apple.
            verify_nested_code(app, environment)
            notarization = {"app": notarize_app(work, app, environment, publish)}

        components = {
            APP: inspect_bundle(app, "com.arkdeck.desktop", versions),
            CLI: inspect_helpers(cli, versions),
            ARKFORGE: inspect_arkforge(arkforge),
        }
        root = work / "dmg-root"
        stage(root, app, cli, arkforge, unsigned, environment)
        staged = {name: tree_sha256(root / name) for name in (APP, CLI, ARKFORGE)}
        for name, digest in staged.items():
            require(digest == components[name]["treeSHA256"], f"{name} changed while it was copied into the DMG")

        suffix = "-unsigned" if unsigned else ""
        dmg = publish / f"ArkDeck-{versions['version']}-{versions['build']}{suffix}.dmg"
        create_dmg(["hdiutil", "create", "-volname", f"ArkDeck {versions['version']}", "-srcfolder", root,
                    "-fs", "HFS+", "-format", "UDZO", "-imagekey", "zlib-level=9", dmg], dmg, environment)
        if not unsigned:
            run(["codesign", "--force", "--sign", identity, "--timestamp", *keychain_arguments(environment), dmg],
                env=environment)
            run(["codesign", "--verify", "--strict", "--verbose=2", "-R", f"={ANCHOR}", dmg], env=environment)
            run(["hdiutil", "verify", dmg], env=environment)
            notarization["dmg"] = notarize(dmg, environment, publish / "notary-log-dmg.json")
            run(["xcrun", "stapler", "staple", dmg], env=environment)
            run(["xcrun", "stapler", "validate", dmg], env=environment)
            run(["spctl", "--assess", "--type", "open", "--context", "context:primary-signature",
                 "--verbose=2", dmg], env=environment)

        mount = work / "mount"
        mount.mkdir()
        device = attach(dmg, mount, environment)
        verify_mounted(mount, staged, unsigned, versions, environment)
        run(["hdiutil", "detach", device], env=environment)
        device = None

        receipt = {
            "schema": RECEIPT_SCHEMA,
            "mode": "unsigned-structure-check" if unsigned else "release",
            "version": versions["version"],
            "build": versions["build"],
            "source": source,
            "arkforge": {
                "pinnedRevision": arkforge_pin(),
                "builtRevision": None if unsigned else arkforge_revision,
                "checkoutRevision": arkforge_revision,
                **components[ARKFORGE],
            },
            "dmg": {
                "name": dmg.name,
                "sha256": sha256_file(dmg),
                "bytes": dmg.stat().st_size,
                "entries": expected_entries(unsigned),
                "signed": not unsigned,
                "stapled": not unsigned,
            },
            "components": {APP: components[APP], CLI: components[CLI]},
            "notarization": notarization,
        }
        (publish / RECEIPT).write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n")
        if unsigned:
            (publish / MARKER).write_text(MARKER_TEXT)
        shutil.move(str(publish), str(output))
        return output / dmg.name
    finally:
        if device is not None:
            try:
                run(["hdiutil", "detach", "-force", device], env=environment)
            except ReleaseError as error:
                print(f"build_macos_release: {error}", file=sys.stderr)
        shutil.rmtree(temporary, ignore_errors=True)


def parse(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    modes = parser.add_subparsers(dest="mode", required=True)
    release = modes.add_parser("release", help="maintainer: sign, notarize and staple the RC")
    release.add_argument("--output", type=Path, required=True)
    release.add_argument("--arkforge-checkout", type=Path, required=True)
    unsigned = modes.add_parser("unsigned", help="structure check of prebuilt components; signs nothing")
    unsigned.add_argument("--output", type=Path, required=True)
    unsigned.add_argument("--app", type=Path, required=True)
    unsigned.add_argument("--helpers", type=Path, required=True)
    unsigned.add_argument("--arkforge-bundle", type=Path, required=True)
    unsigned.add_argument("--arkforge-checkout", type=Path)
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    arguments = parse(sys.argv[1:] if argv is None else argv)
    try:
        dmg = build(arguments.mode, arguments, os.environ)
    except (ReleaseError, OSError) as error:
        print(f"build_macos_release: {error}", file=sys.stderr)
        return 1
    if arguments.mode == "unsigned":
        print("unsigned structure check; not for distribution", file=sys.stderr)
    print(dmg)
    return 0


if __name__ == "__main__":
    sys.exit(main())
