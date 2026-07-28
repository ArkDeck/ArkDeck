# CHG-2026-042 Verification Plan

> Change:CHG-2026-042-tasks-field-colon-parity@r2
> Status:passed # 2026-07-28；三条 AC 与 merge/revalidation OID 见 proposal.md「Verification closure」；仅在维护者 review/merge 本独立 verification-closure PR 后生效
> Core baseline:CORE-2.1.0（零 Core 变更；canonical Core AC 零认领）

验收面全部 change-local。核心判据不是“正则改成了 `[:：]`”，而是两个生产
消费者对两种既有合法标点给出相同语义，同时没有把其他字符、散文或空值扩成授权。

## Environment

- protected `main` 的完整 40-hex base OID；
- macOS host、仓内 Python 3 与 Git；
- readiness 钉定的 `scripts/host_loop/__main__.py`、
  `scripts/host_loop/worker.py`、相关测试文件及全部活跃 `tasks.md`；
- 无设备、HDC、GitHub 写权限、credential 或外部网络要求。

## Change-local acceptance matrix

| AC ID | Verification method | Expected result | Evidence |
| --- | --- | --- | --- |
| `CM7-PARITY-001` | contract + mutation | host-loop 对 `Depends on` / `Allowed paths` 的 `:` 与 `：` 输出逐字段相同；PR guard 的 `Allowed paths` 两种写法同样等价；非法分隔符、空值与散文不产生候选/路径；分别撤销两个全角分支时对应测试必红 | `evidence/runs/TASK-CM7-001/run.md` |
| `CM7-CORPUS-001` | protected-main 活体语料 before/after executable diff | lost = 0；gained 恰为 `TASK-BRC-001`…`006`，且每项 status/grade/hardware/dependency/allowed paths 被记录、六项均非 ready / 不可 dispatch；总数只作 exact-tree 诊断快照，无关 ASCII task 可令两侧对称增减 | `evidence/runs/TASK-CM7-001/run.md` |
| `CM7-SELF-001` | never-claim contract + mutation | 本任务及合法 suffix 永不被循环认领，相邻 task token 不受影响；撤销 root 时专属测试必红 | `evidence/runs/TASK-CM7-001/run.md` |

## Negative and regression tests

- `Depends on；`、`Allowed paths;` 或其他非 `:` / `：` 分隔符不得被接受；
- 空值字段无合法缩进列表时仍省略任务，散文中的 task/path token 仍不能捐值；
- 合法缩进列表续行与现有 ASCII 语料逐字段零漂移；
- `Status`、hardware、grade、approval、dependency completion、path glob、
  base pin、Decision-Grade 与 never-claim 之外的 claim gate零语义变化；
- before/after 差分若出现任何 lost、未登记 gained 或新 ready/可 dispatch
  候选，AC 失败并触发 proposal revision；
- 计数快照须绑定 exact tree 并如实记录：r1 pre-proposal 26→32、
  approved-main 27→33、PR #704 prospective 28→34；不得把总数变化单独判为
  解析语义漂移，也不得用总数相等掩盖 lost/gained 集合变化；
- 分别撤销 `_DEPENDS_RE`、`_ALLOWED_RE` 的全角支持以及 CM7 never-claim root，
  三项变异必须被不同的专属测试击杀；仅改注释的负对照应存活。

## Suite gate

- `scripts/check-sdd.sh`：0 error / 0 warning / 111 acceptance IDs；
- `scripts/test_check_pr_paths.py`：全绿；
- `cd scripts && python3 -m unittest discover -s host_loop -t .`：全绿；
- `git diff --check`：全绿；
- changed paths 全部落在 TASK-CM7-001 allowed paths，secret/privacy 扫描无命中；
- network / GitHub write / device / HDC / E1 / E2 / destructive dispatch 均为 0。

## Result gate

- [x] 三条 change-local AC 全部 passed 且 evidence 可复查
- [x] candidate-set 扩张逐项解释，零 lost、零未登记 gained
- [x] 变异门三项全被击杀，负对照存活
- [x] 任务实现 PR、done 翻转 PR、change verify PR 保持分离
- [x] 未把 proposal/CI 通过解释为 approval、ready、done 或 verified

Closure receipt:`proposal.md#verification-closure2026-07-28`；verification
base = protected main `7b05ccdaea47acc647ba235c630c3899a952c9c3`；
revalidated `2026-07-28T09:09:12Z`。本文件的 `passed` 与 proposal 的
`verified` 只在维护者 review/merge 本独立状态 PR 后生效。
