# M0A Verification Plan

> Status：planned
> Change：CHG-2026-001-macos-m0a
> Core baseline：CORE-1.0.0
> Core conformance：CORE-CONFORMANCE-1.0.0
> Integration：OPENHARMONY-TOOLS@0.1.0

实际结果由 evidence/ 下的 run 记录承载;整体结论经维护者在 PR 中确认(V2 治理)。

## Acceptance matrix

| Evidence ID | Requirement/Port | Method | Expected result | Status |
| --- | --- | --- | --- | --- |
| MAC-M0A-SHELL-001 | App/package boundary | build + clean launch smoke | signed app launches; targets remain separated | passed(evidence/runs/TASK-M0A-001/run.md) |
| MAC-M0A-PROC-001 | REQ-JOB-005、REQ-NFR-002；AC-JOB-005-01、AC-NFR-002-01 | contract fixture | argv/no-shell/stream/timeout/cancel pass | passed(evidence/runs/TASK-M0A-002/run.md) |
| MAC-M0A-HDC-001 | REQ-HDC-001；AC-HDC-001-01、AC-HDC-001-02 | fake + installed tools | complete toolchain diagnostics and semantic failure correctly shown | blocked(evidence/runs/TASK-M0A-002/run.md; installed `hdc version` can mutate host-wide server lifecycle before TASK-M0A-003 ownership guard exists) |
| MAC-M0A-HDC-002 | REQ-HDC-002、REQ-HDC-003、REQ-HDC-004、REQ-HDC-009、REQ-HDC-010；AC-HDC-002-01、AC-HDC-003-01、AC-HDC-003-02、AC-HDC-004-01、AC-HDC-009-01、AC-HDC-010-01、AC-HDC-010-02、AC-HDC-010-03 | server fixture | global event, endpoint isolation, subserver no-call, critical-job block, stale-confirmation rejection and external automatic kill count 0 | blocked(evidence/runs/TASK-M0A-006/rollup.md; TASK-M0A-003 fixture 部分通过,subserver/真实集成证据缺失,部分 fixture 不升级整行) |
| MAC-M0A-RUNTIME-001 | REQ-JOB-008、AC-JOB-008-01 | two-process test | exactly one writer | passed(evidence/runs/TASK-M0A-004/run.md) |
| MAC-M0A-JOURNAL-001 | REQ-JOB-002、AC-JOB-002-01 | fault injection | failed durable intent prevents command | passed(evidence/runs/TASK-M0A-004/run.md) |
| MAC-M0A-POWER-001 | PORT-POWER-001 | unit + manual idle-sleep observation | activity is held only in the critical scope, released on success/failure/cancel/throw, and limits for lid/explicit sleep are stated | passed(evidence/runs/TASK-M0A-004/run.md) |
| MAC-M0A-TRUST-001 | REQ-HDC-001、REQ-HDC-003、REQ-HDC-006；PORT-TOOL-TRUST-001 | clean VM | every DevEco path/version/server/file/key matrix cell has exact tool hash and one result: passed, failed or blocked; none is unclassified | blocked(evidence/runs/TASK-M0A-005/run.md; clean-VM 与 Developer ID 前提缺失,维护者 2026-07-15 接受 blocked 入 TASK-M0A-006 汇总) |
| MAC-M0A-TRUST-002 | PORT-TOOL-TRUST-001 | clean VM | quarantined HDC is either system-blocked with non-bypass guidance or user-allowed by the system; ArkDeck xattr mutation count is 0 | blocked(evidence/runs/TASK-M0A-005/run.md; clean-VM 与 Developer ID 前提缺失,维护者 2026-07-15 接受 blocked 入 TASK-M0A-006 汇总) |
| MAC-M0A-TRUST-003 | PORT-TOOL-TRUST-001 | clean VM | the bit-identical no-quarantine control isolates Gatekeeper from Sandbox/file-access errors | blocked(evidence/runs/TASK-M0A-005/run.md; clean-VM 与 Developer ID 前提缺失,维护者 2026-07-15 接受 blocked 入 TASK-M0A-006 汇总) |
| MAC-M0A-TRUST-004 | PORT-TOOL-TRUST-001 | clean VM | Safari→Archive Utility quarantine propagation and resulting assessment are captured from a restored snapshot without xattr modification | blocked(evidence/runs/TASK-M0A-005/run.md; clean-VM 与 Developer ID 前提缺失,维护者 2026-07-15 接受 blocked 入 TASK-M0A-006 汇总) |
| MAC-M0A-SANDBOX-001 | PORT-FILE-ACCESS-001 | end-to-end | every prototype × image/key/output × USB/UART/TCP cell has an observed allowed/blocked result and diagnostic evidence | blocked(tasks.md TASK-M0A-007 blocker; M0A 壳无 supervised 探测面,维护者 2026-07-15 接受,矩阵移交 M1 重测) |
| MAC-M0A-DIST-001 | PLATFORM-MACOS@0.1.0 | signed entitlement/log + ADR review | ADR selects exactly one v1 distribution, lists exact entitlements, evidence, rejected alternatives, residual risks and revalidation triggers without a Core delta | blocked(evidence/runs/TASK-M0A-006/rollup.md; ADR-0001 已产出,选定分发的签名产物/clean-VM/独立 review 证据不存在) |

## Gate

The change cannot become verified until evidence is recorded for both prototypes or an explicit platform blocker is accepted. A failure may choose non-Sandbox distribution; it cannot weaken Core requirements.
