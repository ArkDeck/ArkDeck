# Tasks — CHG-2026-070

CHG-2026-070@r1 已由维护者通过 PR #1443 review/merge；TASK-AFG-001 原实现
已通过 PR #1444、launcher authority-liveness 修复已通过 PR #1454，TASK-AFG-002
contract stage 已通过 PR #1449。AOT XPC bridge 与 remote-view file panel 修复已分别
通过 PR #1455、#1456，sidebar fallback 已通过 PR #1457；protected-main 真机预检
已到达 Runtime ready 并完成 canonical/alias plan parity。PR #1457 依赖的可见 row
文本未出现在原始 AX attributes，现改用既有受校验 external candidate 完成非提交导航；
同时修复 macOS 26 AppKit remote file panel 暂时接管前台时的精确归属判定后继续 cutover。

## TASK-AFG-001 — ArkForge Swift SDK and release bundle

- Status:done（proposal #1443、原实现 #1444、launcher authority-liveness 修复
  #1454 均已合入；protected-main 预检确认 ArkForge lane ready）
- Platform: macos
- Hardware required: no
- Production reachability: ArkDeck agentd → ArkForgeClient → local daemon
- Acceptance: AFG-AC-1..3
- Review boundary:`CHG-2026-070-arkforge-generic-integration@r1` was merged by
  PR #1443, the original implementation by PR #1444, and the launcher
  descriptor-lifetime remediation by PR #1454.
- Allowed paths:
  - `Packages/ArkDeckKit/**`
  - 本 change `**`
- Forbidden: capability/admission/journal/recovery semantics

Deliver the cross-language SDK, byte-identical golden frames, validated bundle
manifest, one-key LaunchAgent configuration and legacy receipt migration.

Protected-main AFG-AC-9 preflight on 2026-08-21 failed closed before device
mutation because the parent-authority liveness descriptor was closed early.
PR #1454 retained it for the exact daemon handle lifetime; the 2026-08-22
preflight reached `execution: ready` and composed the DAYU200 lane.

## TASK-AFG-002 — Generic operation and alias cutover

- Status:in-progress（AFG-AC-4..8 已通过、实现 #1449 及 actuator 修复 #1455–
  #1457 已合入；正在修复 macOS 26 App-owned remote file panel 前台判定）
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

- Status:blocked（等待 TASK-AFG-002 macOS 26 App-owned remote file panel 修复合入；
  typed Job 队列为空，既有 unknown lineage 已有 Runtime resolution 归属，禁止重放原
  destructive effect）
- Platform: macos
- Hardware required: yes, DAYU200
- Golden Journey: GJ-4
- Acceptance: AFG-AC-9

Run canonical and alias plan-parity checks against the same artifact/target,
then one canonical full restore with postflight verification. Record exact
catalog/bundle/toolchain digests. Do not replay a destructive alias job merely
to prove naming parity.
