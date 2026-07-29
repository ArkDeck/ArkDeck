---
id: CHG-2026-047-unified-runtime-foundation
revision: 1
status: verified # 2026-07-29 verification closure；仅在维护者 review/merge verification PR 后生效
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

## Verification closure（2026-07-29）

`TASK-URB-001` 的实现、测试与 same-revision evidence 已由 PR #777 合入
protected main。五条 change-local AC 均有可复查的 `contract` /
fake-integration evidence；本 verification PR 只翻转 change/verification
状态并新增 latest-main 复验记录，零产品实现、零 scope、零 acceptance 定义
或 authority 变化。

### Protected-main delivery chain

| Stage | Exact reviewed head | Protected-main merge |
| --- | --- | --- |
| proposal #775 | `de09ffd510080d39e7bd7025c7b03d0dd9226efd` | `610af3071a0f1b246a4214f043d0d71383913c98` |
| implementation/evidence #777 | `5c30a59f88446050cd69cbec62e39476d0588747` | `031ad5a0c7f186c389d5789acfb553e3f37a2ac6` |

两个 exact heads 均由维护者 `lvye` review/approve；Agent PR、SDD Guard 与
Swift CI 所需 checks 均为 `SUCCESS`。AC 真值源是
`evidence/runs/TASK-URB-001/run-r1.md` 与
`evidence/runs/TASK-URB-001/verification-r1.md`，不是实现 PR 被 review
这一事实本身。

### Five binary AC conclusions

- `URB-PROV-001` = PASS：当前 provider protocol 为 typed/closed
  resolveFacts/action/lower/verify/reconcile 五方法面；双 provider 注册、
  无 raw command 请求面、语义 verify 与 fail-closed reconcile 的聚焦测试
  全部通过。
- `URB-HDC-001` = PASS：原拆分出的 HDC production/supervisor 安全面及
  既有 golden 输入未漂移；后续 MU 扩展后的 compatibility profile 在当前
  parser 矩阵中保持登记版本可解析、退化输入显式分类与未知版本
  fail-closed。
- `URB-DAEMON-001` = PASS：当前 daemon 聚焦测试覆盖双客户端、single
  instance、0700/0600、AF_UNIX 零 TCP、协议负向、二进制存活与重启后
  job 历史。
- `URB-JOB-001` = PASS：当前引擎聚焦测试覆盖 durable idempotency、
  WAL crash windows、outcomeUnknown/waitingForRecovery 零重发、
  reconcile、mutation capability、timeline 与安全边界 cancel；另以两个
  同 target 的可运行 `debug.hap@1` fake job 实测 18 次 dispatch 的最大并发
  为 1，兑现原 verification plan 的递延 mutation-lane 计数。
- `URB-COMPAT-001` = PASS：ArkDeckKit 全量 651 tests（1 个既有 opt-in
  manual sleep/wake skip）零失败；SDD 与全部声明脚本套件全绿。

复验记录与精确环境、命令、后续输入漂移审计见
`evidence/runs/TASK-URB-001/verification-r1.md`。复验只使用
contract/fake 路径，未执行安装态 HDC、真实设备、device mutation 或
destructive 操作，不产生 hardware/support/conformance 主张。

只有维护者 review/merge 本 PR 后，proposal `verified` 与 verification
`passed` 才生效；archive 仍是后续独立 PR。若合并前 protected main 再次
改变本 change 的 provider/HDC/daemon/job-engine 或对应测试输入，则必须
先重放受影响验证，不能从本记录推断通过。
