# Tasks

每个任务是下面的一个小节;状态直接改本文件,经 PR review 合入生效。

## TASK-MX-NNN — Objective

- Status:ready | in_progress | done | blocked
- Platform:macos | windows | linux
- Requirements:REQ-...
- Acceptance:AC-...
- Depends on:TASK-...(或 none)
- Readiness input pins(非载体示例):

  ```yaml pin-example
  - path: path/to/pinned-input
    blob: <40-hex git OID>
  - artifact: path/to/pinned-artifact
    sha256: <64-hex sha256>
  ```

  实例化新的 readiness 时,必须把 info string 改为 `yaml pins`,并将示例值
  替换为完整、真实的 40-hex Git OID 或 64-hex sha256。
- Applicable failure patterns:AF-NNN...(可多选) | none(附可审查理由)

  见 `../../planning/agent-failure-patterns.md`(非权威索引;与 canonical rule
  冲突时以 canonical 为准)。填 `none` 不是自动通过,reviewer 可要求改为相关
  AF ID;本行只用于让相关问题在开工前被显式回答,不改变任务状态或批准语义。
- Production reachability:root → authority → effect | not applicable(附理由)

  写出 production composition root、authority/permit 的产生点与 effect dispatch
  point;纯文档或 host-only 无 effect 的任务写 `not applicable` 并说明理由。
- Trusted fact sources:事实生产者、freshness/binding 与 anti-forgery 边界

  写明每项被信任的事实由谁生产、绑定到哪个目标/revision、调用方能否同时构造
  该事实与其证明。填写本行不使调用方自报字段升级为可信事实。
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
