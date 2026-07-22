# Flashing Specification Delta

> Change:CHG-2026-025-ai-native-unattended-device-ops
> Target capability:`openspec/specs/flashing/spec.md`
> Baseline:CORE-2.1.0
> Proposed baseline:CORE-3.0.0

## MODIFIED Requirements

### Requirement: REQ-FLASH-015 Agent and ordinary CI destructive boundary

自主 Agent 的执行凭据 MAY dispatch Flash workflow 的全部分支(含 `destructive`
Step),当且仅当存在维护者经 merged PR 预先批准的 standing authorization,且其
pinned 内容(目标设备身份/binding revision、固件、transport、HDC、Provider 与
Step 集合、恢复路径、有效期与次数上限)与待执行计划逐项精确一致。执行器 SHALL
在首个真实设备 Step 前逐项校验待执行计划与 standing authorization 的一致性,并
SHALL 对目标设备执行身份读回确认;standing authorization 缺失、过期、超次或任一
项不一致时 SHALL fail closed:destructive dispatch 数为 0,Job 标记
policyBlocked,并记录 blocked-attempt。evidence SHALL 记录 executor(human 或
agent 身份;agent 执行必须携带 authorizationRef)、目标确认(设备身份读回)、执行
时间与恢复路径。聊天确认、已连接 USB、事后 run 或 hardware evidence SHALL NOT
构成、升级或追认 standing authorization;Agent SHALL NOT 自行创建或批准 standing
authorization。普通 CI 的执行凭据 SHALL 只允许 contract、fake、simulated 或
plan-only 分支,并 SHALL 在真实 binding 与 `destructive` Step 同时出现时 fail
closed。

#### Scenario: AC-FLASH-015-01 无 standing authorization 的真实刷写请求

- GIVEN 一个 Agent/CI 任务拥有真实设备 binding,并生成含 flashPartition 的
  execute plan,但 main 上不存在覆盖该计划的有效 standing authorization
- WHEN workflow authorization gate 校验 execution class
- THEN destructive dispatch 数为 0,Job 标记 policyBlocked 并生成指明缺失授权载体
  的受控 handoff
- AND 该 run 不产生 realHardware evidence

#### Scenario: AC-FLASH-015-02 standing authorization 与待执行计划或目标不一致

- GIVEN 待执行计划的 target binding、固件、transport、HDC、Provider 或 Step 集合
  与 standing authorization 的 pinned 内容任一不同,或授权已过期/超次,或设备
  身份读回与授权 target 不符
- WHEN 执行器在首个真实设备 Step 前校验 standing authorization
- THEN 真实设备 dispatch 数为 0,run 不得产生 verified realHardware evidence
- AND 后续补写 run、hardware evidence 或聊天确认不能把该次执行追认为已授权

#### Scenario: AC-FLASH-015-03 有效 standing authorization 下的无人值守执行

- GIVEN main 上存在维护者 merged PR 载体的有效 standing authorization,其 pinned
  内容与待执行计划逐项一致,且执行前设备身份读回与授权 target 一致
- WHEN 自主 Agent 在无人值守条件下 dispatch 该 execute plan
- THEN destructive Step 按 typed workflow 执行,intent(含 authorizationRef)与
  outcome durable 记录
- AND evidence 记录 executor.kind=agent、authorizationRef 与目标读回,构成有效
  realHardware evidence
