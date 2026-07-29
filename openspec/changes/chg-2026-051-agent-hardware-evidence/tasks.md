# Tasks

## TASK-AHE-001 — Promote V3 and close trusted Runtime evidence projection

- Status:ready（仅在 r4 proposal PR 被维护者 review + merge 后生效；合并前 current
  main 的 r3 任务因下述 durable journal registry stop condition 保持 blocked）
- Historical Status:blocked（r1 开工后审计发现唯一生产 facts port 与 Catalog
  preflight 不可闭合 model/firmware/transport/fresh time；r2 开工后审计发现
  `runApprovedRemoteRead` actionRef 无法由 current Catalog schema/generator 表达，
  derived matrix 与受影响 fixtures 又不在 Allowed paths；r3 首次实现编译发现
  `WorkflowStep.runApprovedRemoteRead` 的独立 sealed action registry 不接受新增
  `deviceModel` / `firmwareBuild`，且源码/测试不在 Allowed paths）
- Grade:D1
- Platform:macos
- Requirements:`REQ-WF-004`
- Acceptance:`AC-WF-004-01`、`AC-WF-004-02`、`AC-WF-004-03`
- Depends on:
  - r4 proposal PR 合并；
  - `CHG-2026-046` archived；
  - `CHG-2026-049/TASK-DHA-001` implementation 已合入；
  - `CHG-2026-025/TASK-AIN-002` done（只作为 schema migration 输入，不借用其
    scoped delta）
- Readiness base:`0eb95fe9e34105571a93947cd5c7fd07e91c1092`
- Readiness input pins:

  ```yaml pins
  - path: Catalog/operations/observe.device.v1.json
    blob: 6efb682bd5e07cd4cab49667b714a889fa44fc56
  - path: Catalog/operations/capture.diagnostics.v1.json
    blob: 37ce723faf58780e00c11f5718f78a4271aef5ae
  - path: Catalog/operations/debug.hap.v1.json
    blob: 1189c9f5d4e73eab71c8ec3d52e7aa53eadf1627
  - path: Catalog/schema/operation.schema.json
    blob: d0320ec62c6346fb59e6fa21d59533e851ce52d0
  - path: Catalog/generated/effect-authorization-matrix.md
    blob: 7dde378010da7acb85b4bd75206389a0904c8905
  - path: openspec/contracts/catalogs/remote-operations.yaml
    blob: fe3841d992bbae89bb8f954a1bcdeab0c4f714d1
  - path: openspec/contracts/hardware-evidence.schema.json
    blob: 98443833b5bef36f4a1e0fdea9dbaaccf057f4d1
  - path: openspec/changes/chg-2026-025-ai-native-unattended-device-ops/contracts/hardware-evidence.schema.v3-draft.json
    blob: 492aa3d5107c6790f56df1fff336280578494364
  - path: openspec/specs/workflow-journal-recovery/spec.md
    blob: f97c64785533f832d6798a63e8c7c96080bb7b69
  - path: Packages/ArkDeckKit/Sources/ArkDeckAgentClient/AgentRuntimeExecutor.swift
    blob: b578e5cec9d902bf36d42b48baeb6a08afb15c15
  - path: Packages/ArkDeckKit/Sources/ArkDeckCore/RuntimeOperationCatalogGenerated.swift
    blob: c4f22f82ab983dc6ae8a119d52598aed50d9f434
  - path: Packages/ArkDeckKit/Sources/ArkDeckCore/RuntimeOperationCatalogTypes.swift
    blob: f51d5f327a12f8f0b681a651c3d435107ccd318e
  - path: Packages/ArkDeckKit/Sources/ArkDeckCore/WorkflowStep.swift
    blob: 6aae31f911ca56f14676c5ae94fd975576daea0f
  - path: Packages/ArkDeckKit/Sources/ArkDeckAgentDaemon/AgentDaemon.swift
    blob: df101a19617eba7af1ffe1e3bc71a887b8d5accf
  - path: Packages/ArkDeckKit/Sources/ArkDeckAgentDaemonMain/main.swift
    blob: 2187ab2c1369edca9c6bf7c9d1700f1a084fee08
  - path: Packages/ArkDeckKit/Sources/ArkDeckOpenHarmony/HDCCompatibilityProfile.swift
    blob: 72456f72f9667d2a2a00644db468f47911549091
  - path: Packages/ArkDeckKit/Sources/ArkDeckWorkflows/Bootstrap/DeviceBootstrap.swift
    blob: b953fc1af65e3052bea7a4c8cae67b65c0301fbb
  - path: Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RuntimeJobEngine.swift
    blob: 6802d11fe28a490c5a6c9b181dc814d071f51c54
  - path: Packages/ArkDeckKit/Sources/ArkDeckWorkflows/Artifacts/RuntimeArtifactStore.swift
    blob: 0e7b7260d9f19c04494a7717eb61cf05385fc0bb
  - path: Packages/ArkDeckKit/Sources/ArkDeckWorkflows/DeviceProviders/DeviceProviderContract.swift
    blob: f4887989019ec357f7e77ad659e89099d2b41a4a
  - path: Packages/ArkDeckKit/Sources/ArkDeckWorkflows/DeviceProviders/DeviceProviderAdapters.swift
    blob: 24aafbcc8bdf14dd96077f876a43133bdd6e137a
  - path: Packages/ArkDeckKit/Sources/ArkDeckWorkflows/DeviceProviders/HDCE0ActionPack.swift
    blob: 828989e98cb81ffc44d6f7c125fbe1068aa3f83c
  - path: Packages/ArkDeckKit/Tests/ArkDeckContractTests/AgentRuntimeExecutorContractTests.swift
    blob: 374ff594920441b86735fb4095e93886fed0e452
  - path: Packages/ArkDeckKit/Tests/ArkDeckContractTests/AgentDaemonContractTests.swift
    blob: fe16f1e37b44c977a6575f2418642983fa089bd7
  - path: Packages/ArkDeckKit/Tests/ArkDeckContractTests/DeviceBootstrapContractTests.swift
    blob: 5e3d41a6c6cb2a081fc821f6b22ec5981231125f
  - path: Packages/ArkDeckKit/Tests/ArkDeckContractTests/DeviceProviderContractTests.swift
    blob: e6ca2052ea28276dce0c554a652bfe6e383a638b
  - path: Packages/ArkDeckKit/Tests/ArkDeckContractTests/DiagnosticsAndHAPContractTests.swift
    blob: 38e0470a410ced2ed79e490769fac7ab22617551
  - path: Packages/ArkDeckKit/Tests/ArkDeckContractTests/HDCE0ActionPackContractTests.swift
    blob: bdffd2f27b5d0bf2ae55442e236356e899723665
  - path: Packages/ArkDeckKit/Tests/ArkDeckContractTests/ObserveDeviceSkeletonContractTests.swift
    blob: 778f87c58e293d3e03aac5c60cd4b5375aa5f984
  - path: Packages/ArkDeckKit/Tests/ArkDeckContractTests/RuntimeArtifactContractTests.swift
    blob: d1c100881a64e8b3c6c88d2e8d43663e0b6a9924
  - path: Packages/ArkDeckKit/Tests/ArkDeckContractTests/RuntimeJobEngineContractTests.swift
    blob: b917578af44e06d031f904d6ed453b4bffc2466d
  - path: Packages/ArkDeckKit/Tests/ArkDeckContractTests/RuntimeOperationCatalogContractTests.swift
    blob: 431aa5259527ceec64f171bac881ac0da8ba8cd0
  - path: Packages/ArkDeckKit/Tests/ArkDeckContractTests/WorkflowStepContractTests.swift
    blob: 15c0df7363b2549f7a64230ef2c7a7f1c2d60861
  - path: Packages/ArkDeckKit/Tests/ArkDeckFakeHDCFixture/main.swift
    blob: bd4b0beb792b8a7989930679a28db9b6ec4db42a
  - path: scripts/catalog_gen/generate.py
    blob: d17aaa56616cd5149d1d16b3b8d084bddc715f62
  - path: scripts/catalog_gen/test_generate.py
    blob: 275f7c0acd6246c21203e2f1dff253fb4b8cb6a1
  - path: AGENTS.md
    blob: f0d6812599c7e1d8d3d58fe9efdd03d0c1a27c0b
  - path: openspec/governance/enforcement.md
    blob: c65f050778fd2faba95ee61193cbd075c8c3520f
  - path: openspec/verification/policy.md
    blob: ef3b42085ff50b54f1bb70650510f27bdc020cf1
  - path: openspec/verification/core-conformance.yaml
    blob: 799d0051463f9aed50ff3c9e50045ef06f61c35e
  - path: openspec/verification/hardware-matrix.md
    blob: 26caa0c77e88ab543aab46e6f39ee878b460146b
  ```
- Applicable failure patterns:
  `AF-001`（schema、producer、consumer 与 conformance 必须同车）、
  `AF-004`（trusted-fact producer 到 evidence consumer 端到端闭合）、
  `AF-005`（不得把 caller fields 当 authority/evidence）、
  `AF-012`（旧 receipt/旧 binding 不得跨 run 复用）
- Production reachability:
  `published Catalog operation → Runtime admission authority → durable target/job/step
  records → provider observations + artifact store → RuntimeAgentExecutionReceipt →
  hardware-evidence V3 projector`。三个 evidence-eligible operation 在 capture/E1
  前有 required `confirm-evidence-target → read-evidence-model →
  read-evidence-firmware` typed prefix；每步独立 WAL，provider 以 durable connectKey
  精确选目标。projector 只记录既有 execution，不产生 authority，effect dispatch
  point 仍在 RuntimeJobEngine/provider。
- Trusted fact sources:
  - executor/operation/job/catalog：Agent runner 与 daemon health/job record；
  - authority：Runtime admission 的 durable decision；E0 为 reviewed default policy，
    E1/E2 为已存在 capability/authorization reference；
  - target/serial digest/transport：exact durable connectKey 与 target-list typed outcome
    在 provider 内匹配并散列；model/firmware：两个无 caller 参数的 exact
    `runApprovedRemoteRead` outcome；binding 来自 target-store 与 request 的双向
    correlation；confirmation time 为最后一条 required preflight outcome time；
  - actual step kinds/effect：durable intents/outcomes 按 registry 计算最大 effect；
  - toolchain/provider/transport：production discovery/provider receipt；
  - Artifact reference/hash：RuntimeArtifactStore 发布后的 immutable metadata/bytes。
  Runtime request/caller 只能给 operation、typed inputs、target/capability reference；
  post-run evidence packaging 只可给 `evidenceId`、`acceptanceIds`、`validUntil`、
  `notes` 等 claim metadata。两者都不能给上述 trusted facts、authority 或
  “schema-valid/PASS”结论。
- Allowed paths:
  - `AGENTS.md`
  - `openspec/contracts/hardware-evidence.schema.json`
  - `openspec/contracts/catalogs/remote-operations.yaml`
  - `Catalog/operations/observe.device.v1.json`
  - `Catalog/operations/capture.diagnostics.v1.json`
  - `Catalog/operations/debug.hap.v1.json`
  - `Catalog/schema/operation.schema.json`
  - `Catalog/generated/effect-authorization-matrix.md`
  - `openspec/governance/enforcement.md`
  - `openspec/verification/policy.md`
  - `openspec/verification/core-conformance.yaml`
  - `openspec/verification/hardware-matrix.md`
  - `Packages/ArkDeckKit/Sources/ArkDeckAgentClient/AgentRuntimeExecutor.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckAgentClient/HardwareEvidenceProjector.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckCore/RuntimeOperationCatalogGenerated.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckCore/WorkflowStep.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckAgentDaemon/AgentDaemon.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckAgentDaemonMain/main.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckOpenHarmony/HDCCompatibilityProfile.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/Bootstrap/DeviceBootstrap.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/Artifacts/RuntimeArtifactStore.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/DeviceProviders/DeviceProviderContract.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/DeviceProviders/DeviceProviderAdapters.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/DeviceProviders/HDCE0ActionPack.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RuntimeJobEngine.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/AgentRuntimeExecutorContractTests.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/AgentDaemonContractTests.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/HardwareEvidenceProjectionContractTests.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/DeviceBootstrapContractTests.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/RuntimeArtifactContractTests.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/RuntimeJobEngineContractTests.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/DeviceProviderContractTests.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/DiagnosticsAndHAPContractTests.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/HDCE0ActionPackContractTests.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/ObserveDeviceSkeletonContractTests.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/RuntimeOperationCatalogContractTests.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/WorkflowStepContractTests.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckFakeHDCFixture/main.swift`
  - `openspec/changes/chg-2026-051-agent-hardware-evidence/**`
- Forbidden paths:
  - `openspec/constitution.md`
  - `openspec/specs/**`
  - `openspec/baselines/**`
  - `Catalog/**`（上列三个 operation、operation schema 与 generated matrix 除外）
  - `openspec/integrations/**`
  - `openspec/platforms/**`
  - `openspec/changes/**`（本 change 除外）
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/StandingAuthorization.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/Rockchip*/**`
  - `.github/**`
  - `ArkDeckApp/**`
- Risk:high（Core required-field migration + realHardware 证据诚信；零设备 dispatch）
- Hardware required:no（schema/projector 与 production Catalog/provider path 使用
  descriptor-bound fake HDC/target/artifact fixtures；fresh 真机 evidence 由消费方
  change 在 archive 后另行 readiness）

### Deliverables

- current hardware-evidence V3 schema 与 stdlib/既有测试栈可运行的正反例 validator；
- Catalog schema/generator 只允许 `runApprovedRemoteRead` 引用
  `arkdeck-remote-operations` 中 step-kind 精确匹配的 action；两个 generated outputs
  零 drift，unknown/missing/cross-kind reference 均拒绝；
- durable WorkflowStep registry 精确接受 `deviceModel` / `firmwareBuild`，journal
  intent 与 Catalog/provider action 零漂移，unknown action 仍拒绝；
- 三个 production operation 的 exact-target/model/firmware typed preflight 在任何
  artifact capture/E1 step 前完成；Catalog/generated Swift/remote-operation mapping
  零 drift，未知/歧义 target 零后续 dispatch；
- Runtime target/receipt/projector 闭合 V3 required facts，不接受 caller 自报；
- legacy target-store record 可读但 evidence-ineligible，fresh typed preflight 后才建立
  model/firmware/confirmation facts；
- E0/E1/E2 authority/effect 条件校验与 schema/Swift parity；
- missing/stale/mismatch/unknown/Artifact hash failure 均输出
  `evidenceIncomplete`，realHardware publication count 为 0；
- current governance/conformance 文案与 V3 对齐，历史 matrix rows 与 evidence bytes
  零改写；
- implementation run 记录包含命令、测试结果、AC 结论、偏差与残余风险，任务状态随
  同一 PR `ready → done`。

### Verification

- `AC-WF-004-01` → Agent E0 positive vector + schema/Swift round-trip →
  receipt 与 V3 record 包含同 binding 的 firmware/confirmation/step/artifact facts。
- `AC-WF-004-02` → required fact 缺失、stale/mismatch、caller injection、raw serial、
  unavailable artifact vectors → `evidenceIncomplete` 且 publication count 0。
- `AC-WF-004-03` → actual effect × authority matrix →
  E0/default policy、E1/runtime capability、E2/standing authorization 精确匹配；
  mismatch/unknown 为 0 publication，schema validation 不授予 device dispatch。
- `scripts/check-sdd.sh`、V3 schema vectors、相关 Swift contract tests与完整
  `swift test --package-path Packages/ArkDeckKit`。

### Stop conditions

- 需要改变 r3 已列明之外的 Catalog operation/effect/typed step 或 provider/profile
  语义；
- 需要修改 E2 execution policy、创建/修改 capability/authorization；
- model/firmware/confirmation/step/artifact 任一事实只能由 caller 提供；
- 只能通过放宽 required field、接受 raw serial、复用旧 binding/receipt 或把
  fake/simulation 计为硬件证据才能通过；
- schema 与 Swift projector 无法对同一 canonical record 保持一致。

任一命中即保持 blocked，并新提 scoped remediation；不得静默扩大本任务。

### Notes / handoff

实现完成后在 `evidence/runs/TASK-AHE-001/` 追加 run 记录。change verified/archive
后，`CHG-2026-049` 仍须 fresh readiness 和新 E0 run；不得复用 attempt#2。
r1/r2 scope 下的未完成代码只作为本地可恢复 WIP，不是 run evidence、实现提交或
Acceptance 结论；r3 合入后必须在 fresh base 重放并按完整 Catalog contract +
typed preflight 设计复审。
