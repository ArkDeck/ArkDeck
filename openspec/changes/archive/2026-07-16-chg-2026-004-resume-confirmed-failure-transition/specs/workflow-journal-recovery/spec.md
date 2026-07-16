# Workflow, Journal, and Recovery Specification Delta

> Change：`CHG-2026-004-resume-confirmed-failure-transition`
> Status：approved delta via maintainer-reviewed PR #16
> Baseline：`CORE-1.0.0`
> Proposed baseline：`CORE-2.0.0`

## MODIFIED Requirements

### Requirement: REQ-JOB-001 Distinct Job terminal states

Job SHALL 使用以下 Core transition graph；未列出的 transition SHALL fail closed 并记录 invariant violation。平台 SHALL NOT 新增绕过确认、recovery 或 cancellation 的状态路径。

```text
execute:
  queued → preflight → running ↔ waitingForDevice ↔ awaitingRebindConfirmation
                        ├→ finalizing → succeeded
                        └→ waitingForRecovery

  any execute nonterminal except userAbandonRequested/finalizing/waitingForRecovery
    --confirmed failure--> finalizing → failed
  any active execute nonterminal --external outcome/identity unknown--> waitingForRecovery
  any cancellable execute nonterminal → cancelRequested
                                      → cancellingAtSafeBoundary → cancelled

  waitingForRecovery --explicit reconcile/recovery request--> reconciling
  reconciling ├→ resumeAtConfirmedSafeBoundary → running
              ├→ finalizing → failed
              └→ waitingForRecovery
  resumeAtConfirmedSafeBoundary
              ├--confirmed failure--> finalizing → failed
              └--external outcome/identity unknown--> waitingForRecovery
  waitingForRecovery → userAbandonRequested → interrupted
                              └--audit/finalization failed--> waitingForRecovery

plan-only:
  queued → preflight → planning → finalizing → planned
  queued | preflight | planning --confirmed failure--> finalizing → failed
  any cancellable plan-only nonterminal → cancelRequested
                                        → cancellingAtSafeBoundary → cancelled

launch recovery:
  nonterminalOnLaunch → reconciling
                      ├→ resumeAtConfirmedSafeBoundary → running | planning
                      ├→ finalizing → failed
                      └→ waitingForRecovery → userAbandonRequested → interrupted
  resumeAtConfirmedSafeBoundary
                      ├--confirmed failure--> finalizing → failed
                      └--external outcome/identity unknown--> waitingForRecovery
```

`confirmed failure` SHALL 表示 failure、设备身份及其外部副作用结果均已确定；只要设备身份或任一 external-effect outcome 仍未知，系统 SHALL 进入或保持 `waitingForRecovery`，不得用 `failed` 掩盖未知结果。`waitingForRecovery` 只能通过显式的 Provider recovery/reconcile 请求进入 `reconciling`，或者通过经审计的用户放弃进入 `userAbandonRequested`。只有 Provider 声明 restart-safe、安全边界已确认、最后 outcome 确定且设备 binding 已确认时，`reconciling` 才能进入 `resumeAtConfirmedSafeBoundary`；能确定失败且无需猜测副作用时才能进入 `finalizing → failed`。否则 SHALL 回到 `waitingForRecovery`。

`resumeAtConfirmedSafeBoundary` SHALL 是恢复控制标记而非普通 Workflow Step 派发阶段。Job SHALL 先转移到 `running` 或 `planning` 才能派发普通 Step。若在该转移前发现 confirmed failure，Job SHALL 直接进入 `finalizing → failed`；若设备身份或任一 external-effect outcome 未知，Job SHALL 直接进入 `waitingForRecovery`。这两个分支 SHALL NOT 先伪造 `running` 或 `planning` 状态，且在 marker 状态的普通 Step 派发数 SHALL 为 0。未知 Step SHALL NOT 被派发、重放或猜测性补偿。

Journal transition-pair contract SHALL 同时允许 `resumeAtConfirmedSafeBoundary → finalizing` 与 `resumeAtConfirmedSafeBoundary → waitingForRecovery`。Pair membership 不构成语义授权：semantic validator SHALL 仅在 failure、identity 与全部 external-effect outcome confirmed 时接受前一 pair，仅在 identity 或至少一个 external-effect outcome unknown 时接受后一 pair；evidence 与 pair 不匹配时 SHALL 拒绝并记录 invariant violation。

`cancellable nonterminal` SHALL 排除 `waitingForRecovery`、`userAbandonRequested`、`reconciling` 和 `finalizing`。执行 `criticalNonInterruptible` Step 时，取消请求仍 SHALL durable 记录并进入 `cancellingAtSafeBoundary`，该状态表示等待 Provider 报告安全边界，而不是强杀当前进程；到达安全边界后才进入 `cancelled`。`planned`、`succeeded`、`failed`、`cancelled` 和 `interrupted` SHALL 是不同终态。终态 Job SHALL NOT 接受新的 external-effect Step。UI、manifest、History 和导出 SHALL NOT 把这些状态折叠为同一个“完成”。

#### Scenario: AC-JOB-001-01 Planned 不是刷机成功

- GIVEN plan-only 完整计划已持久化
- WHEN Job 终结
- THEN状态为 planned
- AND硬件成功计数不增加

#### Scenario: AC-JOB-001-02 非法终态迁移

- GIVEN Job 已处于 succeeded、planned、failed、cancelled 或 interrupted
- WHEN任何组件请求迁移回 running 或派发 external-effect Step
- THEN请求被拒绝并记录 invariant violation

#### Scenario: AC-JOB-001-03 Recovery 不得绕过确认

- GIVEN启动时发现没有 outcome 的 destructive intent
- WHEN Reconciler 运行
- THEN允许的路径只有 waitingForRecovery
- AND不得直接迁移到 running/succeeded 或重放该 Step

#### Scenario: AC-JOB-001-04 Execute preflight 确定失败

- GIVEN execute Job 在 preflight 得到已确认且没有未知外部副作用的失败
- WHEN状态机处理失败
- THEN路径为 preflight → finalizing → failed
- AND该 Job 不会永久停留在非终态

#### Scenario: AC-JOB-001-05 Waiting recovery 的受控恢复

- GIVEN Job 因设备身份或外部 outcome 未知而处于 waitingForRecovery
- WHEN用户发起 Provider recovery/reconcile
- THEN下一状态只能是 reconciling
- AND只有 restart-safe、安全边界、确定 outcome 和已确认 binding 全部成立时才能经 resumeAtConfirmedSafeBoundary 回到 running
- AND任一条件不成立时回到 waitingForRecovery，且不派发未知 Step

#### Scenario: AC-JOB-001-06 普通步骤取消

- GIVEN execute Job 正处于可取消的 running Step
- WHEN用户请求取消
- THEN路径为 cancelRequested → cancellingAtSafeBoundary → cancelled
- AND取消结果与安全边界写入 journal

#### Scenario: AC-JOB-001-07 Resume marker 的二值失败/未知决策

- GIVEN Job 已通过恢复确认并 durable 进入 resumeAtConfirmedSafeBoundary
- AND Job 尚未转移到 running 或 planning，且尚未派发普通 Workflow Step
- WHEN状态机分别评估以下 decision vectors
  - confirmed：failure、设备身份与全部 external-effect outcome 均已确定
  - unknown identity：设备身份未知
  - unknown outcome：至少一个 external-effect outcome 未知
- THEN confirmed vector 的精确路径为 resumeAtConfirmedSafeBoundary → finalizing → failed
- AND unknown identity 与 unknown outcome vectors 的精确目标均为 waitingForRecovery
- AND所有 vectors 在 resumeAtConfirmedSafeBoundary 状态的普通 Workflow Step 派发数均为 0
- AND confirmed 与 unknown vectors 在 marker 和目标状态之间的 running/planning transition 数均为 0
