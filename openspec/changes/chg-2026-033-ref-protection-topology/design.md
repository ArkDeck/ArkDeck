# CHG-2026-033 Design — fail-closed GitHub ref protection topology

> Status:draft / non-executable
> Change:CHG-2026-033-ref-protection-topology@r1

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
- PR #449 已合入为 CHG-2026-030 r6 approved authority；其中 Agent-operated
  constrained D2 gateway 与本 proposed design 冲突。由于本 change 尚未 approved，
  任何受影响实现都必须停止；本 change 获批后再以 CHG-2026-030 r7 显式 supersede。

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
- `agent-pr` Actions token 只有 Contents read + Pull requests write，不是
  main-push/bypass actor；
- future HLR integration 只有 Contents read 与其必要 PR/Issue capability，
  不得有 Contents write、review approval、merge 或 Administration；
- 以 `lvye` 认证的 Codex/GitHub connector 必须从 ArkDeck 断开，或替换为非人类、
  read-only、non-admin、non-push identity；
- 人类维护者只在 Agent 不可达的隔离会话内执行 exact D2 plan，并在完成后退出。

## Data and contract changes

无 Core/schema migration。repository-local D2 evidence 采用：

- canonical UTF-8 JSON，object keys 排序，紧凑 separators，无 trailing LF；
- 记录 byte count 与 SHA-256；
- ruleset、branch protection、repository setting 均固定完整 before、exact after
  write payload 与 exact rollback write payload；
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
- Agent 可调用的 typed/generic route inventory。

受控负向矩阵覆盖：

- direct Git push 与 update-ref 到 main；
- GitHub review `APPROVE`；
- PR merge API；
- enable-auto-merge API；
- repository/branch/ruleset admin route；
- arbitrary commit 与手工构造 merge commit push。

PR merge REST route 需要 Contents write；因此 permission manifest、actor list、route
inventory 与 live negative 必须共同成立。任一 unexpected success 都是 security
incident：立即停链、撤销 identity、保留事实并保持/恢复更严格状态。cleanup 不改变
FAIL。

`guard` 必须固定 app ID `15368`，不能只要求一个可被其他 writer 伪造的 context
字符串。

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
  -> negativeRefAndAPIMatrix
  -> normalHumanMergePilot
  -> evidence

any ambiguity/failure
  -> restoreMainRulesetCoverage
  -> verifyRestore
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

任一阶段取消或 API outcome 不确定：零盲重试。ruleset 已修改时先恢复 main coverage；
恢复已验证后，才可在不削弱不变量的前提下恢复其他 before。无法安全恢复则保留更严格
状态并上报 incident。

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

无需新增产品 ADR；治理决定由本 change 的 proposal/design/git history 承载。
