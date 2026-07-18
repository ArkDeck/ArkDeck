# Tasks — CHG-2026-013 DAYU200 rehearsal preparation(host-only)

> V2 治理:本文件是任务的唯一事实源;任务状态变更仅在维护者 review/merge 后
> 生效。本 change 零设备操作(执行期间 DAYU200 不得连接主机);host 侧命令
> 仅限 proposal「Execution boundary」封闭白名单。

## TASK-RR-001 — 演练准备:工具构建+物料复核+记录模板

- Status:ready(change 经 approval-only PR #91 approved;本 readiness PR 复核
  前置后转 ready,仅在维护者 review/merge 后生效——**须在 #91 之后 merge**。
  前置复核:TASK-RP-001 done(archived 预案 §6 为目标定义)、TASK-FP-001 done
  (版本约束事实来源)——均满足;不依赖 TASK-PD-001;与在途 M1-006/PD-001
  无路径交集;执行前提:全程 DAYU200 不在场,由操作者在执行时书面确认并记录
  于 run.md)
- Requirements/AC:`PREP-DAYU200-TOOLING-001`、`PREP-DAYU200-MATERIALS-001`
  (见 acceptance-cases.yaml)
- Depends on:CHG-2026-010 TASK-RP-001 done(已满足,archived 预案 §6 检查单
  为本任务的目标定义);CHG-2026-011 TASK-FP-001 done(已满足,工具版本约束
  事实来源);不依赖 TASK-PD-001(准备动作与分区语义零耦合)
- Allowed paths:本 change `evidence/**`(prep-record.md、
  rehearsal-record-template.md、runs/**)、本 change `tasks.md`(仅本任务
  状态);仓库外 host 路径(构建目录、物料目录)不入仓
- Forbidden paths:产品代码、`scripts/**`、`Packages/**`、`openspec/specs/**`、
  `openspec/contracts/**`、`openspec/planning/**`、hardware matrix、其他
  change/task evidence
- Risk:low-medium(host 工具构建与执行;设备不在场硬前提消除设备面风险;
  残余风险=白名单外命令混入、下载物来源失控——由封闭白名单+逐下载 hash 记录
  +evidence 逐命令记录覆盖)
- Hardware required:no(**且要求执行期间设备不在场**)
- Deliverables:`evidence/prep-record.md`(构建记录+版本串+无设备 `ld`
  byte-exact 输出+物料 hash 对照表)+ `evidence/rehearsal-record-template.md`
  + runs/TASK-RR-001/run.md(两个 Test ID 结论、逐命令记录、偏差)
- Verification:按 acceptance-cases.yaml 两个 Test ID 执行;任一白名单外命令、
  `ld` 输出出现设备枚举行、任一物料 hash 不一致未如实记录、版本串 <1.32 未
  如实记录,即不得标记 `done`。
