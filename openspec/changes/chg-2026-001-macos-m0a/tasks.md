---
change: CHG-2026-001-macos-m0a@proposed-r1
status: draft
packet_schema: openspec/contracts/task-packet.schema.json@1.0.0
runtime_state_location: evidence/runs/<task-id>/
---

# M0A Task Index

本文件只索引 immutable Task packet，不保存 owner、claim、attempt 或运行结果。packet 获得批准并变为 `ready` 后不可改写；运行态只写独立 claim/run/evidence sidecar。

| Task | Packet | Objective | Packet status |
| --- | --- | --- | --- |
| TASK-M0A-001 | `task-packets/TASK-M0A-001.json` | Bootstrap signed SwiftUI/package shell | draft |
| TASK-M0A-002 | `task-packets/TASK-M0A-002.json` | ProcessExecutor and HDC discovery prototypes | draft |
| TASK-M0A-003 | `task-packets/TASK-M0A-003.json` | HDC server supervision and lifecycle safety | draft |
| TASK-M0A-004 | `task-packets/TASK-M0A-004.json` | Single instance, journal durability and power lease | draft |
| TASK-M0A-005 | `task-packets/TASK-M0A-005.json` | Sandbox, file access and Gatekeeper matrix | draft |
| TASK-M0A-007 | `task-packets/TASK-M0A-007.json` | Controlled read-only USB/UART/TCP hardware matrix | draft |
| TASK-M0A-006 | `task-packets/TASK-M0A-006.json` | Distribution decision record | draft |

这些 draft packets 已固定当前 candidate 的 platform/integration/conformance hash 以便发现漂移；Core baseline hash、真实 base revision、approval ID 和 `ready` 状态仍为空，只能在 governance bootstrap、四轴 ratification 和人类 Task 批准完成后写入各自最终 packet。V1 Task revision 固定为 1；范围变化创建新 Task ID，不原地升 revision。任何 candidate pin 在 Ready Gate 都会重新核对。
