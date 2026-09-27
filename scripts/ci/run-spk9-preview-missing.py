#!/usr/bin/env python3
"""Opt-in, device-free CAS-miss parity against one real, unpaired arkforged.

Builds sequentially before starting the isolated daemon. No installed path,
profile override, replay transport, import, discovery, job or permit is used.
This is only SPK-9's missing-archive refusal subset, never G5/hardware evidence.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import stat
import subprocess
import sys
import tempfile
import time
import tomllib

ROOT = Path(__file__).resolve().parents[2]
SWIFT_CLASS = "ArkForgeMissingArchiveLiveTests"
RUST_CASE = "real_daemon_missing_archive_preview"


def digest(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def stop(process: subprocess.Popen) -> None:
    if process.poll() is None:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=5)


def run(command: list[str], log: Path, env: dict, timeout: int = 600) -> None:
    with log.open("wb") as output:
        process = subprocess.Popen(command, cwd=ROOT, env=env, stdout=output,
                                   stderr=subprocess.STDOUT, start_new_session=True)
        try:
            code = process.wait(timeout=timeout)
            if code:
                raise RuntimeError(f"exit {code}: {command}; see {log}")
        finally:
            stop(process)


def git(source: Path, *args: str) -> str:
    return subprocess.check_output(["git", "-C", str(source), *args], text=True,
                                   timeout=10).strip()


def source_dirty(source: Path) -> bool:
    # Cargo's checkout marker is not source; no other untracked input is allowed.
    return any(line != "?? .cargo-ok" for line in
               git(source, "status", "--porcelain").splitlines())


def artifact(log: Path, target: str, kind: str) -> Path:
    paths = set()
    for line in log.read_text().splitlines():
        if not line.startswith("{"):
            continue
        message = json.loads(line)
        if (message.get("reason") == "compiler-artifact"
                and message.get("target", {}).get("name") == target
                and kind in message["target"]["kind"] and message.get("executable")):
            paths.add(Path(message["executable"]).resolve())
    if len(paths) != 1:
        raise RuntimeError(f"expected one {target} executable in {log}, got {paths}")
    return paths.pop()


def snapshot(runtime: Path) -> dict:
    result = {}
    for path in sorted(runtime.rglob("*")):
        mode = path.lstat().st_mode
        entry = {"mode": stat.S_IMODE(mode)}
        if stat.S_ISREG(mode):
            entry.update(kind="file", size=path.stat().st_size, sha256=digest(path))
        elif stat.S_ISDIR(mode):
            entry.update(kind="directory")
        elif stat.S_ISSOCK(mode):
            entry.update(kind="socket")
        else:
            raise RuntimeError(f"unexpected private-state file type: {path}")
        result[str(path.relative_to(runtime))] = entry
    return result


def write(path: Path, value: dict) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--arkforge-source", type=Path, required=True,
                        help="clean checkout at ArkDeck's exact pinned revision")
    parser.add_argument("--daemon-target", type=Path, required=True,
                        help="task-owned ArkForge build target")
    parser.add_argument("--cargo-target", type=Path, required=True,
                        help="task-owned build target, never a shared worktree target")
    parser.add_argument("--output", type=Path, required=True,
                        help="new evidence directory (must not exist)")
    args = parser.parse_args()
    # Ensure ordinary cancellation runs the same process/directory cleanup.
    def interrupted(_signal, _frame):
        raise KeyboardInterrupt("SPK-9 carrier interrupted")
    signal.signal(signal.SIGTERM, interrupted)
    if sys.platform != "darwin":
        parser.error("the paired Swift/Rust carrier requires macOS")
    source = args.arkforge_source.resolve()
    target = args.cargo_target.resolve()
    output = args.output.resolve()
    pin = tomllib.loads((ROOT / "rust/Cargo.toml").read_text())["workspace"]["dependencies"]["arkforge-client"]["rev"]
    if git(source, "rev-parse", "HEAD") != pin or source_dirty(source):
        parser.error("ArkForge source must be clean at the exact committed SDK pin")
    output.mkdir(parents=True, exist_ok=False)
    env = {k: v for k, v in os.environ.items() if not k.startswith("ARKDECK_SPK9_")}
    env.update(CARGO_BUILD_JOBS="2", CARGO_TARGET_DIR=str(target))
    identity = {"scope": "SPK-9 missing-CAS host refusal subset only",
                "arkforgeCommit": pin, "arkforgeTree": git(source, "rev-parse", "HEAD^{tree}"),
                "arkdeckCommit": git(ROOT, "rev-parse", "HEAD"),
                "arkdeckWorktreeStatus": git(ROOT, "status", "--porcelain"),
                "arkdeckDiffSHA256": hashlib.sha256(subprocess.check_output(
                    ["git", "diff", "HEAD"], cwd=ROOT, timeout=10)).hexdigest(),
                "commands": [], "result": "incomplete"}
    sources = [Path(__file__).resolve(),
               ROOT / "rust/crates/arkdeck-provider-arkforge/tests/live_preview_missing.rs",
               ROOT / "Packages/ArkDeckKit/Tests/ArkDeckContractTests/ArkForgeMissingArchiveLiveTests.swift"]
    identity["carrierSources"] = {str(p.relative_to(ROOT)): digest(p) for p in sources}
    write(output / "result.json", identity)

    def checked(command: list[str], name: str, timeout: int = 600) -> None:
        print(f"START {name}:", output / f"{name}.log", flush=True)
        identity["commands"].append(command)
        write(output / "result.json", identity)
        run(command, output / f"{name}.log", env, timeout)
        print(f"PASS {name}", flush=True)

    try:
        checked(["rustc", "--version", "--verbose"], "rust-toolchain", 10)
        checked(["swift", "--version"], "swift-toolchain", 10)
        env["CARGO_TARGET_DIR"] = str(args.daemon_target.resolve())
        checked(["cargo", "build", "--locked", "--manifest-path", str(source / "Cargo.toml"),
                 "-p", "arkforged", "--bin", "arkforged", "--message-format=json"], "daemon-build")
        daemon = artifact(output / "daemon-build.log", "arkforged", "bin")
        identity.update(daemonPath=str(daemon), daemonSHA256=digest(daemon))
        env["CARGO_TARGET_DIR"] = str(target)
        checked(["cargo", "test", "--locked", "--manifest-path", str(ROOT / "rust/Cargo.toml"),
                 "-p", "arkdeck-provider-arkforge", "--test", "live_preview_missing",
                 "--no-run", "--message-format=json"], "rust-build")
        rust_test = artifact(output / "rust-build.log", "live_preview_missing", "test")
        identity.update(rustTestPath=str(rust_test), rustTestSHA256=digest(rust_test))
        swift = ["sh", "Packages/ArkDeckKit/Scripts/run-swiftpm.sh", "test", "--filter", SWIFT_CLASS]
        # With no opt-in environment this builds the one class and records XCTSkip.
        checked(swift, "swift-build")
        if git(source, "rev-parse", "HEAD") != pin or source_dirty(source):
            raise RuntimeError("ArkForge source changed during the build")
        if any(digest(p) != identity["carrierSources"][str(p.relative_to(ROOT))] for p in sources):
            raise RuntimeError("carrier sources changed during the build")
        with tempfile.TemporaryDirectory(prefix="as9-", dir="/private/tmp") as temporary:
            runtime = Path(temporary)
            os.chmod(runtime, 0o700)
            identity["runtimeDirectory"] = str(runtime)
            daemon_command = [str(daemon), "--runtime-dir", str(runtime)]
            identity["commands"].append(daemon_command)
            with (output / "daemon.log").open("wb") as log:
                process = subprocess.Popen(daemon_command, stdin=subprocess.DEVNULL,
                                           stdout=log, stderr=subprocess.STDOUT,
                                           env=env, start_new_session=True)
                try:
                    deadline = time.monotonic() + 10
                    while not all((runtime / name).is_socket()
                                  for name in ("public.sock", "controller.sock")):
                        if process.poll() is not None or time.monotonic() >= deadline:
                            raise RuntimeError("daemon did not become socket-ready within 10s")
                        # Readiness polling only, never retrying a failed operation.
                        time.sleep(0.02)
                    before = snapshot(runtime)
                    write(output / "state-before.json", before)
                    env.update(ARKDECK_SPK9_RUNTIME=str(runtime),
                               ARKDECK_SPK9_DAEMON_SHA256=identity["daemonSHA256"],
                               ARKDECK_SPK9_RUST_REPORT=str(output / "rust.json"),
                               ARKDECK_SPK9_SWIFT_REPORT=str(output / "swift.json"))
                    checked([str(rust_test), RUST_CASE, "--exact", "--ignored", "--nocapture"],
                            "rust-preview", 30)
                    checked(swift + ["--skip-build"], "swift-preview", 60)
                    after = snapshot(runtime)
                    write(output / "state-after.json", after)
                    if before != after:
                        raise RuntimeError("private daemon state changed during CAS-miss previews")
                    reports = [json.loads((output / f"{owner}.json").read_text()) for owner in ("rust", "swift")]
                    expected = {"outcome": "bundleNotInLaneStore", "archiveSHA256": "0" * 64,
                                "profileReference": "org.openharmony.dayu200@1.0.0",
                                "calls": ["controller.inspectArtifact"], "refusalCode": "ARTIFACT_NOT_FOUND"}
                    for owner, report in zip(("rust", "swift"), reports):
                        if report.get("owner") != owner or any(report.get(k) != v for k, v in expected.items()):
                            raise RuntimeError(f"unexpected {owner} result: {report}")
                    if reports[1].get("executionReady") is not False or reports[1].get("daemonSHA256") != identity["daemonSHA256"]:
                        raise RuntimeError("daemon identity or unpaired readiness mismatch")
                    if process.poll() is not None or digest(daemon) != identity["daemonSHA256"]:
                        raise RuntimeError("daemon exited or executable changed during the check")
                    identity.update(result="pass", stateUnchanged=True, hardwareEvidence=False)
                finally:
                    stop(process)
        identity["runtimeRemoved"] = not runtime.exists()
    except BaseException as error:
        identity.update(result="failed", error=str(error))
        raise
    finally:
        write(output / "result.json", identity)


if __name__ == "__main__":
    main()
