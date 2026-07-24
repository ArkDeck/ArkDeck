# CHG-2026-026 Evidence

本 change 已由 PR #298 合入 `main` 后成为 `approved`；PR #440 合入 proposal r2 后，
`TASK-RKFUI-001` 与 `TASK-RKFUI-001A` 为 `ready`。

已有 evidence：

```text
evidence/runs/TASK-RKFUI-001/run.md
evidence/runs/TASK-RKFUI-001/sanitized-e0-receipt.json
evidence/runs/TASK-RKFUI-001/diagnostic-alignment-2026-07-22.md
evidence/runs/TASK-RKFUI-001/review-nits-2026-07-22.md
evidence/runs/TASK-RKFUI-001/hermetic-contract-test-2026-07-22.md
evidence/runs/TASK-RKFUI-001/e0-preflight-2026-07-24.md
evidence/runs/TASK-RKFUI-001/identity-separation-preflight-2026-07-24.md
```

未来 run 位置：

```text
evidence/runs/TASK-RKFUI-002/
evidence/runs/TASK-RKFUI-003/
evidence/runs/TASK-RKFUI-004/
```

BlueTool 静态分析是 proposal 输入，记录在 change 根目录 `bluetool-analysis.md`；它不是
ArkDeck platform/realHardware 验收，且未执行任何真实设备命令。

`TASK-RKFUI-001` 的历史 run 如实为 `blocked`：contract 定向测试通过，但全量 suite 发现
package-boundary 测试表与已批准设计/Package 依赖不一致，所需测试文件不在任务 allowed
paths；signed Sandbox E0 又在 child launch 前因所选工具带 quarantine fail closed。
2026-07-24 r2 repin preflight 又发现 discovery/destructive identity 共享同一常量，现有
Allowed paths 无法在不改变 destructive pin 的前提下完成 clean repin；proposal r3 merge 前
implementation 保持 blocked。上述 run 均不构成 RockUSB direct-access PASS、真机支持或
后续 execute readiness。
