#!/usr/bin/env python3
"""Copy the published App capability registry into the Rust CLI.

`rust/crates/arkdeck-cli/src/app_capability_registry.json` is the App's
capability table (Swift `AppProductCapabilityRegistry`): the `capabilities` of
the published `openspec/contracts/app-product-capability-registry.yaml`, in the
App's order, with its schema version. The Rust export renders that registry
and the feature coverage's App entries from it, and its test holds the
rendered registry to the published one (`owned.json`), which Swift's own
contract tests hold to the App's table.

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
PUBLISHED = ROOT / "openspec/contracts/app-product-capability-registry.yaml"
COPY = ROOT / "rust/crates/arkdeck-cli/src/app_capability_registry.json"


def rendered() -> str:
    registry = yaml.safe_load(PUBLISHED.read_text(encoding="utf-8"))
    projection = {
        "appCapabilityRegistrySchemaVersion": registry["schemaVersion"],
        "capabilities": registry["capabilities"],
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
        if not COPY.exists() or COPY.read_text(encoding="utf-8") != text:
            print(f"{COPY.relative_to(ROOT)} differs from {PUBLISHED.relative_to(ROOT)}; "
                  f"run python {Path(__file__).resolve().relative_to(ROOT)}", file=sys.stderr)
            return 1
        return 0
    COPY.write_text(text, encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
