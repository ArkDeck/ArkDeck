# CHG-2026-028 Verification Plan

> Status:planned
> Change:CHG-2026-028-guard-ci-mechanization@r1
> Core baseline:CORE-2.1.0(零 Core 变更;canonical Core AC 零认领)

验收面全部为 change-local(见 acceptance-cases.yaml)。共同门:**每个新 check
须有红反证**(canary/反例 fixture,只有绿证据整体 fail);guard 增强合入前后
`check-sdd = 0/0/111` 保持;`archive/**` 零触碰;任何 check 被赋予批准语义的
表述整体 fail。

## Change-local

| Evidence ID | Task | Method | Expected result |
| --- | --- | --- | --- |
| MECH-CI-001 | MECH-001 | documentReview | swift-ci workflow 零 secret/`contents: read`;≥3 个真实 PR 绿 run + 1 次 canary 红 run(注入必败测试的丢弃分支,永不合入)链接在案;docs-only PR 上路径感知秒级 success;App/XCUITest 未覆盖在 job summary 如实注记;测试基线数与 readiness 钉定一致,无静默 skip/`\|\| true` |
| MECH-REV-001 | MECH-002 | contract | 合成 fixture:三方一致正例过;proposal/acceptance/verification 三处各单独漂移的反例各产生恰一条具名 err(含三实值);header 缺失/不可解析 err;archive fixture 跳过;真实基线实现前后 0/0/111 保持 |
| MECH-PIN-001 | MECH-003 | contract | pins block 合法正例过;39/41 hex blob、63 hex sha256、非 yaml、未知 key 反例各具名 err;无 block 文档零校验零 err;archive 跳过;change 模板含 block 示例;真实基线 0/0/111 保持 |
| MECH-PATH-001 | MECH-004 | contract | 声明任务的 canary PR 触碰 Allowed paths 外路径 → job 红并列出越界路径(丢弃不合入);实现/状态/propose 三类真实形态 PR 绿;未声明任务 + 触碰敏感面 → 红;纯 docs 未声明 → 绿;任务不存在/Allowed paths 行缺失/零 token → err(fail closed,非静默过) |

## Gate

本 change `verified` 前提:四 task done(各有 merged 交付 + 独立 done PR +
evidence,含各自红反证);0/0/111 与 Swift 全量基线保持;存量 revision 漂移
(如实现前扫描发现)已以所属 change 名义修复完毕。verified 不构成任何 check
的 required status 翻转(维护者 GitHub 设置动作,独立记录),不改变"CI 绿 ≠
批准"。
