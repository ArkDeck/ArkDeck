# Tasks

## TASK-RIW-001 — Publish the Runtime-owned isolated workspace lane

- Status:in-progress (change, implementation, tests and evidence share one vertical PR;
  maintainer merge is the publication decision)
- Platform:macos
- Golden Journey:GJ-5 Bounded AI Debug Loop
- Base-tree path task:`TASK-HFA-008` (the final commit subject uses this pre-existing
  Task; this new Task is a review supplement and grants no paths)
- Requirements:RIW-REQ-001, RIW-REQ-002, RIW-REQ-003, RIW-REQ-004
- Acceptance:RIW-AC-1..RIW-AC-6
- Depends on:TASK-HFA-009 workspace subject/capability boundary; TASK-HFA-014
  persisted evolution workspace; CHG-2026-057 typed OpenHarmony signing
- Hardware required:no for this PR (the later WaterFlow device replay remains a
  separate real-device result and must not be claimed by contract tests)
- Production reachability:`ArkDeckAgentDaemonMain → RuntimeJobEngine →
  WorkspaceOperationsProvider → RuntimeOwnedWorkspaceDispatcher →
  EvolutionWorkspaceManager → RuntimeArtifactStore`
- Allowed paths:
  - `Catalog/operations/workspace.prepare-isolated-copy.v1.json`
  - `Catalog/operations/workspace.build-openharmony.v1.json`
  - `Catalog/generated/**`
  - `Packages/ArkDeckKit/Sources/ArkDeckAgentDaemonMain/**`
  - `Packages/ArkDeckKit/Sources/ArkDeckCore/RuntimeOperationCatalogGenerated.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckCore/WorkflowStep.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/AgentComposition/**`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/Artifacts/RuntimeArtifactService.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/DeviceProviders/**`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RuntimeJobEngine.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/WorkspaceProvider/**`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/DeviceProviderContractTests.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/HarnessEvolutionContractTests.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/HostOnlyAdmissionContractTests.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/RuntimeOwnedWorkspaceContractTests.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/WorkspaceProviderContractTests.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckCoreTests/RuntimeOperationCatalogTests.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckCoreTests/WorkflowStepContractTests.swift`
  - `openspec/contracts/workflow-step.schema.json`
  - `openspec/contracts/workflow-step-registry.yaml`
  - `scripts/catalog_gen/test_generate.py`
  - `evidence/runs/TASK-RIW-001/**`
  - `openspec/changes/chg-2026-061-runtime-isolated-workspace/**`
- Forbidden paths:
  - `openspec/constitution.md`
  - `openspec/specs/**`
  - `AGENTS.md`
  - `PRODUCT-LOOP.md`
  - `.github/**`
  - `ArkDeckApp/**`
  - `ArkDeck.xcodeproj/**`
- Risk:high (new operation plus capability selection; mitigated by exact source/copy
  revisions, path-free typed action, private root, restart readback and shared-tree
  negative contracts)

### Deliverables

- Closed Catalog descriptor and generated operation table.
- Persisted typed isolation action, host-only plan and composition dispatcher.
- Evolution workspace create/readback/startup-adoption lifecycle.
- Optional measured `unsigned.hap` publication from a declared build product.
- End-to-end Runtime contract proving restart, capability separation and source-tree
  isolation.
- Bounded run evidence and final path preflight in the same PR.

### Verification

- Catalog generator tests and zero-drift check.
- `RuntimeOwnedWorkspaceContractTests` plus Workspace/Harness/Runtime regressions.
- Full ArkDeckKit suite selected by `scripts/ci/plan.py`.
- `check_pr_paths.py --preflight` against `origin/main` after the final commit.
