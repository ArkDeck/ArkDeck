# CHG-2026-026 Evidence

本 change 已由 PR #298 合入 `main` 后成为 `approved`；PR #440 合入 r2 后，
`TASK-RKFUI-001` 与 `TASK-RKFUI-001A` 为 `ready`。001A 当前因 firmware pin drift
在 execute gate fail closed；proposal r3 只起草 `7.0.0.33` exact repin。

已有 evidence：

```text
evidence/runs/TASK-RKFUI-001/run.md
evidence/runs/TASK-RKFUI-001/sanitized-e0-receipt.json
evidence/runs/TASK-RKFUI-001/diagnostic-alignment-2026-07-22.md
evidence/runs/TASK-RKFUI-001/review-nits-2026-07-22.md
evidence/runs/TASK-RKFUI-001/hermetic-contract-test-2026-07-22.md
evidence/runs/TASK-RKFUI-001/e0-preflight-2026-07-24.md
evidence/runs/TASK-RKFUI-001/clean-discovery-repin-2026-07-24.md
evidence/runs/TASK-RKFUI-001A/blocked-preflight-firmware-drift-2026-07-24.md
evidence/runs/TASK-RKFUI-001A/blocked-preflight-firmware-drift-2026-07-24.json
```

未来 run 位置：

```text
evidence/runs/TASK-RKFUI-002/
evidence/runs/TASK-RKFUI-003/
evidence/runs/TASK-RKFUI-004/
```

BlueTool 静态分析是 proposal 输入，记录在 change 根目录 `bluetool-analysis.md`；它不是
ArkDeck platform/realHardware 验收，且未执行任何真实设备命令。

`TASK-RKFUI-001` 当前 run 如实为 `blocked`：contract 定向测试通过，但全量 suite 发现
package-boundary 测试表与已批准设计/Package 依赖不一致，所需测试文件不在任务 allowed
paths；signed Sandbox E0 又在 child launch 前因所选工具带 quarantine fail closed。
该 run 不构成 RockUSB direct-access PASS、真机支持或后续 execute readiness。

`TASK-RKFUI-001A` blocked preflight 只读确认目标 serial、HDC/server 与 clean
`rkdeveloptool` pins 命中，但当前设备报告 OpenHarmony `7.0.0.33`，不同于 PR #440
批准的 `7.0.0.34`。该 run 的 E1/destructive dispatch 均为 0、`maxRuns = 1` 未消费，
不构成 Loader capability evidence；只有维护者 merge proposal r3 后才允许另一个独立
implementation+evidence PR 开始。
