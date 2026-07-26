# CHG-2026-038 Verification Plan

> Status:planned
> Change:CHG-2026-038-main-protection-merge-friction@r1
> Core baseline:CORE-2.1.0（零 Core 变更；canonical Core AC 零认领）

验收面全部为 change-local。任何信任根开关变化、任何 ruleset/凭据/其他 setting
被触碰、Agent 执行 protection 写入、或以 cleanup 改写失败结论，整体 fail。

## Change-local

| Evidence ID | Task | Method | Expected result |
| --- | --- | --- | --- |
| MPF-DELTA-001 | MPF-001 | documentReview | after 的 canonical projection SHA-256 与 readiness 期望值逐字节相等；逐字段比对显示恰好三项变化（`dismiss_stale_reviews`/`strict`/`allow_force_pushes` 均 true→false）；信任根七项前后完全一致（review count 1、CODEOWNER true、enforce_admins true、push users `[lvye]`、linear true、required check `guard`、allow_deletions false）；ruleset `19595282` 独立 GET 前后一致；执行者为 `lvye`，Agent protection 写入计数 = 0 |
| MPF-FLOW-001 | MPF-001 | documentReview | 一个真实 PR 以 `gh pr review --approve && gh pr merge --squash` 单命令完成，审计记录完整（`lvye` APPROVED @ exact head、`mergedBy=lvye`、`auto_merge=null`、squash subject 携 `(#N)`）；main 前进后另一 in-flight PR 无需 `Update branch` 即可合入且 approval 未被作废；补偿控制（merge 前 rebase + 合成树全量套件）在案 |

## Gate

两条全 PASS 且 evidence 在案，任务方可 done；change verify 于任务 done 后以
独立 PR 收口。任何 CI green 或 protection read-back 本身都不构成维护者批准。
