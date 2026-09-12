# 提交与 PR

适用：任务需要 commit、push、创建或更新 PR；准备提交时读取。
本指南由 [AGENTS.md](../../AGENTS.md) 按需引用，所有命令在仓库根目录执行。

- AI 变更使用 `agent/**` 分支，由 [agent-pr.yml](../../.github/workflows/agent-pr.yml) 以
  `github-actions[bot]` 开 PR。维护者 review 后合入 protected `main` 才构成批准；
  文件状态、签名或 CI 不能替代。不静默扩大任务、Allowed paths、Acceptance scope 或
  approved 安全 change 范围。
- PR 标题、正文与最终 commit subject 用英文，概括实际 diff、原因和验证。默认
  ready-for-review，仅用户要求时设为 Draft；提交后读回 title/body/state/isDraft 与 changed files。
- 涉及敏感路径时，最终 commit subject 声明 base 上已有且覆盖完整 diff 的 Task ID，PR
  保留 `Task:` 声明；非敏感文档改动可无 Task。以 [automation_config.json](../automation_config.json)
  与 preflight 为准（`AGENTS.md` 和本目录均属于敏感路径），不为过门禁扩张 Allowed paths；
  受限 supplement 由 checker 判定。最终 commit 后、push 前执行：

  ```bash
  python3 scripts/check_pr_paths.py --repo-root . --preflight \
    --base-revision origin/main --head-revision HEAD
  ```

- 实现确需 base 上该 Task Allowed paths 之外的路径时，可在同一 PR 内把该路径加进 Task 的
  Allowed paths，并在最终 commit 正文逐条写 `Scope-Extension: <pattern>` trailer（CHG-2026-076）。
  只允许有界 pattern：固定前缀至少两级且在 base 树存在、每 PR 至多 8 条、不与 base 已授权路径
  重复；`automation_config.json` 的 `never_self_extend`（CI 信任根、治理文本、durable 格式、
  device lowering、admission/capability/recovery 内核）不可自扩，仍走单独的 scope PR。
  声明不是授权：checker 只把它写进 PR 正文与检查摘要，合入才是批准。

sandbox 内 `gh auth status` 报未登录或 token 无效时，用受控权限提升重试，不据此要求
维护者重复登录；若仍失败，报告实际错误。
