#!/usr/bin/env python3
"""Record what Swift's `arkdeck maintainer contracts export|check` answers.

Each case builds a fresh directory tree, runs one leaf of the given CLI on
it, and keeps the exit status, stdout, stderr and the tree left behind. A
setup step named `export` runs that same CLI's export, so the Rust replay
(`rust/crates/arkdeck-cli/tests/maintainer_contracts.rs`) builds its trees
with the Rust export, which the digest table already holds to Swift's bytes.
The case's root directory is written `<root>`, and the random control
request identity `<controlRequestId>`.

Run it with a built Swift CLI and a scratch directory (never the repository):

    python rust/scripts/record-maintainer-contracts-oracle.py \\
        --cli <swift arkdeck> --work <scratch directory>

It writes `rust/tests/fixtures/maintainer-contracts/oracle.json`.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
OUTPUT = ROOT / "rust/tests/fixtures/maintainer-contracts/oracle.json"
CLEAN = [{"op": "export"}]


def case(name, verb, mode, setup, contracts="contracts", fixtures="fixtures"):
    return {"name": name, "verb": verb, "mode": mode, "setup": setup,
            "contractsDirectory": contracts, "fixturesDirectory": fixtures}


DRIFTED = CLEAN + [{"op": "write", "path": "fixtures/argv/job.status.json", "text": "{}\n"}]
MISSING = CLEAN + [{"op": "remove", "path": "contracts/cli-page.schema.json"},
                   {"op": "remove", "path": "fixtures/argv/job.show.json"}]
UNEXPECTED = CLEAN + [{"op": "write", "path": "fixtures/argv/zz-stray.json", "text": "{}\n"},
                      {"op": "write", "path": "fixtures/nested/stray.txt", "text": "x"},
                      {"op": "write", "path": "fixtures/.hidden", "text": "x"},
                      {"op": "write", "path": "fixtures/.cache/stray.json", "text": "x"}]
EXTRAS = [{"op": "write", "path": "fixtures/stale.json", "text": "{}\n"},
          {"op": "write", "path": "fixtures/argv/old-leaf.json", "text": "{}\n"},
          {"op": "write", "path": "fixtures/.keep", "text": "x"},
          {"op": "write", "path": "contracts/extra.txt", "text": "x"}]
SYMLINKS = [{"op": "write", "path": "outside/file.txt", "text": "outside\n"},
            {"op": "write", "path": "outside/directory/inner.json", "text": "{}\n"},
            {"op": "symlink", "path": "fixtures/link-to-file", "target": "../outside/file.txt"},
            {"op": "symlink", "path": "fixtures/link-to-directory", "target": "../outside/directory"},
            {"op": "symlink", "path": "fixtures/dangling", "target": "../outside/absent.json"}]

CASES = [
    case(f"{verb}-{name}-{mode}", verb, mode, setup, *places)
    for name, verb, setup, places in [
        ("clean", "check", CLEAN, ()),
        ("drifted", "check", DRIFTED, ()),
        ("missing", "check", MISSING, ()),
        ("unexpected", "check", UNEXPECTED, ()),
        ("extras", "export", EXTRAS, ()),
        ("absent", "export", [], ("new/contracts", "new/fixtures")),
        ("symlinks", "export", SYMLINKS, ()),
    ]
    for mode in ("json", "human")
]


def run(cli: Path, root: Path, verb: str, mode: str, contracts: str, fixtures: str):
    argv = [str(cli), "maintainer", "contracts", verb,
            "--contracts-directory", str(root / contracts),
            "--fixtures-directory", str(root / fixtures)]
    if mode == "json":
        argv += ["--output", "json"]
    return subprocess.run(argv, capture_output=True, timeout=300, check=False)


def set_up(cli: Path, root: Path, setup: list) -> None:
    for step in setup:
        path = root / step.get("path", "")
        if step["op"] == "export":
            done = run(cli, root, "export", "human", "contracts", "fixtures")
            if done.returncode != 0:
                raise SystemExit(f"setup export failed: {done.stderr.decode()}")
        elif step["op"] == "write":
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(step["text"].encode())
        elif step["op"] == "remove":
            path.unlink()
        elif step["op"] == "symlink":
            path.parent.mkdir(parents=True, exist_ok=True)
            os.symlink(step["target"], path)
        else:
            raise SystemExit(f"unknown setup step {step}")


def tree(root: Path) -> list:
    """Every entry below `root`, by lstat, with a file's digest or a link's target."""
    entries = []
    for directory, subdirectories, names in os.walk(root):
        subdirectories.sort()
        for name in sorted(subdirectories + names):
            path = Path(directory) / name
            relative = path.relative_to(root).as_posix()
            if path.is_symlink():
                entries.append({"path": relative, "symlink": os.readlink(path)})
            elif path.is_dir():
                entries.append({"path": relative, "directory": True})
            else:
                entries.append({"path": relative,
                                "sha256": hashlib.sha256(path.read_bytes()).hexdigest()})
    entries.sort(key=lambda entry: entry["path"])
    return entries


def normalized(text: str, root: Path) -> str:
    text = text.replace(str(root), "<root>")
    return re.sub(r'"controlRequestId":"[^"]*"', '"controlRequestId":"<controlRequestId>"', text)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--cli", type=Path, required=True, help="the Swift arkdeck to record")
    parser.add_argument("--work", type=Path, required=True,
                        help="a scratch directory for the cases' trees, outside the repository")
    parser.add_argument("--output", type=Path, default=OUTPUT)
    arguments = parser.parse_args()
    cli = arguments.cli.resolve(strict=True)
    work = arguments.work
    if ROOT in [work.resolve(), *work.resolve().parents]:
        raise SystemExit("the work directory must be outside the repository")
    recorded = []
    for entry in CASES:
        root = work / entry["name"]
        if root.exists():
            shutil.rmtree(root)
        root.mkdir(parents=True)
        set_up(cli, root, entry["setup"])
        done = run(cli, root, entry["verb"], entry["mode"],
                   entry["contractsDirectory"], entry["fixturesDirectory"])
        recorded.append({**entry,
                         "exitCode": done.returncode,
                         "stdout": normalized(done.stdout.decode(), root),
                         "stderr": normalized(done.stderr.decode(), root),
                         "tree": tree(root) if entry["verb"] == "export" else None})
        shutil.rmtree(root)
    document = {
        "schemaVersion": "arkdeck.maintainer-contracts-oracle/1",
        "producer": "Swift arkdeck maintainer contracts export|check",
        "cliSHA256": hashlib.sha256(cli.read_bytes()).hexdigest(),
        "sourceRevision": subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT,
                                         capture_output=True, text=True,
                                         check=True).stdout.strip(),
        "cases": recorded,
    }
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    arguments.output.write_text(json.dumps(document, indent=2, sort_keys=True,
                                           ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"recorded {len(recorded)} cases into {arguments.output.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
