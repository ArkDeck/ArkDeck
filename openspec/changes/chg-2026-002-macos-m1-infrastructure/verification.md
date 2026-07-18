# M1 Verification Plan

> Status：planned  
> Change：CHG-2026-002-macos-m1-infrastructure@r4
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

## Platform acceptance matrix

| Evidence ID | Requirement/Port | Method | Expected result | Status |
| --- | --- | --- | --- | --- |
| MAC-M1-PORTS-001 | PORT-INSTANCE-001、PORT-ACTIVATION-001、PORT-POWER-001、PORT-CLOCK-ELAPSED-001、PORT-CLOCK-ACTIVE-001、PORT-SLEEP-WAKE-001；REQ-JOB-008、REQ-NFR-001 | macOS Port contract suite | exactly one writer; activation without lock takeover; power lease released on every terminal path; clock sleep semantics proven; sleep/wake triggers journal+reconcile | pending |
| MAC-M1-JOURNAL-001 | REQ-JOB-002、REQ-JOB-006、REQ-JOB-007 | crash-window fault injection matrix | kills before intent / after durable intent / after side effect / before finalize each reconcile to the defined state; zero destructive replay; outcomeUnknown preserved | pending |
| MAC-M1-STORE-001 | REQ-STO-001…005、PORT-VOLUME-001、PORT-STORAGE-001 | volume identity + admission + ENOSPC injection | same-volume claims share one budget; second heavy writer waits/rejected; metadata headroom survives external pressure; runtime ENOSPC finalizes shards and fails closed | pending |
| MAC-M1-HDC-001 | REQ-HDC-001…010；PORT-PROCESS-001、PORT-FILE-ACCESS-001、PORT-TOOL-TRUST-001、PORT-DEVICE-ACCESS-001 | pinned-golden fake-hdc real-child-process matrix + descriptor-bound launch + durable reopen/replay + signed Sandbox macOS XCUITest | only approved/pinned read-only semantic families are accepted; durable intent and actual descriptor/inode/hash/argv stay bound; path substitution launches zero children; external/unknown automatic lifecycle count 0 while diagnostics and confirmed recovery options are shown; subserver capability is shown read-only with spawn/killall count 0; ownership/generation and endpoint isolation are exact; global failure fans out once; lifecycle preview/confirmation/intent/actual argv/outcome survive reopen with one correlation; every HDC UI result is asserted through the signed Sandbox test build | pending |
| MAC-M1-SIM-001 | REQ-FLASH-006、POL-MODE-001 | simulated end-to-end orchestration run | journal/cancel/reconcile exercised with zero real connectKey and zero external tool launches; evidence persistently classified simulated | pending |
| MAC-M1-DIAG-001 | REQ-DIAG-001、REQ-DIAG-002、PORT-LOGGING-001 | logging/diagnostics skeleton suite | categorized redacted logs; bounded rotation; export bundle excludes device raw by default | pending |

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
