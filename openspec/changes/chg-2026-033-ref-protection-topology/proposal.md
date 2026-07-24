---
id: CHG-2026-033-ref-protection-topology
revision: 1
status: proposed
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
- 所有 `lvye` credential、delegated session、connector、browser session、CLI、
  keychain 与 secret storage 对 Agent 不可达；
- 枚举 Deploy Key、Actions token、GitHub App/integration identity，证明它们均不是
  CODEOWNER、admin、bypass、main push 或 human-approval actor；
- 使用 exact before/after/rollback JSON、hash、受控人类窗口和 fail-closed
  overlap-first 顺序迁移；
- 以 append-only supersession/revalidation 更新 CHG-2026-027、CHG-2026-030 与
  host-loop runbook 的 current-mechanism 指针，不改写历史 evidence。

### Out of scope / non-goals

- Constitution、Core specs/contracts、产品代码、设备或硬件行为；
- 修改 D0/D1/D2 或 E0/E1/E2 定义；
- 任何形式的 auto-merge、merge queue、自动 approval/merge；
- 让 Deploy Key、Actions、GitHub App 或 integration 获得 bypass/main push；
- 把维护者 credential 放进 Agent runtime、gateway 或 connector；
- 由 Agent 执行 ruleset、branch protection、repository setting 或 credential 变更；
- 改写历史 evidence bytes 来掩盖旧机制；
- 把本 proposal、approval 或 readiness merge 当作 D2 execution authorization。

### Observable behavior before/after

- Before：合规 PR 仍要求维护者显式 bypass ruleset。
- After：automation-authored PR 只有在 `lvye` CODEOWNER approval 与 `guard` 成功后，
  才能由 `lvye` 正常 Squash and merge，且无需选择 bypass；Agent direct-main、
  approval、merge、force-push、delete 与 auto-merge 仍不可构造或被拒绝。

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

1. 本 proposal PR：只登记方案；status 保持 `proposed`，任务保持 `blocked`，零 GitHub
   control-plane/ref/credential/probe 变更。
2. 独立 approval-only PR：`proposed → approved`。
3. 独立 CHG-2026-030 r7：supersede #449/r6 的 Agent-operated D2 gateway，明确
   #435 失效、HLR-002A blocked、ruleset setting 只由人类执行，并依赖本 change
   evidence。
4. 独立 D2 readiness PR：fresh main、完整 authenticated before、exact after/rollback
   payload、hash、操作者、窗口和 probe names。
5. 人类维护者在 Agent 外执行 exact GitHub setting 变更。
6. 独立 execution-evidence PR。
7. 独立 operability-evidence PR，记录前一 PR 的 review/check/mergedBy/merge OID 与
   正常无 bypass merge。
8. 独立 task done PR。
9. BAP-CRED-001 current-mechanism supersession/revalidation 与 CHG-2026-030 fresh
   HLR-002A readiness。
10. 五条 AC 全部有 merged、可复查 evidence 后，独立 verification PR。

本 PR 的合入不构成 approval、readiness、authorization、D2 window、done 或 verified。

## Approval

无。仅允许独立 approval-only PR 记录维护者决定。
