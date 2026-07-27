# CHG-2026-039 Verification Plan

> Status:planned
> Change:CHG-2026-039-host-loop-repo-wide-discovery@r2
> Core baseline:CORE-2.1.0（零 Core 变更；canonical Core AC 零认领）

验收面全部为 change-local。任何认领门放宽、任何 lease/transport 触碰、
任何 launchd/plist 动作、任何未知任务 fail-open，整体 fail。

## Change-local

| Evidence ID | Task | Method | Expected result |
| --- | --- | --- | --- |
| NAV-DISC-001 | NAV-001 | contract | 缺省 round 与 `--explain` 枚举全部活跃 change（对真实仓的独立最小抽取对照）；显式 `--change <id>` 单 change 回归绿；跨 change 聚合下每轮至多一个 claim 由契约测试钉死；change-approved 门逐 change 判定有正/负对照 |
| NAV-TRUTH-001 | NAV-001 | contract | done 状态 never-claim 任务不再触发 `only never-claim tasks are ready` 判词（回归测试 + 撤销修复必红的变异门；ready 状态 never-claim 正对照仍触发）；idle/claim 行含 UTC ISO-8601 时间戳与扫描范围 |
| NAV-ARCH-001 | NAV-002 | contract | `check_pr_paths.py` blob 零变更（invariant pin），其既有 archive 语义负向测试集（archive-only 零权威、原子归档家族）保持全绿；活体样本测试经 active-or-archive 解析/动态活跃采样后，scratch worktree `git mv` chg-2026-030 入 archive 的演练全量 suite 与 `check_pr_paths`/`check_sdd` 测试绿（#573 所列 1+5 error 全消）；`check-sdd` 0/0 基线保持（AC 措辞经 r2 更正，见 proposal） |

## Gate

三条全 PASS 且各任务 evidence run 在案，任务方可 done；change verify 于
两任务 done 后以独立 PR 收口。
