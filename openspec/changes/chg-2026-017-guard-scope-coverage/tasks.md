# Tasks — CHG-2026-017 check_sdd scope 覆盖校验

> V2 治理:本文件是任务的唯一事实源;任务状态变更仅在维护者 review/merge 后生效。
> 本 change 零设备、零 spec/contract/product 变更;仅增强 guard 工具与新增测试。

## TASK-GUARD-001 — check_sdd per-change scope 覆盖校验 + 测试

- Status:blocked(双前置:①本 change 经 approval-only PR 置为 `approved`(未满足);
  ②独立 readiness PR 转 `ready`(未满足)。两前置齐备后才可实现)
- Requirements/AC:`GUARD-SCOPE-COVERAGE-001`(见 acceptance-cases.yaml)
- Depends on:backlog 已登记本增强(`openspec/planning/backlog.md`);深度 review
  AC-JOB-003/004 断链发现与追溯修复 PR #138(已合入 main,作为现状基线依据)。
- Allowed paths:
  - `scripts/check_sdd.py`(新增 scope 覆盖校验函数,汇入主流程 err 计数)
  - `scripts/test_check_sdd.py`(新建;合成 fixture + 真实基线断言)
  - `openspec/changes/chg-2026-017-guard-scope-coverage/evidence/**`
  - 本 `tasks.md`(仅本任务状态与 completion evidence)
- Forbidden paths:`Packages/**`、`ArkDeckApp/**`、`openspec/specs/**`、
  `openspec/contracts/**`、`openspec/baselines/**`、其他 change/task evidence、
  任何既有 change 的 scope.yaml/tasks.md(不为通过校验而改数据);设备/网络/product。
- Risk:low(离线 stdlib+PyYAML guard 增强;唯一风险=false positive/negative,由
  design §4 正反 fixture + current-main 基线覆盖)。
- Hardware required:no。
- Required environment:`<ARKDECK_ROOT>/.venv-sdd/bin/python`(guard 既有环境);
  实现/测试仅用 stdlib+PyYAML 与本地临时目录。
- Deliverables:`check_sdd.py` scope 覆盖校验 + `test_check_sdd.py` + `run.md`
  (base OID、实现前 current-main 四 scope.yaml change 零 scope-coverage err 基线、
  测试计数、check-sdd 增强后 0/0/111、偏差)。
- Verification:
  - `GUARD-SCOPE-COVERAGE-001` 二值——`test_check_sdd.py` 正例/反例(核心断链具名
    err)/解析边界/跳过/真实基线全 PASS;
  - 实现前后 `scripts/check-sdd.sh` 均 `0 errors / 0 warnings / 111 acceptance IDs`
    (增强不引入 false positive);
  - `<ARKDECK_PYTHON> scripts/test_check_sdd.py`;`git diff --check`;
  - 反例证明:临时把某 scope.yaml 的一个 acceptance AC 从对应 task 认领面移除(仅
    fixture,不改真实数据)→ guard 具名 err;复原后消失。
- Evidence gate:上述全 PASS 且 current-main 基线不回归后,另起 status PR 起草 `done`。
- PR boundary:一个 implementation + evidence PR;`blocked→ready`、`ready→done` 各用
  独立 PR。
