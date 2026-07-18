# Tasks — CHG-2026-010 DAYU200 recovery playbook(doc-only)

> V2 治理:本文件是任务的唯一事实源;任务状态变更仅在维护者 review/merge 后
> 生效。本 change 零设备操作、零工具执行;网络仅用于文档检索。

## TASK-RP-001 — 恢复/救砖预案文档

- Status:blocked(等待本 change 经 approval-only PR 置为 approved;approve 后
  经独立 readiness/status PR 转 ready)
- Requirements/AC:`RECOVERY-DAYU200-PLAYBOOK-001`、
  `RECOVERY-DAYU200-READINESS-001`(见 acceptance-cases.yaml)
- Depends on:CHG-2026-007 TASK-RB-001 done(已满足,计划第②步);不依赖
  TASK-PD-001(与分区解码并行,无路径交集)
- Allowed paths:本 change `evidence/**`(recovery-playbook.md、run.md)、本
  change `tasks.md`(仅本任务状态)
- Forbidden paths:产品代码、`scripts/**`、`Packages/**`、`openspec/specs/**`、
  `openspec/contracts/**`、`openspec/planning/**`、hardware matrix、其他
  change/task evidence
- Risk:low(纯文档;风险=预案被误当执行授权或 S3 线索被当事实——由显式
  边界与 S3 标注条款覆盖)
- Hardware required:no
- Deliverables:`evidence/recovery-playbook.md`(七节齐备)+ run.md(两个
  Test ID 文档评审结论、来源清单、偏差)
- Verification:按 acceptance-cases.yaml 两个 Test ID 以文档评审执行;缺任一
  节或任一 S3 依赖未标注即不得标记 `done`。
