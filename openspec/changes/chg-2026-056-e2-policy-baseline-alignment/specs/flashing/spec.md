# Flashing Specification Delta

> Change: `CHG-2026-056-e2-policy-baseline-alignment@r7`
> Target: `openspec/specs/flashing/spec.md`
> Baseline: `CORE-3.0.0`
> Proposed baseline: `CORE-4.0.0`

## MODIFIED Requirements

### Requirement: REQ-FLASH-007 Interactive destructive acknowledgement

交互式 UI 的 execute 分支 SHALL 在显示 exact plan 后要求用户确认危险影响；erase、format、
unlock、downgrade 或 userdata wipe SHALL 使用更强文案。acknowledgement SHALL 包含设备、
镜像、Provider、分区和数据影响，且用户拒绝时 SHALL 在 Runtime request 前停止。

该 UI acknowledgement 是 UX boundary，不是 E2、standing authorization、campaign
confirmation、RuntimeCapability 或 recovery proof，且 SHALL NOT 产生 authority/capability
bytes。Headless Agent/Runtime 的 initial execute、ordinary continuation 与 eligible
complete-overwrite recovery 均 SHALL NOT 展示或等待 UI acknowledgement。交互式 UI 点击
确认后仍 SHALL 通过同一 Runtime gate，不得放宽 target/plan/Artifact/coverage/recovery。

#### Scenario: AC-FLASH-007-01 User cancels interactive acknowledgement

- GIVEN 交互式 UI 已显示 exact plan、target、partition 与 userdata impact
- WHEN 用户拒绝 destructive acknowledgement
- THEN UI 不提交 Runtime execute request，updater/flash/erase 调用数为 0
- AND 不创建 authority、RuntimeCapability、reservation、recovery proof 或 realHardware evidence

### Requirement: REQ-FLASH-013 Recovery is bounded and honest

失败 SHALL 提供当前阶段、最后确认步骤、设备模式和 Provider RecoveryGuide。ArkDeck SHALL
明确刷机可能丢失数据、无法启动或需要厂商恢复工具，且 SHALL NOT 保证所有失败可自动恢复。

当 Runtime 能从 durable intent 保守界定所有可能 effect，并通过已发布 Provider contract、
fresh same-target facts、完整覆盖 plan 与 semantic verification 机械证明恢复安全时，产品
SHALL 自动执行 distinct complete-overwrite recovery，不显示需要人批准的
`outcomeUnknown` 决策。无法证明时 SHALL 显示缺失的不可 override 安全条件，且新 dispatch
为 0；UI/chat confirmation 不能替代证明。

#### Scenario: AC-FLASH-013-01 未回连

- GIVEN 设备刷写后未在期限内回连
- WHEN recovery classification 运行
- THEN 状态不是 succeeded，原始 intent 不被重放或伪造 outcome
- AND 若 complete-overwrite proof 成立则自动进入 distinct recovery；否则展示精确 blocker
  与 Provider 人工恢复路径，但不请求用户批准自动重发

### Requirement: REQ-FLASH-015 Runtime-owned autonomous destructive Flash and recovery admission

自主 Agent MAY 请求执行含 `destructive` Step 的真实 Flash workflow，且 SHALL NOT 需要
E2、`standingAuthorization`、`evolutionCampaignConfirmation`、Git Task/PR、AUTH-ID、
legacy mode、UI acknowledgement、`outcomeUnknown` 人工决策或每轮聊天确认。
`destructive` effect 保持不变；不得把 Flash Step 降级为其他 effect。

只有 protected-main Runtime MAY 在完整 materialize 已发布 typed plan 后，基于 Catalog
policy 和 Runtime-owned trusted facts 生成、持久化并消费 RuntimeCapability。capability SHALL
精确绑定 operation/version、stable target identity、binding revision、exact typed inputs、
ordered Step set、plan digest、archive/Artifact lease 与 content digest、Provider/tool facts、
有效期和使用预算。Caller、Agent、candidate、repairer、Manifest、evidence、UI 或聊天文本
SHALL NOT 创建、提供、修改或扩大 capability 或 recovery classification。

每个真实 destructive epoch 的首个外部 Step 前，Runtime SHALL 重新 materialize plan，
验证 Artifact leases，取得 fresh target/binding/tool readback，并 durable reserve capability
use/ordinal。任一 operation/profile/target/binding/input/plan/archive/artifact/tool/freshness/
reservation 缺失、未知或漂移 SHALL fail closed。

一个 closed automation invocation 最多十六个串行 destructive epochs、四小时、并发一。
普通 next attempt 需要前一 attempt durable `safeToReflash`。若存在 `outcomeUnknown`、
unresolved intent 或 partial write，原始 intent SHALL 永不重放；Runtime SHALL 自动计算所有
outstanding intents 的 conservative `uncertainEffectSet`。只有已发布 Provider contract 对
exact operation/profile 声明 complete-overwrite supersession，且 fresh stable identity/
binding/topology、immutable Artifact、全量 coverage 与 verification recipe 均成立时，Runtime
才 MAY durable 分类 `safeToSupersedeByCompleteOverwrite` 并启动 distinct recovery epoch。

recovery epoch SHALL 使用新的 capability、reservation、intent/outcomes，并覆盖所有可能受
影响的 partitions、boot metadata、userdata effects、device modes 及 Provider 声明的其他
状态。只有全部 typed writes、semantic verification、reboot/rebind 与 runtime-build
postflight confirmed 后，Runtime 才 MAY 写 `SupersedingRecoveryEpoch` 并释放 target lane。
原 intent 的 unknown outcome 保持不可变，原 Job 不得记为 succeeded。recovery 自身 unknown
时，其 possible effects 加入 union；若完整 proof 仍成立且预算未耗尽，Runtime MAY 自动执行
下一 distinct recovery。

已有 durable 后续 real Flash MAY 在零设备 dispatch 下被识别为 superseding epoch，但必须
证明 same stable physical target、严格后序、完整 effect coverage、逐项 confirmed outcomes
和 postflight；Job `succeeded` 文本或进程 exit 0 单独不足。任一 effect 无法界定/覆盖、
identity/topology 未知、Provider 未声明、trusted fact 漂移、取消、过期或预算耗尽 SHALL
硬停止且 dispatch 为 0。产品 SHALL 报告不可 override 的 missing proof，不得询问用户是否
强行继续。

Candidate/repairer SHALL NOT 访问设备 transport、Runtime 或 capability admin，且不得扩展
executable/argv、operation、partition、plan、archive、Step set、target 或 coverage proof。
只有 protected-main broker 可 dispatch 已发布 typed Steps。

新 evidence SHALL 记录真实 executor、RuntimeCapability、fresh target confirmation、
reservation/use ordinal、plan/archive/Artifact correlation、uncertain-effect/coverage digests、
actual typed Steps、supersession links 与 terminal/recovery disposition。历史 authority 仅可
decode/export；evidence 不得追溯授权任何 Step。

#### Scenario: AC-FLASH-015-01 Untrusted Runtime facts block real Flash

- GIVEN Agent 请求 initial Flash 或 complete-overwrite recovery，但 target/binding、typed
  inputs、plan、archive/Artifact、Provider/tool、freshness、capability 或 recovery proof 任一
  缺失、未知、caller-supplied 或不匹配
- WHEN protected-main Runtime 在首个真实 device Step 前校验 admission
- THEN destructive dispatch 数为 0，Job 持久记录精确 blocker
- AND UI/chat/human confirmation、connected USB、evidence 或 legacy authority 不能使其通过

#### Scenario: AC-FLASH-015-02 Unknown predecessor permits only proven distinct recovery

- GIVEN automated Flash 有 outcomeUnknown/unresolved/partial predecessor
- WHEN Runtime 评估继续路径
- THEN 原始 intent 的 replay 数为 0，ordinary next attempt 数为 0
- AND 仅当 conservative effect union、same-target facts、Provider complete-overwrite coverage、
  immutable Artifact、verification recipe 与 budget 全部成立时，distinct recovery MAY dispatch
- AND 缺一项时系统硬停止并报告 blocker，而不是请求用户批准

#### Scenario: AC-FLASH-015-03 Runtime policy permits bounded Agent Flash without legacy authority

- GIVEN Agent 提交已发布 Flash execute request，Runtime 已完整 materialize plan、从 trusted
  facts 生成 exact RuntimeCapability、验证 Artifact leases、取得 fresh readback 并 durable
  reserve 当前 use
- WHEN broker dispatches execute plan
- THEN 不要求 standing/campaign/Git/UI/chat authority，且只有声明的 typed Steps 运行
- AND evidence 如实记录 Agent executor、capability、exact plan/target/Artifact 和 disposition
