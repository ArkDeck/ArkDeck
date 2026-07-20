# M1 Verification Plan

> Status：planned  
> Change：CHG-2026-002-macos-m1-infrastructure@r7
> Core baseline：CORE-2.0.0
> Core conformance：CORE-CONFORMANCE-2.0.0
> Integration base：OPENHARMONY-TOOLS@0.2.0
> M1-HDC execution input：CHG-2026-005 verified profile + pinned fixture pack

实际结果由 evidence/ 下的 run 记录承载;整体结论经维护者在 PR 中确认(V2 治理)。

## Core acceptance coverage

本 change 的 62 个 Core AC 全部使用 `openspec/verification/acceptance-cases.yaml` 的 canonical method/Test ID/minimum evidence；expected result 是各 AC 规范 Scenario block 的全部 GIVEN/WHEN/THEN/AND 子句，不得转述或弱化。逐 AC 分配见 `tasks.md` 各任务的 Verification 段(V2:原 immutable task packets 已废止);全部任务分配的并集与 `scope.yaml` 精确相等。`AC-JOB-001-07` 由 `TASK-M1-001` 的 CORE-2.0.0 closure run 覆盖，不借用另一 change 的 evidence 直接宣称本 platform task 完成。

r4 不新增 Core AC；它将 `PORT-FILE-ACCESS-001`、`PORT-TOOL-TRUST-001` 与
`PORT-DEVICE-ACCESS-001` 绑定到 `MAC-M1-HDC-001`，并要求同一 M1-006 evidence 同时证明
durable Core toolchain intent、descriptor/inode-bound atomic launch、封闭 Workflows
executor/finalizer 组合和实际签名 Sandbox XCUITest。SwiftPM/domain 测试不能替代签名 App
路径，签名 Sandbox 也不能替代真实硬件、Developer ID/公证或 release evidence。

r5 不改变 acceptance method、expected result 或 evidence class。它只要求 full package gate
中的两个 legacy case 不再与同一 gate 的 r4 safety assertions 相反：fabricated PID evidence
必须被拒绝，successful lifecycle audit 必须断言 terminal reconciliation；positive ownership
仍由 dedicated process-backed `ownershipEvidenceContract` 提供。

r6 不改变 acceptance method、expected result、minimum evidence 或 evidence class。它只把
TASK-M1-007 的 implementation scheduling dependency 改为已验证的 CHG-2026-014
consolidated-interface boundary。`AC-DEV-001-01`、`AC-DEV-002-01/02`、
`AC-DEV-003-01/02`、`AC-DEV-004-01`、`AC-DEV-005-01`、`AC-DEV-006-01`、
`AC-DEV-008-01` 全部保持 canonical `contract`；其同一 implementation revision 的
binding/rebind/effect/lane contract/property evidence 可在锁屏 headless host 二值执行。
这不满足或降级 M1-006 HDC cases、`MAC-M1-HDC-001` 或任何 platform/hardware claim。

r7 同样不改变 acceptance method、expected result、minimum evidence 或 evidence class。
它只补全 TASK-M1-008 的执行边界并在 TASK-M1-007 尚未 done 时撤回旧的提前 `ready`。
（r7 历史叙述；M1-007 已经 PR #127/#134 done、M1-008 已经 PR #135 readiness 恢复
`ready`，现行状态一律以 tasks.md 为准——2026-07-20 注记。）
`TEST-AC-FLASH-006-01` 仍是 canonical `contract`；`TEST-MAC-M1-SIM-001` 仍是 `platform`，
但其 approved method 只要求实际 macOS 本地 Session/journal/manifest 的 simulated end-to-end
run，可在锁屏 headless host 二值执行，不要求 GUI、签名 App、HDC、真实设备或系统授权。
两项必须绑定同一 implementation revision，并同时证明 persistent simulated classification、
hardware-support verified writer count 0、real connectKey count 0 与 external tool launch count 0；
该 platform evidence 不得升级为 realHardware、compatibility、support、conformance 或 release。

## Platform acceptance matrix

| Evidence ID | Requirement/Port | Method | Expected result | Status |
| --- | --- | --- | --- | --- |
| MAC-M1-PORTS-001 | PORT-INSTANCE-001、PORT-ACTIVATION-001、PORT-POWER-001、PORT-CLOCK-ELAPSED-001、PORT-CLOCK-ACTIVE-001、PORT-SLEEP-WAKE-001；REQ-JOB-008、REQ-NFR-001 | macOS Port contract suite | exactly one writer; activation without lock takeover; power lease released on every terminal path; clock sleep semantics proven; sleep/wake triggers journal+reconcile | passed（TASK-M1-004 done，PR #32/#33；`evidence/runs/TASK-M1-004/run.md` 含人工 sleep/wake attempt 3） |
| MAC-M1-JOURNAL-001 | REQ-JOB-002、REQ-JOB-006、REQ-JOB-007 | crash-window fault injection matrix | kills before intent / after durable intent / after side effect / before finalize each reconcile to the defined state; zero destructive replay; outcomeUnknown preserved | passed（TASK-M1-003 done；`evidence/runs/TASK-M1-003/run.md`） |
| MAC-M1-STORE-001 | REQ-STO-001…005、PORT-VOLUME-001、PORT-STORAGE-001 | volume identity + admission + ENOSPC injection | same-volume claims share one budget; second heavy writer waits/rejected; metadata headroom survives external pressure; runtime ENOSPC finalizes shards and fails closed | passed（TASK-M1-005 done，PR #37/#38；`evidence/runs/TASK-M1-005/run.md`） |
| MAC-M1-HDC-001 | REQ-HDC-001…010；PORT-PROCESS-001、PORT-FILE-ACCESS-001、PORT-TOOL-TRUST-001、PORT-DEVICE-ACCESS-001 | pinned-golden fake-hdc real-child-process matrix + descriptor-bound launch + durable reopen/replay + signed Sandbox macOS XCUITest | only approved/pinned read-only semantic families are accepted; durable intent and actual descriptor/inode/hash/argv stay bound; path substitution launches zero children; external/unknown automatic lifecycle count 0 while diagnostics and confirmed recovery options are shown; subserver capability is shown read-only with spawn/killall count 0; ownership/generation and endpoint isolation are exact; global failure fans out once; lifecycle preview/confirmation/intent/actual argv/outcome survive reopen with one correlation; every HDC UI result is asserted through the signed Sandbox test build | blocked（TASK-M1-006 遗留：所缺只读 probe registry 属 CHG-2026-015，signed XCUITest 另待 Developer Mode 操作者授权；`evidence/runs/TASK-M1-006/run.md`） |
| MAC-M1-SIM-001 | REQ-FLASH-006、POL-MODE-001 | simulated end-to-end orchestration run | journal/cancel/reconcile exercised with zero real connectKey and zero external tool launches; evidence persistently classified simulated | passed（TASK-M1-008 done，PR #147；`evidence/runs/TASK-M1-008/run.md`；evidence 分类 simulated） |
| MAC-M1-DIAG-001 | REQ-DIAG-001、REQ-DIAG-002、PORT-LOGGING-001 | logging/diagnostics skeleton suite | categorized redacted logs; bounded rotation; export bundle excludes device raw by default | passed（TASK-M1-009 done，PR #50/#51；`evidence/runs/TASK-M1-009/run.md`） |

> Status update（2026-07-20，随追溯修复 PR 合入）:上表四行 `passed` 依各 owning task 的
> merged `done` 状态与 run evidence 同步；`MAC-M1-HDC-001` 如实标 `blocked`（M1-006
> 遗留，解锁=CHG-2026-015 probe registry + Developer Mode XCUITest）；`MAC-M1-SIM-001`
> 保持 pending 归 TASK-M1-008。本更新只同步账本，不构成新的验证结论，也不改变
> change 级 `Status:planned`。
>
> Status update（2026-07-20，随 TASK-M1-008 `ready→done` 独立状态 PR 合入）:
> `MAC-M1-SIM-001` 依 TASK-M1-008 merged `done`（implementation PR #147 squash
> `0a06bd6`）与 `evidence/runs/TASK-M1-008/run.md` 翻转 `passed`，evidence 分类保持
> `simulated`。同上，本更新只同步账本；`MAC-M1-HDC-001` 仍 `blocked`（M1-006 遗留），
> change 级 `Status:planned` 不变。

## Gate

本 change 不产生任何真实硬件或发布声明。它成为 `verified` 的前提是：全部 62 个 Core AC
与 6 个 platform AC 有可复查证据、fake/simulated 证据未被记为真机、所有被接受的 HDC
semantic output 都可追到 approved/pinned golden 或真实 evidence、含用户可见结果的 HDC
Scenario 同时具有 signed Sandbox XCUITest closure，且没有任何 Core/AC/contract 变更混入
实现。签名 Sandbox 路径只构成 fake/read-only platform evidence，不改变 ADR-0001、分发或
硬件结论。发布范围
（capability 组合）由后续 release subject 的 `includedCapabilities` 按
`capability-registry.yaml` 另行声明与验证。macOS 在本 r3 修订后仍保持
`conformance_status: notStarted`，不是 `needsReverification`。
