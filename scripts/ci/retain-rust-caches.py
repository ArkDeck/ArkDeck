#!/usr/bin/env python3
"""Retain the newest main Rust build cache for each runner/cache format.

Never touches branch entries or SwiftPM, Xcode, policy-tool or other caches.
Deletion runs in a separate trusted workflow after a successful main CI run.
"""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess

RUST_KEY = re.compile(
    r"arkdeck-rust-build-(?:v1-[0-9a-f]{64}-[0-9a-f]{40}|"
    r"v2-(?P<host>(?:Linux|macOS|Windows)-(?:X64|ARM64))-[0-9a-f]{64}-\d{4}-\d{2}-\d{2})\Z"
)


def removals(entries: list[dict]) -> list[dict]:
    newest = {}
    remove = []
    formats = {}
    for entry in entries:
        match = RUST_KEY.fullmatch(entry["key"])
        if entry["ref"] == "refs/heads/main" and match and match["host"]:
            formats.setdefault(entry.get("version"), set()).add(match["host"])
    for entry in sorted(entries, key=lambda x: (x["created_at"], x["id"]), reverse=True):
        match = RUST_KEY.fullmatch(entry["key"])
        if entry["ref"] != "refs/heads/main" or not match:
            continue
        # actions/cache version binds the archive format and absolute cache
        # path (different on Linux/macOS/Windows). Preserve every such boundary.
        version = entry.get("version")
        if not version:
            continue
        hosts = formats.get(version, set())
        host = match["host"] or (next(iter(hosts)) if len(hosts) == 1 else "legacy")
        group = (host, version)
        if group in newest:
            remove.append(entry)
        else:
            newest[group] = entry
    return remove


def trusted_event(event: dict, repository: str) -> bool:
    run = event.get("workflow_run", {})
    return (event.get("repository", {}).get("full_name") == repository
            and run.get("head_repository", {}).get("full_name") == repository
            and run.get("head_branch") == "main" and run.get("event") == "push"
            and run.get("path") == ".github/workflows/swift-ci.yml"
            and run.get("conclusion") == "success")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    repository = os.environ["GITHUB_REPOSITORY"]
    if args.apply:
        event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text())
        if os.environ.get("GITHUB_EVENT_NAME") != "workflow_run" or not trusted_event(event, repository):
            raise ValueError("cache deletion requires a successful same-repository main push CI event")
    data = subprocess.check_output([
        "gh", "api", "--paginate", "--slurp",
        f"repos/{repository}/actions/caches?ref=refs%2Fheads%2Fmain&per_page=100",
    ], text=True)
    selected = removals([entry for page in json.loads(data) for entry in page["actions_caches"]])
    print(json.dumps({"apply": args.apply, "remove": [
        {key: entry[key] for key in ("id", "key", "version", "size_in_bytes")} for entry in selected
    ]}, indent=2), flush=True)
    if args.apply:
        for entry in selected:
            subprocess.run(["gh", "api", "--method", "DELETE",
                            f"repos/{repository}/actions/caches/{entry['id']}"], check=True)


if __name__ == "__main__":
    main()
