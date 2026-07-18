# Tasks — CHG-2026-007 DAYU200 flash route planning(plan-only)

> V2 治理:本文件是任务的唯一事实源;任务状态变更仅在维护者 review/merge 后
> 生效。本 change 全程 plan-only:零设备命令、零工具执行、零 Provider 代码。

## TASK-RB-001 — Route-B/Integration 四 gap 关闭路径研究计划

- Status:blocked(等待本 change 经 approval-only PR 置为 approved;approve 后
  经独立 readiness/status PR 转 ready)
- Requirements/AC:`PLAN-DAYU200-PARTITION-001`、`PLAN-DAYU200-ADDRESSES-001`、
  `PLAN-DAYU200-PROTOCOL-001`、`PLAN-DAYU200-RECOVERY-001`(见
  acceptance-cases.yaml)
- Depends on:DEC-001 decided(已满足)、CHG-2026-003 archived gaps(已满足)、
  M0B observed 事实(已满足,EVD-M0B-DAYU200-20260718-001)
- Allowed paths:本 change `evidence/**`(route-b-plan.md 及其修订)、本 change
  `tasks.md`(仅本任务状态)
- Forbidden paths:产品代码、`scripts/**`、`openspec/specs/**`、
  `openspec/contracts/**`、`openspec/verification/hardware-matrix.md`、其他
  change/task evidence
- Risk:low(纯文档;风险在于计划内容被误读为执行授权——由验收口径的显式
  否认条款覆盖)
- Hardware required:no
- Deliverables:`evidence/route-b-plan.md`(四 gap × 五要素;依赖序声明
  RECOVERY-PATH 先行;每节含"本计划不构成执行授权"边界)
- Verification:按 acceptance-cases.yaml 四个 Test ID 以文档评审执行;缺任一
  要素不得标记 `done`。
