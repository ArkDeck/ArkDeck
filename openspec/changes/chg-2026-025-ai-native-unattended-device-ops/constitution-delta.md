# Constitution Delta

> Change:CHG-2026-025-ai-native-unattended-device-ops
> Target:`openspec/constitution.md`(ARK-CONSTITUTION 1.0.0 → 2.0.0,archive PR 合入)
> 说明:constitution 不在 `openspec/specs/**` 之下,本文件以完整替换文本形式承载
> 其 delta;格式约定与 spec delta 的 MODIFIED 语义一致(完整新文本、ID 不变)。

## MODIFIED Policies

### POL-AGENT-002 Autonomous device execution is authorized by merged plans, not human presence

(完整替换文本如下)

自主 Agent MAY 对真实设备执行含 `destructive` 在内的 typed Step,当且仅当同时
满足:

1. 操作属于 approved change 中状态为 ready 的任务范围;
2. `destructive` Step 具备以下一种 E2 authority:
   - 维护者经 merged PR 预先批准、与待执行计划逐项精确一致的 standing
     authorization(目标设备身份/binding revision、固件、transport、HDC、Provider、
     Step 集合、恢复路径、有效期与次数上限);或
   - 用户监督式交互 Agent 会话中的 bounded evolution campaign confirmation：Agent 除
     exact plan/target/data-impact 外，还展示并由用户确认 protected-main base、候选允许路径
     与 diff 预算、固定 build target/toolchain、有效期与 attempt 上限；产品硬限制最多 8 个
     串行 attempt、最长 4 小时、并发数 1。未合入 candidate 的 tree/diff/executable digest
     SHALL 在每个 attempt 由 protected-main broker 现场派生，并在独立只读 adversarial
     review PASS 后成为 admission pin;
3. 执行门在首个真实设备 Step 前完成逐项校验与目标设备身份读回,任一缺失或不一致
   SHALL fail closed(零 dispatch,记录 blocked-attempt);
4. evidence 如实记录 executor 身份(human 或 agent)、实际 authority kind/reference、目标
   确认、执行时间与恢复路径；chat confirmation 不得记成 standing authorization。

只读采集与 host 侧分析在 ready 任务范围内 MAY 无人值守执行;可逆 deviceMutation
另需 per-device typed capability evidence。普通 CI 不持 standing authorization,
SHALL 仍只运行 schema/contract tests、fake/simulation 与 plan-only。

bounded evolution campaign confirmation SHALL NOT 变成 standing authorization。r7 one-shot
chat confirmation 的历史 Journal/Manifest/ledger bytes SHALL 保持可读和可导出，但新 usage
reservation、admission 与 destructive dispatch SHALL 拒绝，且不得升级成 campaign。campaign 中
未合入 candidate MAY 在隔离、无 network/USB/HDC/RockUSB/raw-shell/authority capability 的
固定 target 中运行，并产生现有 Catalog 可表达的 typed strategy；真实设备 transport、fresh
target/binding readback、ordinal reservation 与 destructive dispatch SHALL 只由 protected-main
broker 执行。candidate 不得替换、动态加载或修改 broker、Catalog、profile 或 authorization
policy。

每个 attempt SHALL 使用独立 candidate/review pins、Job、Session、intent/outcome 与 fresh
trusted facts。只有前一 attempt 已 durable terminal，且 broker 根据完整 outcome/readback
给出 `safeToReflash`，才可进入下一 attempt；candidate 或 reviewer 不得自行给出该分类。
outcomeUnknown、unresolved destructive intent、身份不确定、broker/reviewer crash、取消时已
存在 destructive intent、无法证明安全的 partial write、越界 diff/plan、成功、过期或超次
均 SHALL 永久终止 campaign，不得自动 replay/recovery。CI、后台 daemon/scheduler 与普通
continuation 不能自行 mint 或扩大 campaign。

产品无法密码学证明聊天账号/传输 provenance，本策略显式信任交互式 Agent 如实转交用户
确认；Agent SHALL NOT 伪造未发生的确认，亦 SHALL NOT 自行创建、修改或批准 standing
authorization(POL-AGENT-001 适用)。AI adversarial review 是用户已确认 delegated envelope
内的必要缩小门，不是独立 authority，也不替代 protected main + 维护者 review 对 policy、
broker、Catalog 与 profile 的发布信任根。已连接 USB、Task 风险标记或事后补记仍不构成或
追认任何 E2 authority。人类操作者亲手执行仍为有效执行路径，其 evidence 以
executor.kind=human 记录。

产品默认 Agent 路径 SHALL 使用 bounded Evolution：带 workspace envelope 的 Harness task
不得再由 caller 选择 normal/evolution mode；交互式 Agent Flash 默认 CLI 直接进入 campaign
preview/execute/continue/status。standing authorization 与人类 handoff 是不同信任/执行用途，
不得因默认化删除。旧 mode/CLI/chat execution surface SHALL fail closed，不得静默回退。
活跃 Harness domain、snapshot 与 status wire SHALL NOT 持久化、输出或基于
`normal|evolution` 分支；workspace policy 是 isolation/review/promotion 的唯一事实源。旧
snapshot mode 只可作为 decoder-only 一致性证据，且与 policy/workspace 冲突时 SHALL
fail closed。历史 chat authority SHALL NOT 暴露新的 validated creation factory。

## 保持不变

- POL-AGENT-001 及其余全部 POL-* 条款原文不动;
- 本 delta 使 constitution 版本 1.0.0 → 2.0.0(MAJOR:改变既有 Safety 条款的
  执行边界),随 CORE-3.0.0 ratification 一并生效。
