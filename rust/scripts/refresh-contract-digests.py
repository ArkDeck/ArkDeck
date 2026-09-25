#!/usr/bin/env python3
"""Refresh the digests the Rust contract export is held to.

`rust/tests/fixtures/contracts-bundle/owned.json` keeps the SHA-256 of each
product of the machine-contract bundle the Rust CLI renders
(`arkdeck_cli::machine_contracts`), because the contract views do not carry the
bundle. `check-contracts.py` holds the table to the committed bundle, and the
Rust test (`tests/machine_contracts.rs`) holds each rendered product to the
table.

The export renders every fixture of the bundle, so the table lists every
committed fixture, and the contract products it already lists. After
`arkdeck maintainer contracts export` changes the bundle (a registry change
rewrites argv fixtures and the fixture index), run this to write the committed
products' digests into the table, then the Rust test to learn whether the Rust
export renders them. With --check it writes nothing and fails when the table
differs from what it would write.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
TABLE = ROOT / "rust/tests/fixtures/contracts-bundle/owned.json"
CONTRACTS = ROOT / "openspec/contracts"
FIXTURES = ROOT / "Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/CLI"


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def rendered() -> str:
    owned = json.loads(TABLE.read_text(encoding="utf-8"))
    table = {}
    for key in owned:
        root, _, relative = key.partition("/")
        if root == "contracts":
            table[key] = digest(CONTRACTS / relative)
    for path in FIXTURES.rglob("*"):
        if path.is_file():
            table["fixtures/" + path.relative_to(FIXTURES).as_posix()] = digest(path)
    return json.dumps(table, indent=2, sort_keys=True) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--check", action="store_true",
        help="write nothing; fail when the table differs from the committed bundle")
    arguments = parser.parse_args()
    text = rendered()
    if arguments.check:
        if TABLE.read_text(encoding="utf-8") != text:
            print(f"{TABLE.relative_to(ROOT)} differs from the committed bundle; "
                  f"run python {Path(__file__).resolve().relative_to(ROOT)}", file=sys.stderr)
            return 1
        return 0
    TABLE.write_text(text, encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
