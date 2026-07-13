---
change: CHG-2026-002-macos-m1-infrastructure@proposed-r1
status: draft
packet_schema: openspec/contracts/task-packet.schema.json@1.0.0
runtime_state_location: evidence/runs/<task-id>/
---

# M1 Task Index

本文件只索引 immutable Task packet，不保存 owner、claim、attempt 或运行结果。packet 获得批准并变为 `ready` 后不可改写；运行态只写独立 claim/run/evidence sidecar。

| Task | Packet | Objective | Packet status |
| --- | --- | --- | --- |
| TASK-M1-001 | `task-packets/TASK-M1-001.json` | Core domain, typed steps and Job state machines | draft |
| TASK-M1-002 | `task-packets/TASK-M1-002.json` | ProcessExecutor and semantic results | draft |
| TASK-M1-003 | `task-packets/TASK-M1-003.json` | Journal, reconcile and audited abandonment | draft |
| TASK-M1-004 | `task-packets/TASK-M1-004.json` | macOS runtime ports | draft |
| TASK-M1-005 | `task-packets/TASK-M1-005.json` | Session/Artifact store and storage coordination | draft |
| TASK-M1-006 | `task-packets/TASK-M1-006.json` | HDC supervisor and authorization | draft |
| TASK-M1-007 | `task-packets/TASK-M1-007.json` | Device binding, rebinding and lanes | draft |
| TASK-M1-008 | `task-packets/TASK-M1-008.json` | SimulatedFlashProvider isolation harness | draft |
| TASK-M1-009 | `task-packets/TASK-M1-009.json` | Diagnostics skeleton | draft |

这些 packets 的 Core/platform/integration/conformance hash 在 candidate baseline 最终生成后复核；base revision、approval ID 和 `ready` 状态只能在 governance bootstrap 完成、baseline ratified 且 M0A 的 distribution decision 可用后产生。
