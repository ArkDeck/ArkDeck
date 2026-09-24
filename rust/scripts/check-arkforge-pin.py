#!/usr/bin/env python3
"""One ArkForge revision for both lanes.

The Swift lane links ArkForge's Swift SDK through
`Packages/ArkDeckKit/Package.swift`, the Rust lane its Rust crates through
`rust/Cargo.toml`, and both talk to the same `arkforged`. Its protocol
negotiation checks only the major version, so two pins that drifted apart
field by field would pass unseen. This check refuses, read-only:

- an ArkForge dependency in `rust/Cargo.toml` that is not the ArkForge
  repository at exactly the revision Package.swift pins (no branch, no tag);
- a crate that names an ArkForge crate other than through the workspace;
- a locked ArkForge package from any other source or revision.

With `--run-vectors` it also reruns, at that revision and from the checkout
cargo fetched for the lockfile, ArkForge's own `swift_sdk_vectors` (the wire
bytes the Swift SDK is held to) and `permit_vectors` (the StepPermit bytes both
authorities mint), so a revision bump cannot land without them.
"""

import argparse
import json
import os
import re
import subprocess
import sys
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
REPOSITORY = "https://github.com/ArkDeck/ArkForge.git"


def fail(message: str) -> None:
    raise SystemExit(f"check-arkforge-pin: {message}")


def swift_pin(package_swift: str) -> str:
    pins = re.findall(
        r'\.package\(\s*url:\s*"https://github\.com/ArkDeck/ArkForge(?:\.git)?",\s*'
        r'revision:\s*"([0-9a-f]{40})"\s*\)',
        package_swift,
    )
    if len(pins) != 1:
        fail(f"Package.swift must pin ArkForge exactly once by revision, found {len(pins)}")
    return pins[0]


def check(root: Path) -> tuple[str, list[str]]:
    pin = swift_pin((root / "Packages/ArkDeckKit/Package.swift").read_text(encoding="utf-8"))
    workspace = tomllib.loads((root / "rust/Cargo.toml").read_text(encoding="utf-8"))
    declared = {
        name: spec
        for name, spec in workspace["workspace"].get("dependencies", {}).items()
        if name.startswith("arkforge-")
    }
    if not declared:
        fail("rust/Cargo.toml declares no ArkForge crate")
    for name, spec in sorted(declared.items()):
        if not isinstance(spec, dict) or set(spec) != {"git", "rev"}:
            fail(f"{name} must be declared as exactly {{ git, rev }}, not {spec!r}")
        if spec["git"] != REPOSITORY:
            fail(f"{name} comes from {spec['git']}, not {REPOSITORY}")
        if spec["rev"] != pin:
            fail(f"{name} is pinned at {spec['rev']}, but Package.swift pins {pin}")
    for manifest in sorted((root / "rust/crates").glob("*/Cargo.toml")):
        crate = tomllib.loads(manifest.read_text(encoding="utf-8"))
        scopes = [crate, *crate.get("target", {}).values()]
        for scope in scopes:
            for table in ("dependencies", "dev-dependencies", "build-dependencies"):
                for name, spec in scope.get(table, {}).items():
                    if name.startswith("arkforge-") and spec != {"workspace": True}:
                        fail(f"{manifest.parent.name} names {name} outside the workspace pin")
    lock = tomllib.loads((root / "rust/Cargo.lock").read_text(encoding="utf-8"))
    source = f"git+{REPOSITORY}?rev={pin}#{pin}"
    locked = sorted(
        package["name"] for package in lock["package"] if package["name"].startswith("arkforge-")
    )
    for package in lock["package"]:
        if package["name"].startswith("arkforge-") and package.get("source") != source:
            fail(f"{package['name']} is locked from {package.get('source')}, not {source}")
    missing = set(declared) - set(locked)
    if missing:
        fail(f"declared but not locked: {sorted(missing)}")
    return pin, locked


def arkforge_checkout(root: Path) -> Path:
    metadata = json.loads(
        subprocess.check_output(
            [
                "cargo", "metadata", "--locked", "--format-version", "1",
                "--manifest-path", str(root / "rust/Cargo.toml"),
            ],
        )
    )
    manifests = {
        Path(package["manifest_path"])
        for package in metadata["packages"]
        if package["name"] == "arkforge-ipc"
    }
    if len(manifests) != 1:
        fail(f"cargo metadata names {len(manifests)} arkforge-ipc checkouts")
    # <checkout>/crates/arkforge-ipc/Cargo.toml
    return manifests.pop().parents[2]


def run_vectors(root: Path) -> None:
    checkout = arkforge_checkout(root)
    environment = dict(os.environ, CARGO_TARGET_DIR=str(root / "rust/target/arkforge-vectors"))
    for package, test in (
        ("arkforge-ipc", "swift_sdk_vectors"),
        ("arkforge-authority-api", "permit_vectors"),
    ):
        command = [
            "cargo", "test", "--locked", "--manifest-path", str(checkout / "Cargo.toml"),
            "-p", package, "--test", test,
        ]
        print("+", " ".join(command), flush=True)
        subprocess.run(command, check=True, env=environment)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--run-vectors", action="store_true")
    arguments = parser.parse_args()
    pin, locked = check(ROOT)
    print(f"ArkForge {pin}: Package.swift, rust/Cargo.toml and rust/Cargo.lock agree "
          f"({', '.join(locked)})")
    if arguments.run_vectors:
        run_vectors(ROOT)


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as error:
        sys.exit(f"check-arkforge-pin: {error}")
