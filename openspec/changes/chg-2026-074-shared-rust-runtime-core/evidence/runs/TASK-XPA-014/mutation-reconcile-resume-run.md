# TASK-XPA-014 — the dedicated readbacks of parked device mutations and the resume lane, replaying a Swift oracle (M2, macOS, 2026-09-24)

TASK-XPA-014 remains in progress. Base: protected main `86ea4d839` (#2137). G5 slice 8 of the
recovery port the maintainer ruled on 2026-09-19 (design §L.1 item 13; the Ruling section of
`evidence/adr-0009-decision-package-20260914.md`), after slices 2d-a/2d-b/2d-c
(`recovery-device-reconcile-oracle-run.md`, `recovery-readback-reconcile-oracle-run.md`,
`recovery-device-reconcile-run.md`). Every answer and file compared here is replayed from a Swift
oracle recorded over the shared fake HDC in a fixed-root host fixture. None of it is device
evidence, installed-Runtime activation or GJ acceptance (POL-VERIFY-001, POL-MODE-001).

## What a user sees

Before this slice `job.reconcile` refused every `debug.hap@1` Job, every
`deploy.native-library.app-owned@1` Job whose outcome was unknown, and every Job parked on an owned
remote path, a package, staging or a screen sequence; and `job.run` refused every Job that had left
`preflight` ("resumes no Job before recovery is ported"), so a mutation a reconcile confirmed
completed kept its capability use `outcomeUnknown` and its Target's lineage blocked for good. Now:

- `job.reconcile` of a Job parked after a mutation intent reads the mutation back once, as Swift's
  engine does, and never resends it: a debug HAP's staging, packages and ability (`ls -ld` of the
  owned path or directory, `bm dump -n`, `pidof`), a diagnostic capture's owned file (`ls -ld`), a
  native deployment's steps (its own inspection), a port rule (`fport ls`, as before). A readback
  that shows the change done confirms it completed and the Job waits at its confirmed safe
  boundary; one that shows it not done fails the Job (`executionConfirmedNotPerformed`), its use
  resolved `safeToReflash` — except a debug HAP, which keeps its failure and runs its failure
  finalization at once, the compensations its succeeded steps declared, under the use it consumed;
  anything indefinite keeps the Job parked.
- `job.run` resumes a Job where Swift's `runOwned` resumes it: at the confirmed safe boundary
  (`resumeAtConfirmedSafeBoundary → running`, "resume confirmed durable provider boundary"), from
  `running` once a restart found nothing outstanding ("resumed: journal-confirmed provider
  boundary"), and a debug HAP's failure finalization from `finalizing`. Every step the journal
  confirmed succeeded is skipped ("resume skipped journal-confirmed step …"); host steps run again;
  the resumed Job continues under the capability use it already holds and settles it at its end,
  so the next mutation on the binding is admitted again.

## Swift semantics, by class (the oracle)

Read from `RuntimeJobEngine.swift` (`runOwned`, `executeSteps`, `reconcileOwned`,
`finishReconcile`, `performDebugHAPFailureFinalization`, `consumeCapabilityBeforeMutation`) and
`DeviceProviderAdapters.swift` (`reconciliationReadback`, `verifyReconciliationReadback`,
`reconcile`), and recorded:

- **Which actions are read back.** `reconcileOwned` routes on the persisted action's effect: at or
  above `deviceMutation` it asks `reconciliationReadback` (a plan that must be at most read-only,
  lowered under `reconcile-<step>-<sha256(attempt)[:32]>`), dispatches it once and judges it with
  `verifyReconciliationReadback`; below it, `reconcile` answers without a dispatch (every read-only
  family is confirmed not executed: observations, bounded captures, a received file, a debug
  template, a package or process readback, application liveness, a native inspection). A
  presence readback concludes completed only for the presence the mutation wanted
  (`["postconditionPresent"]`), not executed for the other one. A native readback concludes by its
  own verdict table: an inspection that verifies is completed (its summary's keys journaled), one
  that fails is not executed for the staging send, backup, stop, start and cleanup, but for a
  publish is `…; publish state is not safe to replay` and for a rollback its failure, both still
  unknown.
- **debug.hap@1.** An install killed before it installed reads back absent: not executed. The
  record is persisted before the decision (with `executionConfirmedNotPerformed`), the Job moves
  `reconciling → finalizing` and stays there, and `finalizeDebugHAPFailure` runs inside the
  reconcile: the compensations of the source steps that succeeded (here the staging cleanup; for a
  Job parked on its read-only HiLog capture the stop, the uninstall and the staging cleanup), under
  the use the Job consumed (`validateContinuation` in `finalizing`), then `finalizing → failed`
  ("original failure retained; declared compensations have confirmed outcomes") and the use
  `confirmed`. An install killed after it installed reads back present: completed; `job.run`
  resumes at the boundary and runs the package readback, the start, the process readback, the
  HiLog capture, the stop, the uninstall and the cleanup, consuming nothing new.
- **deploy.native-library.app-owned@1.** A publish killed after the helper published reads back as
  the leased library (`targetMatchesArtifact`): completed; the resumed Job verifies the library on
  the host again (`verify-elf-locally`, `hash-library` run again), skips the staging send, its
  readback, the backup and the publish, and restarts, starts, verifies the loaded library and
  cleans up. A publish killed before the helper published reads back as the replaced library:
  `nativeTargetHashMismatch: …; publish state is not safe to replay`, so the Job stays
  `waitingForRecovery`, `job.run` refuses it (`is waitingForRecovery, not runnable`) and its unknown
  use refuses the next request (`admissionDenied`).
- **capture.screen-sequence@1.** A receive killed is read-only: not executed, the Job fails.
  **A parked capture is never concluded (Swift defect, reproduced):**
  `PersistedTypedProviderAction.materialize()` has no case for `hdc.captureScreenSequence` or
  `hdc.cleanupScreenSequence`. The reconcile begins (`waitingForRecovery → reconciling`,
  `reconcileStarted`), then fails `internalError` "persisted typed provider action kind
  hdc.captureScreenSequence is unknown" with nothing dispatched; the record file keeps its last
  durable state, the engine keeps the Job resident in `reconciling` (a second reconcile fails the
  same way without writing; `job.run` answers `is reconciling, not runnable`).
- **capture.diagnostics@1 (file legs).** A component tree capture killed before writing reads back
  absent (`ls -ld`): not executed, the Job fails, the use `safeToReflash`. One killed after writing
  reads back present: completed; the resumed Job runs the host storage preflight again, re-records
  every optional step it skips (timeline and missing products, the index keeping one row per
  product), receives the tree, cleans it up and finalizes. A cleanup the device refuses owes a
  debt, which `cleanupDebt.continue` reads back present, retries once and settles.
- **input.tap@1 resumed from `running`.** A daemon that dies at the engine's
  `beforeMutationCapabilityCommit` hook leaves the Job `running` with its evidence steps confirmed
  and no use consumed; after the start, `job.run` resumes it and consumes the use (one `consumed`
  ledger row). One that dies at `beforeDispatchInstall` for `inject-pointer-input` leaves the use
  consumed and the Job's evidence durable; the resumed run continues under that use (Swift's
  persisted-evidence arm: every fresh check again, no second consume), sends the gesture once and
  settles it.
- **A debug HAP finalization left by a restart.** A daemon that dies at the engine's
  `failureFinalizing` checkpoint leaves the Job `finalizing` with its failure; the start keeps it so
  ("recovered: pending declared failure compensation; explicit continuation required"), and
  `job.run` continues the finalization (no transition, no new `startedAtUTC`).

## The oracle

`Packages/ArkDeckKit/Tests/ArkDeckContractTests/DeviceMutationReconcileOracleContractTests.swift`
(new), recorded to `rust/tests/fixtures/device-mutation-reconcile/`: eight scenarios, each over a
fresh fixed root in `HDCOracleHarness`'s composition (the native one with the code-sign helper at
its fixed path, the screen sequence and the file legs with the host receive root under the root,
the screen sequence with every child at 0.5 s), each with its own `hdc-answers.sh` — the answers of
the port-forward, debug HAP, native library, screen sequence, file legs and tap oracles, plus modes
where the HDC call dies on SIGKILL before or after the device changed (`createKilledAfter`,
`installKilledBefore`, `installKilledAfter`, `publishKilledBefore`, `publishKilledAfter`,
`receiveKilled`, `treeKilledBefore`, `treeKilledAfter`) and the file legs' `ls -ld`. Three scenarios
copy the root at an engine hook, let the live run end and put the copy back, as
`CrashWindowOracleContractTests` does. 163 exchanges, 17 Jobs, 51 store snapshots (Job index and
files, capability store, the fake's calls so far), 182 fake calls; 990 files. Recorded twice
(`ARKDECK_RUST_DEVICE_MUTATION_RECONCILE_RECORD=/private/tmp/arkdeck-dmr-r1`, `…-r2`): `diff -r`
identical; the checked-in oracle then compares byte for byte.

No control schema changes: every recorded frame was validated against the published
`spec/control/methods/*.json` (jsonschema 4.26); the only refusal is `job.show` of a screen
sequence Job, whose `screenSequence` object the published schema still pins to `null` — the gap
S11 noted, not this slice's (see "Not in this slice").

## Rust

- `arkdeck-provider-hdc`: `FileAction::from_persisted` (Swift's materialization of the capture
  family: trace, component tree, screenshot with its image type, received file, liveness, crash
  index and log, owned-path cleanup) and `FileAction::written_path`; `PersistedArguments` gains
  `string_array` and `owned_path(image_type)`.
- `arkdeck-hoststore/src/job_reconcile_device.rs`: `PORTED` grows from 11 to 38 kinds — the read-only
  families above, every mutation Swift reads back (HAP, capture, native, port) and the two screen
  sequence kinds Swift's materialization does not know. Materialization goes through each family's
  `from_persisted`; the decision lowers the family's readback under the reconcile's step identity,
  refuses a plan above read-only, dispatches it once and judges it (presence against the wanted
  presence; a native inspection by `NativeAction::reconcile`). A refusal of a persisted action is
  now spelled as Swift interpolates `DeviceProviderError` (its detail alone), where it was wrapped
  in `unsupportedAction(…)` (the oracle's unknown-kind answer proves Swift's spelling; no earlier
  oracle reached one).
- `job_reconcile.rs`: a non-terminal debug HAP is reconciled. Its record is persisted before the
  decision; one confirmed not executed stays `finalizing` and its failure finalization runs through
  the runner (`JobReconciler::runner`, new) after the Job's held use is taken over; a debug HAP left
  `finalizing` is finalized on `job.reconcile` too. A debug HAP's and a native deployment's input
  lease is resolved again before materialization (Swift `resolvedInputArtifact`).
- `job_run.rs`, `device_run.rs`: the resume lane. `job.run` accepts a device-bound Job at
  `resumeAtConfirmedSafeBoundary`, `running` or (a debug HAP) `finalizing`, only when its journal
  stands at that boundary: no torn tail, the record's state, not finalized, no outstanding intent
  and no unknown outcome (a debug HAP's finalization parks itself on those, as Swift's does), a
  confirmed last reconcile decision for the confirmed boundary, and the record not unknown —
  otherwise `resourceConflict` with the zero-dispatch proof. The step loop starts from the steps the
  journal confirmed succeeded (Swift `confirmedSucceededStepIDs`) and skips them; a debug HAP's
  optional cleanup whose failure the journal already confirms owes its debt without a second
  attempt (Swift `resumeConfirmedOptionalDebugHAPCleanupDebt`). An analyzer Job is still run from
  `preflight` only.
- `device_hap_failure.rs`: `perform_hap_failure_finalization` split out of `finalize_hap_failure`
  (the original failure as the record or journal proves it, the Job open again, then the lane);
  `device_run.rs` `conclude_hap_failure` settles the use after it for `job.run` and `job.reconcile`.
- `mutation_execution.rs`, `capability_store.rs`: `take_over_held_use` — a resumed run takes over
  the use its record names only when the record's evidence names the request's capability and the
  capability store still holds that very use (this reservation and Job, the correlated ordinal,
  reservation and query fingerprint) unsettled (`CapabilityStore::unsettled_use`, read-only);
  otherwise `rejected` with the zero-dispatch proof. At a mutation the taken-over use goes through
  Swift's persisted-evidence arm (every fresh check again, nothing consumed); a Job resumed before
  it consumed a use consumes it as a first run does (a retried reservation answers its receipt).
- `arkdeck-agentd/src/host.rs`: `job.reconcile` composes the runner its runs use. Now that a run
  resumes Jobs a reconcile concludes, the two never drive one Job at once: a `job.run` of a Job
  whose reconcile is under way waits it out (`claim_run`) and then meets the Job as the reconcile
  left it, and a reconcile checks for a run and registers itself under the same lock order
  (`running`, then `reconciling`).

## Tests

- `tests/device_mutation_reconcile.rs` (new): the five scenarios replayed step by step — every
  answer, every snapshot where the oracle took it, and everything left (the fake's calls, the
  Target document, the Job store, capability store, Sessions, storage owner, Artifacts, tree) byte
  for byte; the three crashed scenarios with a child of the test binary exiting at the same
  window (the tool identity check that opens the consume; the first clock read once the record
  holds the consumed evidence; the first clock read once the record is `finalizing`), the store it
  leaves compared with Swift's at its death, then every exchange after the submission. And
  `a_resumed_job_continues_only_the_unsettled_use_it_holds`: with the use settled behind the Job's
  back, the resume is refused with nothing dispatched or written.
- `support/reconcile.rs`: the daemon composes the oracle's code-sign helper, host receive root and
  fixed child duration, serves `cleanupDebt.*`, and gives its reconciler a runner.
- `arkdeck-agentd` `host.rs` `a_run_waits_out_a_reconcile_of_its_job_under_way`: a run of a Job a
  reconcile holds waits on the reconcile's slot without taking the Job, then starts its own.
- `arkdeck-provider-hdc` `persisted_forms_materialize_back_as_swift_reads_them`: every persisted
  form of the capture legs materializes back as the action that persisted it, `expectedLeadingBytes`
  read as Swift reads it, a JPEG still's cleanup refused as Swift refuses it.
- Updated to the ported behaviour: `debug_template_run.rs` (a parked read-only template is
  reconciled not executed, the Job fails and is not run again), `debug_hap_run.rs` (a finalization
  continued through an unproven tool is still refused and dispatches nothing), `pointer_input_run.rs`
  (a use consumed while the record could not be written, or a run that died right after consuming,
  is resumed: the gesture sent once, one consumption, the use settled; a run that died after its
  intent is still never resumed), and the materialization refusal spellings in the unit tests.

## Differences from Swift (declared)

- **Stricter takeover.** Swift's persisted-evidence arm reads the resident record alone. The Rust
  runner, which has no resident memory, requires the capability store to still hold the record's
  use unsettled for this reservation and Job before a resumed run continues under it. In every
  flow Swift can produce the use is `pending` or `outcomeUnknown` there; otherwise nothing is
  dispatched.
- **Journal boundary.** Swift trusts its resident state; the Rust runner resumes only a journal
  that stands at the record's boundary (above), and refuses otherwise with the zero-dispatch proof.
- **A run beside a reconcile.** Swift refuses a run of a Job a reconcile holds `reconciling`
  (`is reconciling, not runnable`) and joins one whose failure finalization a reconcile is running
  (`jobFailureFinalizations`), answering its status. The Rust daemon's `job.run` waits the
  reconcile out and then meets the Job as it left it (a finalized debug HAP answers `is failed, not
  runnable`; a Job left at its confirmed boundary is resumed). No oracle times the two against each
  other.
- **Still refused before anything is written:** a debug HAP parked on a declared compensation's
  own intent, on its compensation identity proof (`resumeDebugHAPCompensationAfterIdentityProof`),
  or on a failure decision its journal already holds; a terminal debug HAP whose lineage a repair
  would write; and a Job parked on a read-only action Swift's provider has no reconcile source for
  (a presence readback, a crash index or log: Swift journals its own debug rendering of the
  action). An analyzer Job is not resumed.

## Mutation checks

Each applied to the source, the tests below run, then the file restored and its SHA-256 checked
against the one taken before (`/private/tmp/arkdeck-s15-mutations.log`, one log per mutation
`/private/tmp/arkdeck-s15-mutation-<name>.log`):

| Mutation | Where | Caught by |
| --- | --- | --- |
| A resumption replays an unknown intent: the outstanding-intent and unknown-outcome guard dropped | `job_run.rs` | `pointer_input_run` `restart_after_consumption_resumes_once_and_after_intent_never_replays` fails: the Job that died after its gesture intent is resumed — its record rewritten with the resume timeline, no new gesture in the fake's log — and answers `internalError`, not `resourceConflict` |
| Steps the journal confirmed are run again | `device_run.rs` | 6 of the 10 `device_mutation_reconcile` tests (port rule, debug HAP, native library, file legs, both taps) |
| A debug HAP mutation is concluded completed without its readback | `job_reconcile_device.rs` | `a_debug_hap_is_reconciled_finalized_and_resumed_as_swift_does` (the store at `steps/reconcileNotInstalled` differs) |
| A resumed run ignores the use it holds and consumes again | `mutation_execution.rs` | 5 of the 10 (native library, tap after its consume, file legs, both debug HAP scenarios): e.g. `tap.resume` leaves the record one index version ahead, a second consumption written |
| A resumed run continues the record's evidence without the store proving the use unsettled | `mutation_execution.rs` | `a_resumed_job_continues_only_the_unsettled_use_it_holds` (the Job runs to `succeeded`) |
| A run no longer waits out a reconcile of its Job under way | `arkdeck-agentd` `host.rs` `claim_run` | `a_run_waits_out_a_reconcile_of_its_job_under_way` ("the run never met the reconcile"; `/private/tmp/arkdeck-s15-mutation-run-beside-reconcile.log`) |

## Local targeted checks

All with `CARGO_BUILD_JOBS=2` and the worktree's own target `/private/tmp/arkdeck-1330-rust-target`;
logs `/private/tmp/arkdeck-s15-*.log`.

| Check | Command | Result |
| --- | --- | --- |
| Swift oracle | `ARKDECK_RUST_DEVICE_MUTATION_RECONCILE_RECORD=/private/tmp/arkdeck-dmr-r1` then `…-r2` `sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --filter DeviceMutationReconcileOracleContractTests` (`ARKDECK_SWIFTPM_CACHE_ROOT=/private/tmp/arkdeck-e190-swift`); `diff -r` of the two | exit 0 twice; identical |
| Swift compare | the same filter against the checked-in fixture | exit 0 (1 test, 10.4 s) |
| Frames | every exchange validated against `spec/control/methods/*.json` (jsonschema 4.26) | one refusal, `job.show` of a screen sequence Job (see below) |
| Format | `cargo fmt --all --check` | exit 0 |
| Lint | `cargo clippy -p arkdeck-provider-hdc`, `-p arkdeck-hoststore`, `-p arkdeck-agentd`, `-p arkdeck-soak`, each `--all-targets -- -D warnings` | exit 0 each |
| After the rebase onto #2137 and the run/reconcile serialization | `cargo clippy -p arkdeck-agentd --all-targets -- -D warnings`; `cargo build -p arkdeck-cli`; `cargo test -p arkdeck-agentd --no-fail-fast` | exit 0; exit 0; exit 0 (117 tests in 9 binaries, `managed_hdc_process` 9/9 among them) |
| Changed crates and dependents | `cargo test -p arkdeck-provider-hdc -p arkdeck-hoststore -p arkdeck-agentd -p arkdeck-soak --no-fail-fast` | 796 passed, 1 failed: `managed_hdc_process` `the_managed_server_answers_status_and_availability_and_stops_with_the_daemon` ("no answer to health", outside this diff; it passed in the previous full run over the same agentd code, and its binary alone passes: 9/9) |
| Acceptance | `cargo test -p arkdeck-hoststore --test device_reconcile --test readback_reconcile --test debug_hap_run --test native_library_run --test screen_sequence_run --test device_mutation_reconcile --test crash_window --test pointer_input_run --test capture_diagnostics --test cleanup_debt_continue` | exit 0 (51 tests) |
| Provider | `cargo test -p arkdeck-provider-hdc` | exit 0 (178 tests) |
| Real processes | `check-corpus-replay.py --fixture` for `observe-device`, `capture-diagnostics`, `capture-diagnostics-read-legs`, `agent-execution` | PASS: 28/64, 28/64, 66/144, 29/60 exchanges/checks, before and again after the rebase with the final binaries |
| Real processes, this oracle | the same for `device-mutation-reconcile/portRule` and `…/tapBeforeConsume` | not replayable (see "Not in this slice"): the isolated daemon answers the first mutation's `job.submit` `admissionDenied` and `invalidInput`, where Swift's in-process composition admitted it |
| SDD | `sh scripts/check-sdd.sh` | exit 0 (0 errors, 0 warnings) |
| Leftovers | `pgrep` for fake HDC servers and daemons | none of this run's; the installed agentd and HDC untouched |

Not run: `generate-contract.py --check` and `check-contracts` (no contract input changed), Swift
tests beyond the oracle, App, device.

## CI

Pending.

## Not in this slice

- The Swift defect above: a screen sequence parked on its capture or cleanup can never be
  reconciled (Swift's materialization does not know the kinds), and Rust reproduces it. Treating
  the kinds as mutations without a dedicated readback (`mutation has no dedicated readback;
  original not resent`) would change recorded Swift behaviour and needs a maintainer decision.
- `job.show` of a screen sequence Job: the published schema pins `screenSequence` to `null`, so a
  Rust daemon rewrites that answer to `internalError`. This oracle now records the frame that
  follow-up needs (`screenSequence` `receiveKilled.job.show`: `{"capturedFrameCount": 3,
  "frameDurationsSeconds": [0.5, 0.5, 0.5], "requestedFrameCount": 3}`); re-deriving `job.show`
  from its corpus plus that frame changes a contract input and is left to its own slice.
- The debug HAP lanes listed above, and `cleanupDebt.continue` for a HAP compensation debt left by a
  reconcile (reachable only through a compensation that fails during a reconcile's finalization).
- `check-corpus-replay.py` cannot replay these scenarios through a real daemon: the isolated
  daemon's development mutation authority needs a managed HDC server (as for the file legs and the
  screen sequence), the harness serves neither `job.reconcile` nor a start mid-oracle, and three
  scenarios begin from a daemon that died at an engine hook. The replay is in-process only.
- Found, reproduced: Swift rebuilds a persisted receive or owned-path cleanup with its default PNG
  suffix (`path()`), so a JPEG still's receive or cleanup can be neither materialized for a
  reconcile nor continued as a cleanup debt (`persisted … remote path does not match its owned
  components`). The Rust materialization reads them as Swift does (a unit test pins it).
- Found, not fixed: `cleanupDebt.continue` still renders a refused materialization through
  `FileActionError`'s `Display` (`unsupportedAction("…")`), where Swift's `DeviceProviderError` is
  interpolated as its detail alone (the spelling this oracle proves for a reconcile). No oracle
  reaches that refusal of a continuation.
- Hardware: none of this is device evidence.
