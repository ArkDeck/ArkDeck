# TASK-XPA-014 — the HDC restart lifecycle a foreground console approves, recorded from Swift's daemon (macOS, 2026-09-20)

TASK-XPA-014 remains in progress. Base: protected main `5c9075c5`; no stack (recorded on
`88248f67` and rebased onto `5c9075c5`, which touches none of this slice's files). Every answer
here comes from a synthetic host composition in a contract test over the Swift fake HDC
(`ArkDeckFakeHDCFixture`); nothing is device evidence (POL-VERIFY-001, POL-MODE-001). No production
Swift or Rust source, Catalog, entitlement, `openspec/specs` or constitution change. One Rust test
changes (below).

This is the Swift-only frames slice C2b needs. C2a (#2074) left the Rust daemon answering
`runtime.hdc.restart` up to the `awaitingImpactApproval` record and serving that approval through
the reads; its run record's item 6 lists what the corpora do not show, and an unrecorded shape
becomes `internalError` through the Rust control layer's outbound check. This slice records what
Swift's daemon answers **after** the approval is minted — the foreground console's challenge, its
receipt, and every durable boundary the lifecycle passes — and widens only the schemas those
answers need.

## Already on main / this slice / still remaining

| Already on main | This slice | Still remaining (C2b) |
| --- | --- | --- |
| The with-host answers of the reads and of `runtime.hdc.restart` up to the approval, and their schemas (#2012, #2037, #2052); the Rust HDC owner, its routes and the approval it mints (C1 #2017, C2a #2074); the combined human-action owner (#1953, #1969) | Five Swift tests through the handler, composed as `main.swift` composes it and now also over Swift's own lifecycle chain: the foreground console's challenge and its receipt, the record at `approvalRecorded`, `dispatchPrepared` and `dispatching`, the three outcomes with their dispatch count, each read, reconciled and listed, the resolved approval, the Job-admission interlock in both directions, a console answer that is wrong or too late, and a preview of another server generation | C2b: the Rust console challenge and receipt, the lifecycle executor and its audit, the supervisor, the Job interlock and the recovery of an interrupted lifecycle (design §L.1 item 13) |

## What Swift does (the map this slice records)

Line numbers are on the base.

- **The route** (`AgentDaemon.swift:3114-3166`). `human-action.resume` of an approval takes exactly
  `{resumeReference, humanAction}` and optionally `challengeResponse`; a `selection` is
  `invalidInput`. **Only** a request whose transport is the Unix socket *and* whose peer is a
  foreground console reaches the challenge: without `challengeResponse` the owner issues one, with
  it the owner consumes it. Every other origin — `.direct`, `.appXPC`, a redirected or background
  console — gets the same approval back and advances nothing. That is a silent no-op by design,
  not a refusal, and the corpus already holds it.
- **Issuing** (`HDCControlActionCoordinator.swift:144-183`): the approval must still be waiting,
  else `humanActionExpired`; the plaintext is `ARKDECK-` plus 9 upper-case alphanumerics, the
  record keeps only its digest, and the challenge closes at `min(the action's expiry, now + 120 s)`
  (`HDCControlActionRecord.issuingInteractiveChallenge`, 351-370). The answer is
  `arkdeck.impact-approval-challenge/1`: the plaintext, its identity and expiry, the approval, the
  control action as it now is, the binding, and `newDispatchCount: 0`. Issuing advances the
  action's generation and leaves it `awaitingImpactApproval`.
- **Consuming** (`HDCControlActionCoordinator.swift:185-252`), in this order: the response's shape
  and a composed lifecycle driver (else `admissionDenied`); the action still awaiting this
  challenge (else `humanActionExpired`); **the Runtime's final Job interlock**
  (`RuntimeJobEngine.acquireHDCLifecycleInterlock`, 5546-5567: `resourceConflict` when another
  lifecycle holds it, `factsDrifted` "current Runtime Jobs block the HDC lifecycle action" when any
  Job is current); one fresh reading, which must still be the reviewed impact (else the action is
  invalidated and the answer is `factsDrifted`); the receipt
  (`recordingInteractiveApproval`, 389-409 — `impactApprovalChallengeMismatch` for another
  plaintext, `impactApprovalChallengeExpired` after the challenge closed), which moves the record
  to `approvalRecorded` and resolves the approval; then the driver, whose terminal record must be
  `succeeded`, `failed` or `outcomeUnknown`; then the interlock is released.
- **The boundaries** (`HDCControlActionRecord.appendingLifecycleAudit`, 411-435 and
  `state(afterAppending:prior:)`, 469-487). Each audit entry advances the generation:
  `impactPreview` and `confirmation` keep `approvalRecorded`, `intent` and `actualCommand` make
  `dispatchPrepared`, `launchWindowEntered` makes `dispatching` and is the only thing that makes
  `dispatchCount` 1, and the `outcome` and its `reconciliation` settle the state. `succeeded`
  clears the blocker and answers `nextAction.kind: none`; `failed` is
  `hdc.lifecycleFailedBeforeLaunch` with `none`; `outcomeUnknown` is `hdc.lifecycleOutcomeUnknown`
  with `reconcile`.
- **While a lifecycle holds the interlock** (`RuntimeJobEngine.swift:1772-1776, 1878-1882) no Job
  may be admitted: `job.submit` is `resourceConflict` "a confirmed host-wide HDC lifecycle action
  currently blocks new Job admission". The guard sits before plan materialization, on both sides of
  the actor-reentrancy window.
- **The executor** (`HDCProduction.swift:1164-1355`). The durable authorization is consumed before
  the child (a refused one is a definite `failed` before any launch), the launch window is
  persisted before `posix_spawn`, and only then is `hdc -s <endpoint> kill -r` run. After it: a
  nonzero exit, a registered failure line, unregistered stderr, an unavailable probe or a
  generation that is not strictly newer are all `outcomeUnknown`; only a strictly newer generation
  is `succeeded`.

## The tests

**The composition.** `ControlActionWithHostContractTests` composes each daemon start as
`ArkDeckAgentDaemonMain` does once `HeadlessHDCServerHost` started (#2012, #2052): the HDC
control-action owner with a fresh epoch over the production impact source, the union owner, the
AgentExecution owner and the human-action union over both. This slice adds three things:

1. **A lifecycle driver** (`Lifecycle`), composed into the owner as `main.swift` composes
   `HeadlessHDCControlLifecycleDriver`. It is that driver with the two observations only the
   registered 3.2.0d executable and its live server could answer replaced by the approved facts,
   exactly as `RegisteredHealthyServer` replaces the health proof for the preview:
   `observeRegisteredExistingServer` (a commandless identity, a `checkserver`, the identity again —
   refused for every digest but the registered one) becomes the approved reading's own generation
   and ownership applied to the Supervisor, and the 12-second post-dispatch re-observation becomes
   a fixed answer. **Everything between is production**: the Runtime's own Job-admission interlock
   (`RuntimeHDCLifecycleInterlockOwner` over `RuntimeJobEngine`), the Supervisor's participant
   inventory, impact preview, confirmation and dispatch, the real `HDCProcessLifecycleExecutor` —
   which really launches `<the fixture HDC> -s 127.0.0.1:8710 kill -r` and classifies its exit
   through `HDCRegisteredSemanticProfile.testOnlyFake` — and the control action's own durable
   lifecycle audit. The fake's `kill` behaviour is its `ARKDECK_FAKE_HDC_LIFECYCLE_MODE` seam, and
   every invocation is asserted from its argv log.
2. **The request context.** The recorder now sends a frame through
   `handleLine(_:context:)`, so a test can be the foreground console
   (`.unixSocket(foregroundConsole: true)`) the challenge routes require.
3. **Two read hooks** — one before the nth reading of the impact source, one while the dispatch
   runs — so the durable record can be read back through the routes at a boundary only a running
   lifecycle reaches. The owner and the union owner are actors suspended at their `await`, so these
   reads interleave exactly as a second socket client's would.

The engine also gains the observation provider and the Artifact store `main.swift` composes, so a
`job.submit` reaches the Runtime's durable admission. No Job is ever admitted through the interlock
and none is dispatched.

| Test | What it records |
| --- | --- |
| `testAForegroundConsoleApprovalRestartsTheServerThroughTheLifecycleDriver` | the ready preview and its approval; the console's `human-action.resume` → the challenge (its members, its binding, the action still awaiting at generation 4); the answer → the terminal record. Read back at each boundary: `approvalRecorded` (generation 5, dispatch 0), `dispatchPrepared` (8, 0), `dispatching` (10, **1**), then `succeeded` (12, 1, blocker null, `nextAction.kind: none`), its approval `resolved`. `show`, `reconcile` (no observation), `list` whole and by `state: succeeded`; `human-action.show` and `.list` of the resolved approval. The fake was launched exactly once, with `-s 127.0.0.1:8710 kill -r`. A restart of the terminal action is `admissionDenied` |
| `testALifecycleWithoutAProvenNewGenerationOrALaunchIsUnknownOrFailed` | three more outcomes on their own hosts: a probe that proves no newer generation → `outcomeUnknown` (12, 1, `hdc.lifecycleOutcomeUnknown`, `nextAction.kind: reconcile`); a child that exits 23 after the launch window → the same state, never a proven failure; and an impact that drifts before the executor's durable authorization → `failed` (9, **0**, `hdc.lifecycleFailedBeforeLaunch`, `none`) with nothing launched. The stale and failed records are shown, reconciled, listed by their state and their approvals served |
| `testAConfirmedLifecycleBlocksNewJobAdmissionAndCurrentJobsBlockIt` | while the confirmed lifecycle holds the interlock, `job.submit` of `observe.device@1` is `resourceConflict` "a confirmed host-wide HDC lifecycle action currently blocks new Job admission" and `job.run` of an absent Job answers exactly as it does without the interlock. The other side, on its own host: a Job admitted after the challenge was issued makes the console's answer `factsDrifted` "current Runtime Jobs block the HDC lifecycle action" — nothing ran, and the action stays awaiting with a waiting approval |
| `testAConsoleAnswerThatIsNotTheChallengeOrIsTooLateNeverApproves` | a well-formed answer that is not the issued plaintext → `impactApprovalChallengeMismatch`, the action still awaiting and the one-time challenge not consumed; 121 s later the right plaintext → `impactApprovalChallengeExpired`. No lifecycle ran |
| `testAPreviewOfAnotherServerGenerationIsBlockedAndNotEligible` | an intent naming generation `100000024` against the proved `100000023`: the preview is `blocked` with `hdc.serverGenerationChanged`, its critical-Job gate clear and every participant array empty; shown, and its exact tuple `admissionDenied` |

Rules that held:

- **No invented request member.** Every request is the published tuple, the resume pair, the
  optional `challengeResponse`, or an existing `job.submit`/`job.run` shape.
- **No participant row.** Every `affectedDeviceObservations`, `affectedJobIds`, `affectedTargetIds`
  and `criticalJobGate.blocking` array in an appended frame is empty. The Target adopted to drift
  the final impact, and the Job admitted to block the interlock, appear only in readings and
  refusals no appended frame holds. The maintainer's decision on those open arrays is still
  pending.
- **No secret.** The challenge plaintext is in the challenge frame, as Swift answers it to the
  console; the durable record keeps only its digest, and the receipt never enters a projection.

## How the corpora changed

The recording run (`ARKDECK_CONTROL_FRAME_LOG`, the five tests plus the ten that were already
there) answered 134 frames. **26 lines were appended and none was removed or rewritten**: every
hunk of `git diff -U0` on the eight corpus files is a tail append, so every line the corpora
already held is byte-for-byte what it was. `control-action.list` 23→30, `.show` 15→19,
`.reconcile` 14→17, `human-action.resume` 19→26, `.show` 5→7, `.list` 7→8, `job.submit` 7→8,
`runtime.hdc.impact-preview` 15→16. `runtime.hdc.restart` and `job.run` gained nothing: every
answer they gave is already in the corpora.

Two recorded `control-action.list` lines were deliberately left out. They are the other half of a
two-page split the corpora already hold — the same pair of actions at `pageSize: 1` and its cursor
page, in the opposite random-identity order. Keeping them would leave one unreplayable, because
the Rust replay reproduces whichever split the corpus names. The corpora already carry this
nondeterminism for the whole-page listing (its two lines are that pair in both orders); a cleanup
slice could settle it.

## Schemas widened

Derived per method from that method's corpus ∪ its new frames, in an isolated copy of the
generator's inputs so no other method's schema and no committed corpus could be rewritten, then
checked structurally against the published schema (**0 narrowings, 6 widenings**; jsonschema 4.26
refuses 7 of the 28 appended lines under the old schemas and admits all 936 corpus lines and all
134 recorded frames under the new ones):

- `human-action.resume.$defs.errorCode`: `impactApprovalChallengeMismatch` and
  `impactApprovalChallengeExpired` — both live Swift codes that no published enum held.
- `human-action.resume.$defs.result.blockerReasonCode`: `string` → `["null", "string"]`.
- `human-action.resume.$defs.result.preview.tool.signature` and
  `…result.controlAction.preview.tool.signature`: `null` → the signature object beside null, all
  five members required, `identifier` a string and `teamIdentifier` null.
- `job.submit.$defs.errorCode`: `resourceConflict`, which the interlock answers.
- `x-arkdeck-sampleCounts` only on `control-action.{list,show,reconcile}`,
  `human-action.{list,show}` and `runtime.hdc.impact-preview`. The counts of `human-action.list`
  and `.show` **decrease**: the committed files carried a recording run's counts, not the
  corpora's.

`spec/control/methods/job.run.json` was left alone — its corpus gained nothing, so re-deriving it
would only churn sample counts.

**A trap for any later re-derivation of `job.submit`:** deriving it from the committed corpus
alone silently drops `inputTooLarge`, because the frame that carried that code is not in the
with-host selection. This slice restores it explicitly. Any slice that re-derives that method
without the same guard narrows the enum.

### The Rust replay this slice changes

`rust/crates/arkdeck-agentd/src/control_action_host_control.rs` is the with-host replay test: the
Rust owner must answer every with-host line of the corpora exactly as Swift recorded it, and each
line must be either replayed or one this daemon cannot reach. The appended lines make four
changes necessary, all test-only — no production Rust changes here:

- **The C2b partition.** `c2b_answer` names what only a foreground console's approval reaches: the
  challenge, a record its answer advanced past `awaitingImpactApproval` (the six lifecycle
  states), the approval it resolved, and the interlock's `factsDrifted`. The exact-partition
  assertion uses it where it used `console_answer`, and `with_host` now counts the interlock
  refusal as a with-host line, since only an owner with a lifecycle driver can be told a current
  Job blocks the action.
- **Two selections became ambiguous.** `human-action.show` and `.list` each had exactly one
  with-host line and were picked with `|_| true`; the lifecycle's resolved approval adds a second
  of each. Both now select the approval this scenario made (`result == approval`,
  `items == [approval]`).
- **One line no committed request makes.** The corpora keep one line per answer shape, so the
  restart that created the expired approval answered exactly as another line already did and was
  not appended — leaving a `human-action.show` of a record nothing here can create. `Corpora::unmade`
  names it mechanically (its owner identity appears in no other line) and it joins the deferred
  set for that reason, stated as its own, not as C2b's.
- **A preview this owner does reach.** The `hdc.serverGenerationChanged` blocked preview and its
  read are replayed in a host of their own, as the Swift test made them. Their reconcile answered
  exactly as another blocked action's did and was not appended, so only those two are replayed.
  That replay is conditional on the corpora holding the action (`Corpora::optional_action`),
  because `rust/scripts/check-contracts.py` runs this same Rust against **two** input views: the
  candidate's corpora and the merge-base's published ones, which cannot hold a line this slice
  appends. The first CI run went red exactly there and only there — "no committed line shows
  host-generation-changed" in the published view (run 35508605843, macos-26; ubuntu and windows
  green, the candidate view green). Counting a floor rather than an equality is what the rest of
  this test already does, and the exact-partition assertion still catches the line in the view
  that has it, so nothing is weakened by the guard.


## Not recorded, and why

- **A real health proof, a registered 3.2.0d server, a device.** The seam answers the registered
  server's facts; nothing here runs an HDC client but the fake's own `kill -r`.
- **The recovery of an interrupted lifecycle** (`recoverInterruptedLifecycle`, design §L.1
  item 13). It needs a Runtime start over a record parked at `approvalRecorded`,
  `dispatchPrepared` or `dispatching`; this slice never restarts the daemon mid-lifecycle.
- **A Job-gate `admissionDenied`, and `hdc.criticalJobsUnresolved`.** Both need a current Job,
  which puts rows in `affectedJobIds` and `criticalJobGate.blocking`. Deferred with the
  maintainer's decision on those open arrays.
- **`resourceConflict` "another HDC lifecycle action owns the final Job interlock".** One request
  at a time through one handler cannot hold the interlock twice.
- **An `outcomeUnknown` from an unavailable probe** rather than a stale generation. Its projection
  is the same state, blocker and dispatch count, so the corpus selection keeps one of them; the
  difference is in the lifecycle audit, which no projection carries.

## The maintainer's blocker-vocabulary decision

The blocker members of every method this slice touches are already plain strings, so the codes a
fixture can reach (`hdc.previewDrifted`, `hdc.impactObservationUnavailable`,
`hdc.serverGenerationChanged`, `controlAction.expired`, `controlAction.runtimeRestarted`,
`hdc.lifecycleFailedBeforeLaunch`, `hdc.lifecycleOutcomeUnknown`) need no widening; they are
recorded as oracle lines, not as schema changes. What stays pinned to `{"type": "null"}`, and why
no frame here can widen it:

| Pinned member | Why it cannot be reached |
| --- | --- |
| `runtime.hdc.restart.result.blockerReasonCode` | `requestRestart` answers a record only when it is `previewReady` (becoming `awaitingImpactApproval`) or already awaiting; every blocked action is a refusal, not a result |
| `runtime.hdc.restart.errorDetails.controlAction.humanAction` | only `factsDrifted` carries the action, and only a `previewReady` action reaches that branch, so it has no approval yet |
| `runtime.hdc.restart.{result,errorDetails.controlAction}.preview.criticalJobGate.reasonCode` | a restart needs a ready preview, and a ready preview's gate is clear by construction (`blocker(for:intent:)` refuses anything else) |
| `human-action.resume.result.controlAction.blockerReasonCode` and `…controlAction.preview.criticalJobGate.reasonCode` | `result.controlAction` is only the challenge's embedded action, which is always `awaitingImpactApproval` over a ready preview |
| every `preview.tool.reference` | it names a registered Tool; this host's HDC is a copy no registry holds |
| every `humanAction.selectionSchema` | an impact approval has no selection, by design |

## Local targeted checks

Rebased onto `5c9075c5` with `git rebase --onto origin/main 88248f67`. The only conflict was
`spec/baselines/swift-single-v1.json`; it was resolved to the upstream side and regenerated with
`python3 rust/scripts/generate-contract.py --write`, then `--check`: exit 0, **105 methods, 936
recorded shapes, contract identity `1d7d101e83fe`** — the identity is unchanged, so no method's
request or result shape moved for any other consumer.

- `sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --filter
  '(ControlActionWithHostContractTests|ControlMethodSchemaContractTests|ControlActionNoHostContractTests|HDCControlActionContractTests)'`:
  exit 0 — 42 executed, 0 failures, 2 skipped. Both skips are the tests' own environment gates:
  `testFramesRecordedByThisRunValidate` has no `ARKDECK_CONTROL_FRAME_LOG` directory in a plain
  run, and `testFacadePreservesForegroundConsoleChallengeAndRedirectedHAR` needs
  `ARKDECK_DAEMON_UNDER_TEST`. The with-host class ran 15 (its 10 and this slice's 5).
- With `CARGO_BUILD_JOBS=2` in this worktree's own target: `cargo fmt --all --check` exit 0;
  `cargo clippy -p arkdeck-agentd --all-targets -- -D warnings` exit 0; `cargo build -p
  arkdeck-cli` exit 0 (the agentd process tests need that binary); `cargo test -p arkdeck-contract
  -p arkdeck-control -p arkdeck-agentd -p arkdeck-cli` exit 0 — 52 test binaries, 324 passed, 0 failed.
- `sh scripts/check-sdd.sh`: exit 0, 0 errors, 0 warnings, 121 acceptance IDs (run with the repository's validation venv).
- `rust/scripts/check-contracts.py` — the CI step that failed, run locally after the fix:
  exit 0, "Published and candidate contract checks passed". It builds both views (this checkout's `rust/` over the candidate inputs and
  over the merge-base's), so it is the only local check that exercises the published view. It
  imports `yaml`, so it needs the repository's validation venv too.

Not run locally, by the verification policy: the rest of the Swift suite and the other Rust
crates, the Linux and Windows lanes, and the App build — the PR's CI is the unified gate.

## CI

Pending: the PR's GitHub CI is the unified gate.
