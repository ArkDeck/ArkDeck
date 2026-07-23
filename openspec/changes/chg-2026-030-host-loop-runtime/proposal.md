---
id: CHG-2026-030-host-loop-runtime
revision: 5
status: approved # r1 #361、r2 #405、r3 #407、r4 #415 已批准；r5 ref-boundary remediation 仅在维护者 review/merge 后生效
class: implementation-only
core_change_level: none
owner: lvye
core_baseline: CORE-2.1.0
platforms: [macos]
---

# Host-loop runtime：为 Agent PR 建立可恢复的 worker/reviewer 双循环

> r5 stop gate（2026-07-23）：TASK-HLR-002A implementation #419 已通过 offline/
> repository gates 并合入，但 post-merge live canary 的首个 reserved ref create 被
> active ruleset 以 GH013 `Cannot create ref due to creations being restricted`
> 拒绝。#421 已如实合入失败 evidence：TASK-BAP-003 ruleset exclude
> `refs/heads/agent/**` 的真实正例只覆盖单层 `agent/cred-probe`；GitHub ruleset
> `File::FNM_PATHNAME` 语义下它不覆盖多层
> `agent/host-loop/probes/<uuid>`。ordinary control 未执行，HLR-002A 不得 done，
> HLR-002 D2 继续 blocked。r5 只批准“独立 D2 readiness → 维护者 ruleset 窗口 →
> 多层正/负 ref probes → 重新 live canary”的修复边界；本 revision 零仓外写。

> r4 stop gate（2026-07-23）：TASK-HLR-002A readiness #411 后的 implementation
> candidate #412 已证明 workflow filter、首个 branch guard 与 legacy creator liveness，
> 但首个真实 `pull_request/synchronize` 的 `allowed-paths` job 失败。pinned
> `scripts/check_pr_paths.py` 只识别末段为三位数字的 task token，无法识别仓库既有
> canonical suffix task `TASK-HLR-002A`，并把固定 implementation branch 归一化为
> 非法 task。#412 fail closed、不合入；r4 只批准把 MECH-004 task-token grammar
> 对齐其既有 active task-header grammar，并要求独立 re-readiness/全新 implementation
> candidate。r4 合入前零 parser/workflow 实现、零 D2 identity/secret/scheduler/probe。

> r3 stop gate（2026-07-23）：r2 #405 已解决 GitHub permission category 的表达
> 边界，但后续勘察确认现有 `.github/workflows/agent-pr.yml` 对**每个**
> `agent/**` push 都以 `GITHUB_TOKEN` 抢先创建 PR。HLR-002 要求新 identity
> 创建 probe PR，而 bootstrap 只能到依赖 HLR-002 done 的 HLR-003 才迁移，形成
> creator 循环依赖。HLR-002 继续 `blocked`；r3 先新增 TASK-HLR-002A，把
> `agent/host-loop/**` 从 legacy bootstrap 中排除并保留其他 `agent/**` 行为，再进入
> D2 readiness。r3 合入前零 workflow/identity/secret/scheduler/probe 修改。

> r2 permission finding（已由 #405 批准）：TASK-HLR-002 readiness 勘察确认 GitHub App
> `Pull requests:write` 同时覆盖 PR 创建与 review 提交，`Contents:write` 同时覆盖
> `agent/**` ref 写与 merge endpoint；r1 的“能创建 PR/ref”与“没有 review
> approval/merge API 权限”不能由 GitHub permission manifest 同时表达。因此
> r2 把边界改为“最小平台权限 + 零批准/合并权威 + typed endpoint denylist”。

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
  只会在 live migration 通过后移除，避免两套作者并发创建 PR。r2 明确 least-privilege
  是 GitHub 平台可表达的最小 repository permission categories；runtime 仍只暴露
  typed PR/Issue/ref 操作，绝不暴露 review/merge/admin 通用请求入口。
- r3 在 D2 前先划定 exclusive creator namespace：
  `agent/host-loop/tasks/**`、`agent/host-loop/leases/**` 与
  `agent/host-loop/probes/**`。legacy `agent-pr` 对该 namespace 不运行，对其余
  `agent/**` 保持原 bootstrap 行为；`sdd-guard` 的 push 与 pull-request checks 不变。
  task/lease/probe ref 继续由 TASK-BAP-003 Deploy Key + ruleset 写入，PR/Issue 由新
  identity 写入，因此 App/API identity 不需要 `Contents:write`，merge endpoint 缺少
  所需 category。
- r4 将 HLR-002A 的 implementation scope 扩到现有
  `scripts/check_pr_paths.py`/`scripts/test_check_pr_paths.py`：task declaration token
  必须与其既有 active task-header grammar 一致，接受末段三位数字后的单个大写 suffix
  （例如 `TASK-HLR-002A`），仍须唯一解析到 active task；不得靠手工 PR body、
  错绑 `TASK-HLR-002` 或放宽 allowed paths 绕过。失败候选 #412 永久 superseded。
- r5 纠正 TASK-BAP-003 ruleset 对多层 ref 的能力假设。HLR-002A 先回到
  `blocked`；独立 D2 readiness 必须钉定 ruleset ID/完整 before JSON、现有单层
  exclude 与新增多层 exclude、维护者窗口、rollback 和单层/多层正向 +
  non-agent/main 负向矩阵。只有维护者完成仓外规则变更并 read-back，Agent 才可从
  同一 protected-main base 重新执行 reserved-first/ordinary-second canary。r5 不改
  已合入 workflow/parser，也不把 #421 的零 run/PR 误算为 creator isolation。
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
  D2 人类动作，独立于源码实现。GitHub 官方
  [App permission table](https://docs.github.com/en/rest/authentication/permissions-required-for-github-apps)
  对 PR create/review 与 ref/merge 使用共享的 write categories，不能把 endpoint
  capability 误写成更细粒度权限。因此 identity 只可取得完成任务所需的最小
  repository categories，且必须同时满足：不是 CODEOWNER、不是任何 protected-main/
  ruleset bypass actor、无 Administration/Actions/Workflows 等管理权限；runtime typed
  adapter 对 review、merge、approval、protection 与 admin route 构造数恒为 0。平台
  category 的潜在 endpoint coverage 不构成批准/合并权威；main 写、self-approval、
  merge 与 admin 的 live negative probes 仍须 fail closed。凭据值永不入仓。该前置与
  CHG-2026-027 TASK-BAP-003 凭据分离同等不可跳过。
- Ref boundary：ruleset target pattern 同属 D2 权限配置。当前
  `refs/heads/agent/**` 的单层 probe 不能外推到多层 reserved ref；修复必须保留
  `~ALL` 的 creation/update/deletion 收权、非 bypass Deploy Key 与仅维护者 bypass，
  只增加经 read-back/正负 probes 证明的 `agent` 多层 exclusion。任何 pattern 过宽、
  main/non-agent write 意外成功或 reserved create 仍被拒都立即 rollback/停链。
- Privacy：cursor/evidence 只存 full Git OID、公开 PR/Issue URL、脱敏 command/result
  摘要与 runtime run ID；不复制 raw API payload、secret 或用户路径。
- Compatibility：TASK-HLR-002A 只让 legacy workflow 忽略
  `agent/host-loop/**`，其他 `agent/**` 继续由原 bootstrap 服务；reserved namespace
  在任一时刻只允许 integration identity 这一个 creator。旧 workflow 的整体移除仍须
  等 worker 以新身份真实创建 PR、首个 checks 与 metadata 全部通过并有独立 review。
  rollback 先停 scheduler/worker，再恢复 reserved namespace 的 bootstrap coverage，
  未确认的 lease/PR 仍须先 reconcile，不能凭分支消失推断完成。
- Platform：runtime 首版在已声明的 macOS host 上验证；Windows/Linux 没有产品行为或
  支持声明，未来 host port 记录 deferred，且不得改变上述 GitHub/治理语义。

## Approval and flow

本 proposal PR 仅登记 CHG-2026-030，零 runtime、零 evidence、零状态翻转。它作为
真实 proposal 形态，只有在实际 `pull_request` allowed-paths job 绿色时，才可由
CHG-2026-028 `MECH-004` evidence 如实引用；未出现该 run 不得预填为 live evidence。

r1 的 TASK-HLR-001 已 done；HLR-002A implementation #419 已合入，但 live canary
#421 = FAIL。r5 批准后先走 HLR-002A 独立 D2 re-readiness、维护者 ruleset 窗口、
重新 live evidence 与独立 done，之后才可进入 TASK-HLR-002 D2 readiness。worker
migration 必须等两者 done，review/recovery 和 live pilot 再按顺序推进。每个 PR
仍独立 review/merge；D1/D2 判断门后不做投机性成 PR 工作；change `verified`
只能在六个 task 与五条 acceptance 均有可复查 evidence 后以独立状态 PR 起草。

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
  零产品/设备行为变更；CORE baseline 保持 `CORE-2.1.0`。该句是 r1 历史边界；
  r3 closure 以新增 HLR-002A 在内六 task、五条 acceptance 与独立 verification PR
  为准。

## r2 approval boundary

- r2 是 D1 governance-only remediation，只修改本 change 的 proposal/design/tasks/
  verification；不创建或修改 GitHub identity、token/private key、repository permission、
  ruleset、scheduler、host secret storage、PR/Issue/ref，也不执行任何 live write probe。
- 维护者 review/merge 本 revision 后，才接受“GitHub 最小 permission categories 与
  批准/合并权威分离”的边界：共享 write category 可以覆盖未使用 endpoint，但 actor
  仍非 CODEOWNER/bypass，runtime 无 review/merge/admin typed method 或 generic request，
  所有批准与合并仍只能由维护者逐 PR 完成。
- r2 不使 TASK-HLR-002 ready。其独立 D2 readiness 仍须钉定实际 identity 类型与
  repository installation scope、exact permission categories、secret storage、
  scheduler owner、rollback contact、正负 probes 和 receipt 形态；readiness 合入前
  门后零外部配置、零成 PR execution/evidence。
- HLR-003 readiness 必须把 typed endpoint allowlist 与 forbidden-route static/fault
  tests 纳入 pins；HLR-004 reviewer 继续不持 integration credential。任何 generic
  REST/GraphQL escape hatch、CODEOWNER/bypass 身份或 review/merge/admin route 可构造
  均使 lane `blocked`。

## r3 approval boundary

- 本 revision 是 D1 governance-only remediation，只改本 change 的
  proposal/design/tasks/verification；新增 TASK-HLR-002A 与 reserved namespace，
  不修改 workflow/runtime/credential/scheduler，不创建 PR/Issue/ref probe，不产生
  implementation 或 live evidence。
- 维护者 review/merge 本 PR 即批准六任务顺序、legacy bootstrap 的 namespace
  partition 目标，以及“credential staging 与 worker scheduler activation 分离”的
  边界；不使 HLR-002A/002 ready。HLR-001 done 与其既有 evidence 不重跑、不重分类。
- HLR-002A 须独立 readiness/implementation/evidence/done；只有其 live canary 证明
  reserved namespace 零 legacy creator、普通 `agent/**` bootstrap 与 `sdd-guard`
  仍健康后，HLR-002 才可起草 D2 readiness。
- HLR-002 只激活 identity/secret storage 并登记 scheduler owner/label reservation，
  receipt 必须明确 `workerDisabled=true`；实际 worker source 合入、launchd/automation
  enable 与 legacy workflow 最终迁移留给 HLR-003 的分离 source/evidence 阶段。

## r4 approval boundary

- 本 revision 是 #412 发现后的 D1 governance-only remediation，只修改本 change 的
  proposal/design/tasks/verification；不修改 workflow、MECH-004 parser/tests、
  runtime、credential、scheduler 或仓外状态，不创建新的 implementation/probe。
- 维护者 review/merge 本 revision 即批准 HLR-002A 的最小 scope 扩展：MECH-004
  task token 对齐现有 active task-header grammar，并以 fixtures 证明 suffix task
  可绑定且 malformed/ambiguous token 仍 fail closed；不批准任何 allowed-paths
  放宽、错误 task alias 或人工 metadata 绕行。
- r4 合入不使 HLR-002A ready。独立 re-readiness 必须从当时 protected `main`
  重新钉 workflow/parser/tests 与 fresh non-reserved branch，确认 #412
  `closed`、`merged=false` 且旧 branch 不复用；之后才可形成全新 implementation PR。
- HLR-002、HLR-003 及其 D2 identity/scheduler 门继续 blocked；#412 的 offline
  contract/首推事实只作为失败诊断，不得复用为新 candidate 的 PASS 或 live canary。

## r5 approval boundary

- 本 revision 是 #421 live failure 后的 D1 governance-only remediation，只修改本
  change 的 proposal/design/tasks/verification；不修改已合入 workflow/parser/tests、
  BAP-003 历史 evidence、canonical governance、runtime、identity、scheduler 或仓外
  ruleset，也不创建新的 probe/ref。
- 维护者 review/merge 本 revision 即接受：HLR-002A `ready→blocked`、多层 ruleset
  boundary 的根因定性，以及“独立 D2 readiness → 维护者配置/read-back → 正负 ref
  probes → reserved/ordinary canary → evidence → done”的顺序。r5 merge 本身不授权
  或执行仓外配置。
- D2 readiness 必须固定 active ruleset ID、完整 before conditions/rules/bypass、
  exact additive target-pattern delta、rollback、维护者窗口和四向矩阵；不能用 broad
  bypass、停用 ruleset、给 Deploy Key bypass 或删除 creation/update/deletion 收权来
  让测试通过。
- #419 的 source/repository gates 保持有效，不重写实现；#421 的 GH013、零远端
  ref/run/PR 只作为失败证据。只有 fresh live run 同时证明 nested reserved ref 可写、
  reserved legacy creator 为 0、ordinary creator 恰一且 main/non-agent 仍拒绝，
  HLR-002A 才可起草独立 done PR；此前 HLR-002/003 保持 blocked。
