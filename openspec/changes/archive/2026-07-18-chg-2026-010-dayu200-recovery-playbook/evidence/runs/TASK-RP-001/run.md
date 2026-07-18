# TASK-RP-001 run — DAYU200 恢复/救砖预案(doc-only)

- Change:CHG-2026-010-dayu200-recovery-playbook / Task:TASK-RP-001
- 执行日期:2026-07-18;执行形态:纯文档研究(web 检索 S2/S3 来源 + 引用
  archived CHG-2026-003 member-inventory.json);**零设备操作、零工具执行、
  零二进制下载**(doc-only gate 自证:本 PR 仅新增两个 markdown 文件)
- 交付物:`../../recovery-playbook.md`

## 二值结论(per acceptance-cases.yaml,方法=document review)

| Test ID | 结论 | 依据 |
| --- | --- | --- |
| TEST-RECOVERY-DAYU200-PLAYBOOK-001 | PASS | 七节齐备(§1 进入方式+模式判别、§2 工具+macOS 可用性结论、§3 物料+pinned 成员 hash 对应、§4 步骤序列+逐步前提判别点、§5 风险+中止准则、§6 前置检查单、§7 S2/S3 分级引用);S3 依赖步骤逐条标注【待演练确证】;首段显式"不关闭 gap、不构成执行授权" |
| TEST-RECOVERY-DAYU200-READINESS-001 | PASS | §6 检查单 7 项逐项二值可查(物料 hash/工具构建/PD-001 evidence/维护者风险书面确认/时间窗/中止预案/备选路径),并声明演练 change 须原文引用作前置 gate |

## 偏差 / 遗留

- DAYU200 专属细节(按键点位/时序、USB PID、config.cfg 写序、chip_*/updater
  是否必写)仅有 S3 或推断来源,已全部标注【待演练确证】——这是 doc-only
  阶段的固有边界,非执行偏差。
- 步骤 4 的分区偏移显式依赖 TASK-PD-001 解码 evidence(并行进行中),检查单
  第 3 项将其设为演练前置;两任务无路径交集。
- `GAP-DAYU200-RECOVERY-PATH` 保持 unknown;DEC-002 保持 open。

## Boundary

doc-only;不构成执行授权、支持声明或兼容性结论;不触碰 matrix/specs/
contracts;演练(第③步)须独立立项、approve,并以 §6 检查单+维护者风险明示
确认为前置 gate;`done` 翻转由独立状态 PR 执行。
