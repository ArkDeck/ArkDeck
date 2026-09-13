# 提交与 PR

适用：任务需要 commit、push、创建或更新 PR；准备提交时读取。
本指南由 [AGENTS.md](../../AGENTS.md) 按需引用，所有命令在仓库根目录执行。

- AI 变更使用 `agent/**` 分支，由 [agent-pr.yml](../../.github/workflows/agent-pr.yml) 以
  `github-actions[bot]` 开 PR。维护者 review 后合入 protected `main` 才构成批准；
  文件状态、签名或 CI 不能替代。不静默扩大任务、Acceptance scope 或 approved 安全 change 范围。
- PR 标题、正文与最终 commit subject 用英文，概括实际 diff、原因和验证。默认
  ready-for-review，仅用户要求时设为 Draft；提交后读回 title/body/state/isDraft 与 changed files。
- 改动范围由维护者在真实 diff 上 review，仓内没有按路径放行或拒绝的机器门（CHG-2026-077 退役了
  `check_pr_paths` 路径护栏）。Task 的 Allowed paths 是作者预计触及范围的规划声明：实现需要
  触碰表外路径时直接改，在 PR 正文说明即可；不为此开 scope PR、不扩写 Allowed paths、不写
  `Scope-Extension:` trailer、不做路径 preflight。
- 最终 commit subject 里的 Task ID（如 `fix(TASK-XXX-001): …`）会被 workflow 原样写进 PR 正文的
  `Task:` 行，只作追溯，不做校验；纯文档或没有对应 Task 的改动可以没有。

sandbox 内 `gh auth status` 报未登录或 token 无效时，用受控权限提升重试，不据此要求
维护者重复登录；若仍失败，报告实际错误。
