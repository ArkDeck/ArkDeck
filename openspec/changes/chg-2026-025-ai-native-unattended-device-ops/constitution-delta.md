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
2. `destructive` Step 存在维护者经 merged PR 预先批准、与待执行计划逐项精确一致
   的 standing authorization(目标设备身份/binding revision、固件、transport、
   HDC、Provider、Step 集合、恢复路径、有效期与次数上限);
3. 执行门在首个真实设备 Step 前完成逐项校验与目标设备身份读回,任一缺失或不一致
   SHALL fail closed(零 dispatch,记录 blocked-attempt);
4. evidence 如实记录 executor 身份(human 或 agent)、authorizationRef(agent 执行
   必填)、目标确认、执行时间与恢复路径。

只读采集与 host 侧分析在 ready 任务范围内 MAY 无人值守执行;可逆 deviceMutation
另需 per-device typed capability evidence。普通 CI 不持 standing authorization,
SHALL 仍只运行 schema/contract tests、fake/simulation 与 plan-only。

聊天中的"继续"、已连接 USB、Task 标为 high risk 或事后补记 SHALL NOT 构成或追认
standing authorization;Agent SHALL NOT 自行创建、修改或批准 standing
authorization(POL-AGENT-001 适用)。人类操作者亲手执行仍为有效执行路径,其
evidence 以 executor.kind=human 记录。

## 保持不变

- POL-AGENT-001 及其余全部 POL-* 条款原文不动;
- 本 delta 使 constitution 版本 1.0.0 → 2.0.0(MAJOR:改变既有 Safety 条款的
  执行边界),随 CORE-3.0.0 ratification 一并生效。
