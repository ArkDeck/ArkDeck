# TASK-XPA-009 — GJ-2/3 end to end on the Windows daemon: the real CLI against the signed test daemon

Change: CHG-2026-074-shared-rust-runtime-core. Milestone WM2 (GJ-2 and GJ-3), slice CI2.

Base: protected `main` `5e9a009d`. It builds on M1's Windows Job HDC composition (#2499) and the
signed test daemon (#2479).

Host: the Windows 11 x64 reference host, non-elevated. No device, HDC or board was used, no `hdc`
was run, and nothing installed was read or written. Host tests are not Windows acceptance.

## What

`arkdeck-agentd/tests/spawning/gj23_replay.rs` (Windows) replays two Swift oracles end to end:
`debug.hap@1` (`rust/tests/fixtures/debug-hap`, 63 exchanges) and
`deploy.native-library.app-owned@1` (`deploy-native-library`, 40 exchanges).

**The run.**
1. The real signed `arkdeck.exe` sends every recorded exchange to the signed test daemon over its
   pipe. The CLI checks the daemon with the production peer check.
2. The exchanges cover `job plan`, `job submit` (from the recorded `requestJson`), `job run`,
   `job result`, `job evidence`, `artifact list`, `capability list`, `capability inspect`,
   `cleanup-debt list` and `cleanup-debt continue`.
3. The test daemon composes the production Windows development root (`windows_lifecycle`) and
   M1's Job HDC composition. The shared fake's answers reach it in process, through the
   `cfg(all(windows, test))` seam.

**What must equal Swift's.**
- Every Runtime answer behind the CLI envelope must be the recorded one: the result, or the wire
  code, message and details.
- The fake must have received the recorded calls in order: 108 and 225.
- `targets.json` must be the recorded one.
- Each Job must consume its use exactly once.
- Everything left below the root must be the recorded one: the Job index, records, Journals,
  capability checkpoint and ledger, Sessions, the Session owner and Artifacts.

**How they are read.** Exactly as the hoststore replays read them:
- host paths in the oracle's spelling;
- plan digests and what they derive, relabelled one to one (rulings 48 and 61);
- `PLATFORM-WINDOWS` read as `PLATFORM-MACOS`.

The comparison that follows the exchanges is now one function, `hdc_oracle::assert_relabelled`,
shared with `assert_replays`, so both replays read through the same code.

**The replay root.** It is the oracle's, rebuilt (`support::debug_hap::rebuild`), and shared with
the hoststore replays under their lock.
- While the daemon serves, its `store`, `session-owner` and `Sessions` carry the development
  root's names: `jobs-state`, `session-state` and `sessions`. Before the comparison they get the
  oracle's names back. A path that names them is read under the oracle's names.
- The agent-execution owner, which every Windows development root composes, leaves its empty store
  (`agent-executions\snapshots`). The test checks that it is empty, then removes it, because no
  oracle composed one.

**What the test daemon alone takes.** Three inputs, each set by the test, read only by
`signed_daemon.rs` and compiled into test builds only:
- **The oracle's clock (`CLOCK`).** `host.rs`'s clock reads go through `clock_now` and
  `clock_precise_now`, and `utc_now` checks the same clock first. In a Windows test build these
  read the fixed `TEST_CLOCK` when the process took one. Otherwise, and in every other build, they
  are `runtime_now` and `runtime_precise_now`.
- **The mutation root (`MUTATION_ROOT`).** It is the replay root's own `jobs-state`. A Windows
  development root names the account's `jobs-state`, where no oracle's Job is
  (`the_mutation_root_is_the_only_root_the_proof_passes_on_windows`). The oracle's runs proved
  against their own store.
- **The code-sign helper (`HELPER`).** The native oracle recorded the helper's facts (ABI, build
  id, SHA-256, byte count), not its bytes, at `<root>\host\arkdeck-code-sign-enable`. The test
  daemon composes those facts, as the hoststore replay does. The fake never reads the bytes.

## Measured

| test | result |
| --- | --- |
| `gj23_replay::the_real_cli_runs_every_swift_debug_hap_through_the_signed_test_daemon` | pass: 63 answers, 108 calls, the Target document and every leftover are Swift's, read as above |
| `gj23_replay::the_real_cli_runs_every_swift_native_deployment_through_the_signed_test_daemon` | pass: 40 answers, 225 calls, the same |
| negative control: the mutation root moved elsewhere | the debug.hap replay fails |
| `arkdeck-hoststore` `debug_hap_run` and `native_library_run`, over the extracted comparison | pass (8 and 4 tests) |

## Delegated minor decisions, pending the next rulings batch

- **The three test-daemon inputs above.** Each one is set only in a test build and relaxes no
  production gate: the production Windows daemon still composes an HDC only for a registered tuple,
  proves device mutations against the account's Job state, and verifies the bundled helper's bytes.
- **The replay root under the development root's names,** and the agent-execution owner's empty
  store removed before the comparison.
- **The leaves.** `job.plan`, `job.submit` and `job.run` stay out of `WINDOWS_MEASURED_LEAVES`, as
  the lead ruled: these three leaves serve every operation, and not every one of them answers as
  Swift does on Windows yet. Their GJ-2/3 measurement is this record.

## Left out

- The coverage manifest and the oracle pins do not change, because no leaf was added.
- No real HDC or device. The production daemon's tuple stays unregistered here (CHG-2026-078).

## Local targeted checks

Rust 1.99.0, `CARGO_BUILD_JOBS=2`, `CARGO_TARGET_DIR=D:/cargo-target/ci2-gj23`, with
`ARKDECK_DEV_SIGNER_THUMBPRINT` set.

| command | result |
| --- | --- |
| `cargo fmt --all --check` | exit 0 |
| `cargo clippy --workspace --all-targets -- -D warnings` | exit 0 |
| `cargo test -p arkdeck-agentd -p arkdeck-hoststore --no-fail-fast` | 611 passed, 1 failed (below), 7 ignored, no SKIPPED |
| the same with `TEMP`/`TMP` on an 8.3 short path on C: (`AD-SHO~4`) | exit 0: 612 passed, 7 ignored |
| macOS (`aarch64-apple-darwin`) and Linux (`x86_64-unknown-linux-gnu`) check and clippy `-D warnings`, stub toolchain | exit 0, after making the clock alias's `cfg` exclude Linux (it has no hoststore) |
| `PYTHONUTF8=1 sh scripts/check-sdd.sh` | exit 0 |
| `git diff --check` | exit 0 |

**The one failure.** `windows_account_locations_process`
`the_cli_reads_the_same_account_locations_from_a_dev_signed_daemon` failed once: its account
daemon exited before printing its listening line. I treat it as a transient, on the four criteria:

- the test is not in this diff;
- it starts the account's own daemon, which other worktrees' tests on this host share;
- it passed in the 8.3 run and in three later runs on their own (4/4 each);
- its daemon composes no test seam, so this change does not touch it.

The `spawning` binary passed 8 of 8 after the Linux `cfg` fix.

## CI

To be recorded by the next slice.
