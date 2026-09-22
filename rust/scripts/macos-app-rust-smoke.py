#!/usr/bin/env python3
"""Signed App -> ClientKit -> standalone Rust Mach read/reconnect smoke.

Default is read-only preflight. --execute is for an independent macOS login/VM
where the production Mach name is free. Never replaces an installed service.
Build the App with its production entitlements and --runtime-readonly-smoke
entry point; supply a standalone Rust arkdeck-agentd binary from the same tree.
This is host IPC evidence, not hardware or UI acceptance.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import selectors
import shutil
import subprocess
import sys
import time
import uuid

SERVICE = "com.arkdeck.agentd"
TEAM = "8AQTYW5FKR"
APP_REQUIREMENT = (
    f'anchor apple generic and certificate leaf[subject.OU] = "{TEAM}" '
    'and identifier "com.arkdeck.desktop"'
)


def command(*args, check=True):
    return subprocess.run(args, capture_output=True, timeout=30, check=check)


def require_free_domain():
    if sys.platform != "darwin":
        raise RuntimeError("macOS required")
    uid = os.getuid()
    if uid == 0:
        raise RuntimeError("run as the independent logged-in user, never root")
    installed = Path.home() / "Library/LaunchAgents/com.arkdeck.agentd.plist"
    if installed.exists() or installed.is_symlink():
        raise RuntimeError("installed LaunchAgent exists; use an independent login/VM")
    domain = f"gui/{uid}"
    # GUI and user domains share Mach names. Refuse any existing registration,
    # even one under a label different from the production service label.
    for name in (domain, f"user/{uid}"):
        result = command("/bin/launchctl", "print", name, check=False)
        if name == domain and result.returncode:
            raise RuntimeError("an active independent GUI login domain is required")
        if b"ARKDECK_" in result.stdout or b"CFFIXED_USER_HOME" in result.stdout:
            raise RuntimeError("launchd has Runtime environment overrides; use a clean independent login/VM")
        if SERVICE.encode() in result.stdout:
            raise RuntimeError(f"fixed Mach name already registered in {name}; no service changed")
    return domain


def inspect_app(app):
    command("/usr/bin/codesign", "--verify", "--deep", "--strict", "-R", APP_REQUIREMENT, str(app))
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    entitlements = plistlib.loads(command(
        "/usr/bin/codesign", "-d", "--entitlements", ":-", str(app)).stdout)
    if entitlements.get("com.apple.security.app-sandbox") is not True:
        raise RuntimeError("App must retain its production sandbox")
    if entitlements.get("com.apple.security.temporary-exception.mach-lookup.global-name") != [SERVICE]:
        raise RuntimeError("App must retain exactly the production Mach exception")
    executable = app / "Contents/MacOS" / info["CFBundleExecutable"]
    if executable.parent != app / "Contents/MacOS" or not executable.is_file():
        raise RuntimeError("invalid App executable")
    for key in ("CFBundleShortVersionString", "CFBundleVersion"):
        if not isinstance(info.get(key), str) or not info[key] or any(c in info[key] for c in '\\"\n'):
            raise RuntimeError("invalid App version/build")
    return info, executable


def next_report(process, timeout=40):
    # App emits one bounded JSON record per stdin 'refresh' command. Keep the
    # same App process alive through service termination/restart.
    process.stdin.write(b"refresh\n")
    process.stdin.flush()
    deadline = time.monotonic() + timeout
    buffer = bytearray()
    with selectors.DefaultSelector() as selector:
        selector.register(process.stdout, selectors.EVENT_READ)
        while time.monotonic() < deadline:
            if not selector.select(max(0, deadline - time.monotonic())):
                break
            chunk = os.read(process.stdout.fileno(), 4096)
            if not chunk:
                raise RuntimeError("App exited before its smoke report")
            buffer.extend(chunk)
            if len(buffer) > 65536:
                raise RuntimeError("App smoke output exceeded its budget")
            while b"\n" in buffer:
                line, _, rest = buffer.partition(b"\n")
                buffer = bytearray(rest)
                if line.startswith(b'ARKDECK_IPC_SMOKE '):
                    report = json.loads(line.removeprefix(b'ARKDECK_IPC_SMOKE '))
                    if not isinstance(report, dict) or report.get("schemaVersion") != "arkdeck.app-readonly-smoke/1" or report.get("hardwareAcceptance") is not False:
                        raise RuntimeError("invalid App smoke report schema")
                    return report
    raise RuntimeError("App smoke timed out; no request is replayed")


def execute(args, domain, info, executable):
    output = args.output.resolve()
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    state = output / "state"
    state.mkdir(mode=0o700)
    bundle = output / "ArkDeckAgent.app"
    binary = bundle / "Contents/MacOS/arkdeck-agentd"
    binary.parent.mkdir(parents=True)
    shutil.copy2(args.daemon, binary)
    binary.chmod(0o700)
    metadata = {
        "CFBundleIdentifier": SERVICE, "CFBundleExecutable": "arkdeck-agentd",
        "CFBundlePackageType": "APPL", "CFBundleName": "ArkDeck IPC Smoke Runtime",
        "CFBundleShortVersionString": info["CFBundleShortVersionString"],
        "CFBundleVersion": info["CFBundleVersion"],
    }
    (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps(metadata))
    command("/usr/bin/codesign", "--force", "--options", "runtime", "--sign", args.sign_identity, str(bundle))
    requirement = APP_REQUIREMENT.replace("com.arkdeck.desktop", SERVICE)
    command("/usr/bin/codesign", "--verify", "--strict", "-R", requirement, str(bundle))
    label = "com.arkdeck.ipc-smoke." + str(uuid.uuid4())
    plist = output / (label + ".plist")
    plist.write_bytes(plistlib.dumps({
        "Label": label, "ProgramArguments": [str(binary)], "RunAtLoad": True,
        "MachServices": {SERVICE: True},
        "EnvironmentVariables": {"ARKDECK_APP_INGRESS": "history", "ARKDECK_DEVELOPMENT_STATE_ROOT": str(state)},
        "StandardOutPath": str(output / "daemon.stdout.log"),
        "StandardErrorPath": str(output / "daemon.stderr.log"),
    }))
    registered = False
    app_process = None
    reports = []
    completed = False
    try:
        # Recheck immediately before any registration. A racing registration
        # also makes bootstrap fail; never bootout another service to proceed.
        require_free_domain()
        with (output / "app.stderr.log").open("wb") as stderr:
            app_process = subprocess.Popen(
                [str(executable), "--runtime-readonly-smoke"],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=stderr)
            absent = next_report(app_process)
            reports.append({"phase": "before-service", "report": absent})
            if absent.get("connected") is not False:
                raise RuntimeError("App unexpectedly connected before the isolated service")
            for phase in ("connected", "reconnected"):
                command("/bin/launchctl", "bootstrap", domain, str(plist))
                registered = True
                report = next_report(app_process)
                reports.append({"phase": phase, "report": report})
                if report.get("connected") is not True:
                    raise RuntimeError(f"{phase}: App could not read standalone Rust Runtime")
                service = command("/bin/launchctl", "print", f"{domain}/{label}").stdout
                (output / f"{phase}.launchctl.txt").write_bytes(service)
                command("/bin/launchctl", "bootout", domain, str(plist))
                registered = False
                report = next_report(app_process)
                reports.append({"phase": phase + "-disconnected", "report": report})
                if report.get("connected") is not False or report.get("jobCount") != 0:
                    raise RuntimeError("App retained a successful state after service termination")
            completed = True
            return reports
    finally:
        try:
            if app_process:
                try:
                    app_process.stdin.close()
                except BrokenPipeError:
                    pass
                try:
                    app_process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    app_process.terminate()
                    app_process.wait(timeout=10)
        finally:
            # Only our unique plist, and only after successful bootstrap.
            if registered:
                command("/bin/launchctl", "bootout", domain, str(plist))
        (output / "reports.json").write_text(json.dumps({
            "kind": "signed-app-standalone-rust-host-ipc", "hardwareAcceptance": False,
            "completed": completed,
            "appSHA256": hashlib.sha256(executable.read_bytes()).hexdigest(),
            "daemonSHA256": hashlib.sha256(binary.read_bytes()).hexdigest(),
            "reports": reports,
        }, indent=2) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--daemon", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True, help="new private directory; never installed state")
    parser.add_argument("--sign-identity", default="Developer ID Application: Hanfeng Fu (8AQTYW5FKR)")
    parser.add_argument("--execute", action="store_true", help="register only the isolated temporary service after all preflight checks")
    args = parser.parse_args()
    try:
        domain = require_free_domain()
        info, executable = inspect_app(args.app.resolve())
        if not args.daemon.is_file():
            raise RuntimeError("standalone Rust daemon binary is missing")
        installed_state = (Path.home() / "Library/Application Support/ArkDeck").resolve()
        if args.output.resolve().is_relative_to(installed_state):
            raise RuntimeError("output cannot be inside installed Runtime state")
        libraries = command("/usr/bin/otool", "-L", str(args.daemon)).stdout
        if b"libswift" in libraries.lower():
            raise RuntimeError("daemon links Swift runtime libraries; a standalone Rust binary is required")
        if args.output.exists():
            raise RuntimeError("output must be a new directory")
        if args.execute:
            execute(args, domain, info, executable)
        print(json.dumps({"status": "PASS" if args.execute else "PREFLIGHT_READY", "hardwareAcceptance": False}))
        return 0
    except (RuntimeError, OSError, ValueError, subprocess.SubprocessError) as error:
        print(json.dumps({"status": "BLOCKED_OR_FAILED", "reason": str(error), "hardwareAcceptance": False}))
        return 1


if __name__ == "__main__":
    sys.exit(main())
