"""Root-only portable typed capture entry; default/help performs no host access.

This is a bounded one-command recorder, not a complete Journey or PASS issuer.
Root follows README's existing protected-main guards and reads every product.
"""
from __future__ import annotations

import argparse
import ctypes
import hashlib
import importlib.util
import json
import os
from pathlib import Path, PurePosixPath
import platform
import re
import socket
import stat
import subprocess
import sys

HAP = ("ec5ce24958a16047c784a4af0f2197db86009abe1a3fbb193363a8bdd825e4bf", 130336)
CANDIDATE = ("078b569e5cf94ac9c58d505b47f0ccece056c08c80ed8d67bb473f2ec8861f2a", 26401)
GHOST = ("01d4e785ceec23a3873f67b4ec5035c0bfa469139596f88bfb96dd91dae840ae", 26401)
CATALOG = "c6e92eb252fe7653ed303a9ce34d12635bbc5f71ffb2a54fb8eb1fa3a9b99036"
TEAM = "8AQTYW5FKR"
OPERATIONS = {"observe.device@1", "capture.diagnostics@1", "debug.hap@1",
              "deploy.native-library.app-owned@1"}
READS = {
    ("--version",), ("doctor",), ("runtime", "health"),
    ("runtime", "service", "status"), ("runtime", "hdc", "status"),
    ("runtime", "tool", "list"), ("runtime", "bundle", "list"),
    ("operation", "list"), ("device", "candidates"), ("target", "show"),
    ("target", "availability"), ("agent", "status"), ("agent", "list"),
    ("job", "list"), ("job", "status"), ("job", "wait"), ("job", "show"),
    ("job", "result"), ("job", "evidence"), ("job", "timeline"),
    ("artifact", "list"), ("artifact", "show"), ("artifact", "read"),
    ("artifact", "import", "inspect"), ("human-action", "list"),
    ("human-action", "show"), ("runtime", "service", "verify"),
}
MUTATIONS = {
    ("agent", "run"), ("agent", "resume"), ("target", "adopt"),
    ("artifact", "import", "hap"), ("artifact", "import", "native-library"),
    ("runtime", "service", "restart"),
}
FORBIDDEN = {"--socket", "--json", "--capability", "--reviewed-plan-digest",
             "--request-file", "--idempotency-key"}


class Stop(Exception):
    pass


def require(condition, message):
    if not condition:
        raise Stop(message)


def unique(items):
    result = {}
    for key, value in items:
        require(key not in result, "duplicate JSON key")
        result[key] = value
    return result


def digest(data):
    return hashlib.sha256(data).hexdigest()


def sha_file(path):
    with path.open("rb") as handle:
        return hashlib.file_digest(handle, "sha256").hexdigest()


def pin_file(path, expected):
    require(path.is_file() and path.stat().st_size == expected[1], "material byte count differs")
    require(sha_file(path) == expected[0], "material whole SHA differs")


def ordinary(path, *, directory=False):
    require(path.is_absolute() and path.resolve(strict=True) == path, "path must be explicit canonical absolute")
    for component in (*reversed(path.parents), path):
        mode = component.lstat().st_mode
        require(not stat.S_ISLNK(mode), "path ancestry contains a link")
    require(path.is_dir() if directory else path.is_file(), "path has wrong file kind")
    return path


def json_once(path, value):
    with path.open("x", encoding="utf-8", newline="\n") as stream:
        stream.write(json.dumps(value, sort_keys=True, indent=2) + "\n")


def option(arguments, name):
    return arguments[arguments.index(name) + 1] if name in arguments else None


def validate_argv(arguments, registry):
    require(isinstance(arguments, list) and arguments and all(
        isinstance(v, str) and v and "\0" not in v for v in arguments), "invalid argv array")
    paths = sorted(READS | MUTATIONS, key=len, reverse=True)
    leaf = next((p for p in paths if tuple(arguments[:len(p)]) == p), None)
    require(leaf is not None, "command outside paired Journey allowlist")
    if leaf == ("--version",):
        definitions = {"--output": {"form": "value", "required": True}}
    else:
        rows = [v for v in registry["commands"] if tuple(v["path"]) == leaf
                and v.get("lifecycleStatus") == "current"]
        require(len(rows) == 1, "command is not a unique current published leaf")
        definitions = {v["name"]: v for v in rows[0]["options"]
                       if v.get("published", True) and v["name"] not in FORBIDDEN}
    seen, index = set(), len(leaf)
    while index < len(arguments):
        name = arguments[index]
        require(name.startswith("--") and "=" not in name and name not in seen
                and name in definitions, "unknown, duplicate or forbidden option")
        seen.add(name)
        definition = definitions[name]
        index += 1
        if definition["form"] == "value":
            require(index < len(arguments) and not arguments[index].startswith("--"), "option value missing")
            value = arguments[index]
            grammar = definition.get("grammar") or {}
            if grammar.get("kind") == "enumeration":
                require(value in grammar["values"], "enumeration value differs")
            if grammar.get("kind") == "positiveInteger":
                require(re.fullmatch(r"[1-9][0-9]*", value) is not None, "noncanonical positive integer")
                require(int(value) >= grammar.get("minimum", 1)
                        and int(value) <= grammar.get("maximum", 2**63 - 1), "integer exceeds published bounds")
            if grammar.get("kind") in ("pattern", "duration"):
                require(re.fullmatch(grammar["pattern"], value) is not None, "option grammar differs")
            index += 1
    require(all(not d.get("required") or name in seen for name, d in definitions.items()), "required option absent")
    require(option(arguments, "--output") == "json", "one JSON envelope required")
    if leaf == ("agent", "run"):
        require(option(arguments, "--operation") in OPERATIONS
                and option(arguments, "--execution-id") is not None
                and option(arguments, "--maximum-wait") in ("5m", "10m"), "unsupported operation or launch budget")
        require(option(arguments, "--timeout") == "11m", "bounded 11m launch client timeout required")
        if option(arguments, "--operation") != "observe.device@1":
            require(option(arguments, "--target") and option(arguments, "--inputs-file"), "target/input missing")
    if leaf == ("runtime", "service", "verify"):
        require(option(arguments, "--job") is not None, "verify may only reread an existing observe Job")
    if leaf == ("job", "wait"):
        require(option(arguments, "--timeout") in ("30s", "11m"), "bounded wait timeout required")
    return leaf


def mutation_key(leaf, arguments, step):
    if leaf not in MUTATIONS:
        return None
    names = {( "agent", "run"): "--execution-id", ("agent", "resume"): "--resume-reference",
             ("target", "adopt"): "--observation",
             ("artifact", "import", "hap"): "--import-request-id",
             ("artifact", "import", "native-library"): "--import-request-id"}
    if leaf == ("runtime", "service", "restart"):
        require(step in ("gj1.restart", "gj2.restart"), "restart must use its fixed Journey step")
        return step
    value = option(arguments, names[leaf])
    require(value is not None, "mutation identity absent")
    return ".".join(leaf) + ":" + value


def prior_guard(out, key):
    if key is None:
        return
    for p in out.glob("mac-entry-*.intent.json"):
        intent = json.loads(p.read_text(encoding="utf-8"), object_pairs_hook=unique)
        require(intent.get("mutationKey") != key, "mutation already attempted; never replay")
        outcome_path = p.with_name(p.name.replace(".intent.json", ".outcome.json"))
        require(outcome_path.is_file(), "prior invocation outcome unknown; no new mutation")
        outcome = json.loads(outcome_path.read_text(encoding="utf-8"), object_pairs_hook=unique)
        require(outcome.get("outcomeUnknown") is False, "prior invocation outcome unknown; no new mutation")


def check_configuration(config, *, native_system=platform.system, host_runner=subprocess.run):
    require(native_system() == "Darwin", "this entry requires a real Mac host")
    required = {"schemaVersion", "repository", "sourceRevision", "cli", "cliSha256",
                "daemon", "daemonSha256", "out", "catalogDigest"}
    require(set(config) == required and config["schemaVersion"] == "arkdeck.mac-paired-entry/1", "configuration shape differs")
    require(re.fullmatch(r"[0-9a-f]{40}", config["sourceRevision"]), "source is not a full Git SHA")
    require(config["catalogDigest"] == CATALOG, "paired preparation Catalog differs")
    repo, out = ordinary(Path(config["repository"]), directory=True), ordinary(Path(config["out"]), directory=True)
    require(not out.is_relative_to(repo) and not repo.is_relative_to(out), "Raw root overlaps repository")
    require(out.stat().st_uid == os.getuid() and stat.S_IMODE(out.stat().st_mode) == 0o700, "Root must precreate private owned mode0700 Raw")
    source_heads = []
    for ref in ("HEAD", "origin/main"):
        result = host_runner(["git", "-C", str(repo), "rev-parse", ref], stdin=subprocess.DEVNULL,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10, check=False)
        require(result.returncode == 0, "protected source revision unavailable")
        source_heads.append(result.stdout.decode().strip())
    require(source_heads[0] == source_heads[1], "repository HEAD is not current protected main")
    sys.path.insert(0, str(repo / "scripts"))
    from gj_record import catalog
    built, current = (catalog.at_revision(repo, ref) for ref in (config["sourceRevision"], "origin/main"))
    require(catalog.on_protected_main(repo, built.revision, "origin/main")
            and built.digest == current.digest == config["catalogDigest"]
            and built.operations == current.operations, "RC protected ancestry or same Catalog is unproved")
    clean = host_runner(["git", "-C", str(repo), "status", "--porcelain", "--untracked-files=no"],
                        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                        timeout=10, check=False)
    require(clean.returncode == 0 and not clean.stdout.strip(), "protected source has tracked local changes")
    for field in ("cli", "daemon"):
        path = ordinary(Path(config[field]))
        require(re.fullmatch(r"[0-9a-f]{64}", config[field + "Sha256"])
                and sha_file(path) == config[field + "Sha256"], "verified installed image changed")
        verified = host_runner(["/usr/bin/codesign", "--verify", "--strict", str(path)], stdin=subprocess.DEVNULL,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=20, check=False)
        identity = host_runner(["/usr/bin/codesign", "-dv", "--verbose=4", str(path)], stdin=subprocess.DEVNULL,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=20, check=False)
        require(verified.returncode == 0 and identity.returncode == 0
                and ("TeamIdentifier=" + TEAM) in identity.stderr.decode("utf-8", "replace").splitlines(),
                "installed release image native signature differs")
    return repo, out


class MacNative:
    """Read-only launchd/kernel/code identity; never sends a Runtime frame."""

    def __init__(self, repository, config, *, runner=subprocess.run):
        require(platform.system() == "Darwin" and os.getuid() != 0, "logged-in Mac user required")
        self.uid, self.daemon, self.runner = os.getuid(), config["daemon"], runner
        source = repository / "scripts/ci/installed_rust_ui.py"
        spec = importlib.util.spec_from_file_location("mac_entry_installed_native", source)
        self.existing = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.existing)
        self.existing.run = self.host_read

    def host_read(self, *argv, diagnostics=False):
        # Reuse the installed UI verifier's live PID/path/CDHash checks, with
        # its host subprocesses confined to these exact read-only forms.
        allowed = argv in (("/bin/launchctl", "print", f"gui/{self.uid}/com.arkdeck.agentd"),
                           ("/usr/bin/lipo", "-archs", self.daemon),
                           ("/usr/bin/codesign", "-d", "--verbose=4", self.daemon))
        allowed |= (len(argv) == 5 and argv[:3] == ("/usr/bin/codesign", "--verify", "-R")
                    and re.fullmatch(r'=cdhash H"[0-9a-f]{40}"', argv[3]) is not None
                    and re.fullmatch(r"[1-9][0-9]*", argv[4]) is not None)
        require(allowed, "native subprocess outside read-only allowlist")
        environment = {k: v for k, v in os.environ.items()
                       if not k.upper().startswith(("ARKDECK_", "OHOS_HDC_", "DYLD_"))
                       and k != "CFFIXED_USER_HOME"}
        result = self.runner(list(argv), stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE, timeout=20, check=False, env=environment)
        require(result.returncode == 0 and len(result.stdout) + len(result.stderr) <= 4 * 1024 * 1024,
                "native identity command unavailable or over budget")
        return result.stderr if diagnostics else result.stdout

    def birth(self, pid):
        # Darwin public proc_bsdinfo / PROC_PIDTBSDINFO, also used by
        # arkdeck-platform/src/macos_server.rs::process_birth.
        class BSDInfo(ctypes.Structure):
            _fields_ = [(name, ctypes.c_uint32) for name in
                        ("flags", "status", "xstatus", "pid", "ppid", "uid", "gid", "ruid",
                         "rgid", "svuid", "svgid", "reserved")]
            _fields_ += [("comm", ctypes.c_char * 16), ("name", ctypes.c_char * 32)]
            _fields_ += [(name, ctypes.c_uint32) for name in
                         ("nfiles", "pgid", "pjobc", "tty", "tpgid", "nice")]
            _fields_ += [("seconds", ctypes.c_uint64), ("microseconds", ctypes.c_uint64)]
        library = ctypes.CDLL("/usr/lib/libproc.dylib")
        library.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64,
                                        ctypes.c_void_p, ctypes.c_int]
        library.proc_pidinfo.restype = ctypes.c_int
        info = BSDInfo()
        size = ctypes.sizeof(info)
        require(size == 136 and library.proc_pidinfo(pid, 3, 0, ctypes.byref(info), size) == size
                and info.pid == pid and info.uid == self.uid and info.seconds > 0
                and info.microseconds < 1000000,
                "native process birth/owner unavailable")
        return {"pid": pid, "uid": info.uid, "startSeconds": info.seconds,
                "startMicroseconds": info.microseconds}

    def socket_identity(self, path):
        parent = ordinary(path.parent, directory=True)
        metadata = path.lstat()
        require(parent.stat().st_uid == self.uid and stat.S_IMODE(parent.stat().st_mode) == 0o700
                and stat.S_ISSOCK(metadata.st_mode) and metadata.st_uid == self.uid
                and stat.S_IMODE(metadata.st_mode) == 0o600 and metadata.st_nlink == 1,
                "published socket is not the private account endpoint")
        return {"device": metadata.st_dev, "inode": metadata.st_ino}

    def snapshot(self, launch):
        service = launch["launchDomain"] + "/com.arkdeck.agentd"
        before = self.host_read("/bin/launchctl", "print", service).decode("utf-8")
        pid = self.existing.live_pid(before)
        self.existing.verify_live_endpoint(before)
        require(re.search(r"ARKDECK_RUNTIME_COMPOSITION\s*=>\s*production\s*$", before, re.MULTILINE),
                "live service composition is not production")
        birth = self.birth(pid)
        require(self.existing.process_path(pid) == Path(self.daemon), "live image differs from installed image")
        code_hash = self.existing.verify_live_code(pid, Path(self.daemon))
        endpoint = Path(launch["socketPath"])
        identity = self.socket_identity(endpoint)
        # Darwin SOL_LOCAL/LOCAL_PEERPID: connect only to inspect OS ownership;
        # no IPC bytes, arbitrary command or device operation are submitted.
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as peer:
            peer.settimeout(5)
            peer.connect(str(endpoint))
            require(peer.getsockopt(0, 2) == pid, "published socket is owned by a different process")
        require(self.socket_identity(endpoint) == identity and self.birth(pid) == birth
                and self.existing.process_path(pid) == Path(self.daemon), "native instance changed during read")
        after = self.host_read("/bin/launchctl", "print", service).decode("utf-8")
        require(self.existing.live_pid(after) == pid, "launchd instance changed during read")
        self.existing.verify_live_endpoint(after)
        return {**birth, "liveCodeDirectoryHash": code_hash, "socketIdentity": identity,
                "nativeImageVerified": True, "socketOwnerVerified": True}


def native_instance(config, service, native):
    launch, health = service.get("launchAgent"), service.get("daemonHealth")
    require(isinstance(launch, dict) and all(launch.get(k) is True for k in
            ("installed", "loaded", "socketPresent", "ready")) and launch.get("diagnostics") == [],
            "installed LaunchAgent is not ready")
    require(launch.get("launchDomain") == f"gui/{native.uid}"
            and launch.get("daemonPath") == config["daemon"]
            and launch.get("daemonSHA256") == config["daemonSha256"]
            and isinstance(launch.get("socketPath"), str) and PurePosixPath(launch["socketPath"]).is_absolute(),
            "installed service does not identify the configured image/endpoint")
    require(isinstance(health, dict) and health.get("status") == "ok"
            and health.get("catalogDigest") == config["catalogDigest"], "installed service health differs")
    observed = native.snapshot(launch)
    require(observed.get("nativeImageVerified") is True and observed.get("socketOwnerVerified") is True,
            "actual process/endpoint identity not proved")
    return {**observed, "daemonSHA256": config["daemonSha256"],
            "socketPath": launch["socketPath"], "catalogDigest": health["catalogDigest"]}


def run_once(out, step, arguments, cli, repository, daemon, *, runner=subprocess.run):
    require(re.fullmatch(r"[a-z0-9][a-z0-9.-]{0,63}", step), "capture step grammar differs")
    sys.path.insert(0, str(repository / "scripts"))
    from gj_record import capture
    registry = json.loads((repository / "rust/crates/arkdeck-cli/src/command_registry.json").read_text())
    leaf = validate_argv(arguments, registry)
    key = mutation_key(leaf, arguments, step)
    prior_guard(out, key)
    if leaf in (("artifact", "import", "hap"), ("artifact", "import", "native-library")):
        file = ordinary(Path(option(arguments, "--file")))
        require(file.is_relative_to(out / "inputs"), "import file outside Root protected inputs")
        expected = HAP if leaf[-1] == "hap" else (CANDIDATE if sha_file(file) == CANDIDATE[0] else GHOST)
        pin_file(file, expected)
    if "--inputs-file" in arguments:
        file = ordinary(Path(option(arguments, "--inputs-file")))
        require(file.is_relative_to(out / "inputs") and file.stat().st_size <= 65536, "typed input outside bounded Root inputs")
        json.loads(file.read_text(encoding="utf-8"), object_pairs_hook=unique)
    if leaf == ("agent", "run") and option(arguments, "--operation") == "deploy.native-library.app-owned@1":
        import ast
        module = ast.parse((repository / "scripts/gj_record/record.py").read_text())
        pins = [n.value.value for n in module.body if isinstance(n, ast.Assign)
                and any(isinstance(t, ast.Name) and t.id == "ROLLBACK_FIXTURE_SHA256" for t in n.targets)
                and isinstance(n.value, ast.Constant)]
        require(pins == [GHOST[0]], "reviewed rollback baseline is not published in protected main")
    sequence = len(capture.read_journal(out)) + 1
    prefix = out / ("mac-entry-" + str(sequence) + "-" + step)
    intent_path = prefix.with_suffix(prefix.suffix + ".intent.json")
    outcome_path = prefix.with_suffix(prefix.suffix + ".outcome.json")
    require(not (out / f"{sequence:04d}-{step}.json").exists(), "capture output collision")
    json_once(intent_path, {"schemaVersion": "arkdeck.mac-entry-intent/1", "step": step,
                           "mutationKey": key, "arguments": arguments, "outcomeUnknown": True,
                           "replayAllowed": False})
    outcome = {"schemaVersion": "arkdeck.mac-entry-outcome/1", "nativeExitCode": None,
               "outcomeUnknown": True, "replayAllowed": False, "failureCategory": None}
    env = {k: v for k, v in os.environ.items()
           if not k.upper().startswith(("ARKDECK_", "OHOS_HDC_"))}
    env.update({"ARKDECK_DAEMON_PATH": str(daemon), "ARKDECK_ANALYZER_PATH": str(daemon)})
    try:
        with prefix.with_suffix(prefix.suffix + ".stdout").open("xb") as stdout, prefix.with_suffix(prefix.suffix + ".stderr").open("xb") as stderr:
            def invoke(command, **ignored):
                try:
                    completed = runner(command, stdin=subprocess.DEVNULL, stdout=stdout,
                                       stderr=stderr, timeout=700, check=False, env=env, cwd=out)
                except subprocess.TimeoutExpired:
                    outcome["failureCategory"] = "outerTimeout"
                    raise
                stdout.flush()
                require(stdout.tell() <= 64 * 1024 * 1024, "CLI output exceeded capture bound")
                data = stdout.name and Path(stdout.name).read_bytes()
                outcome["nativeExitCode"] = completed.returncode
                outcome["outcomeUnknown"] = False
                try:
                    value = json.loads(data, object_pairs_hook=unique)
                    def unknown(v):
                        return (isinstance(v, dict) and (v.get("outcomeUnknown") is True or any(unknown(x) for x in v.values()))) or (isinstance(v, list) and any(unknown(x) for x in v))
                    require(isinstance(value, dict) and value.get("schemaVersion") == "arkdeck.cli.result/1", "CLI envelope absent")
                    outcome["outcomeUnknown"] = bool(unknown(value))
                except (ValueError, Stop):
                    outcome.update(outcomeUnknown=True, failureCategory="invalidOrUnknownEnvelope")
                return subprocess.CompletedProcess(command, completed.returncode, data)
            captured = capture.capture(out, step, [str(cli), *arguments], repository=repository,
                                       quiet=True, timeout=700, runner=invoke)
            require(captured["exitCode"] == outcome["nativeExitCode"], "capture exit changed")
    except BaseException:
        outcome["outcomeUnknown"] = True
        if outcome["failureCategory"] is None:
            outcome["failureCategory"] = "captureStopped"
        raise
    finally:
        json_once(outcome_path, outcome)
    require(outcome["outcomeUnknown"] is False, "unknown outcome retained; no replay")
    return outcome["nativeExitCode"]


def closed_ledger(items, states):
    def attention(v):
        if isinstance(v, dict):
            return (v.get("outcomeUnknown") is True or v.get("humanAction") is not None
                    or v.get("waitingForHuman") is True or any(attention(x) for x in v.values()))
        return isinstance(v, list) and any(attention(x) for x in v)
    require(all(isinstance(v, dict) and v.get("state") in states
                and v.get("outcomeUnknown") is False and not attention(v) for v in items),
            "complete ledger has active, unknown or human attention")


def preflight(config, repo, out, *, dispatch=run_once, native_factory=MacNative):
    """One Root invocation, read-only facts/full ledgers/physical projection."""
    sys.path.insert(0, str(repo / "scripts"))
    from gj_record import catalog, record
    from gj_record.run import Run
    def call(step, arguments):
        result = dispatch(out, step, [*arguments, "--output", "json"],
                          Path(config["cli"]), repo, Path(config["daemon"]))
        require(result == 0, "preflight query refused; retain captured output")
        row = Run.load(out).steps[-1]
        require(row.ok, "preflight query has no success envelope")
        return row
    call("preflight.facts.version", ["--version"])
    service = call("preflight.facts.service", ["runtime", "service", "status"])
    native = native_factory(repo, config)
    before = native_instance(config, service.result, native)
    for label, arguments in (
        ("health", ["runtime", "health"]), ("hdc", ["runtime", "hdc", "status"]),
        ("tools", ["runtime", "tool", "list"]), ("doctor", ["doctor", "--deep", "--require-healthy"]),
        ("operations", ["operation", "list"]),
    ):
        call("preflight.facts." + label, arguments)
    run = Run.load(out)
    expected = catalog.at_revision(repo, config["sourceRevision"])
    run.refuse_non_evidence(expected.digest)
    facts = record.fixed_facts(run, expected)
    require(facts["runtimeExecutableSHA256"] == config["daemonSha256"]
            and facts["cliBuildIdentity"] == "sha256:" + config["cliSha256"], "actual running image proof differs")
    operations = run.last("operation.list", lambda s: s.ok).items
    availability_by_operation = {}
    for reference in OPERATIONS:
        matches = [v for v in operations if v.get("reference") == reference]
        require(len(matches) == 1, "paired operation projection missing or duplicated")
        availability_by_operation[reference] = matches[0].get("availability") == "available"
    require(availability_by_operation["observe.device@1"] and availability_by_operation["capture.diagnostics@1"],
            "GJ1 operation unavailable; retain actual refusal")
    def census(kind):
        rows, revision, cursor, cursors = [], None, None, set()
        for number in range(1, 33):
            page = call("preflight." + kind + ".p" + str(number),
                        [kind, "list", "--page-size", "1000", *(["--cursor", cursor] if cursor else [])])
            value = page.result
            observed = value.get("snapshotRevision")
            require(isinstance(observed, str) and observed and (revision is None or observed == revision)
                    and type(value.get("hasMore")) is bool and isinstance(value.get("items"), list), "census page shape/snapshot differs")
            revision = observed
            rows.extend(page.items)
            cursor = value.get("nextCursor")
            if value["hasMore"] is False:
                require(cursor is None, "terminal census page has cursor")
                return rows
            require(isinstance(cursor, str) and cursor and cursor not in cursors, "census cursor differs")
            cursors.add(cursor)
        raise Stop("complete census exceeds bounded pages")
    jobs, agents = census("job"), census("agent")
    closed_ledger(jobs, {"planned", "succeeded", "recovered", "failed", "cancelled", "interrupted"})
    closed_ledger(agents, {"completed", "failed", "abandoned", "budgetExpired", "clockUntrusted"})
    candidates = call("preflight.candidates", ["device", "candidates"]).result
    require(candidates.get("schemaVersion") == "arkdeck.device-observations/1"
            and candidates.get("health") == "current" and isinstance(candidates.get("observations"), list)
            and isinstance(candidates.get("snapshotGeneration"), str)
            and re.fullmatch(r"[1-9][0-9]*", candidates["snapshotGeneration"]),
            "physical discovery is not a fresh projection")
    connected = [v for v in candidates["observations"] if v.get("authorizationState") == "Connected"]
    require(len(connected) == 1, "physical discovery must name exactly one Connected candidate")
    candidate = connected[0]
    require(all(isinstance(candidate.get(k), str) and candidate[k] for k in ("candidateKey", "observationId")),
            "physical discovery omitted observation identity")
    target, revision = candidate.get("adoptedTargetId"), candidate.get("bindingRevision")
    require(isinstance(target, str) and target and type(revision) is int and revision > 0,
            "Root must consume actual candidate/observation/generation through typed target adopt, then refresh preflight")
    shown = call("preflight.target", ["target", "show", "--target", target]).result
    available = call("preflight.availability", ["target", "availability", "--target", target]).result
    require(shown.get("targetId") == target and shown.get("bindingRevision") == revision
            and available.get("targetId") == target
            and (available.get("binding") or {}).get("bindingRevision") == revision
            and (available.get("binding") or {}).get("state") == "ready", "fresh target binding unavailable")
    scoped = (available.get("operations") or {}).get("items")
    require(isinstance(scoped, list), "scoped operation projection absent")
    for reference in OPERATIONS:
        matches = [v for v in scoped if v.get("reference") == reference]
        require(len(matches) == 1, "scoped operation missing or duplicated")
        availability_by_operation[reference] &= matches[0].get("availability") == "available"
    require(sha_file(Path(config["cli"])) == config["cliSha256"]
            and sha_file(Path(config["daemon"])) == config["daemonSha256"], "image changed during preflight")
    final_service = call("preflight.facts.service.end", ["runtime", "service", "status"])
    after = native_instance(config, final_service.result, native)
    require(before == after, "native PID/birth/image/socket/Catalog changed across preflight")
    run = Run.load(out)
    proof = {"classification": "macReadOnlyPreflightOnly", "runtimeSourceRevision": config["sourceRevision"],
             "catalogDigest": expected.digest, "captureCount": len(run.steps), "physicalTarget": target,
             "bindingRevision": revision, "jobCount": len(jobs), "agentCount": len(agents),
             "nativeInstance": after,
             "operationAvailable": availability_by_operation,
             "formalAcceptance": False, "hardwareEvidence": False}
    json_once(out / ("mac-entry-preflight-" + str(len(run.steps)) + ".json"), proof)
    print(json.dumps({"classification": proof["classification"], "closedLedgers": True,
                      "physicalBindingReady": True, "nativeInstanceVerified": True,
                      "operationAvailable": availability_by_operation,
                      "formalAcceptance": False, "hardwareEvidence": False}))
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="phase")
    material = sub.add_parser("verify-materials")
    for name in ("hap", "candidate", "ghost"):
        material.add_argument("--" + name, required=True, type=Path)
    take = sub.add_parser("capture")
    take.add_argument("--config", required=True, type=Path)
    take.add_argument("--step", required=True)
    take.add_argument("--execute", action="store_true")
    take.add_argument("arguments", nargs=argparse.REMAINDER)
    ready = sub.add_parser("preflight")
    ready.add_argument("--config", required=True, type=Path)
    ready.add_argument("--execute", action="store_true")
    args = parser.parse_args(argv)
    try:
        if args.phase is None:
            print(json.dumps({"classification": "offlineMacEntryPlan", "hardwareEvidence": False,
                              "sequence": ["verify-materials", "Root public RC install/identity and private Raw setup",
                                           "capture fixed facts/GJ1", "fresh gates/GJ2/full reads/restart",
                                           "fresh native gates/GJ3 forward and post-publish rollback", "unchanged gj_record assemble"],
                              "requires": ["actual Mac device access", "protected-main release images", "reviewed exact fixture adoption"],
                              "configKeys": ["schemaVersion", "repository", "sourceRevision", "cli", "cliSha256", "daemon", "daemonSha256", "out", "catalogDigest"]}))
            return 0
        if args.phase == "verify-materials":
            for name, expected in (("hap", HAP), ("candidate", CANDIDATE), ("ghost", GHOST)):
                pin_file(ordinary(getattr(args, name)), expected)
            print(json.dumps({"classification": "sameExactFixtureBytes", "allWholePinsMatch": True,
                              "hardwareEvidence": False, "boardTrustProved": False}))
            return 0
        require(args.execute, "capture requires explicit Root --execute; default/help remains offline")
        config = json.loads(args.config.read_text(encoding="utf-8"), object_pairs_hook=unique)
        repo, out = check_configuration(config)
        if args.phase == "preflight":
            return preflight(config, repo, out)
        arguments = args.arguments[1:] if args.arguments[:1] == ["--"] else args.arguments
        return run_once(out, args.step, arguments, Path(config["cli"]), repo, Path(config["daemon"]))
    except (Stop, OSError, ValueError, subprocess.TimeoutExpired):
        print("mac entry: stopped; retain intent/outcome and inspect privately; no automatic replay", file=sys.stderr)
        return 2
    except (Exception, KeyboardInterrupt):
        print("mac entry: local validation stopped; retained outputs require Root review", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
