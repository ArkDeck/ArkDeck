# Tasks — CHG-2026-070

CHG-2026-070@r1 已由维护者通过 PR #1443 review/merge；TASK-AFG-001 原实现
已通过 PR #1444，TASK-AFG-002 contract stage 已通过 PR #1449。protected-main
真机预检暴露 launcher authority-liveness 产品缺陷，本轮先按其原职责边界完成
垂直修复，再继续 operation availability 与 real-device cutover。

## TASK-AFG-001 — ArkForge Swift SDK and release bundle

- Status:in-progress（proposal #1443、原实现 #1444 已合入；AFG-AC-9 预检暴露
  launcher authority-liveness 产品缺陷，本垂直修复待维护者 review/merge）
- Platform: macos
- Hardware required: no
- Production reachability: ArkDeck agentd → ArkForgeClient → local daemon
- Acceptance: AFG-AC-1..3
- Review boundary:`CHG-2026-070-arkforge-generic-integration@r1` was merged by
  PR #1443 and the original implementation was merged by PR #1444. This
  remediation is limited to launcher descriptor lifetime and its contract tests.
- Allowed paths:
  - `Packages/ArkDeckKit/**`
  - 本 change `**`
- Forbidden: capability/admission/journal/recovery semantics

Deliver the cross-language SDK, byte-identical golden frames, validated bundle
manifest, one-key LaunchAgent configuration and legacy receipt migration.

Protected-main AFG-AC-9 preflight on 2026-08-21 failed closed before device
mutation: ArkDeck delivered the 32-byte pairing secret and immediately closed
the pipe which ArkForge defines as its parent-authority liveness capability, so
`arkforged` correctly exited as orphaned. This remediation retains the liveness
descriptor for the exact daemon handle lifetime.

## TASK-AFG-002 — Generic operation and alias cutover

- Status:in-progress（AFG-AC-4..8 已通过、实现 #1449 已合入；等待
  TASK-AFG-001 launcher 修复后完成 availability 垂直修复与真机 cutover）
- Platform: macos
- Hardware required: no for contract stage; yes for final cutover
- Golden Journey: GJ-4
- Acceptance: AFG-AC-4..8
- Allowed paths:
  - `Catalog/**`
  - `Packages/ArkDeckKit/Sources/ArkDeckAgentClient/HardwareEvidenceProjector.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckAgentDaemon/AgentXPCListener.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckAgentDaemonMain/main.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckCLI/ArkDeckCLIMain.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckCore/ArkForgeFlashOperation.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckCore/RuntimeOperationCatalogGenerated.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckCore/RuntimeOperationCatalogTypes.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/ArkForgeFlashRequest.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/ArkForgeFlashSession.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/ArkForgeLaneComposition.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/Artifacts/RuntimeArtifactService.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/DeviceProviders/DescriptorBoundProcessDispatcher.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/DeviceProviders/DeviceProviderAdapters.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/DeviceProviders/DeviceProviderContract.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/DeviceProviders/RockchipRuntimeActionHost.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/DeviceProviders/RockchipRuntimeComposition.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/FlashApplicationFacade.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/OverviewCapabilityApplicationFacade.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RockchipTargetAliasReconciliation.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RuntimeHistoryApplicationFacade.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RuntimeJobEngine.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RuntimeRecoveryService.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/AgentDaemonContractTests.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/ArchitectureBoundaryContractTests.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/ArkForgeFlashSessionContractTests.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/ArkForgeLaneAssemblyContractTests.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/CompleteOverwriteRecoveryContractTests.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/Dayu20070035RuntimePlanOnlyContractTests.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/DeviceProviderContractTests.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/FlashApplicationFacadeContractTests.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/FlashArtifactContractTests.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/ObserveDeviceSkeletonContractTests.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/OverviewCapabilityApplicationFacadeContractTests.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/RockchipRuntimeCompositionContractTests.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/RuntimeArtifactContractTests.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/RuntimeE2CapabilityConsumeContractTests.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/RuntimeOperationCatalogContractTests.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckCoreTests/RuntimeOperationCatalogTests.swift`
  - `scripts/catalog_gen/generate.py`
  - `scripts/catalog_gen/test_generate.py`
  - `scripts/manual_ui_flash/manual_ui_flash.swift`
  - `openspec/changes/chg-2026-070-arkforge-generic-integration/tasks.md`
  - `openspec/changes/chg-2026-070-arkforge-generic-integration/verification.md`
- Forbidden: raw RockUSB commands/addresses in ArkDeck production lowering;
  changes to permit integrity, durable single-use or recovery classification

Publish `flash.full-restore@1`, retain `flash.dayu200` only as a compatibility
alias to the same adapter, switch new UI requests and remove literal branching
from production consumers.

## TASK-AFG-003 — Real-device cutover

- Status:blocked（等待 TASK-AFG-001 launcher 与 TASK-AFG-002 availability 修复合入）
- Platform: macos
- Hardware required: yes, DAYU200
- Golden Journey: GJ-4
- Acceptance: AFG-AC-9

Run canonical and alias plan-parity checks against the same artifact/target,
then one canonical full restore with postflight verification. Record exact
catalog/bundle/toolchain digests. Do not replay a destructive alias job merely
to prove naming parity.
