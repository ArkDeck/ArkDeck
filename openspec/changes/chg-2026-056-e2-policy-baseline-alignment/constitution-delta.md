# Constitution Delta

> Change: `CHG-2026-056-e2-policy-baseline-alignment@r5`
> Target: `openspec/constitution.md`
> Semantics: complete replacement of `POL-AGENT-002`; all other `POL-*` text is unchanged.
> This delta is inert while the proposal remains `proposed`.

## MODIFIED Policies

### POL-AGENT-002 Runtime-owned admission for destructive Agent execution

仓库 SHALL NOT 再定义独立 E2 执行等级，也 SHALL NOT 要求
`standingAuthorization`、`evolutionCampaignConfirmation`、Git Task/PR、AUTH-ID、legacy
mode 或每轮聊天确认作为真实 `destructive` dispatch 的 authority。`destructive` SHALL
继续作为不可降低的 `WorkflowEffect`，不得通过改标为 `deviceMutation`、`readOnly` 或
human execution 绕过本条。

自主 Agent MAY 请求执行已发布 Catalog 的真实 `destructive` typed operation。只有
protected-main Runtime MAY 在完整 materialize 该 operation 的 typed plan 后，从已发布
Catalog policy 与 Runtime 自己取得的 trusted facts 确定性生成、持久化和消费
`RuntimeCapability`；caller、Agent、candidate、repairer、Manifest、evidence 与聊天文本
均 SHALL NOT 创建、提供、修改或扩大该 capability。Agent-facing surface SHALL NOT 暴露
capability install/revoke/admin。

destructive RuntimeCapability SHALL pin operation/version、stable target identity、binding
revision、exact typed inputs、plan digest、archive/artifact digest、有效期、并发和使用预算。
每个真实 destructive Step 前，Runtime SHALL 从已发布 operation 重新计算 plan/step set，
验证 Artifact lease，读取 fresh target/binding facts，并 durable reserve 当前 use。任一
operation/profile/target/binding/input/plan/archive/artifact/tool/freshness/reservation 缺失、
未知或漂移 SHALL fail closed：新 destructive dispatch 为 0，并持久记录 blocker。

一个自动化 invocation 的硬上限 SHALL 为 16 个串行 attempts、四小时、并发一。只有前一
attempt 已 durable terminal 且基于完整 outcome/readback 分类为 `safeToReflash`，Runtime
才 MAY 继续下一轮。success、`outcomeUnknown`、unresolved intent、unsafe partial write、
identity/topology drift、repair rejection、取消后的 destructive intent、过期或预算耗尽
均 SHALL 永久停止该 invocation，且不得自动 retry、replay 或 recovery。

candidate 只可在 task-owned isolation 中按已确认的 source scope build/test；repairer 不得
取得 source workspace。candidate 与 repairer 均不得取得 network、USB/HDC/RockUSB、raw
shell、Runtime 或 capability admin surface，且不得改变 executable/argv、operation、
partition、plan、archive、step set、target 或 broker。只有 protected-main Runtime 可拥有
真实 transport 并 dispatch。

UI MAY 展示 userdata impact、确认或警告，但该文本/点击不是 Runtime authority，且 SHALL
NOT 成为 headless Agent 执行的前置条件。真实 hardware evidence SHALL 如实记录 executor、
effect、RuntimeCapability reference、fresh target confirmation、reservation/use ordinal、
actual typed Steps、Artifact hashes、时间与 terminal/recovery disposition；schema-valid
evidence SHALL NOT mint、扩大或追溯提供 capability。

历史 `standingAuthorization`、`evolutionCampaignConfirmation`、one-shot
`chatConfirmation` 与 legacy execution-mode bytes SHALL 仅可 decode/export；新的 writer、
reservation、admission 或 dispatch SHALL 拒绝这些 authority kind，且 SHALL NOT 把它们
迁移为 RuntimeCapability。人类与 Agent 的真实 destructive execution 使用同一 Runtime
safety gate；human presence 不得放宽 typed-only、identity、durability、privacy 或 recovery
规则。

## Unchanged

`POL-AGENT-001` 与其余 Safety invariants 保持不变，尤其是 typed-only、identity before
convenience、unknown outcome 不重放、local-first privacy、truthful evidence 和 fail-closed。
