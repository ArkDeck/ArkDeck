#!/usr/bin/env python3
"""Run the real Swift update CLI only against isolated CFFIXED_USER_HOME roots."""
import argparse
import base64
import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import uuid

NAME = "12345678-1234-1234-1234-123456789abc.dmg"
ORPHAN = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa.dmg"
SCENARIOS = [
    ("initialStatus", "status", None, False, None),
    ("idleCancel", "cancel", "idle", False, None),
    ("maximumGeneration", "status", "idle", False, "maximumGeneration"),
    ("jsonlStatus", "status", "idle", False, "jsonl"),
    ("jsonlCancel", "cancel", "idle", False, "jsonl"),
    ("jsonlCleanup", "cleanup", "idle", False, "jsonl"),
    ("recoverChecking", "status", "checking", False, None),
    ("recoverDownloading", "status", "downloading", False, None),
    ("recoverVerifying", "status", "verifying", False, None),
    ("recoverHandoff", "status", "handoffInProgress", False, None),
    ("keepAwaitingConsent", "status", "awaitingConsent", False, None),
    ("keepHandedOff", "status", "handedOff", False, None),
    ("cleanupAwaitingConsent", "cleanup", "awaitingConsent", False, None),
    ("cleanupHandedOff", "cleanup", "handedOff", False, None),
    ("liveStatus", "status", "checking", True, None),
    ("liveCancel", "cancel", "checking", True, None),
    ("liveCleanup", "cleanup", "checking", True, None),
    ("writableRecord", "status", "idle", False, "writable"),
    ("noncanonicalRecord", "status", "idle", False, "newline"),
    ("directoryPartial", "status", "idle", False, "directory"),
]


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()


def normalize(value, cache_uri, parse_failure=False):
    if isinstance(value, dict):
        result = {}
        for key, item in value.items():
            if key in ("updatedAtUtc", "updatedAtUTC"):
                datetime.datetime.strptime(item, "%Y-%m-%dT%H:%M:%SZ")
                result[key] = "<timestamp>"
            elif key == "controlRequestId":
                if parse_failure:
                    assert item.startswith("ctl-")
                    uuid.UUID(item[4:])
                    result[key] = "<parse-generated-id>"
                else:
                    assert item == "ctl-update-oracle", item
                    result[key] = item
            else:
                result[key] = normalize(item, cache_uri, parse_failure)
        return result
    if isinstance(value, list):
        return [normalize(item, cache_uri, parse_failure) for item in value]
    if isinstance(value, str):
        return value.replace(cache_uri, "<cache-uri>")
    return value


def run_case(executable, rows, scenario):
    name, leaf, state, live, defect = scenario
    with tempfile.TemporaryDirectory(prefix="arkdeck-update-cli-", dir="/private/tmp") as temporary:
        home = Path(temporary) / "home"
        library = home / "Library/Containers/com.arkdeck.desktop/Data/Library"
        lifecycle = library / "Application Support/ArkDeck/AutoUpdateLifecycle"
        cache = library / "Caches/ArkDeck-Updates"
        lifecycle.mkdir(parents=True, mode=0o700)
        cache.mkdir(parents=True, mode=0o700)
        for entry, data in [(NAME, b"fixture"), (ORPHAN, b"orphan"), ("orphan.part", b"partial"), ("keep.txt", b"keep")]:
            (cache / entry).write_bytes(data)
        record = lifecycle / "state-v1.json"
        if state is not None:
            snapshot = json.loads(base64.b64decode(rows[state]["snapshotBase64"]))
            snapshot["generation"] = (2**64 - 1) if defect == "maximumGeneration" else 7
            snapshot["cancellationRequested"] = False
            text = canonical(snapshot).decode().replace(
                "file:///private/tmp/arkdeck-update-fixture/" + NAME, (cache / NAME).as_uri())
            record.write_text(text + ("\n" if defect == "newline" else ""))
            record.chmod(0o600 if defect == "writable" else 0o400)
        if defect == "directory":
            (cache / "directory.part").mkdir()
            (cache / "directory.part/keep").write_bytes(b"keep")
        lease = None
        try:
            if live:
                lease = os.open(lifecycle / ".operation-v1.lock", os.O_CREAT | os.O_RDWR, 0o600)
                fcntl.flock(lease, fcntl.LOCK_EX | fcntl.LOCK_NB)
            argv = ["runtime", "update", leaf, "--output", "json", "--control-request-id", "ctl-update-oracle"]
            if defect == "jsonl":
                argv[4] = "jsonl"
            environment = dict(os.environ)
            environment["CFFIXED_USER_HOME"] = str(home)
            environment.pop("ARKDECK_ENDPOINT", None)
            result = subprocess.run([str(executable), *argv], env=environment, capture_output=True, timeout=30)
        finally:
            if lease is not None:
                os.close(lease)
        document = normalize(json.loads(result.stdout), cache.as_uri(), defect == "jsonl")
        assert str(home) not in json.dumps(document), name
        current = None
        if record.exists():
            current = {
                "document": normalize(json.loads(record.read_bytes()), cache.as_uri()),
                "mode": record.stat().st_mode & 0o777,
                "trailingNewline": record.read_bytes().endswith(b"\n"),
            }
        return {
            "name": name, "leaf": leaf, "state": state, "liveLease": live, "defect": defect,
            "argv": argv, "exit": result.returncode, "document": document,
            "stderr": result.stderr.decode(), "record": current,
            "cacheEntries": sorted(p.name + ("/" if p.is_dir() else "") for p in cache.iterdir()),
        }


def main():
    parser = argparse.ArgumentParser()
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--swift-cli", type=Path)
    mode.add_argument("--replay-cli", type=Path)
    parser.add_argument("--out", type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    fixture = root / "rust/tests/fixtures/runtime-update/states.json"
    rows = {row["name"]: row for row in json.loads(fixture.read_bytes())["cases"]}
    if args.replay_cli:
        oracle = json.loads((fixture.parent / "cli.json").read_bytes())
        assert oracle["stateFixtureSha256"] == hashlib.sha256(fixture.read_bytes()).hexdigest()
        assert len(oracle["cases"]) == len(SCENARIOS)
        for expected, scenario in zip(oracle["cases"], SCENARIOS):
            actual = run_case(args.replay_cli, rows, scenario)
            assert actual == expected, json.dumps({"case": scenario[0], "expected": expected, "actual": actual}, ensure_ascii=False, indent=2)
        print(f"Replayed {len(SCENARIOS)} actual Swift CLI cases")
        return
    if args.out is None:
        parser.error("--out is required when recording")
    output = {
        "producer": "record-runtime-update-oracle.py",
        "executableSha256": hashlib.sha256(args.swift_cli.read_bytes()).hexdigest(),
        "stateFixtureSha256": hashlib.sha256(fixture.read_bytes()).hexdigest(),
        "cases": [run_case(args.swift_cli, rows, scenario) for scenario in SCENARIOS],
    }
    args.out.mkdir(parents=True, exist_ok=False)
    (args.out / "cli.json").write_text(json.dumps(output, ensure_ascii=False, indent=2) + "\n")
    print(f"Recorded {len(SCENARIOS)} actual Swift CLI cases in {args.out}")


if __name__ == "__main__":
    main()
