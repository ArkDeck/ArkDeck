---
id: CHG-2026-049-diagnostics-and-hap
revision: 2
status: approved # r2 合并即批准 blocker 关闭后的 fresh readiness；合并前任务仍 blocked
class: capability
core_change_level: none
owner: lvye
core_baseline: CORE-2.1.0
platforms: [macos]
---

# Agent-operated diagnostics, HAP debug and the unified artifact model (MU-4)

> 产品闭环兼容说明（2026-07-30）：已发布、Catalog
> `defaultPolicyIssuance=enabled` 的 E1 operation 由 Runtime 在完整
> materialization 后自动签发并持久化 capability；不再要求人工文件、安装或
> review。下文 r2 的人工 E1 capability 描述保留为历史批准记录；E2 不变。

> r2 fresh-readiness revision（2026-07-29）：功能 scope、Acceptance、
> allowed/forbidden paths、E0/E1/E2 边界与硬件分层零变化。
> `CHG-2026-050/TASK-WSC-001` 已由维护者以 PR #789 合入
> `d13dfec6d395dd73662494f16ead9674711fe6ff`，为所有 published
> `captureRemoteStdout` step 增加 closed generated `actionRef`，并使
> diagnostics HiLog/component-tree pair 在 Catalog、generator、JSON Schema
> 与 Swift validator 间闭合。r2 记录 fresh pins、草稿迁移约束和依赖复验；
> 合入 r2 前 `TASK-DHA-001` 仍不得恢复实现。

## Why

MU-1~MU-3(CHG-2026-046/047/048,均已合入;T11 门槛已由 2026-07-29 设备
窗口 attempt#2 关闭)交付了契约、daemon、job engine、bootstrap 与真实
E0 dispatch。现在 `observe.device@1` 能在真机上端到端跑通,但:

1. **产物没有归宿**:引擎只把结果写进 job timeline 与 journal,
   `observe.device@1` 声明的 `device-facts.json` 等 artifact 从未落盘,
   daemon 也没有 artifact 读取面(MU-3 已如实把该面递延本 MU);
2. **E0 采集能力未组合**:T10 交付了 HiLog/UI Dump/Trace 的 typed
   action,但没有把它们编排成一次可提交的 `capture.diagnostics@1`;
3. **E1 面完全空白**:HDC 的 mutation action(send/install/start/stop/
   uninstall/port-forward)尚未实现,`debug.hap@1` 无法执行——这是清单
   MU-4 的核心交付,也是首个需要 runtime capability 的真机面。
4. **Runtime 仍没有 Agent 执行交接**:MU-3 已证明 CLI→daemon→真设备
   的技术链路,但 `BER-HW-*` 的全部 host 命令仍由维护者亲手运行并贴回
   transcript。若继续沿用该窗口模型,新增 operation 仍会把人当作
   Runtime 调用器,与两平面治理中“AI 提交已发布 operation”的目标相悖。

## What changes(T00+T14+T12+T13 垂直交付)

- **T00 Device Runtime Agent 执行交接**:在既有 `ArkDeckAgentClient`/
  `arkdeck` JSON 面上增加一个 one-shot agent runner,封闭执行
  doctor → target list/adopt → submit/wait → artifact query。所有 host
  Runtime 调用由 Agent 执行;调用面只接受 catalog operation、target、
  typed inputs 与 capability reference,不接受 HDC executable/argv/shell,
  也不暴露 capability 创建/修改/批准。等待人类只允许三类结构化
  `humanAction`:设备屏幕首次信任、多候选目标选择、验收所需物理拔插;
  人类不代替 Agent 运行 host CLI。每次执行自动生成脱敏
  `RuntimeAgentExecutionReceipt`(executor、operation、job、target/binding、
  authority reference、humanAction 时间线与终态),不再以人工粘贴
  transcript 作为唯一运行载体。
- **T14 统一 Artifact 模型**(先落地,另两面依赖它):artifact 元数据
  (ID、session/job/step、media type、size、SHA-256、created time、
  provider、target binding snapshot、source operation/version、privacy
  class、retention deadline)、防冲突存储与发布(复用 ArkDeckStorage 既有
  原子发布/path-traversal 防护语义)、artifact ID/lease 访问面(客户端
  永不指定路径)、quota/retention/pin/GC/cleanup debt、默认 redaction
  (token/credential/host path)、manifest 记录 catalog digest 与缺失
  artifact。daemon 增 `artifact.list`/`artifact.inspect`/`artifact.read`
  (有界读)与 `artifact.export`(仅按 ID 导出到调用方指定本地目录)。
  **`observe.device@1` 的四个 artifact 随本面真正落盘**,补齐 MU-3 的
  递延项。
- **T12 `capture.diagnostics@1`**:把 T10 的诊断 action 编排为一次
  operation——preflight → bounded HiLog → UI Dump → bounded Trace →
  receive artifacts → 语义校验 → 索引 → 远端清理 → finalize manifest。
  引擎必须在授权前根据实际选中的步骤计算 effective effect:不选择远端
  trace 时为 E0/readOnly;选择 remote-file trace/cleanup 时为
  E1/deviceMutation,必须持匹配 capability,不得按 operation 的 minimum
  effect 放行。
  **部分成功必须逐 artifact 如实标注**(缺 trace 不得记为整体成功);
  cancel 时停止仍在运行的采集并在安全边界收取已完成产物;超总 byte
  budget 有序截断或失败,不耗尽磁盘;远端清理失败记 cleanup debt 供
  后续 reconcile。
- **T13 HDC E1 Action Pack + `debug.hap@1`**:新增 mutation typed
  action(send artifact to provider-owned staging、install HAP、package
  readback、start/stop ability、verify process state、uninstall、
  create/remove port forward);`debug.hap@1` 编排为 validate → install
  → **package readback**(install 成功不得只看 exit code)→ start →
  **process/ability readback**(start 成功须有可验证信号)→ capture
  diagnostics → stop → 按 cleanup policy 补偿 → finalize。E1 capability
  一次授权整个 recipe,不逐 step 弹审批;结果未知即停止后续 mutation
  并进入 reconcile。

## 硬件与授权门槛(如实分层)

contract/fake 面随实现 PR 交付并可绿。**真机面分两级,两级的 host
Runtime 命令都由 Device Runtime Agent 执行**:

- `DHA-HW-001`(E0 采集,capture.diagnostics@1):Agent 选择不创建远端
  trace 文件的只读 plan,沿用 MU-3 已验证的默认只读策略,**无需新
  capability**;
- `DHA-HW-002`(E1 调试,debug.hap@1):**首个真机 E1 mutation**,除
  硬件可用外还需维护者签发一张 **E1 RuntimeCapability**(scope 限定该
  target + `debug.hap@1`、effect ceiling deviceMutation、有期限与次数)。
  capability 文档由本 change 起草模板、由**维护者 merge 的 PR** 签发——
  Agent 不得自行创建、修改或批准;capability 生效后由 Agent 引用并执行
  整个 recipe(POL-AGENT-002 不变)。

实现 PR 内两条硬件 AC 均标 `hardware-pending`;窗口与 capability 就绪后
由 Agent 执行并以 evidence-only PR 补记。人类仅作为
`physicalAssistant` 完成设备信任、歧义选择或物理拔插;若环境没有可用的
Device Runtime Agent,AC 保持 blocked,不得退回“维护者代跑 CLI”来冒充
Agent 自动化验收。

## Out of scope

- app-owned `.so` 部署(T15/MU-5)、system `.so`(T16)、Rockchip 刷机
  迁移与 DAYU200 端到端(T17/T18/MU-6)、多轮 AI debug 决策 loop 与
  App 改造(MU-7)、
  模块目录大迁移(T23);
- T00 只交付单次 published operation 的 Agent 执行/暂停/恢复与 receipt,
  不做模型推理、自动改代码或无限循环;
- 不修改 `Catalog/` 中既有 operation 的 effect/授权语义(`debug.hap@1`
  与 `capture.diagnostics@1` 的 catalog 条目在 MU-1 已定稿,本 change
  只实现它们);
- 不修改 `openspec/specs/**`、`workflow-step-registry.yaml`;
- E2 面零改动。

## 与既有 change/task 的映射

- 吸收 chg-2026-025 blocked 任务的对应面:AIN-012(ArkUI UI Dump +
  Trace E1 executor)→ T12/T13;AIN-013(HiLog、HAP、app-lifecycle
  executor)→ T13。两任务状态本 change 不翻转,supersede 登记留待 T25。
- chg-2026-008 的 UD-* blocked 任务(受控 UI Dump 采集)→ T12 的
  UI Dump 面;其 harness 与脱敏器经验被复用,不重建。
- 复用:MU-1~MU-3 全部地基 + ArkDeckStorage 既有 artifact/session/
  manifest 原语(SessionArtifactStore、AtomicSessionManifestPublisher、
  SessionRetentionCatalog)——**不建第二套 artifact 存储**。

## Scope

- Canonical Core Requirements claimed:none
- Change-local acceptance:`DHA-AGENT-001`、`DHA-ART-001`、
  `DHA-CAP-001`、`DHA-HAP-001`(contract/fake)+ `DHA-HW-001`、
  `DHA-HW-002`(realHardware,Agent 执行后补记)
- Core baseline bump:no

## Platform impact

| Platform | Disposition | Reason |
| --- | --- | --- |
| macOS | 实现与真机验收 | Agent 执行 host Runtime;人类仅提供必要物理协助 |
| Windows / Linux | deferred / unchanged | provider/transport 边界已留 |

## Safety, privacy, and compatibility

- E1 fail-closed:缺 capability、scope 不匹配、过期/撤销/耗尽一律拒绝
  (MU-1 的 store 语义已验证);install/start 成功判定必须来自 readback,
  不得凭 exit code;结果未知即停止后续 mutation 并 reconcile。
- Agent runner 不是新命令壳:只能调用 daemon 已发布的 typed operation;
  E0 authority reference 固定为 catalog digest + default read-only policy,
  E1 只引用预先接受的 capability ID;runner 无 capability 管理入口。
- effective effect 取实际执行 plan 的最大 step effect,不得只看 catalog
  minimum;remote trace/cleanup 永远不能借 E0 默认策略 dispatch。
- artifact 隐私:HiLog/dump/trace 默认按 privacy class 标注并做基础
  redaction;原始高敏产物需显式标记与授权访问;**设备原始日志/trace/
  dump 永不入 Git**,只落 daemon 私有状态目录。
- 磁盘安全:总 byte budget 与 quota 双层约束;接近 quota 时拒绝新采集
  而非破坏既有 artifact。
- 回滚:revert 实现 PR;artifact 存储为新增独立目录结构,无既有数据
  迁移。

## Approval and flow

r1 proposal PR 合并构成初始批准；随后命中的 typed stdout blocker 已按
stop condition 中止实现。r2 proposal revision 合并构成对 fresh pins、依赖闭合
和恢复边界的 D1 readiness 批准，并使 `TASK-DHA-001` 恢复为 ready。实现 PR
仍交付代码+测试+文档+evidence(contract 面)+状态翻转
(hardware-pending)；真机窗口与 E1 capability 仍由后续独立 D2 载体处理。
