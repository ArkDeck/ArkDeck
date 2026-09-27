#!/usr/bin/env python3
"""Run every workspace test through Cargo, with two bounded macOS queues.

Cargo builds all default targets first. Only audited integration targets with
unique temporary roots may overlap the conservative queue. New targets stay
in the conservative queue. Cargo still owns test environments, feature
unification, custom harnesses and doctests; no test executable is run directly.
"""
from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import tomllib

RUST = Path(__file__).resolve().parents[1]
BASE = ["cargo", "test", "--workspace", "--no-fail-fast", "--locked"]
# No fixed HDC oracle paths, shared TCP ports, or spawning/descriptor tests.
# Each target creates its own PID/nonce directory and Unix socket, and tears
# down its own children. Keep this list small; additions require that audit.
ISOLATED = frozenset({
    ("arkdeck-agentd", "workspace_tests_process"),
    ("arkdeck-agentd", "workspace_checkpoint_process"),
    ("arkdeck-cli", "maintainer_contracts"),
})


def queues(messages: list[dict], metadata: dict) -> list[tuple[str, list[str]]]:
    """Map Cargo's actual default test artifacts to exhaustive native selectors.

    Unsupported target shapes fall back to the original workspace invocation,
    never to a partial test inventory. --workspace is retained in both queues
    so feature unification does not change with the selected test targets.
    """
    if not any(m.get("reason") == "build-finished" and m.get("success") for m in messages):
        raise ValueError("Cargo did not report a successful complete test build")
    members = set(metadata["workspace_members"])
    packages = {p["id"]: p for p in metadata["packages"] if p["id"] in members}
    for package in packages.values():
        manifest = tomllib.loads(Path(package["manifest_path"]).read_text())
        # An un-harnessed bin/example can also be a normal build artifact;
        # avoid inferring test selection from that ambiguous executable.
        entries = [manifest.get("lib", {})]
        entries += [entry for kind in ("bin", "example", "bench") for entry in manifest.get(kind, [])]
        if any(entry.get("harness") is False for entry in entries):
            return [("workspace", BASE)]
        if any("lib" in target["kind"] and not target["test"] for target in package["targets"]):
            return [("workspace", BASE)]
    targets = {}
    for message in messages:
        if message.get("reason") != "compiler-artifact" or message.get("package_id") not in packages:
            continue
        target = message["target"]
        if not message.get("executable") or not (message["profile"]["test"] or target["kind"] == ["test"]):
            continue
        kind = target["kind"]
        if kind == ["test"]:
            flag = "--test"
        elif kind == ["bin"]:
            flag = "--bin"
        elif kind == ["example"]:
            flag = "--example"
        elif "lib" in kind or kind == ["proc-macro"]:
            flag = "--lib"
        else:
            return [("workspace", BASE)]
        package = packages[message["package_id"]]["name"]
        selector = (flag, target["name"] if flag != "--lib" else "")
        targets.setdefault(selector, []).append((package, target["name"]))
    if not targets:
        return [("workspace", BASE)]
    serial, isolated = [], []
    for selector, owners in sorted(targets.items()):
        # A newly added target with the same name in another package must not
        # inherit the audited target's permission to overlap shared resources.
        destination = isolated if selector[0] == "--test" and all(owner in ISOLATED for owner in owners) else serial
        destination.extend(part for part in selector if part)
    return [(name, BASE + flags) for name, flags in (("shared-resources", serial), ("isolated", isolated)) if flags]


def recorded(argv: list[str], directory: Path, label: str, cwd: Path) -> dict:
    started = time.monotonic()
    log = directory / f"{label}.log"
    print(f"+ [{label}] {' '.join(argv)}", flush=True)
    with log.open("w") as output:
        with subprocess.Popen(argv, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True) as process:
            for line in process.stdout:
                output.write(line)
                output.flush()
                if label == "compile" and line.startswith("{"):
                    diagnostic = json.loads(line).get("message", {}).get("rendered")
                    if diagnostic:
                        print(diagnostic, end="", flush=True)
                    continue
                print(f"[{label}] {line}", end="", flush=True)
            code = process.wait()
    return {"name": label, "argv": argv, "seconds": round(time.monotonic() - started, 3),
            "exitCode": code, "log": str(log)}


def execute(cwd: Path = RUST, workers: int = 1, directory: Path | None = None) -> int:
    if workers not in (1, 2):
        raise ValueError("workspace test workers must be 1 or 2")
    if workers == 1:
        return subprocess.run(BASE, cwd=cwd, check=False).returncode
    directory = directory or Path(tempfile.mkdtemp(prefix="arkdeck-test-timings-"))
    directory.mkdir(parents=True, exist_ok=True)
    stages = []
    started = time.monotonic()
    report = {"schemaVersion": "arkdeck.workspace-test-timings/1", "workers": workers,
              "workspace": str(cwd), "completed": False, "stages": stages}
    try:
        # --no-run retains compilation of default examples and integration
        # binaries. The JSON inventory includes both libtest and harness=false.
        build = recorded(BASE + ["--no-run", "--message-format=json"], directory, "compile", cwd)
        stages.append(build)
        if build["exitCode"]:
            return build["exitCode"]
        messages = []
        for line in Path(build["log"]).read_text().splitlines():
            if line.startswith("{"):
                messages.append(json.loads(line))
        metadata = json.loads(subprocess.check_output(
            ["cargo", "metadata", "--no-deps", "--format-version", "1", "--locked"], cwd=cwd, text=True))
        planned = queues(messages, metadata)
        report["queues"] = [{"name": name, "argv": argv} for name, argv in planned]
        with ThreadPoolExecutor(max_workers=2) as pool:
            futures = [pool.submit(recorded, argv, directory, name, cwd) for name, argv in planned]
            stages.extend(future.result() for future in futures)
        # A fallback runs doctests in the original command already. Otherwise
        # preserve docs even after either queue failed (--no-fail-fast semantics).
        if planned != [("workspace", BASE)]:
            stages.append(recorded(BASE + ["--doc"], directory, "doctests", cwd))
        report["completed"] = True
        return 1 if any(stage["exitCode"] for stage in stages) else 0
    finally:
        report["seconds"] = round(time.monotonic() - started, 3)
        (directory / "timings.json").write_text(json.dumps(report, indent=2) + "\n")
        print(f"Workspace test timings: {directory / 'timings.json'}", flush=True)


def main() -> int:
    workers = int(os.environ.get("ARKDECK_RUST_TEST_WORKERS", "1"))
    output = os.environ.get("ARKDECK_RUST_TEST_REPORT_DIR")
    # Checkout / published / candidate use separate reports as well as targets.
    name = os.environ.get("ARKDECK_RUST_TEST_VIEW", "checkout")
    if name not in ("checkout", "published", "candidate"):
        raise ValueError("invalid Rust test view")
    return execute(workers=workers, directory=Path(output) / name if output else None)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"workspace tests: {error}", file=sys.stderr)
        sys.exit(1)
