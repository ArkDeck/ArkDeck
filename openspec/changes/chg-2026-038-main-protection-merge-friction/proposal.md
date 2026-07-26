---
id: CHG-2026-038-main-protection-merge-friction
revision: 1
status: verified # 2026-07-26 本 verification-closure PR（先例 #224/#239/#399/#570）；approval #575；TASK-MPF-001 done #582 已合入（全链 OID 见 Verification closure）；archive 另行。原注：approval-only #575 置 approved
class: implementation-only
core_change_level: none
owner: lvye
core_baseline: CORE-2.1.0
platforms: [macos]
---

# main protection：消除单人维护者的合并摩擦，并复原一处 force-push 漂移

## Why

**摩擦事实（2026-07-26 实测）**：单人维护者每合一个 PR 要做三到四个动作——
approve → main 前进 → `Update branch` → **approval 被 `dismiss_stale_reviews`
作废** → 再 approve → merge。今日 chg-030/037 收官期 25 份载体全部经此，
维护者明确要求消除之。

**两个开关就是元凶，且与信任根无关**：
`required_status_checks.strict=true` 强制 `Update branch`；
`dismiss_stale_reviews=true` 让 branch update 作废刚给出的 approval。
把两者关掉后，一条命令即可完成一个 PR 的全部人类动作：

```text
gh pr review <N> --approve && gh pr merge <N> --squash --delete-branch
```

**明确不动信任根**：`required_approving_review_count=1`、
`require_code_owner_reviews=true`、`enforce_admins=true`、
`restrictions.users=[lvye]`、`required_linear_history=true`、required check
`guard` 全部保持原值。维护者曾考虑一并取消必需 review（可再省一次点击），
经评估**否决并记录理由**：`lvye` 的 `gh` 登录态在 Agent 会话可达（已记录的残余
弱分离面），当前**必需 review 是唯一强制在 exact head 上留下「人做过决定」这一
机器可证记录的机制**；取消它会使账本无法区分「人决定」与「Agent 用人的 token
合并」，正面推翻 CHG-2026-033 建立的 human-only-approval 可证明性——用一次点击
换掉整条审计链不成立。上面的单命令流以零治理代价达成同一个「一个动作」目标。

**顺带发现的漂移（同窗口复原）**：live protection 的
`allow_force_pushes=true`，而 CHG-2026-033 TASK-RPT-001 evidence 明文钉
「force-push false and deletion false」（`2026-07-24-topology-success.md`）。
main 允许 force push 会破坏「git 历史即审计账本」这一根假设，且
`required_linear_history` 挡不住历史重写。何时被改动无可靠日志，故**不追责、
只如实记录发现并复原**；`allow_deletions` 仍为 `false`，无需改动。

## What changes

### In scope

- 由维护者在 Agent 不可达的隔离会话中，对 `main` branch protection 施加**恰好
  三项** delta：`dismiss_stale_reviews: true → false`、
  `required_status_checks.strict: true → false`、
  `allow_force_pushes: true → false`。
- 执行前后各一次 authenticated 全量 GET，记录 full-GET 与 canonical projection
  两个 SHA-256，并逐字段比对确认**只有**上述三项变化。
- 把「单命令合并流」与「strict 关闭后的补偿控制」写入 evidence（不改 governance
  正文——本 change 不触碰 constitution/enforcement/AGENTS.md 的信任根表述，因为
  信任根本身未变）。

### Out of scope

- 任何信任根开关（review count/CODEOWNER/enforce_admins/push
  restrictions/linear history/required `guard`）；
- ruleset `19595282`（agent namespace 边界）、Deploy Key、GitHub App、任何
  凭据或 repository setting；
- `allow_deletions`、`block_creations`、`required_conversation_resolution`；
- auto-merge（治理明令任何等级均无 auto-merge，本 change 不动该结论）；
- Agent 执行 protection 写入——本 change 由人执行，Agent 只起草与核验。

## Risk

关闭 `strict` 后，一个 PR 可能在**未与最新 main 合成测试过**的状态下被合入
（语义冲突风险）。补偿控制（均为既有实践，写入 evidence 并作为约定延续）：

1. Agent 在请求 merge 前把 PR rebase 到最新 `origin/main` 并在合成树上跑全量
   套件与 `check-sdd`——今日 25 份载体已全程如此；
2. required check `guard` 仍在 PR head 上强制运行，`enforce_admins` 不变；
3. `required_linear_history` 保持 `true`，squash 合并不产生分叉；
4. 任一 PR 若与 in-flight 变更有文件交集，仍按既有 drift 规矩重钉 pins 而非
   靠 protection 兜底。

风险等级 low-medium：它把「机械强制的 up-to-date」换成「Agent 侧可复验的
up-to-date + 人的判断」，而后者今日已被实证执行了 25 次。

## Tasks

单任务：TASK-MPF-001（见 tasks.md）。propose 合入 ≠ 批准；approval-only PR
merge 后 change 方为 approved；protection 写入须经独立 readiness 授权。

## Verification closure（2026-07-26）

单任务 TASK-MPF-001 done 于 protected main 在案，两条 change-local AC 证据可
复查；本 PR 仅状态翻转 + 引用，零实现夹带（先例 #224/#239/#399/#570）。

- **任务链**：propose #574 merge
  `aa6b447ceb38585a56b506ee571362f91dccb73a`；approval #575 merge
  `1609b4d5d185410da8d3245efcd5b5a86ccc8d8c`；readiness r1 #576 merge
  `66a70e2a3dc7338be3cd02f9b5ddb4a1dc1ba236`；grade 播种（跨 change，
  MPF-001 标 `D2。`）#577 merge `a720edea0990e7c04b39316a68df30809095f9b0`；
  attempt#1 blocked-attempt evidence #578 merge
  `4a1a118a197a1a0846f04e86acf8232e0784b592`（no-S7 裁决追认）；readiness r2
  #579 merge `4aab55cc42b04d52d4d55b8aedbfa2b2d49eb998`；r2 review-fix #580
  merge `f28d416b4ef0a8e7d98bed2a1d4d4801482d1c68`（另会话三发现 E1/E2/E3，
  执行前修正）；attempt#2 evidence #581 merge
  `b055fe306d07126c1235788f84a8c035c7209c2e`；done #582 merge
  `cb6a70a3b8481073321f41af46f45c72c309118d`（#580 冲突重排 head
  `f61b9470ec918449414ef52cb4f5cc74e0a5c89a`，approval 存续合入）；flow 观测
  实录 #583（exact head `b25f060ae60ab1065c7df4e0972e497fcdcaf5fd`；按本
  closure 编排先于本 PR 合入，merge OID 由其合并记录承载）。
- **MPF-DELTA-001 = PASS**：after 双面投影命中 readiness 期望——REST
  `4046aced77a6ff040ea6789b6edf96a80e288ae6ef144d9d89a85b76a336d2dc`（r1
  expected 经 r2 达成，「白名单清空后 REST 布尔渲染 false」待证门 PASS）、
  GraphQL `241b916010e3fa431663c36d21af7bd4b361cb4a374a789f0db7d74366efbac6`；
  累计逐字段 delta（原始 before `a8cff448…` → 最终 live，修正式）恰好三项
  true→false；信任根七元组 `[1,true,true,["lvye"],true,["guard"],false]`
  前后一致；ruleset `19595282` 四次读数同哈希 `c404036f…`；执行者恒 `lvye`
  （attempt#1 REST PUT ×1 + attempt#2 GraphQL mutation ×1，各在其 readiness
  授权内）；**Agent protection 写入计数 = 0**。全档（含 REST 拍扁渲染与 jq
  `paths(scalars)` 两个平台/工具坑）= run.md attempt#1/#2。
- **MPF-FLOW-001 = PASS**（实录与判据 = run.md「观测实录」段，#583 载体）：
  观测① = #581 单命令流（approve→merge 间隔 3 秒，审计四件套齐）；
  `dismiss_stale_reviews=false` 直接实证 = #582（force-push 后同 review 合入，
  review.commit ≠ merge head）；观测② = **本 verify PR 自身**——与 #583 并行
  in-flight、先获 approve，#583 合入使 main 前进后，本 PR 免 `Update
  branch`、不重新 approve 直接 merge；其 merge 记录按 run.md 钉定判据永久
  可证。补偿控制条款在案（run.md attempt#2）。
- **change 目标的运行证据**：#581/#582/#583/本 PR 全程单命令流，原「approve →
  Update branch → approval 作废 → 再 approve → merge」循环已于 live 消失。
