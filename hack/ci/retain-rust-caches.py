#!/usr/bin/env python3
"""Retain the newest main Rust build caches for each runner/cache format.

Per runner/cache format this keeps the newest entry, plus the newest entry of
one other runner image while the retained Rust entries fit RUST_BUDGET_BYTES:
two images of a hosted runner often serve side by side, and each needs its own
entry because the image is part of the key (ci-workspace.py).
Candidate SwiftPM/Xcode caches retain one entry per branch/format within a
separate 2 GB budget. Trusted SwiftPM, Xcode, policy-tool and other caches are
untouched. Deletion runs only from the separate protected-main workflow.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

RUST_KEY = re.compile(
    r"arkdeck-rust-build-(?:v1-[0-9a-f]{64}-[0-9a-f]{40}|"
    r"v2-(?P<host>(?:Linux|macOS|Windows)-(?:X64|ARM64))-[0-9a-f]{64}-\d{4}-\d{2}-\d{2}|"
    r"v3-(?P<v3host>(?:Linux|macOS|Windows)-(?:X64|ARM64))-image-(?P<image>[A-Za-z0-9._]+)"
    r"-[0-9a-f]{64}-[0-9a-f]{64}-\d{4}-\d{2}-\d{2})\Z"
)
# Every retained main Rust entry together, newest images first. The GitHub
# limit is 10 GB per repository; on 2026-09-30 one entry per host and job came
# to 3.2 GB and the newest SwiftPM and Xcode entries to 1.8 GB, so this leaves
# 3.2 GB for a run's fresh saves before the next retention pass. The newest
# entry of each runner/cache format is kept even beyond it, as before.
RUST_BUDGET_BYTES = 5_000_000_000
CANDIDATE_BUDGET_BYTES = 2_000_000_000
CANDIDATE_KEY = re.compile(
    r"arkdeck-(?P<kind>swiftpm|xcode)-candidate-v1-(?P<branch>[0-9a-f]{64})-"
    r"(?:Linux|macOS|Windows)-(?:X64|ARM64)-xcode-27\.0-"
    r"(?:image-[A-Za-z0-9._]+-)?[0-9a-f]{64}-[0-9a-f]{40}\Z"
)


def candidate_removals(entries: list[dict]) -> list[dict]:
    """Only our branch-scoped candidates, newest first under a strict budget."""
    remove, kept = [], set()
    remaining = CANDIDATE_BUDGET_BYTES
    for entry in sorted(entries, key=lambda x: (x["created_at"], x["id"]), reverse=True):
        match = CANDIDATE_KEY.fullmatch(entry["key"])
        ref, version = entry["ref"], entry.get("version")
        if not match or not ref.startswith("refs/heads/agent/") or not version:
            continue
        if match["branch"] != hashlib.sha256(ref.encode()).hexdigest():
            continue
        group = (ref, match["kind"], version)
        size = entry.get("size_in_bytes")
        if not isinstance(size, int) or size < 0:
            continue
        if group in kept or size > remaining:
            remove.append(entry)
        else:
            kept.add(group)
            remaining -= size
    return remove


def removals(entries: list[dict]) -> list[dict]:
    newest = {}
    other_image = {}
    remove = []
    formats = {}
    for entry in entries:
        match = RUST_KEY.fullmatch(entry["key"])
        host = match and (match["host"] or match["v3host"])
        if entry["ref"] == "refs/heads/main" and host:
            formats.setdefault(entry.get("version"), set()).add(host)
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
        host = match["host"] or match["v3host"] or (next(iter(hosts)) if len(hosts) == 1 else "legacy")
        group = (host, version)
        if group not in newest:
            newest[group] = entry
            continue
        # A second image only ever through a v3 key, which names it; v1/v2
        # entries have no image and go once anything newer exists.
        image = match["image"]
        kept = RUST_KEY.fullmatch(newest[group]["key"])["image"]
        if image and image != kept and group not in other_image:
            other_image[group] = entry
        else:
            remove.append(entry)
    budget = RUST_BUDGET_BYTES - sum(entry.get("size_in_bytes", 0) for entry in newest.values())
    for entry in sorted(other_image.values(), key=lambda x: (x["created_at"], x["id"]), reverse=True):
        size = entry.get("size_in_bytes", 0)
        if size <= budget:
            budget -= size
        else:
            remove.append(entry)
    return remove


def trusted_event(event: dict, repository: str, *, allow_agent: bool = False) -> bool:
    run = event.get("workflow_run", {})
    branch = run.get("head_branch", "")
    return (event.get("repository", {}).get("full_name") == repository
            and run.get("head_repository", {}).get("full_name") == repository
            and (branch == "main" or (allow_agent and branch.startswith("agent/")))
            and run.get("event") == "push"
            and run.get("path") == ".github/workflows/swift-ci.yml"
            and run.get("conclusion") == "success")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    repository = os.environ["GITHUB_REPOSITORY"]
    if args.apply:
        event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text())
        if os.environ.get("GITHUB_EVENT_NAME") != "workflow_run" or not trusted_event(event, repository, allow_agent=True):
            raise ValueError("cache deletion requires a successful same-repository main/agent push CI event")
    data = subprocess.check_output([
        "gh", "api", "--paginate", "--slurp",
        f"repos/{repository}/actions/caches?per_page=100",
    ], text=True)
    entries = [entry for page in json.loads(data) for entry in page["actions_caches"]]
    selected = candidate_removals(entries)
    if not args.apply or trusted_event(event, repository):
        selected += removals(entries)
    print(json.dumps({"apply": args.apply, "remove": [
        {key: entry[key] for key in ("id", "key", "version", "size_in_bytes")} for entry in selected
    ]}, indent=2), flush=True)
    if args.apply:
        for entry in selected:
            subprocess.run(["gh", "api", "--method", "DELETE",
                            f"repos/{repository}/actions/caches/{entry['id']}"], check=True)


if __name__ == "__main__":
    main()
