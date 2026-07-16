# Tasks — CHG-2026-004 recovery-marker exits

> CHG-2026-004 was approved by maintainer review and merge of PR #16 at
> `d09c722ad54bfc73070de0b9dfe3758a34e48ec4`. `done` records completed scoped
> implementation evidence；verification and archive are separate maintainer-reviewed gates.

## TASK-C4-001 — Align the Core graph, journal contract, and state machine

- Status:done
- Completion evidence:`evidence/runs/TASK-C4-001/run.md`（contract/synthetic；change verification 仍等待 maintainer review）
- Approval gate:satisfied by maintainer-approved PR #16
- Platform:core conformance; macOS candidate implementation
- Requirements:REQ-JOB-001; POL-SAFETY-001; POL-RECOVERY-001; POL-WORKFLOW-001
- Acceptance:AC-JOB-001-01…07
- Depends on:none（change approval satisfied）
- Allowed paths:
  - `openspec/changes/chg-2026-004-resume-confirmed-failure-transition/**`
  - `openspec/contracts/journal-event.schema.json`
  - `Packages/ArkDeckKit/Sources/ArkDeckCore/JobStateMachine.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckCoreTests/JobStateMachineTests.swift`
  - journal contract/semantic-validator tests under the corresponding ArkDeckKit test target
  - `openspec/verification/**`（global registry/conformance update only in the approved archive flow）
  - `openspec/baselines/**`（candidate `CORE-2.0.0` ratification/archive flow only）
  - `openspec/config.yaml`（archive PR 仅将 `current_core_baseline` 选择器切换为 ratified `CORE-2.0.0`）
  - `openspec/specs/workflow-journal-recovery/spec.md`（archive PR only）
- Forbidden paths:
  - `openspec/constitution.md`
  - unrelated contracts, requirements, platform implementations, and product modules
  - real-device, HDC, provider, flash, erase, format, unlock, or update execution
- Risk:high（Core safety state-machine and persisted-journal graph change）
- Hardware required:no

### Objective

在 change 获批准后，使 approved delta、journal pair contract、semantic validator、
Swift state machine 和 conformance tests 对同一二值 decision model 达成一致，不引入
普通 Step dispatch window 或伪造 `running`/`planning` transition。

### Deliverables

- Approved complete `REQ-JOB-001` delta with `AC-JOB-001-07`。
- Journal contract 同时加入：
  - `resumeAtConfirmedSafeBoundary → finalizing`；
  - `resumeAtConfirmedSafeBoundary → waitingForRecovery`。
- Semantic guards 证明 confirmed/unknown evidence 与所选 pair 匹配。
- Swift execute/plan-only destination set 同时包含 `finalizing` 和
  `waitingForRecovery`，并保持各自正常 `running`/`planning` 出口。
- Contract/state-machine tests 证明 confirmed、unknown identity、unknown outcome、
  zero normal Step dispatch 和 zero fake execution-phase transition。
- 任务完成后追加 `evidence/runs/TASK-C4-001/` run record；本 proposal 起草和
  `check-sdd.sh` 不计作 TASK-C4-001 implementation evidence。
- Change verified 后的 archive PR 才把 approved delta 合入 current spec/global
  acceptance registry，并 ratify candidate `CORE-2.0.0`。

### Verification

- `AC-JOB-001-07` → `TEST-AC-JOB-001-07`：
  - confirmed row exact path = marker→finalizing→failed；
  - unknown-identity 与 unknown-outcome rows exact destination = waitingForRecovery；
  - all rows normal Workflow Step dispatch count = 0；
  - failure/unknown rows intermediate running/planning transition count = 0；
  - both new journal transition pairs pass schema graph validation, and mismatched
    evidence fails semantic validation。
- `AC-JOB-001-03/05` → canonical recovery fault-injection tests：unknown destructive
  outcome remains recovery-gated and replay/dispatch count is 0。
- `AC-JOB-001-01/02/04/06` → canonical full Job regression suite：existing terminal、
  preflight failure and cancellation semantics remain unchanged。
- Run `scripts/check-sdd.sh` plus the full applicable ArkDeckKit contract/unit suite。

### Platform follow-up

- macOS conformance remains `notStarted`; it must not be changed to
  `needsReverification`。After `CORE-2.0.0` ratification, `CHG-2026-002` follow-up
  verification must target `CORE-2.0.0`。
- Windows/Linux remain deferred/not started and gain no support claim。

### Notes / handoff

- TASK-C4-001 became eligible for `ready` only after PR #16 merged；this readiness
  update does not execute the task or create implementation evidence。
- Do not mark the change `verified` until every AC has reviewable evidence and the
  maintainer confirms it in PR review。
- Do not unblock `TASK-M1-001` merely because this proposal is complete; it remains
  blocked until this Core change is approved and TASK-C4-001 produces aligned contract、
  implementation and verification evidence。
