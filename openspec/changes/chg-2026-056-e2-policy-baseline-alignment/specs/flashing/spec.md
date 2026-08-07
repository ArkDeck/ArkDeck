# Flashing Specification Delta

> Change: `CHG-2026-056-e2-policy-baseline-alignment@r5`
> Target: `openspec/specs/flashing/spec.md`
> Baseline: `CORE-3.0.0`
> Proposed baseline: `CORE-4.0.0`

## MODIFIED Requirements

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

#### Scenario: AC-FLASH-015-03 Runtime policy permits bounded Agent Flash without E2

- GIVEN Agent 提交已发布 Flash execute request，protected-main Runtime 已完整 materialize
  plan，从 trusted facts 生成 exact RuntimeCapability，验证 Artifact leases，取得 fresh
  target/binding/tool readback，并在 16-attempt/four-hour/single-concurrency 预算内 durable
  reserve 当前 use
- WHEN broker dispatches execute plan
- THEN 不要求 standing authorization、campaign confirmation、Git carrier 或 per-attempt user
  message，且只有声明的 typed destructive Steps 运行并写入 durable intent/outcome
- AND realHardware evidence 记录 `executor.kind=agent`、`runtimeCapability` reference、exact
  plan/target/Artifact correlation、use ordinal 和 terminal/recovery disposition
