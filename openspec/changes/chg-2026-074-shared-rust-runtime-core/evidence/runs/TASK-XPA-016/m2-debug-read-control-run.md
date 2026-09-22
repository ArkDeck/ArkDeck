# TASK-XPA-016 — macOS Debug read control

Base: protected main `37453467d403a5adf7c13bdac2d6b12a26bafdd3` (#2105).
Branch: `agent/xpa-016-debug-read-control`. CHG-2026-074, M2/GJ-2/3.

The standalone Rust daemon now answers `debug.probe` and `debug.template.run`
through its production Control/Host, adopted Target route and verified HDC dispatcher.
The probe runs independent package, forward and reverse inventories concurrently,
with Swift's fixed arguments, 30-second budgets, capture limits, semantic failure
classification, sorted output and closed partial-failure warnings. The final projection
retains the 10,000-package/4,096-rule and bundle-name bounds.

The four existing read-only templates retain their command/capture budgets. Receipts
report nonzero exits and truncation without promoting them to success. Invalid UTF-8
or an unavailable receipt is rejected without retry. The returned argv redacts the
connect key; the lowering digest binds the actual argv and verified executable digest.
No caller command, shell fragment, path, executable or evidence enters the lowering.
The existing wire schemas and Swift semantics are unchanged.

The process test uses a private temporary root and inert fake executable, adopts its
synthetic target through the real Target owner and calls the actual production Host.
It checks partial inventory failure, nonzero template exit, exact lowering digest,
redaction, invalid encoding, and zero dispatch for malformed or unadopted requests.
The production Host also replays all 23 exchanges of the existing Swift Debug oracle
and its 26 exact calls, normalizing only its fixed duration. This includes signal death
with the same outcomeUnknown diagnostic and bounded truncation. The oracle is unchanged.
Provider tests check simultaneous dispatch, exact route/budgets, closed templates and
no retry after failed/truncated/unobservable receipts. These are host tests, not
hardware evidence or REAL_DEVICE_PASS. No installed daemon, LaunchAgent, device,
capability or trusted facts were changed.

## Local targeted checks

All Rust commands use `CARGO_BUILD_JOBS=2` and the dedicated
`CARGO_TARGET_DIR=/private/tmp/arkdeck-1330-rust-target` with
`--manifest-path rust/Cargo.toml`.

- `cargo build -p arkdeck-cli`: exit 0; `/private/tmp/arkdeck-debug-cli-build.log`.
  Existing daemon process tests invoke this adjacent binary.
- `cargo test -p arkdeck-provider-hdc -p arkdeck-control -p arkdeck-hoststore
  -p arkdeck-agentd -p arkdeck-soak`: exit 0, 737 passed / 14 pre-existing ignored;
  `/private/tmp/arkdeck-debug-tests.log`. Ignored cases are not counted as passing.
  The soak crate's workload smoke tests are not the RSS/FD performance acceptance.
- `cargo clippy` for those same five crates, `--all-targets -- -D warnings`:
  exit 0; `/private/tmp/arkdeck-debug-clippy.log`.
- `cargo fmt --all --check`: exit 0; `/private/tmp/arkdeck-debug-fmt.log`.
- `sh scripts/check-sdd.sh`: exit 0; `/private/tmp/arkdeck-debug-sdd.log`.

Contract generation was not run: no contract inputs changed. Full CI, signed App
acceptance and performance measurements were not run locally.

## CI

Pending push and automatic PR. No skipped job is counted as passing.

## Remaining

`debug.start/evaluate/status`, production trusted USB discovery, signed deployment and
formal device acceptance remain separate work. This change does not broaden the signed
App Mach ingress; that boundary still needs its own origin/ownership-aware migration.
No performance/soak measurement or G5/cutover claim is made.
