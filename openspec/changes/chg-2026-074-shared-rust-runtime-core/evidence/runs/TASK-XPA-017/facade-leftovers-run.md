# Remove the Rust facade leftovers after #2309

TASK-XPA-017, cleanup after "Retire the Rust daemon's facade mode" (#2309,
`retire-facade-mode-run.md`), base `32db20b10` (#2311), 2026-09-29. Host-only:
no installed Runtime, launchctl, device, signing identity or credential was
used; nothing here is `REAL_DEVICE_PASS`.

## What changed

`rg` over `arkdeck-facade`, `ARKDECK_SWIFT_DAEMON`, `ARKDECK_SWIFT_SHA256`,
`com.arkdeck.agentd.facade` and `facade` in `rust/` found one dead leftover:

- `rust/crates/arkdeck-agentd/build.rs` embedded an `__info_plist` section with
  `CFBundleIdentifier = com.arkdeck.agentd.facade` into every `arkdeck-agentd`
  build. It existed so `package-macos-facade.sh` (deleted in #2309) could sign
  the unbundled Rust daemon as the facade. The Rust helper is signed as
  `ArkDeckAgent.app` with that bundle's `Info.plist` (`package-rust-helpers.sh`,
  `com.arkdeck.agentd`), and nothing reads the embedded section (the only
  `NSBundle.mainBundle` reader, `macos_update_http.m`, serves the CLI). Deleted;
  `rust/README.md` "Retired facade mode" notes it.

Kept, because they are live:

- CLI rollback path: `SWIFT_SHA256_KEY`, `FACADE_EXECUTABLE_NAME`, the facade
  signature check (`arkdeck_platform::validate_facade_signature` and its
  `FACADE_CODE_REQUIREMENT`, which `runtime service status` applies to the
  retained Swift pair's signed facade) and the facade plist rendering
  (`update_installs_the_retained_facade_pair_and_rolls_back_to_it`), and the
  install-time refusal of a Rust bundle that carries a facade.
- Daemon refusals: `production::refuse_retired_facade`,
  `runs_as_retired_facade`, the production composition's `REFUSED` entries for
  `ARKDECK_SWIFT_DAEMON`/`ARKDECK_SWIFT_SHA256`/`ARKDECK_PRIVATE_SOCKET` (their
  own message, asserted by `production_composition.rs` and
  `retired_facade.rs`), `LocalListener::bind_facade`, and the tests that run a
  copy under the facade's name (analyzers and cutover preflight answer or refuse
  first).
- Outside `rust/crates`: the App's and probes' XPC requirement still accepts
  `com.arkdeck.agentd.facade` because the rollback target is the installed
  Swift pair; `installed_rust_ui.py` checks that no facade is installed.

## Local targeted checks

`CARGO_TARGET_DIR=/private/tmp/arkdeck-cleanup-target CARGO_BUILD_JOBS=2`; logs
under `/private/tmp/arkdeck-cleanup-logs/` (not committed).

| Command | Exit | Log |
| --- | --- | --- |
| `cargo fmt --all --check --manifest-path rust/Cargo.toml` | 0 | — |
| `cargo clippy --manifest-path rust/Cargo.toml -p arkdeck-agentd --all-targets -- -D warnings` | 0 | `p1-clippy.log` |
| `cargo build --manifest-path rust/Cargo.toml -p arkdeck-cli` (for `agent_run_cli_process`) | 0 | `p1-cli-build.log` |
| `cargo test --manifest-path rust/Cargo.toml -p arkdeck-agentd --no-fail-fast` | 0 (26 binaries, 217 passed) | `p1-agentd-test.log` |
| `otool -s __TEXT __info_plist target/debug/arkdeck-agentd` | section absent | — |
| `sh scripts/check-sdd.sh` | 0 | `p1-check-sdd.log` |

No crate depends on `arkdeck-agentd`; no contract input changed, so
`generate-contract.py --check` is not needed.

## CI

PR #2314. First head `85d604a28`: Swift CI run 36452084040 failed in "Rust
host-independent checks" at
`rust/scripts/test_ci_execution.py` `test_cache_key_separates_compiler_image_flags_manifests_and_stable_path`
with `OSError: [Errno 39] Directory not empty: .../checkout/.git/objects/pack`
while `TemporaryDirectory` removed its scratch checkout. Invalid run by the four
criteria: the script is not in this diff, the error is a cleanup race with a git
process still writing the pack directory, the suite passes locally (20 tests,
OK), and nothing in it reads `arkdeck-agentd`'s build script. Re-pushed with
this note; the final run is recorded by a docs-only follow-up.
