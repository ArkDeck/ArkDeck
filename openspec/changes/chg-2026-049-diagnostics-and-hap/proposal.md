---
id: CHG-2026-049-diagnostics-and-hap
revision: 1
status: approved # 合并本 PR 即维护者批准(CHG-2026-046 垂直 PR 模型)
class: capability
core_change_level: none
owner: lvye
core_baseline: CORE-2.1.0
platforms: [macos]
---

# Diagnostics capture, HAP debug and the unified artifact model (MU-4)

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

## What changes(T12+T13+T14 垂直交付)

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
- **T12 `capture.diagnostics@1`**:把 T10 的 E0 action 编排为一次
  operation——preflight → bounded HiLog → UI Dump → bounded Trace →
  receive artifacts → 语义校验 → 索引 → 远端清理 → finalize manifest。
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

contract/fake 面随实现 PR 交付并可绿。**真机面分两级**:

- `DHA-HW-001`(E0 采集,capture.diagnostics@1):需设备窗口,沿用
  MU-3 已验证的 E0 授权路径(默认只读策略),**无需新 capability**;
- `DHA-HW-002`(E1 调试,debug.hap@1):**首个真机 E1 mutation**,除
  设备窗口外还需维护者签发一张 **E1 RuntimeCapability**(scope 限定该
  target + `debug.hap@1`、effect ceiling deviceMutation、有期限与次数)。
  capability 文档由本 change 起草模板、由**维护者 merge 的 PR** 签发——
  Agent 不得自行创建、修改或批准(POL-AGENT-002 不变)。

实现 PR 内两条硬件 AC 均标 `hardware-pending`;窗口与 capability 就绪后
以 evidence-only PR 补记。

## Out of scope

- app-owned `.so` 部署(T15/MU-5)、system `.so`(T16)、Rockchip 刷机
  迁移与 DAYU200 端到端(T17/T18/MU-6)、AI loop 与 App 改造(MU-7)、
  模块目录大迁移(T23);
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
- Change-local acceptance:`DHA-ART-001`、`DHA-CAP-001`、`DHA-HAP-001`
  (contract/fake)+ `DHA-HW-001`、`DHA-HW-002`(realHardware,窗口后
  补记)
- Core baseline bump:no

## Platform impact

| Platform | Disposition | Reason |
| --- | --- | --- |
| macOS | 实现与真机验收 | 设备窗口按既有模型 |
| Windows / Linux | deferred / unchanged | provider/transport 边界已留 |

## Safety, privacy, and compatibility

- E1 fail-closed:缺 capability、scope 不匹配、过期/撤销/耗尽一律拒绝
  (MU-1 的 store 语义已验证);install/start 成功判定必须来自 readback,
  不得凭 exit code;结果未知即停止后续 mutation 并 reconcile。
- artifact 隐私:HiLog/dump/trace 默认按 privacy class 标注并做基础
  redaction;原始高敏产物需显式标记与授权访问;**设备原始日志/trace/
  dump 永不入 Git**,只落 daemon 私有状态目录。
- 磁盘安全:总 byte budget 与 quota 双层约束;接近 quota 时拒绝新采集
  而非破坏既有 artifact。
- 回滚:revert 实现 PR;artifact 存储为新增独立目录结构,无既有数据
  迁移。

## Approval and flow

本 proposal PR 合并即批准。TASK-DHA-001 以 ready 建立;实现 PR 交付
代码+测试+文档+evidence(contract 面)+状态翻转(hardware-pending);
真机与 E1 capability 由后续独立载体处理。
