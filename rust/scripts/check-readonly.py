#!/usr/bin/env python3
"""Record actual host-only CLI/control output, then validate the completed set.

This runs the built Rust binaries with no HDC tool or production endpoint. Unix
checks the real UDS exchanges. Windows checks the actual unsigned-daemon refusal;
positive installed-daemon and DAYU200 acceptance belongs to windows-spk3.ps1.
No fixture response is substituted for a daemon output.
"""
from __future__ import annotations

import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import platform
import socket
import subprocess
import tempfile
import time
import tomllib
import uuid

import jsonschema

ROOT = Path(__file__).resolve().parents[2]
BASELINE = ROOT / "spec/baselines/swift-single-v1.json"
CANDIDATE_INPUTS = ROOT / "spec/baselines/swift-candidate-inputs.json"
REGISTRY = ROOT / "Packages/ArkDeckKit/Contracts/control-protocol.json"
SUPPORTED = {"health", "doctor", "operation.list", "device.observations"}


def assert_boundaries() -> None:
    allowed = {
        "arkdeck-contract": set(),
        "arkdeck-platform": set(),
        "arkdeck-control": {"arkdeck-contract"},
        "arkdeck-hoststore": {"arkdeck-contract", "arkdeck-platform"},
        "arkdeck-provider-hdc": {"arkdeck-platform"},
        "arkdeck-client": {"arkdeck-contract", "arkdeck-platform"},
        "arkdeck-cli": {"arkdeck-contract", "arkdeck-client", "arkdeck-platform"},
        "arkdeck-agentd": {"arkdeck-contract", "arkdeck-control", "arkdeck-platform", "arkdeck-provider-hdc"},
    }
    manifests = list((ROOT / "rust/crates").glob("*/Cargo.toml"))
    assert len(manifests) == len(allowed), "review the composition boundary for new crates"
    for path in manifests:
        manifest = tomllib.loads(path.read_text(encoding="utf-8"))
        name = manifest["package"]["name"]
        scopes = [manifest, *manifest.get("target", {}).values()]
        internal = {key for scope in scopes for key in scope.get("dependencies", {})
                    if key.startswith("arkdeck-")}
        assert internal == allowed[name], f"unexpected dependency edge: {name}"
        assert manifest["package"]["publish"] == {"workspace": True}, name
        if name != "arkdeck-platform":
            assert manifest["lints"] == {"workspace": True}, f"unsafe must remain forbidden: {name}"
    workspace = tomllib.loads((ROOT / "rust/Cargo.toml").read_text(encoding="utf-8"))
    assert workspace["workspace"]["lints"]["rust"]["unsafe_code"] == "forbid"


def encode(value: dict) -> bytes:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode() + b"\n"


def read_json(path: Path) -> dict:
    return json.loads(path.read_bytes())


def contract_identity(registry: dict) -> str:
    canonical = json.dumps(registry, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(canonical).hexdigest()


def input_metadata(registry: dict) -> dict:
    path = CANDIDATE_INPUTS if CANDIDATE_INPUTS.is_file() else BASELINE
    contents = path.read_bytes()
    inputs = json.loads(contents)
    published = read_json(BASELINE)
    assert published["kind"] == "development"
    assert published["schemaVersion"] == "arkdeck.swift-development-baseline/1"
    published_commit = published["commit"]
    if path == CANDIDATE_INPUTS:
        assert inputs["kind"] == "candidate"
        assert inputs["schemaVersion"] == "arkdeck.swift-candidate-inputs/1"
        assert "commit" not in inputs, "candidate inputs have no published commit"
        assert inputs["publishedBaselineCommit"] == published_commit
    else:
        assert inputs["kind"] == "development"
        assert inputs["schemaVersion"] == "arkdeck.swift-development-baseline/1"
    identity = contract_identity(registry)
    assert inputs["contractIdentity"] == identity
    assert inputs["protocolVersion"] == registry["currentVersion"]
    assert inputs["methodCount"] == len(registry["methods"])
    return {"baseline": published_commit, "publishedBaselineCommit": published_commit,
            "inputKind": inputs["kind"], "inputDigest": inputs["inputDigest"],
            "inputManifestSHA256": hashlib.sha256(contents).hexdigest(),
            "contractIdentity": identity}


def record(directory: Path, rows: list, name: str, kind: str, data: bytes, **metadata) -> dict:
    path = directory / f"{len(rows):03}-{name}.{kind}"
    path.write_bytes(data)
    row = {"file": path.name, "kind": kind, "sha256": hashlib.sha256(data).hexdigest(), **metadata}
    rows.append(row)
    return row


def invoke(cli: Path, directory: Path, rows: list, environment: dict, name: str,
           arguments: list[str], exit_code: int, error: str | None = None) -> dict:
    command = [str(cli), "--output", "json", "--control-request-id", f"ctl-{name}", *arguments]
    result = subprocess.run(command, env=environment, capture_output=True, timeout=25)
    record(directory, rows, name, "cli.jsonl", result.stdout, exitCode=result.returncode,
           expectedExitCode=exit_code, expectedError=error)
    record(directory, rows, name, "stderr.txt", result.stderr)
    assert result.returncode == exit_code, (name, result.returncode, result.stdout, result.stderr)
    document = json.loads(result.stdout)
    if error:
        assert document["error"]["code"] == error, (name, document)
    return document


def request(registry: dict, method: str, identifier: str, params=None) -> dict:
    value = {"protocolVersion": registry["currentVersion"],
             "contractIdentity": contract_identity(registry),
             "id": identifier, "method": method}
    if params is not None:
        value["params"] = params
    return value


def exchange(endpoint: str, directory: Path, rows: list, name: str, data: bytes,
             method: str | None, expected_error: str | None = None,
             valid_request: bool = True) -> dict:
    record(directory, rows, name, "request.bin", data, method=method, validRequest=valid_request)
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(10)
        connection.connect(endpoint)
        try:
            connection.sendall(data)
        except BrokenPipeError:
            # An oversized frame may be rejected before its trailing bytes.
            # Read the refusal from this connection; never replay it.
            pass
        with connection.makefile("rb") as reader:
            response = reader.readline(8 * 1024 * 1024 + 1)
    record(directory, rows, name, "response.jsonl", response,
           method=method, expectedError=expected_error)
    value = json.loads(response)
    if expected_error:
        assert value["ok"] is False and value["error"]["code"] == expected_error, (name, value)
    else:
        assert value["ok"] is True, (name, value)
    return value


def wait_ready(endpoint: str, daemon: subprocess.Popen) -> None:
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        assert daemon.poll() is None, "daemon exited during startup"
        if os.name == "nt":
            wait_pipe = ctypes.WinDLL("kernel32", use_last_error=True).WaitNamedPipeW
            wait_pipe.argtypes = [ctypes.c_wchar_p, ctypes.c_uint32]
            wait_pipe.restype = ctypes.c_int
            if wait_pipe(endpoint, 50):
                return
        elif Path(endpoint).exists():
            return
        time.sleep(0.05)
    raise AssertionError("private test daemon did not become ready")


def validate_completed(directory: Path, rows: list, registry: dict) -> dict:
    # Called only after all producers have exited and every output is on disk.
    wire = jsonschema.Draft202012Validator(read_json(ROOT / "openspec/contracts/runtime-control-plane.schema.json"))
    cli = jsonschema.Draft202012Validator(read_json(ROOT / "openspec/contracts/cli-result.schema.json"))
    counts = {"controlResponses": 0, "cliEnvelopes": 0, "validRequests": 0}
    for row in rows:
        data = (directory / row["file"]).read_bytes()
        assert hashlib.sha256(data).hexdigest() == row["sha256"]
        kind = row["kind"]
        if kind == "request.bin" and row["validRequest"]:
            wire.validate(json.loads(data))
            counts["validRequests"] += 1
        elif kind in {"response.jsonl", "cli.jsonl"}:
            assert data.endswith(b"\n") and data.count(b"\n") == 1 and b"\r" not in data, row["file"]
            assert len(data) <= registry["maximumResponseFrameBytes"], row["file"]
            value = json.loads(data)
            (wire if kind == "response.jsonl" else cli).validate(value)
            method = row.get("method")
            if kind == "cli.jsonl":
                counts["cliEnvelopes"] += 1
                method = {"doctor": "doctor", "operation.list": "operation.list",
                          "device.candidates": "device.observations"}.get(value["command"])
            else:
                counts["controlResponses"] += 1
            if method in registry["methods"]:
                definitions = read_json(ROOT / f"spec/control/methods/{method}.json")["$defs"]
                if value["ok"]:
                    jsonschema.Draft202012Validator(definitions["result"]).validate(value["result"])
                elif kind == "response.jsonl":
                    jsonschema.Draft202012Validator(definitions["errorCode"]).validate(value["error"]["code"])
                    if "details" in value["error"]:
                        jsonschema.Draft202012Validator(definitions["errorDetails"]).validate(value["error"]["details"])
    return counts


def validate_spk3(directory: Path) -> None:
    """Validate existing Windows output only after the harness closes recording."""
    report = read_json(directory / "spk3.json")
    assert report["evidenceKind"] == "REAL_WINDOWS_HOST_PROBE"
    assert report.get("recordingComplete") is True, "SPK-3 producers have not all completed"
    rows = []
    for name, command in [("doctor", "doctor"), ("operation-list", "operation.list"),
                          ("device-candidates", "device.candidates")]:
        path = directory / f"{name}.stdout.json"
        data = path.read_bytes()
        assert json.loads(data)["command"] == command, path.name
        rows.append({"file": path.name, "kind": "cli.jsonl", "sha256": hashlib.sha256(data).hexdigest()})
    registry = read_json(REGISTRY)
    counts = validate_completed(directory, rows, registry)
    result = {"schemaVersion": "arkdeck.spk3-output-schema-check/1", "result": "PASS",
              "allRecordingsCompletedBeforeValidation": True, "counts": counts,
              "recordings": rows, "deviceAcceptance": False,
              **input_metadata(registry)}
    # This is a derived validation result; the raw host record is not rewritten.
    output = directory / "spk3-schema-validation.json"
    contents = json.dumps(result, indent=2) + "\n"
    if output.exists():
        assert output.read_text(encoding="utf-8") == contents, "existing validation result differs"
    else:
        output.write_text(contents, encoding="utf-8", newline="\n")
    print(json.dumps({"validationFile": str(output), **result}))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bin-dir", type=Path, default=ROOT / "rust/target/debug")
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument("--spk3-recordings", type=Path,
                        help="only validate a completed SPK-3 recording directory; start no processes")
    args = parser.parse_args()
    if args.spk3_recordings:
        if args.output_dir:
            parser.error("--spk3-recordings cannot be combined with --output-dir")
        validate_spk3(args.spk3_recordings.resolve())
        return
    assert_boundaries()
    nonce = uuid.uuid4().hex
    directory = (args.output_dir or ROOT / f"rust/target/readonly-check/{nonce}").resolve()
    directory.mkdir(parents=True, exist_ok=False)
    suffix = ".exe" if os.name == "nt" else ""
    cli = args.bin_dir.resolve() / f"arkdeck{suffix}"
    daemon_binary = args.bin_dir.resolve() / f"arkdeck-agentd{suffix}"
    registry = read_json(REGISTRY)
    metadata = input_metadata(registry)
    rows = []
    environment = {key: value for key, value in os.environ.items()
                   if not key.startswith(("ARKDECK_", "OHOS_HDC_"))}
    environment["ARKDECK_DAEMON_PATH"] = str(daemon_binary)
    with tempfile.TemporaryDirectory(prefix="arkro-") as temporary:
        endpoint = (rf"\\.\pipe\arkdeck-readonly-test-{nonce}" if os.name == "nt"
                    else str(Path(temporary).resolve() / "control.sock"))
        environment["ARKDECK_ENDPOINT"] = endpoint
        daemon = subprocess.Popen([str(daemon_binary)], env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            wait_ready(endpoint, daemon)
            if os.name == "nt":
                # The hosted build is unsigned. It must refuse the actual
                # server identity before health/business bytes are sent.
                for name, command in [("doctor", ["doctor"]), ("operations", ["operation", "list"]),
                                      ("candidates", ["device", "candidates"])]:
                    value = invoke(cli, directory, rows, environment, name, command, 69, "runtimeUnavailable")
                    assert "signing identity" in value["error"]["message"], value
            else:
                for name, command, code, error in [
                    ("doctor", ["doctor"], 0, None),
                    ("deep", ["doctor", "--deep"], 0, None),
                    ("healthy", ["doctor", "--require-healthy"], 69, "healthRequirementFailed"),
                    ("operations", ["operation", "list"], 0, None),
                    ("candidates", ["device", "candidates"], 1, "operationFailed"),
                ]:
                    invoke(cli, directory, rows, environment, name, command, code, error)
                for method in registry["methods"]:
                    expected = ("rejected" if method not in SUPPORTED or method == "device.observations" else None)
                    exchange(endpoint, directory, rows, method, encode(request(registry, method, method)), method, expected)
                for name, method, params, error in [
                    ("bad-deep", "doctor", {"deep": "true"}, "invalidParams"),
                    ("bad-health", "health", {"extra": True}, "invalidParams"),
                    ("bad-list", "operation.list", {"extra": True}, "invalidParams"),
                    ("bad-observations", "device.observations", {"candidateKey": "untrusted"}, "invalidInput"),
                    ("bad-following", "device.observations", {"following": None}, "invalidInput"),
                    ("old-following", "device.observations", {"following": {"candidate": "x", "observationId": "old", "observationGeneration": "1"}}, "resourceConflict"),
                ]:
                    exchange(endpoint, directory, rows, name, encode(request(registry, method, name, params)), method, error)
                valid = request(registry, "health", "negative")
                for name, data, method, error in [
                    ("malformed", b"{\n", None, "malformedFrame"),
                    ("utf8", b"\xff\n", None, "malformedFrame"),
                    ("crlf", encode(valid)[:-1] + b"\r\n", None, "malformedFrame"),
                    ("duplicate", encode(valid)[:-2] + b',"id":"again"}\n', None, "malformedFrame"),
                    ("forged-origin", encode(dict(valid, arkdeckOrigin={"foregroundConsole": True})), None, "malformedFrame"),
                    ("wrong-version", encode(dict(valid, protocolVersion="2.0.0")), "health", "unsupportedProtocolVersion"),
                    ("wrong-identity", encode(dict(valid, contractIdentity="0" * 64)), "health", "unsupportedProtocolVersion"),
                    ("old-method", encode(dict(valid, method="device.candidates")), None, "unknownMethod"),
                    ("oversized", b"x" * registry["maximumRequestFrameBytes"] + b"\n", None, "malformedFrame"),
                ]:
                    exchange(endpoint, directory, rows, name, data, method, error, valid_request=False)
            invoke(cli, directory, rows, environment, "unknown-command", ["job", "run"], 64, "invalidCommand")
            invoke(cli, directory, rows, environment, "bad-option", ["doctor", "--shell", "x"], 64, "invalidOption")
        finally:
            daemon.terminate()
            try:
                stdout, stderr = daemon.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                daemon.kill()
                stdout, stderr = daemon.communicate(timeout=5)
            record(directory, rows, "daemon", "stdout.txt", stdout)
            record(directory, rows, "daemon", "stderr.txt", stderr)
            (directory / "recordings.json").write_text(json.dumps(rows, indent=2) + "\n")
    counts = validate_completed(directory, rows, registry)
    summary = {"schemaVersion": "arkdeck.rust-readonly-host-check/1", "kind": "host-test",
               "result": "PASS", "platform": platform.platform(), "deviceAcceptance": False,
               "windowsInstalledDaemonAcceptance": False, "allRecordingsCompletedBeforeValidation": True,
               **metadata, "counts": counts,
               "binaries": {path.name: hashlib.sha256(path.read_bytes()).hexdigest() for path in [cli, daemon_binary]}}
    (directory / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps({"recordingDirectory": str(directory), **summary}))


if __name__ == "__main__":
    main()
