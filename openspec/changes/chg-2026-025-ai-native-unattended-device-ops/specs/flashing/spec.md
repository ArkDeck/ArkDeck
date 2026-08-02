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
   逐项相同，且该 confirmation 未被消费；或
3. 用户监督式交互 Agent 会话中的 bounded evolution campaign confirmation：除第 2 项的
   exact plan/target/data-impact pins 外，还固定 protected-main base、candidate build target/
   toolchain、允许修改路径、diff 预算、`maxAttempts` 与 `validUntil`。产品只接受
   `maxAttempts <= 8`、有效期不超过 4 小时、并发 attempt = 1；每个未合入 candidate 的
   tree/diff/executable digest 由 protected-main broker 现场派生，并经独立只读 adversarial
   review PASS 后成为该 attempt 的 pin。

执行器 SHALL 在首个真实设备 Step 前逐项校验 authority、待执行计划与目标设备身份读回；
authority 缺失、过期、超次、已消费或任一项不一致时 SHALL fail closed：destructive
dispatch 数为 0，Job 标记 policyBlocked，并记录 blocked-attempt。one-shot chat
confirmation 在首次 admission 时单次消费，失败、取消、crash、outcomeUnknown 均不退款且
不得自动重放；不同 plan/target 或新的 invocation 必须取得新的确认。

bounded evolution campaign SHALL 使用不同 authority kind 与 durable campaign/attempt
ledger；旧 one-shot record 不得升级。未合入 candidate 只可在 task-owned isolation 中构建和
运行，且 SHALL NOT 取得 network、USB/HDC/RockUSB、raw shell、arbitrary executable/argv、
host path 或 authority capability；其唯一可执行输出是现有 Catalog 可表达的 typed strategy。
protected-main broker SHALL 重新 materialize 计划，并拒绝 candidate 对 Catalog/profile/
broker/authorization、operation/step/actionRef、计划、目标或预算的任何扩张。

每个 attempt 使用独立 candidate/review pins、Job/Session/intent/outcome，并在 reserve ordinal
前完成 scope/build/test/adversarial-review、host-only recovery、retention/writer admission、
archive member hash、staging/lowering prerequisite 与 fresh target readback。只有前一 attempt
durable terminal，且 broker 根据完整 step outcome/readback 给出 `safeToReflash`，才可继续；
candidate/reviewer 不能提供该分类。outcomeUnknown、unresolved intent、身份不确定、broker/
reviewer crash、取消时已有 destructive intent、无法证明安全的 partial write、postflight
lineage mismatch、成功、过期、超次、并发或 envelope drift 均终止 campaign，禁止 replay。

evidence SHALL 记录 executor、实际 authority kind/reference、attempt ordinal、candidate/
review/broker pins、fresh target readback、执行时间与 retry disposition；chat authority 不得
伪装成 standing authorization。AI review 是已确认 campaign 内必要且不充分的 candidate gate，
不能单独成为 E2 authority。普通 CI、后台无人值守任务不得 mint/扩权 campaign，并 SHALL 在
真实 binding 与无有效 E2 authority 的 `destructive` Step 同时出现时 fail closed。

#### Scenario: AC-FLASH-015-01 无 E2 authority 的真实刷写请求

- GIVEN 一个 Agent/CI 任务拥有真实设备 binding,并生成含 flashPartition 的
  execute plan,但既无覆盖该计划的有效 standing authorization，也无同一交互会话中
  未消费且逐项匹配的 one-shot/campaign chat confirmation
- WHEN workflow authorization gate 校验 execution class
- THEN destructive dispatch 数为 0,Job 标记 policyBlocked 并生成指明缺失授权载体
  的受控 blocker
- AND 该 run 不产生 realHardware evidence

#### Scenario: AC-FLASH-015-02 E2 authority 与待执行计划或目标不一致

- GIVEN 待执行计划的 target binding、固件、transport、HDC、Provider 或 Step 集合
  与 standing authorization 的 pinned 内容任一不同，或 standing authorization 已过期/
  超次，或 chat confirmation 的 plan/archive/step-set/target 任一漂移、已消费/复用，或
  campaign 的 base/allowed-path/build-toolchain/budget 任一漂移、candidate/review pin 缺失、
  前一 attempt 未 durable terminal/未由 broker 分类 safeToReflash、存在 outcomeUnknown/
  unresolved intent，或设备身份读回与 authority target lineage 不符
- WHEN 执行器在首个真实设备 Step 前校验 E2 authority
- THEN 真实设备 dispatch 数为 0,run 不得产生 verified realHardware evidence
- AND 后续补写 run、hardware evidence 或新的聊天确认不能把该次执行追认为已授权

#### Scenario: AC-FLASH-015-03 有效 E2 authority 下的 Agent 执行

- GIVEN main 上存在维护者 merged PR 载体的有效 standing authorization，或用户在受监督
  的同一交互式 Agent 会话中对已展示的 exact plan/target 作出未消费的明确 chat
  confirmation（one-shot 或 bounded evolution campaign），且执行前设备身份读回与
  authority target 一致；若为 campaign，则 attempt ordinal、有效期、base/scope/toolchain、
  派生 candidate/review pins 和前序 safe terminal 状态均符合封闭预算
- WHEN Agent dispatch 该 execute plan
- THEN destructive Step 按 typed workflow 执行,intent(含 authorizationRef)与
  outcome durable 记录
- AND evidence 记录 executor.kind=agent、实际 authority kind/reference 与目标读回，构成
  有效 realHardware evidence；chat confirmation 不被伪写为 standing authorization
- AND bounded campaign 的每个 attempt 独立记录 ordinal 与 candidate/review/broker pins，
  成功或任一不安全停止条件使其永久终止

#### Scenario: AIN-EVOLUTION-E2-001 未合入候选的分权执行

- GIVEN 用户确认的 campaign 固定 base、allowed paths/diff budget、exact Flash plan、目标、
  toolchain 与时间/attempt 上限，且 candidate 是该 envelope 内未合入 main 的补丁
- WHEN Evolution Mode 构建、测试和 adversarial-review 该 candidate
- THEN candidate 只能在无设备 capability 的 isolation 中产生 closed typed strategy，不能
  打开 USB/HDC/RockUSB、执行 raw shell、读取 authority 或替换 broker
- AND 只有 protected-main broker 可在重算 candidate pins、计划和 fresh target readback 后
  reserve ordinal 并 dispatch；任一越界或 review 非 PASS 时 destructive dispatch=0
