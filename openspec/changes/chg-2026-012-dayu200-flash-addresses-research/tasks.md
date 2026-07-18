# Tasks — CHG-2026-012 DAYU200 flash addresses research(doc-only)

> V2 治理:本文件是任务的唯一事实源;任务状态变更仅在维护者 review/merge 后
> 生效。本 change 零设备操作、零工具执行;网络仅用于文档检索。

## TASK-FA-001 — 烧写地址映射事实清单(文档研究)

- Status:blocked(双前置:①本 change 经 approval-only PR 置为 approved;
  ②TASK-PD-001(CHG-2026-009)分区解码 evidence 合入 main——地址映射表的唯一
  权威来源。两前置齐备后经独立 readiness/status PR 转 ready)
- Requirements/AC:`ADDR-DAYU200-MAPPING-001`、
  `ADDR-DAYU200-OBSERVATION-PLAN-001`(见 acceptance-cases.yaml)
- Depends on:CHG-2026-007 TASK-RB-001 done(已满足,计划第④b步只读阶段);
  CHG-2026-011 TASK-FP-001 done(已满足,通道/工具事实互补输入);
  **TASK-PD-001 evidence 合入 main(未满足,另一会话执行中)**
- Allowed paths:本 change `evidence/**`(flash-address-facts.md、run.md)、本
  change `tasks.md`(仅本任务状态)
- Forbidden paths:产品代码、`scripts/**`(含 `scripts/partition_decode/**`,
  PD-001 evidence 只读引用不改写)、`Packages/**`、`openspec/specs/**`、
  `openspec/contracts/**`、`openspec/planning/**`、hardware matrix、其他
  change/task evidence
- Risk:low(纯文档;风险=自行推导地址混入 evidence、S3 被当事实、只读观察
  草案被误当执行授权——由 PD-001 逐行锚定硬约束与显式边界条款覆盖)
- Hardware required:no
- Deliverables:`evidence/flash-address-facts.md`(五节齐备)+ run.md(两个
  Test ID 文档评审结论、来源清单、偏差)
- Verification:按 acceptance-cases.yaml 两个 Test ID 以文档评审执行;缺任一
  节、映射表任一数值行无 PD-001 evidence 锚点、任一 S3/推断结论未标注、任一
  写设备候选未标 RECOVERY 先行,即不得标记 `done`。
