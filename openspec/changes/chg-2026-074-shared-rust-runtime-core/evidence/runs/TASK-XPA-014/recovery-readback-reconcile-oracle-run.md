# TASK-XPA-014 — recovery port, slice 2d-b: the dedicated-readback `job.reconcile` Swift oracle, and `job.reconcile`'s published answers

Change: CHG-2026-074-shared-rust-runtime-core@r11. Part of slice 2 of the recovery port the
maintainer ruled on 2026-09-19 (design §L.1 item 13; the Ruling section of
`evidence/adr-0009-decision-package-20260914.md`). Slice 2d-a recorded device reconcile without
a dispatch: a read-only intent confirmed from facts, and a mutation with no readback left
unknown. This records the other branch of `job.reconcile`: a parked mutation reconciled by its
dedicated readback, which dispatches one read-only call. It is recorded from Swift, so that the
Rust slice replaying it changes no Swift file (r11 rule 10). Host-local: the shared fake HDC, no
device.

Base: protected main `655c8199` (#2063), which holds 2d-a (#2040) and the harness's `engine`
field this oracle uses. First pushed on `b6bf1536`; rebased after #2037 and again after #2052,
each of which also regenerated the checkout manifest: main's manifest taken each time, then
regenerated, never text-merged. Branch `agent/xpa-014-recovery-readback-oracle-20260919`, no stack. Files:
- `Packages/ArkDeckKit/Tests/ArkDeckContractTests/ReadbackReconcileOracleContractTests.swift` (new);
- `rust/tests/fixtures/readback-reconcile/` (new);
- `job.reconcile`'s control frames and published schema: six lines appended to
  `Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ControlFrames/job.reconcile.jsonl`,
  `spec/control/methods/job.reconcile.json` re-derived, `spec/baselines/swift-single-v1.json`
  regenerated;
- this record.

No Rust source, production Swift, Catalog or other method schema change.

## Carriers exercised

From the package's §1c and §2:
- `reconcileOwned`'s dedicated readback: `provider.reconciliationReadback`, which must lower to a
  plan no stronger than read-only;
- one `dispatcher.dispatch` under a reconcile step id, then `verifyReconciliationReadback`;
- `finishReconcile`'s `confirmedNotExecuted` and `confirmedCompleted` branches;
- `RuntimeCapabilityStore.recordOutcome`'s `resolvesUnknown`, to `safeToReflash`;
- the two lineage repairs of a lost outcome: `repairTerminalSafeToReflashLineageIfNeeded` on
  reconcile and `repairProvablyTerminalCapabilityOutcomeGaps` on the next submission (package §1c
  and §2).

For `port-forward.create@1` the readback is `fport ls` (`DeviceProviderAdapters.swift`
`reconciliationReadback`, `createPortForward`/`removePortForward`).

## The oracle

Over the shared fake HDC, with one adopted device, in `HDCOracleHarness`'s composition, the fake
keeps its rule table in marker files, as the port-forward oracle's fake does. `fport tcp:` dies
on SIGKILL before writing its rule in mode `createKilledBefore`, and after writing it in mode
`createKilledAfter`. After every step the oracle records `steps/<step>/`: the Job index and
files, the capability store, and the fake's call log so far.

| Step | Swift's answer | Calls to the fake |
| --- | --- | --- |
| `killedBefore` submit, run | admitted; the run parks: `waitingForRecovery`, `outcomeUnknown`, the create intent outstanding, its use `outcomeUnknown` | 4 |
| `restart`, `secondRestart` | the parked Job is carried as it is | none |
| `reconcileKilledBefore` | `failed`, `executionConfirmedNotPerformed`: the readback lists no such rule; the use becomes `[outcomeUnknown, safeToReflash]` | 1 (`fport ls`) |
| `reconcileKilledBeforeAgain` | the same terminal status; nothing written | none |
| `killedBeforeOutcomeLost` | not a request: the capability store's checkpoint and ledger are put back as they stood when the Job parked (the crash window between the terminal record and the outcome append, recreated as Swift's contract test recreates it) | none |
| `reconcileKilledBeforeRepairs` | `failed`: the lineage repair (`repairTerminalSafeToReflashLineageIfNeeded`) reads the journal's `confirmedNotExecuted` proof and appends `safeToReflash` again, with no readback and no mutation | none |
| `killedBeforeOutcomeLostAgain` | the same window, recreated again | none |
| `killedAfter` submit, run | the submission first repairs the lost outcome (`repairProvablyTerminalCapabilityOutcomeGaps`, before materialization), then admits under a new capability; the run parks the same way, the rule written | 4 |
| `thirdRestart` | carried | none |
| `reconcileKilledAfter` | `resumeAtConfirmedSafeBoundary`: the readback lists the rule, so the create is confirmed completed; the use stays `outcomeUnknown` (Swift records no capability outcome on this branch) | 1 (`fport ls`) |
| `reconcileKilledAfterAgain` | the same status; nothing written | none |
| `thirdCreate` submit | `admissionDenied` with the zero-dispatch proof: the lineage holds the unknown use | none |

Then every Job's status, show, result and evidence are read, the capabilities are listed and
inspected, and the harness's files are recorded.

## For the maintainer

- A confirmed-completed mutation leaves its capability use `outcomeUnknown` until the Job
  resumes (`resumeAtConfirmedSafeBoundary`), and the lineage blocks every new mutation until
  then. The Rust runner does not resume a Job yet, so a Rust daemon would hold that lineage
  blocked until the resume lane is ported. This is Swift's behaviour, recorded as it is.
- After a `safeToReflash` resolution, the next admission is issued under a new automatic
  capability rather than the same one; the oracle records the capability store as Swift leaves
  it.

## Determinism

The same as 2d-a: a fixed root under the fake's lock, the fixed clock, each Job record's machine
facts as labels, the rule table in fixed marker files.

## Local targeted checks

Per `AGENTS.md` on main `d732e798` (#2015) the unified gate is the PR's CI; locally, through
`sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --filter …`:

| Run | Exit | Result |
| --- | --- | --- |
| recording r1 (`ARKDECK_RUST_READBACK_RECONCILE_RECORD=/private/tmp/arkdeck-readback-reconcile-r1`) | 0 | 1 test, 0 failures |
| recording r2 (`…-r2`), `diff -r` against r1 | 0 | 1 test, 0 failures; identical byte for byte |
| the three reconcile oracles in compare mode with `ARKDECK_CONTROL_FRAME_LOG` (see below) | 0 | 3 tests, 0 failures; 78 frames recorded |
| `ARKDECK_CONTROL_FRAME_LOG=<a directory seeded with the 77 kept frames> … --filter 'ControlMethodSchemaContractTests\|ReadbackReconcileOracleContractTests\|DeviceReconcileOracleContractTests\|JobRunAnalyzerOracleContractTests'` | 0 | 12 tests, 0 failures: the five schema tests (every committed corpus line validates; the seeded frames validate) and every oracle of the three classes in compare mode |
| `python3 Packages/ArkDeckKit/Scripts/generate-control-contract.py --check` | 0 | clean |
| `python3 rust/scripts/generate-contract.py --write`, then `--check` | 0 | 105 methods, 901 recorded shapes (after the rebase onto `655c8199`, whose manifest has 895) |
| `cargo test --locked -p arkdeck-contract -p arkdeck-control` (`CARGO_BUILD_JOBS=2`) | 0 | 71 passed, 0 failed (`corpus_parity` among them); 72 after the rebase onto `655c8199` |
| `cargo fmt --all --check` | 0 | clean |
| `sh scripts/check-sdd.sh` | 0 | 0 errors, 0 warnings |

## `job.reconcile`'s published answers

Slice 2b (the Rust `job.reconcile`, next) found that the published result schema refuses Swift's
own answers. `spec/control/methods/job.reconcile.json` was derived from three frames that never
held a published Session or an unstarted Job, so it pins `sessionPublication.catalogGeneration`
and `manifestSha256` to null, `sessionPublication.reasonCode` to a string and `startedAtUtc` to a
string. Swift answers `job.reconcile` with `RuntimeJobReadProjection.status`, the same projection
as `job.status`, and the Rust control layer rewrites an answer outside its method's schema to
`internalError`. So through a Rust daemon, a reconcile that failed a Job and published its Session
would be carried out and then reported as an internal error.

**Recorded.** The three reconcile oracles, 2a's analyzer oracle, 2d-a's device oracle and this
one, ran in compare mode with `ARKDECK_CONTROL_FRAME_LOG`. They recorded 78 frames: `job.submit`
11, `job.run` 8, `job.reconcile` 18, `job.status`, `job.show`, `job.result` and `job.evidence` 9
each, `capability.list` 2 and `capability.inspect` 3. The file is
`control-frames-15703.jsonl`, SHA-256
`7e2f11eb606fbfa87b653bbe14cafb91c9b2226ed2227dca0a12dfbac90e5eae`. Against the published schemas
(jsonschema 4.26), every frame of every other method is admitted; nine `job.reconcile` frames
are refused. Only `job.reconcile` is re-derived.

**Corpus.** The three committed lines are kept verbatim and in order. Appended: one recorded frame
(the smallest, in recording order) per answer the corpus did not show, using #2012's `append.py`:
answers `waitingForRecovery`, `succeeded`, `failed` (a published Session), `preflight` (an
unstarted Job), and the refusals `internalError` (a removed source) and `notFound`. That is six
lines, 3 → 9. Left out: 2a's `reconcileNumericJob` (`jobId` an integer, `invalidParams`). The
committed line already shows `invalidParams`, and the frame would widen the request schema to
admit an integer `jobId`, which the corpora of `job.cancel`, `job.run` and `job.status` do not
admit either. The Rust control layer validates answers, not requests, so the omission changes no
answer.

**Schema.** It is re-derived in an isolated copy of the generator's inputs (#2012's `derive.py`):
- A derivation from the three committed lines alone reproduces main's `$defs` exactly, so no
  code or shape can be lost.
- The committed schema is the derivation from the final nine-line corpus. A derivation from the
  corpus plus all 77 kept frames gives the same `$defs`.
- #2012's `covers.py` against main's schema finds no narrowing. The widening is exactly:
  `sessionPublication.catalogGeneration` and `manifestSha256` may be strings,
  `sessionPublication.reasonCode` may be null, and `startedAtUtc` may be null. The request schema
  and the error codes are unchanged.
- Validation with jsonschema 4.26: the new schema admits all 17 kept `job.reconcile` frames and
  all nine corpus lines; main's refuses three of the nine (the new shapes).

`python3 rust/scripts/generate-contract.py --write` regenerated the checkout manifest: 105
methods, 901 recorded shapes (895 on `655c8199`), contract identity `1d7d101e83fe…` unchanged. `--check` passes, and
`generate-control-contract.py --check` is clean.

Still unpublished, because no frame here produces it: `threadId` other than null, and a
`job.reconcile` answer for a Job that carries a recovery epoch.

## CI

The PR's `guard` and `swift` aggregate: recorded in the next slice's record.

## Not in this slice

The Rust dedicated-readback reconcile replaying this oracle (after slice 2b), the resume lane
(`resumeAtConfirmedSafeBoundary` → `job.run`), and the `debug.hap@1` branches.
