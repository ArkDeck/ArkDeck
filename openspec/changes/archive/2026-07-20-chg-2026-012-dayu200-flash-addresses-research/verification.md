# CHG-2026-012 Verification Plan

> Status:passed;maintainer confirmation 见 proposal.md Verification closure(2026-07-20)
> Change:CHG-2026-012-dayu200-flash-addresses-research@r2
> Core baseline:CORE-2.0.0

本文件按 change revision 管理;实际结果由 Task run/evidence 记录。r2 只把 CHG-009@r4
拆分后的 mapping evidence owner 从 TASK-PD-001 对齐到 TASK-PD-002，不改变 method、
minimum evidence、五节内容或 pass/fail 标准。零设备/工具执行;evidence 中出现任何命令
执行记录即整体 fail。

## Acceptance matrix

| Evidence ID | Method | Expected result | Status |
| --- | --- | --- | --- |
| ADDR-DAYU200-MAPPING-001 | document review | 五节齐备(寻址方式语义/地址映射表/对账方法/只读观察草案/S2-S3 分级);映射表零自行推导、任何数值行均有 TASK-PD-002 同一次 fresh platform mapping evidence 锚点,PD-002 未覆盖分区显式 unknown;S3/推断结论标【待真机确证】;显式不解除 gap、无兼容性声明 | passed(TASK-FA-001 done,PR #167;`evidence/flash-address-facts.md` §2 15 行锚定 PD-002) |
| ADDR-DAYU200-OBSERVATION-PLAN-001 | document review | 只读观察草案逐条标只读与前提;凡模式切换/写设备候选标【第二阶段·写设备·RECOVERY 先行】;声明执行与白名单扩展均属后续 change,不构成执行授权 | passed(TASK-FA-001 done,PR #167;`evidence/flash-address-facts.md` §4 全写设备候选标第二阶段 RECOVERY 先行) |

> Status update(2026-07-20,随 TASK-FA-001 `ready→done` 独立状态 PR 合入):两项
> `ADDR-DAYU200-*` 依 TASK-FA-001 merged `done`(research/evidence PR #167 squash
> `f9b74cc`,document review PASS)翻转 `passed`。本更新只同步账本,不构成新的验证
> 结论,不解除 `GAP-DAYU200-FLASH-ADDRESSES`、不改变 DEC-002 或 change 级
> `Status:planned`;change 级 verify/archive 另行独立 PR(先例 #48/#49)。

## Gate

- doc-only 硬边界:本 change evidence 不得含命令执行;网络仅文档检索。
- 地址权威性:映射数值唯一来源=TASK-PD-002 同一次 fresh signed-broker platform run 的
  mapping evidence(TASK-PD-002 `done`、evidence 与绑定的 TASK-PD-001 implementation 均为
  合入 main 版本);TASK-PD-001 headless contract receipt 不能作为数值锚点;
  不从镜像成员字节推导地址(CHG-2026-003 非目标延续)。
- 不解除 `GAP-DAYU200-FLASH-ADDRESSES`、不改变 DEC-002 状态;写设备观察受
  RECOVERY 先行硬序约束(route-b-plan.md 全局规则)。
- 第二阶段(若必要)写设备验证另行独立立项/approve,仅在
  `GAP-DAYU200-RECOVERY-PATH` 关闭后;本文档是其输入,非其授权。
