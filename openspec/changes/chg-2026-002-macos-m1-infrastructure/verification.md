# M1 Verification Plan

> Status：planned  
> Change：CHG-2026-002-macos-m1-infrastructure@r1  
> Core baseline：CORE-1.0.0
> Core conformance：CORE-CONFORMANCE-1.0.0  
> Integration：OPENHARMONY-TOOLS@0.1.0

实际结果由 evidence/ 下的 run 记录承载;整体结论经维护者在 PR 中确认(V2 治理)。

## Core acceptance coverage

本 change 的 61 个 Core AC 全部使用 `openspec/verification/acceptance-cases.yaml` 的 canonical method/Test ID/minimum evidence；expected result 是各 AC 规范 Scenario block 的全部 GIVEN/WHEN/THEN/AND 子句，不得转述或弱化。逐 AC 分配见各 immutable Task packet 的 `verification` 数组；packet union 与 `scope.yaml` 精确相等。

## Platform acceptance matrix

| Evidence ID | Requirement/Port | Method | Expected result | Status |
| --- | --- | --- | --- | --- |
| MAC-M1-PORTS-001 | PORT-INSTANCE-001、PORT-ACTIVATION-001、PORT-POWER-001、PORT-CLOCK-ELAPSED-001、PORT-CLOCK-ACTIVE-001、PORT-SLEEP-WAKE-001；REQ-JOB-008、REQ-NFR-001 | macOS Port contract suite | exactly one writer; activation without lock takeover; power lease released on every terminal path; clock sleep semantics proven; sleep/wake triggers journal+reconcile | pending |
| MAC-M1-JOURNAL-001 | REQ-JOB-002、REQ-JOB-006、REQ-JOB-007 | crash-window fault injection matrix | kills before intent / after durable intent / after side effect / before finalize each reconcile to the defined state; zero destructive replay; outcomeUnknown preserved | pending |
| MAC-M1-STORE-001 | REQ-STO-001…005、PORT-VOLUME-001、PORT-STORAGE-001 | volume identity + admission + ENOSPC injection | same-volume claims share one budget; second heavy writer waits/rejected; metadata headroom survives external pressure; runtime ENOSPC finalizes shards and fails closed | pending |
| MAC-M1-HDC-001 | REQ-HDC-002、REQ-HDC-003、REQ-HDC-004、REQ-HDC-009、REQ-HDC-010 | fake-hdc real-child-process supervisor matrix | external/unknown automatic lifecycle call count 0; ownership/generation transitions exact; endpoint isolation holds; global failure fans out exactly once | pending |
| MAC-M1-SIM-001 | REQ-FLASH-006、POL-MODE-001 | simulated end-to-end orchestration run | journal/cancel/reconcile exercised with zero real connectKey and zero external tool launches; evidence persistently classified simulated | pending |
| MAC-M1-DIAG-001 | REQ-DIAG-001、REQ-DIAG-002、PORT-LOGGING-001 | logging/diagnostics skeleton suite | categorized redacted logs; bounded rotation; export bundle excludes device raw by default | pending |

## Gate

本 change 不产生任何真实硬件或发布声明。它成为 `verified` 的前提是：全部 61 个 Core AC 与 6 个 platform AC 有可复查证据、fake/simulated 证据未被记为真机、且没有任何 Core/AC/contract 变更混入实现。发布范围（capability 组合）由后续 release subject 的 `includedCapabilities` 按 `capability-registry.yaml` 另行声明与验证。
