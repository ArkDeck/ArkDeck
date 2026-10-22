# ArkDeck task runner.
#
# Recipes wrap the scripts the repository already uses. They do not fetch
# dependencies, select a toolchain, or replace scripts/ci/plan.py.

set shell := ["bash", "-eu", "-o", "pipefail", "-c"]

# List the recipes.
default:
    @just --list

# Build the Rust workspace (runtime, CLI, and providers).
build-rust:
    python3 rust/scripts/run-cargo.py build

# Build the Swift package. This is the app-side libraries, not the runtime.
build-swift:
    sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh build

# Build the macOS app with the shared Xcode runner. Extra arguments are forwarded.
build-app *args:
    sh scripts/ci/run-xcodebuild.sh {{args}}

# Build the Rust workspace and the Swift package.
build: build-rust build-swift

# Test the Rust CLI package. Pass a crate name to test a different package.
test-rust crate="arkdeck-cli":
    python3 rust/scripts/run-cargo.py test -p {{crate}}

# Test the Swift package. Pass a class name to filter.
test-swift filter="":
    #!/usr/bin/env bash
    set -euo pipefail
    if [[ -n "{{filter}}" ]]; then
        sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --filter "{{filter}}"
    else
        sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --parallel
    fi

# Run the default Rust and Swift test entry points.
test: test-rust test-swift

# Format-check the Rust workspace, clippy one crate, and run the SDD check.
lint crate="arkdeck-contract":
    python3 rust/scripts/run-cargo.py fmt --all --check
    python3 rust/scripts/run-cargo.py clippy -p {{crate}} --all-targets -- -D warnings
    sh scripts/check-sdd.sh

# Run the path-aware local CI plan. Missing base facts select every lane.
ci:
    python3 scripts/ci/plan.py \
        --repo-root . \
        --base-revision origin/main \
        --head-revision HEAD \
        --merge-base \
        --include-worktree \
        --run-local

# Read-only SDD and catalog consistency check used by the guard job.
sdd:
    sh scripts/check-sdd.sh

# Check that every arkforge crate is pinned to the same full commit.
pin:
    python3 rust/scripts/check-arkforge-pin.py
