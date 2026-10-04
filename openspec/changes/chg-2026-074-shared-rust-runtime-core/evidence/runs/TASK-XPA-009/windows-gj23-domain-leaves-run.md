# TASK-XPA-009 — GJ-2/3 domain leaves on Windows: `debug hap`, `debug native deploy`, `recovery cleanup continue`

Change: CHG-2026-074-shared-rust-runtime-core. Milestone WM2 (GJ-2 and GJ-3).

Base: protected `main` `0b8cd63cb` (after the Windows census, #2555). It builds on the GJ-2/3 daemon
replay (`windows-gj23-daemon-replay-run.md`) and the GJ-1 domain-leaf measurement
(`gj1_device_leaves.rs`, TASK-XPA-005).

Host: the Windows 11 x64 reference host, non-elevated. No device, HDC or board was used, no `hdc`
was run, and nothing installed was read or written. Host tests are not Windows acceptance.

## What

`arkdeck-agentd/tests/spawning/gj23_replay.rs` (Windows) gains the two domain leaves and both
spellings of the cleanup debt continuation.

**The domain leaves.** `debug hap` and `debug native deploy` run through the real signed
`arkdeck.exe` against the signed test daemon over the Swift oracle's rebuilt root, with the
synthetic USB census naming the board of the oracle's adopted Target (`TGT-3ba3f5f43b92`):

1. The leaf takes the inputs of the oracle's first `job.submit` (`--target`, `--inputs-file`) and
   the fake is put in the mode of the oracle's first `job.run`.
2. It observes the board (`device.observations`), submits and runs the operation's Job, reads its
   evidence and Artifacts, and completes: exit 0, `ok`, the leaf's command, the operation's
   reference, `outcomeUnknown: false`, every Artifact `bytesVerified`.
3. The receipt's evidence observation is the one the oracle's first `job.result` carries:
   `debug.hap@1` binds the Target's observation; the native library deploy's evidence has none
   (`observation: null` in the oracle), and the receipt has none.
4. The fake must have received, after the leaf's observation reads (`list targets -v` only),
   exactly the calls of the oracle's first Job, the Job identity aside (this run mints its own).
   The oracle's first Job ends at the next Job's observation or, for a Job that observes nothing
   (the native library deploy), at the first call naming another Job.

**The fake.** The native library answers did not list targets, because the Swift oracle's Jobs
never listed the device. The CLI's domain leaf observes first, so the shared fake now answers
`list targets -v` in native-library mode with the fixture's one target, as the debug HAP answers
already do (`arkdeck-provider-hdc/tests/common/oracle_fake.rs`). No Swift oracle replay reaches
that answer.

**Both continuation spellings.** The daemon replays send a remote path's debt through
`recovery cleanup continue` and a bundle's through `cleanup-debt continue`. Each answer, call and
leftover must still be Swift's (63 and 40 exchanges, 108 and 225 calls).

**Measured leaves.** `debug.hap`, `debug.native.deploy`, `recovery.cleanup.continue` and
`cleanup-debt.continue` join `WINDOWS_MEASURED_LEAVES`. `arkdeck maintainer contracts export`
regenerated `openspec/contracts/cli-feature-coverage.json`: `debug.hap@1`,
`deploy.native-library.app-owned@1` and `cleanupDebt.continue` move from `partial` to
`implemented` on Windows, and nothing else changes. The tests assert those statuses in the
coverage the build renders. The census (`docs/design/cross-platform/windows-remaining.md`) drops
their rows, and restates two stale ones: `workspace sign` (#2508 merged; the leaf is measured
only as the development root's refusal) and `workspace symbolize` (#2512 closed; the leaf waits
for a crash dump Artifact published on Windows).

## Measured

| test | result |
| --- | --- |
| `gj23_replay::the_real_cli_debug_hap_leaf_runs_the_swift_oracle_s_job` | pass |
| `gj23_replay::the_real_cli_debug_native_deploy_leaf_runs_the_swift_oracle_s_job` | pass |
| `gj23_replay::the_real_cli_runs_every_swift_debug_hap_through_the_signed_test_daemon` | pass, with `recovery cleanup continue` for `debt.continuePath` |
| `gj23_replay::the_real_cli_runs_every_swift_native_deployment_through_the_signed_test_daemon` | pass, the same |

## Left out

- The oracle pins do not change: no oracle was re-recorded.
- `job.plan`, `job.submit` and `job.run` stay unmeasured (the lead's ruling of 2026-10-04).
- No real HDC or device; the board window confirms GJ-2/3 on the DAYU200.

## Local targeted checks

Rust 1.99.0, `CARGO_BUILD_JOBS=2`, `CARGO_TARGET_DIR=D:/cargo-target/s1-remaining`, with
`ARKDECK_DEV_SIGNER_THUMBPRINT` set; heavy commands through the host's gate slot.

| command | result |
| --- | --- |
| `cargo fmt --all --check` | exit 0 |
| `cargo clippy --workspace --all-targets -- -D warnings` | exit 0 |
| `cargo test -p arkdeck-cli -p arkdeck-agentd -p arkdeck-provider-hdc --no-fail-fast` (on `efb64785d`; main since changed only `account_tool_selection.rs` and docs) | exit 0: 634 passed, 0 failed, no SKIPPED |
| the same with `TEMP`/`TMP` on an 8.3 short path on C: | exit 0 |
| macOS (`aarch64-apple-darwin`) and Linux (`x86_64-unknown-linux-gnu`) clippy `-D warnings`, stub toolchain | exit 0 |
| `PYTHONUTF8=1 sh scripts/check-sdd.sh` | exit 0 |
| `git diff --check origin/main...HEAD` |
| `arkdeck maintainer contracts check` | exit 0: 242 checked, clean | exit 0 |

## CI

To be recorded by the next slice.
