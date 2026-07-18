# Tasks — CHG-2026-009 DAYU200 partition decode(read-only)

> V2 治理:本文件是任务的唯一事实源;任务状态变更仅在维护者 review/merge 后
> 生效。本 change 零设备操作、零网络、零 subprocess。

## TASK-PD-001 — parameter.txt 只读解码器 + 映射/对账 evidence

- Status:blocked(2026-07-18 execution review:accepted AC 要求流式定位
  `parameter.txt` 且“不读取其他成员内容”,但 pinned 输入是单一 gzip/DEFLATE
  tar stream，目标位于第 8 个成员；定位其 header 必须消费前 7 个成员字节。
  当前 candidate 如实记录读后丢弃 178168731 bytes，故 AC 不通过。若批准意图
  是“允许流式解压/丢弃但不解析、不保留、不落盘”,须独立 governance PR
  澄清/修订 AC。另因 CLI 接受 path，`lstat→open` 无法排除替换为 device 后先
  open、再由 fstat 拒绝的竞态，故也不能静态证明 absolute zero device access；
  需治理定义可信 fd/OS sandbox/threat model 后重新 ready。本 blocked 起草仅在
  维护者 review/merge 后生效)
- Requirements/AC:`DECODE-DAYU200-PARTITION-001`、`DECODE-DAYU200-RECONCILE-001`
  (见 acceptance-cases.yaml)
- Depends on:CHG-2026-007 TASK-RB-001 done(已满足,计划第①步)、
  CHG-2026-003 archived(pinned identity 与成员清单,已满足)
- Allowed paths:`scripts/partition_decode/**`、本 change `evidence/**`、本
  change `tasks.md`(仅本任务状态)
- Forbidden paths:产品代码、`Packages/**`、`openspec/specs/**`、
  `openspec/contracts/**`、`openspec/planning/**`、hardware matrix、其他
  change/task evidence
- Risk:low(离线只读;风险=解码结论被误用为烧写依据——由 non-authoritative
  边界与"不推导地址"条款覆盖)
- Hardware required:no(需要本地 pinned 镜像文件在场,identity gate 校验)
- Deliverables:解码器 + 单元测试(文法正负分支、identity gate、静态审计);
  evidence(映射表/对账表/来源引用/hash 引用)+ run.md
- Verification:按 acceptance-cases.yaml 两个 Test ID;缺任一项不得标记
  `done`;结论仅对 pinned 镜像成立,不构成烧写依据或支持声明。
