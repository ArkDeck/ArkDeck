# GJ-2 compensation after confirmed failure — scope review

Source baseline: `a076ca31ef97ef4285981af053d07b7fe0f052bd`.
This review proposes two exact Task paths and the associated
[scoped delta](../../../spec-delta.md#gj-2-confirmed-failure-compensation-candidate-scoped-delta).
It does not claim implementation, approval, test success or hardware acceptance.

## Observed defect

The existing Runtime record `job-c4a51d35f513cf0152c5b9cacec01bcb` requested
`debug.hap@1` with `cleanupPolicy=uninstall`, `postRunAbilityState=stopped` and
ten seconds of diagnostics. Its journal records successful HAP send, install,
package readback, ability start and process readback. The diagnostics intent at
`2026-09-07T06:54:59Z` timed out at `06:55:45Z`; Runtime correctly parked the
unresolved intent in `waitingForRecovery`.

Explicit reconcile at `06:56:28Z` recorded a correlated failed outcome with
`confirmedNotExecuted`, then `finalizing → failed`. The journal contains no
stop, uninstall or staging-cleanup intent/outcome, and no cleanup debt was
recorded. This is the observed product gap. The original diagnostics intent was
not replayed. This review neither re-ran nor changed that Job, its authority or
its hardware evidence.

The supporting sources are the existing `job-record.json` and `journal.jsonl`
under the configured Runtime Job store for that Job, plus the implementation at
the source baseline. Those historical records are references, not current
Catalog acceptance. A later verification must use a new request through the
published Runtime; it must not reconstruct missing proof or clean historical
state as part of this repair.

The timeout itself does not establish a timeout-policy defect. The current
bounded HiLog lowering applies a 45-second timeout to this ten-second request;
the successful read-only diagnostics journey uses the same lowering. Raising
that timeout is outside this repair.

## Why the existing recovery path loses compensation

- `RuntimeJobEngine.executeAdmittedSteps` calls `compensateDebugHAP` for an
  ordinary confirmed required-step failure. It first stops on an unknown
  outcome, which is the correct safety boundary.
- `RuntimeJobEngine.reconcile` resolves `confirmedNotExecuted` and directly
  completes `finalizing → failed`. Its interrupted-finalization branch also
  completes failed without scheduling compensation.
- REQ-JOB-004 requires applicable typed compensation on failure and preservation
  of the original failure. CHG-049's DHA-HAP-001 explicitly requires compensation
  according to cleanup policy after HAP failures.
- The Core graph and `journal-event.schema.json` omit
  `finalizing → waitingForRecovery`. Core ordinary dispatch in `finalizing`
  allows only `finalizeSession`. Although Journal's current coarse intent-state
  check allows finalizing, it cannot authorize ordinary device cleanup there.
  Merely calling `compensateDebugHAP` in this branch would leave a subsequent
  unknown cleanup without a legal parking path.
- `RuntimeRecoveryService` currently closes a clean interrupted finalizing Job
  as failed. A repair must preserve any durable pending compensation before
  that fallback is applied; restart itself must still dispatch nothing.
- Existing `cleanupDebt.continue` requires a debt that already exists and a
  persisted exact typed action. The measured Job has neither cleanup attempt
  nor debt. The two supported residue kinds, remote path and installed bundle,
  also cannot represent an unknown stop action. Debt is not a substitute for
  the missing compensation lifecycle.

## One existing compensation protocol

The repository already has two relevant execution forms: ordinary typed
Workflow steps, including forward-path cleanup, and first-class compensation
events. `compensateDebugHAP` currently emits the former; Storage/Core already
provide `CompensationDescriptor`, source `compensationDescriptors`,
`CompensationPlanner`, `compensationIntent` and `compensationOutcome` for the
latter. The existing compensation intent includes `compensationOfStepId`, the
exact descriptor and target. Manifest validation also requires the descriptor
to have been declared by that source Step.

The finalization repair should use that existing compensation protocol. Adding
another marker to `stepIntent` would create a third representation of the same
compensation, force every replay/projector/manifest consumer to distinguish it,
and still require new linkage and crash semantics. It would not be justified
merely because a Task lacks permission to edit the existing descriptor type.

The exact stop, policy-selected uninstall and owned-path descriptors must be
stored with their source intents before source dispatch. A finalizer may then
select only applicable descriptors of confirmed successful sources. It must
validate source/descriptor/target/binding/arguments linkage, preserve the
original diagnostics failure, and skip every already-attempted compensation.
The existing `CompensationPlanner` supplies the reverse source order; a second
planner or new device operation is unnecessary.

## Two exact path additions

| Additional TASK-SVC-002 path | Necessary change | Already provided |
| --- | --- | --- |
| `Packages/ArkDeckKit/Sources/ArkDeckCore/WorkflowStep.swift` | Add `uninstallPackage` to `CompensationDescriptor.allowedKinds` | The typed kind, packageName validation, deviceMutation effect, confirmed-device binding and cancellation metadata already exist |
| `openspec/contracts/workflow-step.schema.json` | Add that same kind to the compensationDescriptor enum | Existing typedStepInvariants and typedArgumentsByKind already enforce its closed shape |

No new field, event kind, schema version, Job state, operation, provider,
capability authority or raw command is needed. The candidate recovery edge
joins two existing states. This review does not change either of these two
source/contract files before their scope is approved on the base.

The base TASK-SVC-002 already covers all other identified implementation,
contract and test paths below. TASK-DHA-001/002 forbid global contracts;
TASK-WSC-001 covers these descriptor files but forbids Workflows and lacks the
recovery/Journal scope; SVC-001 explicitly excludes durable-layout changes;
SVC-005 is an acceptance/documentation task. These existing owners do not supply
one suitable alternative Task for the complete repair. Multiple Task allowlists
cannot be combined, and the checker's vertical supplement can add only a new
change/evidence namespace, not these production paths.

## Atomic implementation and consumer checks

| Existing allowed file | Required behavior |
| --- | --- |
| `Sources/ArkDeckCore/JobStateMachine.swift` | Execute-only finalizing-to-waiting recovery edge and explicit compensation dispatch; normal finalizing dispatch remains closed except finalizeSession |
| `Sources/ArkDeckStorage/JournalReplay.swift` | Source descriptor, confirmed source outcome, exact target/binding and single-attempt checks on append and replay; unresolved compensation cannot terminate |
| `Sources/ArkDeckStorage/JournalEvent.swift`, `JournalEventValidation.swift` | Reuse existing compensation constructors, typed descriptor and correlated outcome validation; no second event shape |
| `Sources/ArkDeckWorkflows/RuntimeJobEngine.swift` | Materialize source descriptors; dispatch/reconcile the exact compensation; preserve original failure; schedule only pending obligations; revalidate authority and settle it only at a known terminal boundary |
| `Sources/ArkDeckWorkflows/RuntimeRecoveryService.swift` | Recover pending compensation from durable declarations and outcomes; preserve finalization; no device dispatch on restart |
| `Sources/ArkDeckWorkflows/Artifacts/RuntimeArtifactStore.swift` | Persist confirmed cleanup failure debt once, with exact typed action; do not swallow debt persistence failure before finalization |
| `Sources/ArkDeckStorage/SessionManifest.swift` | Keep source declaration, compensation records and journal references mutually consistent in export/readback |
| `Sources/ArkDeckWorkflows/RuntimeJobReadProjection.swift`, `Sources/ArkDeckAgentClient/HardwareEvidenceProjector.swift` | Verify consumers preserve actual compensation steps, original failure and separate unknown/failed compensation facts; change only if the existing projection omits them |
| `openspec/contracts/journal-event.schema.json` | Add the one recovery pair consistently with the Core graph; preserve the strict existing compensation event shape |

`Sources/` paths in this table are relative to `Packages/ArkDeckKit/`.
`RuntimeJobRecord.swift` is also in the existing Task scope; first reuse its
failure/action fields and journal-derived progress rather than adding another
durable compensation state. No current Core spec or unrelated protocol is part
of this scope review.

## Behavior and crash matrix for the implementation

| Vector | Required observation |
| --- | --- |
| Confirmed send/install/start; diagnostics unknown then confirmedNotExecuted | Stop, selected uninstall and staging cleanup each once; original diagnostics failure retained; final failed; diagnostics dispatch count unchanged |
| cleanupPolicy retain | Stop and owned-path cleanup; zero uninstall; original failure retained |
| Confirmed failed cleanup | Separate failure and supported residue debt; remaining safe obligations continue; original failure unchanged; repeated reconcile produces no duplicate debt |
| Each of stop, uninstall and owned-path cleanup becomes unknown | One exact outstanding compensation intent; waitingForRecovery; no subsequent mutation, terminal transition or capability release |
| Compensation readback confirms completed | One correlated compensationOutcome; only remaining finalization runs; no compensation resend or running/planning transition |
| Compensation readback confirms notExecuted | One correlated failed compensationOutcome; no resend; separate debt/attention and remaining safe obligations; original operation stays failed |
| Missing/drifted target, binding, plan, Artifact or authority | Zero new compensation dispatch; no forged proof or premature lineage settlement |
| Undeclared/mismatched source, descriptor, kind, args/hash, target or binding | Reject before dispatch; ordinary finalizing mutations remain forbidden |
| Crash after original reconcileOutcome or after entering finalizing | Restart zero dispatch; preserve pending declared obligations; explicit continuation schedules each unattempted compensation once |
| Crash between compensations | Derive completed/failed/attempted progress from journal; do not rerun the previous compensation |
| Crash after compensation intent before dispatch, or after effect before outcome | Preserve exact unknown intent; never infer non-execution from the missing outcome; only dedicated readback may resolve it |
| Crash after outcome before debt/record, or after debt before next compensation | Restore known progress and record required debt once; do not resend |
| Crash after final compensation before terminal, or terminal before capability outcome | Journal-only completion/lineage repair; no new dispatch; original failure retained; settlement idempotent |
| Historical source lacks declarations or complete proof | No descriptor backfill, automatic cleanup, replay or rewritten evidence |

Primary suites are `DiagnosticsAndHAPContractTests`, `JournalRecoveryContractTests`,
`JobStateMachineTests`, `WorkflowStepContractTests` and
`SessionArtifactStorageContractTests`. Existing capability/engine fault fixtures
should verify authority settlement and the crash windows, and a consumer test
must read the resulting Job/Manifest/evidence rather than only inspect mock
dispatch counts. Normal HAP success and its policy-selected cleanup must remain
covered.

The required local CI planner passed for this documentation-only diff: 79 common
tests, SDD validation and generator checks, with all nine relative links resolving.
It selected no Swift, App or UI lane. The log is local at
`/private/tmp/arkdeck-svc-a-20260908/gj2-scope-unified-gate.log`.
The implementation suites, full product gate and a new published headless GJ-2
run remain separate verification work; no production or hardware pass is claimed.
