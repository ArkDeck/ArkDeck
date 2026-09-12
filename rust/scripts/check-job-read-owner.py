#!/usr/bin/env python3
"""Compare the real Rust daemon with an explicit Swift-generated Job fixture.

Generate the disposable fixture using JobReadResourcesContractTests/
testRustJobOwnerCurrentSQLiteFixture with ARKDECK_RUST_JOB_FIXTURE_OUTPUT.
This harness never uses installed Runtime state or executes a device operation.
"""
import argparse
import base64
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import time


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--fixture", type=Path, required=True)
    parser.add_argument("--daemon", type=Path, required=True)
    parser.add_argument("--cli", type=Path, required=True)
    args = parser.parse_args()
    fixture = args.fixture.resolve(strict=True)
    if not fixture.is_relative_to(Path("/private/tmp")):
        raise SystemExit("Only an explicitly generated private temporary fixture is accepted")
    samples = json.loads((fixture / "swift-results.json").read_text())
    daemon, cli = args.daemon.resolve(strict=True), args.cli.resolve(strict=True)
    env = {k: v for k, v in os.environ.items() if not k.startswith("ARKDECK_")}
    with tempfile.TemporaryDirectory(prefix="arkdeck-job-read-", dir="/private/tmp") as temporary:
        root = Path(temporary)
        shutil.copytree(fixture / "jobs-state", root / "jobs-state")
        artifact_mode = (fixture / "artifacts").is_dir()
        if artifact_mode:
            shutil.copytree(fixture / "artifacts", root / "artifacts")
        endpoint = root / "control.sock"
        env.update(ARKDECK_DEVELOPMENT_STATE_ROOT=str(root), ARKDECK_ENDPOINT=str(endpoint))

        def start():
            log = open(root / "daemon.log", "ab")
            process = subprocess.Popen([str(daemon)], env=env, stdout=log, stderr=log)
            log.close()
            for _ in range(100):
                if process.poll() is not None:
                    raise AssertionError((root / "daemon.log").read_text())
                if endpoint.exists():
                    try:
                        with socket.socket(socket.AF_UNIX) as probe:
                            probe.connect(str(endpoint))
                        return process
                    except OSError:
                        pass
                time.sleep(0.02)
            process.terminate()
            process.wait(timeout=5)
            raise AssertionError("daemon endpoint did not appear")

        def request(method, params):
            with socket.socket(socket.AF_UNIX) as connection:
                connection.settimeout(5)
                connection.connect(str(endpoint))
                stream = connection.makefile("rb")
                # Read identity from the checked-in current contract; health is
                # still verified by the actual Rust CLI below.
                protocol = json.loads((Path(__file__).resolve().parents[2] / "spec/control/methods/health.json").read_text())
                frame = {"protocolVersion": "1.0.0", "contractIdentity": protocol["x-arkdeck-contractIdentity"], "id": "rust-job-read-test", "method": method, "params": params}
                connection.sendall(json.dumps(frame).encode() + b"\n")
                return json.loads(stream.readline(8 * 1024 * 1024))

        process = start()
        try:
            for sample in samples:
                reply = request(sample["method"], sample["params"])
                assert reply["ok"], reply
                actual, expected = reply["result"], sample["result"]
                if "items" in expected:
                    assert actual["items"] == expected["items"], (sample["method"], actual, expected)
                else:
                    assert actual == expected, (sample["method"], actual, expected)
            commands = [["job", "list"], ["job", "show", "--job", "job-rust-a"], ["job", "status", "--job", "job-rust-b"], ["job", "timeline", "--job", "job-rust-a"]]
            if artifact_mode:
                reference = samples[0]["params"]
                owner_options = ["--job", reference["owner"]["id"], "--artifact", reference["artifactId"]]
                commands = [["artifact", "inspect", *owner_options], ["artifact", "read", *owner_options]]
            for command in commands:
                result = subprocess.run([str(cli), *command, "--socket", str(endpoint), "--output", "json"], capture_output=True, timeout=10)
                assert result.returncode == 0, (command, result.stdout, result.stderr)
                json.loads(result.stdout)
            if artifact_mode:
                raw = subprocess.run([str(cli), "artifact", "read", *owner_options, "--socket", str(endpoint), "--raw"], capture_output=True, timeout=10)
                expected = next(item["result"] for item in samples if item["method"] == "artifact.read")
                assert raw.returncode == 0, (raw.stdout, raw.stderr)
                assert raw.stdout == base64.b64decode(expected["base64"])
                missing = request("artifact.inspect", {**reference, "owner": {"kind": "job", "id": "absent"}})
                assert missing["error"]["code"] == "resourceNotFound", missing
            # The second owner must refuse without rewriting the live SQLite.
            other = subprocess.run([str(daemon)], env=env, capture_output=True, timeout=5)
            assert other.returncode != 0
            assert request("job.status", {"jobId": "absent"})["error"]["code"] == "notFound"
            before = (root / "jobs-state/runtime-jobs.sqlite3").read_bytes()
            process.terminate(); process.wait(timeout=5)
            process = start()
            for sample in samples:
                reply = request(sample["method"], sample["params"])
                assert reply["ok"], reply
                expected = sample["result"]
                assert (reply["result"]["items"] == expected["items"]) if "items" in expected else (reply["result"] == expected)
            assert (root / "jobs-state/runtime-jobs.sqlite3").read_bytes() == before
            print(json.dumps({"status": "PASS", "producer": "Swift current SQLite and RPC", "samples": len(samples), "cliProcesses": len(commands) + int(artifact_mode), "restart": True, "secondOwnerRefused": True, "deviceDispatchCount": 0}))
        finally:
            if process.poll() is None:
                process.terminate(); process.wait(timeout=5)


if __name__ == "__main__":
    main()
