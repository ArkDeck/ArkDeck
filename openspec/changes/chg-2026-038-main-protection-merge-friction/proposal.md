---
id: CHG-2026-038-main-protection-merge-friction
revision: 1
status: proposed
class: governance
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
