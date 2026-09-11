#!/usr/bin/env python3
"""Exercise DevEco registration through real CLIs and an isolated Rust daemon.

The installed DevEco Contents root is only read. The fresh state directory and
all receipts are retained for independent Swift readback. This is a native host
check, never device or hardware acceptance. A missing installation is an
explicit SKIP, not a native PASS. Registration is never retried after uncertainty.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import socket
import stat
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
SOURCE_ROLES = {
    "Resources/product-info.json": 64 * 1024,
    "sdk/default/sdk-pkg.json": 64 * 1024,
    "tools/node/bin/node": 256 * 1024 * 1024,
    "tools/hvigor/bin/hvigorw.js": 8 * 1024 * 1024,
    "_CodeSignature/CodeResources": 32 * 1024 * 1024,
}
MAX_RESPONSE_BYTES = 8 * 1024 * 1024
PROCESS_TIMEOUT_SECONDS = 300
RUN_TIMEOUT_SECONDS = 900


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"),
                      ensure_ascii=False, allow_nan=False).encode()


def metadata(value):
    # Reading may update atime; it is intentionally not a mutation assertion.
    return {"device": value.st_dev, "inode": value.st_ino, "mode": value.st_mode,
            "uid": value.st_uid, "gid": value.st_gid, "links": value.st_nlink,
            "bytes": value.st_size, "modifiedNs": value.st_mtime_ns,
            "changedNs": value.st_ctime_ns}


def file_fingerprint(path, maximum):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    with os.fdopen(descriptor, "rb") as stream:
        before = os.fstat(stream.fileno())
        if not stat.S_ISREG(before.st_mode) or before.st_size > maximum:
            raise ValueError(f"source or metadata file exceeds its bounded role: {path}")
        digest = hashlib.sha256()
        total = 0
        while data := stream.read(1024 * 1024):
            total += len(data)
            if total > maximum:
                raise ValueError(f"file grew beyond its bounded role: {path}")
            digest.update(data)
        if metadata(os.fstat(stream.fileno())) != metadata(before):
            raise ValueError(f"file changed during observation: {path}")
    if metadata(os.lstat(path)) != metadata(before):
        raise ValueError(f"file identity changed during observation: {path}")
    return {**metadata(before), "sha256": digest.hexdigest()}


def source_fingerprint(source):
    directories = {source, source.parent, source / "sdk/default/openharmony"}
    result = {}
    for role, limit in SOURCE_ROLES.items():
        path = source / role
        result[role] = file_fingerprint(path, limit)
        parent = path.parent
        while parent != source:
            directories.add(parent)
            parent = parent.parent
    for directory in sorted(directories):
        value = os.lstat(directory)
        if not stat.S_ISDIR(value.st_mode):
            raise ValueError(f"source role directory is not a physical directory: {directory}")
        key = ".." if directory == source.parent else str(directory.relative_to(source))
        result[f"directory:{key}"] = metadata(value)
    return result


def tree_fingerprint(root, *, hash_files=False):
    """Bounded, no-follow metadata census; optionally hash private index bytes."""
    if not root.exists() and not root.is_symlink():
        return {"exists": False}
    result = {}
    pending = [root]
    while pending:
        path = pending.pop()
        if len(result) >= 20_000:
            raise ValueError("Bootstrap metadata census exceeds its entry bound")
        value = os.lstat(path)
        entry = metadata(value)
        if stat.S_ISLNK(value.st_mode):
            entry["link"] = os.readlink(path)
        elif stat.S_ISDIR(value.st_mode):
            pending.extend(sorted(path.iterdir(), reverse=True))
        elif hash_files and stat.S_ISREG(value.st_mode):
            entry = file_fingerprint(path, 4 * 1024 * 1024)
        result[str(path.relative_to(root))] = entry
    return result


def check(condition, message):
    if not condition:
        raise AssertionError(message)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bin-dir", type=Path, default=ROOT / "rust/target/debug")
    parser.add_argument("--cli-path", type=Path,
                        help="optional registration CLI, including the current Swift CLI")
    parser.add_argument("--source-root", type=Path,
                        default=Path("/Applications/DevEco-Studio.app/Contents"))
    parser.add_argument("--record-frames", type=Path,
                        help="also save the actual direct typed exchanges to this new file")
    args = parser.parse_args()
    if sys.platform != "darwin" or not args.source_root.exists():
        print(json.dumps({"result": "SKIP", "kind": "isolated-native-host-test",
                          "reason": "macOSRequired" if sys.platform != "darwin" else "DevEcoContentsUnavailable",
                          "nativeVerificationPerformed": False, "deviceAcceptance": False,
                          "sourceRoot": str(args.source_root)}))
        return 0
    if not args.source_root.is_absolute():
        parser.error("--source-root must be an absolute installed Contents root")
    if args.record_frames and args.record_frames.exists():
        parser.error("--record-frames must name a new output file")

    daemon = (args.bin_dir / "arkdeck-agentd").resolve(strict=True)
    inspect_cli = (args.bin_dir / "arkdeck").resolve(strict=True)
    register_cli = (args.cli_path or inspect_cli).resolve(strict=True)
    source = args.source_root
    installed = Path.home() / "Library/Application Support/ArkDeck/Bootstrap/v1"
    registry = json.loads((ROOT / "Packages/ArkDeckKit/Contracts/control-protocol.json").read_bytes())
    identity = hashlib.sha256(canonical(registry)).hexdigest()
    run_root = Path(tempfile.mkdtemp(prefix="arkdeck-deveco-register-", dir="/private/tmp")).resolve()
    state = run_root / "state"
    state.mkdir(mode=0o700)
    endpoint = state / "a.sock"
    bootstrap = state / "bootstrap"
    env = {key: value for key, value in os.environ.items() if not key.startswith("ARKDECK_")}
    env.update(ARKDECK_DEVELOPMENT_STATE_ROOT=str(state), ARKDECK_ENDPOINT=str(endpoint),
               ARKDECK_DAEMON_PATH=str(daemon))
    deadline = time.monotonic() + RUN_TIMEOUT_SECONDS
    children = []
    logs = []
    frames = []
    emissions = []
    source_before = installed_before = None
    native_verified = False
    uncertain = False
    report = {"result": "FAIL", "kind": "isolated-native-host-test", "deviceAcceptance": False,
              "fixtureRoot": str(run_root), "stateRoot": str(state), "bootstrapRoot": str(bootstrap),
              "sourceRoot": str(source), "contractIdentity": identity,
              "protocolVersion": registry["currentVersion"], "deviceDispatchCount": 0,
              "daemonSHA256": hashlib.sha256(daemon.read_bytes()).hexdigest(),
              "registrationCLISHA256": hashlib.sha256(register_cli.read_bytes()).hexdigest(),
              "inspectionCLISHA256": hashlib.sha256(inspect_cli.read_bytes()).hexdigest()}

    def remaining(maximum=PROCESS_TIMEOUT_SECONDS):
        seconds = min(maximum, deadline - time.monotonic())
        check(seconds > 0, "overall host-check deadline expired; no registration retry was issued")
        return seconds

    def stop(child):
        if child.poll() is None:
            child.terminate()
            try:
                child.wait(timeout=10)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait(timeout=10)

    def start():
        stderr_path = run_root / f"daemon-{len(children) + 1}.stderr.log"
        stderr = stderr_path.open("xb")
        logs.append(stderr)
        child = subprocess.Popen([str(daemon)], env=env, stdout=subprocess.DEVNULL, stderr=stderr)
        children.append(child)
        started = time.monotonic() + remaining(20)
        while time.monotonic() < started:
            check(child.poll() is None, f"isolated Rust daemon exited; inspect {stderr_path}")
            if endpoint.exists():
                try:
                    with socket.socket(socket.AF_UNIX) as connection:
                        connection.settimeout(1)
                        connection.connect(str(endpoint))
                    return child
                except OSError:
                    pass
            time.sleep(.02)
        raise AssertionError(f"isolated Rust daemon did not bind; inspect {stderr_path}")

    def exchange(method, params=None):
        nonlocal uncertain
        request = {"protocolVersion": registry["currentVersion"], "contractIdentity": identity,
                   "id": f"deveco-wire-{len(frames) + 1}", "method": method}
        if params is not None:
            request["params"] = params
        with socket.socket(socket.AF_UNIX) as connection:
            connection.settimeout(remaining())
            connection.connect(str(endpoint))
            connection.sendall(canonical(request) + b"\n")
            with connection.makefile("rb") as reader:
                payload = reader.readline(MAX_RESPONSE_BYTES + 1)
        check(len(payload) <= MAX_RESPONSE_BYTES and payload.endswith(b"\n"), "invalid bounded control frame")
        response = json.loads(payload)
        check(response.get("id") == request["id"], "control response identity mismatch")
        row = {"protocolVersion": registry["currentVersion"], "method": method, **response}
        if params is not None:
            row["params"] = params
        row.pop("id")
        frames.append(row)
        if response.get("error", {}).get("code") in {"outcomeUnknown", "clientTimeout"}:
            uncertain = True
            raise AssertionError("Runtime reported uncertainty; no registration retry was issued")
        return response

    def health():
        response = exchange("health")
        check(response.get("ok") is True, "isolated health request failed")
        value = response["result"]
        check(value.get("contractIdentity") == identity and value.get("protocolVersion") == registry["currentVersion"],
              "binary identity does not match this isolated input view")
        check({"runtime.tool.register", "runtime.tool.inspect"} <= set(value.get("publishedMethods", [])),
              "the tested binary does not publish the required Bootstrap methods")
        report["publishedMethodCount"] = len(value["publishedMethods"])

    def command(cli, arguments, expected=0, error_code=None):
        nonlocal uncertain
        request_id = f"deveco-cli-{len(emissions) + 1}"
        argv = [str(cli), *arguments, "--socket", str(endpoint), "--output", "json", "--control-request-id", request_id]
        started = time.monotonic()
        try:
            completed = subprocess.run(argv, env=env, capture_output=True, timeout=remaining())
        except subprocess.TimeoutExpired as error:
            uncertain = "register" in arguments
            emissions.append({"argv": argv, "timedOut": True,
                              "stdout": (error.stdout or b"").decode(errors="replace"),
                              "stderr": (error.stderr or b"").decode(errors="replace")})
            raise AssertionError("CLI wait expired; no registration retry was issued") from error
        entry = {"argv": argv, "exitCode": completed.returncode,
                 "elapsedSeconds": round(time.monotonic() - started, 3),
                 "stdout": completed.stdout.decode(errors="replace"),
                 "stderr": completed.stderr.decode(errors="replace")}
        emissions.append(entry)
        try:
            value = json.loads(completed.stdout)
        except ValueError:
            uncertain = "register" in arguments
            raise
        if value.get("error", {}).get("code") in {"outcomeUnknown", "clientTimeout"}:
            uncertain = True
            raise AssertionError("CLI reported uncertainty; no registration retry was issued")
        check(completed.returncode == expected, f"unexpected CLI exit {completed.returncode}; inspect cli-results.jsonl")
        check(value.get("meta", {}).get("controlRequestId") == request_id, "CLI response identity mismatch")
        if error_code is None:
            check(value.get("ok") is True, "CLI did not return a successful registration/read result")
        else:
            check(value.get("ok") is False and value.get("error", {}).get("code") == error_code,
                  f"CLI did not preserve {error_code}")
            check("result" not in value, "failed CLI query exposed a success result")
        return value

    def same_metadata(baseline):
        check(tree_fingerprint(bootstrap, hash_files=True) == baseline,
              "a repeated registration, read or refusal changed Bootstrap metadata")

    try:
        source_before = source_fingerprint(source)
        installed_before = tree_fingerprint(installed)
        report["sourceClosedRolesFingerprintSHA256"] = hashlib.sha256(canonical(source_before)).hexdigest()
        report["installedBootstrapMetadataFingerprintSHA256"] = hashlib.sha256(canonical(installed_before)).hexdigest()
        first = start()
        health()
        register_arguments = ["runtime", "tool", "register", "--kind", "deveco", "--root", str(source)]
        value = command(register_cli, register_arguments)["result"]
        check(value.get("schemaVersion") == "arkdeck.runtime-tool/1" and value.get("kind") == "deveco"
              and value.get("state") == "available" and value.get("generation") == "1"
              and value.get("source") == "registeredRoot" and value.get("selected") is False
              and value.get("contentRetained") is False, "registration projection is not an unselected DevEco candidate")
        digest = value.get("contentDigest", "")
        check(len(digest) == 64 and all(c in "0123456789abcdef" for c in digest)
              and value.get("toolRef") == f"toolchain:sha256:{digest}", "registration content identity is inconsistent")
        check(value.get("trust", {}).get("signature") == "verified"
              and value["trust"].get("executionAssessment") == "notPerformed",
              "registration did not return verified native content without execution")
        native_verified = True
        report["toolReference"] = value["toolRef"]
        check((bootstrap / "deveco-toolchains.json").is_file(), "registration did not persist its own metadata")
        baseline = tree_fingerprint(bootstrap, hash_files=True)
        check(command(register_cli, register_arguments)["result"] == value, "repeat changed the public projection")
        same_metadata(baseline)
        stop(first)
        start()
        health()
        # The optional Swift executable is used for registration only. Inspect
        # always uses the typed Rust consumer, never Swift's legacy local store.
        check(command(inspect_cli, ["runtime", "tool", "inspect", "--tool", value["toolRef"]])["result"] == value,
              "fresh daemon could not inspect the exact persisted registration")
        same_metadata(baseline)
        check(command(register_cli, register_arguments)["result"] == value, "restart re-registration changed the projection")
        same_metadata(baseline)
        missing = state / "missing.app/Contents"
        command(register_cli, ["runtime", "tool", "register", "--kind", "deveco", "--root", str(missing)],
                expected=77, error_code="fileIdentityChanged")
        same_metadata(baseline)
        for params in [{"kind": "hdc", "root": str(source)}, {"kind": "deveco", "root": "relative"}]:
            denied = exchange("runtime.tool.register", params)
            check(denied.get("ok") is False and denied.get("error", {}).get("code") == "invalidParams",
                  "invalid registration parameters were not refused")
            check(denied["error"].get("details") == {"phase": "bootstrapRegistryOwner", "newDispatchCount": 0},
                  "registration refusal lost its owner/zero-device-dispatch proof")
            same_metadata(baseline)
        command(register_cli, ["runtime", "tool", "register", "--kind", "deveco", "--root", "relative"],
                expected=65, error_code="invalidInput")
        same_metadata(baseline)
        report["bootstrapMetadataFingerprint"] = baseline
        report["result"] = "PASS"
    except (AssertionError, OSError, ValueError, subprocess.SubprocessError) as error:
        report["failure"] = str(error)
    finally:
        for child in children:
            stop(child)
        for log in logs:
            log.close()
        for key, before, observe in [
            ("sourceClosedRolesUnchanged", source_before, lambda: source_fingerprint(source)),
            ("installedBootstrapMetadataUnchanged", installed_before, lambda: tree_fingerprint(installed)),
        ]:
            try:
                report[key] = before is not None and observe() == before
                if not report[key]:
                    report["result"] = "FAIL"
                    report.setdefault("failure", f"{key} could not be verified")
            except (OSError, ValueError) as error:
                report[key] = False
                report["result"] = "FAIL"
                report.setdefault("failure", str(error))
        report.update(nativeVerificationPerformed=native_verified, uncertainHostPublication=uncertain,
                      registrationRetriesAfterUncertainty=0, cliCommands=len(emissions),
                      directControlExchanges=len(frames), fixtureRetained=True)
        (run_root / "cli-results.jsonl").write_bytes(b"".join(canonical(row) + b"\n" for row in emissions))
        frame_bytes = b"".join(canonical(row) + b"\n" for row in frames)
        (run_root / "control-frames.jsonl").write_bytes(frame_bytes)
        (run_root / "summary.json").write_bytes(canonical(report) + b"\n")
        if args.record_frames:
            args.record_frames.parent.mkdir(parents=True, exist_ok=True)
            with args.record_frames.open("xb") as output:
                output.write(frame_bytes)
        print(json.dumps(report, sort_keys=True))
    return 0 if report["result"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
