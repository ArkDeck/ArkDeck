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
2. 用户监督式交互 Agent 会话中的 bounded evolution campaign confirmation：除 exact
   plan/target/data-impact pins 外，还固定 protected-main base、candidate build target/
   toolchain、允许修改路径、diff 预算、`maxAttempts` 与 `validUntil`。产品只接受
   `maxAttempts <= 8`、有效期不超过 4 小时、并发 attempt = 1；每个未合入 candidate 的
   tree/diff/executable digest 由 protected-main broker 现场派生，并经独立只读 adversarial
   review PASS 后成为该 attempt 的 pin。

执行器 SHALL 在首个真实设备 Step 前逐项校验 authority、待执行计划与目标设备身份读回；
authority 缺失、过期、超次、已消费或任一项不一致时 SHALL fail closed：destructive
dispatch 数为 0，Job 标记 policyBlocked，并记录 blocked-attempt。r7 one-shot chat
confirmation 只保留历史 bytes 的只读 decode/export；新 usage、admission 与 dispatch
全部拒绝，且不得静默升级为 campaign。

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

同一 invocation 中，产品 SHALL 在每个 `safeToReflash` terminal 后自动执行下一轮 bounded
repair/build/test/review/fresh-reservation/broker execution，无需新的用户消息。repairer 只能看到
标准化失败码、attempt ordinal 与既往 strategy 摘要，运行在 read-only、owner-only、无源码/
network/device/Runtime/authority port 的目录，并只能返回 starting modes 与有界 Loader/HDC/
read-only timeout/poll 的 closed strategy；额外 key、越界值、重复 strategy 或任何 argv/
operation/partition/plan/target/authority 提议均 SHALL 拒绝。strategy 必须作为 immutable
synthetic candidate artifact 纳入 digest 和 adversarial review，即使 source diff 为空。

自动 continuation SHALL 证明本轮产生了新的 durable reservation，不能借旧 terminal 重放。
Loader transition 失败仅在 destructive intent 前且 merged broker fresh readback 证明同一 durable
target 仍处于 registered HDC-normal/Loader mode 时，MAY 分类 `safeToReflash`；fresh readback
缺失、target/topology 漂移、未新增 reservation 或任何不确定状态 SHALL 永久停止。candidate
evaluation 与 Flash attempt 均不得超过 campaign `maxAttempts`，exact Provider argv 不得因策略
修复改变。

evidence SHALL 记录 executor、实际 authority kind/reference、attempt ordinal、candidate/
review/broker pins、fresh target readback、执行时间与 retry disposition；chat authority 不得
伪装成 standing authorization。AI review 是已确认 campaign 内必要且不充分的 candidate gate，
不能单独成为 E2 authority。普通 CI、后台无人值守任务不得 mint/扩权 campaign，并 SHALL 在
真实 binding 与无有效 E2 authority 的 `destructive` Step 同时出现时 fail closed。

交互式 Agent 的默认 Flash CLI SHALL 直接使用 campaign preview/execute/continue/status，
不得再要求 caller 选择 evolution mode 或传入 one-shot confirmation fields。standing
authorization 与 human handoff SHALL 保留。旧 `evolution-*`/one-shot surface 必须在任何
usage reservation、intent 或 device process 前拒绝。

Harness 活跃 domain、snapshot 与 status wire SHALL NOT 保存、输出或基于
`normal|evolution` 分支；workspace policy 直接决定 isolation/review/promotion。旧 snapshot
mode 只可作为 decoder-only 一致性证据并在迁移后删除，且 mode/policy/workspace 任一冲突
SHALL 拒绝加载。task submit current wire 只接受 `workspaceAllowedPaths` 与
`workspaceAllowedOperations`；旧 `executionMode`、`allowedPaths`、
`evolutionAllowedOperations` SHALL 在建立 workspace/job 前拒绝。历史 chat authority 只可
从既有 bytes 解码/export，不得暴露新的 validated creation factory。

#### Scenario: AC-FLASH-015-01 无 E2 authority 的真实刷写请求

- GIVEN 一个 Agent/CI 任务拥有真实设备 binding,并生成含 flashPartition 的
  execute plan,但既无覆盖该计划的有效 standing authorization，也无同一交互会话中
  未消费且逐项匹配的 bounded evolution campaign confirmation
- WHEN workflow authorization gate 校验 execution class
- THEN destructive dispatch 数为 0,Job 标记 policyBlocked 并生成指明缺失授权载体
  的受控 blocker
- AND 该 run 不产生 realHardware evidence

#### Scenario: AC-FLASH-015-02 E2 authority 与待执行计划或目标不一致

- GIVEN 待执行计划的 target binding、固件、transport、HDC、Provider 或 Step 集合
  与 standing authorization 的 pinned 内容任一不同，或 standing authorization 已过期/
  超次，或 campaign 的 base/allowed-path/build-toolchain/budget 任一漂移、candidate/review
  pin 缺失、
  前一 attempt 未 durable terminal/未由 broker 分类 safeToReflash、存在 outcomeUnknown/
  unresolved intent，或设备身份读回与 authority target lineage 不符
- WHEN 执行器在首个真实设备 Step 前校验 E2 authority
- THEN 真实设备 dispatch 数为 0,run 不得产生 verified realHardware evidence
- AND 后续补写 run、hardware evidence 或新的聊天确认不能把该次执行追认为已授权

#### Scenario: AC-FLASH-015-03 有效 E2 authority 下的 Agent 执行

- GIVEN main 上存在维护者 merged PR 载体的有效 standing authorization，或用户在受监督
  的同一交互式 Agent 会话中对已展示的 exact plan/target 作出未消费的 bounded evolution
  campaign confirmation，且执行前设备身份读回与
  authority target 一致；若为 campaign，则 attempt ordinal、有效期、base/scope/toolchain、
  派生 candidate/review pins 和前序 safe terminal 状态均符合封闭预算
- WHEN Agent dispatch 该 execute plan
- THEN destructive Step 按 typed workflow 执行,intent(含 authorizationRef)与
  outcome durable 记录
- AND evidence 记录 executor.kind=agent、实际 authority kind/reference 与目标读回，构成
  有效 realHardware evidence；chat confirmation 不被伪写为 standing authorization
- AND bounded campaign 的每个 attempt 独立记录 ordinal 与 candidate/review/broker pins，
  成功或任一不安全停止条件使其永久终止

#### Scenario: AIN-EVOLUTION-DEFAULT-001 Agent 默认路径无旧模式分叉

- GIVEN 一个新建的 workspace-backed Agent task 或交互式 Agent Flash 请求
- WHEN caller 未提供 execution-mode/evolution alias/one-shot chat fields，并使用默认
  `--workspace-allowed-*` envelope
- THEN workspace task 自动进入 bounded Evolution，Flash 默认入口产生或消费 exact campaign
- AND 旧 surface 在 reservation/intent/device process 前拒绝，历史 chat evidence 仍可读取
- AND snapshot/status 不含 mode 字段，legacy mode 仅在与 workspace policy 一致时可迁移
- AND standing authorization 与 human handoff 的独立生产路径保持可用

#### Scenario: AIN-EVOLUTION-E2-001 未合入候选的分权执行

- GIVEN 用户确认的 campaign 固定 base、allowed paths/diff budget、exact Flash plan、目标、
  toolchain 与时间/attempt 上限，且 candidate 是该 envelope 内未合入 main 的补丁
- WHEN Evolution Mode 构建、测试和 adversarial-review 该 candidate
- THEN candidate 只能在无设备 capability 的 isolation 中产生 closed typed strategy，不能
  打开 USB/HDC/RockUSB、执行 raw shell、读取 authority 或替换 broker
- AND 只有 protected-main broker 可在重算 candidate pins、计划和 fresh target readback 后
  reserve ordinal 并 dispatch；任一越界或 review 非 PASS 时 destructive dispatch=0

#### Scenario: AIN-EVOLUTION-REPAIR-001 同一 invocation 自动安全修复

- GIVEN 用户已确认一个未过期且仍有 attempt 预算的 campaign，前一 attempt 的 durable terminal
  由 merged broker 分类为 `safeToReflash`
- WHEN 默认 Flash 入口继续该 invocation
- THEN read-only repairer 仅基于标准化失败提出新的 bounded closed strategy，candidate target
  精确校验并回显，独立 adversarial review PASS 后 merged broker 才可 fresh reserve/execute
- AND 若 Loader transition 失败但 fresh readback 证明同一 durable target 仍在 registered mode，
  产品自动进入下一轮；success、unknown/unsafe、漂移、无新 reservation 或预算耗尽立即封口
- AND 任一轮的 Provider operation/partition/argv、plan/archive/step-set、target 与 authority pins
  均保持不变，candidate/repairer 从不接触真实设备
