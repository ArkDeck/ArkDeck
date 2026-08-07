# Tasks

## TASK-E2B-001 — Close GJ-4 with Runtime-owned admission and autonomous proven recovery

- Status:blocked (r5/r6 implementation is present on protected main through #1183; r7 autonomous
  complete-overwrite recovery awaits maintainer review/merge before implementation or hardware use)
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
- Depends on:maintainer reviews and merges CHG-2026-056@r7 to protected `main`
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
  - `Catalog/operations/flash.dayu200.v1.json`
  - `Catalog/operations/deploy.native-library.system.v1.json`
  - `Catalog/profiles/dayu200.v1.json` (notes text only; identity and partition mapping are forbidden)
  - `Catalog/profiles/dayu200.v2.json`
  - `Catalog/generated/effect-authorization-matrix.md`
  - `openspec/constitution.md`
  - `openspec/specs/flashing/spec.md`
  - `openspec/specs/workflow-journal-recovery/spec.md`
  - `openspec/contracts/provider-contracts.md`
  - `openspec/contracts/hardware-evidence.schema.json`
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
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/FlashApplicationFacade.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RuntimeJobEngine.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RuntimeRecoveryService.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RuntimeHistoryApplicationFacade.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RockchipAuthorizationFacts.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RockchipFlashAuthorization.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RockchipFlashExecution.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RockchipFlashExecutionHost.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RockchipFlashSessionReconcile.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/DeviceProviders/**`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/AgentComposition/HarnessAdapters/**`
  - `Packages/ArkDeckKit/Sources/ArkDeckAgentClient/HardwareEvidenceProjector.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckAgentDaemon/AgentDaemon.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckAgentDaemon/AgentXPCListener.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckAgentDaemonMain/main.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckRuntime/HumanActionRequired.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckCLI/ArkDeckCLIMain.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckCLI/ArkDeckRuntimeCommands.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckHarness/Application/HarnessPolicyGuard.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckHarness/Domain/HarnessEvolution.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/**`
  - `Packages/ArkDeckKit/Tests/ArkDeckCoreTests/**`
  - `ArkDeckApp/Features/Flash/**`
  - `ArkDeckApp/Resources/FlashLocalizable.xcstrings`
  - `ArkDeckAppUITests/AppShell/AppShellUITests.swift`
- Forbidden paths:
  - integration/device profile identity or partition mapping beyond the exact stale note above
  - new operation, Provider, raw command surface, executable/argv input or effect downgrade
  - caller/Agent capability administration or trusted-fact injection
  - legacy authority instance bytes or migration into RuntimeCapability
  - retry/replay or guessed outcome for an unknown intent; recovery without a reviewed exact
    Provider coverage contract and complete Runtime-derived proof
- Risk:destructive (r7 intentionally permits a distinct full-overwrite dispatch after an unknown
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
