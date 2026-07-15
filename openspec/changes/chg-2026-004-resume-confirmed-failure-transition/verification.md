# Verification Plan

> Change：CHG-2026-004-resume-confirmed-failure-transition
> Change status：approved via maintainer-reviewed PR #16
> Verification status：implementation passed；TASK-C4-001 evidence recorded，等待 maintainer verification confirmation 与 archive flow

## Environment

- Candidate baseline：`CORE-2.0.0` over pinned `CORE-1.0.0`。
- JSON Schema 2020-12 validator for `journal-event.schema.json` plus Core semantic
  transition validator。
- macOS Swift toolchain used by `Packages/ArkDeckKit` and synthetic in-memory Job
  fixtures for both execute and plan-only modes。
- Dispatch call counters separated by host/read-only、deviceMutation、destructive and
  unknown-kind attempts；state-transition recorder separately counts
  `running`/`planning` events。
- No hardware、HDC、provider process、network or external-effect dispatch。

## Binary oracle for AC-JOB-001-07

每个 vector 从已 durable 进入 `resumeAtConfirmedSafeBoundary` 且尚未进入
`running`/`planning` 的 Job 独立开始：

| Vector | Device identity | External-effect outcomes | Failure disposition | Exact result | Ordinary Step dispatch | Intermediate running/planning |
| --- | --- | --- | --- | --- | ---: | ---: |
| C（confirmed） | confirmed | all confirmed | confirmed failure | `resumeAtConfirmedSafeBoundary → finalizing → failed` | 0 | 0 |
| U-I（unknown identity） | unknown | all confirmed or unknown | must not be classified confirmed | `resumeAtConfirmedSafeBoundary → waitingForRecovery` | 0 | 0 |
| U-O（unknown outcome） | confirmed or unknown | at least one unknown | must not be classified confirmed | `resumeAtConfirmedSafeBoundary → waitingForRecovery` | 0 | 0 |

每个 vector 分别在 execute 与 plan-only mode 运行。普通 Step dispatch counter 必须
对 read-only/host、deviceMutation、destructive 和 unknown-kind attempts 全部为 0。
Recovery control event、state-transition persistence 和进入 `finalizing` 后的既有
finalization action 不计为 marker 状态的普通 Workflow Step dispatch。

## Acceptance matrix

| AC ID | Test ID / method | Binary expected result | Required evidence |
| --- | --- | --- | --- |
| AC-JOB-001-07 | `TEST-AC-JOB-001-07`; recovery decision + journal contract/state-machine matrix | C、U-I、U-O 全部精确匹配上表；两个新增 pair 均可编码/解码；evidence/pair mismatch 被拒绝；所有 marker dispatch counters 为 0 | schema report、semantic-validator report、Swift unit/property test report and fixtures |
| AC-JOB-001-03 | `TEST-AC-JOB-001-03`; canonical `recoveryFaultInjection` | intent-without-outcome destructive Step 只到 waitingForRecovery；replay/dispatch count 0 | regression test report |
| AC-JOB-001-05 | `TEST-AC-JOB-001-05`; canonical `recoveryFaultInjection` | only all-confirmed recovery gates reach marker；任一条件不成立回到 waitingForRecovery，unknown Step dispatch 0 | property/matrix report |
| AC-JOB-001-01/02/04/06 | canonical global Test IDs/methods | normative Scenario blocks remain unchanged and all clauses pass | full Job regression report |

## Journal and semantic contract tests

- Pair-only schema accepts both
  `resumeAtConfirmedSafeBoundary → finalizing` and
  `resumeAtConfirmedSafeBoundary → waitingForRecovery` for otherwise valid transition
  events；round-trip preserves exact pair。
- Semantic validator accepts marker→finalizing only for C and accepts
  marker→waitingForRecovery for U-I/U-O。
- Semantic validator rejects：
  - marker→finalizing with unknown identity or outcome；
  - marker→waitingForRecovery presented as a fully confirmed failure decision；
  - confirmed/unknown handling that first records marker→running/planning；
  - any pair not present in the complete Core graph。
- Existing finalizing→failed pair remains valid；no required field or schema version
  change is silently introduced。

## Swift state-machine and dispatch tests

- Exact destination set assertions：
  - execute marker = running、finalizing、waitingForRecovery；
  - plan-only marker = planning、finalizing、waitingForRecovery。
- C event directly records marker→finalizing, preserves original failure, then reaches
  failed after finalization。
- U-I/U-O event directly records marker→waitingForRecovery and preserves unknown/no
  dispatch directives。
- Normal resume confirmation still selects only the mode-correct running/planning edge。
- From marker, authorization attempts for every ordinary effect/kind are rejected with
  invariant evidence; dispatch call count remains 0。
- Property test over evidence combinations proves unknown precedence and absence of a
  confirmed/unknown path through running/planning。

## Regression and compatibility checks

- Validate every permitted transition pair and reject every non-graph pair。
- Run full applicable ArkDeckKit Job/journal tests and `scripts/check-sdd.sh`。
- Read an old journal with the new reader；exercise a new-edge journal against an old-graph
  compatibility fixture and record the expected rejection。No journal rewrite or downgrade
  claim is permitted。

## Platform disposition

| Platform | Required disposition |
| --- | --- |
| macOS | Current `conformance_status` remains `notStarted`, not `needsReverification`; after candidate baseline ratification, CHG-2026-002 follow-up verification must be retargeted to `CORE-2.0.0`. |
| Windows | deferred / not started; no verification or support claim in this change. |
| Linux | deferred / not started; no verification or support claim in this change. |

## Deviations

- AJV Draft 2020-12 validation 未加载可选 `ajv-formats` plugin，故明确忽略
  `date-time` format assertion；两个 synthetic timestamp 自身为 ISO 8601 UTC，本
  change 的 graph oracle 不依赖该 format。结构、external schema reference 与两个新
  transition pair 均通过验证。
- Contract/synthetic evidence 不报告为 real hardware evidence。

## Result gate

- [x] Maintainer-approved delta selects both direct marker exits and their precedence。
- [x] TASK-C4-001 was unblocked only after approval and all applicable tests passed。
- [x] Journal pair schema、semantic validator and Swift state machine agree on both new
  exits。
- [x] `AC-JOB-001-07` C/U-I/U-O rows are binary and all zero-dispatch/no-fake-state
  counters pass。
- [x] Existing `AC-JOB-001-01…06` regressions pass with reviewable evidence。
- [x] macOS/Windows/Linux dispositions above are recorded without a premature support
  claim。
- [ ] Maintainer confirms verification in PR review before any `verified` status change。
