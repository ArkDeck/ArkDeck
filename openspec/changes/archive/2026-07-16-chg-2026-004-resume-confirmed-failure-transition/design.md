# Change Design

## Context and constraints

- Pinned baseline：`CORE-1.0.0`；candidate baseline：`CORE-2.0.0`（MAJOR）。
- Conflicting inputs：`REQ-JOB-001` 与
  `openspec/contracts/journal-event.schema.json#/$defs/stateTransitionPair`。
- 本文件是候选设计；change 在 maintainer approval 前保持 non-authoritative。
- Recovery marker/control event 与普通 Workflow Step dispatch 是两个不同概念。
  `resumeAtConfirmedSafeBoundary` 不得成为 read-only、mutation 或 destructive Step
  的派发 phase。
- Unknown identity/outcome 必须优先 fail closed；不能为了适配旧 graph 构造
  `running`/`planning` 中间状态。

## Normative decision model proposed for approval

在 Job 已处于 `resumeAtConfirmedSafeBoundary` 且尚未转移到正常 execution phase 时，
一次 boundary evaluation 只允许下列二值结论：

| Evidence class | Required facts | Direct transition | Completion |
| --- | --- | --- | --- |
| confirmed failure | failure 已确定，device identity 已确认，全部 external-effect outcome 已确认 | `resumeAtConfirmedSafeBoundary → finalizing` | `finalizing → failed` |
| unknown | device identity 未知，或至少一个 external-effect outcome 未知 | `resumeAtConfirmedSafeBoundary → waitingForRecovery` | 保持 recovery-gated，等待显式 reconcile/recovery |

Unknown 分支优先：只要任一 uncertainty predicate 为真，调用方就不得产生
confirmed-failure event。无 failure 且所有 resume gate 仍成立时，既有正常出口
`running`（execute）或 `planning`（plan-only）不变；该正常路径不属于本 change 的
新增语义。

所有 decision rows 都要求 marker 状态下普通 Workflow Step dispatch count 为 0。
confirmed 与 unknown rows 还要求 marker 与目标状态之间的 `running`/`planning`
transition count 为 0。

## Requirement mapping

| Requirement / AC | Design component | Verification |
| --- | --- | --- |
| REQ-JOB-001 / AC-JOB-001-07 confirmed row | direct marker→finalizing pair、confirmed semantic guard、finalizing→failed | journal contract + Swift state-machine tests |
| REQ-JOB-001 / AC-JOB-001-07 unknown rows | direct marker→waitingForRecovery pair、identity/outcome uncertainty guard | journal contract + fault/matrix tests |
| REQ-JOB-001 / AC-JOB-001-07 dispatch row | marker excluded from ordinary dispatch phases | read-only/mutation/destructive zero-dispatch tests |
| AC-JOB-001-03/05 | existing outcomeUnknown/recovery gates | regression fault-injection/property tests |

## Architecture and data flow

1. Reconciler 只有在 restart-safe、safe boundary、outcome 和 binding 均已确认时才可
   进入 `resumeAtConfirmedSafeBoundary`。
2. 在正常 resume transition 之前，recovery coordinator 对当前 identity、全部 durable
   external-effect outcomes 和 failure disposition 生成同一次 evaluation result。
3. Semantic transition validator 先应用 unknown precedence，再产生 confirmed-failure、
   unknown 或 normal-resume control event；它不得把普通 Workflow Step 当作 control
   event。
4. State machine 从 marker 直接选择目标，并在任何目标侧动作前 durable 写入相应
   state-transition event。
5. 进入 `finalizing` 后按既有 finalization path 保留原始 failure，并终结为 `failed`；
   进入 `waitingForRecovery` 后保持 zero dispatch，直到显式 recovery/reconcile。

## Journal contract candidate

`journal-event.schema.json#/$defs/stateTransitionPair` 中
`from == resumeAtConfirmedSafeBoundary` 的 `to` set 候选改为：

```text
running | planning | finalizing | waitingForRecovery
```

本 change 新增且必须同时加入的 transition pairs 是：

```text
resumeAtConfirmedSafeBoundary → finalizing
resumeAtConfirmedSafeBoundary → waitingForRecovery
```

现有 `finalizing → failed` pair 不变。JSON Schema 的 pair validation 只判断 graph
membership，不能单独证明 triggering evidence；因此 Core semantic validator 还必须
执行：

- `→ finalizing`：failure、identity 与全部 external-effect outcome 均 confirmed；
- `→ waitingForRecovery`：identity unknown 或至少一个 outcome unknown；
- 若 evidence 与 pair 不匹配，拒绝 event、记录 invariant violation，普通 Step dispatch
  count 保持 0。

不新增 journal field、不改写旧 journal。`reason`/`triggerEventId` 继续携带可追踪原因；
具体 reason code 可由实现选定，但不得改变上述 pass/fail oracle。

## Swift state-machine candidate

macOS Swift 候选实现必须与同一 Core graph 对齐，但此处不批准具体 API 命名。至少
包含以下 destination changes：

```text
(.execute, .resumeAtConfirmedSafeBoundary)
  → [.running, .finalizing, .waitingForRecovery]

(.planOnly, .resumeAtConfirmedSafeBoundary)
  → [.planning, .finalizing, .waitingForRecovery]
```

事件处理候选沿用或等价实现：

- confirmed-failure event 从 marker 直接调用 transition to `finalizing`，保留
  original failure，并设置 failure finalization disposition；
- external-outcome-or-identity-unknown event 从 marker 直接调用 transition to
  `waitingForRecovery`，携带 no-unknown-step-dispatch / preserve-outcome-unknown
  directives；
- normal resume confirmation 才能进入 mode 对应的 `running`/`planning`；confirmed
  failure 与 unknown event 不得先调用 normal resume confirmation。

普通 dispatch authorization 的 allowlist 继续排除
`resumeAtConfirmedSafeBoundary`。该 guard 需要对 host/read-only、deviceMutation、
destructive 和 unknown-kind fail-closed case 做测试，不能只依赖 destination graph。

## Failure, cancellation, and recovery

- Confirmed failure：direct marker→finalizing→failed。
- Unknown identity/outcome：direct marker→waitingForRecovery；不得 failed、不得 replay。
- Cancellation：无变化。
- Crash/restart：durable marker 和选定 edge 继续由 journal reconciliation 解释；缺失
  outcome 仍按 unknown，不从 failure label 或 process exit code 推断成功/失败。
- Finalization failure：沿既有 finalization/recovery 规则处理，不在本 change 新增出口。

## Compatibility, security, and privacy

- 旧 reader 可能拒绝两种新 pair，部署/回滚必须按 reader graph compatibility gate。
- 不放宽 binding、effect、durability、replay 或 agent hardware policy。
- 不收集新信息；test evidence 为 contract/synthetic，不构成 hardware evidence。

## Alternatives and ADR disposition

- 保持旧 contract 并把 confirmed failure 排除在 marker 之外：拒绝，因为会留下已知
  failure 无法合法终结的 Core 歧义。
- 只加入 `marker → finalizing`：拒绝，因为 marker 后重新发现 unknown 时仍无合法的
  fail-closed journal edge。
- 先写 `running`/`planning` 再处理 failure/unknown：拒绝，因为会伪造 execution
  phase，并可能打开普通 Step dispatch window。
- 允许 marker 直接派发普通 Step：拒绝，因为会把 recovery control marker 变成执行
  phase，破坏 durable state-before-dispatch boundary。

无需单独 ADR：该选择本身是 Core product-state-machine 决策，由本 change proposal、
delta 和 maintainer approval 记录。
