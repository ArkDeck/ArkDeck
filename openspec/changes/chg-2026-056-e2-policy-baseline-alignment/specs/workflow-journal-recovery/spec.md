# Workflow, Journal, and Recovery Specification Delta

> Change: `CHG-2026-056-e2-policy-baseline-alignment@r7`
> Target: `openspec/specs/workflow-journal-recovery/spec.md`
> Baseline: `CORE-3.0.0`
> Proposed baseline: `CORE-4.0.0`

## MODIFIED Requirements

### Requirement: REQ-WF-004 Trusted Runtime facts and truthful hardware evidence

Runtime SHALL 仅从 durable admission/intent/outcome/recovery lineage、trusted target/binding/
tool facts 和已发布 immutable Artifact metadata 推导 realHardware evidence。Agent
`hostOnly`/`readOnly` run SHALL 记录 `defaultReadOnlyPolicy`；`deviceMutation`/`destructive`
SHALL 记录 `runtimeCapability`。destructive evidence SHALL 精确关联 operation/version、plan、
target/binding、typed inputs、Artifact hashes、reservation/use ordinal 与 terminal disposition。

Superseding recovery evidence 还 SHALL 记录每个 covered unknown intent、conservative
uncertain-effect-set digest、Provider coverage contract version、exact recovery plan、fresh
identity/topology、每个 typed effect outcome、reboot/rebind/postflight 与 resulting target epoch。
只有这些 trusted facts 完整时才可发布 `SupersedingRecoveryEpoch`。它 SHALL 明示原 outcome
仍 unknown，且不得把原 Job 投影为 succeeded。

Schema validation、evidence packaging、Manifest、caller assertion、UI/chat confirmation、
connected USB、历史 authority 或 terminal 文本 SHALL NOT mint capability、生成 coverage proof
或追溯改变旧 outcome。已有后续 Flash history 只有在全部同 target、ordering、coverage、
outcomes 与 postflight facts 可验证时 MAY 新增 supersession relation。

缺失、stale、mismatched、unknown、caller-supplied 或非 durable trusted facts；未匹配
intent/outcome；不可界定/覆盖 effect；或不可验证 Artifact hash SHALL 阻止 evidence
publication 和 recovery dispatch。Target identity 与 raw artifacts 继续适用隐私和不可变规则。

#### Scenario: AC-WF-004-01 Agent evidence facts complete

- GIVEN Agent 完成真实 typed run 或 complete-overwrite recovery，且 trusted admission、fresh
  target/tool facts、durable outcomes、lineage 和 Artifact metadata 完整
- WHEN Runtime projects hardware evidence
- THEN record 包含实际 executor/effect/Steps、匹配 policy provenance、target/plan/use/Artifact
  correlation，并在 recovery 时包含 effect-set/coverage/supersession/postflight facts
- AND record 通过 schema/semantic validation，但不 mint capability 或重写旧 outcome

#### Scenario: AC-WF-004-02 Required evidence facts are untrusted or incomplete

- GIVEN run/recovery 缺少 required trusted fact、identity、coverage、outcome、lineage 或 hash
- WHEN Runtime 被请求发布 evidence 或 supersession relation
- THEN schema-valid publication 与 recovery dispatch 均为 0，并报告精确 blocker
- AND caller、UI/chat、historical receipt 或 terminal text 不能使 run PASS

#### Scenario: AC-WF-004-03 Legacy E2 evidence cannot substitute for Runtime admission

- GIVEN 新 destructive run/recovery 声称 legacy authority，或尝试迁移 authority/evidence
- WHEN Runtime validates admission or projects the Job
- THEN 新 dispatch、capability mint 与 supersession publication 均为 0
- AND 历史 bytes 仅可 decode/export，不发生 migration 或 replay

### Requirement: REQ-JOB-001 Distinct recovery and terminal semantics

Job SHALL 保留现有 Core transition graph，并增加一个受控 complete-overwrite recovery branch：

```text
waitingForRecovery
  --automatic trusted proof--> recoveringByCompleteOverwrite
recoveringByCompleteOverwrite
  --all effects + reboot/rebind/postflight confirmed--> finalizing -> recovered
  --outcome/effect becomes unknown--> waitingForRecovery
  --confirmed failure with target state known--> finalizing -> failed
```

`recovered` SHALL 是与 `succeeded`、`failed`、`cancelled`、`interrupted` 不同的 terminal
disposition。它只声明一个 durable `SupersedingRecoveryEpoch` 已建立且当前 target lane 已知；
不得声明原 unknown Step 或原 workflow succeeded。History/UI/Manifest/export SHALL 显示原始
unknown intent 和恢复 linkage，不得折叠成普通成功。

进入 `recoveringByCompleteOverwrite` 前，Runtime SHALL 已 durable 写 conservative effect set、
coverage proof、fresh identity/binding/topology、new capability reservation 与 recovery intent。
该状态只能 dispatch proof 中声明的 recovery Steps。若启动时发现已有 durable 后续 Flash
满足完整 proof，Reconciler MAY 零 dispatch 建立 relation 并进入 `recovered`。

#### Scenario: AC-JOB-001-03 Recovery does not replay an unknown Step

- GIVEN 启动时发现没有 outcome 的 destructive intent
- WHEN Reconciler 运行
- THEN 原 Step dispatch 数为 0，原 outcome 保持 unknown
- AND 只有完整 proof 可进入 distinct complete-overwrite recovery，否则保持 waitingForRecovery

#### Scenario: AC-JOB-001-05 Waiting recovery has an autonomous proven branch

- GIVEN Job 因 external outcome unknown 而处于 waitingForRecovery，stable identity 已确认
- WHEN Runtime 计算 conservative effect union 与 Provider coverage
- THEN proof 完整时无需用户请求即可进入 recoveringByCompleteOverwrite
- AND proof 缺失时仍处于 waitingForRecovery、dispatch 为 0，并报告不可 override blocker

### Requirement: REQ-JOB-006 Crash reconciliation never guesses or blindly replays

启动并取得单实例锁后，系统 SHALL 扫描未 finalize Session。只有 Provider 声明 restartSafe、
最后 outcome 确定且设备匹配时 MAY 从普通安全边界恢复。只有 intent 没有 outcome SHALL 标记
`outcomeUnknown`；该 destructive Step SHALL NOT 重放或猜测性补偿。

对 identity 已知的 unknown destructive intent，Reconciler SHALL 自动评估 exact published
Provider 的 complete-overwrite supersession contract。只有 durable old intent 足以界定 effect
union，且 fresh target/topology、Artifact、coverage、verification 和 budget 全部成立时，才
MAY 创建 distinct recovery capability/reservation/intent。既有 durable 后续 Flash 也只有在
完整 proof 下可零 dispatch 建立 supersession relation。否则保持 waitingForRecovery，且用户
确认不能改变结果。

#### Scenario: AC-JOB-006-01 Flash outcome missing

- GIVEN App 在 Flash intent durable 后、outcome 前崩溃
- WHEN 重启 reconcile
- THEN 原 Flash dispatch 数不增加，原 intent 标记 outcomeUnknown
- AND 完整 supersession proof 成立时自动运行 distinct recovery；不成立时零 dispatch 并报告 blocker
