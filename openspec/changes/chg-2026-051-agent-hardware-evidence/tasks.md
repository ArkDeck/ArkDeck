# Tasks

## TASK-AHE-001 — Promote V3 and close trusted Runtime evidence projection

- Status:ready（仅在本 proposal PR 被维护者 review + merge 后生效）
- Grade:D1
- Platform:macos
- Requirements:`REQ-WF-004`
- Acceptance:`AC-WF-004-01`、`AC-WF-004-02`、`AC-WF-004-03`
- Depends on:
  - 本 proposal PR 合并；
  - `CHG-2026-046` archived；
  - `CHG-2026-049/TASK-DHA-001` implementation 已合入；
  - `CHG-2026-025/TASK-AIN-002` done（只作为 schema migration 输入，不借用其
    scoped delta）
- Readiness base:`9637df189b560af2e27bd65ddbf082aae9ce4621`
- Readiness input pins:

  ```yaml pins
  - path: openspec/contracts/hardware-evidence.schema.json
    blob: 98443833b5bef36f4a1e0fdea9dbaaccf057f4d1
  - path: openspec/changes/chg-2026-025-ai-native-unattended-device-ops/contracts/hardware-evidence.schema.v3-draft.json
    blob: 492aa3d5107c6790f56df1fff336280578494364
  - path: openspec/specs/workflow-journal-recovery/spec.md
    blob: f97c64785533f832d6798a63e8c7c96080bb7b69
  - path: Packages/ArkDeckKit/Sources/ArkDeckAgentClient/AgentRuntimeExecutor.swift
    blob: b578e5cec9d902bf36d42b48baeb6a08afb15c15
  - path: Packages/ArkDeckKit/Sources/ArkDeckAgentDaemon/AgentDaemon.swift
    blob: df101a19617eba7af1ffe1e3bc71a887b8d5accf
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
  - path: Packages/ArkDeckKit/Tests/ArkDeckContractTests/DeviceBootstrapContractTests.swift
    blob: 5e3d41a6c6cb2a081fc821f6b22ec5981231125f
  - path: Packages/ArkDeckKit/Tests/ArkDeckContractTests/RuntimeArtifactContractTests.swift
    blob: d1c100881a64e8b3c6c88d2e8d43663e0b6a9924
  - path: Packages/ArkDeckKit/Tests/ArkDeckContractTests/RuntimeJobEngineContractTests.swift
    blob: b917578af44e06d031f904d6ed453b4bffc2466d
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
  hardware-evidence V3 projector`。projector 只记录既有 execution，不产生 authority，
  effect dispatch point 仍在 RuntimeJobEngine/provider。
- Trusted fact sources:
  - executor/operation/job/catalog：Agent runner 与 daemon health/job record；
  - authority：Runtime admission 的 durable decision；E0 为 reviewed default policy，
    E1/E2 为已存在 capability/authorization reference；
  - target/model/serial digest/firmware/binding/confirmation time：同 run/target/binding
    的 descriptor-bound typed E0 preflight readback；它在 evidence-bearing capture
    与任何 E1/E2 step 前完成并 durable 记录 outcome/time；
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
  - `openspec/governance/enforcement.md`
  - `openspec/verification/policy.md`
  - `openspec/verification/core-conformance.yaml`
  - `openspec/verification/hardware-matrix.md`
  - `Packages/ArkDeckKit/Sources/ArkDeckAgentClient/AgentRuntimeExecutor.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckAgentClient/HardwareEvidenceProjector.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckAgentDaemon/AgentDaemon.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/Bootstrap/DeviceBootstrap.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/Artifacts/RuntimeArtifactStore.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/DeviceProviders/DeviceProviderContract.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/DeviceProviders/DeviceProviderAdapters.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/DeviceProviders/HDCE0ActionPack.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RuntimeJobEngine.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/AgentRuntimeExecutorContractTests.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/HardwareEvidenceProjectionContractTests.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/DeviceBootstrapContractTests.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/RuntimeArtifactContractTests.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/RuntimeJobEngineContractTests.swift`
  - `openspec/changes/chg-2026-051-agent-hardware-evidence/**`
- Forbidden paths:
  - `openspec/constitution.md`
  - `openspec/specs/**`
  - `openspec/baselines/**`
  - `Catalog/**`
  - `openspec/integrations/**`
  - `openspec/platforms/**`
  - `openspec/changes/**`（本 change 除外）
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/StandingAuthorization.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/Rockchip*/**`
  - `.github/**`
  - `ArkDeckApp/**`
- Risk:high（Core required-field migration + realHardware 证据诚信；零设备 dispatch）
- Hardware required:no（只做 schema/contract/fake trusted-fact projection；fresh 真机
  evidence 由消费方 change 在 archive 后另行 readiness）

### Deliverables

- current hardware-evidence V3 schema 与 stdlib/既有测试栈可运行的正反例 validator；
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

- 需要改变 Catalog operation/effect/typed step 或 provider/profile 语义；
- 需要修改 E2 execution policy、创建/修改 capability/authorization；
- model/firmware/confirmation/step/artifact 任一事实只能由 caller 提供；
- 只能通过放宽 required field、接受 raw serial、复用旧 binding/receipt 或把
  fake/simulation 计为硬件证据才能通过；
- schema 与 Swift projector 无法对同一 canonical record 保持一致。

任一命中即保持 blocked，并新提 scoped remediation；不得静默扩大本任务。

### Notes / handoff

实现完成后在 `evidence/runs/TASK-AHE-001/` 追加 run 记录。change verified/archive
后，`CHG-2026-049` 仍须 fresh readiness 和新 E0 run；不得复用 attempt#2。
