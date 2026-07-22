# TASK-MECH-002 run — active change revision consistency guard

- Date:2026-07-22;executor:agent(host-only contract;零设备、零 HDC、零
  network dispatch、零 secret)。
- Base:fresh `origin/main`
  `7fd15a93bbed33d3e9d00062116abf13c74d68f6`。
- Readiness pins:
  - `scripts/check_sdd.py` blob
    `f5e9e39e864daf1928d9ef65f8d6dfb9cdaf183d` = **MATCH**;
  - `scripts/test_check_sdd.py` blob
    `526c62ab76e93e95c31bdb06ca1dba61b8ba3bfa` = **MATCH**。
- Environment:Python 3.14.6 / PyYAML 6.0.3(`.venv-sdd`)。
- Evidence class:offline contract + repository baseline;不构成批准/授权或
  hardware evidence。

## Pre-implementation scan

- `ARKDECK_PYTHON=<PRIMARY_CHECKOUT>/.venv-sdd/bin/python
  ./scripts/check-sdd.sh` = **0 errors / 0 warnings / 111 acceptance IDs**。
- active 三方一致:006 = 2/2/@r2、008 = 10/10/@r10、015 = 3/3/@r3、
  021 = 2/2/@r2、022 = 2/2/@r2、023 = 1/1/@r1、024 = 2/2/@r2、
  027 = 1/1/@r1、028 = 1/1/@r1;无 acceptance carrier 的二方一致:
  025 = 2/@r2、026 = 1/@r1。readiness 所列三处存量漂移均已在各自
  change lane 清零,未发现新漂移。
- 两枚待改文件 blob 与 readiness 完整 OID 精确匹配;MECH-003 同文件 lane
  尚未开工,无 pin 漂移。
- 实现期间 main 前进:#341(`a6b403213133305fcbae79ea5a180a03f397d221`)
  由 `lvye` 对 exact head APPROVED 后将 CHG-015 三载体同步重钉 r3;#342
  (`7fd15a93bbed33d3e9d00062116abf13c74d68f6`)由 `lvye` 对 exact head
  APPROVED 后使 TASK-MECH-001 D0 done 生效。分支已 fast-forward 到最新 main;
  两枚 MECH-002 blob pin 仍精确匹配,并在该新 base 重新得到 13/13 与
  0/0/111,未复用旧 base 结论。

## Deliverables

- `check_change_revision_consistency`:只枚举 active
  `openspec/changes/chg-*`;`archive/**` 不进入扫描。proposal front matter
  `revision`、存在时 acceptance `change_revision`、verification 唯一
  `> Change:<ID>@rN` header 必须为正整数并相等;无 acceptance 文件时只比较
  proposal/verification 二元组。
- 任一 carrier 漂移、字段缺失、verification header 缺失/不可解析/多义均
  每 change 追加一条 `revision consistency failed` 具名错误,同时列出
  proposal、acceptance、verification 三处实际值;不以 warning 或 skip
  代替失败。
- 合成 fixture 覆盖:三方/二方正例;proposal、acceptance、verification 各
  单独漂移;proposal/acceptance 字段缺失;verification header 缺失与不可解析;
  二方漂移;archive 跳过。

## Verification

| Command/check | Result |
| --- | --- |
| `.venv-sdd/bin/python scripts/test_check_sdd.py` | PASS:13 tests,0 failures/errors/skips(含 6 个 revision contract test methods) |
| `python3 scripts/test_check_pr_paths.py` | PASS:12 tests,0 failures/errors/skips |
| `.venv-sdd/bin/python -m py_compile scripts/check_sdd.py scripts/test_check_sdd.py` | PASS |
| `ARKDECK_PYTHON=<PRIMARY_CHECKOUT>/.venv-sdd/bin/python ./scripts/check-sdd.sh` | PASS:0 errors,0 warnings,111 acceptance IDs |
| `git diff --check` | PASS |

负反证不是模拟绿结果:三个单 carrier drift fixture 各断言 errors 增量恰为 1,
并逐项断言错误文本含三处实际值;missing/unparseable header 同样断言 exit
判定所依赖的 error 增量为 1。archive drift fixture 故意使用 3/2/@r1,扫描
结果仍为零,证明冻结历史未被新规则追溯检查。

## Deviation and residual risk

- 实现前完整运行 `test_check_sdd.py` 暴露一个既有 fixture 期望漂移:测试仍
  把已归档的 CHG-001/002/005 列为 active scope,因此 7 项中 1 项失败。
  本实现只把该真实 baseline 期望机械更新为当前仍 active 的 CHG-006;
  scope coverage 算法、Core/AC/contract 均未改变。更新后原 7 项与新增 6 项
  合计 13/13 全绿。
- 校验只证明 revision 载体数值同步,不判断 revision 内容是否语义充分;
  CI 绿仍不构成批准。`archive/**` 继续全体豁免。
- 本 evidence-only 后续 PR 不翻 TASK-MECH-002 状态;实现 #343 已由维护者
  review/merge,但仍须先合入本 live evidence,随后另立 `ready→done` D0 状态
  PR。TASK-MECH-003 继续等待 MECH-002 done 后重钉同文件 blobs,不得基于
  未合 evidence 或未生效状态投机开工。

## Live PR evidence

- PR #343 初始 implementation head
  `c98eb5e858038129ec558afb8774c5db949f58c6`。push Swift run
  `29936036221` = **SUCCESS**:Apple Swift 6.3.3,全量 **358 tests /
  1 skipped / 0 failures**;push SDD Guard run `29936040282` = guard
  SUCCESS(`allowed-paths` 在 push event 正确 skipped,不冒充 PR diff check)。
- 自动 PR-opened 的 Swift run `29936062954` 初始为 `action_required`,当时
  不是绿证据;维护者批准 workflow run 后,同一真实 `pull_request` run 于
  exact head **SUCCESS**(10s),路径感知判定零 Swift surface,Xcode/toolchain/
  full test 步骤均明确 skipped,未冒充全量。PR SDD Guard run
  `29936067155` = guard SUCCESS + live `allowed-paths` SUCCESS;body edited
  触发的 `29936110570` 亦为 guard + live `allowed-paths` 双 SUCCESS。
- `lvye` 于 exact head `c98eb5e858038129ec558afb8774c5db949f58c6`
  提交 GitHub APPROVED review,随后合入 #343;merge OID =
  `6f9e3df9ee29d792d7d5cfb85b035a425c03e19c`。CI 绿与 AI review 不构成
  该批准,人类 review/merge 才使实现进入 protected main。
- 不同 AI 会话对 implementation + 本 run evidence 前一版的 final commit
  `c98eb5e858038129ec558afb8774c5db949f58c6` 独立复核 = **APPROVE**;
  逐项重跑 13/13、12/12、0/0/111 与 diff check,核对 #341/#342 exact-head
  approval/merge、active revision 清单、allowed paths 与零状态翻转。reviewer
  未在 GitHub approve/merge;本合后 evidence-only delta 仍须对新 final head
  复核并取得其自身 PR checks,不得把 #343 的检查冒充本 PR 检查。

## AC conclusion(candidate)

`MECH-REV-001`:contract、真实 baseline、implementation PR live CI、独立
AI review 与维护者 exact-head review/merge 面全部 PASS;本合后 evidence
尚待独立复核、PR checks 与维护者合入,其后仍需独立 `ready→done` 状态 PR。
故本记录是 D0 状态候选 evidence,不在本 PR 把 task/change 标为
done/verified。
