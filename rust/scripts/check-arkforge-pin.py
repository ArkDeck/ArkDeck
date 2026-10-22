#!/usr/bin/env python3
"""One ArkForge revision for the whole Rust workspace.

ArkDeck consumes ArkForge only through its Rust crates, pinned in
`rust/Cargo.toml`. The Swift lane linked ArkForge's Swift SDK through
`Packages/ArkDeckKit/Package.swift` until the Swift Runtime was deleted
(CHG-2026-074, TASK-XPA-017); that pin is gone, and this check now holds the
Rust pin alone. It refuses, read-only:

- ArkForge crates in `rust/Cargo.toml` that are not the ArkForge repository
  at one exact revision (no branch, no tag), or at more than one;
- a crate that names an ArkForge crate other than through the workspace;
- a locked ArkForge package from any other source or revision;
- an ArkForge package reference returning to `Packages/ArkDeckKit/Package.swift`.

With `--run-vectors` it also reruns, at that revision and from the checkout
cargo fetched for the lockfile, ArkForge's own `swift_sdk_vectors` (its wire
bytes) and `permit_vectors` (the StepPermit bytes both authorities mint), so a
revision bump cannot land without them.

The same checkout must use ArkForge's current layout. The pin check reads
`api/versions.yaml` and `api/arkforge.proto` without compiling them. Library
crates stay under `crates/`. Binaries are `cmd/`, the boot-loop helper is
`hack/`, the spec is `docs/spec/`, and transcripts are `test/transcripts/`.
The retired `proto/`, `scripts/`, root `spec/`, and root `transcripts/` paths
must be absent.
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
IPC_MANIFEST = Path("crates/arkforge-ipc/Cargo.toml")
CONTRACT_FILES = (
    Path("api/arkforge.proto"),
    Path("api/versions.yaml"),
    Path("cmd/arkforge-cli/Cargo.toml"),
    Path("cmd/arkforged/Cargo.toml"),
    Path("crates/arkforge-arkdeck-adapter/Cargo.toml"),
    Path("crates/arkforge-ipc/Cargo.toml"),
    Path("hack/restore-boot-loop.py"),
    Path("docs/spec/README.md"),
    Path("test/transcripts"),
)
RETIRED_PATHS = (
    Path("proto/arkforge.proto"),
    Path("scripts/restore-boot-loop.py"),
    Path("spec/README.md"),
    Path("transcripts"),
)
VERSION_NEEDLES = (
    "schema: arkforge.contract-versions/v1",
    "proto: api/arkforge.proto",
    "package: arkforge.ipc.v1",
    "protocolMajor: 1",
    "protocolMinor: 0",
    'protocolVersion: "1.0"',
    "contractTag: arkforge-contract-v1.0.0",
    "arkdeckContract: arkforge.arkdeck-contract/1.0.0",
    "mappingTable: arkforge.arkdeck-step-map/v1",
    "controlTable: arkforge.arkdeck-control-map/v1",
)


def fail(message: str) -> None:
    raise SystemExit(f"check-arkforge-pin: {message}")


def workspace_pin(declared: dict) -> str:
    revisions = {spec.get("rev") for spec in declared.values() if isinstance(spec, dict)}
    if len(revisions) != 1 or not re.fullmatch(r"[0-9a-f]{40}", str(next(iter(revisions)))):
        fail("rust/Cargo.toml must pin every ArkForge crate at one full revision, "
             f"found {sorted(map(str, revisions))}")
    return revisions.pop()


def check(root: Path) -> tuple[str, list[str]]:
    package_swift = (root / "Packages/ArkDeckKit/Package.swift").read_text(encoding="utf-8")
    if "ArkDeck/ArkForge" in package_swift:
        fail("Package.swift references ArkForge; the Swift SDK was deleted with the Swift Runtime")
    workspace = tomllib.loads((root / "rust/Cargo.toml").read_text(encoding="utf-8"))
    declared = {
        name: spec
        for name, spec in workspace["workspace"].get("dependencies", {}).items()
        if name.startswith("arkforge-")
    }
    if not declared:
        fail("rust/Cargo.toml declares no ArkForge crate")
    pin = workspace_pin(declared)
    for name, spec in sorted(declared.items()):
        if not isinstance(spec, dict) or set(spec) != {"git", "rev"}:
            fail(f"{name} must be declared as exactly {{ git, rev }}, not {spec!r}")
        if spec["git"] != REPOSITORY:
            fail(f"{name} comes from {spec['git']}, not {REPOSITORY}")
        if spec["rev"] != pin:
            fail(f"{name} is pinned at {spec['rev']}, not {pin}")
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
    manifest = manifests.pop()
    if manifest.name != "Cargo.toml" or Path(*manifest.parts[-3:]) != IPC_MANIFEST:
        fail(f"arkforge-ipc must live at {IPC_MANIFEST.as_posix()}, found {manifest}")
    # <checkout>/crates/arkforge-ipc/Cargo.toml
    return manifest.parents[2]


def check_layout(checkout: Path) -> None:
    """Read the published contract files and require the moved tree."""
    for relative in CONTRACT_FILES:
        if not (checkout / relative).exists():
            fail(f"pinned ArkForge is missing {relative.as_posix()}")
    for relative in RETIRED_PATHS:
        if (checkout / relative).exists():
            fail(f"pinned ArkForge still has retired path {relative.as_posix()}")
    proto = (checkout / "api/arkforge.proto").read_text(encoding="utf-8")
    if 'syntax = "proto3"' not in proto or "package arkforge.ipc.v1;" not in proto:
        fail("api/arkforge.proto is not the arkforge.ipc.v1 proto3 contract")
    versions = (checkout / "api/versions.yaml").read_text(encoding="utf-8")
    for needle in VERSION_NEEDLES:
        if needle not in versions:
            fail(f"api/versions.yaml lacks {needle}")


def run_vectors(root: Path, checkout: Path) -> None:
    environment = dict(os.environ, CARGO_TARGET_DIR=str(root / "rust/target/arkforge-vectors"))
    for package, test in (
        ("arkforge-ipc", "consumer_contract"),
        ("arkforge-arkdeck-adapter", "consumer_contract"),
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
    print(f"ArkForge {pin}: rust/Cargo.toml and rust/Cargo.lock agree "
          f"({', '.join(locked)})")
    checkout = arkforge_checkout(ROOT)
    check_layout(checkout)
    print(f"ArkForge {pin}: api/arkforge.proto and api/versions.yaml match the moved layout")
    if arguments.run_vectors:
        run_vectors(ROOT, checkout)


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as error:
        sys.exit(f"check-arkforge-pin: {error}")
