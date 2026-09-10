#!/usr/bin/env python3
"""Compare the Rust host-store candidates against the actual Swift store readers.

Every store lives in a fresh test-owned temporary directory. The Rust process
receives bytes over stdin, and cannot select or mutate a live Runtime path.
Receipts contain hashes and case names, never filter strings or snapshot bytes.
A local run is not a nightly day or hardware evidence. Scheduled receipts must
be matched to their actual Actions run before any cutover gate can consume them.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
EXPECTED = {
    **{f"history-{state}-{index}": "equal" for state in ("saved", "deleted") for index in range(3)},
    "history-maximum-generation": "equal",
    "history-extra-query-field": "refused",
    "history-extra-document-field": "refused",
    **{f"names-{state}": "equal" for state in ("targets", "tombstone", "candidate")},
    "names-extra-record-field": "refused", "names-extra-index-field": "refused",
    **{f"{kind}-{state}": "equal" for kind in ("bundle", "tool") for state in ("available", "retained", "removed")},
    **{f"{kind}-extra-{level}-field": "refused" for kind in ("bundle", "tool") for level in ("record", "index")},
}
INPUTS = [
    "rust/Cargo.lock", "rust/rust-toolchain.toml",
    "rust/crates/arkdeck-hoststore/Cargo.toml",
    "rust/crates/arkdeck-hoststore/src/lib.rs",
    "rust/crates/arkdeck-hoststore/src/main.rs",
    "rust/crates/arkdeck-hoststore/src/registry.rs",
    "rust/crates/arkdeck-hoststore/src/display_names.rs",
    "rust/scripts/hoststore-shadow.py",
    "Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RuntimeHistoryFilterStore.swift",
    "Packages/ArkDeckKit/Sources/ArkDeckWorkflows/Bootstrap/RuntimeTargetDisplayNameStore.swift",
    "Packages/ArkDeckKit/Sources/ArkDeckCore/CanonicalDigests.swift",
    "Packages/ArkDeckKit/Sources/ArkDeckCore/ArkDeckHelperIdentity.swift",
    "Packages/ArkDeckKit/Sources/ArkDeckBootstrap/BootstrapBundleRegistry.swift",
    "Packages/ArkDeckKit/Sources/ArkDeckBootstrap/BootstrapToolRegistry.swift",
    "Packages/ArkDeckKit/Sources/ArkDeckBootstrap/BootstrapToolTrust.swift",
    "Packages/ArkDeckKit/Sources/ArkDeckBootstrap/BootstrapToolFiles.swift",
    "Packages/ArkDeckKit/Tests/ArkDeckContractTests/HostStoreShadowContractTests.swift",
]


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def source_hashes() -> dict[str, str]:
    return {path: digest((ROOT / path).read_bytes()) for path in INPUTS}


def validate_cases(directory: Path) -> list[dict]:
    files = sorted(directory.glob("*.json"))
    if {path.stem for path in files} != set(EXPECTED):
        raise ValueError("missing or unexpected cross-language cases; no receipt published")
    cases = []
    for path in files:
        case = json.loads(path.read_bytes())
        if set(case) != {"case", "store", "outcome", "inputSHA256", "projectionSHA256"}:
            raise ValueError("unexpected case shape")
        expected_store = {"history": "history-filter", "bundle": "bundle-registry", "tool": "tool-registry", "names": "display-names"}[path.stem.split("-", 1)[0]]
        if (case["case"] != path.stem or case["store"] != expected_store
                or case["outcome"] != EXPECTED[path.stem]):
            raise ValueError("case identity or outcome mismatch")
        for key in ("inputSHA256", "projectionSHA256"):
            if len(case[key]) != 64 or any(c not in "0123456789abcdef" for c in case[key]):
                raise ValueError("invalid digest")
        cases.append(case)
    return cases


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path,
                        help="new digest-only receipt; existing files are never replaced")
    args = parser.parse_args()
    if args.output.exists():
        parser.error("output already exists")
    started = datetime.now(timezone.utc).isoformat()
    hashes = source_hashes()
    subprocess.run(["cargo", "build", "--locked", "-p", "arkdeck-hoststore"],
                   cwd=ROOT / "rust", check=True, timeout=600)
    metadata = json.loads(subprocess.check_output(
        ["cargo", "metadata", "--format-version", "1", "--no-deps", "--locked"], cwd=ROOT / "rust"))
    binary = Path(metadata["target_directory"]) / "debug/arkdeck-hoststore"
    binary_hash = digest(binary.read_bytes())
    with tempfile.TemporaryDirectory(prefix="arkdeck-shadow-results-") as results:
        env = dict(os.environ, ARKDECK_HOSTSTORE_SHADOW_BINARY=str(binary),
                   ARKDECK_HOSTSTORE_SHADOW_RESULTS=results)
        subprocess.run(["sh", "Packages/ArkDeckKit/Scripts/run-swiftpm.sh", "test", "-j", "4",
                        "--filter", "HostStoreShadowContractTests"], cwd=ROOT, env=env,
                       check=True, timeout=900)
        cases = validate_cases(Path(results))
    if source_hashes() != hashes or digest(binary.read_bytes()) != binary_hash:
        raise ValueError("source or binary changed during comparison; no receipt published")
    receipt = {
        "schemaVersion": "arkdeck.hoststore-shadow-run/1",
        "kind": "isolated-host-differential",
        "startedAtUTC": started,
        "completedAtUTC": datetime.now(timezone.utc).isoformat(),
        "sourceCommit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
        "sourceFiles": hashes,
        "binarySHA256": binary_hash,
        "cases": cases,
        "coveredStores": ["history-filter", "bundle-registry", "tool-registry", "display-names"],
        "remainingStores": ["session-storage", "trace-cache"],
        "remainingCoverage": ["full semantic refusal parity", "tool published identity/selection", "filesystem ownership and cutover"],
        "cutoverEligible": False,
        # These are provenance hints, not trusted approval or seven-day proof.
        "actions": {key: os.environ.get(key) for key in (
            "GITHUB_REPOSITORY", "GITHUB_EVENT_NAME", "GITHUB_RUN_ID", "GITHUB_RUN_ATTEMPT", "GITHUB_SHA")},
    }
    # Exclusive publication means a rerun cannot silently overwrite its earlier evidence.
    with args.output.open("x", encoding="utf-8") as output:
        json.dump(receipt, output, indent=2, sort_keys=True)
        output.write("\n")
    print(f"Compared {len(cases)} cases; digest-only receipt: {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
