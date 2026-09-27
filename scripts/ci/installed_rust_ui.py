#!/usr/bin/env python3
"""Private evidence/restore helper for the opt-in installed Rust UI test.

Never installs, signs, starts, stops or registers a service. The UI performs
the test save; this helper only reads, or CAS-restores that test-owned change.
All subprocesses use fixed executables/argument arrays. No raw IPC dispatch.
"""
import ctypes
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import pwd
import re
import subprocess
import sys
import uuid

sys.dont_write_bytecode = True
REPO = Path(__file__).resolve().parents[2]
SERVICE = "com.arkdeck.agentd"
TEAM = "8AQTYW5FKR"


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def run(*argv, diagnostics=False):
    environment = {k: v for k, v in os.environ.items()
                   if not k.startswith(("ARKDECK_", "DYLD_")) and k != "CFFIXED_USER_HOME"}
    result = subprocess.run(argv, capture_output=True, timeout=30, env=environment)
    # Do not echo argv, stdout, stderr, launchd environments or filter contents.
    require(result.returncode == 0, f"{Path(argv[0]).name} exited {result.returncode}")
    output = result.stderr if diagnostics else result.stdout
    require(len(output) <= 4 * 1024 * 1024, "command output exceeded budget")
    return output


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read_json(path):
    require(path.is_file() and path.stat().st_size <= 1024 * 1024, "invalid evidence document")
    return json.loads(path.read_text())


def write_private(path, value):
    data = json.dumps(value, sort_keys=True, indent=2).encode() + b"\n"
    # Snapshots are private and durable before the UI is allowed to save.
    with open(path, "xb") as stream:
        os.chmod(path, 0o600)
        stream.write(data)
        stream.flush()
        os.fsync(stream.fileno())


def pinned_hash(path, expected):
    require(re.fullmatch(r"[0-9a-f]{64}", expected) is not None, "missing release SHA256 pin")
    require(digest(path) == expected, "release SHA256 mismatch")
    return expected


def process_path(pid):
    library = ctypes.CDLL("/usr/lib/libproc.dylib")
    buffer = ctypes.create_string_buffer(4096)
    length = library.proc_pidpath(int(pid), buffer, len(buffer))
    require(length > 0, "cannot identify live process executable")
    return Path(os.fsdecode(buffer.value)).resolve()


def live_pid(text):
    values = re.findall(r"^\s*pid = ([1-9][0-9]*)\s*$", text, re.MULTILINE)
    require(len(values) == 1, "launchd does not report one live service PID")
    return int(values[0])


def verify_live_endpoint(text):
    blocks = re.findall(r'"com\.arkdeck\.agentd"\s*=\s*\{([^{}]*)\}', text)
    require(len(blocks) == 1 and re.search(r"^\s*active = 1\s*$", blocks[0], re.MULTILINE),
            "production Mach endpoint is not active on the live service")


def verify_live_code(pid, executable):
    require(run("/usr/bin/lipo", "-archs", str(executable)).decode().strip() == "arm64",
            "installed acceptance requires the shipped thin arm64 executable")
    details = run("/usr/bin/codesign", "-d", "--verbose=4", str(executable), diagnostics=True).decode()
    values = re.findall(r"^CDHash=([0-9a-f]{40})$", details, re.MULTILINE)
    require(len(values) == 1, "missing pinned executable CodeDirectory hash")
    # codesign supports PID arguments for dynamic validation. A replaced on-disk
    # binary must not disguise a still-running Swift/old release process.
    run("/usr/bin/codesign", "--verify", "-R", '=cdhash H"' + values[0] + '"', str(pid))
    return values[0]


def signature(bundle, identifier, version, build):
    require(all(re.fullmatch(r"[0-9.]+", v) for v in (version, build)), "invalid release version")
    requirement = (f'anchor apple generic and certificate leaf[subject.OU] = "{TEAM}" '
                   f'and identifier "{identifier}" '
                   f'and info[CFBundleShortVersionString] = "{version}" '
                   f'and info[CFBundleVersion] = "{build}"')
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", "-R", "=" + requirement, str(bundle))


def inspect(config):
    require(sys.platform == "darwin" and os.getuid() != 0, "logged-in macOS user required")
    require(Path.home() == Path(pwd.getpwuid(os.getuid()).pw_dir), "relocated home is not installed acceptance")
    # Reuse the existing production App signature, sandbox and Mach-name checks.
    spec = importlib.util.spec_from_file_location("app_rust_smoke", REPO / "rust/scripts/macos-app-rust-smoke.py")
    existing = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(existing)
    app = Path(config["app"])
    info, executable = existing.inspect_app(app)
    pinned_hash(executable, config["appSHA256"])
    entitlements = plistlib.loads(run("/usr/bin/codesign", "-d", "--entitlements", ":-", str(app)))
    expected_entitlements = plistlib.loads((REPO / "ArkDeckApp/ArkDeckApp.entitlements").read_bytes())
    require(entitlements == expected_entitlements, "App entitlements differ from production source")
    version, build = info["CFBundleShortVersionString"], info["CFBundleVersion"]
    support = Path.home() / "Library/Application Support/ArkDeck"
    bundle = support / "Helpers/ArkDeckAgent.app"
    daemon = (bundle / "Contents/MacOS/arkdeck-agentd").resolve()
    signature(bundle, SERVICE, version, build)
    pinned_hash(daemon, config["daemonSHA256"])
    require(not (bundle / "Contents/MacOS/arkdeck-facade").exists(), "installed facade sibling exists")
    require(b"libswift" not in run("/usr/bin/otool", "-L", str(daemon)).lower(), "installed daemon links Swift")
    cli = Path(config["cli"]).resolve()
    require(cli.name == "arkdeck" and cli.parent.name == "MacOS", "expected packaged CLI executable")
    signature(cli.parent.parent.parent, "com.arkdeck.cli", version, build)
    pinned_hash(cli, config["cliSHA256"])
    require(b"libswift" not in run("/usr/bin/otool", "-L", str(cli)).lower(), "CLI links Swift")
    receipt_path = support / "LaunchAgent/install-receipt.json"
    receipt = read_json(receipt_path)
    require(receipt.get("schemaVersion") == "arkdeck-launchagent-install/v1", "receipt schema mismatch")
    require(receipt.get("daemonPath") == str(daemon) and receipt.get("daemonSHA256") == config["daemonSHA256"], "receipt does not identify pinned daemon")
    plist_path = Path.home() / f"Library/LaunchAgents/{SERVICE}.plist"
    plist = plistlib.loads(plist_path.read_bytes())
    require(plist.get("Label") == SERVICE and plist.get("ProgramArguments") == [str(daemon)], "installed launch arguments are not pure Rust")
    require(plist.get("MachServices") == {SERVICE: True}, "production Mach registration mismatch")
    environment = plist.get("EnvironmentVariables", {})
    require(environment.get("ARKDECK_RUNTIME_COMPOSITION") == "production", "installed composition is not production")
    bypasses = ("ARKDECK_APP_INGRESS", "ARKDECK_DEVELOPMENT_STATE_ROOT", "ARKDECK_ENDPOINT",
                "ARKDECK_SWIFT_DAEMON", "ARKDECK_SWIFT_SHA256", "ARKDECK_PRIVATE_SOCKET",
                "ARKDECK_HDC_SHA256", "CFFIXED_USER_HOME")
    require(not any(k in environment for k in bypasses), "installed environment contains a bypass")
    launch = run("/bin/launchctl", "print", f"gui/{os.getuid()}/{SERVICE}").decode()
    pid = live_pid(launch)
    verify_live_endpoint(launch)
    require(process_path(pid) == daemon, "live launchd owner is not the installed daemon")
    code_hash = verify_live_code(pid, daemon)
    require(re.search(r"ARKDECK_RUNTIME_COMPOSITION\s*=>\s*production\s*$", launch, re.MULTILINE) is not None, "live service composition is not production")
    require(str(daemon) in launch and SERVICE in launch, "live service registration mismatch")
    require(not any(re.search(r"^\s*" + key + r"\s*=>", launch, re.MULTILINE) for key in bypasses), "live service environment contains a bypass")
    # Refuse coexisting facade/Swift daemon processes; do not dump process argv.
    processes = run("/bin/ps", "-u", str(os.getuid()), "-o", "pid=,comm=").decode()
    for line in processes.splitlines():
        fields = line.strip().split(None, 1)
        if len(fields) != 2 or Path(fields[1]).name not in ("arkdeck-agentd", "arkdeck-facade", "ArkDeckAgentDaemon", "ArkDeckAgentDaemonMain"):
            continue
        require(int(fields[0]) == pid, "another Runtime/facade process exists")
    return {"pid": pid, "daemonPath": str(daemon), "daemonSHA256": config["daemonSHA256"], "liveCodeDirectoryHash": code_hash,
            "appSHA256": config["appSHA256"], "cliSHA256": config["cliSHA256"],
            "receiptSHA256": digest(receipt_path), "plistSHA256": digest(plist_path),
            "version": version, "build": build, "production": True, "swiftBypassAbsent": True}


def app_processes():
    rows = run("/bin/ps", "-u", str(os.getuid()), "-o", "pid=,comm=").decode().splitlines()
    return [int(parts[0]) for line in rows if len(parts := line.strip().split(None, 1)) == 2
            and Path(parts[1]).name == "ArkDeck"]


def verify_app_process(config):
    processes = app_processes()
    require(len(processes) == 1, "expected exactly one signed App process")
    expected = (Path(config["app"]) / "Contents/MacOS/ArkDeck").resolve()
    require(process_path(processes[0]) == expected, "UI launched a different App executable")
    pinned_hash(expected, config["appSHA256"])
    verify_live_code(processes[0], expected)
    return processes[0]


def cli_filter(config, action, *arguments):
    return json.loads(run(config["cli"], "history", "filter", action, *arguments, "--json"))


def resource(document):
    require(document.get("schemaVersion") == "arkdeck.history-filter-list/1", "filter response schema mismatch")
    generation = document.get("generation")
    require(isinstance(generation, str) and re.fullmatch(r"0|[1-9][0-9]*", generation), "invalid generation")
    filters = document.get("filters")
    require(isinstance(filters, list) and len(filters) <= 1, "invalid saved filter count")
    query = filters[0]["query"] if filters else None
    if filters:
        require(filters[0].get("generation") == generation, "inconsistent generation")
    return {"generation": generation, "query": query}


def restore_arguments(query):
    arguments = []
    for key, flag in (("search", "search"), ("status", "status"), ("mode", "mode"),
                      ("sessionId", "session"), ("targetId", "target"),
                      ("timeRange", "time"), ("activity", "activity")):
        value = query[key]
        if value is None and key in ("sessionId", "targetId"):
            continue
        # The current CLI rejects an option value starting with '--'. Refuse
        # before UI mutation when the original cannot be restored losslessly.
        require(isinstance(value, str) and not value.startswith("--") and "\0" not in value,
                "original query cannot be restored through current typed CLI")
        arguments.extend(["--" + flag, value])
    return arguments


def restoration(original, current, test_query):
    if current == original:
        return "unchanged"
    require(current["query"] == test_query and int(current["generation"]) == int(original["generation"]) + 1,
            "filter changed outside this test; snapshot retained, no overwrite")
    return "delete" if original["query"] is None else "save"


def restore(config, snapshot):
    current = resource(cli_filter(config, "list"))
    action = restoration(snapshot["original"], current, snapshot["testQuery"])
    if action != "unchanged":
        arguments = ["--expected-generation", current["generation"]]
        if action == "save":
            arguments.extend(restore_arguments(snapshot["original"]["query"]))
        cli_filter(config, action, *arguments)
    after = resource(cli_filter(config, "list"))
    require(after["query"] == snapshot["original"]["query"], "original filter was not restored")
    require(int(after["generation"]) == int(current["generation"]) + (action != "unchanged"), "restore generation changed unexpectedly")
    return {"restored": True, "action": action, "generation": after["generation"]}


def main():
    stage, directory = sys.argv[1:]
    output = Path(directory)
    require(stage in ("prepare", "verify-original", "verify-save", "restore"), "unsupported test helper action")
    os.umask(0o077)
    if stage == "prepare":
        require(os.environ.get("ARKDECK_INSTALLED_RUST_UI") == "1", "installed UI opt-in required")
        require(output.is_absolute(), "absolute evidence directory required")
        require(not output.resolve().is_relative_to(Path.home() / "Library/Application Support/ArkDeck"), "evidence cannot be inside installed Runtime state")
        output.mkdir(mode=0o700, parents=False, exist_ok=False)
        config = {key: os.environ[env] for key, env in (
            ("app", "ARKDECK_INSTALLED_RUST_APP"), ("cli", "ARKDECK_INSTALLED_RUST_CLI"),
            ("appSHA256", "ARKDECK_INSTALLED_RUST_APP_SHA256"),
            ("cliSHA256", "ARKDECK_INSTALLED_RUST_CLI_SHA256"),
            ("daemonSHA256", "ARKDECK_INSTALLED_RUST_DAEMON_SHA256"))}
        identity = inspect(config)
        require(not app_processes(), "quit existing ArkDeck windows before installed UI acceptance")
        original = resource(cli_filter(config, "list"))
        if original["query"] is not None:
            restore_arguments(original["query"])
        query = {"search": "arkdeck-ui-" + str(uuid.uuid4()), "status": "all", "mode": "all",
                 "sessionId": None, "targetId": None, "timeRange": "anyTime", "activity": "all"}
        write_private(output / "snapshot.json", {"config": config, "identity": identity, "original": original, "testQuery": query})
        print(json.dumps({"app": config["app"], "search": query["search"]}))
        return
    snapshot = read_json(output / "snapshot.json")
    config = snapshot["config"]
    require(inspect(config) == snapshot["identity"], "installed service identity changed; no restoration dispatched")
    if stage == "verify-original":
        verify_app_process(config)
        require(resource(cli_filter(config, "list")) == snapshot["original"], "saved filter changed before UI write; no save allowed")
        print(json.dumps({"originalUnchanged": True}))
    elif stage == "verify-save":
        app_pid = verify_app_process(config)
        current = resource(cli_filter(config, "list"))
        require(current["query"] == snapshot["testQuery"] and int(current["generation"]) == int(snapshot["original"]["generation"]) + 1, "UI save did not persist the exact test query")
        result = {"saved": True, "generation": current["generation"], "appPID": app_pid,
                  "identity": snapshot["identity"]}
        write_private(output / ("verified-" + str(uuid.uuid4()) + ".json"), result)
        print(json.dumps(result))
    else:
        result = restore(config, snapshot)
        require(inspect(config) == snapshot["identity"], "service changed during restoration")
        write_private(output / "restoration.json", result)
        print(json.dumps(result))


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        # Avoid exception contents: third-party commands can include credentials.
        reason = str(error) if type(error) is RuntimeError else type(error).__name__
        result = {"passed": False, "reason": reason, "snapshotRetained": True}
        if len(sys.argv) == 3 and sys.argv[1] == "restore":
            directory = Path(sys.argv[2])
            if (directory / "snapshot.json").is_file():
                write_private(directory / ("restore-failed-" + str(uuid.uuid4()) + ".json"), result)
        print(json.dumps(result))
        sys.exit(1)
