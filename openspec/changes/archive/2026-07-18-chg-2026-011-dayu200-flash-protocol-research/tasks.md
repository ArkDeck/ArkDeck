# Tasks — CHG-2026-011 DAYU200 flash protocol research(doc-only)

> V2 治理:本文件是任务的唯一事实源;任务状态变更仅在维护者 review/merge 后
> 生效。本 change 零设备操作、零工具执行;网络仅用于文档检索。

## TASK-FP-001 — 烧写协议事实清单(文档研究)

- Status:done(交付物经 PR #80 合入 main `67bfa01`,2026-07-18;两个
  PROTOCOL-* Test ID 均以 document review 判 PASS(见 evidence/runs/
  TASK-FP-001/run.md);doc-only gate 自证:#80 仅新增两个 markdown,零命令
  执行。本翻转仅在维护者 review/merge 本状态 PR 后生效。完成不解除
  `GAP-DAYU200-FLASH-PROTOCOL`、不构成兼容性/支持声明、不构成任何执行授权:
  §4 只读观察面为设计草案,其执行须独立立项;写设备候选受 RECOVERY 先行
  硬序约束;DEC-002 保持 open)
- Requirements/AC:`PROTOCOL-DAYU200-CHANNELS-001`、
  `PROTOCOL-DAYU200-OBSERVATION-PLAN-001`(见 acceptance-cases.yaml)
- Depends on:CHG-2026-007 TASK-RB-001 done(已满足,计划第④步只读阶段);
  不依赖 TASK-PD-001(协议不依赖分区偏移)
- Allowed paths:本 change `evidence/**`(flash-protocol-facts.md、run.md)、本
  change `tasks.md`(仅本任务状态)
- Forbidden paths:产品代码、`scripts/**`、`Packages/**`、`openspec/specs/**`、
  `openspec/contracts/**`、`openspec/planning/**`、hardware matrix、其他
  change/task evidence
- Risk:low(纯文档;风险=只读观察草案被误当执行授权、S3 被当事实——由显式
  边界与 S3 标注条款覆盖)
- Hardware required:no
- Deliverables:`evidence/flash-protocol-facts.md`(五节齐备)+ run.md(两个
  Test ID 文档评审结论、来源清单、偏差)
- Verification:按 acceptance-cases.yaml 两个 Test ID 以文档评审执行;缺任一
  节或任一 S3 依赖未标注、任一写设备候选未标 RECOVERY 先行,即不得标记 `done`。
