#!/usr/bin/env python3
"""Run the Rust workspace tests against contract inputs they can actually match.

`cargo test --workspace` includes `corpus_parity`, and two of its cases assert
that every Swift contract input in the checkout is byte-identical to
`spec/baselines/swift-single-v1.json`. That is a statement about the repository,
not about the Rust code, and on a branch that legitimately changes a recorded
frame it is false by construction: `generate-contract.py --write` only accepts a
commit that is already in `origin/main`, so the pin cannot be moved forward
until after the branch merges.

So the lane splits the two questions it was really asking:

* Does the Rust code still replay the contract? When the checkout matches the
  pin, `cargo test --workspace` answers it directly. When the checkout is a
  candidate, `check-contracts.py` answers it in the isolated candidate view,
  where it regenerates `control_generated.rs` and runs the same workspace tests
  against the candidate manifest.
* Is the committed pin current? That is asked here against `origin/main`, which
  is where it can be true or false independently of any branch. This is the
  check that was missing when #1773 drifted the corpus and the lane stayed
  green.

Exit codes are cargo's when the tests run, 1 for a stale pin or an unusable
repository, 0 for a candidate checkout whose pin is current as of main.
"""

from __future__ import annotations

import hashlib
import json
import pathlib
import subprocess
import sys

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
BASELINE = REPO_ROOT / "spec" / "baselines" / "swift-single-v1.json"
BASE_REF = "origin/main"


def sha256_of(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def git(*arguments: str) -> subprocess.CompletedProcess[bytes]:
    return subprocess.run(
        ("git", *arguments), cwd=REPO_ROOT, capture_output=True, check=False
    )


def base_revision() -> str | None:
    if git("rev-parse", "--verify", "--quiet", BASE_REF).returncode == 0:
        return BASE_REF
    # A shallow or detached CI checkout may not carry the ref yet.
    if git("fetch", "--depth=1", "origin", "main").returncode == 0:
        for candidate in (BASE_REF, "FETCH_HEAD"):
            if git("rev-parse", "--verify", "--quiet", candidate).returncode == 0:
                return candidate
    return None


def main() -> int:
    try:
        pinned = json.loads(BASELINE.read_text(encoding="utf-8"))["files"]
    except (OSError, KeyError, json.JSONDecodeError) as error:
        print(f"cannot read the pinned Swift baseline: {error}", file=sys.stderr)
        return 1

    drifted = sorted(
        path
        for path, pin in pinned.items()
        if not (REPO_ROOT / path).is_file()
        or sha256_of((REPO_ROOT / path).read_bytes()) != pin["sha256"]
    )
    if not drifted:
        return subprocess.run(
            ("cargo", "test", "--workspace"), cwd=REPO_ROOT / "rust", check=False
        ).returncode

    base = base_revision()
    if base is None:
        print(
            "the checkout differs from the pinned Swift baseline and "
            f"{BASE_REF} is unavailable, so the pin's currency cannot be "
            "established; fetch main and re-run",
            file=sys.stderr,
        )
        return 1

    stale = []
    for path, pin in pinned.items():
        blob = git("show", f"{base}:{path}")
        if blob.returncode != 0 or sha256_of(blob.stdout) != pin["sha256"]:
            stale.append(path)
    if stale:
        print(
            "the committed Swift baseline is stale against "
            f"{base} for {len(stale)} file(s), so this checkout cannot be "
            "judged against it. Re-pin with "
            "`python3 rust/scripts/generate-contract.py --write "
            f"--baseline-revision {base}`. First: " + "\n  ".join([""] + stale[:10]),
            file=sys.stderr,
        )
        return 1

    print(
        f"{len(drifted)} Swift contract input(s) in this checkout are ahead of a "
        f"pin that is current as of {base}, so the workspace tests run in "
        "check-contracts.py's candidate view instead of against the published "
        "pin. Re-pin after this branch merges. Ahead: "
        + "\n  ".join([""] + drifted[:10])
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
