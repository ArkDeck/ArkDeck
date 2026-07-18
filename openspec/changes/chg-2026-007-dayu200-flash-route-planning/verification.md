# CHG-2026-007 Verification Plan

> Status:passed;maintainer confirmation 见文末,candidate `verified` 在
> verification closure PR 合入后生效
> Change:CHG-2026-007-dayu200-flash-route-planning@r1
> Core baseline:CORE-2.0.0

本文件是 immutable verification plan;实际结果由 Task run/evidence 记录
(acceptance matrix 的 Status 列保持起草期 `pending` 不改写,四项实际二值结论
以 `evidence/runs/TASK-RB-001/run.md` 为准:全部 PASS)。本
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

## Maintainer confirmation(2026-07-18)

- Approval:PR #64,维护者 `lvye` merge,merge commit `36df85e`;readiness:
  PR #65,merge commit `bc4967e`。
- Deliverable + evidence:PR #66,维护者 `lvye` merge,merge commit `7c68710`。
- Task `ready→done`:PR #67,维护者 `lvye` merge,merge commit `c98d2b6`。
- Confirmation scope:`TASK-RB-001` 交付物(四 gap × 五要素 route-b-plan.md,
  含 RECOVERY-PATH 先行硬序)、四个 `TEST-PLAN-DAYU200-*` 的 run.md 二值结论
  (全部 PASS,document review)、plan-only gate 自证(零命令执行),以及计划
  不解除 gap/不改变 DEC-002/非执行授权的边界。
- 本 confirmation 满足 verified gate;不构成 archive。本 change 暂不归档:
  route-b-plan.md 仍是 Route-B 在途步骤的活跃硬序依据,archive 留待 Route-B
  收官后独立 PR 裁量(先例 #21/#49)。
