# Tasks — CHG-2026-012 DAYU200 flash addresses research(doc-only)

> V2 治理:本文件是任务的唯一事实源;任务状态变更仅在维护者 review/merge 后
> 生效。本 change 零设备操作、零工具执行;网络仅用于文档检索。r2 只修正
> CHG-2026-009@r4 拆分后的 upstream evidence owner,不执行任务或生成 evidence。

## TASK-FA-001 — 烧写地址映射事实清单(文档研究)

- Status:done(TASK-FA-001 research + evidence PR #167 已由维护者 review/merge 合入
  `main` squash commit `f9b74cc`;本独立状态 PR 依据下列 completion evidence 起草
  `ready→done`,仅在维护者 review/merge 后生效。本状态只关闭烧写地址映射事实清单的
  document-review evidence,non-authoritative——不解除 `GAP-DAYU200-FLASH-ADDRESSES`、
  不改变 DEC-002 状态、无兼容性/支持声明、非执行授权)
- Completion evidence:`evidence/flash-address-facts.md`
  (SHA-256 `e1c09d169264ce1f774f306bc275435768bfbd37448574bc6f280900ed29c2c2`)与
  `evidence/runs/TASK-FA-001/run.md`
  (SHA-256 `75fef5ffd185c5854bbee20572166d2983c0ce99ed4be3289066986993d80c82`):
  五节齐备;两个 Test ID document review PASS——`TEST-ADDR-DAYU200-MAPPING-001`
  (§2 全 15 数值行锚定 TASK-PD-002 `partition-mapping.json`,字节列显式标 S2 ×512
  派生非 PD-002 数值,PD-002 未覆盖项全 unknown+【待真机确证】,零 alias/镜像字节
  推导)与 `TEST-ADDR-DAYU200-OBSERVATION-PLAN-001`(§4 逐条只读+前提,全部模式切换/
  写设备候选标【第二阶段·写设备·RECOVERY 先行】,零执行授权);doc-only(仅两
  markdown,零命令执行),check-sdd 0/0/111,敏感扫描零命中。状态 PR 复核
  (2026-07-20,当前 `main` `f9b74cc`):两文件 hash 与合入版逐字节一致——该复核只
  确认 evidence 在案,不构成新的验证结论。merge 本 PR 后:`GAP-DAYU200-FLASH-ADDRESSES`
  与 DEC-002 保持不变,本文档作为其后续决策的 grounded 输入;CHG-2026-013 演练检查单
  第 3 项(TASK-PD-002 mapping)已随 PD-002 done 满足。
- Readiness review(2026-07-20;doc-only,零设备/工具/采集 dispatch):
  - Change gate:satisfied。CHG-2026-012 approved(PR #89,`4455737`);r2 upstream
    evidence-owner 修正已合入,revision 标记三方一致 2/@r2;本 readiness 不修改两项
    `ADDR-DAYU200-*` AC/method/minimum evidence。
  - Dependency gate:satisfied——双前置与两项互补输入全部就位:
    - TASK-PD-002 `done`(evidence PR #164 squash `6f26ca3`、状态 PR #165
      `e20a832`),绑定 TASK-PD-001 implementation identity(r4 #124 `110071c1`+
      r5 #160 `33aff46`,done #125/#161);
    - **数值行唯一权威锚点**(执行时逐行引用,零自行推导/零镜像字节推导):
      `evidence/runs/TASK-PD-002/platform-2026-07-20-r5/partition-mapping.json`
      SHA-256 `965e3bf3bd926c76a646a1bc02ce1f3f4ba855b4e09a7e61b48872195c131347`、
      `member-reconciliation.json`
      `55c3515667ff6b1bd8cc922721b0c46a649eee9203a6f8a40c23397765b2d4ad`
      (仅对 pinned archive identity `fc7637f3…5280` 成立,non-authoritative 边界
      随锚点继承);
    - CHG-2026-007 TASK-RB-001 done(route-b-plan §④b 只读阶段)与 CHG-2026-011
      TASK-FP-001 done(archived `flash-protocol-facts.md` SHA-256
      `a012c16a5011918a967e1fa21806afb20613e3dfd54078d5beebc599abb000ba`,通道/
      工具事实互补输入,只读引用)。
  - Scope gate:satisfied on merge。执行范围严格等于 Allowed paths(本 change
    `evidence/**` 两文件 + 本 `tasks.md` 状态行);Forbidden paths 不变;PD-002
    evidence 只读引用不改写;网络仅用于官方文档检索(rkdeveloptool/upgrade_tool/
    RKDevTool/parameter.txt/GPT 语义),CHG-011 documentReview 先例。
  - Verification boundary:执行须满足 acceptance-cases 两个 Test ID 的全部硬约束
    ——五节齐备、映射表每一数值行锚定上述 pinned PD-002 evidence、PD-002 未覆盖
    分区显式 unknown、S2/S3 分级且 S3/推断结论标 unconfirmed、观察面草案全部
    写设备候选标【第二阶段·RECOVERY 先行】且不授权任何执行;缺任一项不得 done。
  - Review boundary:本 readiness 只翻转状态;facts 文档内容、S2/S3 分级与观察面
    草案在 research implementation PR 由维护者 review;`ready→done` 另用独立状态
    PR。
- Requirements/AC:`ADDR-DAYU200-MAPPING-001`、
  `ADDR-DAYU200-OBSERVATION-PLAN-001`(见 acceptance-cases.yaml)
- Depends on:CHG-2026-007 TASK-RB-001 done(已满足,计划第④b步只读阶段);
  CHG-2026-011 TASK-FP-001 done(已满足,通道/工具事实互补输入);
  **TASK-PD-002 `done` 状态、其 fresh evidence PR 与绑定的 TASK-PD-001 implementation
  identity 全部合入 main(未满足)**。TASK-PD-001 headless contract evidence 不能替代该依赖。
- Allowed paths:本 change `evidence/**`(flash-address-facts.md、run.md)、本
  change `tasks.md`(仅本任务状态)
- Forbidden paths:产品代码、`scripts/**`(含 `scripts/partition_decode/**`,
  TASK-PD-002 evidence 只读引用不改写)、`Packages/**`、`openspec/specs/**`、
  `openspec/contracts/**`、`openspec/planning/**`、hardware matrix、其他
  change/task evidence
- Risk:low(纯文档;风险=自行推导地址混入 evidence、S3 被当事实、只读观察
  草案被误当执行授权——由 TASK-PD-002 fresh mapping 逐行锚定硬约束与显式边界条款覆盖)
- Hardware required:no
- Deliverables:`evidence/flash-address-facts.md`(五节齐备)+ run.md(两个
  Test ID 文档评审结论、来源清单、偏差)
- Verification:按 acceptance-cases.yaml 两个 Test ID 以文档评审执行;缺任一
  节、映射表任一数值行无 TASK-PD-002 fresh platform evidence 锚点、任一 S3/推断结论
  未标注、任一
  写设备候选未标 RECOVERY 先行,即不得标记 `done`。
