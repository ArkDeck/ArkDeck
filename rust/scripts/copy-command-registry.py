#!/usr/bin/env python3
"""Copy the published command registry into the Rust CLI.

`rust/crates/arkdeck-cli/src/command_registry.json` is Swift's projection of
its whole registry: the `commands` of the published
`openspec/contracts/cli-command-registry.yaml`, with its schema version. The
Rust CLI serves `commands`, `help` and `completion` from it and renders the
registry YAML from it; `CLIRustCommandRegistryCopyContractTests` holds it to
Swift's projection.

Run it after `arkdeck maintainer contracts export` changes the registry to
refresh the copy; with --check it writes nothing and fails when the copy has
drifted.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys

import yaml

ROOT = Path(__file__).resolve().parents[2]
PUBLISHED = ROOT / "openspec/contracts/cli-command-registry.yaml"
COPY = ROOT / "rust/crates/arkdeck-cli/src/command_registry.json"


def rendered() -> str:
    registry = yaml.safe_load(PUBLISHED.read_text(encoding="utf-8"))
    projection = {
        "commandRegistrySchemaVersion": registry["schemaVersion"],
        "commands": registry["commands"],
    }
    return json.dumps(projection, indent=2, sort_keys=True, ensure_ascii=False) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--check", action="store_true",
        help="write nothing; fail when the copy differs from the published registry")
    arguments = parser.parse_args()
    text = rendered()
    if arguments.check:
        if COPY.read_text(encoding="utf-8") != text:
            print(f"{COPY.relative_to(ROOT)} differs from {PUBLISHED.relative_to(ROOT)}; "
                  f"run python {Path(__file__).resolve().relative_to(ROOT)}", file=sys.stderr)
            return 1
        return 0
    COPY.write_text(text, encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
