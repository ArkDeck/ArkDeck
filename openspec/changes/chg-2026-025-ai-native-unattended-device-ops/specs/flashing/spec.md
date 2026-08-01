# Flashing Specification Delta

> Change:CHG-2026-025-ai-native-unattended-device-ops
> Target capability:`openspec/specs/flashing/spec.md`
> Baseline:CORE-2.1.0
> Proposed baseline:CORE-3.0.0

## MODIFIED Requirements

### Requirement: REQ-FLASH-015 Agent and ordinary CI destructive boundary

自主 Agent 的执行凭据 MAY dispatch Flash workflow 的全部分支(含 `destructive`
Step),当且仅当具备以下一种 E2 authority：

1. 维护者经 merged PR 预先批准的 standing authorization，且其 pinned 内容(目标设备
   身份/binding revision、固件、transport、HDC、Provider、Step 集合、恢复路径、有效期
   与次数上限)与待执行计划逐项精确一致；或
2. 用户监督式交互 Agent 会话中的一次性 chat confirmation：Agent 已向用户展示完整
   canonical plan digest、archive/step-set digest、目标 binding 摘要与数据影响，用户在
   同一会话明确确认，产品收到的 typed confirmation assertion 与现场重算 plan/target
   逐项相同，且该 confirmation 未被消费。

执行器 SHALL 在首个真实设备 Step 前逐项校验 authority、待执行计划与目标设备身份读回；
authority 缺失、过期、超次、已消费或任一项不一致时 SHALL fail closed：destructive
dispatch 数为 0，Job 标记 policyBlocked，并记录 blocked-attempt。chat confirmation 在
首次 admission 时单次消费，失败、取消、crash、outcomeUnknown 均不退款且不得自动重放；
不同 plan/target 或新的 invocation 必须取得新的确认。evidence SHALL 记录 executor、实际
authority kind/reference、目标读回、执行时间与恢复路径；chat confirmation 不得伪装成
standing authorization。产品无法密码学证明聊天账号或传输 provenance，本策略显式信任
交互式 Agent 如实转交确认 assertion；Agent SHALL NOT 伪造未发生的确认或自行创建/批准
standing authorization。普通 CI、后台无人值守任务及没有新用户消息的自动 continuation
SHALL 只允许 contract、fake、simulated 或 plan-only 分支，并 SHALL 在真实 binding 与
`destructive` Step 同时出现时 fail closed。

#### Scenario: AC-FLASH-015-01 无 E2 authority 的真实刷写请求

- GIVEN 一个 Agent/CI 任务拥有真实设备 binding,并生成含 flashPartition 的
  execute plan,但既无覆盖该计划的有效 standing authorization，也无同一交互会话中
  未消费且逐项匹配的 chat confirmation
- WHEN workflow authorization gate 校验 execution class
- THEN destructive dispatch 数为 0,Job 标记 policyBlocked 并生成指明缺失授权载体
  的受控 blocker
- AND 该 run 不产生 realHardware evidence

#### Scenario: AC-FLASH-015-02 E2 authority 与待执行计划或目标不一致

- GIVEN 待执行计划的 target binding、固件、transport、HDC、Provider 或 Step 集合
  与 standing authorization 的 pinned 内容任一不同，或 standing authorization 已过期/
  超次，或 chat confirmation 的 plan/archive/step-set/target 任一漂移、已消费/复用，或
  设备身份读回与 authority target 不符
- WHEN 执行器在首个真实设备 Step 前校验 E2 authority
- THEN 真实设备 dispatch 数为 0,run 不得产生 verified realHardware evidence
- AND 后续补写 run、hardware evidence 或新的聊天确认不能把该次执行追认为已授权

#### Scenario: AC-FLASH-015-03 有效 E2 authority 下的 Agent 执行

- GIVEN main 上存在维护者 merged PR 载体的有效 standing authorization，或用户在受监督
  的同一交互式 Agent 会话中对已展示的 exact plan/target 作出未消费的明确 chat
  confirmation，且执行前设备身份读回与 authority target 一致
- WHEN Agent dispatch 该 execute plan
- THEN destructive Step 按 typed workflow 执行,intent(含 authorizationRef)与
  outcome durable 记录
- AND evidence 记录 executor.kind=agent、实际 authority kind/reference 与目标读回，构成
  有效 realHardware evidence；chat confirmation 不被伪写为 standing authorization
