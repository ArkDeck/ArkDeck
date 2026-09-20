# TASK-XPA-014 — recovery port, slice 2e-b: the Rust crash-window matrix

Change: CHG-2026-074-shared-rust-runtime-core@r11. The last piece of slice 2 of the recovery port
the maintainer ruled on 2026-09-19 (design §L.1 item 13; the Ruling section of
`evidence/adr-0009-decision-package-20260914.md`), and XPA-AC-7's kill matrix: the runner killed
before and after an intent and before and after the capability consume, failing closed, with
`outcomeUnknown` carried and never replayed. It replays the Swift oracle slice 2e-a recorded
(`recovery-crash-window-oracle-run.md`, #2061) with the Rust runner dying at the same four
windows. Host-local: the shared fake HDC, no device.

Base: protected main `7c10f9f3`, which holds slice 2d-c (#2086, the device-bound reconcile) and
slice 2b (#2071). No stack. Branch
`agent/xpa-014-recovery-crash-window-20260919`. Files: `tests/crash_window.rs` (new),
`tests/support/reconcile.rs` (two additive methods), `rust/README.md` (the recovery paragraph's
last sentences) and this record. No Rust source, Swift, Catalog, spec, schema, control-frame or
fixture change: the oracle's fixture is already on main.

## The four quadrants, and where Rust dies

A child of the test binary rebuilds the root from the window's fixture, admits the oracle's
`input.tap@1` (the recorded answer, exactly) and runs it until the window, where it exits without
unwinding, so nothing past the last durable write happens.

| Window | Intent | Consume | Where the Rust runner dies | Exit |
| --- | --- | --- | --- | --- |
| `beforeConsume` | before | before | the tool identity check that opens `consume_mutation_authority`, once the last evidence step's outcome is durable; nothing durable happens between it and the consume | 81 |
| `afterReadOnlyIntent` | after (read-only) | before | as `read-evidence-model` would launch the tool, its intent durable | 82 |
| `afterConsume` | before | after | the first clock read once the Job record holds its `runtimeCapability` evidence, which is the intent's envelope | 83 |
| `afterIntent` | after | after | as `inject-pointer-input` would launch the injector, its intent durable | 84 |

Swift's oracle took its copy at the matching boundary: its engine's
`beforeMutationCapabilityCommit` and `beforeDispatchInstall` hooks, and its fake while answering
the two calls. The store each pair leaves is the same, so the Rust crash store is compared with
Swift's `crash/` byte for byte, index rows included.

## What the replay proves

For every window, after the Rust runner died there:
- **the store is Swift's** (`crash/`): the same journal, record, index row and capability ledger;
- **two starts** (`recover_active_jobs`) answer Swift's statuses and leave Swift's store
  (`restart/`, `secondRestart/`): the read-only and mutation intents park the Job
  (`waitingForRecovery`, `outcomeUnknown`, the use settled `outcomeUnknown` where one was
  consumed), and a Job with no outstanding intent is carried as `running` with
  `recovered: journal clean`;
- **two `job.reconcile`** answer Swift's answers and leave Swift's store: the read-only intent is
  confirmed not executed from recorded facts, the pointer mutation stays unknown and is never
  resent, and a Job whose outcome is known is answered as it stands;
- **the next tap** is admitted where nothing was consumed, and refused `admissionDenied` with the
  zero-dispatch proof where a use is outstanding ("outcome pending" after the consume,
  "outcome outcomeUnknown" after the intent);
- **every read** (`job.status`, `job.show`, `job.result`, `job.evidence`) and the capability
  reads are Swift's;
- **nothing is dispatched**: the fake's log does not grow from the death to the end. Where Swift's
  fake took the copy while answering a call, its log holds that call and the Rust log does not —
  the Rust runner died before launching the tool. The replay asserts that the Rust log is exactly
  Swift's without that one line, and that the line is the call the window names.

Because the Rust store at the death is Swift's byte for byte, these starts are also the Rust
daemon starting over the store a Swift daemon died with: the other column of XPA-AC-7's matrix,
which r11 builds no sidecar for.

## Mutation checks

- Recovery no longer recording the recovered use's outcome fails at
  `afterIntent`'s `restart/capabilities/runtime-capabilities.ledger`.
- Dying one write earlier in `afterConsume` (at the ledger's consumption, as `pointer_input_run.rs`
  does, before the Job's evidence is persisted) fails at `crash/index.json`.

## For the maintainer

- **One leftover is not Swift's.** The Rust admission of a device mutation checks the Runtime's
  storage state (`MutationAuthority::require_state`) through the Session owner's
  `runtime.storage.status`, which takes the storage owner's lock and the retention catalog's, so
  it leaves `session-owner/.session-storage.lock`, `sessions/.arkdeck-retention-catalog.json` and
  its lock. Swift's admission reads the Session root without them and writes them when it first
  publishes. The bytes are the ones Swift writes then (the replay compares them against the
  window whose failed publication wrote them), so only their timing differs. It predates this
  slice (the mutation authority of #1984) and shows here because these are the first oracles
  where no Session is ever published; the replay removes exactly those three files before
  comparing the tree, and excuses nothing else. Ruled on 2026-09-20 through the coordinating
  session: an incidental side-effect file of r11 §3, kept as a declared difference here and in
  the admission section of `rust/README.md` rather than a slice of its own, and revisited only
  if some oracle's T0 file set stops matching because of it.
- After a death before the mutation intent the Job stays `running` with no executor, as in Swift:
  `job.run` resumes it, and the Rust runner still refuses a resumable Job (the resume lane).

## Local targeted checks

Per `AGENTS.md` the unified gate is the PR's CI. Locally, from `rust/`, with `CARGO_BUILD_JOBS=2`,
in this branch's own worktree and cargo target:

| Command | Exit | Result |
| --- | --- | --- |
| `cargo fmt --all --check` | 0 | clean |
| `cargo clippy --locked -p arkdeck-hoststore -p arkdeck-control -p arkdeck-agentd --all-targets -- -D warnings` | 0 | clean |
| `cargo test --locked -p arkdeck-hoststore` | 0 | 472 passed, 0 failed, 14 ignored: the two of `crash_window.rs` among them, and every other replay of the shared root unchanged |
| `cargo test --locked -p arkdeck-control` | 0 | 23 passed, 0 failed |
| `cargo build --locked -p arkdeck-cli`, then `cargo test --locked -p arkdeck-agentd --bin arkdeck-agentd` | 0 | 42 passed, 0 failed |
| `cargo test --locked -p arkdeck-agentd --test job_recovery_process --test import_publication_process --test app_ingress_startup` | 0 | 3 passed, 0 failed |
| `python3 rust/scripts/check-contracts.py` (PyYAML and jsonschema) | 0 | published and candidate views pass |
| `sh scripts/check-sdd.sh` (repository root) | 0 | 0 errors, 0 warnings |

Log: scratchpad `logs/checks-2eb-push.log`, SHA-256
`00f1c027c15136ec125b19b7726749cf127359d88ce4760e166ef5184715cc77`, run on protected main
`7c10f9f3`. Earlier: over 2d-c's branch on main `3f033e83`, `checks-2eb-final.log` (hoststore 464
passed, 14 ignored), SHA-256
`14924c72d826e52f79353aa15a71711b8dd9740330af58cab47b6334cc5f959d`. An earlier run over both on main `28d2016c` is
`checks-2eb-main.log` (hoststore 451 passed, 13 ignored), SHA-256
`68f6da102cb7045609c7c4e738b981c914ae560327a27d305cccd8b335d8019e`. No Rust source and no contract input changed, so no owner's
behaviour and no schema moved; the runs that matter are the replays of the shared fake HDC's
root, which this binary joins under the same lock.

## CI

The PR's `guard` and `swift` aggregate (Rust lane): recorded in the next slice's record.

## Not in this slice

- The resume lane (`job.run` of a recovered `running` Job and of one waiting at
  `resumeAtConfirmedSafeBoundary`), which the crash windows before the mutation intent leave to
  it.
- The Rust-only window between the ledger's consumption and the Job's evidence, which Swift has
  no seam for: `pointer_input_run.rs` already holds it with fail-closed assertions.
- A crash window under a debug HAP or a native library deployment, and the façade kill matrix.
