# Current Session publication and exact export — scope review

Source: protected main `0b35d535ccda2d01a12d29c9966de54c46a276ab`.
This proposes the [scoped delta](../../../spec-delta.md#current-session-publication-candidate-scoped-delta)
and eighteen exact Task paths. It contains no production implementation, user
state change, Task status change, approval or hardware-pass claim.

## Two measured defects in one required product path

The [published host run](../TASK-SVC-005/host-import-export-20260908.md) completed
three imports and a byte-identical HAP Artifact export. Session export remains
blocked: the current storage owner reports zero catalog entries and one
unaccounted historical Session. Its original five-event Journal ends in
waitingForRecovery after a device-mutation intent, without an outcome,
finalized event or manifest. These bytes provide no authority to recover,
finalize, move or register that historical Session.

The same current Runtime lists seven Jobs, including two succeeded Jobs and
their sessionId values. `RuntimeJobRecord.sessionID` supplies an identity string;
`RuntimeJobEngine.publishFinalizeArtifacts` produces Runtime Artifacts. No
production caller creates their formal Session manifest and catalog entry.
Merely relaxing the export guard would leave this producer missing. Creating a
fixture Session, changing roots or exporting one Artifact cannot satisfy the
required current Job → Session → exact finalized export acceptance.

This slice supplies that complete path using the existing Session owner,
publisher and export commands. It does not introduce an operation, control
method, export mode, migration framework or capability administration.

## Eighteen additional Task paths

Each path below is absent from base TASK-SVC-002. The implementation may use it
only after this scope review merges; the candidate head cannot authorize itself.

| Exact additional path | Responsibility |
| --- | --- |
| `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RuntimeSessionPublication.swift` | New current authoritative Job publication coordinator |
| `Packages/ArkDeckKit/Sources/ArkDeckCore/RuntimeSessionPublicationContract.swift` | New package-only closed wire validator shared by Workflows, CLI and AgentClient; no public API or reverse module dependency |
| `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RuntimeSessionStorageStore.swift` | Same configured owner, current claims, register/readback and exact export validation |
| `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RuntimeSessionExportRecordStore.swift` | Strict durable preview/result and cached receipt validation |
| `Packages/ArkDeckKit/Sources/ArkDeckCLI/CLIJobResources.swift` | Required publication fact in exact Job decoders |
| `Packages/ArkDeckKit/Sources/ArkDeckCLI/CLIJobEvents.swift` | The same fact in run/wait/watch status consumers |
| `Packages/ArkDeckKit/Sources/ArkDeckCLI/ArkDeckRuntimeCommands.swift` | Ordinary job wait/reconcile and submit --wait paths which currently bypass the full Job decoder |
| `Packages/ArkDeckKit/Sources/ArkDeckCLI/CLIAgentExecutions.swift` | Strict validation of the same fact in Agent's compact job projection |
| `openspec/contracts/cli-next-action.schema.json` | Generated closed next-action vocabulary, including the reviewed GJ-2 finalization continuation |
| `Packages/ArkDeckKit/Sources/ArkDeckCLI/CLISessionResources.swift` | Closed export source/catalog disclosure and digest validation |
| `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RuntimeHistoryApplicationFacade.swift` | Typed publication fact in History summaries/details and fixtures |
| `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/XPCConnectionBox.swift` | Validate the same fact before App read-resource conversion |
| `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/DiagnosticSessionUIFixture.swift` | Explicit publication facts in existing inputs to the newly strict App decoder |
| `ArkDeckApp/Features/History/RuntimeHistoryView.swift` | Existing Session fact row: saved/pending/failed/unknown, with no new action |
| `ArkDeckApp/Resources/HistoryLocalizable.xcstrings` | Accurate English/Chinese publication states and reasons |
| `ArkDeckAppUITests/AppShell/AppShellUITests.swift` | Corresponding History assertions in the existing suite |
| `Packages/ArkDeckKit/Scripts/generate-control-contract.py` | Current closed field/enum rules and actual-frame derivation |
| `docs/design/cli-session-export.md` | Exact export behavior and visible global blocker |

Existing Task scope already covers Engine/admission/recovery/record/projection,
Storage, Artifact owners, daemon composition, Agent execution, current schemas,
corpus and contract/crash tests, the other Job/Session/storage product documents
and this change. No Workflows or App wildcard is added. Global Inspector,
Settings, operation/Catalog, Core specs, Constitution, archives and user data
are outside this repair; there is no new Session export UI.

### Existing Runtime soak fixture caller

The production writer requirement also reaches the existing executable fixture
at `Packages/ArkDeckKit/Tests/ArkDeckRuntimeSoakFixture/main.swift`. Its
`makeEngine` currently calls the production `Configuration` initializer without
a Session writer. Once the publication repair refuses that missing production
dependency, the fixture would fail admission before exercising its existing
soak scenario.

The additional exact path permits only switching that fixture call from
`.init(stateDirectory:)` to `.fixture(stateDirectory:)`, alongside the already
scoped contract/crash fixture callers. The proposed one-line implementation
has compiled in the Session candidate. Its production missing-writer and
explicit-fixture admission regressions have passed. No production fallback,
environment detection, new operation or hardware execution is introduced.

This supplement requires maintainer review and merge before the implementation
may use it as base authority. Task status and acceptance requirements are
unchanged. Compatibility: the existing fixture dependency needs this one-path
review; no additional readiness or status-only delivery is introduced.

### GJ-2 finalization consumers covered by the same supplement

The reviewed [GJ-2 compensation scope](gj2-compensation-scope-review.md) permits
known failure finalization to remain explicitly continuable. Its implementation
candidate projects state=finalizing, outcomeUnknown=false and a reconcile
nextAction with reasonCode=job.finalizationPending and no retryAfter when a
revoked capability prevents unattempted compensation. The original failure is
preserved and no compensation intent is dispatched.

Three existing CLI checks do not yet accept this legitimate variant:
CLIJobEvents treats every known nonterminal state as wait/job.running;
CLIAgentExecutions accepts only recovery.outcomeUnknown for reconcile; and
CLIMachineContracts' generated reconcile vocabulary lacks job.finalizationPending.
The latter generator is already in base scope. The first two consumers and
cli-next-action.schema.json are included above for an atomic GJ-2 fix after
scope approval, before that implementation PR is submitted.

Acceptance of this reason is restricted to the confirmed debug.hap failure
finalizing case; it cannot relax ordinary Job/Agent state relationships or turn
unknown into known. Job status/show/list/wait and Agent run/resume must remain
readable, return explicit continuation rather than poll forever, and produce
zero new dispatch while the owning capability is unavailable. A regression
will take actual handler responses from the production revoked-capability
fixture through the CLI paths. The per-method schemas already accept the
reason string and absent retryAfter; actual recorded shapes determine any
additional corpus/schema update. No new reason is supplied as fabricated
recorded output.

## One observable publication result

Job status and summary gain required, non-null `sessionPublication`, including
their existing nested show/result and run/reconcile/list consumers. This closed
object has exactly four required keys. Nullable values are explicit null:

| state | manifestSha256 / catalogGeneration | reasonCode |
| --- | --- | --- |
| pending | null / null | jobNotTerminal, waitingForStorage or finalizationPending |
| published | lowercase SHA-256 / canonical decimal string | null |
| failed | null / null | storageUnavailable, sourceIntegrityFailed, identityChanged or contractViolation |
| outcomeUnknown | null / null | publicationUncertain |
| unavailable | null / null | noCurrentPublicationRecord |

`published` requires readback of the original manifest, sealed Journal, Artifact
inventory and exact catalog registration, followed by a durable receipt. It is
a publication receipt, not a permanent retention promise or device-success
claim. No marker means unavailable, including pre-existing current Jobs; their
sessionId is not backfilled into ownership. New production admissions must use
the writer. Missing production wiring cannot silently select the test fallback.

Original Job state/failure/outcome and CLI execution exit codes retain their
meaning. A Session write failure cannot replace a confirmed device result or
authorize its replay. Read methods report publication facts without retrying
writes. Product acceptance requires published, not merely Job succeeded.

AgentDaemon.executionResultProjection explicitly adds the same fact to its
existing compact job object, making seven keys. This is used by agent.run,
agent.status, agent.resume and human-action.resume; it does not become the full
Job status object. Their CLI/Agent consumers and actual method frames are
updated together. agent.list/abandon keep their existing execution metadata.
The new compact field is required only when the job object exists. No-Job and
human-action.resume's HAR/controlAction/challenge branches retain their current
shape and do not acquire a fictitious Job.

The executor's existing RuntimeAgentExecutionReceipt also retains nullable
sessionPublication: the key is always present, containing the same validated
object once a trusted Job status was read and explicit null otherwise. Synthesized
optional omission is not permitted; an unobserved Job cannot be called unavailable.
Its machine and human emitters preserve it without
altering the execution conclusion or hardware evidence. The generic CLI result
envelope already allows this payload; no additional result schema or method is
invented. The shared validator stays package-only in Core.

## Current ownership, claims and deterministic publication

The existing authoritative RuntimeJobRecord gains optional internal
`sessionPublicationRecord`. Non-null records are closed, with required fields:

| Field | Exact value/shape |
| --- | --- |
| sessionId, catalogDigest, policyGeneration | This Job's identity, admitted Catalog SHA-256 and canonical storage generation |
| root | path, device, inode, volumeIdentity; canonical verified configured root; never in public Job output |
| relativeSessionPath | Derived yyyy/mm/sessionId, never a caller path |
| sessionRootIdentity | null or device/inode from the actually opened Session |
| claims | Nonempty per-volume entries: volumeIdentity, claimId, admissionGeneration, writerClass, metadataHeadroomBytes, finalizationHeadroomBytes, remainingGrowthBytes |
| phase | awaitingStorage, recording, prepared, sealed, manifestPublished or catalogPublished |
| checkpointSeal | null or sha256, byteCount, lastJournalSequence |
| proposal | null or manifestSha256, manifestByteCount, terminalStatus, outcomeCertainty, completedAtUtc |
| journalSeal | null or sha256, byteCount, lastSequence |
| receipt | null or manifestSha256, catalogGeneration, publishedAtUtc |
| failure | null or code/certainty; the five publication failure codes above, confirmed except publicationUncertain/outcomeUnknown |

IDs, hashes, decimal strings and UTC use current canonical validation. Nested
objects reject extra/missing keys; nullable fields are never omitted. There is
one fixed owner-only auxiliary file in the existing Job directory,
`session-manifest.proposal.json`, bounded by the existing 16 MiB Manifest limit.
It is referenced by hash/bytes, not by a caller-selected path. Artifact copying
reuses existing atomic partial publication and source/derived lineage.

1. Before creating the authoritative Job, reserve metadata and finalization
   headroom with the daemon's existing host-wide coordinator. If the complete
   output/copy claim is unavailable, persist queued/awaitingStorage; no Provider
   or optional Artifact dispatch is permitted.
2. Upgrade that same Job's claim atomically after checking actual free space,
   per-volume peak source/copy growth, writer class and retention blockers.
   Persist its new generation before queued → preflight. GB inputs retain
   controlled references/hashes under REQ-ART-005, without automatic copying.
3. After execution, compensation and recovery are actually known, copy and
   verify outputs. Freeze a checkpoint of the actual current record and its
   synced Journal prefix before proposal/seal/receipt fields are set. The
   Session snapshot preserves those bytes and may be advanced by the later
   Journal suffix; it does not pretend finalizing is succeeded.
4. Persist checkpointSeal, then fixed canonical Manifest proposal and completion
   time. Append the legal terminal transition and last finalized event referring
   to that proposal hash; sync and seal the complete original Journal. Do not
   put the complete Journal hash inside the Manifest: finalized already refers
   to the Manifest, which would otherwise create a hash cycle. journalSeal and
   export source bind the complete Journal separately.
5. Publish identical Journal bytes and the validated Manifest through the
   existing SessionStorageTerminalFinalizer. Read back, register with the same
   storage owner, read the exact catalog entry, persist receipt/catalogPublished,
   then release claims. The wrapper that releases before registration is not
   suitable. A repeat returns the same receipt without incrementing generation.

The frozen checkpoint never acquires later proposal/hash/receipt/claim fields.
After a crash between its write and checkpointSeal, only equality to the same
authoritative record and Journal prefix can establish it; otherwise preserve
unknown and never overwrite it. Each later phase similarly requires exact
ownership/proposal/Journal/manifest proof. A write past the seal boundary with
unprovable outcome reports publicationUncertain, not confirmed non-execution.

Restart enumerates only authoritative current Jobs with markers. It reopens the
same root/volume/Session identities, accounts for partial bytes, and re-admits
remaining future growth using current free space and a new admission generation.
It never inherits an old process-local lease or repairs an arbitrary directory.
Unknown intent stays pending and triggers zero Provider dispatch. Root/policy
drift fails closed. Lock ordering must not await another actor while holding
the storage document lock.

Current owned active content remains visible in global incomplete accounting;
its verified marker can prevent double-counting its own claim. Historical
unaccounted content is never subtracted. Exact export of a known leaf does not
remove the existing blocker on new heavy writers.

## Current Manifest execution evidence

The current v1 adds required nullable runtimeAuthority and the actual
defaultReadOnlyPolicy/runtimeCapability executionAuthority kinds in Manifest
and jobCreated. Existing actor branches retain their constraints and require
runtimeAuthority=null; a bare standardAgent destructive intent still fails.
No actor is changed to interactiveUser/controlledHardwareLab to pass validation.

Non-null runtimeAuthority has exactly these fourteen required fields:

```text
kind, reference, admittedAtUtc, validUntilUtc, consumptionFingerprintSha256,
reservationId, useOrdinal, planDigest, stepSetDigest, targetBindingDigest,
artifactDigest, completeOverwriteRecovery, recoveryProviderExecutableSha256,
recoveryEpoch
```

The default policy has its actual decision time and default-read-only-policy
reference; all fields after admittedAtUtc are null and no mutation intent is
allowed. A consumed capability has its actual validity, fingerprint,
reservation/use and complete plan/step/target tuple; artifactDigest is present
when that consumption requires an input Artifact. These are source audit facts,
never authority supplied by the Manifest. Current capability owner and Job
records must verify them. No consumption tuple is manufactured from createdAt.

Pre-consume failure/cancellation may have runtimeAuthority=null only when the
current record and original Journal mechanically prove no mutation/destructive
intent or compensation. Durable consumption requires the complete object even
if no later dispatch occurred. Schema-valid JSON alone supplies no such proof.

completeOverwriteRecovery uses the existing closed six-field context:
coveredIntents, uncertainEffectSetSha256, coverageContractVersion,
coveredEffectSetSha256, profileReference and destructiveEpochOrdinal. Each
covered intent preserves jobId, intentEventId, operationReference,
profileReference, observedAtUtc and nonempty unique typed possibleEffects.
It and recoveryProviderExecutableSha256 are present together. recoveryEpoch
preserves the existing nineteen-field Runtime evidence epoch, with its exact
target, plan, Artifact, Provider, effects, confirmed steps and source relations.

```text
epochId, source, stableTargetIdentitySha256, bindingRevision, coveredIntents,
uncertainEffectSetSha256, coverageContractVersion, coveredEffectSetSha256,
recoveryJobId, recoveryIntentEventId, operationReference, profileReference,
materializedPlanDigestSha256, artifactSha256, providerExecutableSha256,
confirmedStepIds, resultingTargetEpochSha256, establishedAtUtc, epochSha256
```

Manifest recovered is valid only for execute/runtimeCapability/confirmed,
failure=null, complete context and this Job's distinctRecoveryExecution epoch,
including proven overwrite/readback/rebind/postflight and matching Journal
outcomes. The original covered Jobs remain unknown. Failed recovery retains its
attempted coverage context and Provider hash with recoveryEpoch=null. The
existing succeeded storage disposition accepts succeeded/recovered while the
Manifest and receipt retain recovered. No new Job state or recovery authority
is introduced.

Host-only execution uses an honest target branch: kind=host, connectKey=null,
transport=host, actual typed host/workspace identitySnapshot and empty binding
history, only with no device effect and no binding-required Step. toolchain none
is allowed when no external executable ran; an actual external host tool uses
closed kind/providerIdentity/profileIdentifier/reportedVersion/sha256. Device
targets keep their address, binding and tool requirements. Missing source facts
produce a publication failure, not synthetic device or tool placeholders.

SessionManifestDocument, JSON Schema and Journal cross-validation enforce the
same shape and relationships. Current fixture builders explicitly write the
new field; historical raw/retired fixtures are not rewritten into positive
examples. Export keeps source authority digests opaque and preserves consistent
ID redaction without claiming the derived document can authorize Runtime work.

## Exact export with visible global incomplete content

The existing preview/result each add two required closed objects. `source` has
jobId, manifestSha256, journalSha256, rootDevice, rootInode, volumeIdentity,
sessionDevice and sessionInode. `catalogStatus` has complete,
unaccountedSessionCount, measurementIncomplete, usedBytes and blocker.

Success permits either complete/count=0/measurementIncomplete=false/blocker=null,
or complete=false/count≥1/measurementIncomplete=true with
blocker=unaccountedSessionContent. In the latter case the scan must mechanically
locate all unknown content in unrelated leaves; usedBytes is measured known
content, not a complete total. Root/volume uncertainty, corrupt catalog,
unscoped unknown, duplicate identity or an incomplete/unregistered selected
Session still produces no successful preview or output.

previewDigest remains SHA-256 of the full JCS preview object minus only
previewDigest, including both new objects. apply validates the durable preview,
digest, complete source/global/generation/destination/privacy/expiry tuple and
the existing postflight snapshot. Drift remains resourceConflict before output.
Result facts match the applied preview; cached applied receipts are strictly
validated. Old missing-field receipts are not backfilled or reapplied; durable
applying with unknown outcome remains non-replayable.

Global list/show/pin/unpin/cleanup keep their existing fail-closed contract.
Default raw/partial exclusion, sensitive opt-in, device-ID redaction, original
hashes and derived Artifact lineage remain intact. RetentionAndExport's Manifest
scrubber and revalidation cover the new authority/epoch fields in this slice.

## Verification and delivery

- The twelve changed method shapes are job.list/reconcile/result/run/show/status,
  agent.run/status/resume, human-action.resume and session.export.preview/apply.
  Their production writers and real frame corpus move together. Job submit,
  plan and cancel acknowledgements do not claim Session publication and keep
  their existing shapes.
- Use a real production Engine + configured owner + handler + CLI test to create
  the Job, Session, outputs, snapshot, Journal, Manifest and catalog before exact
  export. A prebuilt finalized fixture does not prove the producer.
- Cover succeeded, failed before/after consume with compensation, cancelled,
  recovered and unresolved waiting outcomes; original failure/authority remain
  unchanged across host publication failures.
- Record every affected real method variant; synchronize strict CLI/App/Agent
  consumers, schema rules and corpus atomically. Missing/extra/duplicate keys,
  wrong null/state/reason/hash/decimal and forged published receipt are negative.
- Crash at claim upgrade, copy/partial, checkpoint, proposal, terminal/finalized,
  Journal copy, manifest rename/fsync, registration and receipt/release. Restart
  must prove no device replay, no early release and no historical adoption.
- Coexist one preserved historical manifestless unknown with a newly produced
  current Session. Exact export succeeds with the blocker disclosed; exporting
  the unknown target and unsafe global operations remain refused.
- Test source/root/claim/policy drift, insufficient headroom, unknown growth,
  corrupt catalog and export applying unknown, plus authority/epoch privacy
  round-trip and source-byte preservation.
- Assert bilingual History publication facts without replacing execution state.
  Run the unified local planner and final actual-frame validation after all
  recording ends. Publish only through reviewed protected main, then repeat the
  affected headless/Session acceptance in the original configured Runtime root.

The documentation-only unified local planner passed: 87 common tests, SDD with
zero errors/warnings and the Catalog generator check. It selected no Swift,
App, UI or Rust build lane. The log is local at
`/private/tmp/arkdeck-svc-a-20260908/session-scope-final-unified-gate.log`.
All five Task statuses are unchanged and exactly eighteen paths are added.
The actual current Session export and SVC-AC-05/10 remain incomplete; fixture
success cannot become hardware evidence.
