# Tasks

## TASK-ATI-002 — Publish typed ArkTrace deep analysis

- Status:in-progress（四件套、Catalog、production Runtime、测试与 evidence 同车；维护者
  review/merge 前不声称 published）
- Platform:macos
- Requirements:ATD-REQ-001, ATD-REQ-002, ATD-REQ-003, ATD-REQ-004
- Acceptance:ATD-AC-1..ATD-AC-8
- Depends on:TASK-ATI-001 merged by PR #1309 (`528b521c7a6ace44e225ffbc3d1e1797b9c1a54f`)
- Golden Journey:GJ-5 Bounded AI Debug Loop
- Base-tree path task:`TASK-HFA-007`（最终 commit subject 使用该 ID；本新 Task 只作同车
  operation review supplement，不授予路径权限）
- Production reachability:`ArkDeckAgentDaemonMain → Runtime submit/admission → AnalyzerProvider
  → DescriptorBoundProcessDispatcher → RuntimeArtifactStore`
- Hardware required:no（signed macOS profile replay required；Large Trace deferred）
- Allowed paths:
  - `Catalog/operations/analyzer.analyze-trace.v1.json`
  - `Catalog/generated/**`
  - `Packages/ArkDeckKit/Sources/ArkDeckCore/RuntimeOperationCatalogGenerated.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckCore/WorkflowStep.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckAgentDaemonMain/**`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/AnalyzerProvider/**`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/Artifacts/RuntimeArtifactService.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/Artifacts/RuntimeArtifactStore.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/DeviceProviders/**`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RuntimeJobEngine.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckCoreTests/**`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/**`
  - `scripts/catalog_gen/test_generate.py`
  - `docs/adr/**arktrace**`
  - `evidence/runs/TASK-ATI-002/**`
  - `openspec/changes/chg-2026-060-arktrace-deep-analysis/**`
- Forbidden paths:
  - `Catalog/operations/analyzer.summarize-trace.v1.json`
  - `openspec/constitution.md`
  - `openspec/specs/**`
  - `openspec/contracts/**`
- Risk:medium

### Deliverables

- New generated Catalog descriptor and operation-set locks.
- Submit-time closed cross-field validation.
- Shared pinned profile with action-specific analysis lowering.
- Closed context/analyze result validator and exact Artifact publisher.
- Source/provenance, budget, cancellation, recovery and compatibility regressions.
- Signed profile replay evidence; no fake counted as platform trust.

### Verification

- Run catalog generator unittest + zero-drift.
- Run focused Analyzer/Runtime/Artifact tests.
- Run full ArkDeckKit Swift suite selected by `scripts/ci/plan.py`.
- Run real signed ArkTrace profile replay when the reviewed descriptor is available.
- Run final `check_pr_paths.py --preflight` against `origin/main`.
