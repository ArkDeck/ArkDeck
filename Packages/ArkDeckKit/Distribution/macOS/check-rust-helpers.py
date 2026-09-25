#!/usr/bin/env python3
"""Check the unsigned Rust helper pair that build-unsigned-rust-helpers.sh lays out.

CHG-2026-074 M5, G5 slice 20a. The Rust release (build-helpers.sh with
ARKDECK_HELPER_RUNTIME=rust) and the unsigned structure build share one
layout-and-signing step, package-rust-helpers.sh. Signed ad hoc, its output is
checked here without any signing identity:

- the exact file tree of ArkDeckCLI.app and its nested ArkDeckAgent.app, which
  carries no facade, and the output root's unsigned marker;
- each Info.plist byte for byte as Distribution/macOS ships it, with the
  versions the App's XPC server requirement pins equal to the App's
  MARKETING_VERSION and CURRENT_PROJECT_VERSION;
- the placeholder where the release embeds each provisioning profile, and the
  OpenHarmony code-sign helper byte for byte where the Rust daemon looks for it;
- thin arm64 executables, owner-only;
- the signatures: strict deep verification, each bundle's identifier and bound
  Info.plist (`codesign -R`), the hardened runtime, the entitlements exactly as
  the Distribution files declare them, and no Developer ID anchor;
- what `runtime service update` asks of a Rust daemon before installing it:
  `--cutover-preflight` in an empty relocated home, clear and writing nothing,
  and `--analyze-crash-ledger` printing Swift's recorded answer to the CLI's
  probe listing byte for byte;
- the packaged Rust CLI's own `runtime service update`, taking the packaged
  daemon bundle through the production helper validator in an empty relocated
  home: refused at the signature alone, before launchd is asked anything;
- a retained rollback helper, when there is one: the Swift daemon behind its
  facade, intact.

The kernel kills an executable signed ad hoc that carries these restricted
entitlements, so the two executables run from copies re-signed ad hoc without
entitlements; each copy holds the packaged executable's bytes once both
signatures are removed, which is checked too.

Usage: check-rust-helpers.py [--expect-rollback] <output-root>
(--expect-rollback when ARKDECK_ROLLBACK_HELPER named a helper to retain.)
Exit status: 0 when every check holds, 1 naming each one that does not, 2 on
a usage error.
"""

from __future__ import annotations

import base64
import json
import os
import plistlib
import re
import shlex
import shutil
import stat
import subprocess
import sys
import tempfile
from pathlib import Path

DISTRIBUTION = Path(__file__).resolve().parent
REPO = DISTRIBUTION.parents[3]
CODE_SIGN_HELPER_SOURCE = (
    REPO
    / "Packages/ArkDeckKit/Sources/ArkDeckWorkflows/Resources/OpenHarmonyNativeCodeSign"
    / "arkdeck-code-sign-enable"
)
ANALYZER_ORACLE = REPO / "rust/tests/fixtures/crash-ledger-analyzer/oracle.json"
APP_PROJECT = REPO / "ArkDeck.xcodeproj/project.pbxproj"

CODESIGN = "/usr/bin/codesign"
LIPO = "/usr/bin/lipo"
MARKER = "UNSIGNED-STRUCTURE-CHECK-ONLY.txt"
MARKER_TEXT = (
    b"UNSIGNED STRUCTURE CHECK ONLY: signed ad hoc with placeholder provisioning "
    b"profiles, no timestamp and no notarization. Never distribute or install it.\n"
)
CLI = "ArkDeckCLI.app"
DAEMON = "Contents/Helpers/ArkDeckAgent.app"
CODE_SIGN_HELPER = (
    "Contents/Resources/ArkDeckKit_ArkDeckWorkflows.bundle/OpenHarmonyNativeCodeSign"
    "/arkdeck-code-sign-enable"
)
TEAM = "8AQTYW5FKR"
PREFLIGHT_SCHEMA = "arkdeck.cutover-preflight/1"
ANALYZER_PROBE = "runtime-service-probe"
SIGNATURE_REFUSAL = b"arkdeck-agentd helper signature does not match ArkDeck"
TIMEOUT_SECONDS = 120

CLI_FILES = frozenset({
    "Contents/Info.plist",
    "Contents/embedded.provisionprofile",
    "Contents/MacOS/arkdeck",
    "Contents/_CodeSignature/CodeResources",
    f"{DAEMON}/Contents/Info.plist",
    f"{DAEMON}/Contents/embedded.provisionprofile",
    f"{DAEMON}/Contents/MacOS/arkdeck-agentd",
    f"{DAEMON}/{CODE_SIGN_HELPER}",
    f"{DAEMON}/Contents/_CodeSignature/CodeResources",
})


class Report:
    def __init__(self) -> None:
        self.passed = 0
        self.failures: list[str] = []

    def check(self, condition: bool, what: str) -> bool:
        if condition:
            self.passed += 1
        else:
            self.failures.append(what)
        return condition


def run(arguments: list[str], environment: dict[str, str] | None = None) -> subprocess.CompletedProcess:
    return subprocess.run(
        arguments,
        capture_output=True,
        env=environment,
        timeout=TIMEOUT_SECONDS,
        check=False,
    )


def placeholder(identifier: str) -> bytes:
    return (
        f"ArkDeck unsigned structure check: placeholder for the {identifier} "
        "provisioning profile; it authorizes nothing\n"
    ).encode()


def tree(root: Path) -> tuple[set[str], set[str], set[str]]:
    """Regular files, directories and anything else below `root`, unfollowed."""
    files: set[str] = set()
    directories: set[str] = set()
    others: set[str] = set()
    for directory, subdirectories, names in os.walk(root):
        for name in subdirectories + names:
            path = Path(directory, name)
            relative = path.relative_to(root).as_posix()
            mode = path.lstat().st_mode
            if stat.S_ISDIR(mode):
                directories.add(relative)
            elif stat.S_ISREG(mode):
                files.add(relative)
            else:
                others.add(relative)
    return files, directories, others


def parents(paths: frozenset[str]) -> set[str]:
    result: set[str] = set()
    for path in paths:
        parts = path.split("/")[:-1]
        for index in range(1, len(parts) + 1):
            result.add("/".join(parts[:index]))
    return result


def app_versions() -> tuple[set[str], set[str]]:
    text = APP_PROJECT.read_text(encoding="utf-8")
    return (
        set(re.findall(r"\bMARKETING_VERSION = ([^;\s]+);", text)),
        set(re.findall(r"\bCURRENT_PROJECT_VERSION = ([^;\s]+);", text)),
    )


def signing_details(bundle: Path) -> tuple[int, str]:
    result = run([CODESIGN, "-dv", "--verbose=4", str(bundle)])
    return result.returncode, result.stderr.decode(errors="replace")


def field(details: str, name: str) -> str | None:
    match = re.search(rf"^{re.escape(name)}=(.*)$", details, re.MULTILINE)
    return match.group(1) if match else None


def signed_entitlements(code: Path) -> object:
    result = run([CODESIGN, "-d", "--entitlements", "-", "--xml", str(code)])
    if result.returncode != 0:
        return "unreadable"
    if not result.stdout.strip():
        return None
    return plistlib.loads(result.stdout)


def requirement_status(code: Path, requirement: str, *, deep: bool = False) -> int:
    """codesign's answer: 0 satisfied, 3 a valid requirement not satisfied."""
    arguments = [CODESIGN, "--verify", "--strict"]
    if deep:
        arguments.append("--deep")
    return run(arguments + ["-R", f"={requirement}", str(code)]).returncode


def satisfies(code: Path, requirement: str, *, deep: bool = False) -> bool:
    return requirement_status(code, requirement, deep=deep) == 0


def check_layout(report: Report, root: Path) -> bool:
    entries = {entry.name for entry in root.iterdir()}
    expected = {CLI, MARKER} | ({"rollback"} & entries)
    report.check(
        entries == expected,
        f"the output root holds {sorted(entries)}, not {sorted(expected)}",
    )
    marker = root / MARKER
    report.check(
        marker.is_file() and marker.read_bytes() == MARKER_TEXT,
        f"{MARKER} does not say the output is unsigned and never to be distributed",
    )
    cli = root / CLI
    if not report.check(cli.is_dir() and not cli.is_symlink(), f"{CLI} is missing"):
        return False
    files, directories, others = tree(cli)
    report.check(not others, f"{CLI} holds links or special files: {sorted(others)}")
    report.check(
        files == CLI_FILES,
        f"{CLI} files differ: missing {sorted(CLI_FILES - files)}, "
        f"unexpected {sorted(files - CLI_FILES)}",
    )
    report.check(
        directories == parents(CLI_FILES),
        f"{CLI} directories differ: missing {sorted(parents(CLI_FILES) - directories)}, "
        f"unexpected {sorted(directories - parents(CLI_FILES))}",
    )
    report.check(
        not (cli / DAEMON / "Contents/MacOS/arkdeck-facade").exists(),
        "the Rust daemon bundle carries a facade, which `runtime service update` refuses",
    )
    return True


def check_contents(report: Report, cli: Path) -> tuple[str, str] | None:
    daemon = cli / DAEMON
    marketing, build = app_versions()
    report.check(
        len(marketing) == 1 and len(build) == 1,
        f"the App project pins no single version: MARKETING_VERSION {sorted(marketing)}, "
        f"CURRENT_PROJECT_VERSION {sorted(build)}",
    )
    versions = (next(iter(marketing)), next(iter(build))) if marketing and build else None
    for bundle, source, identifier, executable in (
        (cli, "ArkDeckCLI-Info.plist", "com.arkdeck.cli", "arkdeck"),
        (daemon, "ArkDeckAgent-Info.plist", "com.arkdeck.agentd", "arkdeck-agentd"),
    ):
        info_path = bundle / "Contents/Info.plist"
        if not info_path.is_file():
            continue
        info_bytes = info_path.read_bytes()
        report.check(
            info_bytes == (DISTRIBUTION / source).read_bytes(),
            f"{bundle.name}'s Info.plist is not Distribution/macOS/{source}",
        )
        info = plistlib.loads(info_bytes)
        for key, expected in (
            ("CFBundleIdentifier", identifier),
            ("CFBundleExecutable", executable),
            ("CFBundlePackageType", "APPL"),
            ("LSBackgroundOnly", True),
        ):
            report.check(
                info.get(key) == expected,
                f"{bundle.name} Info.plist {key} is {info.get(key)!r}, not {expected!r}",
            )
        if versions:
            report.check(
                (info.get("CFBundleShortVersionString"), info.get("CFBundleVersion")) == versions,
                f"{bundle.name} Info.plist version "
                f"{info.get('CFBundleShortVersionString')!r}/{info.get('CFBundleVersion')!r} is "
                f"not the App's {versions[0]!r}/{versions[1]!r} "
                "(ArkDeck.xcodeproj), which the App's XPC server requirement pins",
            )
        profile = bundle / "Contents/embedded.provisionprofile"
        report.check(
            profile.is_file() and profile.read_bytes() == placeholder(identifier),
            f"{bundle.name} does not embed the {identifier} provisioning profile placeholder",
        )
        program = bundle / "Contents/MacOS" / executable
        if program.is_file():
            report.check(
                stat.S_IMODE(program.stat().st_mode) == 0o700,
                f"{executable} is {oct(stat.S_IMODE(program.stat().st_mode))}, not owner-only 0o700",
            )
            archs = run([LIPO, "-archs", str(program)]).stdout.decode().split()
            report.check(archs == ["arm64"], f"{executable} is {archs}, not thin arm64")
    helper = daemon / CODE_SIGN_HELPER
    report.check(
        helper.is_file() and helper.read_bytes() == CODE_SIGN_HELPER_SOURCE.read_bytes(),
        "the daemon's OpenHarmony code-sign helper is not the tracked resource byte for byte",
    )
    return versions


def check_signatures(report: Report, cli: Path, versions: tuple[str, str] | None) -> None:
    daemon = cli / DAEMON
    report.check(
        run([CODESIGN, "--verify", "--strict", "--deep", "--verbose=2", str(cli)]).returncode == 0,
        f"{CLI} does not pass strict deep signature verification",
    )
    for bundle, identifier, source in (
        (cli, "com.arkdeck.cli", "ArkDeckCLI.entitlements"),
        (daemon, "com.arkdeck.agentd", "ArkDeckAgent.entitlements"),
    ):
        status, details = signing_details(bundle)
        report.check(status == 0, f"{bundle.name}'s signature cannot be read")
        info_path = bundle / "Contents/Info.plist"
        info = plistlib.loads(info_path.read_bytes()) if info_path.is_file() else {}
        for name, expected in (
            ("Identifier", identifier),
            ("Format", "app bundle with Mach-O thin (arm64)"),
            ("Signature", "adhoc"),
            ("TeamIdentifier", "not set"),
            ("Info.plist entries", str(len(info))),
        ):
            report.check(
                field(details, name) == expected,
                f"{bundle.name} signature {name} is {field(details, name)!r}, not {expected!r}",
            )
        flags = re.search(r"^CodeDirectory .*flags=0x[0-9a-f]+\(([^)]*)\)", details, re.MULTILINE)
        report.check(
            flags is not None and {"adhoc", "runtime"} <= set(flags.group(1).split(",")),
            f"{bundle.name} is not signed with the hardened runtime",
        )
        report.check(
            re.search(r"^Sealed Resources version=2 ", details, re.MULTILINE) is not None,
            f"{bundle.name} seals no resources",
        )
        if versions:
            bound = (
                f'identifier "{identifier}" and info[CFBundleIdentifier] = "{identifier}" '
                f'and info[CFBundleShortVersionString] = "{versions[0]}" '
                f'and info[CFBundleVersion] = "{versions[1]}"'
            )
            report.check(
                satisfies(bundle, bound),
                f"{bundle.name} is not signed as {identifier} over its own Info.plist and versions",
            )
        # The production requirement itself, which the helper validator and the
        # App's XPC peer check hold the release to: an ad hoc signature fails it.
        report.check(
            requirement_status(
                bundle,
                f'anchor apple generic and certificate leaf[subject.OU] = "{TEAM}" '
                f'and identifier "{identifier}"',
            )
            == 3,
            f"{bundle.name} does not fail the Developer ID requirement as an unsigned output must",
        )
        declared = plistlib.loads((DISTRIBUTION / source).read_bytes())
        report.check(
            signed_entitlements(bundle) == declared,
            f"{bundle.name}'s signed entitlements are not Distribution/macOS/{source}",
        )


def runnable_copy(report: Report, program: Path, work: Path) -> Path | None:
    """`program` re-signed ad hoc without entitlements, so the kernel runs it."""
    if not report.check(program.is_file(), f"{program.name} is missing, so it cannot be run"):
        return None
    copy = work / program.name
    shutil.copyfile(program, copy)
    copy.chmod(0o700)
    if not report.check(
        run([CODESIGN, "--force", "--sign", "-", str(copy)]).returncode == 0,
        f"{program.name} cannot be re-signed to run",
    ):
        return None
    report.check(signed_entitlements(copy) is None, f"the runnable {program.name} keeps entitlements")
    stripped = []
    for source in (program, copy):
        target = work / f"{program.name}.{len(stripped)}.unsigned"
        shutil.copyfile(source, target)
        run([CODESIGN, "--remove-signature", str(target)])
        stripped.append(target.read_bytes())
    report.check(
        stripped[0] == stripped[1],
        f"the runnable {program.name} is not the packaged one with its signature replaced",
    )
    return copy


def private_home(work: Path, name: str) -> Path:
    home = work / name
    home.mkdir()
    return home.resolve()


def check_daemon_answers(report: Report, daemon: Path, work: Path) -> None:
    home = private_home(work, "preflight-home")
    result = run(
        [str(daemon), "--cutover-preflight"],
        {"HOME": str(home), "CFFIXED_USER_HOME": str(home), "ARKDECK_RUNTIME_COMPOSITION": "production"},
    )
    report.check(
        result.returncode == 0,
        f"--cutover-preflight exited {result.returncode}: {result.stderr.decode(errors='replace')}",
    )
    try:
        document = json.loads(result.stdout)
    except ValueError:
        document = None
    state = home / "Library/Application Support/ArkDeck/Agentd"
    report.check(
        isinstance(document, dict)
        and document.get("schemaVersion") == PREFLIGHT_SCHEMA
        and document.get("clear") is True
        and document.get("blocks") == []
        and document.get("instanceLockHeld") is False
        and document.get("stateDirectory") == str(state),
        f"--cutover-preflight answered no clear {PREFLIGHT_SCHEMA} document over {state}: "
        f"{result.stdout[:512]!r}",
    )
    report.check(not any(home.iterdir()), "--cutover-preflight wrote into the home it read")

    oracle = json.loads(ANALYZER_ORACLE.read_text(encoding="utf-8"))
    case = next((case for case in oracle["cases"] if case["name"] == ANALYZER_PROBE), None)
    if not report.check(case is not None, f"the analyzer oracle lost its {ANALYZER_PROBE} case"):
        return
    listing = work / "crash-index.txt"
    listing.write_bytes(base64.b64decode(case["input"]))
    listing.chmod(case["inputMode"])
    metadata = listing.stat()
    alias = f"/.vol/{metadata.st_dev}/{metadata.st_ino}"
    arguments = [
        argument.replace("{inputVolume}", alias).replace("{input}", str(listing))
        for argument in case["arguments"]
    ]
    result = run([str(daemon), *arguments], {})
    report.check(
        (result.returncode, result.stdout, result.stderr)
        == (case["exitStatus"], case["stdout"].encode(), case["stderr"].encode()),
        f"--analyze-crash-ledger does not answer the CLI's probe listing as Swift's analyzer "
        f"({ANALYZER_PROBE}): exit {result.returncode}, {result.stdout[:512]!r}",
    )


def check_cli_update(report: Report, cli_program: Path, daemon_bundle: Path, work: Path) -> None:
    home = private_home(work, "update-home")
    log = work / "launchctl.log"
    launchctl = work / "launchctl"
    launchctl.write_text(
        f'#!/bin/sh\nprintf "%s\\n" "$*" >> {shlex.quote(str(log))}\nexit 113\n',
        encoding="utf-8",
    )
    launchctl.chmod(0o700)
    result = run(
        [
            str(cli_program), "runtime", "service", "update",
            "--daemon", str(daemon_bundle), "--hdc", "/usr/bin/true",
            "--arktrace-descriptor", "none", "--arkforge-bundle", "none", "--json",
        ],
        {
            "HOME": str(home),
            "CFFIXED_USER_HOME": str(home),
            "ARKDECK_LAUNCHCTL_FOR_RELOCATED_HOME": str(launchctl),
        },
    )
    report.check(
        result.returncode == 1 and not result.stdout and SIGNATURE_REFUSAL in result.stderr,
        "the packaged CLI's `runtime service update` does not refuse the packaged daemon "
        f"bundle at its signature alone: exit {result.returncode}, "
        f"{result.stderr.decode(errors='replace').strip()!r}",
    )
    calls = log.read_text(encoding="utf-8").splitlines() if log.exists() else []
    report.check(
        all(call.startswith("print ") for call in calls),
        f"`runtime service update` asked launchd more than whether the service is loaded: {calls}",
    )
    report.check(not any(home.iterdir()), "`runtime service update` wrote into the home it refused")


def check_rollback(report: Report, root: Path, expected: bool) -> None:
    rollback_root = root / "rollback"
    if not report.check(
        rollback_root.exists() or not expected,
        "no rollback helper was retained although one was asked for",
    ) or not rollback_root.exists():
        return
    entries = sorted(entry.name for entry in rollback_root.iterdir())
    report.check(entries == ["ArkDeckAgent.app"], f"rollback/ holds {entries}, not one ArkDeckAgent.app")
    bundle = rollback_root / "ArkDeckAgent.app"
    info_path = bundle / "Contents/Info.plist"
    info = plistlib.loads(info_path.read_bytes()) if info_path.is_file() else {}
    report.check(
        (info.get("CFBundleIdentifier"), info.get("CFBundleExecutable"))
        == ("com.arkdeck.agentd", "arkdeck-agentd"),
        "the retained rollback helper is not an ArkDeck daemon bundle",
    )
    for name in ("arkdeck-agentd", "arkdeck-facade"):
        program = bundle / "Contents/MacOS" / name
        report.check(
            program.is_file() and os.access(program, os.X_OK),
            f"the retained rollback helper lacks {name}: it must be the Swift daemon behind its facade",
        )
    report.check(
        run([CODESIGN, "--verify", "--strict", "--deep", str(bundle)]).returncode == 0
        and satisfies(bundle, 'identifier "com.arkdeck.agentd"', deep=True)
        and satisfies(bundle / "Contents/MacOS/arkdeck-facade", 'identifier "com.arkdeck.agentd.facade"'),
        "the retained rollback helper is no longer intact as signed",
    )


def main(arguments: list[str]) -> int:
    expect_rollback = "--expect-rollback" in arguments
    arguments = [argument for argument in arguments if argument != "--expect-rollback"]
    if len(arguments) != 1 or not Path(arguments[0]).is_absolute():
        print(
            "usage: check-rust-helpers.py [--expect-rollback] <absolute output root>",
            file=sys.stderr,
        )
        return 2
    if sys.platform != "darwin":
        print("the helper pair is checked on macOS only", file=sys.stderr)
        return 2
    root = Path(arguments[0])
    if not root.is_dir():
        print(f"no output root at {root}", file=sys.stderr)
        return 2
    report = Report()
    if check_layout(report, root):
        cli = root / CLI
        versions = check_contents(report, cli)
        check_signatures(report, cli, versions)
        with tempfile.TemporaryDirectory(prefix="arkdeck-rust-helper-check.") as scratch:
            work = Path(scratch).resolve()
            daemon = runnable_copy(report, cli / DAEMON / "Contents/MacOS/arkdeck-agentd", work)
            if daemon is not None:
                check_daemon_answers(report, daemon, work)
            program = runnable_copy(report, cli / "Contents/MacOS/arkdeck", work)
            if program is not None:
                check_cli_update(report, program, cli / DAEMON, work)
        check_rollback(report, root, expect_rollback)
    for failure in report.failures:
        print(f"FAIL: {failure}")
    print(
        f"{report.passed} checks passed, {len(report.failures)} failed: "
        f"unsigned Rust helper pair at {root}"
    )
    return 1 if report.failures else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
