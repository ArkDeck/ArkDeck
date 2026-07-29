# Spec Delta

> Change:CHG-2026-050-diagnostics-step-contract
> Target capability:`openspec/specs/workflow-journal-recovery/spec.md`

## ADDED Requirements

None.

## MODIFIED Requirements

### Requirement: REQ-WF-001 Closed typed workflow steps

Workflow SHALL 只组合批准的 typed step，例如 HDC/remote tool、send/receive、
parameter snapshot/set/restore、wait、verify、storage preflight、
postprocess、owned cleanup 和 confirmation。Profile SHALL NOT 注入任意
host shell。每个 published Catalog 中准备由 Runtime dispatch 的
`captureRemoteStdout` step SHALL 携带 closed、machine-checkable 的 action
identity；该 identity SHALL 能被 workflow-step schema 与实现 validator
一致地表达为 typed arguments。缺失、未知、kind 不匹配或不可表达的 action
binding SHALL 在 Catalog validation/generation 阶段 fail closed，不得由
Runtime 按 stepID 猜测或退化为通用远端命令。

#### Scenario: AC-WF-001-01 非法自由命令

- GIVEN Profile 包含未注册的 host command string
- WHEN schema/plan 校验
- THEN计划被拒绝
- AND外部进程调用数为 0

#### Scenario: AC-WF-001-02 Catalog stdout action 不可表达

- GIVEN published operation 声明 `captureRemoteStdout` step
- AND该 step 的 action identity 缺失、未知、kind 不匹配或无法通过
  workflow-step schema 与实现 validator
- WHEN Catalog validation/generation
- THEN Catalog 被拒绝且不生成 Runtime descriptor
- AND外部进程调用数为 0

## REMOVED Requirements

None.

## RENAMED Requirements

None.
