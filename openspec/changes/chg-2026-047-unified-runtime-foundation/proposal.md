---
id: CHG-2026-047-unified-runtime-foundation
revision: 1
status: approved # 合并本 PR 即维护者批准(CHG-2026-046 交付的垂直 PR 模型)
class: capability
core_change_level: none
owner: lvye
core_baseline: CORE-2.1.0
platforms: [macos]
---

# Unified runtime foundation (MU-2)

## Why

CHG-2026-046(已合入 #773/#774)交付了两平面治理、Runtime API v2、
RuntimeCapability 与 Operation Catalog。但设备执行仍是两套互不相通的栈:
HDC 侧(`ArkDeckOpenHarmony`,`HDCProduction.swift` 单文件 2528 行)与
Rockchip 侧(`RockchipFlashExecutionHost`),**无统一 provider 抽象、无
daemon/IPC、无 idempotency 去重、`WriteAheadIntentGate` 只有测试消费方**;
App/CLI 各自直接持有执行栈。清单 MU-2(T05-T08)要求在真实 E0 走通
(MU-3)之前,先建立唯一的设备执行 composition root。

## What changes(T05-T08 垂直交付)

- **T05 Device Provider Contract**:`DeviceProvider` 协议(resolveFacts /
  lower / verify / reconcile),typed action 封闭枚举(HDC 观察族 +
  Rockchip flash),`ProviderFacts`/`TypedProcessPlan`/`ProcessReceipt`/
  `SemanticOutcome`/`ReconcileOutcome`;为现有 HDC 栈与
  `RockchipFlashExecutionHost` 提供 adapter(先兼容,不建第二状态机)。
  调用方无法经 provider API 注入 executable/argv;verify 永不只看 exit code。
- **T06 HDC Production Foundation**:把 `HDCProduction.swift` 按职责拆为
  组件文件(discovery/descriptor/server supervisor/process dispatcher/
  compatibility profile/semantic parser/target facts/action lowering),
  **纯移动零行为变化**(既有全部测试与 golden 不动);新增
  `HDCCompatibilityProfile` + 观察族 semantic parser:E0 输出判定改为
  版本 profile + 语义解析 + 不变量 + golden fixture,不再被非语义空白/
  诊断文本差异卡死;destructive 面继续精确 pin;未知版本/无法判定语义
  返回 unsupported(fail-closed),绝不降级 raw。
- **T07 `arkdeck-agentd` 与本地 Control Plane**:新 SwiftPM 目标
  `ArkDeckAgentDaemon`(库)+ `arkdeck-agentd`(可执行)+
  `ArkDeckAgentClient`(客户端库);Unix domain socket(0700 目录 +
  0600 socket,仅本用户),版本化 JSON 行协议 + 结构化错误;
  single-instance lock(复用 `RuntimeInstanceCoordinator`),重复启动
  返回既有实例信息;API:health/version、target list/get/adopt、
  operation list/describe(直接来自 catalog 生成常量)、job submit/list/
  get/cancel/reconcile/result、artifact metadata、capability list/
  install/revoke(接 `RuntimeCapabilityStore`)。transport 与 handler
  分离。
- **T08 Durable Job Engine 接入**:`RuntimeJobEngine`(复用
  `JobStateMachine`/`FileDurableJournal`/`SessionStore`/
  `DeviceBindingJournalAdapter` 语义,不建第二套):submit 走
  catalog 校验 → capability/默认策略 → durable idempotency ledger
  (同 `idempotencyKey` 返回原 job,不复制副作用)→ session+journal
  jobCreated;**dispatch 前 `WriteAheadIntentGate` 持久化 intent 成为
  生产路径**;每设备 mutation 互斥(复用 `DeviceMutationLaneCoordinator`
  + 重启后 adopt);重启恢复:可安全恢复的继续、结果未知 reconcile、
  不可判定保持 outcomeUnknown(复用 `JournalReplay`);cancel 只在安全
  边界;artifact 经 ID/lease 暴露,不给客户端任意路径。
  `waitingForHuman` 为呈现层状态(machine state + 未决 human action 的
  视图),不改既有 18 态持久图。

## Out of scope

- Bootstrap 状态机、HDC E0 typed action pack 全集、真实设备 walking
  skeleton(MU-3:T09-T11);诊断/HAP/artifact 策略(MU-4);AI loop/
  完整 CLI/App 改造(MU-7);模块目录大迁移(T23)。
- 不修改 `openspec/specs/**`、`workflow-step-registry.yaml`、`Catalog/`
  数据;不动 `scripts/**`(catalog_gen/check_sdd 均不变)。
- 不删除既有 `RockchipFlashExecutionHost` 公有入口与
  `HDCApplicationDiagnosticsFacade`(App/CLI 迁移属 T17/T20/T21)。
- 真机 evidence:本 MU 全部为 contract/fake integration;涉及真实设备的
  验收在 MU-3 起才可主张。

## 与既有 change/task 的映射

- 复用(不重建):chg-2026-025 的 AIN-010(TrustedDeviceOperationHost,
  作为 v1 admission 面保留,v2 内核为其演进)、AIN-006/008(授权/持久化)、
  AIN-007(Rockchip typed executor,经 T05 adapter 接入)。
- chg-2026-022/043 交付的 HDC supervisor 观察面被 T06 组件化**原样搬运**,
  其契约测试保持字节级不动。
- 不翻转任何其他 change 的任务状态。

## Scope

- Canonical Core Requirements claimed:none
- Change-local acceptance:`URB-PROV-001`、`URB-HDC-001`、
  `URB-DAEMON-001`、`URB-JOB-001`、`URB-COMPAT-001`
- Contracts/schemas:daemon 线协议(版本化)以 Swift 契约测试钉定;
  不新增 openspec/contracts 文件
- Core baseline bump:no

## Platform impact

| Platform | Disposition | Reason |
| --- | --- | --- |
| macOS | 新增 daemon/引擎/协议实现 | UDS + POSIX 权限为 macOS 面;协议与 handler 分离为未来端口保留边界 |
| Windows / Linux | deferred / unchanged | transport 可替换(named pipe/socket);不阻塞 macOS MVP |

## Safety, privacy, and compatibility

- 零真实设备执行:HDC/Rockchip adapter 的 dispatch 面在本 MU 只经
  fake/fixture 驱动;真实 dispatch 门(descriptor 校验、authorization、
  binding)全部保留且新增路径复用同一 fail-closed 原语。
- daemon 默认零网络监听;socket 仅本用户可达;协议未知主版本拒绝。
- idempotency/intent/journal 均 durable-first:效果前必有持久 intent,
  outcomeUnknown 永不自动重放(既有 journal 校验器继续强制)。
- 回滚:revert 实现 PR;新增目标/文件为主,`HDCProduction.swift` 拆分为
  纯移动,revert 即还原;无持久数据格式变更(新 ledger 文件独立)。

## Approval and flow

本 proposal PR 合并即批准。TASK-URB-001 以 ready 建立;实现、测试、
evidence 与状态翻转由一个垂直实现 PR 交付;change 级 verify/archive 为
后续独立动作。
