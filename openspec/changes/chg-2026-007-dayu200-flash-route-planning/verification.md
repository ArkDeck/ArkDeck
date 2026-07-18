# CHG-2026-007 Verification Plan

> Status:planned
> Change:CHG-2026-007-dayu200-flash-route-planning@r1
> Core baseline:CORE-2.0.0

本文件是 immutable verification plan;实际结果由 Task run/evidence 记录。本
change plan-only:任何设备/工具命令的出现即为越界失败。

## Acceptance matrix

| Evidence ID | Method | Expected result | Status |
| --- | --- | --- | --- |
| PLAN-DAYU200-PARTITION-001 | document review | 分区表语义 gap 计划节五要素齐备(事实定义/来源分级/获取方法含读写分级/安全边界/evidence 口径);显式"不构成执行授权" | pending |
| PLAN-DAYU200-ADDRESSES-001 | document review | 烧写地址 gap 计划节五要素齐备;本 change 内不从成员字节推导地址;显式"不构成执行授权" | pending |
| PLAN-DAYU200-PROTOCOL-001 | document review | flashd/rockusb/transport 协议 gap 计划节五要素齐备;候选观察逐条标注只读/写设备;显式"不构成执行授权" | pending |
| PLAN-DAYU200-RECOVERY-001 | document review | 恢复路径 gap 计划节五要素齐备;计划声明硬顺序:RECOVERY-PATH 先于任何 flash 类观察关闭,期间禁止写设备 | pending |

## Gate

- plan-only 硬边界:本 change 的 evidence 不得含任何命令执行记录;出现即整体
  fail 并须 run.md 记录偏差。
- 计划文档不改变 DEC-002 状态、不解除任何 gap、不触碰 hardware matrix。
- 后续执行型 change 必须逐个独立立项/approve;本计划不得被解释为其执行授权。
