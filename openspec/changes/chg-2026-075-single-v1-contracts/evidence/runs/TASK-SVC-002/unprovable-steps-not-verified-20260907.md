# A Job whose typed steps cannot be proven was published as verified — 2026-09-07

Filed under `TASK-SVC-002` (declares `ArkDeckAgentDaemon/**`,
`spec/control/methods/**`, `Tests/ArkDeckContractTests/**` and the change dir),
on the precedent of #1744/#1746/#1747/#1748/#1761.

## Two corrections to the residuals recorded in #1760

Both were wrong, and an adversarial review of the proposed follow-up caught
them before any code was written.

1. **"the persisted `RuntimeAgentExecutionReceipt`" — it is not persisted.**
   Nothing in the repository writes or decodes a receipt
   (`rg 'RuntimeAgentExecutionReceipt.self'` → 0 hits). Its only exit is a bare
   `JSONEncoder()` to CLI stdout. The pause path persists `PendingExecution`,
   which holds no receipt.
2. **"it is fail-closed downstream" — it is not.** There are four reads of
   `receipt.stepKinds`. Three are in `HardwareEvidenceProjector`, which has
   **zero production callers** (`rg -g '!*Tests*'` finds only its declaration at
   HardwareEvidenceProjector.swift:448). The fourth,
   HeadlessRuntimeVerifier.swift:641, sits in `report(...)` whose first
   predicate is `receipt.operationReference == "observe.device@1"` (:135) —
   while `actualStepKinds` can only be nil for ArkForge flash operations
   (RuntimeJobEngine.swift:5052-5056 returns an array for everything else). The
   one live check is structurally unable to see the receipt that can be wrong.

## The defect this change fixes

With no consumer refusing it, an unprovable step list rode inside an accepted
document. `blockers` never carried the fact, so:

- `RuntimeJobResourceReader` chose `reason = "verified"`
  (the `else` of the ladder at :144-149), and
- `AgentDaemon.executionResultProjection` chose
  `evidence["status"] = blockers.isEmpty ? "verified" : "blocked"` (:2950),

which means a **destructive** Job whose write could not be proven answered
`status: "verified"` with `blockers: []`. The CLI's own integrity gate
`RuntimeCLI.evidenceIntegrityExit` (ArkDeckRuntimeCommands.swift:3177) reads
**only** `blockers`, so it returned nil and the command exited 0.

Separately, the published schemas of `job.result`, `agent.run` and
`agent.status` declared the embedded `evidence.actualStepKinds` as a
non-nullable array, while the daemon has answered `null` there since #1760.
#1761 did not close this: its recorded run drove no unprovable Job through
those methods, so the corpus held no such frame and the derivation could not
publish the shape — the same silence that hid the original defect.

## Change

- One shared blocker, `RuntimeJobResourceReader.stepKindsUnprovable`, named once
  and inserted by both producers of this fact: the Job read surface and the
  Agent execution projection. `blockers` is an open array of strings in every
  published schema, so this widens no shape.
- The reader's status ladder gains a branch, so an unprovable Job reports
  `stepKindsUnprovable` instead of `verified`. The Agent projection needs no
  ladder change: a non-empty blocker list already makes it `blocked`.
- Re-recorded and re-derived: `spec/control/methods/job.result.json` now
  declares `evidence.actualStepKinds` as `anyOf` array|null.

Bounded by construction: `durableActualStepKinds` returns an array for every
non-ArkForge operation, so the new blocker cannot fire outside flash
operations, and GJ-1 (`observe.device@1`) is untouched.

## Verification

- `JobReadResourcesContractTests.testAJobWhoseTypedStepsAreUnprovableIsNotAVerifiedResult`
  — a terminal Flash Job whose journal is gone publishes
  `actualStepKinds: null`, carries `stepKindsUnprovable`, is **not** `verified`,
  and makes `RuntimeCLI.evidenceIntegrityExit` non-nil. Negative control in the
  same test: an ordinary Job with proven steps stays an array, carries no such
  blocker, stays `verified`, and exits clean.
- Removing only the blocker insertion fails that test.
- The fixture documents an invariant worth keeping: a terminal Job **cannot**
  carry an unresolved intent — the journal refuses it outright
  (`unresolved intent cannot enter finalization or terminal state`). So on a
  terminal Job the only route to unprovable steps is a journal that is gone,
  and the fixture leaves none. The unclosed-journal route stays covered by the
  `waitingForRecovery` fixture added in #1760.
- 49 of the 51 corpus files a raw re-derivation rewrites were compared by the
  generator's own `signature()` fingerprint, found shape-identical, and
  reverted, exactly as in #1761. Only `job.result.jsonl` gained a shape.
  `agent.status.json` and `health.json` moved only in `x-arkdeck-sampleCounts`.
- Full package suite and the unified gate: see the PR.

## Residuals

1. `agent.run` and `agent.status` still declare `evidence.actualStepKinds`
   non-nullable. Their **behaviour** is fixed here (the projection now emits the
   blocker), but publishing the null branch needs a recorded frame, which needs
   an agent-execution fixture whose Job is a terminal Flash Job with no journal.
   `executionResultProjection` (AgentDaemon.swift:2919) only needs an execution
   record carrying that `jobId`, so the fixture is the whole cost.
2. `RuntimeJobReadProjection.show` (:140) publishes
   `record.actualStepKinds ?? []` while five neighbours in the same literal
   spell `?? .null`. Production never stores an empty array (the only writer,
   RuntimeJobEngine.swift:3902-3905, always appends at least one element), so a
   published `[]` there is always the collapse and never a recorded fact. A
   scan of 1,897 real job records found 38 with the key absent and 0 with an
   empty array; 27 of the 38 coexist with durable work, including 25 flash Jobs
   whose steps ran inside the ArkForge lane and 6 that reconciled to
   "lane postflight verified the flashed device". `job.show` reports all of
   them as `[]`.
3. Deeper than (2): `job.show` is a pure record projection
   (RuntimeJobResourceReader.swift:30) and never calls `durableActualStepKinds`,
   so it cannot see steps the ArkForge lane ran. This is documented in-tree at
   RuntimeJobEngine.swift:5033-5042. Either plumb the derivation into `job.show`
   or have it defer to the `evidence` pointer it already publishes.
4. `durableActualStepKinds` returns `record.actualStepKinds ?? []` for every
   non-ArkForge operation (RuntimeJobEngine.swift:5053-5056), so the same
   collapse survives on `job.evidence` for those.
5. `ArkDeckApp/Features/History/RuntimeHistoryView.swift:947` still branches on
   `!isEmpty` and ignores `actualStepKindsWereReported`. `ArkDeckApp/**` is
   declared by no SVC Task in this change.
6. The GJ-4 blocker itself — `post-flash binding changed before verified alias
   publication` — remains untouched.
