# TASK-GCC-001 verification closure replay r1

Date:2026-07-30

Classification:`contract`。本记录不是 product runtime、installed-HDC、
real-device、platform-conformance 或 `realHardware` evidence。

## Verdict

PR #818 exact head
`a7bb8963c58970e89c440f224c38caef332cf253` 由维护者 `lvye` approve，并合入为
`55110476658df9b7955f4bd807f56b3071660c17`。其 same-revision `run.md` 将
`GUARD-COUNT-CURRENCY-001` 记录为 PASS。

独立 closure replay 在该 exact protected-main merge OID 上执行；current 111
基线与叠加 #816 后的 114 candidate 均使用同一测试脚本 blob 通过。此记录本身不
批准 `verified`；只有维护者 review/merge verification PR 后状态才生效。

## Delivery trust chain

- r1 proposal #817 exact head
  `237fb1e5b694606ee0ce161c724b0cecf54f8354` 由维护者 `lvye` approve，并合入为
  `8a9bfef4d4794ff4289cc1e35d1b50e4c1d816b6`。
- governing r2 correction #819 exact head
  `e70316b2f07deeb7760ca27405333c972734b7fe` 由维护者 `lvye` approve，并合入为
  `04190f73f69d06ad2046997a7532b48eb3afb966`。
- implementation/evidence #818 exact head
  `a7bb8963c58970e89c440f224c38caef332cf253` 由维护者 `lvye` approve，并合入为
  `55110476658df9b7955f4bd807f56b3071660c17`。
- 三个 PR 的 required Agent PR、SDD Guard、allowed-path 与 Swift CI checks 均为
  `SUCCESS`。approval/merge facts 建立 authority；具体 AC 真值仍来自
  implementation run 与本次独立 replay。

## Replay environment and inputs

```text
macOS 26.6 (25G72), arm64
SDD interpreter: shared repository .venv-sdd
Python 3.14.6 / pinned PyYAML
protected-main replay OID:
  55110476658df9b7955f4bd807f56b3071660c17
scripts/test_check_sdd.py:
  744ca88ebbdb73d03517ac689165ba7eacc141f1
scripts/check_sdd.py:
  43d889cd4c97f958270157514f79059c316f0b3e
openspec/verification/core-conformance.yaml:
  0684bdb4efaac9659cf137d18d83cacc22ce6816
.github/workflows/sdd-guard.yml:
  1ab1db896b4ee83207e006b2720cdbe1c0d27e70
CHG-2026-051 archive candidate:
  1d12c16f6e47ae5d1d03d643cf2df96ec0cccdc2
```

## Current-main commands and results

| Command/gate | Result |
| --- | --- |
| shared-Python `scripts/test_check_sdd.py` | PASS, 63/63 |
| shared-Python `scripts/test_check_pr_paths.py` | PASS, 50/50 |
| `scripts/check-sdd.sh` | PASS, 0 errors / 0 warnings / 111 acceptance IDs |
| `git diff --check` + clean status | PASS |

`AcceptanceCountCurrencyTests` 的正例返回 `114`；11 个 negative documents 覆盖
top-level null/list、missing/null `acceptance_index`、missing/null
`count`、bool、string、float、zero 与 negative，全部抛出 assertion。
`IntegrationProfileHeaderLockTests` 的独立负例继续要求
`acceptance count 1 != actual 0`；真实基线测试先要求 subprocess exit code = 0，
再要求 0 errors / 0 warnings / manifest exact count 的完整成功摘要。

## 114-count downstream replay

在临时 detached worktree 从 protected-main replay OID 开始，以
`git merge --no-commit --no-ff` 叠加 #816 candidate
`1d12c16f6e47ae5d1d03d643cf2df96ec0cccdc2`。合成 merge 无冲突、不提交、不推送；
结果：

| Command/gate | Result |
| --- | --- |
| shared-Python `scripts/test_check_sdd.py` | PASS, 63/63 |
| shared-Python `scripts/test_check_pr_paths.py` | PASS, 50/50 |
| `scripts/check-sdd.sh` | PASS, 0 errors / 0 warnings / 114 acceptance IDs |
| `git diff --check` + `git diff --cached --check` | PASS |
| `git hash-object scripts/test_check_sdd.py` | `744ca88ebbdb73d03517ac689165ba7eacc141f1` |
| `git diff --name-status HEAD -- scripts/test_check_sdd.py` | empty |

复验后执行 `git merge --abort` 并移除临时 worktree。该 replay 只证明
`GUARD-COUNT-CURRENCY-001` 的 count-currency contract，不批准 #816 archive；
#816 仍须更新到 latest main 并通过其 own exact-head checks/review。

## Acceptance and effect boundary

- `GUARD-COUNT-CURRENCY-001`:PASS（contract）。accepted positive integer 是唯一
  expected-count source；malformed/type/range 与 actual/declared mismatch 均
  fail closed；111 与 114 两棵树无需再次编辑 test source 即通过。
- Deviation:none。
- AC replay 全部使用 tracked repository input + local Python subprocess；未运行
  product Runtime、installed HDC、设备、device mutation、destructive step，
  未改变 capability/authorization，未产生 product/test network request 或
  hardware/platform support 声明。GitHub PR metadata 只做只读治理账本核验，不是
  AC 执行输入。

若 verification PR 合入前 protected main 改变上述 test/guard/manifest/workflow
blob，或 #816 candidate 改变其 114-count 输入，必须重放受影响验证并更新记录；
不得从旧 replay 推断通过。
