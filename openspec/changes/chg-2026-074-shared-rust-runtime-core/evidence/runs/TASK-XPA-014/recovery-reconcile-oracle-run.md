# TASK-XPA-014 — recovery port, slice 2a: the restart and `job.reconcile` Swift oracle (analyzer Jobs)

Change: CHG-2026-074-shared-rust-runtime-core@r11. Slice 2 of the recovery port the maintainer
ruled on 2026-09-19 (design §L.1 item 13; the Ruling section of
`evidence/adr-0009-decision-package-20260914.md`): recoverable Job classification on a daemon
start and `job.reconcile`. This first sub-slice records, from Swift, the oracle the Rust startup
recovery and reconcile slice replays, for the host-only analyzer Jobs, so that the Rust slice
changes no Swift file (r11 rule 10). Host-local only: no device, no HDC, no capability.

Base: protected main `5b70cebd` (#2014). Branch `agent/xpa-014-recovery-reconcile-oracle-20260919`,
no stack. Files:
- `Packages/ArkDeckKit/Tests/ArkDeckContractTests/JobRunAnalyzerOracleContractTests.swift`: the
  writer composition can reopen a root (a daemon starting again over its state) and exposes its
  engine; a new recording, `testSwiftRecoversAndReconcilesTheParkedAnalyzerJobs`;
- `rust/tests/fixtures/job-reconcile-analyzer/` (new);
- this record.

No Rust, production Swift, Catalog, spec, schema or control-frame change. The four existing
recordings of the class reproduce their checked-in oracles unchanged.

## Carriers exercised

From the package's §1a, §1b and §1c: `recoverActiveJobs` / `recover(records:)`,
`RuntimeRecoveryService.replay(_:)`, `RuntimeJobRepository.activeJobs()`, the `job.reconcile`
handler case, `reconcile(jobID:)` / `reconcileOwned(jobID:)`, `finishReconcile` and the analyzer
provider's `reconcile` (`AnalyzerProvider.swift`, confirmed not executed only when the resolved
source is the one the intent named). Decision 4's `confirmedNotExecuted` semantic code is
journaled on the reconciled step outcome.

## The oracle

In the writer composition the run, publication and cancellation oracles use (the daemon's engine
with its Session publication writer, the analyzer pinned, fixed clocks, the fixed root under its
lock):
1. Four Jobs are admitted: `parked` and `parkedSourceRemoved` run into a signal death and park in
   `waitingForRecovery` with their intent outstanding; `succeeded` runs to success; `admitted` is
   only admitted. The second parked Job's source payload is then removed. The store is recorded
   (`before/`).
2. The daemon starts twice over the same root (`recoverActiveJobs`, then again); what each start
   returns (`starts.json`) and the store after each (`restart/`, `secondRestart/`) are recorded.
3. `job.reconcile` is sent eight times; each answer (`cases.json`) and the store after each
   (`steps/<name>/`) are recorded. Then every Job's `job.status/show/result/evidence`
   (`reads.json`), the final store, Artifacts, Sessions, storage owner and tree.

| Step | Swift's answer |
| --- | --- |
| restart, second restart | the admitted Job stays `preflight` (journal clean); both parked Jobs stay `waitingForRecovery`, `outcomeUnknown`, their intents outstanding; no dispatch, no journal write; the record gains the marker "recovered: outstanding intents or unknown outcomes; no redispatch" once |
| `reconcileParked` | ok, `failed`: the analyzer reconciles the intent as confirmed not executed; journal `reconcileStarted`, a `stepOutcome` failed with semantic code `confirmedNotExecuted`, a `reconcileOutcome` to `finalizing`, the transitions to `failed`, the Session finalized and published; failure `executionConfirmedNotPerformed` |
| `reconcileParkedAgain` | ok, the same terminal status; nothing written |
| `reconcileSourceRemoved` | `internalError` (`indexCorrupted`: the source payload is missing): the lease cannot be resolved after the journal already moved to `reconciling` and recorded `reconcileStarted`; the record file still says `waitingForRecovery` |
| `reconcileSucceeded` | ok, `succeeded`; nothing written |
| `reconcileAdmitted` | ok, `preflight`; nothing written |
| `reconcileAbsent` | `notFound` |
| `reconcileWithoutJob`, `reconcileNumericJob` | `invalidParams` |

No reconcile answer carries `details`: `job.reconcile` never states the zero-dispatch proof
(`details.phase`, `newDispatchCount`); only the plan, submit and run lifecycle does. An analyzer
reconcile dispatches nothing.

## For the maintainer

- **Journal and record apart after a failed reconcile** (`reconcileSourceRemoved`): Swift journals
  `waitingForRecovery → reconciling` and `reconcileStarted` before it resolves the source, and a
  failure there leaves the record at `waitingForRecovery`. This oracle does not restart the
  daemon after that step, so what a later start makes of a Job journaled as `reconciling` (a
  blocking state in the shared preflight table) is not recorded here; a later recording covers it.
  The oracle pins the step as Swift does it; the Rust port reproduces it.
- A missing source payload surfaces as the Artifact store's `indexCorrupted` and so as
  `internalError`, not as the provider's `stillUnknown` ("source identity does not match"), which
  needs a resolved but different source.

## Determinism

Fixed clocks, the fixed root under its lock, and each Job record's machine facts as labels, as
the class's other recordings. Two recordings are compared in "Local targeted checks".

## Local targeted checks

Per `AGENTS.md` on main `d732e798` (#2015) the unified gate is the PR's CI; locally, recording
and comparing through `sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --filter …`:

| Run | Exit | Result |
| --- | --- | --- |
| recording r1 (`ARKDECK_RUST_JOB_RECONCILE_RECORD=/private/tmp/arkdeck-job-reconcile-r1`) | 0 | 1 test, 0 failures |
| recording r2 (`…-r2`), `diff -r` against r1 | 0 | identical byte for byte |
| `--filter JobRunAnalyzerOracleContractTests`, fixture installed | 0 | 5 tests, 0 failures: the run, publication, cancellation and running-cancellation oracles reproduce their checked-in files with the reopenable composition, and this one compares every file |
| `sh scripts/check-sdd.sh` | 0 | 0 errors, 0 warnings |

## CI

The PR's `guard` and `swift` aggregate: recorded after the run completes.

## Not in this slice

- The Rust startup recovery and `job.reconcile` for these Jobs (the next sub-slice).
- Device-bound reconcile (fresh facts, the HDC provider's tables, the dedicated readback
  dispatch), the capability ledger's `resolvesUnknown`, the submit-time lineage repair and the
  HAP branches: later sub-slices with their own recordings.
