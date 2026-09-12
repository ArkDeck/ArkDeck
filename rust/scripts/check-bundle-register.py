#!/usr/bin/env python3
"""Exercise the real Rust Bundle RPC/CLI with source-created unsigned fixtures.

Only fresh temporary state is used. No native signed source is copied, helper is
executed, or installed owner is activated. Success registration requires separate
native evidence; this check proves closed input, trust refusal, durable initial
state, restart, lock/quota failures and no replay after a lost owner response.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[2]
METHOD = "runtime.bundle.register"

def encoded(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()

def require(condition, message):
    if not condition:
        raise AssertionError(message)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bin-dir", type=Path, default=ROOT / "rust/target/debug")
    args = parser.parse_args()
    if sys.platform != "darwin":
        print(json.dumps({"result":"SKIP", "reason":"macOSRequired", "deviceAcceptance":False}))
        return 0
    import fcntl
    daemon, cli = [(args.bin_dir / name).resolve(strict=True) for name in ["arkdeck-agentd", "arkdeck"]]
    registry = json.loads((ROOT / "Packages/ArkDeckKit/Contracts/control-protocol.json").read_bytes())
    require(METHOD in registry["methods"], "candidate Bundle registration contract is required")
    identity = hashlib.sha256(encoded(registry)).hexdigest()
    run = Path(tempfile.mkdtemp(prefix="bundle-register-process-", dir="/private/tmp"))
    source = run / "Unsigned.app"
    (source / "Contents/MacOS").mkdir(parents=True, mode=0o700)
    for directory in [source, source / "Contents"]:
        directory.chmod(0o700)
    info = source / "Contents/Info.plist"
    info.write_bytes(b'<plist><dict><key>CFBundleIdentifier</key><string>com.arkdeck.agentd</string><key>CFBundleExecutable</key><string>arkdeck-agentd</string></dict></plist>')
    info.chmod(0o600)
    executable = source / "Contents/MacOS/arkdeck-agentd"
    executable.write_bytes(b"non-executable source fixture bytes")
    executable.chmod(0o700)
    before = {str(p.relative_to(source)): p.read_bytes() for p in [info, executable]}
    environment = {k:v for k,v in os.environ.items() if not k.startswith("ARKDECK_")}
    environment["ARKDECK_DAEMON_PATH"] = str(daemon)
    children, logs, frames, calls = [], [], [], []
    report = {"result":"FAIL", "kind":"isolated-unsigned-host-test", "deviceAcceptance":False,
              "nativeRegistrationAcceptance":False, "fixtureRoot":str(run), "contractIdentity":identity}

    def stop(child):
        if child.poll() is None:
            child.terminate()
            try: child.wait(timeout=10)
            except subprocess.TimeoutExpired:
                child.kill(); child.wait(timeout=10)

    def start(state):
        state.mkdir(mode=0o700, exist_ok=True)
        endpoint = state / "a.sock"
        log = (run / f"daemon-{len(children)}.log").open("xb")
        logs.append(log)
        child = subprocess.Popen([str(daemon)], env={**environment, "ARKDECK_DEVELOPMENT_STATE_ROOT":str(state),
            "ARKDECK_ENDPOINT":str(endpoint)}, stdout=subprocess.DEVNULL, stderr=log)
        children.append(child)
        for _ in range(500):
            require(child.poll() is None, "isolated daemon exited")
            if endpoint.exists():
                try:
                    with socket.socket(socket.AF_UNIX) as probe:
                        probe.settimeout(1); probe.connect(str(endpoint))
                    return child, endpoint
                except OSError: pass
            time.sleep(.02)
        raise AssertionError("isolated daemon did not bind")

    def command(endpoint, arguments, expected=None):
        result = subprocess.run([str(cli), *arguments, "--socket", str(endpoint), "--output", "json"],
                                env=environment, capture_output=True, timeout=30)
        value = json.loads(result.stdout)
        calls.append({"arguments":arguments, "exitCode":result.returncode, "value":value})
        if expected:
            require(result.returncode != 0 and value.get("error",{}).get("code") == expected, f"expected {expected}: {value}")
            require("result" not in value, "failed registration exposed success")
        else: require(result.returncode == 0 and value.get("ok") is True, f"CLI failed: {value}")
        return value

    def exchange(endpoint, params):
        request = {"protocolVersion":registry["currentVersion"], "contractIdentity":identity,
                   "id":"bundle-wire", "method":METHOD, "params":params}
        with socket.socket(socket.AF_UNIX) as connection:
            connection.settimeout(30); connection.connect(str(endpoint)); connection.sendall(encoded(request)+b"\n")
            with connection.makefile("rb") as reader: response=json.loads(reader.readline(4*1024*1024+1))
        frames.append({"method":METHOD, "protocolVersion":registry["currentVersion"], "params":params,
                       **{k:v for k,v in response.items() if k != "id"}})
        return response

    register = ["runtime", "bundle", "register", "--kind", "daemon-bundle", "--file", str(source)]
    try:
        state = run / "state"; first, endpoint = start(state)
        command(endpoint, register, "admissionDenied")
        bootstrap = state / "bootstrap"; index = (bootstrap / "bundles.json").read_bytes()
        require(json.loads(index)["records"] == [], "untrusted Bundle acquired a record")
        require(sorted(p.name for p in bootstrap.iterdir()) == [".lock", "bundles.json"], "untrusted capture leaked staging")
        stop(first); _, endpoint = start(state)
        require(command(endpoint, ["runtime", "bundle", "list"])["result"]["items"] == [], "restart did not read empty registry")
        require((bootstrap / "bundles.json").read_bytes() == index, "restart changed registration state")
        with (bootstrap / ".lock").open("rb") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            command(endpoint, register, "resourceConflict")
        for params in [{}, {"kind":"hdc","file":str(source)}, {"kind":"daemon-bundle","file":"relative"},
                       {"kind":"daemon-bundle","file":str(source),"digest":"caller"}]:
            require(exchange(endpoint, params).get("error",{}).get("code") == "invalidParams", "invalid request reached owner")
        for n in range(4): (bootstrap / f".staging-retained-{n}").mkdir(mode=0o700)
        command(endpoint, register, "quotaExceeded")
        require((bootstrap / "bundles.json").read_bytes() == index, "quota refusal changed index")
        # Separate fresh state exercises a lost real response after the owner
        # initialized its durable index and refused unsigned captured bytes.
        _, lost_endpoint = start(run / "lost")
        proxy = run / "proxy.sock"; seen, errors = [], []
        with socket.socket(socket.AF_UNIX) as listener:
            listener.bind(str(proxy)); proxy.chmod(0o600); listener.listen(2); listener.settimeout(30)
            def lose_response():
                try:
                    with listener.accept()[0] as downstream, socket.socket(socket.AF_UNIX) as upstream:
                        downstream.settimeout(30); upstream.settimeout(30); upstream.connect(str(lost_endpoint))
                        with downstream.makefile("rb") as incoming, upstream.makefile("rb") as outgoing:
                            for n in range(2):
                                raw = incoming.readline(4*1024*1024+1); request = json.loads(raw); seen.append(request)
                                upstream.sendall(raw); response = outgoing.readline(4*1024*1024+1)
                                if n == 0: downstream.sendall(response)
                                else:
                                    require(request["method"] == METHOD and json.loads(response).get("error",{}).get("code") == "admissionDenied", "unexpected lost owner response")
                    listener.settimeout(.2)
                    try:
                        extra, _ = listener.accept(); extra.close(); raise AssertionError("CLI replayed registration")
                    except socket.timeout: pass
                except BaseException as error: errors.append(error)
            thread = threading.Thread(target=lose_response); thread.start()
            try: command(proxy, register, "outcomeUnknown")
            finally: thread.join(timeout=35)
            require(not thread.is_alive() and not errors, f"lost response check failed: {errors}")
        require(len(seen) == 2, "registration must be called exactly once after health")
        require(command(lost_endpoint, ["runtime", "bundle", "list"])["result"]["items"] == [], "lost response changed retained inventory")
        report.update(result="PASS", cliCommands=len(calls), checks=["nativeTrustRefusal", "closedRequest", "durableEmptyIndex", "restart", "sharedLock", "stagingQuota", "lostOwnerResponseNoReplay"])
    finally:
        for child in children: stop(child)
        for log in logs: log.close()
        report["sourceUnchanged"] = all(p.read_bytes() == before[str(p.relative_to(source))] for p in [info, executable])
        (run / "report.json").write_bytes(encoded(report))
        (run / "frames.jsonl").write_bytes(b"".join(encoded(row)+b"\n" for row in frames))
        (run / "cli-results.jsonl").write_bytes(b"".join(encoded(row)+b"\n" for row in calls))
        print(json.dumps(report, sort_keys=True))
        require(report["sourceUnchanged"], "source fixture changed")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
