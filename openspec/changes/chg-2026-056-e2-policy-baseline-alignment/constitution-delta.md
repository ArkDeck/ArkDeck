# Constitution Delta

> Change: `CHG-2026-056-e2-policy-baseline-alignment`
> Target: `openspec/constitution.md` (`ARK-CONSTITUTION` 1.0.0 -> 2.0.0 at archive)
> Semantics: complete replacement of `POL-AGENT-002`; all other `POL-*` text is unchanged.

## MODIFIED Policies

### POL-AGENT-002 Autonomous destructive execution requires exact E2 authority

自主 Agent MAY 对真实设备 dispatch 已发布 Catalog 所定义的 `destructive` typed Step，
当且仅当持有以下一种、且与本次 dispatch 精确一致的 E2 authority：

1. 维护者经 merged PR 预先批准的 standing authorization，逐项 pin 目标设备身份与
   binding revision、firmware、transport、HDC、Provider、plan digest、Step 集合、
   recovery path、有效期与使用次数；或
2. 用户监督式交互 Agent 会话中的 bounded evolution campaign confirmation。Agent SHALL
   在同一会话展示 exact plan/archive/step-set、脱敏 target/binding、userdata impact、
   protected-main base、candidate allowed paths/diff budget、build target/toolchain、
   validity 和 attempt limit，并如实取得用户确认。campaign 的硬上限为 16 个串行
   attempts、四小时、并发一。

在每一个真实 destructive Step 前，merged broker SHALL 从已发布 typed plan 重新计算
plan/step set，读取 fresh target/binding facts，并校验 authority、immutable candidate pin、
reservation ordinal、有效期和全部预算。任一缺失、已消费、candidate/authority 漂移、过期、
超限、没有 fresh reservation、身份/拓扑不确定、outcomeUnknown、unresolved intent 或 unsafe
partial write SHALL fail closed：新 destructive dispatch 数为 0，并持久记录 blocked 或 terminal
disposition。独立 adversarial review 不是 admission pin；candidate 修改不得因此强制创建
review session。

campaign 内未合入 candidate 只可在确认的 allowed paths/diff budget 所限定、task-owned
isolation 中完成固定 build 与封闭策略输出校验，并生成 immutable candidate pin。candidate
或其 pin 缺失/漂移 SHALL fail closed；独立 adversarial review 不是 reservation 或 dispatch
的条件，产品不得因 candidate 修改而强制创建此类 review session。repairer 不得取得 source
workspace。candidate 与 repairer 均不得取得 network、USB/HDC/RockUSB、raw shell、Runtime
或 authority capability。它们只能在既有 Catalog 的封闭策略空间内提出 strategy；不得创建
或改变 executable/argv、operation、partition、plan、archive、step set、target、broker 或
authorization。只有 protected-main broker 可在每轮 fresh readback 与 durable reservation
之后 dispatch。只有前一 attempt 已 durable terminal 且 broker 基于完整 outcome/readback
分类为 `safeToReflash`，同一 invocation 才 MAY 自动继续下一轮；success、unknown、
unresolved、unsafe partial、drift、repairer rejection、取消后的 destructive intent、过期或
预算耗尽均 SHALL 永久停止，且不得自动 replay/recovery。

普通 CI、后台 daemon/scheduler、无有效 E2 authority 的 Agent 和 caller-supplied
authorization/context SHALL 只运行 contract/fake/simulated/plan-only 分支。已连接 USB、
Task 风险标记、事后 evidence 或一句未绑定 exact plan 的聊天消息都不构成 authority。
Agent SHALL NOT 伪造未发生的用户确认，也 SHALL NOT 自行创建、修改、批准或吊销
standing authorization。historical one-shot `chatConfirmation` 与 legacy execution mode
仅可 decode/export；新的 reservation、admission 和 dispatch 必须拒绝，且不得升级为
campaign。

真实硬件 evidence SHALL 如实记录 executor（human 或 agent）、实际 authority
kind/reference、fresh target confirmation、时间、actual typed step 与恢复路径。
`evolutionCampaignConfirmation` SHALL NOT 被记作 standing authorization，schema-valid
evidence 也 SHALL NOT mint、扩大或事后追认 authority。人类亲手执行仍是有效路径。

## Unchanged

`POL-AGENT-001` 与其余全部 Safety invariant 保持不变；尤其是 typed-only、identity
before convenience、unknown outcome 不重放、privacy 和 fail-closed 规则继续适用于上述
所有 E2 attempt。
