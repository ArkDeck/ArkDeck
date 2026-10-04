#!/usr/bin/env python3
"""SPK-8 negative cases against the installed Runtime (TASK-XPA-019).

  installed_spk8_negatives.py self-test        /absolute/new/evidence-dir
  installed_spk8_negatives.py foreign-client   /absolute/new/evidence-dir
  installed_spk8_negatives.py version-mismatch /absolute/new/evidence-dir

(a) foreign-client: a bare ad-hoc signed tool (not team 8AQTYW5FKR) sends one
    read-only `health` frame to `com.arkdeck.agentd`; the installed pure-Rust
    daemon must cut it off with no reply frame (zero dispatch) and keep serving.
(b) version-mismatch: the signed App's `--runtime-readonly-smoke` entry, facing
    an installed daemon of another version/build, must report the mismatch and
    its remedy within a bound, twice, and exit cleanly.
self-test: compiles the (a) client and runs it against anonymous in-process
    listeners only. No Mach name, launchd or Runtime is contacted.

Each case is opt-in (see scripts/ci/installed-rust-ui.md); without its switch it
prints SKIPPED and exits 77. A skip, a self-test or these fixtures are never
SPK-8 evidence. PASS exits 0; FAIL or BLOCKED exits 1. Nothing here installs,
signs with a team identity, starts, stops or registers a service; the only
launchd call is the read-only `launchctl print` the positive case also uses.
"""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import time

sys.dont_write_bytecode = True
REPO = Path(__file__).resolve().parents[2]
SERVICE = "com.arkdeck.agentd"
TEAM = "8AQTYW5FKR"
SKIPPED = 77
APP_REQUIREMENT = (f'anchor apple generic and certificate leaf[subject.OU] = "{TEAM}" '
                   'and identifier "com.arkdeck.desktop"')
# The App's `serverIdentityRequirement` (AgentXPCContract.swift), before it
# appends the release pin.
SERVER_IDENTITY = (f'anchor apple generic and certificate leaf[subject.OU] = "{TEAM}" '
                   'and identifier "com.arkdeck.agentd"')
# Only the pre-cutover negative case observes this retired identity. The App
# and the pure-Rust positive/foreign-client cases still admit SERVER_IDENTITY only.
LEGACY_FACADE_IDENTITY = (f'anchor apple generic and certificate leaf[subject.OU] = "{TEAM}" '
                          'and identifier "com.arkdeck.agentd.facade"')
MISMATCH_WORDS = "Runtime release does not match this App"
REMEDY = "run runtime service update"
REPORT_BUDGET_SECONDS = 20


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# The positive case's installed-identity checks and the App smoke reader.
ui = load("installed_rust_ui", Path(__file__).with_name("installed_rust_ui.py"))
smoke = load("app_rust_smoke", REPO / "rust/scripts/macos-app-rust-smoke.py")
require = ui.require


def run(*argv, timeout=30, check=True):
    environment = {k: v for k, v in os.environ.items()
                   if not k.startswith(("ARKDECK_", "DYLD_")) and k != "CFFIXED_USER_HOME"}
    result = subprocess.run(argv, capture_output=True, timeout=timeout, env=environment)
    if check:
        require(result.returncode == 0, f"{Path(argv[0]).name} exited {result.returncode}")
    return result


def release_requirement(identity, version, build):
    require(all(v and all(c.isdigit() or c == "." for c in v) for v in (version, build)),
            "invalid release version")
    return (f'{identity} and info[CFBundleShortVersionString] = "{version}" '
            f'and info[CFBundleVersion] = "{build}"')


def evidence_directory(text):
    output = Path(text)
    require(output.is_absolute(), "absolute evidence directory required")
    installed = Path.home() / "Library/Application Support/ArkDeck"
    require(not output.resolve().is_relative_to(installed.resolve()) and not output.is_relative_to(installed),
            "evidence cannot be inside installed Runtime state")
    output.mkdir(mode=0o700, parents=False, exist_ok=False)
    return output


def health_frame():
    schema = json.loads((REPO / "spec/control/methods/health.json").read_text())
    return json.dumps({"contractIdentity": schema["x-arkdeck-contractIdentity"], "id": "spk8-foreign-client",
                       "method": "health", "protocolVersion": schema["x-arkdeck-protocolVersion"]},
                      sort_keys=True, separators=(",", ":"))


def build_client(output):
    """Compile and ad-hoc sign the (a) client, then prove it is foreign."""
    binary = output / "spk8-foreign-client"
    run("/usr/bin/xcrun", "swiftc", "-O", "-o", str(binary), str(REPO / "scripts/ci/spk8_foreign_client.swift"),
        timeout=300)
    run("/usr/bin/codesign", "--force", "--sign", "-", str(binary))
    details = run("/usr/bin/codesign", "-d", "--verbose=2", str(binary)).stderr.decode()
    require("Signature=adhoc" in details and "TeamIdentifier=not set" in details,
            "foreign client must be ad-hoc signed with no team")
    # The daemon's own App requirement must reject it, or the case proves nothing.
    require(run("/usr/bin/codesign", "--verify", "-R", "=" + APP_REQUIREMENT, str(binary),
                check=False).returncode != 0, "foreign client unexpectedly satisfies the App requirement")
    return binary, hashlib.sha256(binary.read_bytes()).hexdigest()


def client_json(binary, *arguments):
    result = run(str(binary), *arguments, timeout=30)
    record = json.loads(result.stdout)
    require(record.get("schemaVersion") == "arkdeck.spk8-foreign-client/1", "invalid foreign client record")
    return record


def judge_self_test(record):
    refusing, control = record.get("refusing", {}), record.get("control", {})
    require(refusing.get("outcome") == "refused" and refusing.get("handlerEntries") == 0,
            "self-test: the App-requirement listener did not refuse with zero handler entries")
    require(control.get("outcome") == "answered" and control.get("handlerEntries") == 1,
            "self-test: the probe did not detect a dispatch on the control listener")


def judge_foreign(probe, before, after):
    """(status, reason) for one probe of the installed daemon."""
    outcome = probe.get("outcome")
    if before != after:
        return "FAIL", "installed service identity changed during the probe"
    if outcome == "refused" and probe.get("replyError") in ("connectionInterrupted", "connectionInvalid") \
            and probe.get("elapsedMs") is not None:
        return "PASS", "daemon cut off the foreign client with no reply frame"
    if outcome in ("answered", "answeredMalformed"):
        return "FAIL", "daemon answered a client outside team 8AQTYW5FKR (dispatch)"
    if outcome == "serverRequirementUnmet":
        return "BLOCKED", "the answering service is not the inspected installed daemon"
    if outcome == "noAnswer":
        return "FAIL", "no answer or refusal within 5 s (hang)"
    return "FAIL", "unexpected libxpc outcome"


def installed_service():
    """Read-only: the live launchd owner of the fixed Mach name and its bundle."""
    plist = plistlib.loads((Path.home() / f"Library/LaunchAgents/{SERVICE}.plist").read_bytes())
    arguments = plist.get("ProgramArguments")
    require(plist.get("Label") == SERVICE and isinstance(arguments, list) and arguments,
            "installed LaunchAgent does not name the service")
    executable = Path(arguments[0]).resolve()
    bundle = executable.parent.parent.parent
    require(executable.parent.name == "MacOS" and bundle.suffix == ".app", "installed service is not a bundle")
    launch = ui.run("/bin/launchctl", "print", f"gui/{os.getuid()}/{SERVICE}").decode()
    pid = ui.live_pid(launch)
    ui.verify_live_endpoint(launch)
    require(ui.process_path(pid) == executable, "live launchd owner is not the installed executable")
    info = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
    return {"pid": pid, "executable": str(executable), "bundle": str(bundle),
            "version": info.get("CFBundleShortVersionString"), "build": info.get("CFBundleVersion"),
            "executableSHA256": ui.digest(executable)}


def judge_mismatch(reports, exited):
    require(len(reports) == 2, "App did not answer both refreshes")
    for report in reports:
        require(report.get("connected") is False and report.get("historyAvailable") is False,
                "App accepted a daemon of another release")
        reason = report.get("unavailableReason") or ""
        require(MISMATCH_WORDS in reason and reason.endswith(REMEDY),
                "App did not name the release mismatch and its remedy")
    require(exited, "App smoke did not exit after its refreshes")


def smoke_app(executable, budget=REPORT_BUDGET_SECONDS):
    """Two bounded refreshes through the App's own ClientKit transport."""
    reports, exited = [], False
    process = subprocess.Popen([str(executable), "--runtime-readonly-smoke"],
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    try:
        for _ in range(2):
            started = time.monotonic()
            report = smoke.next_report(process, timeout=budget)
            reports.append({**report, "elapsedSeconds": round(time.monotonic() - started, 3)})
        process.stdin.close()
        try:
            exited = process.wait(timeout=10) == 0
        except subprocess.TimeoutExpired:
            pass
    finally:
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=10)
        for stream in (process.stdin, process.stdout):
            if not stream.closed:
                stream.close()
    return reports, exited


def foreign_client(output):
    config = {key: os.environ[env] for key, env in (
        ("app", "ARKDECK_INSTALLED_RUST_APP"), ("cli", "ARKDECK_INSTALLED_RUST_CLI"),
        ("appSHA256", "ARKDECK_INSTALLED_RUST_APP_SHA256"),
        ("cliSHA256", "ARKDECK_INSTALLED_RUST_CLI_SHA256"),
        ("daemonSHA256", "ARKDECK_INSTALLED_RUST_DAEMON_SHA256"))}
    before = ui.inspect(config)
    binary, client_sha = build_client(output)
    judge_self_test(client_json(binary, "self-test", health_frame(), APP_REQUIREMENT))
    requirement = release_requirement(f'anchor apple generic and certificate leaf[subject.OU] = "{TEAM}" '
                                      f'and identifier "{SERVICE}"', before["version"], before["build"])
    probe = client_json(binary, "probe", health_frame(), requirement)["probe"]
    after = ui.inspect(config)
    status, reason = judge_foreign(probe, before, after)
    return {"status": status, "reason": reason, "probe": probe, "clientSHA256": client_sha,
            "identity": before}


def version_mismatch(output):
    app = Path(os.environ["ARKDECK_SPK8_APP"]).resolve()
    info, executable = smoke.inspect_app(app)
    ui.pinned_hash(executable, os.environ["ARKDECK_SPK8_APP_SHA256"])
    version, build = info["CFBundleShortVersionString"], info["CFBundleVersion"]
    before = installed_service()
    bundle = before["bundle"]
    name = Path(before["executable"]).name
    require(name in ("arkdeck-agentd", "arkdeck-facade"), "unrecognized installed Runtime executable")
    identity = LEGACY_FACADE_IDENTITY if name == "arkdeck-facade" else SERVER_IDENTITY
    run("/usr/bin/codesign", "--verify", "--strict", "-R", "=" + SERVER_IDENTITY, bundle)
    # The old bundle's principal executable is the Swift daemon, but launchd
    # runs its separately signed facade. Verify the actual live owner, including
    # its release, before testing a mismatch; a failed identity check is not one.
    run("/usr/bin/codesign", "--verify", "-R",
        "=" + release_requirement(identity, before["version"], before["build"]), str(before["pid"]))
    ui.verify_live_code(before["pid"], Path(before["executable"]))
    pinned = run("/usr/bin/codesign", "--verify", "-R",
                 "=" + release_requirement(identity, version, build), str(before["pid"]), check=False)
    if pinned.returncode == 0:
        return {"status": "BLOCKED", "reason": "installed daemon is this App's release; no mismatch to observe",
                "app": {"version": version, "build": build}, "service": before}
    require(not ui.app_processes(), "quit existing ArkDeck windows before the version-mismatch case")
    reports, exited = smoke_app(executable)
    after = installed_service()
    require(after == before, "installed service changed while the App was refused")
    ui.verify_live_code(after["pid"], Path(after["executable"]))
    judge_mismatch(reports, exited)
    return {"status": "PASS", "reason": "App reported the release mismatch and its remedy without hanging",
            "app": {"version": version, "build": build, "sha256": os.environ["ARKDECK_SPK8_APP_SHA256"]},
            "acceptanceScope": "pre-cutover-legacy-facade" if name == "arkdeck-facade"
            else "installed-daemon-release-mismatch",
            "service": before, "reports": reports}


def self_test(output):
    binary, client_sha = build_client(output)
    record = client_json(binary, "self-test", health_frame(), APP_REQUIREMENT)
    judge_self_test(record)
    return {"status": "PASS", "reason": "probe refuses under the App requirement and detects a dispatch",
            "selfTest": record, "clientSHA256": client_sha, "spk8Evidence": False}


CASES = {"self-test": (None, self_test),
         "foreign-client": ("ARKDECK_SPK8_FOREIGN_CLIENT", foreign_client),
         "version-mismatch": ("ARKDECK_SPK8_VERSION_MISMATCH", version_mismatch)}


def main(argv):
    require(len(argv) == 2 and argv[0] in CASES, "usage: {self-test|foreign-client|version-mismatch} DIR")
    switch, case = CASES[argv[0]]
    if switch and os.environ.get(switch) != "1":
        print(json.dumps({"case": argv[0], "status": "SKIPPED", "reason": f"{switch}=1 not set"}))
        return SKIPPED
    require(sys.platform == "darwin" and os.getuid() != 0, "logged-in macOS user required")
    os.umask(0o077)
    output = evidence_directory(argv[1])
    try:
        result = case(output)
    except (RuntimeError, OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        # Never echo third-party command output; it can carry environment data.
        reason = str(error) if type(error) is RuntimeError else type(error).__name__
        result = {"status": "FAIL", "reason": reason}
    result = {"case": argv[0], **result}
    ui.write_private(output / "result.json", result)
    print(json.dumps({"case": argv[0], "status": result["status"], "reason": result["reason"],
                      "evidence": str(output / "result.json")}))
    return 0 if result["status"] == "PASS" else 1


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except (RuntimeError, OSError, ValueError) as error:
        reason = str(error) if type(error) is RuntimeError else type(error).__name__
        print(json.dumps({"status": "FAIL", "reason": reason}))
        sys.exit(1)
