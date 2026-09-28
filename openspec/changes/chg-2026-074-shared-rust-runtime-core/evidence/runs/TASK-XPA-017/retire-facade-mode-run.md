# Retire the Rust daemon's facade mode (S6c)

TASK-XPA-017, final-lane §4 S6 ("一并退役: Rust daemon 的 façade 模式与
`rust/scripts/package-macos-facade.sh`; `build-helpers.sh` 与 `build-local-helpers.sh`
的 Swift 分支"), base `6edb4e479` (#2307), 2026-09-28. Host-only: no installed
Runtime, real launchctl, device, signing identity or credential was used; nothing
here is `REAL_DEVICE_PASS`.

## What changed

- `arkdeck-agentd` has two compositions left: the isolated development root and
  the standalone/production one. `src/facade.rs` (the forwarding transport),
  `src/facade_owners.rs` and its tests are deleted. A process started under the
  retired `arkdeck-facade` name, or handed `ARKDECK_SWIFT_DAEMON` /
  `ARKDECK_SWIFT_SHA256`, now refuses to start (exit 69) before binding or
  opening anything (`production::refuse_retired_facade`); it no longer forwards.
  The one-shot modes (analyzers, symbolizer, cutover preflight) still answer
  first, and the production composition and the cutover preflight keep refusing
  the facade name and the pairing inputs as before. App ingress no longer checks
  for a paired Swift sibling (the startup refusal precedes it).
- Deleted: `rust/scripts/package-macos-facade.sh`, `test-macos-facade.py`,
  `test-macos-foreign-euid.py` (its fixture was the facade test),
  `benchmark-macos-facade.py`, `check-facade-host-owners.py`; `check-contracts.py`
  no longer runs the facade transport test.
- `build-helpers.sh` and `build-local-helpers.sh` build only the Rust pair
  through `package-rust-helpers.sh`; `ARKDECK_HELPER_RUNTIME` and
  `ARKDECK_ROLLBACK_HELPER` are no longer read. `package-rust-helpers.sh` drops
  its seventh (rollback helper) argument, `build-unsigned-rust-helpers.sh` and
  `check-rust-helpers.py` (`--expect-rollback`, `check_rollback`) follow, and
  `scripts/release/build_macos_release.py` stops passing the mode. This follows
  the maintainer's 2026-09-28 ruling P8: no Swift rollback build; the rollback is
  the installed facade + Swift pair kept by `runtime service update` in
  `Helpers/.rollback` plus the maintainer's `ditto` copy.
- Kept on purpose: the Rust CLI's support for installing and reading a prebuilt
  bundle that carries a signed `arkdeck-facade` (plist `ProgramArguments` = the
  facade, `ARKDECK_SWIFT_SHA256` pinning the Swift daemon beside it, the facade
  signature check in `status`). That is the runbook §4 rollback path and needs no
  facade source. `LocalListener::bind_facade` and the production composition's
  refusal to start beside the installed facade's transport lock also stay: the
  installed Swift release holds that lock until the cutover.
- New tests: `arkdeck-agentd/tests/retired_facade.rs` (name, both pairing
  variables, and the two production refusals, each exit 69 with nothing created)
  and `production::tests::the_retired_facade_is_refused_by_name_and_by_its_pairing`;
  `arkdeck-cli/tests/runtime_service.rs`
  `update_installs_the_retained_facade_pair_and_rolls_back_to_it` installs a
  prebuilt facade + Swift bundle in a temporary home with the recording launchd,
  checks the plist byte for byte, the receipt and `status`, cuts over to a Rust
  helper (the pair lands in `.rollback`) and rolls back to the retained copy,
  restoring the plist and receipt byte for byte.
- `LaunchAgentServiceContractTests.testDistributionHelpersShareOnlyTheProvisionedKeychainGroup` (Swift) pinned the
  Swift steps of both build scripts; it is minimally updated to pin the Rust
  steps, one notarization each, and the absence of the retired inputs. S6 deletes
  this file with the Swift targets and can drop the edit on rebase.
- Docs: `rust/README.md` (the facade host-owner section becomes "Retired facade
  mode"), `Packages/ArkDeckKit/LaunchAgents/README.md`, runbook appendix line
  references for the rewritten scripts.

## Local targeted checks

Logs under `/private/tmp/arkdeck-s6c-logs/` (not committed).
`CARGO_TARGET_DIR=/private/tmp/arkdeck-s6c-target CARGO_BUILD_JOBS=2`.

| Command | Exit | Log |
| --- | --- | --- |
| `cargo fmt --all --check --manifest-path rust/Cargo.toml` | 0 | — |
| `cargo clippy --manifest-path rust/Cargo.toml -p arkdeck-agentd -p arkdeck-cli --all-targets -- -D warnings` | 0 | — |
| `cargo test --manifest-path rust/Cargo.toml -p arkdeck-cli` | 0 | `cli-test.log` |
| `cargo test --manifest-path rust/Cargo.toml -p arkdeck-agentd --no-fail-fast` | 101: 25 binaries ok, 1 test failed (below) | `agentd-test2.log` |
| `cargo test … -p arkdeck-agentd --test crash_ledger_analyzer` ×3 | 0, 0, 0 | — |
| `python3 Packages/ArkDeckKit/Distribution/macOS/test-local-rust-helpers.py` | 0 (7 tests) | — |
| `python3 scripts/release/test_build_macos_release.py` | 0 (18 tests) | — |
| `build-unsigned-rust-helpers.sh` (binaries from the debug target) then `check-rust-helpers.py` | 0, 0 (66 checks) | `unsigned.log`, `check-rust-helpers.log` |
| `sh scripts/check-sdd.sh` | 0 | `check-sdd.log` |
| `sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --filter LaunchAgentServiceContractTests` | 0 (26 tests) | `swift-launchagent.log` |

The first `cargo test -p arkdeck-agentd` run stopped at `agent_run_cli_process`
because the `arkdeck` CLI binary was not yet built in this fresh target (the test
says to build it or run the workspace tests); after `cargo build -p arkdeck-cli`
the rerun passed it. In that rerun
`crash_ledger_analyzer::an_agent_execution_of_the_analyzer_runs_its_job_to_the_end`
failed once (Job `failed` instead of `succeeded`) and passed three times alone.
It is not in this diff's scope (the analyzer mode and its dispatch order are
unchanged), ran while the host load was about 3–3.5, and is stable alone: an
invalid run by the four criteria.

`python rust/scripts/test_contract_checks.py` was not run locally (this host's
Python lacks `jsonschema`); the one-line removal from `check-contracts.py` is
exercised by CI's contract parity step. `generate-contract.py --check` is not
needed: no contract input changed.

## CI

To be recorded by the next slice or a docs-only follow-up (PR number, run id,
conclusion).
