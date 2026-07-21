# CHG-2026-005 Verification Plan

> Status:passed;maintainer confirmation 见文末,candidate `verified` 在
> verification closure PR 合入后生效(acceptance matrix 的 Status 列保持起草期
> `pending` 不改写,七项 gate 实际结论以 TASK-I5-001/TASK-I5-002 run.md 为准:
> 全部 satisfied;`AC-HDC-005-01` 不在本 confirmation 范围,仍待 M1-006)
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

## Maintainer confirmation(2026-07-18)

- Approval:PR #40,维护者 `lvye` merge,merge commit `3a4d45c`。
- 实现+登记(provenance 认可):PR #41,维护者 `lvye` merge,merge commit
  `4ac288c`。
- TASK-I5-001 `→done`:PR #42,merge commit `8162004`;TASK-I5-002(M1-006
  readiness 恢复+自身 done):PR #43,merge commit `e29462c`。
- Confirmation scope:七项 `I5-HDC-*` gate 的 run.md 结论(全部 satisfied,
  含三方 hash 1/1/1 两次独立复核、`.copy` 资源契约 3/0、零 dispatch)、真实
  3.2.0d 无 `[success]` 标记的登记披露,以及 Result gate 边界——本 change 仅
  证明 fixture prerequisite registered,`AC-HDC-005-01` 不在 confirmation 范围,
  仍待 `TASK-M1-006` parserGolden 实证。
- 本 confirmation 满足 verified gate;不构成 archive。本 change 暂不归档:
  M1-006 在途会话仍以本 change 的 registry/evidence 路径为只读依据,archive
  留待 M1-006 done 后独立 PR 裁量(先例 #21/#49)。
