# Rust CLI version entry found during signed cutover preparation

The signed CLI built from protected main `443e805ef7529e61a9860ccae7011c072142e52a`
returned exit 64 for `arkdeck --version --output json`. The registry knew the
flag, but did not route it to a local result. This prevented the headless
runbook from identifying the actual build before acceptance.

The local entry now reports the same product and pinned contract versions as
Swift. Its build identity is the SHA-256 of the running executable, including
its signature, streamed in 1 MiB chunks; unreadable identity is null. It never
connects to the Runtime. Global/leaf precedence follows the registry, preserving
leaf-owned `--version` values and the existing leading connection-option rules.

`CLIVersionOracleContractTests` runs the actual Swift CLI for the 30 committed
observations. Rust replays those exit statuses and outputs, verifying each
executable's actual hash before labelling it. Only generated correlations and
that independently checked build hash are labelled. For `doctor --help --version`,
Rust must return its complete ordinary doctor help: its existing transport prose
and option formatting differ from Swift's; this change preserves those words.
Additional regression coverage keeps leaf-owned version refusal ordering with
leading connection options.

## Local targeted checks

All commands ran on macOS, with `CARGO_BUILD_JOBS=2` and the worktree-specific
`CARGO_TARGET_DIR=/private/tmp/arkdeck-takeover-d79c-target` for Rust.

- `cargo test --manifest-path rust/Cargo.toml -p arkdeck-cli`: exit 0,
  480 passed; `/private/tmp/arkdeck-version-cli-tests.log`. The initial sandbox
  attempt could not bind test sockets; the host-environment rerun passed.
- `cargo clippy --manifest-path rust/Cargo.toml -p arkdeck-cli --all-targets -- -D warnings`:
  exit 0; `/private/tmp/arkdeck-version-clippy.log`.
- `cargo fmt --all --check --manifest-path rust/Cargo.toml`: exit 0;
  `/private/tmp/arkdeck-version-fmt.log`.
- `python3 rust/scripts/generate-contract.py --check`: exit 0;
  `/private/tmp/arkdeck-version-contract-check.log`.
- `sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --filter CLIVersionOracleContractTests`:
  exit 0, one test covering 30 process observations;
  `/private/tmp/arkdeck-version-swift-oracle.log`.
- `sh scripts/check-sdd.sh`: exit 0; `/private/tmp/arkdeck-version-sdd.log`.

No direct workspace crate depends on `arkdeck-cli`. The added `sha2` dependency
uses the already locked workspace version. Full multi-platform verification is
left to GitHub CI; no local unified gate was run. No device operation or installed
Runtime change is part of this fix.

## CI

The bot PR and exact-head GitHub CI results will be reported in the PR after push.
This result is not GJ hardware acceptance or approval to retire Swift targets.
