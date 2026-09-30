# TASK-XPA-012 on Windows — the cleanup debt methods on the Windows daemon (2026-09-30)

- **Kind:** host-only, on the Windows 11 x64 reference host. No hdc was run and the DAYU200 was
  not touched. Every daemon ran over a fresh development root below the temporary directory,
  holding recorded Swift state.
- **Base:** protected `main` `57cbfe39` (#2421).

## What changed

- `arkdeck-hoststore`: `cleanup_debt_continue.rs` (`JobRunner::continue_cleanup_debt`) builds on
  Windows. Its code is unchanged. `cleanup_debt.rs` and `list_cleanup_debt` already built there.
- `arkdeck-agentd`: the Windows `Host::cleanup_debt` answers `cleanupDebt.list` from the Artifact
  owner, as macOS does. It answers `cleanupDebt.continue` through `windows_runner`, the runner
  `job.run` uses on Windows, with `hdc: None`. There is no census entry: macOS names none for
  these methods, which ride on `artifacts` and `jobs`.
- `cleanup_debt_control.rs` (the control-layer replay of the committed corpus) runs on Windows
  too. On Windows its host also composes the planning root, which the Windows runner is built
  over and which the daemon always composes with the Job owner.
- `arkdeck-cli`: `recovery.cleanup.list` and its alias `cleanup-debt.list` join
  `WINDOWS_MEASURED_LEAVES`. `cli-feature-coverage.json` was regenerated with `arkdeck maintainer
  contracts export`, so `cleanupDebt.list` becomes Windows `implemented` (61 → 62). The six
  coverage-digest pins in `rust/tests/fixtures/maintainer-contracts/oracle.json` were
  substituted (`380e91ed…` → `b5ada317…`).
- `cleanupDebt.continue` stays `partial`. With no Windows HDC tuple registered, every owed debt
  is refused before its readback.

## Swift oracles

- `ControlFrames/cleanupDebt.list.jsonl` (3 frames): each list is answered as recorded over a
  ledger that owes what it lists, on both hosts (`cleanup_debt_control.rs`). Over the real
  daemon, Swift's recorded debug HAP ledger (`rust/tests/fixtures/debug-hap/artifacts/
  cleanup-debt.json`, without the settlements its continuations wrote) lists exactly as the corpus
  records it, before and after a restart.
- `ControlFrames/cleanupDebt.continue.jsonl`: its refusal (`invalidParams`) is answered as
  recorded. Its two `settled` continuations need the HDC. Their replays stay in the macOS device
  oracles (`arkdeck-hoststore/tests/support/hdc_oracle.rs`).

## The no-HDC refusal

`windows_cleanup_debt_process.rs` admits the two recorded Jobs that owe the debts into
`jobs-state` (Job store owner, daemon stopped). It lays Swift's recorded capability store beside
them in `jobs-state\capabilities`. For each owed debt (the bundle `com.example.demo`, and the
staged HAP path), `cleanupDebt.continue` then:

- reads the ledger;
- loads the terminal Job as restart recovery does, proving its authorization lineage against
  that capability store;
- materializes the persisted action and matches it to the residue;
- is refused `rejected` `internalFailure("provider hdc is unavailable")` before any readback or
  retry is planned.

The ledger's bytes are unchanged, also after a restart. Two more refusals are shown:

- A debt the ledger does not owe is refused as `jobNotFound`.
- An undecodable ledger fails both methods with Swift's store error.

Through the real CLI against a development-signed daemon:

- `recovery cleanup list` and `cleanup-debt list` print the recorded rows.
- `recovery cleanup continue --job … --bundle com.example.demo` exits non-zero. It reports the
  daemon's `rejected` refusal, which the CLI renders as `outcomeUnknown` with
  `details.wireCode: rejected`.

## Delegated minor decision (pending the next rulings batch)

1. `cleanupDebt.continue` on Windows needs the planning root as well as the Job and Artifact
   owners, because the Windows runner is composed over it in one place (`windows_runner`). The
   daemon always composes the three together, so a real daemon answers the same as macOS.

## Checks

- `ARKDECK_DEV_SIGNER_THUMBPRINT=AAC23CA4D38D100996C861D9E1A68DEECD69B149`,
  `CARGO_TARGET_DIR=D:/cargo-target/a1-cleanup`.
- See the commit message for the local results and the macOS cross-check.
