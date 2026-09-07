# job.evidence lost every fact when one fact was underivable — 2026-09-07

Defect fix filed under `TASK-SVC-001` after the Task reached `done`, on the
precedent of #1749 under this Task and #1744/#1746/#1747/#1748 under
`TASK-SVC-002`. No `Allowed paths` were widened: the daemon read surface, the
client evidence reader and `RuntimeHistoryApplicationFacade.swift` are all
already declared by this Task.

## What was observed

The 2026-09-07 GJ-4 window left `job-c9274a31cb5ba7c8aad61451416af4f4`
(`flash.full-restore@1`) in `waitingForRecovery` / `outcomeUnknown`. Asking the
running daemon for its evidence answered with a decodable-by-nobody shape:

```
$ arkdeck job evidence --job job-c9274a31cb5ba7c8aad61451416af4f4 --json
  "actualStepKinds" : null,
  "providerId" : null,
  "executionMode" : null,
  "actualEffect" : null,   "authority" : null,   "observation" : null,
  "bindingRevision" : null, "startedAtUtc" : null, "parameters" : null,
  "blockers" : [ "artifactIntegrityFailed", "recordUnreadable", "resultNotReady" ],
  "terminalState" : "outcomeUnknown",
  "operationReference" : "flash.full-restore@1"
```

`RuntimeHardwareEvidenceTrustedFacts` declares `providerID`, `executionMode`
and `actualStepKinds` non-optional, so `AgentRuntimeExecutor` could only record
`trustedEvidenceQuery:DecodingError…`, and `RuntimeHistoryApplicationFacade`
could only answer `"Job evidence did not match the selected Job"` — a statement
about identity that was not true.

The Runtime had in fact recorded the terminal reason. It was in
`Agentd/jobs/<jobId>/journal.jsonl` and reachable only by reading that file by
hand:

```
reconcileOutcome  evidence: ["lane postflight did not verify: failed(\"verified
  post-flash HDC binding could not be persisted: productionConfigurationUnavailable
  (\\\"post-flash binding changed before verified alias publication\\\")\")"]
```

## Root cause

`RuntimeJobEngine.evidenceSnapshot` derives the typed step kinds through
`durableActualStepKinds`, which for a Flash operation refused with a `throw`
when the journal was not closed (`RuntimeJobEngine.swift`, the
`persisted Flash journal is not closed` guard). An `outcomeUnknown` Flash Job
is exactly the Job whose journal is not closed, so the derivation refused for
the whole class of Jobs an operator most needs to inspect — and the refusal
threw away the entire snapshot, including the ~12 facts that sit on the durable
record and were readable the whole time. `RuntimeJobResourceReader` caught the
throw and published its degraded shape, which nulled `providerId` and
`executionMode` even though the record it builds that shape from carries both.

Same family as #1744/#1746/#1747/#1748: a legitimately-absent value meets a
reader that cannot express absence, and the absence is widened into a failure
of everything around it.

## Fix

- `RuntimeJobEvidenceSnapshot.actualStepKinds` is `[String]?`.
  `durableActualStepKinds` returns `nil` — never a partial list — when durable
  state cannot prove the steps, and no longer throws. Every other fact in the
  snapshot is published as before.
- `AgentDaemon.encodeEvidence` publishes that `nil` as an explicit `null`.
- `RuntimeJobResourceReader`'s degraded shape publishes `providerId` from the
  record it already holds and `executionMode` from the new shared
  `RuntimeJobEvidenceSnapshot.persistedExecutionMode`, which also replaces the
  literal in `evidenceSnapshot` so the two cannot drift.
- `RuntimeHardwareEvidenceTrustedFacts.actualStepKinds` is `[String]?`.
  `HeadlessRuntimeVerifier` fails `runtimePostflightVerified` on `nil` exactly
  as it does on an incomplete set: unknown steps are not verified steps.
- `RuntimeHistoryApplicationFacade` separates "this envelope is for another
  Job" from "this envelope is missing facts the Runtime must publish", and
  carries `actualStepKindsWereReported` beside the list so an empty list is not
  read as a claim that nothing ran. The field is additive, following the
  `parametersWereReported` precedent in the same struct.

## Verification

- `JobReadResourcesContractTests.testAFlashJobWithAnUnprovableJournalStillPublishesTheFactsItHolds`
  — the fixture writes a real `journal.jsonl` through `FileDurableJournal`
  (`jobCreated` → `preflight` → `running` → a destructive `flashPartition`
  `stepIntent` with no outcome → `waitingForRecovery`) and asserts the journal
  is genuinely unclosed before the read. The Job publishes
  `providerId`/`executionMode`/`terminalState`/`targetId`, publishes
  `actualStepKinds` as `null`, and the real client decoder
  (`CurrentRuntimeResourceReads.evidence`) accepts it. Negative control: an
  ordinary Job still publishes its step kinds as an array.
- `JobReadResourcesContractTests.testTheDegradedEvidenceReadPublishesWhatTheRecordAlreadyProves`
  — the degraded path is reached by corrupting
  `superseding-recovery-epochs.json` (the Job record beside it stays readable);
  it publishes the record's provider and execution mode and decodes. Negative
  control: with the document readable the full snapshot answers instead.
- `RuntimeHistoryApplicationContractTests.testMissingPublishedFactsAreNotReportedAsAJobIdentityMismatch`
  — unknown steps stay available with `actualStepKindsWereReported == false`; a
  missing `providerId` says so; negative control: a foreign `jobId` still
  reports an identity mismatch.
- `AgentRuntimeExecutorContractTests` — added the `stepKinds: nil` case to the
  existing reopen-report fixture; it fails closed like the incomplete set.
- Unified gate: `python3 scripts/ci/plan.py --repo-root . --base-revision
  origin/main --head-revision HEAD --merge-base --include-worktree --run-local`.
- Every new assertion was checked against the pre-fix behaviour before it was
  kept. The first attempt at the Flash fixture was wrong and the negative
  control is what caught it: it wrote no journal at all, so it exercised the
  unreadable-journal branch and still passed with the not-closed branch
  reverted. With a real unclosed journal in place, reverting only
  `return nil` → `return storedKinds` fails it on `actualStepKinds` — which
  also proves the fixture reaches the branch this change is about. Reverting
  the reader's two fields fails the degraded-read test with the field's own
  `DecodingError.valueNotFound … Path: providerId`, the same error the shipped
  build produced; reverting the facade's split guard fails the History test on
  the identity message.

## Residuals

1. `spec/control/methods/job.evidence.json` publishes `providerId`,
   `executionMode` and `actualStepKinds` as non-nullable and required. The
   daemon already emitted `null` for all three before this change (the capture
   above is from the shipped build), so the schema was already wrong about a
   reachable shape; this change removes two of the three violations and leaves
   `actualStepKinds: null` as a deliberate one. Correcting the schema needs a
   recorded fallback frame and a re-derivation, and `spec/control/methods/**`
   is not declared by `TASK-SVC-001`. Owner: whoever holds `TASK-SVC-002` /
   `TASK-XPA-001`.
2. `AgentRuntimeExecutor.receipt` still collapses unknown steps to `[]` in the
   persisted `RuntimeAgentExecutionReceipt`. It is fail-closed downstream
   (`HardwareEvidenceProjector` rejects an empty `stepKinds`, and
   `HeadlessRuntimeVerifier` requires a superset), but a reader of the receipt
   alone cannot tell "unknown" from "none" — which is how this session first
   mis-read the GJ-4 attempt as "no partition was written". Making the receipt
   field optional changes a persisted document shape and deserves its own PR.
3. `ArkDeckApp/Features/History/RuntimeHistoryView.swift` renders the step
   kinds behind `!isEmpty` and does not yet read
   `actualStepKindsWereReported`, so the App still shows unknown steps as an
   absent section. `ArkDeckApp/**` is not declared by this Task.
4. The GJ-4 blocker itself is untouched here: `lane postflight did not verify:
   post-flash binding changed before verified alias publication`. This change
   is what makes that reason reach a published surface instead of only the
   on-disk journal.
