# CHG-2026-010 Verification Plan

> Status:planned
> Change:CHG-2026-010-dayu200-recovery-playbook@r1
> Core baseline:CORE-2.0.0

本文件是 immutable verification plan;实际结果由 Task run/evidence 记录。零
设备/工具执行;evidence 中出现任何命令执行记录即整体 fail。

## Acceptance matrix

| Evidence ID | Method | Expected result | Status |
| --- | --- | --- | --- |
| RECOVERY-DAYU200-PLAYBOOK-001 | document review | 七节齐备(进入方式+模式判别/工具+macOS 可用性/物料+hash 对应/步骤序列+前提判别点/风险+中止准则/演练前置检查单/S2-S3 分级引用);S3 依赖逐步标注"待演练确证";显式"不关闭 gap、不构成执行授权" | pending |
| RECOVERY-DAYU200-READINESS-001 | document review | 检查单逐项二值可查(物料/工具/维护者风险明示/时间窗/中止预案);声明演练 change 必须原文引用本检查单作前置 gate | pending |

## Gate

- doc-only 硬边界:本 change evidence 不得含命令执行;网络仅文档检索,不下载
  执行二进制。
- 预案不关闭 `GAP-DAYU200-RECOVERY-PATH`(关闭需第③步真机演练成功);不改变
  DEC-002 状态。
- 演练 change 独立立项/approve;本预案+检查单是其前置 gate,不是其授权。
