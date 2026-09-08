# GJ-2 confirmed-failure compensation implementation candidate

- Task: TASK-SVC-002
- Base: `f0670ba6bcae64c98efe6ed90e8bf0f3101e2cd6`. The GJ-2 compensation scope entered at `6a8a06fc2f437c790322c50871173b72a9ca80c9`; reviewed PR #1772 adds the complete CLI finalization consumer scope. Reviewed PR #1771 supplies the Rust candidate-contract check dependency.
- Scope: existing GJ-2 failure compensation and its durable recovery consumers; no new operation, Job state, event envelope, Runtime authority, or hardware claim.
- Status: implementation candidate; the final unified gate and independent validation of all completed recordings passed. Maintainer review and published Runtime acceptance remain pending. Task/change approval or verification status is unchanged.

## Defect and behavior

The 2026-09-07 diagnostic timeout in Job `job-c4a51d35f513cf0152c5b9cacec01bcb` occurred after HAP send, install, start and required readbacks succeeded. The exact diagnostic later reconciled as confirmed not executed. The old path immediately reached failed without stop, uninstall or staging cleanup, and had no cleanup debt to continue.

New admissions materialize failure compensation in the complete authorization plan and predeclare the exact existing descriptors in each source Step intent. Once the original failure and every preceding external effect are confirmed, finalizing executes applicable source declarations in reverse order using existing compensationIntent/compensationOutcome. Normal finalizing Workflow dispatch remains restricted to finalizeSession. Retain omits uninstall; failure still stops an ability the Job started even when a successful run requested it remain running.

Every new compensation revalidates the complete plan, live owning capability use, Artifact leases, target identity, binding and tool facts. Unknown compensation outcome or identity parks waitingForRecovery and retains the original operation failure and capability lineage. Exact read-only reconciliation returns both confirmed compensation completion and non-execution to failure finalization, never running. An existing intent is never resent. Confirmed cleanup failure is separately durable and idempotently recorded; stop failure remains a separate journal outcome/needsAttention entry within the existing residue vocabulary.

Restart performs zero device dispatch. Clean pending failure finalization remains explicitly continuable through job.run/job.reconcile, with nextAction=reconcile. Outcome-before-debt and terminal-before-capability windows use durable correlation; only known effects and durable compensation dispositions allow the failed terminal and confirmed capability outcome. Historical records without source declarations receive no backfilled cleanup or new dispatch.

A first send confirmed not executed retains safeToReflash only when the complete Journal proves every mutation and compensation intent was not executed, with no torn tail or unresolved outcome. Both immediate settlement and terminal lineage repair use that same proof. Earlier successful mutations followed by a nonexecuted diagnostic still settle confirmed. Merely declaring a compensation does not dispatch it; its eventual intent must separately satisfy exact source, target, binding and live authorization checks.

All CLI status/show/list, ordinary wait, streamed wait, submit --wait and Agent run/resume consumers accept the narrow debug.hap confirmed-failure finalizing branch. Waiting returns resultNotReady (75) with job.finalizationPending and an explicit reconcile action, without retryAfter. It does not poll to clientTimeout, classify the record unreadable or replace the original failure. Unrelated operations/states, unknown or human-waiting facts, missing/unknown failure and an added polling hint are refused.

Independent review found three additional recovery gaps in the initial candidate. A required staging cleanup that failed on the normal path lost its exact action before finalization could record debt. An optional uninstall that had already failed could reach its old intent again after a crash between outcome and debt. A crash between the durable finalizing-to-waiting transition and record projection could leave identity recovery unreachable. The revised candidate retains ordinary cleanup actions until debt is durable, resumes confirmed optional cleanup bookkeeping from the original declaration and intent without changing optional success semantics, and reconstructs pending identity proof from the durable waiting boundary without inventing a Provider outcome.

## Candidate checks added

- Three compensation actions, uninstall/retain policy, post-run-running failure cleanup, original failure preservation, no normal running transition and no duplicate terminal dispatch.
- Each compensation unknown, restart, dedicated readback returning completed or not executed, remaining compensation, separate debt and no resend.
- Captured durable fixture images at original reconcile outcome; clean failure finalizing; each compensation intent and outcome; cleanup debt; preterminal and terminal-before-capability. Restore preserves the original artifact paths and plan identity.
- Required normal staging cleanup failure: one original intent, one staging debt, original failed result, confirmed capability settlement, no resend across finalizing/debt snapshots and repeated reconciliation.
- Optional normal uninstall failure: before/after-debt crash snapshots and an actual ledger storage failure remain resumable; only the remaining staging cleanup dispatches, debt is idempotent and the Job retains optional success semantics.
- Identity unavailable before any compensation intent: snapshot exactly after the durable waiting transition while the record still says finalizing/known; restart dispatches nothing and restores explicit fresh-identity reconciliation.
- Revoked capability: zero new intent/dispatch, pending finalization and explicit continuation read model.
- Actual producer journal negative cases on append and cold replay: source, descriptor, arguments, target and binding drift; ordinary finalizing mutation; wrong outcome envelope; repeated compensation.
- Historical source declarations absent: restart/reconcile produces no new compensation.
- Core compensation lane excludes planOnly, ordinary mutations, terminal state, unconfirmed source and success finalization; recovery preserves the original failure.
- Real control handler responses for compensation waitingForRecovery and failed via agent.resume, job.reconcile and job.result; agent.resume's reconcile/readResult nextAction has no retryAfter. A known failed terminal Job is read successfully through job.result with its original structured failure; with no remaining debt its nextAction is null. Frame recording uses the existing control recorder when root runs the suite.
- The same regression now calls agent.status, idempotent agent.run, human-action.resume, job.evidence and job.show in both waiting and terminal states, plus agent.list, nonterminal job.result and rejected agent.abandon while waiting. Calls enter the real handler with their own method and exact parameters; no recorded frame is relabeled. The tests retain the original execution and Job identities, verify zero new dispatch for reads/re-entry/refusal, preserve the typed authorized HAP request, and compare the complete Runtime capability authority correlation across the evidence consumers.
- The existing waiting/abandoned Agent fixture now also calls agent.status and agent.resume before and after abandonment. It records the genuine no-Job nullable fields, pending physical action, abandoned null nextAction and expired resume refusal while preserving zero Jobs and zero dispatch.
- A real revoked-capability failure-finalizing Job passes handler → UDS → CLI status/show/list/Agent status, then job result/wait, Agent run/resume and human-action.resume return bounded explicit continuation with zero new intents or dispatch. The actual nextAction passes both the generated and committed CLI schema; inconsistent variants are negative consumer tests.
- A nonempty additional HAP lease and all six scalar HAP options pass real materialization, compensation and handler output. The multi-package digest differs from the single-package digest, each compensation retains the correct source arguments/target/binding, and evidence/request consumers preserve every input.

These are deterministic fixture checks, not real-device acceptance. Manifest vocabulary continues through the existing WorkflowStep/CompensationDescriptor validator and correlated journal format; no new manifest pipeline is introduced.

## Verification log

The production sources compiled and the development focus executed 185 tests.
Two new fixture failures were corrected: canonical single-line request bytes
are now stored, and each policy variant has its own capability lineage. The
policy regression passed its exact rerun. The Agent regression's known failed
terminal result is read successfully with its original structured failure,
following the existing product contract. No production check was relaxed to
make these fixtures pass.

The final four producer tests passed in a root-owned serialized run, including
the two original Agent/abandonment tests, the revoked-capability CLI continuation
and multi-package HAP test. Four original files contain 49 real handler frames.
The log is `/private/tmp/arkdeck-svc-a-20260908/gj2-complete-producer-final-v2.log`.

Root combined the affected current corpus, the earlier 24 original producer
frames and this final batch into 144 frames for twelve methods. Input
`gj2-method-schema-input-v3.jsonl` has SHA-256
`9947b65f1f387d2b97ee93254f7ab75e5836af3f6315015c9c6dacb5cff04a68`;
`gj2-method-schema-input-provenance-v3.json` records every source file/hash.
Health frames are excluded because this change does not alter that method.
No method name, original bytes or response was fabricated. The twelve schemas
and eleven changed corpus files preserve full capability correlation, all HAP
inputs, waiting/failed evidence and genuine no-Job HAR consumers. The generated
CLI next-action schema was exported by the candidate CLI; only its actual
changed product was copied into the repository.

All 45 consumer/schema focused tests passed, including eight contradictory
finalization variants. The first unified gate exposed a missing derived build
version in the new compensation context, incorrect whole-use settlement after
the first send was disproved, and an overbroad new target check on unexecuted
compensation declarations. Production fixes preserve the existing four tests
and their assertions. Those regressions plus all DiagnosticsAndHAP tests then
passed: 113 tests (`gj2-gate-regression-focus.log`).

The required unified local planner passed with all selected lanes: common
checks, 2,482 parallel Swift tests, one serialized process-identity test, five
serialized Viewer tests, 83 design-system tests, App build-for-testing, and both
published/candidate Rust contract checks. The Rust checks each completed 111
actual control responses, seven CLI envelopes and 102 valid requests before
their independent validation. Cargo deny passed all four policies and Cargo
vet confirmed 25 fully audited dependencies. The final log is
`/private/tmp/arkdeck-svc-a-20260908/gj2-final-unified-gate-v5.log`.

Earlier retries exposed missing local Python dependencies and pinned Cargo
audit tools, after the behavior checks had passed. The successful run used a
task-local environment containing repository-pinned PyYAML/jsonschema and the
existing pinned cargo-deny 0.20.2/cargo-vet 0.10.2. No repository dependency,
audit policy or published Rust pin was changed to pass the gate.

After every recorder stopped, ten separate Swift recorded-frame validator
runs passed across all GJ-2 and earlier HDC/CRLF/HAR recording directories:
12,652 complete original frames. Standard `jsonschema.Draft202012Validator`
independently validated the same request/result/error definitions with zero
failures. Results, file hashes and logs are preserved in
`gj2-final-post-recording-verification.json` and
`gj2-standard-schema-post-recording.json` under the same local log directory.
No original response was edited. Generator check alone is not the conformance
proof. App UI assertions and published device acceptance remain unperformed
for this candidate; no live CLI run/resume/reconcile used its unreviewed code.
