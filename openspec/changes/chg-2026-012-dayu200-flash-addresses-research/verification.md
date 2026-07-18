# CHG-2026-012 Verification Plan

> Status:planned
> Change:CHG-2026-012-dayu200-flash-addresses-research@r1
> Core baseline:CORE-2.0.0

本文件是 immutable verification plan;实际结果由 Task run/evidence 记录。零
设备/工具执行;evidence 中出现任何命令执行记录即整体 fail。

## Acceptance matrix

| Evidence ID | Method | Expected result | Status |
| --- | --- | --- | --- |
| ADDR-DAYU200-MAPPING-001 | document review | 五节齐备(寻址方式语义/地址映射表/对账方法/只读观察草案/S2-S3 分级);映射表零自行推导、任何数值行均有 TASK-PD-001 解码 evidence 锚点,PD-001 未覆盖分区显式 unknown;S3/推断结论标【待真机确证】;显式不解除 gap、无兼容性声明 | pending |
| ADDR-DAYU200-OBSERVATION-PLAN-001 | document review | 只读观察草案逐条标只读与前提;凡模式切换/写设备候选标【第二阶段·写设备·RECOVERY 先行】;声明执行与白名单扩展均属后续 change,不构成执行授权 | pending |

## Gate

- doc-only 硬边界:本 change evidence 不得含命令执行;网络仅文档检索。
- 地址权威性:映射数值唯一来源=TASK-PD-001 解码 evidence(合入 main 版本);
  不从镜像成员字节推导地址(CHG-2026-003 非目标延续)。
- 不解除 `GAP-DAYU200-FLASH-ADDRESSES`、不改变 DEC-002 状态;写设备观察受
  RECOVERY 先行硬序约束(route-b-plan.md 全局规则)。
- 第二阶段(若必要)写设备验证另行独立立项/approve,仅在
  `GAP-DAYU200-RECOVERY-PATH` 关闭后;本文档是其输入,非其授权。
