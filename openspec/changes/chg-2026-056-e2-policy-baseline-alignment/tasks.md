# Tasks

## TASK-E2B-001 — Remove the E2 authority lane and close GJ-4 through Runtime admission

- Status:blocked (awaiting maintainer approval of `CHG-2026-056@r5`; r1-r4 approval is not
  sufficient and proposal CI does not authorize implementation or hardware execution)
- Golden Journey:GJ-4
- Platform:macos; windows/linux contract compatibility only
- Requirements:`POL-AGENT-002`, `REQ-FLASH-007`, `REQ-FLASH-015`, `REQ-FLASH-016`,
  `REQ-FLASH-017`, `REQ-FLASH-018`, `REQ-WF-004`
- Acceptance:`AC-FLASH-007-01`, `AC-FLASH-015-01`, `AC-FLASH-015-02`, `AC-FLASH-015-03`,
  `AC-WF-004-01`, `AC-WF-004-02`, `AC-WF-004-03`, `E2R-CATALOG-001`,
  `E2R-RUNTIME-001`, `E2R-NEGATIVE-001`, `E2R-COMPAT-001`, `E2R-GJ4-001`
- Depends on:maintainer changes r5 proposal status to `approved` and merges it to protected `main`
- Production reachability:
  `ArkDeckApp/manual UI driver -> Agent XPC -> protected-main RuntimeJobEngine ->
  RuntimeCapabilityStore -> Rockchip Runtime composition -> typed Provider -> DAYU200`
- Trusted fact sources:Catalog from protected main; Runtime plan materializer; Artifact store/lease
  digests; Runtime target registry and same-attempt fresh readback; daemon-owned capability store,
  reservation and journal. Caller/candidate/repairer cannot construct these facts and their proof.
- Allowed paths:
  - `AGENTS.md`
  - `Catalog/schema/operation.schema.json`
  - `Catalog/operations/flash.dayu200.v1.json`
  - `Catalog/operations/deploy.native-library.system.v1.json`
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
  - `Packages/ArkDeckKit/Sources/ArkDeckCore/RuntimeOperationCatalogTypes.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckCore/RuntimeOperationCatalogGenerated.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckRuntime/RuntimeOperationModelsV2.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckStorage/RuntimeCapabilityStore.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckStorage/AuthorizationUsageLedger.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckStorage/JournalEvent.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckStorage/JournalEventValidation.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckStorage/JournalReplay.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckStorage/SessionManifest.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/EvolutionCampaignAuthority.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/FlashApplicationFacade.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RuntimeJobEngine.swift`
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
  - `Packages/ArkDeckKit/Sources/ArkDeckAgentDaemonMain/main.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckCLI/ArkDeckCLIMain.swift`
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
  - automatic retry/replay/recovery of unknown, unresolved or unsafe partial outcome
- Risk:destructive (the approved implementation intentionally removes per-plan human intent proof;
  real validation erases DAYU200 userdata)
- Hardware required:yes, but only after approved implementation passes every host gate
- Decision-Grade:D1 for Core implementation approval; D2 for the later physical device window

### Deliverables

- Apply the approved r5 deltas to Constitution, AGENTS, current specs/contracts, governance and
  verification registries without lowering the `destructive` effect.
- Replace the Catalog `oneShotExactPlan` writer policy for both published destructive operations
  with unified RuntimeCapability admission; update schema, generator vocabulary, generated Swift
  and catalog tests in lockstep.
- Make protected-main Runtime deterministically generate/consume the exact destructive capability
  from trusted facts. Remove standing/campaign from new admission while preserving versioned
  decode/export of historical records.
- Update Job/journal/recovery/evidence V5 projection so all new mutation/destructive Agent runs
  record `runtimeCapability`, and every mismatch/unknown/unsafe branch remains zero dispatch.
- Remove or relabel product/CLI/UI surfaces that present E2/campaign as a required authority. Keep
  truthful userdata-impact UX and keep Agent capability administration absent.
- Deliver a standalone `scripts/rockchip_component/manual_ui_flash.swift` driver that exercises
  the real signed App UI but is not part of any Xcode test target, Swift test target, default UI
  test plan or CI discovery.
- After all host gates pass, run that driver against the explicitly supplied DAYU200 archive and
  record truthful GJ-4 Job/Session/Artifact/postflight evidence. Fix product defects and repeat
  only when the preceding attempt is durably `safeToReflash` and the Runtime budget permits.

### Verification

- `E2R-CATALOG-001`: schema/generator/catalog/Swift parity and both destructive operations retain
  effect/Steps while no new Catalog writer emits `oneShotExactPlan`.
- `E2R-RUNTIME-001`: fake Provider positive path proves an Agent request reaches typed dispatch
  through Runtime-generated capability with no standing/campaign/user-message dependency.
- `E2R-NEGATIVE-001`: comprehensive fact drift, caller-forgery, reservation, lineage,
  unknown/unsafe/cancel/expiry/budget matrix proves external dispatch 0.
- `E2R-COMPAT-001`: V1-V4 authority/evidence decode/export remains byte-compatible while every
  legacy-to-new admission/migration attempt is rejected.
- All four local gates plus path preflight pass before any device window.
- `E2R-GJ4-001`: production UI Flash succeeds on the real DAYU200, postflight reads the flashed
  build from the device and evidence is V5/realHardware. UI navigation alone is not PASS.

### Stop conditions

- Stop before implementation if r5 is not `approved` on protected main.
- Stop and revise this same change if implementation needs a new operation/provider/profile,
  effect downgrade, caller-supplied capability/trusted fact, or any path outside the reviewed
  scope.
- During hardware validation, stop permanently for unknown identity/outcome, unresolved intent,
  unsafe partial, non-`safeToReflash` predecessor, cancellation after intent or exhausted budget.
- Never consume or migrate a legacy standing/campaign record to make the new path pass.
