---
id: CHG-2026-004-resume-confirmed-failure-transition
status: archived
class: core
core_change_level: major
owner: lvye
core_baseline: CORE-1.0.0
platforms: [macos, windows, linux]
---

# Define recovery-marker exits for confirmed failure and uncertainty

## Why

`REQ-JOB-001` 要求适用的 nonterminal Job 在 confirmed failure 时进入
`finalizing → failed`，并要求设备身份或 external-effect outcome 未知时 fail
closed 到 `waitingForRecovery`。按其字面范围，这两条规则都覆盖
`resumeAtConfirmedSafeBoundary`。已 accepted 的
`journal-event.schema.json` 却只允许该 marker 转移到 `running` 或
`planning`；当前 Swift 状态机候选也采用了同样的受限 destination set。

因此，恢复过程中在 marker 状态发现确定失败或重新发现不确定性时，现有
authorities 无法共同表达结果。实现不得伪造一次 `running`/`planning` 中间状态来
绕开 contract，也不得从冲突 authority 中自行选择更方便的一项。本 Core change
提议显式补齐两个安全出口，供维护者决定并批准。

## What changes

### In scope

- 将 `resumeAtConfirmedSafeBoundary` 明确定义为恢复控制标记，并采用以下
  mutually exclusive 决策：
  - failure、设备身份和全部 external-effect outcome 均已确定：
    `resumeAtConfirmedSafeBoundary → finalizing → failed`；
  - 设备身份或任一 external-effect outcome 未知：
    `resumeAtConfirmedSafeBoundary → waitingForRecovery`。
- 在 journal transition-pair contract 中加入两对：
  `resumeAtConfirmedSafeBoundary → finalizing` 和
  `resumeAtConfirmedSafeBoundary → waitingForRecovery`。pair-only schema 只表达
  graph；semantic validator 仍须分别证明 confirmed 或 unknown 前提。
- 使 Swift 状态机候选在 execute 与 plan-only mode 下均包含上述两个出口，并由
  confirmed-failure/unknown 事件从 marker 直接选择对应出口。
- 禁止以 `resumeAtConfirmedSafeBoundary → running|planning` 伪造中间状态处理已
  确定失败；既有正常恢复才可使用 `running|planning` 出口。
- 保持 marker 状态下所有普通 Workflow Step 均不可派发；状态转换和 recovery
  control event 不属于普通 Step dispatch。
- 新增 `AC-JOB-001-07`，以二值 decision vectors 同时覆盖 confirmed、unknown、
  两个 journal transition pair、零普通 Step dispatch 和零伪造中间状态。

### Out of scope

- 除上述两个 marker 出口及其 guard 外的 Job transition、cancellation、recovery
  或 journal-event 行为。
- 放宽 `outcomeUnknown`、device binding、restart-safe、safe-boundary 或 durable
  journal gate。
- 新增 journal field、重写既有 journal，或在本 proposal 阶段修改 accepted
  contract/current spec/global acceptance registry/baseline。
- 真实设备操作、平台特例或硬件支持声明。

### Observable behavior before/after

- Before：Core prose 要求 confirmed failure 终结并要求 unknown fail closed，但
  journal contract 与 Swift destination set 均拒绝 marker 的这两个直接出口。
- After：confirmed vector 可 durable 记录
  `resumeAtConfirmedSafeBoundary → finalizing → failed`；unknown identity/outcome
  vector 可 durable 记录 `resumeAtConfirmedSafeBoundary → waitingForRecovery`。
  两者在 marker 状态的普通 Step dispatch count 均为 0，且都不会先产生虚假的
  `running`/`planning` transition。

## Scope（涉及的 Requirement/AC）

- Requirements：`REQ-JOB-001`，并保持 `POL-SAFETY-001`、
  `POL-RECOVERY-001` 与 `POL-WORKFLOW-001` 的 safety boundary。
- Acceptance：`AC-JOB-001-01`…`AC-JOB-001-06`（regression），
  `AC-JOB-001-07`（added；change-local 登记，archive 时才进入 global registry）。
- Contracts/implementations after approval：
  `openspec/contracts/journal-event.schema.json` 的两个 transition pair、Core semantic
  transition validator，以及 macOS Swift `JobStateMachine` conforming implementation。
- Core baseline bump：yes；candidate baseline 保持 `CORE-2.0.0`。该 change 改变已
  accepted 的 Core 状态机和 journal graph，因此 `core_change_level` 保持 `major`。

## Safety, privacy, and compatibility

- Failure precedence：unknown identity/outcome 优先进入 `waitingForRecovery`；只有
  identity 与所有 outcome 均已确定时，失败才可分类为 confirmed 并进入
  `finalizing`。不得用 `failed` 掩盖未知结果。
- Dispatch safety：marker 不是普通执行 phase。read-only、mutation、destructive
  普通 Step 在该状态的授权数都必须为 0；unknown Step 不得重放。
- Journal compatibility：contract 将新增两个 allowed transition pair，不新增 required
  field。硬编码旧 graph 的 reader 可能拒绝包含任一新 edge 的 journal；回滚前必须
  显式确认 reader compatibility，不做隐式 journal rewrite。
- Privacy/hardware：不收集新数据；验证仅使用 schema、unit/property test 与 synthetic
  fixture，不接触真实设备或外部 provider。

## Declared platform disposition

| Platform | Current conformance | Disposition for this proposal |
| --- | --- | --- |
| macOS | `notStarted` | 保持 `notStarted`，不得写成 `needsReverification`。`CHG-2026-002` 的后续实现/验证必须改为针对 ratified `CORE-2.0.0` 重新验证；在此之前不得产生新 conformance claim。 |
| Windows | `notStarted` | `deferred` / not started；不得新增支持或 release claim。 |
| Linux | `notStarted` | `deferred` / not started；不得新增支持或 release claim。 |

## Approval

维护者 `lvye` 于 2026-07-15 在 PR #16 提交 approving review；该 PR 随后合入受保护
的 `main`，merge commit 为
`d09c722ad54bfc73070de0b9dfe3758a34e48ec4`。因此 `status: approved` 已生效，
本 change 的语义决策获得人类批准。批准不等于 TASK-C4-001 已执行、done 或 change
verified；任务 readiness 由批准后的独立 PR 更新。

## Verification closure

`TASK-C4-001` 的 contract/synthetic evidence、完整 Swift regression、Draft 2020-12
journal fixtures 与 SDD guard 已在 PR #19 提交。维护者 `lvye` 于 2026-07-16 对 head
commit `c8d256b4cf8158630d1fd80d7b5da47d4945411e` 提交 approving review；该 PR
随后合入受保护 `main`，merge commit 为
`478ef98fb5363b69d7cbdabe7e871d974c4cd7ca`。

该 review/merge 构成 `verification.md` 所要求的 maintainer verification
confirmation，并使 verification closure PR 中的 `status: verified` 生效。

## Archive and CORE-2.0.0 ratification

本 archive PR 将 approved delta 精确合入 current
`workflow-journal-recovery` spec，把 `AC-JOB-001-07` 加入全局 acceptance
index/cases 与 `CORE-CONFORMANCE-2.0.0`，并新增 `CORE-2.0.0` baseline 记录。

本文件中的 `status: archived` 和 baseline 记录中的 `status: ratified`
在维护者 `lvye` review 并将该 archive PR 合入受保护 `main` 后同时生效；
未合入前仍只是待批准的 archive/ratification 声明。该合入不改变任何
platform conformance claim：macOS 保持 `notStarted`，Windows/Linux 保持
deferred/not started。
