#!/usr/bin/env python3
"""Run the Rust workspace tests against the checkout's own contract inputs.

`cargo test --workspace` includes `corpus_parity`, whose cases assert that every
Swift contract input in the checkout is byte-identical to the committed manifest
`spec/baselines/swift-single-v1.json`. That manifest describes the checkout it
is committed in, so the assertion is false only when a change edited an input
without regenerating. This wrapper names that case, with the regenerate command,
before the tests run, and otherwise runs them unchanged.

It compares the checkout with nothing else. A Swift change regenerates the
manifest in its own PR, and `origin/main` never enters: a merge elsewhere cannot
make this checkout red. The published-versus-candidate comparison is
check-contracts.py's job, later in the same lane.

Exit codes are cargo's when the tests run, 1 when the manifest or bindings need
regeneration or cannot be read.
"""

from __future__ import annotations

import importlib.util
import pathlib
import subprocess
import sys

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]


def load_generator():
    path = pathlib.Path(__file__).resolve().with_name("generate-contract.py")
    spec = importlib.util.spec_from_file_location("arkdeck_contract_generator_workspace", path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def main(run=subprocess.run, generator=None) -> int:
    try:
        (generator or load_generator()).verify_checkout()
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(
            "the checkout's contract inputs, manifest and generated bindings "
            f"disagree, so the workspace tests would fail on the repository, not "
            f"on the Rust code: {error}",
            file=sys.stderr,
        )
        return 1
    return run(
        ("cargo", "test", "--workspace"), cwd=REPO_ROOT / "rust", check=False
    ).returncode


if __name__ == "__main__":
    raise SystemExit(main())
