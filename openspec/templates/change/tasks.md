---
change: CHG-YYYY-NNN@approved-r1
core_baseline: CORE-1.0.0
platform_profile: PLATFORM-ID@version+sha256
integration_profiles: []
conformance_suite: CORE-CONFORMANCE-ID@sha256
base_revision: git-commit-or-immutable-workspace-revision
---

# Tasks

`tasks.md` is an index. Each executable packet is an immutable JSON file under `task-packets/` and validates against `contracts/task-packet.schema.json`. Claim/attempt/owner/run state is never written back here or into an approved packet.

## TASK-MX-NNN — Objective

- Revision：1
- Packet：`task-packets/TASK-MX-NNN.json`
- Status：draft | ready（superseded 是 owner-attested run 终态，不改 packet）
- Approval ID：APR-...（ready only；binds exact packet byte hash）
- Platform：macos | windows | linux（shared change 必须拆成至少一个明确执行平台的 Task；平台 evidence 不得来自 `shared`）
- Requirements：REQ-...
- Acceptance：AC-...
- Depends on：TASK-...
- Allowed paths：
  - `path/**`
- Forbidden paths：
  - `openspec/constitution.md`
  - `openspec/baselines/**`
- Exclusive resources：canonical `arkdeck-resource:<kind>:<id>` URNs or none
- Risk：low | medium | high | destructive
- Execution environment：standardAgent | controlledHardwareLab
- Runtime capabilities：显式最小白名单；未列出即禁止
- Hardware required：yes | no

### Deliverables

- 可观察产出和准确文件/模块。

### Verification

- AC → TEST → expected evidence。

### Stop conditions

- 规格冲突、需要 Core change、缺硬件/权限或出现 unknown destructive outcome 时 blocked。

### Handoff

- Claim/run/evidence sidecar 记录修改文件、命令/结果、evidence、remaining risk、下一安全恢复点；replacement claim 绑定并严格晚于 exact `taskSupersession` approval，普通 claim 的对应字段为 null；claim/run owner proof 来自受保护 claim 服务，controlled lab 另有 exact plan/target 人类授权；不改写 packet。
