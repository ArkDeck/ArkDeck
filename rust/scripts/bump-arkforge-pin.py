#!/usr/bin/env python3
"""Move every ArkForge workspace pin to one full upstream revision.

ArkDeck pins ArkForge by commit (`rust/scripts/check-arkforge-pin.py`): one
40-hex `rev` for every `arkforge-*` crate, never a branch or a tag. This tool
compares that rev with the HEAD of a local ArkForge clone. When the pin is an
ancestor of that HEAD it rewrites every rev together and refreshes Cargo.lock
with `cargo update -p` for those crates only.
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
REPOSITORY = "https://github.com/ArkDeck/ArkForge.git"
FULL_REV = re.compile(r"[0-9a-f]{40}")
LINE = re.compile(
    r'^(?P<name>arkforge-[A-Za-z0-9-]+) = \{ git = "'
    + re.escape(REPOSITORY)
    + r'", rev = "(?P<rev>[0-9a-f]{40})" \}$'
)


def fail(message: str) -> None:
    raise SystemExit(f"bump-arkforge-pin: {message}")


def parse_pins(text: str) -> dict[str, str]:
    found: dict[str, str] = {}
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped.startswith("arkforge-"):
            continue
        match = LINE.fullmatch(stripped)
        if match is None:
            fail(f"ArkForge dependency must be exactly git + rev, found {stripped}")
        found[match.group("name")] = match.group("rev")
    if not found:
        fail("rust/Cargo.toml declares no ArkForge crate")
    revisions = set(found.values())
    if len(revisions) != 1:
        fail(f"ArkForge crates are pinned at more than one revision: {sorted(revisions)}")
    return found


def rewrite(text: str, revision: str) -> str:
    if FULL_REV.fullmatch(revision) is None:
        fail(f"refusing non-revision pin {revision!r}")
    pins = parse_pins(text)
    current = next(iter(set(pins.values())))
    if revision == current:
        return text
    lines = []
    for line in text.splitlines():
        stripped = line.strip()
        match = LINE.fullmatch(stripped)
        if match is None:
            lines.append(line)
            continue
        lines.append(line.replace(match.group("rev"), revision, 1))
    rewritten = "\n".join(lines)
    if text.endswith("\n"):
        rewritten += "\n"
    if set(parse_pins(rewritten).values()) != {revision}:
        fail("rewrite did not land one revision")
    return rewritten


def _git(repo: Path, *args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", "-C", str(repo), *args],
        check=False,
        capture_output=True,
        text=True,
    )


def upstream_head(repo: Path) -> str:
    result = _git(repo, "rev-parse", "HEAD")
    if result.returncode != 0:
        fail(f"cannot read upstream HEAD: {result.stderr.strip()}")
    revision = result.stdout.strip()
    if FULL_REV.fullmatch(revision) is None:
        fail(f"upstream HEAD is not a full revision: {revision!r}")
    return revision


def relation(repo: Path, pin: str, upstream: str) -> str:
    if FULL_REV.fullmatch(pin) is None or FULL_REV.fullmatch(upstream) is None:
        fail("pin comparison requires two full revisions")
    if pin == upstream:
        return "current"
    if _git(repo, "cat-file", "-e", f"{pin}^{{commit}}").returncode != 0:
        return "diverged"
    if _git(repo, "cat-file", "-e", f"{upstream}^{{commit}}").returncode != 0:
        return "diverged"
    ancestor = _git(repo, "merge-base", "--is-ancestor", pin, upstream)
    if ancestor.returncode == 0:
        return "behind"
    if ancestor.returncode == 1:
        return "diverged"
    fail(f"merge-base failed: {ancestor.stderr.strip()}")
    return "diverged"


def update_lock(repository: Path, names: list[str]) -> None:
    command = [
        "cargo", "update",
        "--manifest-path", str(repository / "rust" / "Cargo.toml"),
    ]
    for name in names:
        command.extend(["-p", name])
    env = dict(os.environ, CARGO_NET_GIT_FETCH_WITH_CLI="true")
    subprocess.run(command, check=True, cwd=repository, env=env)


def decide(repository: Path, upstream_repo: Path, apply: bool) -> str:
    manifest = repository / "rust" / "Cargo.toml"
    text = manifest.read_text(encoding="utf-8")
    pins = parse_pins(text)
    pin = next(iter(set(pins.values())))
    upstream = upstream_head(upstream_repo)
    status = relation(upstream_repo, pin, upstream)
    if status != "behind":
        return status
    if not apply:
        return status
    manifest.write_text(rewrite(text, upstream), encoding="utf-8")
    update_lock(repository, sorted(pins))
    return "bumped"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repository", type=Path, default=ROOT)
    parser.add_argument("--upstream-repo", type=Path, required=True)
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--status-file", type=Path)
    arguments = parser.parse_args()
    status = decide(arguments.repository, arguments.upstream_repo, arguments.apply)
    if status == "diverged":
        fail("pinned revision is not an ancestor of upstream HEAD; not bumping")
    if arguments.status_file is not None:
        arguments.status_file.write_text(status + "\n", encoding="utf-8")
    print(status)


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as error:
        sys.exit(f"bump-arkforge-pin: {error}")
