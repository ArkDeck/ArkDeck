---
id: CHG-2026-051-agent-hardware-evidence
revision: 3
status: approved # r3 proposal PR 合并即批准；合并前 TASK-AHE-001 保持 blocked
class: core
core_change_level: major
owner: lvye
core_baseline: CORE-2.1.0
platforms: [macos, windows, linux]
---

# Close Agent-produced hardware evidence and Runtime receipt projection

## Why

ArkDeck 的 Device Runtime Plane 已允许 Agent 执行 published typed operation：
E0 使用默认只读策略，E1 使用 per-device RuntimeCapability，E2 仍受适用的
standing-authorization / exact-plan capability 安全规则约束。治理文档也要求真实
硬件 evidence 如实记录 `executor`、授权依据、目标确认、设备/固件/toolchain 与
Artifact。

current `openspec/contracts/hardware-evidence.schema.json` 仍是 V2：

- `operator` 只能是人类，Agent identity 明确无效；
- `physicalTargetConfirmation` 只能表达旧人工执行模型；
- `device.firmware` 与目标确认时间是必填，但
  `RuntimeAgentExecutionReceipt` 不提供这些事实；
- receipt 也不提供 serial digest、model、transport/provider、实际 step kinds 与
  Artifact hash，无法无损投影为有效 realHardware evidence。

该冲突已在 `CHG-2026-049` 的 `DHA-HW-001` attempt#2 实际命中：E0 runtime Job
成功，但不能把不满足 current schema 的 receipt 伪装为验收 PASS。

r1 合入后的 production-reachability 审计又发现：唯一生产 composition
`ArkDeckAgentDaemonMain/main.swift` 的 `TargetStoreFactsPort` 只返回旧 target
identity/tool，明确把 model/firmware 留空，也没有 fresh source time、transport 或
binding correlation；当前三个 evidence-eligible operation 也没有一组在 artifact capture
与 E1 step 前完成的 typed model + firmware + exact-target preflight。只在 fake
`ProviderFacts` 中填字段可以让 contract 变绿，却会让下一次真实 E0 run 原样
`evidenceIncomplete`。这命中 r1 `AF-004` 与“需要改变 Catalog/provider 语义即停止”的
stop condition；未完成实现已保存为不计 evidence 的 WIP，不得以 r1 scope 宣告 done。

r2 合入后的 Catalog contract 审计进一步发现：r2 要求给
`runApprovedRemoteRead` 写入 exact `actionRef`，但 current
`Catalog/schema/operation.schema.json` 与 `scripts/catalog_gen/generate.py`
明确只允许 `captureRemoteStdout` 携带 `actionRef`，且 generator 尚未读取
`arkdeck-remote-operations` registry。任何 operation JSON 改动还会改变 catalog
digest，并强制同步 `Catalog/generated/effect-authorization-matrix.md`；该生成物与
受影响的既有 diagnostics/HAP contract fixture 均未列入 r2 Allowed paths。绕过 schema、
保留 step-ID 猜测或提交 generated drift 都不合法，因此 r2 实现 WIP 再次保存，本文
r3 只补齐这组机械必需的 contract/generated/test 路径与 pins。

`CHG-2026-025` 已批准“eligible typed operation 由 Agent 执行”的总体方向，也已完成
一个 change-local V3 draft；但其 proposal 明确禁止其他 change 在该大型 change
archive 前使用该 draft。继续等待 `CHG-2026-025` 的 E1/E2 executor 与真机任务全部
完成，会让已经发布且成功执行的 E0 operation 长期无法产生诚实证据。因此本 change
抽离并接管 **hardware-evidence current contract + Runtime receipt/projection** 这一
封闭垂直单元；`CHG-2026-025` 继续拥有 executor、capability、E2 policy 与
human-boundary 清理，不再在 archive 时覆盖本 contract。

## What changes

In scope:

- **Hardware evidence V3 current contract**：以本 change 的
  `contracts/hardware-evidence.schema.v3-draft.json` 为唯一候选，将 V2 的
  human-only `operator` 改为 `executor { kind: human|agent, id, authority? }`，
  将 `physicalTargetConfirmation` 改为 actor-neutral `targetConfirmation`。
- **按实际 effect 绑定 authority**：
  - Agent E0 必须记录 `defaultReadOnlyPolicy` reference；
  - Agent E1 必须记录 `runtimeCapability` reference；
  - Agent E2 的结构只能记录 `standingAuthorization` reference，且 schema-valid
    evidence **不授予执行权限**；dispatch 是否允许仍完全由当时适用的 approved
    Safety delta 与 execution gate 决定；
  - human evidence 不伪造 Agent authority。
- **Runtime trusted-fact receipt/projection**：
  `RuntimeAgentExecutionReceipt` 与 daemon 的只读查询面补齐 operation/job/catalog、
  actual effect/step kinds、target/binding、model、serial SHA-256、firmware/build、
  transport、provider/toolchain、fresh target-confirmation method/time、authority 与
  Artifact reference/hash。hardware-evidence projector 只消费 product-owned durable
  records、provider observations 与 artifact metadata，不接受 caller 自报这些事实。
  evidence packaging 层只可补充不授予权限的 claim metadata（`evidenceId`、
  `acceptanceIds`、`validUntil`、`notes`），且其 AC 归属仍由 verification plan 与
  维护者 review 判定。
- **Production typed preflight closure（r2）**：
  - `observe.device@1`、`capture.diagnostics@1` 与 `debug.hap@1` 在任何
    evidence-bearing capture / E1 step 前依次执行 descriptor-bound `probeDevice`
    exact-target confirmation、`runApprovedRemoteRead(deviceModel)` 与
    `runApprovedRemoteRead(firmwareBuild)`；
  - 三个 read 均是 reviewed Catalog step，各自有 durable intent/outcome，不通过
    synthetic side-channel、bootstrap adoption time 或 `job.evidence` 事后补跑；
  - HDC target-list parser 必须按 pinned family 解析并选中 target-store 的 exact
    `connectKey`，在 provider 内立即散列 serial 并返回 transport；0 个/多个 match、
    binding/identity drift 或未知列形态一律失败；
  - property read 使用已有 closed `HDCAllowlistedProperty`，lowering 为
    executable + argument array 且显式 `-t <connectKey>`；caller 不能选择 property
    key、connectKey 或命令；
  - Runtime 将三条 outcome 与 target-store identity/binding、tool discovery 合并为
    一份 job-local observation，最后一条 preflight outcome durable 后才允许后续
    capture/E1 step；旧 target row 缺 transport 等字段时由本次 typed preflight
    重建 job observation，不改写历史 evidence。
- **Catalog action-reference closure（r3）**：
  - operation schema 与 stdlib generator 只对
    `runApprovedRemoteRead` 新增 `actionRef` 能力；该引用必须来自
    `arkdeck-remote-operations` registry，且 action 的 `step_kind` 必须精确为
    `runApprovedRemoteRead`；
  - `captureRemoteStdout` 的既有 registry/验证行为保持不变，其他 step kind 仍禁止
    `actionRef`；unknown catalog/action、step-kind mismatch 与缺失 required
    `actionRef` 均 fail closed；
  - Catalog digest 变化同步两个既有 generated outputs；descriptor-bound fake HDC
    fixture 增加 exact `-t <connectKey> shell param get <closed-property>` 的 model/
    firmware 响应，既有 diagnostics/HAP contract fixtures 只做新 required prefix
    的 production-shaped 适配，不放宽其原断言。
- **Fail closed evidence publication**：任一 required fact 缺失、unknown、stale、
  binding 不一致、authority/effect 不匹配或 Artifact bytes/hash 不可验证时，runner
  返回结构化 `evidenceIncomplete` blocker；不得发布 schema-valid realHardware
  record，不得使 AC PASS。
- **文档与 conformance 同步**：current contract 激活时同步 AGENTS、
  enforcement、verification policy、hardware matrix 序言与 core-conformance 中
  human-only/`authorizationRef` 漂移；统一使用 effect-aware authority reference。
- **Ownership transfer**：`CHG-2026-025/TASK-AIN-002` 的历史实现/evidence 保留，
  作为本 draft 的输入；current contract 激活与 receipt closure 由本 change 独占。
  `CHG-2026-025` archive 不得再次替换 hardware-evidence schema。

Observable behavior:

- Before：Agent runtime run 即使成功，receipt 缺少 schema-required facts，也只能
  记录为 blocked/incomplete；V2 只接受 human operator。
- After：Agent 通过 published typed operation 完成真实设备 run 后，只有在 runtime
  能从可信来源闭合全部 V3 facts 时才生成 schema-valid evidence；E0/E1 authority
  按实际 effect 对应，缺失或漂移明确失败。人类执行仍可生成 V3 evidence。

## Out of scope

- 本 r3 proposal PR 不修改 current schema、Catalog/Runtime 代码或 current specs，不执行
  device/HDC/tool，不产生或追认任何 realHardware evidence。
- 不追溯改写 V2 历史记录；`DHA-HW-001` attempt#2 继续保持“runtime succeeded /
  formal acceptance blocked”，不得补写字段后追认为 PASS。
- 不新增 operation、provider、integration/device profile，不改变 Catalog effect
  level、现有非 preflight step 的语义或 RuntimeCapability 的签发/消费语义；r2 列明的
  三条 required preflight prefix 与两个 exact remote-read action 是唯一 Catalog 变化。
- 不修改 E2 execution policy、standing authorization、Constitution
  `POL-AGENT-002` 或 `REQ-FLASH-015`；schema 只能记录授权依据，不能授权 dispatch。
- 不把所有 legacy human harness 机械改名为 Agent。产品 executor 与真机 evidence
  未闭合的任务继续 blocked；物理/系统配置/身份歧义/recovery 判断/D1-D2 review 等
  human allowlist 继续由 `CHG-2026-025/TASK-AIN-017` 管理。
- 不在本 change 执行新的真机验收；本 change archive 后，消费方 change 必须做 fresh
  readiness 并产生新的 run。

## Scope (涉及的 Requirement/AC)

- Requirement:`REQ-WF-004` (ADDED)
- Acceptance:`AC-WF-004-01`、`AC-WF-004-02`、`AC-WF-004-03` (ADDED)
- Contracts/schemas:
  - `openspec/contracts/hardware-evidence.schema.json` 2.0.0 → 3.0.0
  - `RuntimeAgentExecutionReceipt` 与 hardware-evidence projection contract
  - 三个已发布 operation 增加 required E0 evidence-preflight steps（同版本
    breaking modification，经本 Core MAJOR change 批准）
  - `arkdeck-remote-operations` 增加无 caller 参数的 exact `deviceModel` /
    `firmwareBuild` action
  - Operation Catalog schema/generator 对 `runApprovedRemoteRead` 的 exact
    registered action reference 支持，以及既有 generated outputs 同步
- Core baseline bump:需要。以 current `CORE-2.1.0` 为基线时 candidate 为
  `CORE-3.0.0`（MAJOR：替换 schema required fields、收紧 realHardware evidence
  publication）。若 `CHG-2026-050` 或其他 Core change 先 archive，archive PR 必须按
  届时 current baseline 计算下一个 MAJOR 版本，不复用已占用版本号。

## Platform impact

| Platform | Disposition | Reason |
| --- | --- | --- |
| macOS | contract + Runtime implementation；archive 后 needsReverification | 当前 Device Runtime 实现面；不在本 change 产生硬件支持声明 |
| Windows | deferred / contract applies | 端口未启动；共享 V3 schema 与 conformance vectors，不产生支持声明 |
| Linux | deferred / contract applies | 端口未启动；共享 V3 schema 与 conformance vectors，不产生支持声明 |

## Safety, privacy, and compatibility

- **Trusted facts**：model/serial digest/firmware/confirmation 来自同 run、同 binding
  的 typed E0 preflight readback；该 preflight 可作为 operation 的首个 device step，
  但必须在后续 evidence-bearing capture 以及任何 E1/E2 effect 前完成。
  step kinds/effect 来自 durable execution record；authority 来自
  admission decision；Artifact hash 来自已发布 bytes。caller 不能同时构造事实与证明。
- **Exact target**：target-store 只提供内部寻址 `connectKey` 与既有 identity/binding；
  provider 在 typed target-list outcome 中精确匹配后才使用 `-t` 做 property read。
  `connectKey`/raw serial 不进入 daemon evidence wire、projector 或 Git；target-list
  0/multiple match 不猜测默认设备。
- **Fail closed**：missing/unknown/stale/mismatch 一律 `evidenceIncomplete`，不得用
  target ID、exit 0、相似型号、旧 receipt 或人工补写推断。
- **Authorization separation**：evidence 是执行结果记录，不是 capability。事后
  evidence 永远不能补发 E1/E2 权限。
- **Privacy**：仓库只允许 serial SHA-256、脱敏 transcript 与受控 Artifact 引用；raw
  serial、connectKey、设备日志/dump/trace bytes、secret 不入 Git。
- **Compatibility**：V2 历史 bytes 保持不可变；V3 只用于新 evidence。读取端 MAY
  并存读取 V2/V3，但新写入端只能生成 V3，不做有损自动迁移。
- **Durable target migration**：旧 target-store record 缺少 model/firmware/
  confirmation 时保持可读，但 evidence eligibility 为 incomplete；必须经 fresh typed
  preflight 补建新 observation，不得从 adoption time、target ID 或旧 tool version 合成。
- **Rollback**：实现 PR 可整体 revert 回 V2 + blocked behavior；不得以移除 required
  facts 或允许 caller 补写来恢复“成功”。

## Approval and flow

r1 proposal PR 已承载 `CHG-2026-051` 初始 approval 与 `CHG-2026-025` r6 ownership
修订，r2 承载 production preflight scope。本文 r3 是 Catalog contract/generator
stop condition 后的 D1 机械范围/readiness 修订；维护者 review + merge r3 exact head
后，`TASK-AHE-001` 才可按新 pins 恢复。r3 合并不构成 contract 激活、真机窗口、
E1 capability 或 E2 authorization。实现、
测试、文档、run evidence 与任务状态翻转仍同车交付；随后 change 级 verification 与
archive 分别使用独立 PR。
