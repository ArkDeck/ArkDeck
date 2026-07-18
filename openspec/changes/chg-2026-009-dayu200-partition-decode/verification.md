# CHG-2026-009 Verification Plan

> Status:planned
> Change:CHG-2026-009-dayu200-partition-decode@r1
> Core baseline:CORE-2.0.0

本文件是 immutable verification plan;实际结果由 Task run/evidence 记录。零
设备/网络/subprocess;identity gate 不命中即整体拒绝。

## Acceptance matrix

| Evidence ID | Method | Expected result | Status |
| --- | --- | --- | --- |
| DECODE-DAYU200-PARTITION-001 | identity-gated streaming decode + branch-complete tests | pinned identity 强制;流式读 parameter.txt 不解包不读其他成员;封闭文法未知形态显式 fail;evidence 含映射表/S2 引用/hash 引用,无原文无 locator,标注仅对 pinned 镜像成立;静态审计零 subprocess/网络/设备 | pending |
| DECODE-DAYU200-RECONCILE-001 | mapping ↔ 17 成员清单对账 | 每成员归位或显式孤儿;每无成员分区显式列出;non-authoritative,不推导烧写地址,零烧写/兼容/支持声明 | pending |

## Gate

- 只读硬边界:任何 subprocess/网络/设备访问或磁盘解包出现即整体 fail。
- 解码失败是合法结果:未知文法如实记录,不得猜测凑表。
- 本 evidence 是 DEC-002 输入的候选,登记须另行 governance PR(先例 #52);
  gap 状态不由本 change 改变。
