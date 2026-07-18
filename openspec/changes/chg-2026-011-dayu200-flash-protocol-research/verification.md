# CHG-2026-011 Verification Plan

> Status:planned
> Change:CHG-2026-011-dayu200-flash-protocol-research@r1
> Core baseline:CORE-2.0.0

本文件是 immutable verification plan;实际结果由 Task run/evidence 记录。零
设备/工具执行;evidence 中出现任何命令执行记录即整体 fail。

## Acceptance matrix

| Evidence ID | Method | Expected result | Status |
| --- | --- | --- | --- |
| PROTOCOL-DAYU200-CHANNELS-001 | document review | 五节齐备(通道枚举/进入方式+USB 识别、TCP-UART out of scope/工具映射+macOS 可用性/只读观察草案/S2-S3 分级);S3 结论标【待真机确证】;显式不解除 gap、无兼容性声明 | pending |
| PROTOCOL-DAYU200-OBSERVATION-PLAN-001 | document review | 只读观察草案逐条标只读;凡模式切换/写设备候选标【第二阶段·写设备·RECOVERY 先行】;声明执行属后续 change,不构成执行授权 | pending |

## Gate

- doc-only 硬边界:本 change evidence 不得含命令执行;网络仅文档检索。
- 不解除 `GAP-DAYU200-FLASH-PROTOCOL`、不改变 DEC-002 状态;写设备观察受
  RECOVERY 先行硬序约束(route-b-plan.md 全局规则)。
- 第二阶段真机确认另行独立立项/approve;本文档是其输入,非其授权。
