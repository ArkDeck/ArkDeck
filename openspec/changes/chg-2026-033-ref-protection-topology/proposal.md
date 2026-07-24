---
id: CHG-2026-033-ref-protection-topology
revision: 3
status: approved # r3 仅在独立 approval-only PR #474 经 lvye review/merge 后生效；proposal #473 merge 6153d581d7caf1bd1ed3335171318b3e92250926
class: implementation-only
core_change_level: none
owner: lvye
core_baseline: CORE-2.1.0
platforms: [macos]
---

# GitHub ref 权限保护拓扑：分离 Agent namespace 收权与 main PR enforcement

## Why

当前 repository ruleset `agent-ref-boundary`（ID `19595282`）对除
`refs/heads/agent/**` 以外的全部 branch ref 应用 `creation`、`update`、`deletion`
restriction。GitHub 把正常 PR merge 也视为 `refs/heads/main` 的 update，因此维护者
合并一个已经由 CODEOWNER 审批且 `guard` 通过的 PR 时，仍必须选择红色
“Merge without waiting for requirements to be met (bypass rules)”。

这使例外 bypass 变成日常正常路径，削弱 bypass 的审计信号。需要把两个不同职责拆开：

1. ordinary ref 与 Agent namespace 的边界继续由 ruleset 收权；
2. `main` 的 PR、review、status check 与 merge 约束由 exact-main branch protection
   单独执行。

本 change 的只读 discovery 还发现一个更高优先级的凭据问题：当前 Agent 可达的 Codex
GitHub connector 以人类维护者 `lvye` 身份认证，repository metadata 报告
`admin=true`、`maintain=true`、`push=true`，且 Agent-callable surface 包含 review
`APPROVE`、ref update、merge 与 enable-auto-merge。GitHub 无法区分“人类 lvye 点击”
与“Agent 使用 lvye user credential”。任何 ref 拓扑都不能在该身份仍可达时证明
human-only approval。

因此候选“两层保护”只有在第三层“身份与 capability containment”同时成立时才完整。

并发治理事实：proposal 起草期间 PR #449 已合入 protected main
`490412f0da3ab29fee254643f0844b705a9e1b1a`，使 CHG-2026-030 r6 成为当前 approved
revision。r6 允许 Agent 在 standing authorization 下经 constrained gateway 修改
ruleset，这与本 change 的“GitHub 设置变更由人类维护者在 Agent 外执行”边界冲突。
因此本 change 获批后，必须先以独立 CHG-2026-030 r7 supersede 该 r6 D2 路径；
r7 合入前，r6 gateway/readiness/execution 的 dispatch 必须为 0。

### r2 bootstrap finding

#467 D2 执行在 fail-closed 顺序中先把 repository workflow setting
`can_approve_pull_request_reviews` 从 `true` 改为 `false`，随后 branch-protection
PUT 因同时发送 legacy `contexts` 与 App-bound `checks` 被 GitHub 以 HTTP 422 拒绝。
ruleset 与 main protection 没有被修改，旧 ruleset 继续覆盖 main。

后续实测与 GitHub 官方 setting 语义共同证明：
`can_approve_pull_request_reviews` 是 “Allow GitHub Actions to **create and approve**
pull requests” 的组合开关，不存在 repository-level create-only 取值。设为 `false`
同时切断 `.github/workflows/agent-pr.yml` 使用 `GITHUB_TOKEN` 创建 bot-authored PR
的既有治理通道。失败证据 branch 的 `guard` 成功而 `open-pr` 失败，且没有生成 PR。

这不改变高层不变量，但推翻 r1 readiness 的低层假设。GitHub permission category
可能覆盖 review endpoint，并不等于 automation 拥有批准权威；current enforcement
必须由以下事实共同闭合：

- Agent 草案 PR 的唯一作者是 `github-actions[bot]`；
- GitHub 禁止 PR 作者批准自己的 PR；
- 唯一 CODEOWNER 仍是人类 `lvye`；
- Actions bot 不是 CODEOWNER、collaborator/admin、ruleset bypass 或 main push actor；
- main 仍要求人类 CODEOWNER approving review、`guard`，并禁止 auto-merge。

普通新 PR 已无法创建。用户明确授权将仍为 bot-authored/open、head 精确为
`d3aeeaaa8eba79526474580208dc253c4c46d26a` 的 #459 作为一次性 bootstrap
载体，并允许在 expected-head 无漂移时以最新 main 为 base 替换其旧产品 diff。该聊天
授权只允许安全重建载体；**只有更新后的 #459 经 `lvye` review/merge 才批准 r2
机制修订与其中 exact bootstrap D2 readiness**。

### r3 topology execution finding

#470 的完整 topology D2 已真实执行并 fail closed。branch protection after、ruleset
after、双层/branch-protection-only main negative、single-level Agent ref
create/update/delete，以及 multi-level Agent ref create/update 的 server receipts 均成功；
`main` 全程保持
`928d6e06b928e16874df9137950a9830aa38d8d0`。失败发生在 multi-level update 后：
Git push 已成功，但紧随其后的单次 Git-ref REST GET 暂时返回更新前 OID，执行器把它
判为 drift 并回滚。稍后独立 `git ls-remote` 与 #471 head 都观察到预期更新后 OID。
这与 read-after-write 可见性延迟一致，但只能作为原因推断，不能把失败 run 改判 PASS。

回滚重新让旧 ruleset 覆盖 main，branch-protection write projection 也恢复 before；
完整 branch-protection JSON 因 GitHub materialize 空
`dismissal_restrictions` 而未逐字节复现旧 capture。因此后续必须 fresh authenticated
capture，不能复用 #470 的 full hash。

执行还暴露两个副作用：

- multi-level probe 创建触发 `agent-pr`，自动生成无 diff 的 #471；#471 已于
  `2026-07-24T11:00:50Z` 关闭且从未合并；
- rollback 先恢复 old ruleset 后，Deploy Key 无法删除 deeper probe ref。该 ref 仍固定为
  `refs/heads/agent/rpt001/deep/7908274d-d874-47d6-b844-c2e35ba9d2a9` /
  `2e1e5ce85266f96f54eb60d9f2547398d1c9b3e7`，只能由新的 exact D2 plan 在安全
  after-ruleset 状态内清理。

#470 readiness、executor、window、payload/hash 与全部 probe UUID 均已 exhausted。
#472 merge
`398a1e9f14ebf0debe785591f4f7517b54e16b26` 只固化失败事实，不批准 r3 或新 D2。

## What changes

### In scope

- 保留 ruleset `19595282` 的 `~ALL`、active enforcement、creation/update/deletion
  restrictions 与仅人类 `lvye` bypass；
- ruleset exclusion 固定为：
  - `refs/heads/agent/**`；
  - `refs/heads/agent/**/*`；
  - exact `refs/heads/main`；
- exact main exclusion 只在 main branch protection 已先强化且 authenticated
  read-back 完整通过后写入；
- main branch protection 独立要求：
  - pull request；
  - 至少 1 个 approving review；
  - CODEOWNER review；
  - required check `guard`，固定 GitHub Actions app ID `15368`；
  - `enforce_admins=true` / 不允许管理员 bypass requirements；
  - push restriction users 仅 `lvye`，teams/apps 为空；
  - force-push 与 deletion 禁止；
- repository auto-merge 关闭；merge queue/自动审批/自动 merge 不进入方案；
- legacy `agent-pr` 仍以 `github-actions[bot]` 创建普通 `agent/**` PR；由于 GitHub
  只有 create+approve 组合开关，repository setting 保持/恢复为 `true`，但该平台
  endpoint coverage 不构成批准权威，self-approval 与有效 CODEOWNER approval
  仍由作者分离 + human-only CODEOWNER + main protection 阻断；
- 所有 `lvye` credential、delegated session、connector、browser session、CLI、
  keychain 与 secret storage 对 Agent 不可达；
- 枚举 Deploy Key、Actions token、GitHub App/integration identity，证明它们均不是
  CODEOWNER、admin、bypass、main push 或 human-approval actor；
- 使用 exact before/after/rollback JSON、hash、受控人类窗口和 fail-closed
  overlap-first 顺序迁移；
- positive ref probe 的每个 pushed tip commit 固定包含 GitHub 支持的
  `[skip actions]`，并在 preflight 固定全部 workflow trigger，防止临时 probe
  触发 `agent-pr` 或创建 PR；这不修改 workflow、Actions setting 或 main；
- successful ref mutation 以 Git server receipt + bounded `git ls-remote` +
  bounded Git-ref REST convergence 交叉验证；单次即时 stale REST observation 不再
  直接升级为 drift，超出固定收敛预算或两通道持续矛盾仍 fail closed；
- residual #470 deeper probe ref 作为唯一具名 preexisting controlled ref，在新
  ruleset after 已 authenticated read-back、branch protection 已知 exact after 且 main
  未变后由 Deploy Key 删除；不得用 `lvye` bypass 或替换 ref/OID；
- 非 main-security failure 时，若 branch protection exact after 且 main 未变，先在
  after-ruleset 下清理全部 controlled Agent refs，再恢复 ruleset main coverage；
  main state 未知或 negative unexpected success 时仍优先恢复/保留更严格 main protection；
- 以 append-only supersession/revalidation 更新 CHG-2026-027、CHG-2026-030 与
  host-loop runbook 的 current-mechanism 指针，不改写历史 evidence。

### Out of scope / non-goals

- Constitution、Core specs/contracts、产品代码、设备或硬件行为；
- 修改 D0/D1/D2 或 E0/E1/E2 定义；
- 任何形式的 auto-merge、merge queue、自动 approval/merge；
- 让 Deploy Key、Actions、GitHub App 或 integration 获得 bypass/main push；
- 把 `can_approve_pull_request_reviews=true` 误写为 Actions 已获得 CODEOWNER、
  main merge 或 self-approval authority；
- 把维护者 credential 放进 Agent runtime、gateway 或 connector；
- 由 Agent 执行 ruleset、branch protection、repository setting 或 credential 变更；
- 改写历史 evidence bytes 来掩盖旧机制；
- 把 r1 proposal/approval 或任一 superseded readiness merge 当作 D2 execution
  authorization；
- 在一次性 bootstrap readiness 下修改 ruleset、main branch protection、repository
  merge setting、credential、ref protection 或任何 PR review/merge 状态。
- 为 probe 修改 `.github/**`、临时关闭 workflow/Actions、使用 workflow
  disable/enable API，或把自动生成 PR 当作允许的清理副作用。

### Observable behavior before/after

- Before：合规 PR 仍要求维护者显式 bypass ruleset。
- Bootstrap failure state：main 完整性仍由旧 ruleset 保持，但 Actions PR creator
  不可用，普通 governance PR 无法新建。
- Bootstrap recovery after：只恢复 bot-authored PR transport；ruleset 与 main
  protection 保持原样，完整两层 topology 仍等待后续独立 fresh D2 readiness。
- After：automation-authored PR 只有在 `lvye` CODEOWNER approval 与 `guard` 成功后，
  才能由 `lvye` 正常 Squash and merge，且无需选择 bypass；Agent direct-main、
  self-approval、有效 CODEOWNER approval、merge、force-push、delete 与 auto-merge
  authority 仍不可构造或被拒绝。

## Scope(涉及的 Requirement/AC)

- Requirements：无；canonical Core requirement 与 Safety invariant 零修改。
- Acceptance：五条 change-local：
  `RPT-BOUNDARY-001`、`RPT-MAIN-001`、`RPT-IDENTITY-001`、
  `RPT-MIGRATION-001`、`RPT-AUDIT-001`。
- Contracts/schemas：仅 repository-local canonical JSON/hash/evidence 记录格式；
  不进入 Core contract registry。
- Core baseline bump：不需要。

## Safety, privacy, and compatibility

- missing authenticated field、unexpected actor、main/ref/blob drift、overlapping
  control-plane operation、hash mismatch、API ambiguity 或 negative probe unexpected
  success，任一发生立即停链；
- branch protection 在旧 ruleset 仍覆盖 main 时先强化、read-back 与负向预检；
  exact main 只有在这些门通过后才从 ruleset 排除；
- ruleset 修改后任一失败，rollback 先恢复 main 的 ruleset coverage 并验证，再处理
  branch protection/repository setting；不得留下双层同时缺失的窗口；
- token、key、cookie、browser storage、private path、Authorization header 与 raw
  secret-bearing payload 不进入 Git、evidence、日志或 Agent output；
- 本 change 零产品/platform conformance 影响；macOS 只是当前受控 host，
  Windows/Linux 不形成支持声明。

## Approval and flow

1. r1 proposal/approval、CHG-2026-030 r7、TASK-RPT-001 ready 与 #467 readiness
   保留历史；#467 execution 已 fail closed 且永久 exhausted。
2. 一次性 bootstrap carrier #459 只包含失败证据、r2 机制修订与恢复 PR transport
   的 exact D2 readiness。载体复用/阶段合并是由通道自身失效造成的封闭例外，必须在
   PR title/body/review 中显式披露；它不允许 topology mutation。
3. #459 经 `lvye` review/merge 后，人类维护者在 Agent 不可达的隔离 session 中只把
   Actions 组合 setting 从 exact `false/read` 恢复为 exact `true/read` 并 read-back。
4. human session logout、Agent credential containment 复核后，以普通
   `agent-pr` 通道创建并合入独立 failure/execution evidence PR。
5. 从届时最新 protected main 重新执行正常序列：独立 proposal/mechanism follow-up
   （若需要）→ approval-only → fresh topology D2 readiness → human execution →
   execution evidence → operability evidence → done。
6. 后续 topology readiness 的 branch-protection payload 使用 App-bound
   `checks` **而不同时发送 legacy `contexts`**；全部 before/after/rollback/hash、
   window、nonce、OID 重新固定。
7. TASK-RPT-002、BAP-CRED-001/HLR supersession 与最终 verification 继续保持原依赖。
8. #470 execution 与 #472 failure evidence 保留历史；r3 proposal revision 先登记
   ref convergence、workflow suppression、conditional cleanup 与 residual-ref
   cleanup 机制。r3 只有在后一独立 approval-only PR 经 `lvye` review/merge 后成为
   approved/current；在此之前 TASK-RPT-001 回到 `blocked`，D2 dispatch 为 0。
9. r3 approval 后，从当时最新 protected main 做 fresh authenticated discovery；再以
   独立 D2 readiness 固定新的 main/PR/blob/ref/settings、normalized full branch
   protection before、exact after/rollback、全新 UUID、收敛预算、operator 与窗口。

历史 r1 proposal carrier #453 的合入不构成 approval、readiness、authorization、
D2 window、done 或 verified；r2 #459 的精确授权边界以下文为准。

## Approval

- r1 proposal carrier：PR #453，head
  `acb3e618b021cab128306341d7bedd62feef7a2c`，由维护者 `lvye` 合入 protected main
  `cecca155fa74a3304fa3d4b7b0ac8fcccc591f1d`。该 merge 只登记 proposal，不构成
  approval。
- 历史 approval-only PR #455 的维护者 review/merge 构成对下列范围的批准：
  - Layer A ordinary-ref ruleset、Layer B exact-main branch protection、Layer C
    identity/repository capability containment 三层缺一不可；
  - ruleset、branch protection、repository setting 与 credential 变更只由人类维护者
    在 Agent 不可达的隔离 session 中执行；
  - 先以 CHG-2026-030 r7 supersede #449/r6 Agent-operated D2 gateway，再进入
    TASK-RPT-001 独立 readiness；
  - overlap-first migration、双 direct-main negative、ruleset-first rollback 与
    execution/operability/done evidence separation；
  - enforcement.md、AGENTS.md、Constitution 与 Core specs/contracts 零修改。
- #455 merge 本身不使 TASK-RPT-001/002 `ready`，不创建 D2
  authorization/window，不批准 payload/probe，不修改任何 GitHub
  control-plane/ref/credential，也不构成 `done`/`verified`。
- r2 bootstrap carrier #459 的维护者 review/merge 仅批准：
  - 本 proposal 的 platform-capability 机制修订；
  - `d2-readiness.md` 中一次 exact Actions transport recovery；
  - 将 #459 的旧 head 作为 superseded historical OID，并接受一次性载体复用事实。
- r2 merge 不批准 ruleset、branch protection、repository merge setting、credential、
  probe ref、review、merge 或 auto-merge mutation；不构成 TASK-RPT-001 `done` 或
  change `verified`。
- r3 proposal carrier 只登记机制修订与作废 #470 readiness，不批准任何 GitHub
  control-plane/ref/PR-state write，不把成功的子 probe 改判为 AC PASS，也不使
  TASK-RPT-001 `ready`。r3 的批准必须由后续独立 approval-only PR 完成。
- r3 proposal carrier #473 由 `github-actions[bot]` 创建，exact head
  `9c359396ca1cdd7355ea2c0c3d28e988335ad49b`、base
  `398a1e9f14ebf0debe785591f4f7517b54e16b26`，经 `lvye` 对该 head
  `APPROVED`、`guard`/Swift success 后，由 `lvye` 于
  `2026-07-24T11:20:17Z` 合入 protected main
  `6153d581d7caf1bd1ed3335171318b3e92250926`。该 merge 只登记 r3 proposal。
- 独立 r3 approval-only PR #474 经 `lvye` review/merge 后，批准的新增范围仅为：
  - Git push receipt + bounded stable `ls-remote` + authenticated REST convergence；
  - positive probe tip `[skip actions]`、workflow trigger/blob pin 与零 run/PR assertion；
  - 在 exact after main protection 下的 controlled-ref-first conditional cleanup；
  - 在后续 fresh D2 中按 exact name/OID 清理 #470 residual ref；
  - #470/#471/#472 的历史/stop boundary 与全新 D2 pins 要求。
- r3 approval 不改变 Layer A/B/C、高层治理不变量或五条 AC；不批准任何 current
  before/after/rollback payload、hash、window、operator action、control-plane/ref/
  PR-state mutation，也不构成 AC PASS、task `done` 或 change `verified`。它只允许
  TASK-RPT-001 进入 `ready` 并在下一独立 PR 从届时最新 protected main 起草 D2
  readiness。
