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

自动开 PR 会保留已有 PR 的实际 base；新 PR 从未合入的同仓 PR 中选择唯一最近的祖先。
首次 push 需要明确父层（例如父层已前进，或有多个可能父层）时，在末尾提交添加
`Stack-Base: agent/<直接父分支>` trailer；显式新建独立栈可写 `Stack-Base: main`。
该行从提交说明正文的任一行读取（提交时工具在其后追加的署名段落不影响读取），只能出现一次；
该 trailer 只参与新 PR 的创建，不重设已有 PR，也不代替 restack。

机器人通过 GitHub Stacks REST API 登记依赖链；只创建新栈或在既有栈顶追加新层，并读回
membership 与顺序。已有不同子层、多个栈交叠或 API 不可用时会明确失败，保留 PR 与 base，
不重写分支、不拆掉已有栈、不把元数据失败计作通过。先解决报告的依赖问题，再重新 push。

## 合并队列

`guard` 与 `swift` 同时处理 `merge_group: checks_requested`。队列按事件固定的 base/head SHA
检查完整组合，Rust published baseline 也固定到该 base；临时分支变化不改变检查对象。
每层 push 的 required checks 继续保留，不用上层通过替代下层验证。

[队列设置](../../.github/merge-queue.json) 是待发布的 GitHub ruleset 配置；提交该文件不会启用
队列。只有这组工作流经维护者 review 合入 protected `main` 后才能应用。启用前备份并核对
远端 branch protection 与 rulesets，保留 `guard`、`swift`、review、linear history 及现有
权限边界。采用 `ALLGREEN`、squash、1 个并行候选构建、每组最多 3 个 PR、360 分钟检查超时，
不为凑组增加等待；后续根据实际队列耗时调整，不把增大合并组当作减少 CI 构建。

`agent-ref-boundary` 也匹配 `gh-readonly-queue/main/**`。应用前让 GitHub merge queue bot 能够
创建、更新和删除临时队列分支；只给该内置 bot 添加 bypass，不开放其他 actor 的分支写入。
应用后读回 queue 配置和必需检查；由维护者 review 后入队的首个真实 PR 验证 `merge_group`
上的 `guard`、`swift`。不得用手工上传 status 或旧 PR 的绿色检查替代组合验证。

## 共享文件与重复构建

CI 的 Linux planner 同时运行被选中的设计系统交互测试，SDD `guard` 在自己的 runner 上检查
token 一致性。验收记录不触发交互测试；原型、设计清单与实际测试输入仍触发。planner 全部
成功且明确没有编译车道时，required `swift` job 以成功跳过结束，不额外领取 runner。
planner 失败、取消或缺少输出时仍执行汇总并阻塞合入；有编译车道时继续检查每条车道结果。

同时推进的平台或功能若触及同一份 `spec/ui-semantics/strings.json`、Catalog、control contract
或对应生成物，先在已有 PR 链中选一个共享集成层并注明负责 Agent。该层合并双方需要的源输入，
运行生成器并提交配套产物；其他层基于它消费结果。确实需要新增共享字段时先更新该层再向上
restack，不让多个顶层各自重复生成。独立文件仍可并行开发。

SwiftPM 与 Xcode 的成功 agent push 可复用本分支构建缓存；候选缓存按分支隔离，只在相同
runner、toolchain 和输入键上复用。main 与 merge group 只读取可信 main 缓存，每个候选仍运行
已选择的构建和测试。受保护 main 上的维护 workflow 按最新成功构建清理候选缓存，保留总预算
2 GB、每分支/格式最新一份，避免大量层级缓存长期挤占 main 缓存；写入到清理之间可能暂时超出
保留预算。缓存命中和耗时以实际 CI 为准，不把本地 fixture 结果当作性能改善证据。
