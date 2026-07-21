# CHG-2026-018 Tasks

## TASK-CA-001 — conformance manifest 条件化适用性修订与 CORE-2.1.0 baseline 起草

- Status:blocked(双前置:① 本 change 经独立 approval-only PR 批准;② 独立 readiness PR
  确认执行时 pins。二者均须维护者 review/merge 后生效;本 propose PR 不构成实现授权)
- Objective:按 design.md normative 草案对 `openspec/verification/core-conformance.yaml`
  做一次 additive 修订(suite 升 `CORE-CONFORMANCE-2.1.0`,新增 `integration_conditional`
  机制并仅登记 `AC-HDC-006-01`/`AC-HDC-009-01` 两条,`shared_inputs` 补记 0.3.0/0.4.0
  integration 输入),并起草 `openspec/baselines/CORE-2.1.0.yaml`(ratification 由 archive
  PR 构成)。
- Requirements/AC:不修改任何 Core Requirement/Scenario;本 change 交付面由 change-local
  `CA-HDC-APPLICABILITY-001`、`CA-HDC-APPLICABILITY-002` 验收(不计入 canonical 111)。
- Depends on:
  - CHG-2026-015/TASK-I15-001(done;registry 与 unsupported provenance 是排除条件的唯一
    事实源,本任务只读引用)
  - TASK-M1-006 closeout(#191/#192;addendum 23 是缺口 ②③ 的认定载体,本任务不改其
    evidence)
- In scope:core-conformance.yaml 的 design.md 所列 delta;CORE-2.1.0 baseline 起草;本
  change evidence run 记录。
- Out of scope:specs/**、canonical acceptance-cases.yaml/acceptance-index.txt、
  integrations/**、platforms/**、Packages/**、ArkDeckApp/**、其他 change 的任何文件;
  TASK-M1-006 状态与 addendum 23 缺口 ①;CHG-2026-002 账本同步(另行 governance ledger
  PR,先例 #193)。
- Allowed paths:
  - `openspec/verification/core-conformance.yaml`(仅 design.md 所列 delta)
  - `openspec/baselines/CORE-2.1.0.yaml`(新建)
  - `openspec/changes/chg-2026-018-hdc-acceptance-applicability/evidence/**`
  - `openspec/changes/chg-2026-018-hdc-acceptance-applicability/tasks.md`(仅本任务状态与
    completion evidence)
- Forbidden paths:`openspec/specs/**`、`openspec/verification/acceptance-cases.yaml`、
  `openspec/verification/acceptance-index.txt`、`openspec/integrations/**`、
  `openspec/platforms/**`、`openspec/contracts/**`、`Packages/**`、`ArkDeckApp*/**`,以及
  上述清单以外的一切。
- Risk:medium(Core conformance 语义面;零代码、零 spec 原文变更;排除机制 fail-closed,
  错误方向是「多排除」——由 CA-002 的逐字对照与维护者 review 拦截)
- Hardware required:no
- Required environment:仓库 + `scripts/check-sdd.sh` 可运行;无设备、无网络、无签名要求。
- Deliverables:core-conformance.yaml@2.1.0(delta 与 design.md 草案逐项对应);
  CORE-2.1.0.yaml baseline 草案;evidence run(delta 逐项核对、111 计数不变证明、
  check-sdd 结果、registry provenance 逐字引用)。
- Verification:`TEST-CA-HDC-APPLICABILITY-001`(documentReview)与
  `TEST-CA-HDC-APPLICABILITY-002`(documentReview + guard),见本 change
  verification.md/acceptance-cases.yaml。Commands:`./scripts/check-sdd.sh`;
  `git diff --check`;`git diff --stat`(改动面仅 allowed paths)。
- Evidence gate:在 `evidence/runs/TASK-CA-001/run.md` 记录 base revision、两个 Test ID 的
  二值结论、delta 与 design 草案的逐项对照、acceptance index/cases 111 计数与全部条目
  未变的证明、registry unsupported reason 逐字引用及其 provenance PR 链
  (#141/#155/#156/#159/#163)。缺任一项不得标 `done`;`done` 翻转须独立状态 PR;
  ratification 另由 archive PR 构成。
