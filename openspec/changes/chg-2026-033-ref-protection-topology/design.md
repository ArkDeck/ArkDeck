# CHG-2026-033 Design — fail-closed GitHub ref protection topology

> Status:draft / non-executable
> Change:CHG-2026-033-ref-protection-topology@r3

## Context and constraints

- Authority：Constitution → current specs/contracts → compatible profiles →
  approved change design/verification → code/comments。
- Core baseline：`CORE-2.1.0`；零 Core/Product behavior delta。
- 当前 ruleset ID：`19595282`；旧机制覆盖 main，导致正常 PR merge 需要 bypass。
- 当前 main 公开保护只证明 `protected=true` 与 `guard`/app ID `15368`；
  完整 reviews/admin/restrictions/force/delete 必须 fresh authenticated GET。
- #435 只对旧 HLR-002A topology、旧 base/window/payload 成立，不能重放。
- Agent 可达 `lvye` connector 是独立 stop gate；typed route promise 不能替代 credential
  removal。
- PR #449 曾把 CHG-2026-030 r6 Agent-operated constrained D2 gateway 合入；
  #456 / r7 已显式 supersede 该路径并把相关任务保持 blocked。它只保留为历史，
  不再是 executable authority。
- #467 D2 已 fail closed：Actions create+approve 组合 setting 变为 false；
  branch-protection PUT 因 `contexts` + `checks` schema 冲突返回 422；ruleset
  mutation、ref probe 与 main update 均为 0。#467 readiness/script/window/payload
  已 exhausted，不能修补或重放。
- GitHub 没有为 `GITHUB_TOKEN` 提供 repository-level “create PR yes / approve
  review no” 分离开关。r2 必须区分 platform endpoint coverage 与 repository approval
  authority，沿用 CHG-2026-030 r2 已批准的三层证明方式，而不是虚构不存在的 permission。
- #470 topology D2 已 fail closed 并由 #472 固化：单次 immediate REST ref GET
  观察到旧 OID，后续 `ls-remote` 与 #471 head 观察到预期新 OID；旧 ruleset 与
  branch-protection projection 已恢复，`main` 未变。#470 全部 pins 已 exhausted。
- #470 留下一个 exact deeper `agent/**` ref；误建的无 diff PR #471 已关闭未合并。
  后续只能在 fresh D2 中按 exact ref/OID 清理，不能用 human bypass 临时处理。

## Requirement mapping

| Requirement / AC | Design component | Verification |
| --- | --- | --- |
| `RPT-BOUNDARY-001` | Layer A ordinary-ref ruleset | authenticated read-back + live ref matrix |
| `RPT-MAIN-001` | Layer B exact-main branch protection | protection read-back + negative PR/ref matrix + normal merge pilot |
| `RPT-IDENTITY-001` | Layer C actor/capability containment | actor/permission/route inventory + negative API probes |
| `RPT-MIGRATION-001` | overlap-first state machine | timestamped before/after/rollback receipt |
| `RPT-AUDIT-001` | append-only mechanism supersession | document review + protected-main OID pointers |

## Architecture and data flow

### Layer A — ordinary-ref namespace ruleset

保留 ruleset ID `19595282`、name `agent-ref-boundary`、target `branch`、
enforcement `active`：

```yaml
conditions:
  ref_name:
    include:
      - "~ALL"
    exclude:
      - "refs/heads/agent/**"
      - "refs/heads/agent/**/*"
      - "refs/heads/main"
rules:
  - creation
  - update
  - deletion
bypass_actors:
  - actor_id: 4340161
    actor_type: User
    bypass_mode: always
```

`refs/heads/agent/**` 与 `refs/heads/agent/**/*` 同时保留，因为 GitHub ruleset 的
`fnmatch`/`FNM_PATHNAME` 语义下 `*` 不跨 `/`。Deploy Key、repository role、team、
GitHub App、Actions 或 integration 均不得进入 bypass。

### Layer B — exact-main branch protection

```yaml
required_pull_request: true
required_approving_review_count: 1
require_code_owner_reviews: true
required_status_checks:
  strict: <由 fresh before 决定，不得静默放宽>
  checks:
    - context: guard
      app_id: 15368
enforce_admins: true
restrictions:
  users: [lvye]
  teams: []
  apps: []
allow_force_pushes: false
allow_deletions: false
```

fresh authenticated before 决定所有未列字段。exact after 必须保留任何兼容且更严格
的既有设置，不能因 full-protection PUT 漏字段而静默清空。

GitHub protected-branch 语义要求：进入 push restriction 的 actor 在启用 required PR
后仍须走 PR，在 required checks 失败时仍不能 merge；管理员必须由
`enforce_admins=true` 纳入同一约束。

### Layer C — identity and repository capability containment

- repository `allow_auto_merge=false`；
- merge queue disabled；
- `CODEOWNERS` 保持 `* @lvye`，automation 永远不是 owner；
- Agent Git 只持 Deploy Key ID `158088026` 或经本 change 重新验证的 replacement；
- repository default workflow permission 保持 `read`；`agent-pr` workflow 只声明
  Contents read + Pull requests write，并以 `github-actions[bot]` 创建 PR；
- GitHub 的 `can_approve_pull_request_reviews=true` 同时开放 `GITHUB_TOKEN` 的
  create/review endpoint category；它是当前 legacy creator liveness 的必要条件，
  **不是** approval authority；
- Actions bot 不是 CODEOWNER、collaborator/admin、main push 或 ruleset bypass actor。
  它创建的 PR 作者也是同一 bot，GitHub author rule 禁止其 self-approval；即使平台
  category 可覆盖其他 review endpoint，automation review 也不能满足
  human-only `@lvye` CODEOWNER requirement；
- future HLR integration 只有 Contents read 与其必要 PR/Issue platform category，
  不得有 Contents write、merge 或 Administration；共享 Pull requests write category
  可能覆盖 review endpoint，但 typed adapter 不提供 review route，且 self-approval/
  CODEOWNER/merge authority 必须由 live negatives 证明不存在；
- 以 `lvye` 认证的 Codex/GitHub connector 必须从 ArkDeck 断开，或替换为非人类、
  read-only、non-admin、non-push identity；
- 人类维护者只在 Agent 不可达的隔离会话内执行 exact D2 plan，并在完成后退出。

## Data and contract changes

无 Core/schema migration。repository-local D2 evidence 采用：

- canonical UTF-8 JSON，object keys 排序，紧凑 separators，无 trailing LF；
- 记录 byte count 与 SHA-256；
- 完整 topology D2 对 ruleset、branch protection、repository setting 均固定完整
  before、exact after write payload 与 exact rollback write payload；bootstrap
  recovery 只固定 Actions setting，其他对象为 exact read-only invariant；
- actor inventory 记录 stable login/app/deploy-key ID、scope、permission category、
  bypass/main-push/CODEOWNER/admin membership，但不记录 credential value；
- timeout/ambiguous response 不判成功，先 authenticated read-back。

## Authority and production reachability

- Production composition root：GitHub repository ruleset + exact-main branch
  protection + repository merge settings + actor permission graph。
- Authority 产生点：只有人类 `lvye` 对 exact PR head 的 CODEOWNER review；Agent、
  Issue、CI、digest、receipt 均不能产生 approval authority。
- Effect dispatch point：人类在 requirements 全绿后点击正常 Squash and merge；
  GitHub 更新 protected main ref。
- Fake/simulation 与 production：fixture 只能验证 payload/canonicalization；不能替代
  authenticated read-back、live negative probe 或正常 merge pilot。
- Facts/provenance：GitHub authenticated GET、full Git OID、review/check/merge metadata；
  executor 自报 receipt 只作佐证。

## Proving no alternate main path

对每个 Agent 可达 actor 记录并交叉验证：

- stable actor/login/app/deploy-key ID 与 repository scope；
- repository/organization permission manifest；
- CODEOWNER、ruleset bypass、branch push restriction 与 custom-role membership；
- `contents:write`、`pull_requests:write`、Actions/Workflows、Administration；
- Agent 可调用的 typed/generic route inventory；
- PR author、review author、CODEOWNER satisfaction 与有效 approval count 分开记录，
  不把“API endpoint 存在”误判为“拥有 main approval authority”。

受控负向矩阵覆盖：

- direct Git push 与 update-ref 到 main；
- integration/Actions 对其自身 authored PR 的 review `APPROVE`；
- 任一 non-human review 是否被计为 required CODEOWNER approval；
- PR merge API；
- enable-auto-merge API；
- repository/branch/ruleset admin route；
- arbitrary commit 与手工构造 merge commit push。

PR merge REST route 需要 Contents write；因此 permission manifest、actor list、route
inventory 与 live negative 必须共同成立。Pull requests write 可能覆盖 create 与
review，这是 GitHub 平台 category 的真实边界；验证目标是 self-approval 被 author
rule 拒绝、automation review 不满足 `@lvye` CODEOWNER、merge/main/admin route
不可达，而不是宣称 review endpoint category 不存在。任一 automation review 被计为
required CODEOWNER approval、self-approval/merge 成功或其他 unexpected authority
都是 security incident：立即停链、撤销 identity、保留事实并保持/恢复更严格状态。
cleanup 不改变 FAIL。

`guard` 必须固定 app ID `15368`，不能只要求一个可被其他 writer 伪造的 context
字符串。

## One-time bootstrap recovery after #467

普通 `agent-pr` 通道在 Actions 组合 setting 为 false 时不可用，而新 governance PR
又必须由 bot author 与 human reviewer 分离，形成 bootstrap deadlock。一次性恢复只
能使用仍为 open 且 bot-authored 的既有 PR #459：

1. 无认证 public GET 与 authenticated capture 都证明 #459 head 精确为
   `d3aeeaaa8eba79526474580208dc253c4c46d26a`，作者为
   `github-actions[bot]`；其旧产品 diff 已由 main 上 #457 取代。
2. 用户显式授权以该 OID 为 `force-with-lease` expected head，从 latest main 重建
   #459；原 OID 永久进入 failure/bootstrap evidence。
3. 更新后的 #459 只承载 failure evidence、r2 mechanism revision 与 exact Actions
   transport-recovery readiness；PR title/body 必须由人类在 review 前改为真实 scope。
4. #459 merge 前所有 GitHub settings write 为 0；merge 仍需 `lvye` review、`guard`
   success，并可能因旧 ruleset 使用一次显式 human bypass。
5. merged readiness 只授权 Actions workflow setting
   `false/read → true/read`；branch protection、ruleset、repository merge setting、
   credential、ref probe、review/merge state mutation预算均为 0。
6. transport 恢复并形成独立 evidence PR 后，完整 topology migration 必须从新的
   protected main 重新 discovery/readiness，不得继承本 bootstrap 的 OID/window/hash。

这个 carrier collapse 是 availability recovery，不把聊天指令升级为 governance
approval；权威仍只来自 `lvye` 对更新后 #459 exact head 的 review/merge。

## Failure, cancellation, and recovery

```text
discover
  -> quiesce
  -> containHumanCredentials
  -> strengthenMainProtection
  -> authenticatedReadbackMain
  -> negativeMainProbeUnderOverlap
  -> excludeMainFromOrdinaryRuleset
  -> authenticatedReadbackRuleset
  -> repeatNegativeMainProbeUnderBranchProtectionOnly
  -> cleanupPinnedResidualRef
  -> negativeRefAndAPIMatrix
  -> normalHumanMergePilot
  -> evidence

any ambiguity/failure
  -> classifyMainAndBothProtections
  -> cleanupControlledAgentRefsWhenMainProtectionIsExact
  -> restoreMainRulesetCoverage
  -> verifyMainCoverage
  -> restoreOtherBeforeStateIfSafe
  -> blocked
```

顺序解释：

1. 旧 ruleset 持续覆盖 main。
2. 强化 main branch protection，完整 authenticated read-back。
3. 完成 human-credential containment 与 actor inventory。
4. Deploy Key direct-main negative 在双层重叠时先跑一次；该结果只证明 overlap
   fail-closed，不能单独归因于 branch protection。
5. 只有前述门全过，才把 exact main 加入 ruleset exclusion。
6. ruleset immediate read-back 后重复同一 negative；第二次才是 branch protection
   在 ruleset 不覆盖 main 时明确拒绝 Deploy Key 的因果证据。
7. 人类隔离 admin session 在两项 mutation、read-back 与 immediate negatives 完成后
   才退出，且从未暴露给 Agent。

### Probe transport, convergence and workflow isolation

Temporary ref probes are not governance PR branches. Every positive
create/update tip commit SHALL contain the exact GitHub skip instruction
`[skip actions]`. Preflight SHALL pin all repository workflow blobs and prove
that no workflow uses an event outside `push`/`pull_request` that ignores this
instruction. The multi-level positive additionally uses the already excluded
`agent/host-loop/**` namespace. No workflow file, Actions setting or workflow
enabled state is modified. This mechanism follows GitHub's documented
[`push`/`pull_request` skip instructions](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/skip-workflow-runs);
the live preflight remains authoritative over documentation alone.

For each successful create/update:

1. require exit 0 plus the expected server-side Git push receipt;
2. poll `git ls-remote --refs` within an exact readiness-pinned budget until
   two consecutive observations equal the expected OID;
3. poll authenticated Git-ref REST within the same bounded budget until it
   converges to the expected OID;
4. assert no PR, Actions run or unexpected ref was created for the probe.

A single stale REST observation is recorded but is not drift while the bounded
convergence gate remains open. Timeout, persistent transport disagreement,
unexpected workflow/PR creation or a ref moving to any third OID is ambiguous
and fails closed. Delete uses the symmetric two-observation absent check plus
REST 404. DNS, authentication, transport failure or local inference is never
a positive result.

The exact residual #470 ref/OID is allowed as the sole preexisting controlled
ref in the next preflight. It is deleted with the Deploy Key only after main
branch protection is exact after, the ruleset exact after excludes both Agent
patterns and main, main is unchanged, and #471 is closed/unmerged. Its absence
is required before fresh probe names are used.

上述 state machine 只适用于后续完整 topology D2。bootstrap recovery 使用更窄的
`read exact before → write Actions true/read → authenticated read-back → logout`
state machine，且完全不进入 `strengthenMainProtection` 或
`excludeMainFromOrdinaryRuleset`。

任一阶段取消或 API outcome 不确定：零盲写重试。若 branch protection exact after、
main 未变且不存在 main negative unexpected success，controlled Agent ref cleanup
先在 after-ruleset 仍允许 deletion 时执行，随后恢复 ruleset main coverage并验证，再
恢复 branch protection before。若 main 或 branch-protection state 未知、main negative
unexpected success，优先恢复 ruleset coverage或保留更严格 branch protection；不得为了
清理 ref 推迟 main recovery。无法在安全条件下清理的 ref 作为 exact residual 报告，不能
用未固定的人类 bypass 补删。cleanup 永不把 failed run 变成 PASS。

## Security and privacy

- raw human credential/App private key 永不进入 repository、Agent process、gateway、
  environment、CLI、keychain、browser storage、log 或 evidence；
- authenticated before 可在维护者隔离环境采集；只把 secret-free JSON 与 hash
  带入 readiness；
- evidence 对 response body 做字段级脱敏，但保留 actor ID、setting、hash、时间、
  HTTP/Git error class 和 OID；
- Agent 不得创建、修改、批准或执行 standing authorization；本 change 不建立
  privileged gateway；
- 真实 main force/delete 不做“试试看”。只有 readiness 能证明 request 必在 mutation
  前被拒且 rollback exact 时才允许；否则该 AC 保持 blocked，以 authenticated setting
  + non-bypass actor negative 佐证。

## Replaced mechanism descriptions

历史事实原文保持不可变，current-mechanism pointer 需要 append-only addendum：

- CHG-2026-027 proposal 的 `BAP-CRED-001` closure；
- CHG-2026-027 TASK-BAP-003 current status note；
- CHG-2026-027 TASK-BAP-003 run evidence；
- `openspec/governance/host-loop-runbook.md` 中把全部 non-Agent ref 拒绝归因于
  ruleset 的描述；
- CHG-2026-030 proposal/design/tasks/verification r5/r6 中的 old single-ruleset
  topology、Agent-operated D2 candidate 与所有 HLR-002A readiness；
- #435 的 OID、window、before、after/rollback payload/hash、ref names、UUID 与
  executor script。

`openspec/governance/enforcement.md` 与 `AGENTS.md` 表达的是高层不变量，不依赖旧
GitHub mechanism；除非 review 发现真实语义歧义，否则保持逐字不动。

## Alternatives and ADRs

- 保留旧 ruleset、把红色 bypass 视为正常：拒绝；异常路径失去审计意义。
- 给 Deploy Key/Actions/App bypass：拒绝；直接违反凭据隔离。
- maintainer bypass 改为 pull-request-only：拒绝；仍把正常 merge 建模为 bypass，
  且不解决 human-token exposure。
- 全局移除 `update` rule：拒绝；ordinary ref update 失去保护。
- 先排除 main 再验证 branch protection：拒绝；产生未验证窗口。
- 只做 branch protection、不移除 Agent 可达 `lvye`：拒绝；GitHub 无法区分调用者。
- 只靠 typed-adapter source scan：拒绝；当前通用 connector 已暴露 privileged route。
- #449/r6 的 Agent-operated constrained D2 gateway：提议由 CHG-2026-030 r7
  supersede；它扩大了 Agent production reachability，并偏离用户明确的人类执行边界。
- 关闭 Actions 组合 setting、同时继续依赖 `GITHUB_TOKEN` 创建 PR：拒绝；GitHub
  不提供该组合，#467 后 live failure 已证实 creator 被一并关闭。
- 把 `can_approve_pull_request_reviews=true` 等同于 automation approval authority：
  拒绝；共享 endpoint category 仍受 PR author rule、human-only CODEOWNER、main
  protection 与 actor exclusion 约束。
- 在 bootstrap carrier 中顺手修复 `contexts` + `checks` 或修改 topology：拒绝；这会
  越过一次性 recovery scope。后续独立 topology readiness 只能使用 `checks` form，
  并重新固定全部 before/after/rollback。

无需新增产品 ADR；治理决定由本 change 的 proposal/design/git history 承载。
