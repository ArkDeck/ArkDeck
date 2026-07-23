---
id: CHG-2026-030-host-loop-runtime
revision: 1
status: approved # 本 approval-only PR 经维护者 exact-head review/merge 后生效；所有任务仍 blocked
class: implementation-only
core_change_level: none
owner: lvye
core_baseline: CORE-2.1.0
platforms: [macos]
---

# Host-loop runtime：为 Agent PR 建立可恢复的 worker/reviewer 双循环

## Why

审计基线为 protected `main`
`e73b025dab3c12162465040bd0829470b2409ae9`。该基线的
`.github/workflows/agent-pr.yml` 是一次性 bootstrap：它只在 `agent/**` push
后以 `GITHUB_TOKEN` 建 PR，PR body 是固定文案，且 attribution 固定为某一厂商
工具。它没有为 task PR 写入 `Task: TASK-*`，也没有完整 base OID、D0/D1/D2
grade、evidence 或依赖字段。

这使得 CHG-2026-028 的 `MECH-004` 虽已提供 PR diff guard，仍不能可靠地在首个
PR event 得到正确输入：`GITHUB_TOKEN` 创建的 PR 不会触发新的 workflow run；随后
必须有人另行编辑 body，才可能得到 `pull_request` 的 allowed-paths 复核。GitHub 对
Actions 递归事件的限制见
[官方事件文档](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#triggering-a-workflow-from-a-workflow)。

更根本的是，现有守望流程没有 durable cursor、可 fencing 的 task lease、heartbeat、
崩溃后从 GitHub/main 重新协调的机制，亦没有把实现与独立 AI 合前 review 调度为两个
互不复用的循环。因此 branch push、PR 创建、check、review、batch 入队与 merge 观察之间
存在人工记忆和重试窗口；不确定时无法机械地 fail closed。

## What changes

- 新增受测试的 host-loop runtime。它在受控 host 上以 `--once` 轮询运行，分为
  worker loop 与 reviewer loop；两者各有 run ID、worktree 和日志/evidence 边界，
  不得复用会话来把实现结论充作独立 review。
- 定义并生成结构化 PR envelope。task-bound PR 必须有独立一行
  `Task: TASK-*`，并包含完整 `Base-OID`、`Head-OID`、decision grade、依赖、
  evidence、producer/runtime/run attribution。proposal/approval 等非 task PR 明示
  `Task: none`；该字段不会伪装成 `TASK-*`。
- 用 GitHub Issue 作为可重建的运行 cursor/批次导航，并用受限 `agent/**` namespace
  中的远端 lease ref 提供原子 claim、fencing token 和 heartbeat。Issue、digest、
  lease 均不承载批准、ready、done 或 merge 授权；canonical state 始终由
  protected-main OID、任务文件和 GitHub PR/merge metadata 复核。
- 以 least-privilege 的非 `GITHUB_TOKEN` integration identity 创建/更新 task PR，
  从而让首个 PR event 带着完整 metadata 到达 existing checks。旧 `agent-pr` bootstrap
  只会在 live migration 通过后移除，避免两套作者并发创建 PR。
- reviewer loop 仅调度并记录独立 AI 合前 review（`APPROVE` / `REQUEST_CHANGES` /
  `BLOCKED`）；它不作 GitHub approval、不 merge、不改变 change/task 状态。通过
  checks 与独立 review 后，worker 才可按 CHG-2026-027 将 digest 放入 batch Issue；
  任何 merge 均仍由维护者逐 PR 完成。
- 实现 merge-OID reconciliation：崩溃、网络失败或 heartbeat 失效后，runtime 只从
  protected `main`、PR API 和 lease fencing token 恢复；无法确认 exact merge OID、
  lease owner 或 PR identity 时停止该 lane，不推测续跑。

Out of scope / Non-goals:

- 不改变 `AGENTS.md`、Constitution、enforcement、Core spec/contract/schema、
  D0/D1/D2 或 E0/E1/E2；CORE baseline 不升版。
- 不引入 auto-merge、GitHub review approval、自动 `approved`/`ready`/`done`/
  `verified` 状态翻转，亦不把 Issue/comment/lease 当成批准载体。
- 不执行真实设备、HDC、Flash 或其他设备副作用；不把 fake/contract/live GitHub
  evidence 写成硬件或产品 conformance。
- 不在仓库内存放 token、private key、GitHub App private key、host absolute path、
  真实设备身份或未脱敏 API payload。
- 不抢占 CHG-2026-027 TASK-BAP-002 所属的 batch digest/runbook 文档；该任务未完成
  前，本 change 只能消费其已批准的治理语义，不能改写其 canonical 载体。

Observable behavior before/after:

- Before：PR body 无结构化 task/grade/evidence/dependency/base pin，首次 PR check
  可能缺席；host 守望靠临时上下文，崩溃后缺少可验证恢复点，review 不独立调度。
- After：每个 task PR 在创建时即携带可解析 envelope 并触发首个 `pull_request`
  checks；worker/reviewer 以 lease 与 cursor 协调，所有外部写均可幂等重试，merge
  只以 exact OID 确认后续跑。人工批准的信任根与 before 完全相同。

## Scope(涉及的 Requirement/AC)

- Requirements:无（canonical Core 零认领）
- Acceptance:五条 change-local：`HLR-ENVELOPE-001`、`HLR-LEASE-001`、
  `HLR-WORKER-001`、`HLR-REVIEW-001`、`HLR-RECOVERY-001`
- Contracts/schemas:repo-local runtime envelope、cursor 和 lease serialization；均不进入
  Core contract registry
- Core baseline bump:不需要

## Safety, privacy, and compatibility

- Failure modes：lease acquire/renew/release、PR lookup/create/update、Issue cursor update、
  check/review 读取或 merge-OID 查询的任一结果不确定时，停止该 task lane、保留事实，
  不 dispatch 新 work；lease 过期 takeover 必须以 remote ref 的 exact expected OID
  比较交换，fence mismatch 即停止。网络分区后的旧 owner 每次 GitHub 写前复核 fence，
  不得创建第二个 PR 或推进 cursor。
- Credentials：integration identity 的创建、权限、host scheduler 与 secret storage 是
  D2 人类动作，独立于源码实现。它仅可有完成任务所需的 `agent/**` ref、PR、Issue
  权限；不得有 main bypass、merge、review approval、Actions/branch-protection admin
  权限。其值永不入仓。该前置与 CHG-2026-027 TASK-BAP-003 凭据分离同等不可跳过。
- Privacy：cursor/evidence 只存 full Git OID、公开 PR/Issue URL、脱敏 command/result
  摘要与 runtime run ID；不复制 raw API payload、secret 或用户路径。
- Compatibility：先保留旧 workflow，直到 worker 以新身份真实创建 PR、首个 checks 与
  metadata 全部通过并有独立 review。切换时只允许一个 PR creator；rollback 是恢复已
  知健康版本的 bootstrap workflow 并停掉 host scheduler，未确认的 lease/PR 仍须先
  reconcile，不能凭分支消失推断完成。
- Platform：runtime 首版在已声明的 macOS host 上验证；Windows/Linux 没有产品行为或
  支持声明，未来 host port 记录 deferred，且不得改变上述 GitHub/治理语义。

## Approval and flow

本 proposal PR 仅登记 CHG-2026-030，零 runtime、零 evidence、零状态翻转。它作为
真实 proposal 形态，只有在实际 `pull_request` allowed-paths job 绿色时，才可由
CHG-2026-028 `MECH-004` evidence 如实引用；未出现该 run 不得预填为 live evidence。

维护者批准后，TASK-HLR-001 与 D2 的 TASK-HLR-002 可按依赖并行准备；worker migration
必须等两者 done，review/recovery 和 live pilot 再按顺序推进。每个 PR 仍独立 review/
merge；D1/D2 判断门后不做投机性成 PR 工作；change `verified` 只能在五条 acceptance
均有可复查 evidence 后以独立状态 PR 起草。

## Approval

- r1 proposal 由 PR #359 登记：proposal head
  `39b5a8f5af244b9bf82d3f654b7f954046b2513b` 经维护者 `lvye` APPROVED，
  以 merge OID `b2571fa6e30cf00594869c365c10d48946a8c9f6` 合入 protected
  `main`（2026-07-23）。该 merge 只登记 `status: proposed` 的 change package，
  不构成本 change 的正式批准或任务 ready。
- 正式批准由本 approval-only PR 将 `status: proposed → approved`，并由维护者对
  exact head review/merge 后生效。批准范围封闭为 proposal/design/tasks/verification
  r1 已列出的五项 host-only task、五条 change-local acceptance、worker/reviewer
  双循环、结构化 PR envelope、Issue cursor、fenced lease/heartbeat、legacy creator
  migration 与 merge-OID recovery。
- 批准同时接受以下不变量：protected `main` + 维护者逐 PR review/merge 仍是唯一
  批准事实；runtime 不 auto-merge、不作 GitHub approval、不自行翻转 change/task
  状态；Issue/digest/lease/reviewer result 均无批准语义；任何 fence、PR identity、
  check/review 或 merge OID 不确定都 fail closed。
- 本批准不授权 implementation。TASK-HLR-001…005 全部保持 `blocked`；各自仍须满足
  `tasks.md` 的依赖与独立 readiness。尤其 TASK-BAP-003 done、TASK-HLR-002 的 D2
  integration identity/host activation receipt、后续串行依赖与 allowed/forbidden paths
  均不可跳过。
- 本 PR 零 runtime/workflow/evidence、零 Core/spec/contract/schema/governance 正本、
  零产品/设备行为变更；CORE baseline 保持 `CORE-2.1.0`。change verified 仍须等待
  五 task done、正反 live evidence 完整及独立 verification PR。
