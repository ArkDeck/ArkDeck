# CHG-2026-005 Verification Plan

> Status:planned
> Change:CHG-2026-005-hdc-parser-golden-registration@r2
> Core baseline:CORE-2.0.0
> Integration input:OPENHARMONY-TOOLS@0.1.0

## Environment

- 仓库内只读 M0A failure candidate，以及维护者预先认可的 authoritative/controlled-human
  success/health/version raw inputs；登记任务自身不执行已安装 HDC、设备、外联网络或外部服务。
- 验证工具限于 byte comparison、SHA-256、SwiftPM build/resource smoke、YAML/SDD lint
  与 Git diff review。

## Acceptance matrix

| Gate ID | Method | Expected result | Status |
| --- | --- | --- | --- |
| I5-HDC-FIXTURE-001 | failure-candidate byte comparison | 每个 failure raw fixture 与 M0A candidate 的对应字节完全相等，不改写既有 failure marker/family | pending |
| I5-HDC-FIXTURE-002 | success/health/version provenance audit | 每个非 failure raw fixture 与维护者认可的 authoritative/controlled-human input bytes 完全相等；没有 Agent-run installed HDC 或由 parser 常量反向编造的 output | pending |
| I5-HDC-FIXTURE-003 | supported-family closure | M1-006 接受的每个 success/failure/healthy/version family 均有 versioned profile mapping 与 pinned golden；未登记 family 保持 unknown/unsupported | pending |
| I5-HDC-FIXTURE-004 | independent SHA-256 registry check | fixture ID/version/path/hash 在文件、OpenHarmony profile、Integration lock 与 Core conformance 中一致 | pending |
| I5-HDC-FIXTURE-005 | SDD/readiness guard | 新 profile/lock 版本可解析、SDD guard 通过，且 M1-006 只在完整 fixture closure、M1-005 durable seam、r3 design/UI/audit allowed paths 全部就绪后由独立 readiness/status PR 恢复 `ready` | pending |
| I5-HDC-RESOURCE-001 | SwiftPM build + Bundle.module resource contract | ArkDeckContractTests 以 `.copy("Fixtures/HDC/Golden")` 构建且无 unhandled-file warning；Bundle.module 保留 `Golden/<version>/...`，fixture registry path、集合、bytes 与 pinned hash 精确一致 | pending |
| I5-HDC-NODISPATCH-001 | static/run audit | HDC/process/network/device/destructive dispatch 均为 0，无真机或 conformance/release 声明 | pending |

## Negative checks

- 任一 fixture 字节、path、version 或 hash 不一致时 fail closed；
- failure fixture 出现 M0A candidate 中不存在的 marker/family，或非 failure fixture 超出
  维护者认可 input family 时停止并修订 integration proposal；
- success/healthy/checkserver/version provenance 缺失或只是 Agent-authored fake string 时
  fail closed；
- Integration lock 与 Core conformance 只有一方登记时 fail closed；
- `Package.swift` 未声明 Golden resources、build 出现 unhandled-file warning、Bundle.module
  缺文件或多文件时 fail closed；
- Golden resource 使用 `.process`、bundle 未保留 `Golden/<version>/...` registry path，
  或不同版本的同名文件冲突时 fail closed；
- 任何测试尝试执行已安装真实 `hdc` 或访问非 loopback 网络时停止。

## Result gate

- 本 change 只能证明完整 supported-family fixture/profile prerequisite 已 approved、
  versioned 且 pinned；
- `AC-HDC-005-01` 仍必须由后续 `TASK-M1-006` 的 canonical
  `TEST-AC-HDC-005-01` parserGolden run 二值验证；
- 任务实现、状态恢复与验证结论分属独立 PR，不得由本 proposal
  的批准替代。
