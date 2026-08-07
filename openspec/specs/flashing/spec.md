# Flashing Specification

> Version：2.0.0
> Status：candidate CORE-4.0.0（current ratified baseline remains CORE-3.0.0）
> Baseline：CORE-4.0.0 candidate
> MVP：one verified HDC/flashd provider  
> Applicability：all platforms

## Purpose

定义刷机 Provider、preflight、执行模式、危险步骤、恢复和硬件支持声明。平台差异不得改变安全门。

## Requirements

### Requirement: REQ-FLASH-001 Typed Provider contract

每个 Flash Provider SHALL 提供 probe、validate、makePlan 和 recover，并生成 typed FlashStep。HDC/flashd、fastboot、Rockchip 或厂商工具 SHALL 是独立 Provider；系统 SHALL NOT 承诺一套命令覆盖所有设备。

#### Scenario: AC-FLASH-001-01 Unsupported protocol

- GIVEN设备不支持当前 Provider
- WHEN probe/validate
- THEN preflight 阻断
- AND不会尝试“相似命令”

### Requirement: REQ-FLASH-002 Explicit prerequisites

Provider SHALL 声明 `root | updater | flashd | unlocked | stablePower | recoveryPath | ...` 的 required/optional/notApplicable 和 satisfied/unsatisfied/unknown。任何 required prerequisite 为 unsatisfied 或 unknown 时 SHALL 在临界步骤前阻断。

#### Scenario: AC-FLASH-002-01 Flashd 未验证

- GIVEN设备已进入 updater 但无法确认 flashd 能力
- WHEN destructive confirmation 前 preflight
- THEN执行分支不可开始

### Requirement: REQ-FLASH-003 Validated image set and exact plan

Profile SHALL 声明允许分区、必需文件、大小范围、hash 和顺序。UI SHALL 展示设备身份、Provider、镜像路径/hash、分区、数据擦除和完整计划。

#### Scenario: AC-FLASH-003-01 镜像 hash 不符

- GIVEN image hash 与 Profile 不匹配
- WHEN validate
- THEN执行和 planned-success 都被阻断

### Requirement: REQ-FLASH-004 Distinct execution modes

`execute | planOnly | simulated` SHALL 在 UI、Job、manifest、History 和导出中持续可辨识。只有 execute MAY 触发真实设备 mutation。

#### Scenario: AC-FLASH-004-01 模式标识持久化

- GIVEN任一模式完成或失败
- WHEN Session 导出
- THEN manifest 保留 executionMode 和相应 Provider/fixture identity

### Requirement: REQ-FLASH-005 Plan-only produces a full non-executed plan

真实 Provider 的 plan-only SHALL 复用真实 probe/validate/makePlan，允许 hostOnly/readOnly probe 和流式 hash。完整计划 SHALL 保留 deviceMutation/destructive steps、顺序和参数摘要并标记 `notExecuted(planned)`，但 SHALL NOT 派发它们。任何错误派发尝试 SHALL fail closed；只有 plan Artifact finalization 成功后状态为 planned。

#### Scenario: AC-FLASH-005-01 完整计划且零 mutation

- GIVEN有效 Profile 含 enterUpdater、erase 和 flashPartition
- WHEN plan-only 成功
- THEN三个步骤均出现在 plan Artifact
- AND mutation/destructive runner 调用数为 0
- AND terminal status 为 planned

#### Scenario: AC-FLASH-005-02 Finalization 失败

- GIVEN完整计划无法持久化
- WHEN finalization 失败
- THEN status 为 failed 而不是 planned

### Requirement: REQ-FLASH-006 Simulation is isolated from real devices

Simulated Provider SHALL 使用合成设备/fixture 和可配置 delay/failure/disconnect/outcomeUnknown，不接受真实 connectKey、不启动外部工具。Release 中如保留 SHALL 只在明确 Demo/Developer Mode 出现，并持续标识模拟。

#### Scenario: AC-FLASH-006-01 Simulation 不进入硬件矩阵

- GIVEN模拟刷机全部成功
- WHEN生成 verification evidence
- THEN evidence 类型为 simulated
- AND hardware support matrix 不新增 verified 记录

### Requirement: REQ-FLASH-007 Interactive destructive acknowledgement

交互式 UI 的 execute 分支 SHALL 在显示 exact plan 后要求用户确认危险影响；erase、format、
unlock、downgrade 或 userdata wipe SHALL 使用更强文案。acknowledgement SHALL 包含设备、
镜像、Provider、分区和数据影响，且用户拒绝时 SHALL 在 Runtime request 前停止。

该 UI acknowledgement 是 UX boundary，不是 E2、standing authorization、campaign
confirmation 或 RuntimeCapability，且 SHALL NOT 产生 authority/capability bytes。
Headless Agent/Runtime execute 不展示或等待 UI acknowledgement；它只受
`REQ-FLASH-015` 的 Runtime-owned safety admission 约束。交互式 UI 点击确认后也 SHALL
通过同一 Runtime gate，不得因 human presence 放宽 target/plan/Artifact/recovery 规则。

#### Scenario: AC-FLASH-007-01 User cancels interactive acknowledgement

- GIVEN 交互式 UI 已显示 exact plan、target、partition 与 userdata impact
- WHEN 用户拒绝 destructive acknowledgement
- THEN UI 不提交 Runtime execute request，updater/flash/erase 调用数为 0
- AND 不创建 authority、RuntimeCapability、reservation 或 realHardware evidence

### Requirement: REQ-FLASH-008 Critical writes are not force-killed

分区写入 SHALL 标为 criticalNonInterruptible 或 Provider 证明的等价安全策略。取消只 SHALL 阻止后续步骤并在安全边界生效。

#### Scenario: AC-FLASH-008-01 写分区时退出请求

- GIVEN App 收到正常退出且 critical write 在运行
- WHEN退出协调开始
- THEN请求被 durable 记录并延迟到安全边界

### Requirement: REQ-FLASH-009 Power activity with honest limits

Execute 分支从进入升级模式前到 postflight 或稳定 recovery/terminal SHALL 持有引用计数的 idle-sleep activity，并在所有 success/failure/cancel/throw 路径释放。UI SHALL 提示勿合盖、主动睡眠、断电或拔线，并 SHALL NOT 承诺阻止这些事件。

#### Scenario: AC-FLASH-009-01 Sleep/wake 仍发生

- GIVEN系统发生无法阻止的 sleep/wake
- WHEN App 恢复
- THEN事件写入 journal
- AND执行 reconnect/reconcile 而非假设步骤继续

### Requirement: REQ-FLASH-010 Rebinding obeys transport identity rules

进入 updater、重启和返回系统模式 SHALL 使用 Core device binding contract。身份未确认时，任何 Flash mutation SHALL 被阻断。

#### Scenario: AC-FLASH-010-01 TCP updater 回连

- GIVEN TCP 设备进入升级流程后断线再出现
- WHEN目标可达
- THEN必须由用户确认 identity diff
- AND不会静默续刷

### Requirement: REQ-FLASH-011 Host/device space and streaming progress

Flash SHALL 对 host Session/归档和设备 staging 的需要执行空间 preflight，并使用 HostStorageCoordinator。Hash 和 transfer SHALL 流式执行；只有 Provider 有可靠 byte total 时 MAY 显示百分比/吞吐/ETA。

#### Scenario: AC-FLASH-011-01 未知传输总量

- GIVEN厂商工具只报告阶段文本
- WHEN镜像传输
- THEN UI 显示 indeterminate 阶段
- AND不按步骤数量伪造百分比

### Requirement: REQ-FLASH-012 Success requires semantic verification and postflight

进程退出 0 SHALL NOT 单独构成刷机成功。Provider SHALL 解析语义输出并完成适用的 postflight、设备/版本校验后才进入 succeeded。

#### Scenario: AC-FLASH-012-01 工具退出 0 但 postflight 不匹配

- GIVEN flash tool 退出 0 但设备未返回或版本不符
- WHEN postflight
- THEN Job 不为 succeeded

### Requirement: REQ-FLASH-013 Recovery is bounded and honest

失败 SHALL 提供当前阶段、最后确认步骤、设备模式和 Provider RecoveryGuide。ArkDeck SHALL 明确刷机可能丢失数据、无法启动或需要厂商恢复工具，且 SHALL NOT 保证所有失败可自动恢复。

#### Scenario: AC-FLASH-013-01 未回连

- GIVEN设备刷写后未在期限内回连
- WHEN recovery UI 显示
- THEN状态不是 succeeded
- AND展示经过 Provider 定义的人工恢复路径与 unknown 状态

### Requirement: REQ-FLASH-014 Hardware support requires real evidence

MVP SHALL 至少在一个明确设备型号、固件、HDC 版本和 Provider 组合上完成真实验收。新增设备或厂商协议 SHALL 独立记录工具、Profile、parser、恢复路径和硬件证据。

#### Scenario: AC-FLASH-014-01 支持矩阵条目

- GIVEN目标设备完成全部 required hardware AC
- WHEN审核 evidence
- THEN support matrix 记录精确组合与证据日期
- AND simulation/fake 不可替代

### Requirement: REQ-FLASH-015 Runtime-owned destructive Flash admission

自主 Agent MAY 请求执行含 `destructive` Step 的真实 Flash workflow，且 SHALL NOT 需要
E2、`standingAuthorization`、`evolutionCampaignConfirmation`、Git Task/PR、AUTH-ID、
legacy mode 或每轮聊天确认。`destructive` effect 保持不变；任何实现不得把 Flash Step
降级为 `deviceMutation` 或 `readOnly` 以通过准入。

只有 protected-main Runtime MAY 在完整 materialize 已发布 `flash.dayu200@1` typed plan
后，基于已发布 Catalog policy 和 Runtime-owned trusted facts 生成、持久化并消费
`RuntimeCapability`。capability SHALL 精确绑定 operation/version、stable target identity、
binding revision、exact typed inputs、ordered Step set、plan digest、archive/Artifact lease 与
content digest、provider/tool facts、有效期和使用预算。Caller、Agent、candidate、repairer、
Manifest、evidence 或 UI confirmation SHALL NOT 创建、提供、修改或扩大 capability。

每个真实 destructive attempt 的首个外部 Step 前，Runtime SHALL 重新 materialize plan，
验证 Artifact leases，取得 fresh target/binding/tool readback，并 durable reserve capability
use/ordinal。任一 operation/profile/target/binding/input/plan/archive/artifact/tool/freshness/
reservation 缺失、未知或漂移，或存在 non-terminal predecessor、`outcomeUnknown`、unresolved
intent 或 unsafe partial write，SHALL fail closed：destructive dispatch 为 0，Job 持久记录
具体 blocker/terminal disposition。

一个 closed automation invocation 最多 16 个串行 attempts、四小时、并发一。只有前一
attempt durable terminal 且完整 outcome/readback 分类为 `safeToReflash`，Runtime 才 MAY
reserve 下一轮。success、unknown、unresolved、unsafe partial、identity/topology drift、
repair rejection、取消后的 destructive intent、过期或预算耗尽 SHALL 永久关闭 invocation；
不得自动 retry、replay 或 recovery。

Candidate 与 repairer SHALL NOT 访问设备 transport、Runtime 或 capability admin，且不得
扩展 executable/argv、operation、partition、plan、archive、Step set 或 target。只有
protected-main broker 可 dispatch 已发布 typed Steps。UI MAY 展示 userdata impact 或确认，
但该点击不是 Runtime authority，也不是 headless Agent execution 的前置条件。

新 evidence SHALL 记录真实 executor、`runtimeCapability` reference、fresh target
confirmation、reservation/use ordinal、plan/archive/Artifact correlation、actual typed Steps
与 terminal/recovery disposition。历史 `standingAuthorization`、
`evolutionCampaignConfirmation` 和 one-shot `chatConfirmation` 仅可 decode/export，不能
reserve、admit、dispatch 或迁移为 RuntimeCapability；evidence 不得追溯授权任何 Step。

#### Scenario: AC-FLASH-015-01 Untrusted Runtime facts block real Flash

- GIVEN Agent 提交已发布真实 Flash execute request，但 target/binding、typed inputs、plan、
  archive/Artifact、provider/tool、freshness 或 Runtime-generated capability 任一缺失、未知、
  caller supplied 或不匹配
- WHEN protected-main Runtime 在首个真实 device Step 前校验 admission
- THEN destructive dispatch 数为 0，Job 为 `policyBlocked` 或对应 durable blocker
- AND UI confirmation、聊天文本、connected USB、evidence 或 legacy authority 不能使其通过

#### Scenario: AC-FLASH-015-02 Unsafe predecessor blocks the next attempt

- GIVEN 一个 automated Flash invocation 已有先前 attempt，但其 intent/outcome/readback
  非 durable terminal `safeToReflash`，或存在 unknown、unresolved、unsafe partial、identity
  drift、cancellation-after-intent、expiry 或 exhausted budget
- WHEN Runtime 尝试 reserve 或 dispatch 下一 attempt
- THEN 新 destructive dispatch 数为 0，invocation 持久记录永久 terminal stop
- AND 后续 run、UI 点击、hardware evidence 或重启不能自动 retry/replay/recover

#### Scenario: AC-FLASH-015-03 Runtime policy permits bounded Agent Flash without legacy authority

- GIVEN Agent 提交已发布 Flash execute request，protected-main Runtime 已完整 materialize
  plan，从 trusted facts 生成 exact RuntimeCapability，验证 Artifact leases，取得 fresh
  target/binding/tool readback，并在 16-attempt/four-hour/single-concurrency 预算内 durable
  reserve 当前 use
- WHEN broker dispatches execute plan
- THEN 不要求 standing authorization、campaign confirmation、Git carrier 或 per-attempt user
  message，且只有声明的 typed destructive Steps 运行并写入 durable intent/outcome
- AND realHardware evidence 记录 `executor.kind=agent`、`runtimeCapability` reference、exact
  plan/target/Artifact correlation、use ordinal 和 terminal/recovery disposition

### Requirement: REQ-FLASH-016 Board profiles are board-scoped; build facts are derived

A published DAYU200 device profile SHALL select a board: its partition map, write-forbidden
partitions, prerequisites, and archive-member classification rules. Every published reference
for that board SHALL describe the same board facts.

No admission decision SHALL depend on a firmware build being enumerated in the product.
Per-build facts SHALL be derived under Runtime control during Artifact import and recorded on the
lease: archive and member byte counts/SHA-256 digests, the partition table parsed from the
archive's `parameter.txt`, and the runtime build version read from the system image that will be
written. The build version SHALL NOT be inferred from the archive filename or build log.

Import SHALL fail closed when a mapped partition lacks a member, the partition table is invalid
or declares an unknown partition, or the system image yields no runtime build version. Before an
upload begins, declared size and digest are validated only for positive bounded size and canonical
lowercase SHA-256 shape; membership in a compiled set of known builds SHALL NOT be required.

#### Scenario: AC-FLASH-016-01 An unseen firmware build is importable

- GIVEN a conforming DAYU200 archive for a build no published profile enumerates
- WHEN Runtime imports it against the DAYU200 board profile
- THEN member digests, partition table and runtime build version are derived and recorded on the lease
- AND no product code change or build allowlist entry is required

#### Scenario: AC-FLASH-016-02 A non-conforming archive creates no admission artifact

- GIVEN an archive whose partition table omits a mapped partition
- WHEN Runtime imports it
- THEN import fails closed with the missing partition identified
- AND no lease, plan, RuntimeCapability or reservation is created

### Requirement: REQ-FLASH-017 Byte integrity is carried by the lease

The guarantee that a destructive Step writes exactly the admitted bytes SHALL rest on the
Artifact lease and the exact plan/archive binding in the Runtime-owned capability, not on a
compiled build digest. Immediately before the first destructive Step, Runtime SHALL re-verify
that the leased archive byte count and SHA-256 match the materialized plan and SHALL refuse drift.

#### Scenario: AC-FLASH-017-01 Drifted bytes are refused at the last safe boundary

- GIVEN a materialized exact plan over an imported archive
- WHEN the leased bytes no longer match the materialized size or SHA-256
- THEN destructive dispatch is 0
- AND the Job durably records Artifact drift

### Requirement: REQ-FLASH-018 Post-flash verification compares against the flashed image

Post-flash verification SHALL compare the device-reported build version with the runtime build
version derived from the system image the plan wrote, not a device-profile constant. That fact
SHALL reach verification in Runtime-resolved context alongside its Artifact lease. Step
materialization SHALL remain pure over typed inputs and resolved context and SHALL NOT open the
archive.

#### Scenario: AC-FLASH-018-01 Verification uses the derived version

- GIVEN a completed write plan whose system image declares `OpenHarmony-7.0.0.36`
- WHEN post-flash verification reads the device build version
- THEN it passes only if the device answers that exact derived value

#### Scenario: AC-FLASH-018-02 Step materialization performs no archive I/O

- GIVEN typed inputs and resolved context for a Flash Job
- WHEN each published step of `flash.dayu200@1` is materialized
- THEN every step materializes without opening the image archive
