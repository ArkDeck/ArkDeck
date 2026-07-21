# Tasks — CHG-2026-017 check_sdd scope 覆盖校验

> V2 治理:本文件是任务的唯一事实源;任务状态变更仅在维护者 review/merge 后生效。
> 本 change 零设备、零 spec/contract/product 变更;仅增强 guard 工具与新增测试。

## TASK-GUARD-001 — check_sdd per-change scope 覆盖校验 + 测试

- Status:done(TASK-GUARD-001 implementation + evidence PR #187 已由维护者
  `lvye` approve/review 并合入 `main` squash commit
  `5c2079c996aea74e3fbef6a510a68f99477263f0`;本独立状态 PR 依据下列
  completion evidence 起草 `ready→done`,仅在维护者 review/merge 后生效。
  本状态只关闭 scope-coverage guard 交付,不构成 CHG-2026-017 `verified`
  或任何 product/platform/hardware/support/release 声明)
- Completion evidence:`evidence/runs/TASK-GUARD-001/run.md`(实现范围仅
  `scripts/check_sdd.py`、`scripts/test_check_sdd.py` 与本任务 run evidence;
  合入版 `main` `5c2079c996aea74e3fbef6a510a68f99477263f0` 独立复验为合成+真实
  baseline 7 tests/0 failures、guard 0 errors/0 warnings/111 acceptance IDs;四个
  scoped change 分别 scope=28/68/1/5 且 missing 全为 0。具名断链、标识符
  边界、干扰行、简写拒绝、无 scope 跳过与单向校验均有可复查断言;
  零设备/网络/destructive dispatch,零 spec/contract/baseline/product 变更)
- Readiness restoration review(2026-07-20;host-only/offline,零设备、零网络):
  - Approval/grammar gate:satisfied。CHG-2026-017 r2 精确 acceptance-ID grammar
    已经 PR #184 由维护者合入 main `d568800`。
  - Traceability gate:satisfied。PR #185 已由维护者合入 main
    `32ab471`;r2 精确基线复跑结果为 M0A scope=28/missing=0、
    M1 scope=68/missing=0、CHG-005 scope=1/missing=0、M0B scope=5/missing=0。
    复核记录见本 change 的
    `evidence/runs/TASK-GUARD-001/traceability-remediation-2026-07-20.md`。
  - Contract/verification gate:satisfied。r2 已固定不透明 ID 动态精确匹配、
    `AC-*`/`MAC-*`/`HW-*` 正例、具名断链、标识符边界、简写拒绝、
    跳过与真实基线断言,无阻塞性 TBD。
  - Environment gate:satisfied。`<MAIN_CHECKOUT>/.venv-sdd/bin/python` 实测
    Python 3.14.6 + PyYAML 6.0.3;`scripts/check-sdd.sh` 为 0 errors /
    0 warnings / 111 acceptance IDs。
  - Scope/risk gate:satisfied。allowed/forbidden paths、low-risk false-positive/
    false-negative 边界、hardware required=no 与独立 PR 闭环已明确;
    实现仅需固定 Python、stdlib、PyYAML 与本地临时目录。
  - Review boundary:本 PR 只起草 `blocked→ready` 并记录 DoR 复核;
    implementation + evidence 必须使用独立 TASK-GUARD-001 PR,
    `ready→done` 仍需另一独立状态 PR。
- Closed readiness invalidation(2026-07-20;host-only/offline):
  - Exact preflight:按 design §2 的 `AC-[A-Z0-9]+-\d+-\d+` 与续行规则
    执行,CHG-001 缺 20、CHG-002 缺 10、CHG-005 缺 0、CHG-006 缺 5;
    具名记录见 `evidence/runs/TASK-GUARD-001/preflight-blocker-2026-07-20.md`。
  - Conflict:proposal/design/verification 要求四个现有 `scope.yaml` change 零
    false positive,但 design 精确 token 语法无法解析已有 `MAC-*`/`HW-*`
    acceptance,也不展开 `…`/`*`/`01/02`/`等` 简写;两者不能同时满足。
  - Grammar gate:closed by PR #184;r2 以 scope 中不透明 acceptance ID
    动态精确匹配,覆盖 `AC-*`/`MAC-*`/`HW-*`,并拒绝从简写推断。
  - Re-entry gate:closed by PR #185 + 本 readiness 复跑;旧 change 认领已
    显式化,四个 scoped change 均 missing=0。
- Superseded readiness review(2026-07-20;PR #182 合入时的历史快照;
  已被上述 exact preflight 作废):
  - Approval gate:satisfied。CHG-2026-017 approved(approval-only PR #181 已由维护者
    合入 main `d55b25f`)。
  - Dependencies:satisfied。backlog 增强项已在 main 登记;AC-JOB-003/004 追溯
    修复 PR #138 已合入 main `48efe97`,固定当前基线输入。
  - Contract/verification gate:satisfied。`GUARD-SCOPE-COVERAGE-001`、design 解析
    规则、正反 fixture、真实基线断言与二值 evidence 要求已固定,
    无阻塞性 TBD;本任务 allowed/forbidden paths、low-risk 边界与独立
    PR 闭环已明确。
  - Environment gate:satisfied。`<MAIN_CHECKOUT>/.venv-sdd/bin/python` 实测
    Python 3.14.6 + PyYAML 6.0.3;`scripts/check-sdd.sh` 为 0 errors / 0 warnings /
    111 acceptance IDs;实现/测试仅需该环境、stdlib 与本地临时目录,
    hardware required=no。
  - Review boundary:本 PR 只起草 `blocked→ready` 并记录 DoR 复核;实现+
    evidence 须使用独立 TASK-GUARD-001 PR,`ready→done` 仍需另一独立
    状态 PR。
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
- Deliverables:`check_sdd.py` 全 acceptance ID scope 覆盖校验 +
  `test_check_sdd.py` + `run.md`
  (base OID、实现前 current-main 四 scope.yaml change 零 scope-coverage err 基线、
  测试计数、check-sdd 增强后 0/0/111、偏差)。
- Verification:
  - `GUARD-SCOPE-COVERAGE-001` 二值——`test_check_sdd.py` 覆盖
    `AC-*`/`MAC-*`/`HW-*` 精确认领正例、核心断链具名 err、标识符边界、
    简写拒绝、跳过与真实基线全 PASS;
  - 实现前后 `scripts/check-sdd.sh` 均 `0 errors / 0 warnings / 111 acceptance IDs`
    (增强不引入 false positive);
  - `<ARKDECK_PYTHON> scripts/test_check_sdd.py`;`git diff --check`;
  - 反例证明:临时把某 scope.yaml 的一个 acceptance AC 从对应 task 认领面移除(仅
    fixture,不改真实数据)→ guard 具名 err;复原后消失。
- Evidence gate:上述全 PASS 且 current-main 基线不回归后,另起 status PR 起草 `done`。
- PR boundary:一个 implementation + evidence PR;`blocked→ready`、`ready→done` 各用
  独立 PR。
