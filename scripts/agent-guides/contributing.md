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

## 连续 PR 使用 stacked PR

按 [GitHub stacked PR 文档](https://docs.github.com/en/pull-requests/get-started/about-stacked-prs)
组织同一工作流的连续改动，降低依赖分支反复修改共享文件造成的冲突；stack 不能保证零冲突。

- 开始下一层前 fetch 并读回已有 PR 的状态、head 与 base。前一层未合入时，从它的最新分支
  创建下一层 `agent/**`，PR base 指向相邻下层；已合入则从最新 `main` 开始新栈。真正无依赖、
  无共享改动的工作可另开独立栈，不为连续编号制造依赖。所有层放在同一仓库。
- 每层保持一个完整、可审阅的行为增量；共享契约、类型和生成器放在依赖它们的层下面。
  PR 正文注明直接依赖的 PR 链接与顺序，diff 对相邻下层只包含本层改动，避免重复提交
  下层补丁、历史 run 记录或生成物。
- 优先使用仓库已可用的 GitHub 原生 stack / `gh stack` 管理依赖。仅调整 base 的普通 PR 链
  不自动等于已登记的原生 stack；读回 stack membership 与顺序。原生功能不可用时保留分支
  依赖链，显式维护 base、PR 链接和每层 required checks，不假定继承了 trunk 的保护。
- 下层因 review、冲突或 `main` 更新而变化时，先更新最底层，再逐层 restack；每次以上一层
  的最新 head 为准。解决源码与契约冲突后再运行对应生成器，不用整文件 ours/theirs 丢弃
  另一层行为，也不手改生成物来掩盖冲突。只跑受影响的本地检查，完整验证交给 PR CI。
- 已推送分支优先保留历史；需要 rebase 时先核对远端与他人提交，只用匹配已核对远端 SHA 的
  `--force-with-lease`，不盲目 force push。同步后读回每层 head/base、changed files、冲突状态
  和当前 head 的 CI，确认上层没有混入下层 diff 或遗漏新提交。
- 合入由维护者从底向上进行；不因上层 CI 绿而越过下层 review。原生 stack 的中间层或顶层
  合入可能同时合入其下所有层，未获整段授权不得触发。下层合入后读回自动 rebase/retarget
  结果；普通 PR 链则显式更新剩余分支与 base，squash/rebase 合入时避免重放已合入补丁。

兼容说明：当前 `agent-pr.yml` 自动创建 PR 和身份回读仍固定 `main`。创建上层 PR 后应设置并
读回实际下层 base；若该 workflow 因固定 base 假设失败，如实报告为自动化兼容缺口，不把
它计作通过，不为消除此报错把有依赖的 PR 改回 `main`，也不放宽 required checks 或 review。
