# Decision package — what carries ADR-0009 decisions 2 and 4 today (design §L.1 item 13)

Prepared 2026-09-14 against protected main `6cf99fb6` for CHG-2026-074 r11. This file asks the
maintainer for one ruling; it rules nothing itself. All paths are under `Packages/ArkDeckKit/`
unless stated; line numbers are those of `6cf99fb6` and were read, not inferred.

## The question

`docs/adr/0009-campaign-unknown-outcome-authority.md` (accepted 2026-08-07) argued from four
symbols that CHG-2026-065/066 later removed (`settlesUnknownLoaderTransition`,
`recordCampaignOutcome`, `reconcileUnresolved`, `closeAttempt`). Its head note (lines 3–14) records
that it is undecided whether decision 2 (a crashed attempt stays `outcomeUnknown` and must not be
described or treated as recoverable) and decision 4 (an existing proof is never discarded) still
bind the current runtime and what carries them. Design §L.1 item 13 forbids porting recovery to Rust
before that is settled, because Rust would otherwise fix an unruled semantic. TASK-XPA-014 has so
far refused every recoverable state, `job.reconcile`, resumable Jobs and recovery epochs for that
reason, and GJ-1's restart carry-over and GJ-4's DEC-016 path both run through it.

## Proposed ruling

> ADR-0009 decisions 2 and 4 bind the current runtime. Decision 2 is carried by the engine's park
> and no-redispatch paths, the recovery service's replay, the journal projection, the CLI exit
> status and the client classification listed in §1; decision 4 by the `confirmedNotExecuted`
> semantic code and its readers, the append-only capability ledger, the hash-chained
> superseding-recovery relation, the retention leases and the unreadable-record refusals listed in
> §2. The Rust port reproduces those carriers unchanged (T0 for the durable formats, T1 for the
> transitions and refusals), adds no new recovery semantics, and keeps the four missing symbols
> missing; the ADR head note is updated to name these carriers.

If the maintainer rules otherwise, the port follows the ruling; nothing below presumes it.

## 1. Decision 2 — crashed attempts stay `outcomeUnknown`, never replayed

### 1a. Where a Job is classified unknown and parked

| Carrier | Function | Decisive statement |
| --- | --- | --- |
| `Sources/ArkDeckWorkflows/RuntimeJobEngine.swift:1-9` | file header | "Unknown outcomes park in waitingForRecovery; there is no automatic replay anywhere in this file." |
| `RuntimeJobEngine.swift:2079-2094` | `run(...)` catch of `RuntimeDispatchFailure` | `.outcomeUnknown(reason)` → transition to `.waitingForRecovery`, `record.outcomeUnknown = true` |
| `RuntimeJobEngine.swift:3365-3378` | `parkDebugHAPCompensation(jobID:reason:)` | `outcomeUnknown = true` and the capability outcome recorded as `.outcomeUnknown` |
| `RuntimeJobEngine.swift:4368-4375` | step dispatch outcome switch | "outcomeUnknown …; durable intent left outstanding" (recording an outcome would make the read-back impossible) |
| `RuntimeJobEngine.swift:7020-7045` | still-unknown reconcile tail | `nextState: .waitingForRecovery, outcomeCertainty: .outcomeUnknown` |
| `Sources/ArkDeckWorkflows/RuntimeRecoveryService.swift:743-767` | `replay(_:)` | `record.outcomeUnknown = true`; timeline "recovered: outstanding intents or unknown outcomes; no redispatch" |
| `Sources/ArkDeckStorage/JournalReplay.swift:148-167` | `requiresRecovery` | `hasTornTail || !outstandingIntents.isEmpty || !unknownOutcomes.isEmpty` — the projection that forces the park |

### 1b. Where recovery refuses to replay or re-dispatch

| Carrier | Function | Decisive statement |
| --- | --- | --- |
| `RuntimeJobEngine.swift:5919-5921` | `recoverActiveJobs()` | delegates to `recover(records: admissionService.activeJobs())` |
| `RuntimeJobEngine.swift:5923-5981` | `recover(records:)` | "Reopen the supplied authoritative job set, replay each journal and park unknowns. … Recovery itself never dispatches."; the `outcomeUnknown` capability outcome is re-asserted on every restart (5971–5974) |
| `RuntimeRecoveryService.swift:1-6` | file header | "It never resolves facts, dispatches a provider action, or changes authority." |
| `RuntimeRecoveryService.swift:631-634` | `replay(_:)` doc | "Replays a repaired projection without ever dispatching a provider. Any unresolved intent is durably parked…" |
| `RuntimeRecoveryService.swift:676-679, 704-715, 725-741` | `replay(_:)` | `mustParkWithoutRedispatch` = unresolved intent ∨ lost ArkForge lane ∨ pending HAP identity proof; "Resuming that Job would create a new lane actor and could materialize the same destructive plan again. Park it unknown" |
| `RuntimeRecoveryService.swift:768-771` | `replay(_:)` else branch | "Complete only these already-durable decisions; recovery never dispatches in any branch." |
| `Sources/ArkDeckStorage/RuntimeJobRepository.swift:293-305` | `activeJobs()` | `waitingForRecovery` is not excluded from the active set, so an unknown Job is reopened, never reclaimed, on every restart |
| `Sources/ArkDeckCLI/ArkDeckRuntimeCommands.swift:127-133` | `terminalJobExit(_:)` | "POL-RECOVERY-001 forbids replaying it, so it gets its own exit status" (75); "the original effect is never replayed" |
| `Sources/ArkDeckCLI/CLIErrorRegistry.swift:109-121` | `isControlRequestRetryable` | "retrying the request that produced it is exactly what POL-RECOVERY-001 forbids" |
| `Sources/ArkDeckAgentClient/AgentRuntimeExecutor.swift:540-543` | terminal classification | `waitingForRecovery` → `.failed(reason: "job requires typed reconcile: …")` — the agent surface never presents it as recoverable |
| `Sources/ArkDeckWorkflows/DebugApplicationFacade.swift:1570-1578` | `compatibilityFailure(state:outcomeUnknown:)` | `code: .outcomeUnknown, recovery: .awaitRuntimeReconciliation` |

### 1c. The only sanctioned exits

| Exit | Carrier | Function | Decisive statement |
| --- | --- | --- | --- |
| `job.reconcile` read-back | `Sources/ArkDeckAgentDaemon/AgentDaemon.swift:1112-1131` | handler case `"job.reconcile"` | "Reconciliation resolves a durable intent against the device"; only a genuinely absent Job is `notFound` |
| — engine entry | `RuntimeJobEngine.swift:6161-6199` | `reconcile(jobID:)` / `reconcileOwned(jobID:)` | gate at 6254: `guard runtime.record.outcomeUnknown` |
| — legacy refusal | `RuntimeJobEngine.swift:6316-6322` | `reconcileOwned` | "reconcile refused: legacy outcomeUnknown event cannot be rewritten; original not resent" |
| — terminal decision | `RuntimeJobEngine.swift:6652-6799` | `finishReconcile(...)` | three-way `confirmedCompleted` / `confirmedNotExecuted` ("confirmed not executed; original not resent", 6714–6728) / `stillUnknown` (stays `waitingForRecovery`, 6729–6735) |
| POL-RECOVERY-001 complete proof | `RuntimeJobEngine.swift:7167-7187` | `hasCompleteMutationNonExecutionProof(_:)` | "A failure message, one reconciled Step or an absent declaration cannot stand in for this complete Journal proof." |
| — its consumer | `RuntimeJobEngine.swift:7079-7165` | `repairTerminalSafeToReflashLineageIfNeeded(for:)` | requires `!record.outcomeUnknown` (7087); dispatches "a Provider readback (and never the original mutation)" (7082–7083) |
| DEC-016 complete-overwrite epoch | `RuntimeRecoveryService.swift:67-185` | `completeOverwriteAdmission(...)` | "Without a campaign an unknown older than four hours stays exactly where it was." (147–153); ordinal cap ≤ 16 (170–173) |
| — epoch establishment | `RuntimeJobEngine.swift:2220-2231` | finalize branch of `run` | "superseding recovery epoch … established; original outcomes remain unknown" |
| — epoch never rewrites the Job | `Sources/ArkDeckStorage/RecoveryCoordination.swift:93-96` | `SupersedingRecoveryEpoch` doc | "Covered intents remain outcomeUnknown in their own journals; admission consults this independent relation instead of rewriting or guessing their historical result." |

The descriptive half of decision 2 ("must not be described as recoverable") survives in three
independent places — the recovery timeline (1a), the agent client classification and the CLI exit
status (1b) — although the writer the ADR named is gone.

## 2. Decision 4 — existing proofs are never discarded

| Carrier | Function | Decisive statement |
| --- | --- | --- |
| `RuntimeJobEngine.swift:789` and `6714-6721` | `confirmedNotExecutedSemanticCode`; `finishReconcile` `.confirmedNotExecuted` | the reconciled outcome is journaled with this semantic code — the literal decision-4 change of the ADR, still in place; the same code at the two other producing sites (3951–3967, 4365–4394) |
| `RuntimeJobEngine.swift:7132-7164` | `repairTerminalSafeToReflashLineageIfNeeded` | reads the proof back by `semanticCode == confirmedNotExecuted` and `outcomeCertainty == confirmed`, then upgrades the lineage to `.safeToReflash` |
| `RuntimeJobEngine.swift:7189-7217` | `repairProvablyTerminalCapabilityOutcomeGaps(targetID:bindingRevision:)` | "The Job record becomes durable before the independently durable capability outcome, so ENOSPC or process loss can leave the former complete and the latter pending." — a lost proof is recovered, not dropped |
| `Sources/ArkDeckStorage/RuntimeCapabilityStore.swift:1-16` | file header | "Every use appends a hash-linked execution node."; every write atomic under flock, "never a torn one" |
| `RuntimeCapabilityStore.swift:509-543` | `recordOutcome(...)` | the only permitted rewrite is `resolvesUnknown` (`outcomeUnknown → .confirmed/.safeToReflash`, 513–519); anything else throws `outcomeConflict`; outcomes are appended (538), never replaced |
| `RuntimeCapabilityStore.swift:845-870` | `loadLedgerEvents()` | "A final line without its newline is a torn append: the write never completed, so the event never happened and the tail is dropped rather than guessed at." |
| `RuntimeCapabilityStore.swift:1029-1066` | `appendEvent(_:resultingIn:)` | `O_WRONLY \| O_APPEND \| O_CREAT` + full sync: "A use that survived a crash unrecorded would be a use nothing accounted for." |
| `RecoveryCoordination.swift:93-129` | `SupersedingRecoveryEpoch` | "An append-only relation proving that a later complete overwrite established a known target epoch." — hash-chained through `previousEpochSHA256`/`epochSHA256` |
| `RecoveryCoordination.swift:185-253` | `RuntimeSupersedingRecoveryStore.append(_:)` | an identical draft returns the existing epoch (192–200); a differing one throws `conflictingEpoch` — no overwrite |
| `RecoveryCoordination.swift:274-300` | `load()` | "recovery epoch hash chain is invalid at …" — a tampered or truncated chain fails closed |
| `RuntimeJobEngine.swift:5610-5620` | `isCurrentJob(_:)` | an `outcomeUnknown` Job stays current unless an epoch or alias resolution exists |
| `RuntimeJobEngine.swift:5622-5634` | `activeSessionIDsForRetention()` | "Session retention treats every nonterminal or outcome-unknown Runtime Job as an active lease." |
| `RuntimeJobEngine.swift:1236-1254` | `quarantinedJobRecords` / `unreadableDurableRecords` | "dropping it from the active set is what would let the retention sweep reclaim the very evidence an operator needs" |
| `RuntimeRecoveryService.swift:199-213` and `283-288` | `unresolvedDestructiveIntents(...)` | an unreadable historical record blocks the overwrite proof ("Walking past it in silence would let the proof be assembled with a hole in it, so it refuses instead."); "The absence of that intent is never treated as proof that no effect happened" |
| `RuntimeJobEngine.swift:8588-8616` | lineage gate before a new execution | unresolved rows (`!= .confirmed && != .safeToReflash`) block a new use unless a durable epoch covers them |
| `RuntimeJobEngine.swift:5169-5198`, `6618-6626`, `7055-7077` | zero-dispatch proofs | "never-started job closed with zero dispatch"; compensation resumed after identity proof "confirmed; zero dispatch"; "a drained cancellation is one the engine proved did not dispatch" |
| `Sources/ArkDeckStorage/RecoveryManifestContract.swift:4-33, 35-60`; `JournalReplay.swift:1071-1080` | recovery manifests | `outcomeCertainty ∈ {confirmed, outcomeUnknown}`; a guessed `known` device mode refuses to decode; hazards derive only from `unknownOutcomes` with `effect >= .deviceMutation` |

## 3. Contract tests that pin the carriers (`Tests/ArkDeckContractTests/`)

- `RuntimeJobEngineContractTests.swift`: `testOutcomeUnknownParksAndReconcileClears` (1784; asserts
  "reconcile never redispatches" at 1804 and `semanticCode == "confirmedNotExecuted"` at 1825–1827 —
  the direct decision-4 pin), `testCrashWindowsPreserveUnknownOutcomeAndNeverRedispatch` (2023),
  `testTerminalLineageRepairsWithoutRedispatchForReconcileAndNextSubmit` (1830),
  `testMutationOutcomeUnknownBlocksNewExecutionAcrossDaemonRecovery` (1444),
  `testDaemonRecoveryReopensOnlyActiveJobsWhileTerminalHistoryStaysQueryable` (951),
  `testARecordThisBuildCannotReadIsQuarantinedRatherThanTakingRecoveryDown` (1135),
  `testQuietCrashInLanelessStatesRecoversToHonestTerminalState` (2112).
- `CompleteOverwriteRecoveryContractTests.swift`:
  `testRecoveryStoreIsAppendOnlyIdempotentAndRejectsConflictingProof` (399),
  `testRecoveryStoreRejectsTamperedHashChain` (436),
  `testCompleteLaterFlashHistoryAppendsSupersessionWithoutChangingUnknownJobs` (456),
  `testJournalUncertaintyCannotBeHiddenByAStaleRecordProjection` (522),
  `testCleanRunningArkForgeExecutionParksUnknownWithoutRedispatch` (576),
  `testANamedHardwareAcceptanceCampaignAdmitsRecoveryAfterTheSharedFourHourBudget` (685, DEC-016),
  `testRecoveryNegativeMatrixBlocksCoverageCancellationExpiryAndAttemptSeventeen` (622),
  `testSupersededUnknownPresentationIsTruthfulButNoLongerNeedsAttention` (1264),
  `testMissingOrInvalidDaemonProofNeverFallsBackToBuildReadbackAcrossRestarts` (1111).
- `JournalRecoveryContractTests.swift`: `testDurableUnknownOutcomeForcesFailClosedDispatchAndHazards`
  (504), `testMacOSCrashWindowMatrixPreservesUnknownOutcomeAndZeroDeviceDispatch` (535),
  `testOutstandingExternalIntentCannotBeFinalizedOrHiddenFromRecovery` (583),
  `testTornTailIsIgnoredButForcesExplicitRecovery` (318),
  `testManifestRecoveryAndHazardUseTheLockedRequiredNullableShape` (439).
- `RuntimeCapabilityStoreContractTests.swift`:
  `testPendingAndOutcomeUnknownBlockDifferentReservationWithoutConsuming` (332),
  `testDedicatedReadbackCanResolveUnknownWithoutASecondConsumption` (588),
  `testDedicatedReadbackCanResolveUnknownAsSafeToReflash` (612),
  `testConfirmedOutcomeCreatesHashLinkedAuthorizationLineage` (373),
  `testTamperedLineageDigestFailsClosed` (941),
  `testMissingCheckpointBesideLedgerCannotBecomeEmptyAuthority` (1025),
  `testOldV1ShapeAndUnknownNestedFieldsCannotResetCapabilityUses` (978).
- `RuntimeCLIExitStatusContractTests.swift`: `testAnUnknownOutcomeGetsItsOwnStatusAndOutranksTheState`
  (45; its doc comment cites POL-RECOVERY-001).
- `DiagnosticsAndHAPContractTests.swift`:
  `testEachUnknownCompensationReconcilesWithoutResendingOrLosingOriginalFailure` (2723),
  `testConfirmedDiagnosticNonExecutionFinalizesOnlyDeclaredCompensations` (2679),
  `testCompensationIdentityWaitTransitionCrashRestoresExplicitReconciliation` (2970),
  `testHistoricalFinalizingJobWithoutDeclarationsNeverBackfillsCompensation` (3180),
  `testAgentResumeReadsUnknownCompensationAndFailedResultWithoutNewDispatch` (4377).
- `JobReadResourcesContractTests.swift`: `testUnknownOutcomeRemainsReconcileAndSuccessfulStatusQuery`
  (1372).

These are the oracles the Rust port replays (T0 for the durable files they write, T1 for the
transitions and refusals they assert).

## 4. What Rust already mirrors (`rust/crates/arkdeck-hoststore/src/`)

- `job_run.rs:617-633` `park(...)`: failure `("outcomeUnknown", "unknownOutcome",
  "runtimeDecisionRequired", "awaitRuntimeReconciliation")`, transition to `waitingForRecovery`,
  `set_outcome_unknown()`, persist — the Swift park exactly.
- `job_run.rs:482-489`: `Dispatch::OutcomeUnknown` leaves the intent outstanding ("no outcome is
  invented, and recovery alone may resolve it by readback"); `466-481` and `500-509` park the
  undrained-cancellation and raced-completion lanes rather than claim a result; `237` guards on
  `!record.outcome_unknown()`.
- `job_record.rs:492-499` `set_outcome_unknown()` / `outcome_unknown()`; unknown durable fields refused.
- `job_cancel.rs:1-3, 236-255`: "A Job that never started closes with zero dispatch" (mirrors
  `RuntimeJobEngine.swift:5174-5183`).
- `job_journal_replay.rs:337-353, 392-419, 428-444, 639-641`: `has_torn_tail`,
  `outstanding_intents`, `unknown_outcomes`, `requires_unknown_finalized_outcome`; a torn tail is
  "reported but never interpreted"; device-mutation hazards derive from unknowns.
- `job_journal_writer.rs:21-28, 149-150`: `JournalAppendError::OutcomeUnknown`.

No Rust mirror exists yet for the capability ledger's `recordOutcome` rule, the superseding-recovery
relation or `finishReconcile`; those are exactly the parts the ruling unblocks.

## 5. Symbols the ADR relies on that have no carrier today

1. `AgentAuthorityUsageTerminal` — zero hits in `Sources/`. The ledger invariant of the ADR's fact 5
   (refusing a non-empty `confirmedNotExecutedIntentEventIDs` when `status != .failed`), which the
   ADR's "not done" section relies on to keep the `outcomeUnknown + confirmedNotExecuted` shape
   unconstructible, has no direct successor; the nearest equivalent is
   `RuntimeCapabilityStore.recordOutcome`'s `resolvesUnknown` guard (513–519), which restricts
   transitions but not that field-level shape.
2. `confirmedNotExecutedIntentEventIDs` — zero hits in `Sources/`. The proof is now the journal
   `semanticCode` on the step outcome (`RuntimeJobEngine.swift:789`, `6719`) plus the
   `.safeToReflash` lineage outcome, not an ID set on a usage terminal.
3. `mutationIntentEvidence` — zero hits in `Sources/`; survives as a test comment at
   `RuntimeJobEngineContractTests.swift:1807`. The reader the ADR says "only recognises this code"
   is today `hasCompleteMutationNonExecutionProof` (7170–7187) and the scan at 7132–7139. The
   producer side of decision 4 is pinned by a test whose named consumer no longer exists; if the
   maintainer wants decision 4 traceable by symbol, this comment or the concept should be renamed.
4. Decision 5's `attemptTerminal.detail` — no `attemptTerminal` symbol exists. The nearest surviving
   record is the `evidence: [detail]` array on `JournalEvent.reconcileOutcome`
   (`RuntimeJobEngine.swift:6740-6745`, details at 6713/6728/6735); a different record on a
   different event, so it is flagged here as unclear rather than claimed as a carrier.

## 6. What the ruling unblocks in TASK-XPA-014

Porting `RuntimeRecoveryService.replay` and `recover(records:)` (restart carry-over of parked Jobs,
design §G.4), `job.reconcile` with `finishReconcile`'s three outcomes, the capability ledger's
`recordOutcome` rule, `RuntimeSupersedingRecoveryStore` and `completeOverwriteAdmission` (DEC-016)
— in that order, each against the tests of §3 as oracle. Until then the Rust owner keeps refusing
resumable Jobs, `job.reconcile` and recovery epochs, as every TASK-XPA-014 run record since
2026-09-14 states.

## Ruling

Recorded 2026-09-19 against protected main `9c58e484`. The Repo Agent wrote this section from the
maintainer's instruction; merging it is the maintainer's attestation of the record.

- **Date:** 2026-09-19.
- **Ruled by:** lvye (maintainer), on design §L.1 item 13.
- **Ruling:** 「按本包点名的承载代码原样移植」: port recovery exactly as the carrier code this
  package names.

This adopts the proposed ruling above. ADR-0009 decisions 2 and 4 bind the current runtime. What
carries them is what §1 and §2 name. The Rust port reproduces those carriers unchanged (T0 for the
durable formats, T1 for the transitions and refusals), adds no recovery semantics of its own, and
keeps the four symbols of §5 missing. The carrier tables above are kept exactly as prepared and
are the binding list:

| Decision | Carrier tables | Oracles |
| --- | --- | --- |
| 2: a crashed attempt stays `outcomeUnknown` and is never described or treated as recoverable | §1a (classification and park), §1b (refusal to replay or re-dispatch), §1c (the only sanctioned exits) | §3 |
| 4: an existing proof is never discarded | §2 | §3 |

§5 stays a list of flagged gaps. None of its four items is ruled a carrier, and the port neither
revives nor renames them.

Line numbers remain those of `6cf99fb6`. Between that commit and `9c58e484` the named Swift
sources changed only by one added first line: `import ArkDeckClientKit` in
`RuntimeJobEngine.swift`, `AgentDaemon.swift` and `DebugApplicationFacade.swift`, and
`@testable import ArkDeckClientKit` in `CompleteOverwriteRecoveryContractTests.swift` and
`JobReadResourcesContractTests.swift`. A line cited in those five files is one higher on
`9c58e484`; every other named source and test file is byte-identical.

### Port order (TASK-XPA-014)

Each slice reads the carriers it ports from the tables above and records itself in
`runs/TASK-XPA-014/recovery-<slice>-run.md`.

1. Recovery manifests and `RecoveryManifestContract` (the last row of §2): T0 format, the exact
   Swift key set, and read-back by the Swift strict validator.
2. Recoverable Job classification and `job.reconcile` with `finishReconcile`'s three outcomes
   (§1a, §1b, §1c and the first two rows of §2).
3. The superseding recovery epoch relation (`RecoveryCoordination.swift` in §1c and §2): append-only,
   hash-chained, continuing from the highest existing ordinal.
4. The design §G.4 preflight predicate table, shared by `runtime service restart` carry-over (M1)
   and the M5 preflight.

The recovered row of `cleanupDebt.continue`, `debug.start/status/evaluate` (the Flash recovery
broker) and DEC-016's `completeOverwriteAdmission` follow in M2/M4, after these four.
