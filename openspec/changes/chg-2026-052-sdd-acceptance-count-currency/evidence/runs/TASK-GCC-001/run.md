# TASK-GCC-001 implementation run — 2026-07-30

- Evidence class:`contract`
- Core baseline:`CORE-2.1.0`
- Scope:`GUARD-COUNT-CURRENCY-001`
- Executor:`agent`（Repo Agent Plane）
- Base:`04190f73f69d06ad2046997a7532b48eb3afb966`
  （CHG-2026-052 r2 Allowed-path correction PR #819 merge；包含 #817）
- Input pins:四项 readiness blob 与 `tasks.md` 声明逐项一致，零漂移。
- Changed script blob:
  `scripts/test_check_sdd.py` `2b7b046d4253050d932ad971605a61aeccb5f469`
  → `744ca88ebbdb73d03517ac689165ba7eacc141f1`
- Evidence currency:`current`

## Environment

- macOS 26.6（25G72），arm64
- Python 3.14.6 / repository shared SDD environment / PyYAML
- host-only/offline contract execution；未连接设备，未运行 HDC 或 product Runtime

## Work completed

- 新增 `declared_core_acceptance_count`，只读取 conformance manifest 的
  `acceptance_index.count`，只接受非 bool 的正整数；读取/解析失败、非 mapping、
  missing/null/bool/string/float/zero/negative 均抛出 assertion。
- 新增一个合成 contract test，正例固定 `114`，11 个 malformed/type/range
  反例全部 fail closed。
- 真实仓库 subprocess test 保留 exit code = 0 门，并把 success 摘要的 expected
  count 从 Python 字面量改为上述严格 reader；仍精确要求 0 errors / 0 warnings。
- 未修改 `check_sdd.py`、conformance manifest、canonical AC、workflow 或
  allowed-path guard。

## Commands and results

| Command | Result |
| --- | --- |
| `<sdd-python> scripts/test_check_sdd.py` on implementation tree | PASS，63/63 |
| `<sdd-python> scripts/test_check_pr_paths.py` | PASS，50/50 |
| `./scripts/check-sdd.sh` on implementation tree | PASS，0 errors / 0 warnings / 111 acceptance IDs |
| `git diff --check` | PASS |

## 114-count downstream replay

在临时 worktree 以本地 git refs 构造未提交合成树：

- protected-main/proposal base =
  `04190f73f69d06ad2046997a7532b48eb3afb966`;
- implementation script blob =
  `744ca88ebbdb73d03517ac689165ba7eacc141f1`;
- CHG-2026-051 archive candidate =
  `1d12c16f6e47ae5d1d03d643cf2df96ec0cccdc2`（PR #816 branch）。

合成 merge 无冲突，且未提交、未推送。结果：

| Command | Result |
| --- | --- |
| `<sdd-python> scripts/test_check_sdd.py` | PASS，63/63 |
| `<sdd-python> scripts/test_check_pr_paths.py` | PASS，50/50 |
| `./scripts/check-sdd.sh` | PASS，0 errors / 0 warnings / 114 acceptance IDs |
| `git diff --check` + `git diff --cached --check` | PASS |

预览后已执行 `git merge --abort` 并移除临时 worktree/branch。该 replay 是
contract preview，不构成 CHG-2026-051 archive 批准；#816 仍须在本实现合入后
更新到 latest main，并以 GitHub exact-head checks 复验。

## AC conclusion

- `GUARD-COUNT-CURRENCY-001`:PASS（contract）。当前 111 与真实 #816
  114 合成树均使用同一脚本 blob 通过；valid 114 reader 正例与全部 invalid
  shape/type/range 反例通过。实际 count 不等于 manifest 时，精确 success 摘要
  断言不匹配并失败；subprocess 非零仍在此前的独立门失败。

## Deviations and residual risk

- Deviation:none。
- 本 run 零 product/device/HDC/network dispatch，零 capability/authorization
  变化，不产生 platform/hardware support 声明。
- residual gate：维护者须 review/merge 本 implementation/evidence PR；随后 change
  级 verification 与 archive 分别独立完成。#816 必须基于合入后的 main 重跑，
  不得把本地合成 preview 当作 merge approval。
