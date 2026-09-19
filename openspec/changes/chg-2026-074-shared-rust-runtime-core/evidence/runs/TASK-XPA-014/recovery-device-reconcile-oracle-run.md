# TASK-XPA-014 — recovery port, slice 2d-a: the restart and `job.reconcile` Swift oracle (device Jobs)

Change: CHG-2026-074-shared-rust-runtime-core@r11. Part of slice 2 of the recovery port the
maintainer ruled on 2026-09-19 (design §L.1 item 13; the Ruling section of
`evidence/adr-0009-decision-package-20260914.md`). Slice 2a recorded restart carry-over and
`job.reconcile` for host-only analyzer Jobs (#2030). This records the same for Jobs bound to a
device, so that the Rust device-bound reconcile changes no Swift file (r11 rule 10). There are
two Jobs: a read-only one settled from the device's recorded facts, and a mutation with no
dedicated readback. Host-local: the shared fake HDC, no device.

Base: protected main `2af5c806` (#2034). Branch
`agent/xpa-014-recovery-device-reconcile-oracle-20260919`, no stack. Files:
- `Packages/ArkDeckKit/Tests/ArkDeckContractTests/HDCOracleHarness.swift`: `Composition` exposes
  the engine behind its handler (one additive field), for `recoverActiveJobs`;
- `Packages/ArkDeckKit/Tests/ArkDeckContractTests/DeviceReconcileOracleContractTests.swift` (new);
- `rust/tests/fixtures/device-reconcile/` (new);
- this record.

No Rust, production Swift, Catalog, spec, schema or control-frame change.

## The oracle

Over the shared fake HDC, with one adopted device, in `HDCOracleHarness`'s composition of the
standalone daemon's engine:
1. Three Jobs run:
   - `observed`: `observe.device@1`, succeeds;
   - `observeParked`: `observe.device@1` whose version probe answers nothing, parked in
     `waitingForRecovery` with its read-only intent outstanding;
   - `tapParked`: `input.tap@1` the injector acknowledges as another gesture, parked with its
     mutation intent outstanding and its capability use `outcomeUnknown`.

   The store (index, Job files, capability store) is recorded in `before/`.
2. The daemon starts twice over the same root: a reopened composition, then `recoverActiveJobs`.
   Each start's answer is recorded in `cases.json` `starts`, and the store after each in
   `restart/` and `secondRestart/`.
3. `job.reconcile` is sent five times. Each answer is recorded, and the store after each in
   `steps/<name>/`.
4. A new tap is submitted under the same capability. Then every Job's status, show, result and
   evidence are read, the capabilities are listed and inspected, and the harness's files are
   recorded: the fake and every call it received, the Target document, the store, Artifacts,
   Sessions and owner, and `tree.json`.

| Step | Swift's answer |
| --- | --- |
| two starts | both parked Jobs stay `waitingForRecovery`, `outcomeUnknown`, their intents outstanding; the succeeded Job is not active and is not touched |
| `reconcileObserveParked` | ok, `failed`, `executionConfirmedNotPerformed`: the read-only intent is settled confirmed not executed from the device's recorded facts (no device call) |
| `reconcileObserveParkedAgain` | ok, the same terminal status; nothing written |
| `reconcileTapParked` | ok, `waitingForRecovery`, `outcomeUnknown`: the journal gains `waitingForRecovery → reconciling`, `reconcileStarted`, a `reconcileOutcome` with evidence "mutation has no dedicated readback; original not resent" and `outcomeUnknown`, and the transition back; the capability ledger is unchanged |
| `reconcileTapParkedAgain` | the same, with four more journal events under a new attempt |
| `reconcileObserved` | ok, `succeeded`; nothing written |
| `tapAfterReconcile.submit` | `admissionDenied` with the zero-dispatch proof (`details.phase`, `newDispatchCount`): "target binding has unresolved capability … use 1 outcome outcomeUnknown" |

The fake's call log does not grow from the end of the runs to the end of the reconciles: the test
asserts it. Recovery never dispatches. A read-only reconcile uses the device's recorded facts,
and a pointer gesture has no dedicated readback, so nothing is resent.

## What this adds to slice 2's evidence

- **The `outcomeUnknown` lane is carried and never replayed**, for a mutation under a
  capability: two daemon starts and two reconciles leave the tap parked, its use unknown, and the
  lineage blocking the next mutation. The refusal carries the named admission owner's
  zero-dispatch proof. `job.reconcile`'s answers carry none, as in 2a.
- **A device-bound reconcile** resolves the device's facts first (`resolveFacts`,
  `validateEvidenceFacts`), then the provider's decision table: read-only families are confirmed
  not executed, and a mutation with no dedicated readback stays unknown.

## Determinism

The same as the class's HDC oracles: a fixed root under the fake's lock, the fixed clock, each
Job record's machine facts as labels. The harness's `provenance.json` lists the digests of the
files it records. The `before/`, `restart/`, `secondRestart/` and `steps/` snapshots are
compared file by file like every other file of the oracle.

## Local targeted checks

Per `AGENTS.md` on main `d732e798` (#2015) the unified gate is the PR's CI; locally, through
`sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --filter …`:

| Run | Exit | Result |
| --- | --- | --- |
| recording r1 (`ARKDECK_RUST_DEVICE_RECONCILE_RECORD=/private/tmp/arkdeck-device-reconcile-r1`) | 0 | 1 test, 0 failures |
| recording r2 (`…-r2`), `diff -r` against r1 | 0 | 1 test, 0 failures; identical byte for byte |
| `--filter 'ArkDeckContractTests\..*OracleContractTests'`, this fixture installed | 0 | 26 tests, 0 failures: every oracle class that composes `HDCOracleHarness` reproduces its checked-in files with the added field, and this one compares every file |
| `sh scripts/check-sdd.sh` | 0 | 0 errors, 0 warnings |

## CI

| PR | Head | Runs | Result |
| --- | --- | --- | --- |
| #2040 | `727c011b` | 35447196728, 35447196790, 35447196898 | 11 checks passed, `app-build` skipped; merged as `531058e8` |

## Not in this slice

- The Rust device-bound reconcile replaying this oracle: it needs slice 2b (the Rust startup
  recovery and `job.reconcile` for analyzer Jobs) first.
- Dedicated readback dispatch (a parked mutation that has a readback, such as a port rule or an
  installed package) and the `debug.hap@1` branches: later recordings.
