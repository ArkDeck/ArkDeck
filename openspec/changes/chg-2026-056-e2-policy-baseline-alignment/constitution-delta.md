# Constitution Delta

> Change: `CHG-2026-056-e2-policy-baseline-alignment@r7`
> Target: `openspec/constitution.md`
> Semantics: complete replacement of `POL-RECOVERY-001` and `POL-AGENT-002`; all other `POL-*`
> text is unchanged. This delta is inert while the proposal remains `proposed`.

## MODIFIED Policies

### POL-RECOVERY-001 Unknown outcomes are never replayed blindly

只有 `stepIntent` 而没有 confirmed `stepOutcome` 的 destructive step SHALL 标记为
`outcomeUnknown`。系统 SHALL NOT 重放该 intent、猜测其结果或把后续恢复结果追溯写成该
intent 的 outcome。

protected-main Runtime MAY 在不询问用户的情况下执行一个独立、typed 的 complete-overwrite
recovery，但仅当它从 durable operation/profile/plan facts 保守计算出所有 outstanding
intent 的完整 `uncertainEffectSet`，已发布 Provider contract 声明 exact operation/profile
支持 complete-overwrite supersession，且 fresh stable identity/binding/topology、immutable
Artifact、全覆盖映射、逐项 semantic verification 和 budget 全部可机械证明。Runtime SHALL
为该恢复生成独立 capability、reservation、intent/outcomes；只有全部写入及
reboot/rebind/postflight 成功后才可 durable 写 `SupersedingRecoveryEpoch` 并释放 target lane。
原 intent 的 `outcomeUnknown` 保持不可变。

任一 possible effect 无法界定或覆盖、stable physical identity 未知、trusted fact 漂移、
Provider 未发布安全声明、取消待处理或预算耗尽时，新的 destructive dispatch SHALL 为 0。
UI 点击、聊天确认、caller/evidence 声明不得替代缺失证明。系统 SHALL 报告不可由确认绕过
的安全 blocker，而不是请求用户批准重放。放弃恢复仍须先持久化审计，再释放 lane 和
storage claim。

### POL-AGENT-002 Runtime-owned admission and recovery for destructive Agent execution

仓库 SHALL NOT 再定义独立 E2 执行等级，也 SHALL NOT 要求
`standingAuthorization`、`evolutionCampaignConfirmation`、Git Task/PR、AUTH-ID、legacy
mode、UI acknowledgement 或每轮聊天确认作为真实 `destructive` dispatch 的 authority。
`destructive` SHALL 继续作为不可降低的 `WorkflowEffect`，不得通过改标为
`deviceMutation`、`readOnly` 或 human execution 绕过本条。

自主 Agent MAY 请求执行已发布 Catalog 的真实 `destructive` typed operation。只有
protected-main Runtime MAY 在完整 materialize 该 operation 的 typed plan 后，从已发布
Catalog policy 与 Runtime 自己取得的 trusted facts 确定性生成、持久化和消费
`RuntimeCapability`；caller、Agent、candidate、repairer、Manifest、evidence 与聊天文本
均 SHALL NOT 创建、提供、修改或扩大该 capability。Agent-facing surface SHALL NOT 暴露
capability install/revoke/admin。

destructive RuntimeCapability SHALL pin operation/version、stable target identity、binding
revision、exact typed inputs、plan digest、archive/artifact digest、有效期、并发和使用预算。
每个真实 destructive epoch 前，Runtime SHALL 从已发布 operation 重新计算 plan/step set，
验证 Artifact lease，读取 fresh target/binding/tool facts，并 durable reserve 当前 use。任一
operation/profile/target/binding/input/plan/archive/artifact/tool/freshness/reservation 缺失、
未知或漂移 SHALL fail closed：新 destructive dispatch 为 0，并持久记录 blocker。

一个自动化 invocation 的硬上限 SHALL 为 16 个串行 destructive epochs、四小时、并发一。
普通下一 attempt 只有在前一 attempt durable terminal 且分类为 `safeToReflash` 时才 MAY
继续。存在 `outcomeUnknown`、unresolved intent 或 partial write 时，原始 intent SHALL 永不
重放；只有 `POL-RECOVERY-001` 的完整机械证明成立并 durable 分类为
`safeToSupersedeByCompleteOverwrite` 时，Runtime 才 MAY 自动启动一个独立 recovery epoch。
该 recovery 若再次 unknown，后续 epoch 必须重新覆盖所有旧与新增 uncertain effects，并
继续计入同一预算。

只有成功的 `SupersedingRecoveryEpoch` 才可使已覆盖的 uncertain intents 不再阻断 target
lane；它 SHALL NOT 修改原始 outcome 或声称原 Job succeeded。已有 durable 后续 Flash
history 仅在相同 identity、时序、完整覆盖、逐项 outcome 与 postflight 均可验证时 MAY
补记该 relation。缺失证明、identity/topology drift、不可覆盖 effect、repair rejection、
取消、过期或预算耗尽 SHALL 硬停止且零新 dispatch；用户确认不得 override。

candidate 只可在 task-owned isolation 中按已确认的 source scope build/test；repairer 不得
取得 source workspace。candidate 与 repairer 均不得取得 network、USB/HDC/RockUSB、raw
shell、Runtime 或 capability admin surface，且不得改变 executable/argv、operation、
partition、plan、archive、step set、target、coverage proof 或 broker。只有 protected-main
Runtime 可拥有真实 transport 并 dispatch。

UI MAY 展示 userdata impact、确认或警告，但该文本/点击不是 Runtime authority，且 SHALL
NOT 成为 headless Agent 执行、ordinary continuation 或 eligible complete-overwrite recovery
的前置条件。真实 hardware evidence SHALL 如实记录 executor、effect、RuntimeCapability、
fresh target confirmation、reservation/use ordinal、actual typed Steps、Artifact hashes、
uncertain-effect/coverage digests、supersession links、时间与 terminal/recovery disposition；
schema-valid evidence SHALL NOT mint、扩大或追溯提供 capability。

历史 `standingAuthorization`、`evolutionCampaignConfirmation`、one-shot
`chatConfirmation` 与 legacy execution-mode bytes SHALL 仅可 decode/export；新的 writer、
reservation、admission 或 dispatch SHALL 拒绝这些 authority kind，且 SHALL NOT 把它们
迁移为 RuntimeCapability。人类与 Agent 的真实 destructive execution 使用同一 Runtime
safety gate；human presence 不得放宽 typed-only、identity、durability、privacy、coverage
或 recovery 规则。

## Unchanged

`POL-AGENT-001` 与其余 Safety invariants 保持不变，尤其是 typed-only、identity before
convenience、local-first privacy、truthful evidence 和 fail-closed。r7 修改的是 unknown 后
允许的独立完整覆盖恢复，不是允许盲重放 unknown intent。
