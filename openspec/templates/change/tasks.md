# Tasks

每个任务是下面的一个小节;状态直接改本文件,经 PR review 合入生效。

## TASK-MX-NNN — Objective

- Status:ready | in_progress | done | blocked
- Platform:macos | windows | linux
- Requirements:REQ-...
- Acceptance:AC-...
- Depends on:TASK-...(或 none)
- Allowed paths:
  - `path/**`
- Forbidden paths:
  - `openspec/constitution.md`
  - `openspec/specs/**`(除非任务本身就是 archive PR 的 delta 合入)
- Risk:low | medium | high | destructive(destructive 的真实设备步骤须持 merged PR 承载的 standing authorization;人类亲手或 Agent 无人值守执行均须 evidence 记录 executor)
- Hardware required:yes | no

### Deliverables

- 可观察产出和准确文件/模块。

### Verification

- AC → 方法 → expected evidence。

### Notes / handoff

- 完成后在 `evidence/runs/<task-id>/` 追加 run 记录(命令、结果、AC 结论、偏差、遗留风险)。
