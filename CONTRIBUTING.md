# Contributing to ArkDeck

Thanks for helping improve ArkDeck. This file is the public entry point. Day-to-day
agent and maintainer boundaries live in [AGENTS.md](AGENTS.md). Safety invariants in
[`openspec/`](openspec/) are contracts: a change that weakens one is not merged.

Please read the [Code of Conduct](CODE_OF_CONDUCT.md) before participating.

## What you can change

ArkDeck is a local-first workbench for real OpenHarmony boards. Callers submit a
published operation and typed inputs. They do not submit raw `hdc` strings, shell
command lines, executable paths, remote paths, or trusted device facts.

Ordinary product work is one vertical pull request: the behavior, the tests that
prove it, and the docs that describe it. These changes need an OpenSpec change in
the same pull request, plus maintainer review:

- a new operation, or a breaking change to a published operation
- a new provider
- a new integration or device profile
- a change to destructive admission or another safety policy

Do not open a pull request whose only content is a status flip, a readiness note,
or a release tag. This repository does not cut git tags as part of routine work.

## Setup

You need the tools listed in [README.md](README.md#building-from-source):

- macOS 27 on Apple silicon and Xcode 27.0 (Swift 6.4) for the desktop app
- Rust from [`rust/rust-toolchain.toml`](rust/rust-toolchain.toml) for the runtime and CLI
- an OpenHarmony `hdc` executable only when the work talks to a real device

The root [`justfile`](justfile) wraps the existing commands. It does not introduce
a second build system. Run `just` to list recipes.

## Build, test, and lint

From the repository root:

```bash
just build          # Rust workspace and the Swift package
just test           # Rust CLI tests and Swift package tests
just lint           # rustfmt, clippy on arkdeck-contract, and the SDD check
just ci             # the same path-aware plan GitHub CI uses
```

Equivalent commands, if `just` is not installed:

```bash
python3 rust/scripts/run-cargo.py build
sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh build

python3 rust/scripts/run-cargo.py test -p arkdeck-cli
sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --parallel

python3 rust/scripts/run-cargo.py fmt --all --check
python3 rust/scripts/run-cargo.py clippy -p arkdeck-contract --all-targets -- -D warnings
sh hack/check-sdd.sh

python3 hack/ci/plan.py \
  --repo-root . \
  --base-revision origin/main \
  --head-revision HEAD \
  --merge-base \
  --include-worktree \
  --run-local
```

Targeted checks before push:

- Rust formatting: `python3 rust/scripts/run-cargo.py fmt --all --check`
- For each crate you changed, and crates that depend on it directly:
  `python3 rust/scripts/run-cargo.py clippy -p <crate> --all-targets -- -D warnings`
  and `python3 rust/scripts/run-cargo.py test -p <crate>`
- Contract inputs (`control-protocol.json`, `api/control/methods/**`, ControlFrames,
  CLI argv corpora): `python3 rust/scripts/generate-contract.py --check`
- `openspec/**`, `docs/**`, or `AGENTS.md`: `sh hack/check-sdd.sh`
- Swift: `sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --filter <Class>`
- App changes: `sh hack/ci/run-xcodebuild.sh` for the affected scheme

The Rust runner keeps `CARGO_BUILD_JOBS=2` and isolates caches with
`ARKDECK_CARGO_OWNER` (default `CODEX_THREAD_ID`, or `local` in a normal terminal).
Do not run the full CI matrix locally. GitHub CI is the complete gate.

The macOS app build is separate: `just build-app`, or
`sh hack/ci/run-xcodebuild.sh`. A Release build is `just build-app --release`.

## Pull requests

1. Branch from the latest `main`. Use an `agent/<short-topic>` branch for
   agent-drafted work. The name must not be `agent/host-loop/**`.
2. Keep the branch independent. Do not stack it on another open pull request.
   An agent commit that must stay on `main` includes exactly one trailer line:
   `Stack-Base: main`.
3. Push the branch. [`.github/workflows/agent-pr.yml`](.github/workflows/agent-pr.yml)
   opens the pull request as `github-actions[bot]`. Do not open a second pull
   request for the same branch.
4. Write the title and body in English. State what changed, why, and how you
   checked it. The template is
   [`.github/PULL_REQUEST_TEMPLATE.md`](.github/PULL_REQUEST_TEMPLATE.md).
5. Required status checks on protected `main` are `guard` (SDD Guard) and `swift`
   (the Swift CI aggregate). A green check is verification, not maintainer approval.
6. A human CODEOWNER review is required before merge. See
   [`.github/CODEOWNERS`](.github/CODEOWNERS). Agents do not merge.

Merge is a maintainer action. [Governance enforcement](openspec/governance/enforcement.md)
records a squash merge whose subject includes `(#N)`, so the git history alone
can be tied back to the pull request. Do not force-push `main`.

## Secrets and device data

Do not commit serial numbers, connect keys, machine names, account names, home
directory paths, or other secrets. Raw artifacts stay local. Logs and evidence
that land in the repository must already be redacted.

Report vulnerabilities privately, as described in [SECURITY.md](SECURITY.md).
Do not file a public issue for a security report.

## License

By contributing, you agree that your contributions are licensed under the
[MIT License](LICENSE).
