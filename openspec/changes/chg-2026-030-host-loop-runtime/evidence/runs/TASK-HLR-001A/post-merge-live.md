# TASK-HLR-001A Post-merge Live Run — ordinary Agent evidence PR

- Date:2026-07-24（Asia/Shanghai）。
- Executor:`agent` for repository-only evidence drafting and Deploy Key branch
  push；`github-actions[bot]` is the only permitted PR creator/workflow
  identity；human `lvye` is reserved for the later metadata revalidation and
  review/merge decisions。
- Classification:`live GitHub repository workflow`，host-only；零真实设备/HDC，
  零 GitHub setting/branch-protection/ruleset/credential mutation，零 Agent
  review/merge/auto-merge。
- Task state boundary:本 PR 只采集 post-merge evidence，不翻
  `TASK-HLR-001A ready→done`；HLR-002A canary/ref dispatch 继续为零。

## Immutable preflight

- Approved readiness:#483 exact reviewed head
  `83f508aa6d64ba26789edd6e82ce0c2f8dff5fb3`，由 `lvye` APPROVED，
  merge/main `c2fd6d1dff71717f8a8dd3137c68b4a06cf569cf`。
- Implementation:#485 final exact head
  `6717ae3c8cfbc464294de284a173e914ed1024bf`，由 `lvye` APPROVED，
  review commit 与 final head 相等；`mergedBy=lvye`，于
  `2026-07-24T14:24:53Z` merge 为 protected main
  `cae9a4c378b75409a4d7a31205583560f17d73aa`。
- Evidence pilot base/current protected main:
  `cae9a4c378b75409a4d7a31205583560f17d73aa`。
- Preflight remote state:implementation/evidence branches 均 absent，open PR
  count = 0；planned evidence branch =
  `agent/task-hlr-001a-auto-ci-evidence`。

## Live result gate

本 initial evidence commit 只建立可审计载体，不预填 live PASS。首次 push 后必须
从 public GitHub API 固定以下事实，随后才可在同一 PR 的 evidence-only commit
中判定：

- exactly one open same-repository PR；`author=github-actions[bot]`，
  base/ref/head OID 与本 branch 完全一致；
- exact-head SDD Guard、Swift CI、Agent PR `open-pr` 与 `allowed-paths` 均自动
  success；event 为 `push`，`pull_request`/`action_required` routine run = 0；
- 不需要维护者点击 `Approve and run workflows`；
- existing-PR evidence-only push 仍复核同一 PR 且四项检查自动 success；
- human edit/reopen 仍触发 base-defined metadata revalidation，且无需 workflow
  approval。

任一 0/2 PR、wrong repository/base/ref/head/author、缺失 check、`action_required`
或必须人工批准 workflow 才能满足治理门，均为 FAIL；停止本 task done 与后续
HLR-002A readiness，不以重跑掩盖失败。
