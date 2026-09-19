# TASK-XPA-014 — recovery port, slice 2b: Rust restart carry-over and `job.reconcile` for analyzer Jobs

Change: CHG-2026-074-shared-rust-runtime-core@r11. Second half of slice 2 of the recovery port
the maintainer ruled on 2026-09-19 (design §L.1 item 13; the Ruling section of
`evidence/adr-0009-decision-package-20260914.md`): recoverable Job classification on a daemon
start and `job.reconcile`, ported from the carriers the package names and replaying the oracle
slice 2a recorded (`recovery-reconcile-oracle-run.md`). Host-local only: no device, no HDC, no
capability use.

Base: protected main, which holds slice 2a (#2030, the oracle this slice replays) and the
`job.reconcile` answers widened by slice 2d-b (the readback oracle PR; see "The published
answers" below). Branch `agent/xpa-014-recovery-reconcile-20260919`, no stack: it was written on 2a's
branch and rebased onto main, and it is pushed only once 2d-b is on main, because the
`check-contracts.py` published view runs this branch's Rust tests against the merge base's
schemas. No Swift, Catalog, spec, schema or control-frame change.

While rebasing, #2039 (the Artifact retention sweep at the isolated daemon's start) conflicted in
`arkdeck-agentd/src/main.rs`. Swift's daemon recovers its Jobs (`recoverActiveJobs`,
`ArkDeckAgentDaemonMain/main.swift` line 1289) before it collects expired Artifacts (line 1326),
so the Rust daemon now recovers first and sweeps second, and the sweep's comment says so.

## Already on main / delivered here / remaining

| Already on main or in 2a | Delivered here | Remaining in the port |
| --- | --- | --- |
| The runner parks an unobservable analyzer child in `waitingForRecovery` with its intent outstanding (`job_run.rs`); the capability ledger's `resolvesUnknown` (#2034) | `job_recovery.rs`: Swift `recover(records:)` over `RuntimeRecoveryService.replay`, as `recover_jobs` (named Jobs, a terminal one included) and `recover_active_jobs` (the daemon-start pass over `RuntimeJobRepository.activeJobs()`) | Device-bound `job.reconcile` (fresh facts, the dedicated readback dispatch), replaying 2d-a's and 2d-b's oracles (#2040 and the readback PR) |
| Journal replay facts and the append rules (`job_journal_replay.rs`, `job_journal_writer.rs`) | `job_reconcile.rs`: the `job.reconcile` handler case, `reconcile`/`reconcileOwned`, `finishReconcile` and `AnalyzerProvider.reconcile` for `analyzer.extract-crash-signature@1` | HAP reconcile branches (failure finalization, compensation identity proof), the submit-time lineage repair, cancelled-lineage repair |
| Slice 1 (the recovery-manifest codec), slice 2a (this oracle), slice 3 (the superseding epoch store, #2025), slice 4 (the §G.4 predicate table, #2026, #2028) | The router's `job.reconcile` hook, the recovery pass at the isolated daemon's start, the resident record a failed reconcile leaves | `job.run` resumption of a recovered Job; the crash-window matrix over the Rust runner |

## Ported exactly

Recovery (`recover_jobs` / `recover_active_jobs`):
- the active set: every index row not in a terminal state (unknown states active), in creation
  then identity order;
- quarantine of a record this build cannot read: reported, never written, still active;
- `restoreInitialAdmissionProjectionIfNeeded`: the wholly absent projection (no journal, or an
  empty one, or one holding only `jobCreated` and `queued -> preflight`) restored from the
  admission's own record; any other partial projection stops the recovery;
- `replay`: the torn tail cut on open; a reconcile decision left without its transition
  completed (`recovery-t-<n>`, `complete durable reconcile decision after restart`); the park
  rule (`mustParkWithoutRedispatch`: torn tail, outstanding intent, unknown outcome, an
  `outcomeUnknown` reconcile certainty, or a debug HAP's pending identity proof) with its
  durable park transition from any state that allows it; a clean cancellation completed; an
  interrupted finalization failed; a debug HAP's declared failure compensation left waiting
  (`originalFailure`, whether `derive` finds a declaration, `actualStepKinds` from the
  journal's intents); the `recovered: …` markers, never twice in a row;
- every recovered record persisted (record file, then index state, `updatedAt`, version + 1);
- `recordCapabilityOutcome` for a runtime-capability Job: `(outcomeUnknown,
  waitingForRecovery)` or `(confirmed, state)` through `CapabilityStore::record_outcome`;
- no Session publication, no dispatch.

`job.reconcile` for analyzer Jobs: the handler's `invalidParams`/`notFound`/`rejected`/
`internalError` mapping, no details on any answer; a terminal Job's status, or its Session
started again after the writer's confirmed refusal of an unbound source; a clean cancellation
whose executor is gone settled; a Job whose outcome is known answered as it is; a durable
reconcile decision completed; the confirmed resume and finalization continuations; the legacy
unknown-outcome refusal; the recovery-boundary checks; `waitingForRecovery -> reconciling`;
the unfinished attempt continued or `reconcileStarted` with `recovery-<job>-<sequence>`; the
source lease resolved again and checked against the materialized request; the persisted
`analyzer.analyze` action materialized as its closed recovery identity; a confirmed outcome the
journal already holds reused; `AnalyzerProvider.reconcile`; `finishReconcile`'s three outcomes
(`confirmedNotExecuted` journaled on the step outcome, the failure
`executionConfirmedNotPerformed`, finalization to `failed`, Session publication; or
`waitingForRecovery`); a reconcile that fails after its journal moved keeps what it journaled
resident (`JobStore` reads it first until the Job is persisted again), as Swift's engine does.

## Refused, fail-closed

- Recovery: an ArkForge Flash execution (`flash.full-restore@1`, `flash.dayu200@1`, or an
  `arkforge-runtime-state.json` beside the record) and a complete-overwrite recovery Job are
  reported in `refused` and left untouched. A runtime-capability Job recovered without a
  capability store fails the whole call, naming it, before anything is written.
- `job.reconcile` of any other operation: its status where Swift writes nothing (a non-terminal
  Job whose outcome is known and that is not a stuck cancellation or a finalizing HAP; a
  terminal Job with no capability lineage to repair and no unbound Session refusal); otherwise
  `rejected` with nothing written or dispatched.
- In the daemon, a reconcile of a Job a run of this owner holds answers its status and writes
  nothing; concurrent reconciles of one Job join.

## Tests

- `tests/job_reconcile.rs` replays `rust/tests/fixtures/job-reconcile-analyzer/`: the sources
  rebuilt (the removed payload from its mode), the four admissions and three runs (`runs.json`),
  the store before the restart (`before/`), two recoveries (`starts.json`, `restart/`,
  `secondRestart/`), the eight reconcile answers (`cases.json`) and their snapshots
  (`steps/<name>/`), every read (`reads.json`, the failed reconcile's Job read from its resident
  record) and the final store, Artifacts, Sessions, storage owner and tree, byte for byte.
- `tests/job_recovery.rs` (5 tests): a start parks an outstanding intent (`recovery-t-4`) and a
  second start adds nothing; a reconcile without the exact typed action is refused unwritten; a
  clean cancellation and an interrupted finalization are completed; a terminal Job named
  explicitly gains only `recovered: journal clean`; a reconcile decision's missing transition is
  completed; a wholly absent admission projection is restored and a partial one refused
  unchanged; an unreadable record is quarantined untouched; a capability Job without a store
  fails naming it.
- Unit tests in `job_recovery.rs` (3) and `job_reconcile.rs` (4): the HAP original failure and
  declaration, the marker rule, the analyzer's identity match, action materialization, the
  unbound-source marker and the unfinished attempt.
- `arkdeck-agentd` `tests/job_recovery_process.rs`: the isolated daemon started over a parked Job
  recovers it before serving (the marker), `job.reconcile` fails it as confirmed not executed,
  its analyzer never starts again, and a later start reopens nothing.

## Local targeted checks

Per `AGENTS.md` the unified gate is the PR's CI. Locally, from `rust/`, with `CARGO_BUILD_JOBS=2`,
in a worktree and cargo target of this branch's own, on top of slice 2d-b's widened
`job.reconcile` schema:

| Command | Exit | Result |
| --- | --- | --- |
| `cargo fmt --all --check` | 0 | clean |
| `cargo clippy --locked -p arkdeck-hoststore -p arkdeck-control -p arkdeck-agentd --all-targets -- -D warnings` | 0 | clean |
| `cargo test --locked -p arkdeck-hoststore` | 0 | 440 passed, 0 failed, 13 ignored |
| `cargo test --locked -p arkdeck-control` | 0 | 23 passed, 0 failed |
| `cargo build --locked -p arkdeck-cli`, then `cargo test --locked -p arkdeck-agentd --bin arkdeck-agentd` | 0 | 37 passed, 0 failed |
| `cargo test --locked -p arkdeck-agentd --test job_recovery_process --test import_publication_process --test app_ingress_startup` | 0 | 3 passed, 0 failed: the new daemon test (its `job.reconcile` answer is now the Job's status, equal to `job.status`), and the two other process tests that start the isolated daemon over a Job store or at all |
| `python3 rust/scripts/check-contracts.py` (the lane's own gate; PyYAML and jsonschema) | 0 | published and candidate views pass, `check-session-cleanup.py` among them |
| `sh scripts/check-sdd.sh` (repository root) | 0 | 0 errors, 0 warnings |

Log: scratchpad `logs/checks-2b-main.log`, SHA-256
`a196dfe8caf5d0899adfa1926aef2abccd73752296a66359d78daadd4429019b`, run on protected main
`28d2016c` (#2050 merged). In it the run of `arkdeck-hoststore` was made beside two other cargo
runs and `rust_runs_every_swift_debug_hap_as_swift_does` differed once; that oracle is the debug
HAP run, which this branch does not touch, and it passes alone, twice: `--test debug_hap_run`
7 passed, and the whole crate again on its own, 440 passed, 13 ignored, in
`logs/checks-2b-hoststore-retry.log`, SHA-256
`1fd4f51074b85a56cfe184098a807be2edb1ede7f4c31cd7cb9e9a6c5ec27db1`, whose counts the table
above gives. Earlier runs: on 2d-b's rebased head `f7ee84a3` over main `655c8199` (#2063),
`checks-2b-new.log` (hoststore 440 passed, 13 ignored), SHA-256
`cabcb9528513cc91488d0cd0b215de2f29a0804c24e8358866b9840d41ff2ab5`; on main `6592bcce` with 2d-b's head applied, `checks-2b-trial.log` (hoststore 423 passed,
13 ignored; control 22; the daemon binary 35), SHA-256
`e4e594ac50d9f9b17f1772055b3b9302f78cde4b57aa32645e4669234041447f`; on 2d-b's head `c96d024e` (main `e5daa945`),
`checks-2b-final.log` (hoststore 421 passed, 12 ignored), SHA-256
`8d68527bbed410775ba6bf92c45d3d7f95b8a9bc730a58acffc26c14969dacb8`; on main `b6bf1536` with 2d-b's
first head, `checks-2b-restacked.log` (hoststore 406 passed, the daemon binary 33), SHA-256
`87b1c36df766ae36cb68c15719c6c24742b39663a1121359245585f92c77a8a1`; on slice 2a's branch before
the schema was widened (hoststore 391 passed, with the daemon test then pinning the
`internalError` rewrite), `checks-2b.log`, SHA-256
`a44685ad6e60f6a9847359a2da81ad3745dbe2305e36ce58d025ebdb73d3b87b`. The other agentd process
tests (`control_action_*`, `managed_hdc_process`) admit no Job and were not run.

Mutation checks while writing the replay: a changed `recovered: journal clean` marker fails it at
`restart/index.json`, and a reconcile that does not keep its resident record fails it at the
source-removed Job's `job.result` read.

No contract input changed, so `generate-contract.py --check` was not required.

## CI

The PR's `guard` and `swift` aggregate (Rust lane): recorded after the run completes.

## For the maintainer

- **The session-cleanup fixture had to change, because a daemon now recovers when it starts.**
  `rust/scripts/check-session-cleanup.py` seeds Job rows directly in SQLite with no durable
  projection. A row that claims a non-terminal state other than `preflight` with no record and no
  journal is a store neither owner accepts: Swift's
  `restoreInitialAdmissionProjectionIfNeeded` completes that pair only from an admission's own
  record, and refuses anything else, which now stops the daemon from starting (the PR's first
  `macos-26` lane). The fixture seeds its active Job `preflight` instead, the one non-terminal
  state a Job holds before its record and journal exist, and removes the projection the start
  completes for the Job it later returns to a terminal state, so it keeps saying that nothing
  durable of that Job remains. What it tests is unchanged: which Sessions hold an active lease.
- **A restored projection retains its Session, by the census's own rule.** `with_active_sessions`
  keeps a Session whose indexed Job has a directory, terminal or not ("until journal
  reconciliation is migrated", `job_owner.rs`). Now that a start completes an admitted Job's lost
  projection, such a Job gains a directory and its Session is retained by that rule rather than by
  its state. Whether that rule should now narrow is TASK-XPA-013's to say; nothing here changes
  it.
- **`job.reconcile`'s published answers.** The result schema used to pin
  `sessionPublication.catalogGeneration` and `manifestSha256` to null, `reasonCode` to a string and
  `startedAtUtc` to a string, so four of the oracle's five successful answers were rewritten to
  `internalError` by the Rust control layer. Slice 2d-b recorded the three reconcile oracles'
  frames and widened the schema, with the old schema's every document still admitted. Through the
  daemon, `tests/job_recovery_process.rs` now expects the reconcile's own answer: its status,
  equal to `job.status`.
- A Job a start completes to `cancelled` or `failed` stays resident in Swift, so a later
  `job.reconcile` in the same process publishes its Session; the Rust owner keeps no resident
  set for it and answers its status unpublished.
- `job.run`'s refusal of a recovered `running`, `resumeAtConfirmedSafeBoundary` or other
  resumable Job still says "the Rust Runtime resumes no Job before recovery is ported";
  `job_run.rs` was left untouched here (other slices edit it) apart from making
  `binding_refusal` `pub(crate)` for the reconcile's source check.
- `doctor` still emits neither `runtime.jobRecordUnreadable` nor
  `runtime.durableRecordsUnreadable`; the daemon names quarantined Jobs on its standard error at
  its start.
- As 2a noted, what a start makes of a Job journaled `reconciling` by a failed reconcile is not
  recorded by any oracle; the Rust recovery does what the Swift code does (it stays
  `reconciling`, parked, its marker not repeated).

## Dependencies of the M2/M4 follow-ups

The ruling task defers three recovery carriers to M2/M4 and asks that their dependencies be listed
here first. None is built in this slice.

| Follow-up | Swift carrier | Depends on | Where it stands |
| --- | --- | --- | --- |
| The recovered row of `cleanupDebt.continue` | `RuntimeJobEngine.continueCleanupDebt`: for a Job its engine does not hold (every terminal Job), `recover(records: [persistedJob])` appends `recovered: journal clean`, persists the record and index row, and settles a runtime-capability use `confirmed`; a Job whose outcome is unknown is answered `outcomeUnknown` with nothing written or resent | this slice's `recover_jobs` (a named terminal Job, no Session publication, a capability store required for a runtime-capability Job); the `cleanupDebt.list` reader; the continuation's own facts, dispatch and residue refresh (`debug.hap@1` slice F, `deploy.native-library.app-owned@1`) | taken by the native-library session (branch `agent/xpa-014-cleanup-debt-20260919`): `cleanupDebt.list` first, then `continue` over `recover_jobs` once this slice is on main |
| `debug.start`, `debug.status`, `debug.evaluate` (the Flash recovery broker, `RuntimeDebugInvocationController`; CLI `recovery flash-invocation`) | only `flash.full-restore@1` or `flash.dayu200` seeds; `evaluate` with execute creates one Job per destructive epoch | the M4 flash plan in Rust (`flash.dayu200` materialized); the ArkForge lane (SPK-9, not yet a go); DEC-016's complete-overwrite admission (next row); the epoch store (#2025); device-bound reconcile with the Rockchip dedicated readbacks (`enterLoader`, `rebootToNormal`) | M4 |
| DEC-016's complete-overwrite recovery epoch | `RuntimeRecoveryService.completeOverwriteAdmission` (the unresolved destructive-intent scan, the shared four-hour budget, the campaign window, ordinal ≤ 16, a `historicalRecognition` epoch) and the finalize branch's `establishSupersedingRecoveryEpoch` (`distinctRecoveryExecution`, `finalizing → recovered`) | the epoch store (#2025); the capability lineage gate skipping a superseded Job, `isCurrentJob`, and the Job projections' epoch fields (their schemas pin `recoveryEpochId`, `supersededByRecoveryEpochId` and `recoveryEpoch` to null, so Swift-recorded frames come first); the DEC-014 campaign window (`runtime service update --arkforge-campaign`); the flash postflight observation (#1936); the ArkForge lane | M4 |

## Not in this slice

- Device-bound reconcile, dedicated readbacks, the submit-time lineage repair and the HAP
  reconcile branches; resumption of recovered Jobs by `job.run`.
- A Rust CLI `job reconcile` leaf (none routes to the method today).
- The crash-window matrix (Rust and Swift, before and after the intent, before and after the
  consume); it needs this slice's recovery and checkpoints in the Rust runner.
