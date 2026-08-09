# Tasks

## TASK-E2B-001 — Close GJ-4 with Runtime-owned admission and autonomous proven recovery

- Status:ready (IMPLEMENTING: r10 was reviewed by #1217 and its Runtime invocation landed in
  #1219. #1220 proved the real UI path still stopped before that invocation and used an
  intermediate PR as experiment transport; the pre-admission candidate actuator and accepted
  request handoff are now the remaining implementation scope. Host contract evidence is not
  real-device completion; GJ-4 remains IMPLEMENTING until the explicit device window reaches
  success or reports one truthful non-overridable blocker.)
- Golden Journey:GJ-4
- Platform:macos; windows/linux contract compatibility only
- Requirements:`POL-RECOVERY-001`, `POL-AGENT-002`, `REQ-FLASH-007`, `REQ-FLASH-013`,
  `REQ-FLASH-015`, `REQ-FLASH-016`, `REQ-FLASH-017`, `REQ-FLASH-018`, `REQ-WF-004`,
  `REQ-JOB-001`, `REQ-JOB-006`
- Acceptance:`AC-FLASH-007-01`, `AC-FLASH-013-01`, `AC-FLASH-015-01`,
  `AC-FLASH-015-02`, `AC-FLASH-015-03`,
  `AC-WF-004-01`, `AC-WF-004-02`, `AC-WF-004-03`, `E2R-CATALOG-001`,
  `AC-JOB-001-03`, `AC-JOB-001-05`, `AC-JOB-006-01`, `E2R-RUNTIME-001`,
  `E2R-NEGATIVE-001`, `E2R-COMPAT-001`, `E2R-RECOVERY-001`,
  `E2R-RECOVERY-NEGATIVE-001`, `E2R-HISTORY-001`, `E2R-NOQUESTION-001`, `E2R-GJ4-001`
- Depends on:r7/r9/r10 approval dependencies are satisfied by #1193/#1194, #1206/#1207 and
  #1217; the remaining dependency is implementation host gates followed by the explicit D2
  real-device window
- Production reachability:
  `ArkDeckApp/manual UI driver -> Agent XPC -> protected-main RuntimeJobEngine ->
  RuntimeCapabilityStore -> Rockchip Runtime composition -> typed Provider -> DAYU200`
- Trusted fact sources:Catalog from protected main; Runtime plan materializer; Artifact store/lease
  digests; Runtime target registry and same-attempt fresh readback; daemon-owned capability store,
  reservation and journal. Caller/candidate/repairer cannot construct these facts and their proof.
- Allowed paths:
  - `PRODUCT-LOOP.md`
  - `AGENTS.md`
  - `Catalog/schema/operation.schema.json`
  - `Catalog/operations/capture.diagnostics.v1.json`
  - `Catalog/operations/debug.hap.v1.json`
  - `Catalog/operations/deploy.native-library.app-owned.v1.json`
  - `Catalog/operations/flash.dayu200.json`
  - `Catalog/operations/flash.dayu200.v1.json` (rename source)
  - `Catalog/operations/deploy.native-library.system.v1.json`
  - `Catalog/operations/observe.device.v1.json`
  - `Catalog/operations/port-forward.create.v1.json`
  - `Catalog/operations/port-forward.remove.v1.json`
  - `Catalog/profiles/dayu200.json`
  - `Catalog/profiles/dayu200.v1.json` (delete)
  - `Catalog/profiles/dayu200.v2.json` (delete)
  - `Catalog/generated/effect-authorization-matrix.md`
  - `openspec/constitution.md`
  - `openspec/specs/flashing/spec.md`
  - `openspec/specs/workflow-journal-recovery/spec.md`
  - `openspec/contracts/provider-contracts.md`
  - `openspec/contracts/hardware-evidence.schema.json`
  - `openspec/integrations/INTEGRATION-PROFILES.lock.yaml`
  - `openspec/integrations/openharmony/profile.md`
  - `openspec/integrations/openharmony/trace-probes/1.0.0/registry.yaml`
  - `openspec/governance/enforcement.md`
  - `openspec/verification/policy.md`
  - `openspec/verification/acceptance-index.txt`
  - `openspec/verification/acceptance-cases.yaml`
  - `openspec/verification/core-conformance.yaml`
  - `openspec/verification/traceability.md`
  - `openspec/config.yaml`
  - `openspec/baselines/CORE-4.0.0.yaml`
  - `openspec/changes/chg-2026-056-e2-policy-baseline-alignment/**`
  - `scripts/catalog_gen/**`
  - `scripts/check_sdd.py`
  - `scripts/rockchip_component/**`
  - `Packages/ArkDeckKit/Sources/ArkDeckCore/RuntimeCapability.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckCore/JobStateMachine.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckCore/RuntimeOperationCatalogTypes.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckCore/RuntimeOperationCatalogGenerated.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckCore/AgentXPCContract.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckRuntime/RuntimeOperationModelsV2.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckStorage/RuntimeCapabilityStore.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckStorage/RecoveryCoordination.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckStorage/RuntimeJobRepository.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckStorage/AuthorizationUsageLedger.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckStorage/JournalEvent.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckStorage/JournalEventValidation.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckStorage/JournalReplay.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckStorage/SessionManifest.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/EvolutionCampaignAuthority.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/EvolutionCampaignAttemptAdmission.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/EvolutionCampaignEngineLaneAdmitter.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/EvolutionCandidatePipeline.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/FlashApplicationFacade.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RuntimeJobEngine.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RuntimeRecoveryService.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RuntimeHistoryApplicationFacade.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/OverviewCapabilityApplicationFacade.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/Artifacts/RuntimeArtifactService.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RockchipAuthorizationFacts.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RockchipFlashPreflight.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RockchipFlashProfile.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RockchipFlashAuthorization.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RockchipFlashExecution.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RockchipFlashExecutionHost.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RockchipBootloaderStatus.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RockchipFlashSessionReconcile.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/DeviceProviders/**`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/AgentComposition/EvolutionCampaignHost.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/AgentComposition/HarnessAdapters/**`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/AgentComposition/LocalAgentEvolutionStrategyRepairer.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckAgentClient/HardwareEvidenceProjector.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckAgentClient/AgentRuntimeExecutor.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckAgentDaemon/FlashBundleArtifactImport.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckAgentDaemon/AgentDaemon.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckAgentDaemon/AgentXPCListener.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckAgentDaemonMain/main.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckRuntime/HumanActionRequired.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckRuntime/RuntimeOperationModelsV2.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckCLI/ArkDeckCLIMain.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckCLI/ArkDeckRuntimeCommands.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckCLI/EngineLaneEvolutionFlashDispatcher.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckHarness/Application/HarnessPolicyGuard.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckHarness/Domain/HarnessEvolution.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckHarness/Candidate/main.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckOpenHarmony/TraceProbeAdapter.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/**`
  - `Packages/ArkDeckKit/Tests/ArkDeckCoreTests/**`
  - `ArkDeckApp/Features/Flash/**`
  - `ArkDeckApp/Features/History/RuntimeHistoryView.swift`
  - `ArkDeckApp/Features/Jobs/GlobalJobInspectorView.swift`
  - `ArkDeckApp/Resources/FlashLocalizable.xcstrings`
  - `ArkDeckAppUITests/AppShell/AppShellUITests.swift`
  - `docs/design/prototype.html`
  - `docs/design/design-agent-briefs.md`
  - `docs/design/macos-ux-interaction-spec.md`
  - `ArkDeckApp/Documentation/macos-ui-implementation-proposal.md`
- Forbidden paths:
  - integration/device profile identity beyond the exact v1/v2-to-`dayu200` consolidation and
    DAYU200 trace-family `-v1` suffix removal, or any partition mapping other than the retained
    current nine-partition facts
  - new operation, Provider, raw command surface, executable/argv input or effect downgrade
  - caller/Agent capability administration or trusted-fact injection
  - legacy authority instance bytes or migration into RuntimeCapability
  - retry/replay or guessed outcome for an unknown intent; recovery without a reviewed exact
    Provider coverage contract and complete Runtime-derived proof
- Risk:destructive (r9 intentionally permits a distinct full-overwrite dispatch after an unknown
  destructive outcome when complete Runtime proof exists; real validation erases DAYU200 userdata)
- Hardware required:yes, but only after approved implementation passes every host gate
- Decision-Grade:D1 for Core implementation approval; D2 for the later physical device window

### r7 Deliverables

- Apply r7 deltas to Constitution, AGENTS, PRODUCT-LOOP, current specs/contracts, governance and
  verification registries without lowering `destructive` or rewriting accepted history.
- Add a reviewed complete-overwrite recovery declaration to exact DAYU200 operation/profile
  combinations without changing operation inputs, partition facts, Provider selection or argv.
- Make protected-main Runtime conservatively derive the union of all outstanding uncertain
  effects and admit distinct recovery only after fresh same-target, immutable Artifact, complete
  coverage, verification and budget proof.
- Journal every recovery with a new capability/reservation/intent, preserve old unknown outcomes,
  and publish `SupersedingRecoveryEpoch` only after all effects plus reboot/rebind/postflight pass.
- Add a read-only historical semantic scanner that can append a supersession relation only from
  complete durable proof; incomplete legacy facts remain blocked and unmodified.
- Replace `outcomeUnknown` approval prompts with automatic recovery for eligible cases and a
  non-overridable diagnostic for ineligible cases. Retain truthful initial userdata-impact UX.
- Keep the standalone manual UI driver outside all default test discovery. After host gates and
  protected-main merge, validate the supplied DAYU200 archive through the real signed UI without
  E2/campaign/chat/outcome-decision prompts and record truthful Job/Session/Artifact/postflight.

### r7 Verification

- `E2R-CATALOG-001`: schema/generator/catalog/Swift parity and both destructive operations retain
  effect/Steps while no new Catalog writer emits `oneShotExactPlan`.
- `E2R-RUNTIME-001`: fake Provider positive path proves an Agent request reaches typed dispatch
  through Runtime-generated capability with no standing/campaign/user-message dependency.
- `E2R-NEGATIVE-001`: comprehensive fact drift, caller-forgery, reservation, lineage,
  unknown/unsafe/cancel/expiry/budget matrix proves external dispatch 0.
- `E2R-COMPAT-001`: V1-V4 authority/evidence decode/export remains byte-compatible while every
  legacy-to-new admission/migration attempt is rejected.
- `E2R-RECOVERY-001`: an outcomeUnknown fixture with known identity and complete DAYU200 effect
  coverage automatically dispatches a distinct recovery, never replays the original intent, and
  releases the lane only after all writes and postflight are confirmed.
- `E2R-RECOVERY-NEGATIVE-001`: identity ambiguity, unbounded/omitted effect, protected partition,
  partial coverage, caller proof, drift, cancellation and budget cases all dispatch 0 and never
  offer a confirmation override.
- `E2R-HISTORY-001`: a complete later real-Flash fixture appends a supersession relation with zero
  device dispatch; missing identity/coverage/outcome/postflight facts append nothing and preserve
  the old unknown record byte-for-byte.
- `E2R-NOQUESTION-001`: initial Agent Flash, safe ordinary continuation and eligible recovery have
  no UI/chat/human-action dependency; ineligible recovery emits a diagnostic, not an approval ask.
- All four local gates plus path preflight pass before any device window.
- `E2R-GJ4-001`: production UI Flash succeeds on the real DAYU200, postflight reads the flashed
  build from the device and V6/realHardware evidence truthfully records any recovery lineage. UI
  navigation alone is not PASS.

### r7 Stop conditions

- Stop before implementation if r7 maintainer adjudication merge is absent from protected main.
- Stop and revise this same change if implementation needs a new operation/provider/profile,
  effect downgrade, caller-supplied capability/trusted fact, or any path outside the reviewed
  scope.
- During hardware validation, never replay an unknown intent. Continue automatically only through
  durable `safeToReflash` or `safeToSupersedeByCompleteOverwrite`; hard-stop for unknown identity,
  incomplete coverage, undeclared Provider support, drift, cancellation or exhausted budget.
- Never consume or migrate a legacy standing/campaign record to make the new path pass.

### r9 DAYU200 singleton deliverables and verification

- Publish exactly one unversioned `dayu200` Catalog profile and remove both versioned files and all
  production references to `dayu200@1`/`dayu200@2`.
- Retain the current seed archive/build, nine-partition complete-overwrite coverage and
  write-forbidden facts; retain already-published generic observe/debug/deploy/flash capabilities.
- Publish the typed operation only as `flash.dayu200`, with no Catalog version field, while keeping
  its destructive effect/Steps/Provider unchanged and profile input enum exactly `dayu200`.
- Rename its singleton Catalog source file to `flash.dayu200.json`; assert the old `.v1.json`
  source path is absent and UI/CLI/Agent/Provider new writers expose no DAYU200 version suffix.
- Rename DAYU200 hitrace/bytrace family identifiers without `-v1`, refresh the registry digest,
  and leave the captured golden bytes and capability authority unchanged.
- Remove the old rev2/chat-attestation same-revision migration and its versioned selection digest;
  historical bindings remain readable but unprepared, unchanged and unable to authorize Flash.
- Keep old versioned request/capability/journal values decode/export-only; prove
  `flash.dayu200@1` cannot match the new operation or authorize/recover/dispatch it.
- Prove Catalog schema/generator/Swift parity; reject a bare/versioned mixture for one profile ID;
  prove both old profile strings fail lookup/admission with zero external dispatch.
- Do not rewrite historical evidence or guess that an incomplete old recovery is compatible. Such a
  Job remains blocked until exact durable proof satisfies the reviewed recovery contract.

### r10 Runtime-mediated candidate debugging deliverables

- Replace the retired campaign entry point with one Runtime-owned debug invocation. The invocation
  carries no human authority and uses the existing sixteen-epoch/four-hour/concurrency-one budget.
- Keep repairer/candidate in task-owned isolation with no Runtime socket, device transport,
  capability/fact/reservation/journal stores or raw target identity.
- Add a closed `CandidateDecision` grammar that can select only reviewed alternatives, bounded
  timing and published read-only observations. It cannot contain operation/profile, target,
  partition, Artifact, Step, effect, executable, argv, capability, outcome or coverage fields.
- Make protected-main Runtime independently re-materialize the published plan, read fresh trusted
  facts, validate the decision envelope and mint/reserve its exact capability before every use.
- Return structured, redacted failure observations to the isolated repair loop. A safe terminal may
  produce the next candidate without a Git task/change/PR/merge/chat prompt; unknown, cancellation,
  drift and budget stops remain non-overridable.
- Cover DAYU200 mode transition, bounded deadlines, unique post-flash HDC-personality selection and
  read-only postflight in the first reviewed repair envelope. Anything outside the envelope returns
  `repairSurfaceInsufficient` with zero new dispatch.
- Export one normal promotion candidate only after the real loop passes. The final source change is
  reviewed in one ordinary PR; per-attempt PRs are forbidden.
- Extend the invocation to the pre-admission UI path: a candidate may select only reviewed exact-app
  activation, bounded control-delivery alternatives and waits. The protected actuator owns action
  order, control identifiers, archive, target, plan facts and the sole submit action.
- Persist an exact pre-admission session. A refusal before submission has external dispatch 0 and
  may accept a materially distinct candidate; an interrupted submission blocks replay until the
  Runtime result is reconciled. Material identity includes the closed decision, protected actuator
  and actual executable digest from an isolated candidate App build.
- After App `job.submit` is accepted, capture the exact binding-pinned request without App client
  context as an owner-only, non-authoritative Runtime debug seed. A safe Runtime failure continues
  through the #1219 invocation, not through an intermediate source PR.

### r10 Verification

- Positive fake-provider flow: at least two distinct isolated candidates are built and evaluated in
  one invocation, the predecessor is durably `safeToReflash`, and the second reaches success with no
  Git/PR/merge or user-confirmation input.
- Negative matrix: unknown fields, out-of-range timing, new operation/profile/target/partition/Step,
  executable/argv, candidate facts/capability/outcome/coverage, digest drift, unknown predecessor,
  cancellation, attempt 17, elapsed four hours and concurrency two all produce external dispatch 0.
- Provenance: candidate source/build/decision digests are durable but explicitly non-authoritative;
  Runtime materialization/fresh facts/capability/reservation/outcome remain the admission record.
- Post-write failure: Runtime performs only reviewed read-only observation first and never reflashes
  unless ordinary `safeToReflash` or complete-overwrite recovery independently proves eligibility.
- Surface audit: active App/Agent/CLI/Runtime responses contain no instruction to merge a PR before
  the next eligible candidate; a genuine envelope miss reports `repairSurfaceInsufficient`.
- Real GJ-4: one explicit device window reaches success or one truthful non-overridable blocker
  without an intermediate PR. Simulation/fake/host green is not `REAL_DEVICE_PASS`.
- Pre-admission regression: candidate A may fail before Job creation and candidate B may reach the
  exact review barrier in the same durable session with dispatch 0 between them. Candidate input
  cannot name an app, archive, target, plan, control identifier, submit action, executable, argv,
  Runtime socket or authority.
- Handoff regression: only a successfully admitted App Flash request can produce the owner-only
  debug seed; `clientContext` is removed and no authority/campaign field is added. Unknown UI
  submission state blocks both another UI candidate and automatic destructive replay.

### r10 Stop conditions

- Before r10 review/merge, implementation is host-only and candidate-backed device dispatch is 0.
- Never run an unmerged broker or Provider against the device. The protected-main Runtime remains
  the only owner of transport, facts, plan, capability, reservation, journal and outcome.
- Stop with `repairSurfaceInsufficient` rather than widening the candidate grammar when a repair
  needs a new external effect, target rule, trusted fact, Step, command, partition or Provider plan.
