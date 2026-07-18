# Tasks — CHG-2026-008 ui-dump HiDumper wrapper integration

> V2 治理:本文件是任务的唯一事实源;任务状态变更仅在维护者 review/merge 后
> 生效。全部真机采集由人类维护者执行,Agent 不执行真实 `hdc`。

## TASK-UD-001 — 固定 HiDumper 调用包装 + golden 登记 + 对抗测试

- Status:blocked(双前置:本 change 经 approval-only PR approved;
  `TASK-M1-006` done 合入 main——`Packages/**` 当前由其会话独占。解除须独立
  readiness/status PR 复核两前置)
- Requirements/AC:`INT-UD-WRAPPER-001`、`INT-UD-GOLDEN-001`(见
  acceptance-cases.yaml)
- Depends on:`TASK-M1-006`(CHG-2026-002)、M0B 事实
  (EVD-M0B-DAYU200-20260718-001,已满足)
- Allowed paths:`Packages/ArkDeckKit/**`(ui-dump 包装与测试/golden 资源)、
  integration profile/lock 对应文件、本 change `evidence/**`、本 change
  `tasks.md`(仅本任务状态)
- Forbidden paths:`openspec/specs/**`(如需 spec 措辞修订另行 revision)、
  `openspec/contracts/**`、hardware matrix、其他 change/task evidence
- Risk:medium(golden 采集需真机在场,人类执行只读白名单命令;代码变更以
  fake 对抗测试覆盖 exit-0 陷阱)
- Hardware required:golden 采集 yes(人类操作);代码/测试 no
- Deliverables:包装 argv 形态与标记判定实现;脱敏 golden fixture(先钉
  `.gitattributes`);对抗测试;run.md
- Verification:按 acceptance-cases.yaml 两个 Test ID;缺任一项不得标记
  `done`;不构成兼容性/支持声明。
