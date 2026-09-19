# TASK-XPA-014 — recovery port, slice 2e-a: the crash-window Swift oracle

Change: CHG-2026-074-shared-rust-runtime-core@r11. Part of slice 2 of the recovery port the
maintainer ruled on 2026-09-19 (design §L.1 item 13; the Ruling section of
`evidence/adr-0009-decision-package-20260914.md`). The ruling task and XPA-AC-7
(`verification.md`) ask for the crash-window matrix: the daemon killed before and after an
intent, and before and after the capability consume, failing closed, with `outcomeUnknown`
carried and never replayed. XPA-AC-7 names its two columns "Rust authority / Swift sidecar". r11
builds no sidecar: `executor.step.execute` is not built once SPK-6/9/10 pass
(`docs/design/cross-platform/macos-chain-agent-prompt.md`). The Swift column is therefore the
Swift daemon, today's authority, dying at a window, with the Rust daemon later starting over its
store. This slice records Swift's side from Swift, so that the Rust slice replaying it changes no
Swift file (r11 rule 10). Host-local: the shared fake HDC, no device.

Base: protected main `6592bcce` (#2051). Branch
`agent/xpa-014-recovery-crash-window-oracle-20260919`, no stack. Files:
- `Packages/ArkDeckKit/Tests/ArkDeckContractTests/HDCOracleHarness.swift`: `composition` takes
  the engine's package-only `testHooks` (one parameter, `.none` by default);
- `Packages/ArkDeckKit/Tests/ArkDeckContractTests/CrashWindowOracleContractTests.swift` (new);
- `rust/tests/fixtures/crash-window/` (new, one directory per window);
- the CI sections of the records of #2033, #2034 and #2040;
- this record.

No Rust, production Swift, Catalog, spec, schema or control-frame change.

## The windows

One `input.tap@1` runs over the shared fake HDC, in `HDCOracleHarness`'s composition of the
standalone daemon's engine, one window per pass over a fresh root. The tap's journal is: three
read-only evidence steps (`confirm-evidence-target`, `read-evidence-model`,
`read-evidence-firmware`), the capability consume ("capability consumed before first mutation"),
then the `inject-pointer-input` intent and dispatch.

| Window | Intent | Consume | Where the root is copied |
| --- | --- | --- | --- |
| `beforeConsume` | before | before | the engine's `beforeMutationCapabilityCommit` hook: every evidence step done, nothing consumed |
| `afterReadOnlyIntent` | after (read-only) | before | the fake, answering `read-evidence-model`: that intent durable, its tool running |
| `afterConsume` | before | after | the engine's `beforeDispatchInstall` hook for `inject-pointer-input`: the use consumed and the Job's `runtimeCapability` evidence durable, no mutation intent |
| `afterIntent` | after | after | the fake, answering `uinput`: the mutation intent durable, the injector running |

A death is what the daemon left on disk at that moment. The whole root is copied there, the way
Swift's own crash contract tests recreate a death (`HAPCheckpointCapture` in
`DiagnosticsAndHAPContractTests`). The live run is left to finish, and then the copy replaces the
root. Both engine hooks already exist (`RuntimeJobEngine.Configuration.TestHooks`); no hook was
added to the engine. At each window the daemon is between durable writes: suspended in a hook, or
waiting for the tool.

After the death, the daemon starts twice over the root (`recoverActiveJobs`), the Job is
reconciled twice (`job.reconcile`), a new tap is submitted under the same automatic capability
policy, and the Job and the capabilities are read. Each window's directory keeps every answer
(`cases.json`), the store at the death (`crash/`), after each start (`restart/`,
`secondRestart/`) and after each reconcile (`steps/<name>/`), and what the harness records of a
root, including every call the fake received.

## Swift's answers

| Window | The two starts | `job.reconcile`, twice | The next tap |
| --- | --- | --- | --- |
| `beforeConsume` | `running`, `recovered: journal clean`; journal unchanged (9 events) | the Job's status, nothing written | admitted: nothing was consumed |
| `afterReadOnlyIntent` | parked: `running -> waitingForRecovery`, `outcomeUnknown`, `recovered: outstanding intents or unknown outcomes; no redispatch` | `failed`, `executionConfirmedNotPerformed`: the read-only intent confirmed not executed from facts; again, nothing written | admitted |
| `afterConsume` | `running`, `recovered: journal clean`; the use stays consumed with no outcome | the Job's status, nothing written | `admissionDenied`, `{phase: preAdmission, newDispatchCount: 0}`: "… unresolved capability … use 1 outcome pending" |
| `afterIntent` | parked as above; the capability ledger gains the use's `outcomeUnknown` (`waitingForRecovery`) | `waitingForRecovery`, `outcomeUnknown`: the mutation has no dedicated readback, nothing resent; each reconcile adds four journal events | `admissionDenied`, the same proof: "… use 1 outcome outcomeUnknown" |

In every window, neither start nor either reconcile adds a call to the fake (the test asserts it).
The fake's log at the death holds 3, 2, 3 and 4 calls respectively.

What this shows, in Swift:
- **Fail closed, zero replay.** `recoverActiveJobs` dispatches nothing in any quadrant, and no
  reconcile resends the gesture. After the mutation intent, the unknown outcome is carried
  through two starts and two reconciles and the lineage blocks the next mutation.
- **The zero-dispatch proof** (`details.phase`, `newDispatchCount`) appears on the admission
  owner's refusal, and on `job.result`'s `resultNotReady`, never on a start's or a reconcile's
  answer.
- **A use consumed without an intent** is neither settled nor released by a start: it blocks
  every new mutation on the device.
- **A read-only intent left outstanding** parks the Job like a mutation, and the reconcile settles
  it from the device's recorded facts without a device call.

## For the maintainer

- After a death before the mutation intent (`beforeConsume`, `afterConsume`), the Job stays
  `running` across starts with no executor; `job.status` says `running` and `job.result` answers
  `resultNotReady` with `nextAction` `wait`, `job.running`. Only `job.run` resumes it (the resume
  lane, not yet ported). With `afterConsume` the consumed use blocks every new mutation on the
  device until then, and the §G.4 cutover preflight counts a `running` Job as blocking.
- With `afterReadOnlyIntent` the failed Job's Session is not published:
  `sessionPublication.reasonCode` is `sourceIntegrityFailed`, "device Session: missing or
  inconsistent job-local target/tool observation". The interrupted evidence steps never recorded
  the model and firmware that a device Session requires (`RuntimeSessionPublication`
  `deviceContext`). This is not an artefact of the copy.
- The window between the ledger's consumption and the Job's evidence (the Rust runner's
  `consume` crash in #1984's `pointer_input_run.rs`) has no Swift hook, so Swift's store there is
  not recorded. The Rust slice covers it with fail-closed assertions of its own.

## Determinism

The same as the other HDC oracles: a fixed root under the fake's lock, the fixed clock, each Job
record's machine facts as labels, `provenance.json` listing the digests of each window's files.
The copies keep file modes: the modes `tree.json` records for the paths this oracle shares with
the device-reconcile oracle (#2040) are the same. Every published schema admits every recorded
answer: 44 exchanges, checked with jsonschema 4.26 against `spec/control/methods/` on the base
(scratchpad `validate-cases.py`).

## Local targeted checks

Per `AGENTS.md` (#2015) the unified gate is the PR's CI; locally, through
`sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --filter …`:

| Run | Exit | Result |
| --- | --- | --- |
| recording r1 (`ARKDECK_RUST_CRASH_WINDOW_RECORD=/private/tmp/arkdeck-crash-window-r1`) | 0 | 1 test, 0 failures |
| recording r2 (`…-r2`), `diff -r` against r1 | 0 | 1 test, 0 failures; identical byte for byte |
| `--filter 'ArkDeckContractTests\..*OracleContractTests'`, this fixture installed | 0 | 28 tests, 0 failures: every oracle class composing `HDCOracleHarness` reproduces its checked-in files with the added parameter, and this one compares every file |
| `sh scripts/check-sdd.sh` | 0 | 0 errors, 0 warnings |

## CI

The PR's `guard` and `swift` aggregate: recorded in the next slice's record.

## Not in this slice

- The Rust replay (slice 2e-b): the Rust runner killed at the same four windows in child
  processes, its store at the death compared with `crash/`, then its starts, reconciles, next
  admission and reads compared with Swift's. It needs slice 2b (the Rust restart carry-over and
  `job.reconcile`) and the Rust device-bound reconcile.
- `job.run` of a Job a start left `running` (the resume lane).
