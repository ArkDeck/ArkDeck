#!/usr/bin/env python3
"""Real CLI/daemon HDC registration in fresh temporary registries only.

No captured executable is launched or selected. The default native system file
is a storage sample, not HDC/device evidence; --source-file opts into real HDC
bytes. Library checkpoint tests cover source races and publication interruption.
This process check covers native writes/restart, refusals and an actually lost
post-publication response. It never retries an uncertain registration.
"""
from __future__ import annotations
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import socket
import shutil
import subprocess
import sys
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("deveco_check", Path(__file__).with_name("check-deveco-register.py"))
common = importlib.util.module_from_spec(spec)
spec.loader.exec_module(common)
canonical, check = common.canonical, common.check


def source_fingerprint(source):
    paths = [source]
    sibling = source.parent / "libusb_shared.dylib"
    if sibling.exists():
        paths.append(sibling)
    result = {str(p): common.file_fingerprint(p, 256 * 1024 * 1024) for p in paths}
    for parent in {p.parent for p in paths}:
        result[str(parent)] = common.metadata(parent.lstat())
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bin-dir", type=Path, default=ROOT / "rust/target/debug")
    parser.add_argument("--source-file", type=Path, default=Path("/usr/bin/true"))
    parser.add_argument("--record-variants", action="store_true",
                        help="also record native quarantine and saved-metadata preservation fixtures; no selection operation")
    args = parser.parse_args()
    if sys.platform != "darwin":
        print(json.dumps({"result": "SKIP", "reason": "macOSRequired", "deviceAcceptance": False}))
        return 0
    import fcntl
    source = args.source_file
    check(source.is_absolute() and source.is_file(), "an existing absolute native source file is required")
    daemon, cli = [(args.bin_dir / name).resolve(strict=True) for name in ["arkdeck-agentd", "arkdeck"]]
    contract = json.loads((ROOT / "Packages/ArkDeckKit/Contracts/control-protocol.json").read_bytes())
    identity = hashlib.sha256(canonical(contract)).hexdigest()
    run = Path(tempfile.mkdtemp(prefix="arkdeck-hdc-rpc-", dir="/private/tmp"))
    installed = Path.home() / "Library/Application Support/ArkDeck/Bootstrap/v1"
    before_source = source_fingerprint(source)
    before_installed = common.tree_fingerprint(installed)
    children, logs, frames, cli_rows = [], [], [], []
    report = {"result": "FAIL", "kind": "isolated-native-host-test", "deviceAcceptance": False,
              "sourceFile": str(source), "fixtureRoot": str(run), "contractIdentity": identity,
              "daemonSHA256": hashlib.sha256(daemon.read_bytes()).hexdigest(),
              "cliSHA256": hashlib.sha256(cli.read_bytes()).hexdigest()}
    env = {k: v for k, v in os.environ.items() if not k.startswith("ARKDECK_")}
    env["ARKDECK_DAEMON_PATH"] = str(daemon)
    deadline = time.monotonic() + 300

    def stop(child):
        if child.poll() is None:
            child.terminate()
            try:
                child.wait(timeout=10)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait(timeout=10)

    def start(state):
        state.mkdir(mode=0o700, exist_ok=True)
        endpoint = state / "a.sock"
        log = (run / f"daemon-{len(children)}.log").open("xb")
        logs.append(log)
        child = subprocess.Popen([str(daemon)], env={**env, "ARKDECK_DEVELOPMENT_STATE_ROOT": str(state),
                                  "ARKDECK_ENDPOINT": str(endpoint)}, stdout=subprocess.DEVNULL, stderr=log)
        children.append(child)
        for _ in range(500):
            check(child.poll() is None, "temporary daemon exited")
            if endpoint.exists():
                try:
                    with socket.socket(socket.AF_UNIX) as connection:
                        connection.settimeout(1)
                        connection.connect(str(endpoint))
                    break
                except OSError:
                    pass
            time.sleep(.02)
        else:
            raise AssertionError("temporary daemon did not bind")
        # The development daemon binds its socket before it creates and opens
        # the state children (bootstrap included), so a connect only proves the
        # listener exists. Requests are served once every store is open, so one
        # health round trip is the readiness signal, as in the sibling owner
        # checks. Callers seed <state>/bootstrap right after start(); without
        # this the corrupt/quota fixtures raced the daemon's mkdir. The probe is
        # readiness only and is not recorded as evidence.
        request = {"protocolVersion": contract["currentVersion"], "contractIdentity": identity,
                   "id": "hdc-ready", "method": "health"}
        with socket.socket(socket.AF_UNIX) as connection:
            connection.settimeout(30)
            connection.connect(str(endpoint))
            connection.sendall(canonical(request) + b"\n")
            with connection.makefile("rb") as reader:
                response = json.loads(reader.readline(common.MAX_RESPONSE_BYTES + 1))
        check(response.get("id") == request["id"] and response.get("ok") is True,
              f"temporary daemon did not finish initializing: {response}")
        return child, endpoint

    def command(endpoint, arguments, code=None):
        remaining = min(30, deadline - time.monotonic())
        check(remaining > 0, "bounded process check expired")
        argv = [str(cli), *arguments, "--socket", str(endpoint), "--output", "json"]
        result = subprocess.run(argv, env=env, capture_output=True, timeout=remaining)
        cli_rows.append({"argv": argv, "exitCode": result.returncode,
                         "stdout": result.stdout.decode(), "stderr": result.stderr.decode()})
        value = json.loads(result.stdout)
        if code is None:
            check(result.returncode == 0 and value.get("ok") is True, f"CLI failed: {value}")
        else:
            check(result.returncode != 0 and value.get("error", {}).get("code") == code, f"expected {code}: {value}")
            check("result" not in value, "failed registration exposed a success result")
        return value

    def retained_fingerprint(bootstrap):
        value = common.tree_fingerprint(bootstrap)
        # Capture creates/removes an owned staging sibling even on a duplicate;
        # the root directory's timestamps may change. Every retained child,
        # root identity/mode, and index byte must remain unchanged.
        for key in ["modifiedNs", "changedNs"]:
            value["."].pop(key, None)
        return value

    def record(request, response):
        # Actual frames, only transport correlation is projected out, as in the
        # existing DevEco recorder. No successful result is synthesized.
        row = {"method": request["method"], "protocolVersion": request["protocolVersion"], **response}
        row.pop("id", None)
        if "params" in request:
            row["params"] = request["params"]
        frames.append(row)

    def exchange(endpoint, params, method="runtime.tool.register"):

        request = {"protocolVersion": contract["currentVersion"], "contractIdentity": identity,
                   "id": "hdc-wire", "method": method, "params": params}
        with socket.socket(socket.AF_UNIX) as conn:
            conn.settimeout(30)
            conn.connect(str(endpoint))
            conn.sendall(canonical(request) + b"\n")
            with conn.makefile("rb") as reader:
                response = json.loads(reader.readline(common.MAX_RESPONSE_BYTES + 1))
        record(request, response)
        return response

    register = ["runtime", "tool", "register", "--kind", "hdc", "--file", str(source)]
    try:
        state = run / "state"
        first, endpoint = start(state)
        value = command(endpoint, register)["result"]
        check(value["kind"] == "hdc" and value["selected"] is False and value["contentRetained"] is True
              and value["source"] == "registeredCopy" and value["generation"] == "1"
              and value["trust"]["executionAssessment"] == "notPerformed", "invalid HDC registration projection")
        bootstrap = state / "bootstrap"
        receipt = run / "receipt.json"
        receipt.write_bytes(canonical({"bootstrapRoot":str(bootstrap), "deviceAcceptance":False, "result":value}))
        report.update(bootstrapRoot=str(bootstrap), toolReference=value["toolRef"], receiptPath=str(receipt))
        baseline = retained_fingerprint(bootstrap)
        index = (bootstrap / "tools.json").read_bytes()
        check(command(endpoint, register)["result"] == value, "duplicate changed its receipt")
        check(retained_fingerprint(bootstrap) == baseline and (bootstrap / "tools.json").read_bytes() == index,
              "duplicate changed native metadata")
        stop(first)
        _, endpoint = start(state)
        check(command(endpoint, ["runtime", "tool", "inspect", "--tool", value["toolRef"]])["result"] == value,
              "restart inspect failed")
        check(exchange(endpoint, {"kind": "hdc", "file": str(source)})["result"] == value,
              "restart registration changed its receipt")
        with (bootstrap / ".lock").open("rb") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            command(endpoint, register, "resourceConflict")
        check(retained_fingerprint(bootstrap) == baseline and (bootstrap / "tools.json").read_bytes() == index,
              "read/repeat/held-lock refusal changed registered metadata")
        for params in [{"kind":"hdc","root":str(source)}, {"kind":"hdc","file":"relative"},
                       {"kind":"hdc","file":str(source),"selected":True},
                       {"kind":"hdc","file":str(source),"root":str(source)}]:
            result = exchange(endpoint, params)
            check(result.get("error", {}).get("code") == "invalidParams", "invalid typed request reached owner")
        if args.record_variants:
            # This is the same pre-existing selection metadata fixture used by
            # the storage library tests. Seed a new offline registry before its
            # daemon starts; no selection API or installed registry is touched.
            preserved_state = run / "preserved"
            preserved_state.mkdir(mode=0o700)
            preserved = preserved_state / "bootstrap"
            shutil.copytree(bootstrap, preserved, copy_function=shutil.copy2)
            document = json.loads(index)
            document["selection"] = {"activeToolRef": value["toolRef"], "activeGeneration": 7}
            document["records"][0]["references"] = [{"kind":"activeSelection", "id":"runtime-hdc-selection"}]
            preserved.joinpath("tools.json").write_bytes(canonical(document))
            preserved_index = preserved.joinpath("tools.json").read_bytes()
            _, preserved_endpoint = start(preserved_state)
            saved = exchange(preserved_endpoint, {"kind":"hdc", "file":str(source)})
            check(saved.get("ok") is True and saved["result"]["selected"] is True
                  and saved["result"]["activeSelectionGeneration"] == "7", "duplicate lost existing metadata")
            check(command(preserved_endpoint, register)["result"] == saved["result"], "CLI rejected preserved metadata")
            check(preserved.joinpath("tools.json").read_bytes() == preserved_index, "duplicate rewrote saved metadata")
            # Attach quarantine only to fresh test-owned copies before taking
            # their source fingerprint. The real source stays untouched.
            sample = run / "quarantine-source"
            sample.mkdir(mode=0o700)
            for name, original in [("hdc", source), ("libusb_shared.dylib", source.parent / "libusb_shared.dylib")]:
                if not original.exists():
                    continue
                target = sample / name
                shutil.copyfile(original, target)
                target.chmod(0o700)
                subprocess.run(["/usr/bin/xattr", "-w", "com.apple.quarantine", "0081;65a00000;ArkDeckTest;", str(target)], check=True)
            quarantine_before = source_fingerprint(sample / "hdc")
            _, quarantine_endpoint = start(run / "quarantine")
            quarantined = exchange(quarantine_endpoint, {"kind":"hdc", "file":str(sample / "hdc")})
            check(quarantined.get("ok") is True and isinstance(quarantined["result"]["quarantineSHA256"], str),
                  "quarantine bytes were not retained in the receipt")
            inspected = exchange(quarantine_endpoint, {"tool":quarantined["result"]["toolRef"]}, "runtime.tool.inspect")
            check(inspected.get("result") == quarantined["result"], "inspect rejected native quarantine fields")
            check(source_fingerprint(sample / "hdc") == quarantine_before, "capture changed its quarantine source fixture")
            unsigned = run / "unsigned-source"
            unsigned.mkdir(mode=0o700)
            for name, original in [("hdc", source), ("libusb_shared.dylib", source.parent / "libusb_shared.dylib")]:
                if not original.exists():
                    continue
                target = unsigned / name
                shutil.copyfile(original, target)
                target.chmod(0o700)
                subprocess.run(["/usr/bin/codesign", "--remove-signature", str(target)], check=True, capture_output=True)
            unsigned_before = source_fingerprint(unsigned / "hdc")
            _, unsigned_endpoint = start(run / "unsigned")
            unsigned_result = exchange(unsigned_endpoint, {"kind":"hdc", "file":str(unsigned / "hdc")})
            check(unsigned_result.get("ok") is True and unsigned_result["result"]["trust"]["signature"] == "unsigned"
                  and unsigned_result["result"]["trust"]["registeredIdentity"] is False,
                  "native unsigned storage sample gained execution identity")
            unsigned_inspect = exchange(unsigned_endpoint, {"tool":unsigned_result["result"]["toolRef"]}, "runtime.tool.inspect")
            check(unsigned_inspect.get("result") == unsigned_result["result"], "inspect rejected nullable dependency trust fields")
            check(source_fingerprint(unsigned / "hdc") == unsigned_before, "capture changed its unsigned source fixture")

        # Corruption and quota fixtures live in separate fresh registries, never
        # in the successful registry retained for native Swift readback.
        for label, expected in [("corrupt", "recordUnreadable"), ("quota", "quotaExceeded")]:
            _, fault_endpoint = start(run / label)
            root = run / label / "bootstrap"
            root.joinpath("bundles.json").write_bytes(b'{"records":[],"schemaVersion":"arkdeck.bootstrap-bundles/1"}')
            root.joinpath("tools.json").write_bytes(b'{broken' if label == "corrupt" else b'{"records":[],"schemaVersion":"arkdeck.bootstrap-tools/2"}')
            for name in ["bundles.json", "tools.json"]:
                root.joinpath(name).chmod(0o600)
            if label == "quota":
                for n in range(4):
                    root.joinpath(f".tool-staging-retained-{n}").mkdir(mode=0o700)
            content = root.joinpath("tools.json").read_bytes()
            command(fault_endpoint, register, expected)
            check(root.joinpath("tools.json").read_bytes() == content, "refusal changed index")
        oversized = run / "oversized-source"
        with oversized.open("xb") as stream:
            stream.truncate(256 * 1024 * 1024 + 1)
        oversized.chmod(0o700)
        oversized_response = exchange(endpoint, {"kind":"hdc", "file":str(oversized)})
        check(oversized_response.get("error", {}).get("code") == "inputTooLarge", "native size limit lost its classification")
        # A proxy forwards health and one actual first registration, reads the
        # successful durable receipt, then drops it. There is no owner injection.
        _, loss_endpoint = start(run / "loss")
        proxy_path = run / "loss-proxy.sock"
        requests, responses, failures = [], [], []
        with socket.socket(socket.AF_UNIX) as listener:
            listener.bind(str(proxy_path))
            os.chmod(proxy_path, 0o600)
            listener.listen(2)
            listener.settimeout(30)
            def lose_receipt():
                try:
                    with listener.accept()[0] as downstream, socket.socket(socket.AF_UNIX) as upstream:
                        downstream.settimeout(30)
                        upstream.settimeout(30)
                        upstream.connect(str(loss_endpoint))
                        with downstream.makefile("rb") as inp, upstream.makefile("rb") as out:
                            for n in range(2):
                                raw = inp.readline(common.MAX_RESPONSE_BYTES + 1)
                                request = json.loads(raw)
                                requests.append(request)
                                upstream.sendall(raw)
                                response_raw = out.readline(common.MAX_RESPONSE_BYTES + 1)
                                response = json.loads(response_raw)
                                responses.append(response)
                                record(request, response)
                                if n == 0:
                                    downstream.sendall(response_raw)
                                else:
                                    check(request["method"] == "runtime.tool.register" and response.get("ok") is True,
                                          "proxy did not lose an actual published registration receipt")
                    listener.settimeout(.2)
                    try:
                        extra, _ = listener.accept()
                        extra.close()
                        raise AssertionError("CLI reconnected after a lost write response")
                    except socket.timeout:
                        pass
                except BaseException as error:
                    failures.append(error)
            thread = threading.Thread(target=lose_receipt)
            thread.start()
            try:
                command(proxy_path, register, "outcomeUnknown")
            finally:
                thread.join(timeout=35)
            check(not thread.is_alive() and not failures, f"lost-response proxy failed: {failures}")
        check(len(requests) == 2, "registration request replayed")
        lost_value = responses[1]["result"]
        check(command(loss_endpoint, ["runtime", "tool", "inspect", "--tool", lost_value["toolRef"]])["result"] == lost_value,
              "lost response did not retain durable registration")
        report.update(result="PASS", cliCommands=len(cli_rows), lostResponseOwnerCalls=1,
                      checks=["first", "duplicate", "restartInspect", "restartRegister", "sharedLock",
                              "closedRequest", "corruptIndex", "stagingQuota", "sourceSizeLimit", "lostPublishedResponseNoReplay"],
                      metadataAndQuarantineVariants=args.record_variants)
    finally:
        for child in children:
            stop(child)
        for log in logs:
            log.close()
        report["sourceUnchanged"] = source_fingerprint(source) == before_source
        report["installedMetadataUnchanged"] = common.tree_fingerprint(installed) == before_installed
        (run / "report.json").write_bytes(canonical(report))
        (run / "frames.jsonl").write_bytes(b"".join(canonical(v) + b"\n" for v in frames))
        (run / "cli-results.jsonl").write_bytes(b"".join(canonical(v) + b"\n" for v in cli_rows))
        print(json.dumps(report, sort_keys=True))
        check(report["sourceUnchanged"] and report["installedMetadataUnchanged"], "source or installed metadata changed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
