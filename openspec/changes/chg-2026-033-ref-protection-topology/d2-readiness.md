# TASK-RPT-001 D2 readiness

> Status:PROPOSED / NON-EXECUTABLE UNTIL THIS EXACT FILE IS REVIEWED AND MERGED
>
> 本文件只固定一次性 D2 plan。PR 合入前 control-plane write、probe ref mutation 与
> Agent privileged dispatch 均为 0。合入后仍须先通过 credential containment、fresh
> read-back、drift 与 overlap gates；任何 gate 失败均为零 dispatch。

## A. Authority, capture and concurrency pins

```yaml
schema: arkdeck-rpt001-readiness/v1
audit_time_utc: 2026-07-24T04:49:22.184539Z
discovery_schema: arkdeck-rpt001-discovery/v2
discovery_api_version: 2026-03-10
discovery_classification: GET-only; zero credential values; zero external writes
captured_by:
  login: lvye
  id: 4340161
  type: User
  site_admin: false
protected_main_oid_at_capture: 60ea5266e506f88b81c0ef8a2c6744c770b5b3d5
readiness_base_oid: 5b41a15391256d9adcc3a5a316654971c9aab57e
change_approval_merge_oid: c86f07ae6b843affaaa3f698e2f9f08a6f4c96cd
compatible_chg030_r7_merge_oid: c5a1a9f0f1c0a9bc0dd3d04275ac01a5738697f7
ruleset_id: 19595282
```

`readiness_merge_oid` 在本 PR 合入前不存在。执行 preflight 必须从受保护 `main` 的
GitHub merge facts 取得本 PR 的完整 merge OID，并证明当前 `main` 仍等于该 OID；
不得由 PR head、短 SHA 或本地推测替代。

固定 blob：

| Path | Blob OID |
| --- | --- |
| `.github/CODEOWNERS` | `f4edd22f87965efcfc27ea512283a0c2252bf0fb` |
| `.github/workflows/agent-pr.yml` | `41426544637db25224dc6c6b3718abd4ebbfca7c` |
| `.github/workflows/sdd-guard.yml` | `809147e462512d970813d1992a3fcdf41f8b4b10` |
| `AGENTS.md` | `3c2d3c6a01d3eaa31cd9e3ee333f3153552f4164` |
| CHG-2026-030 `design.md` | `7e2e20bfb884875de32cbbeb5f0399df7a137056` |
| CHG-2026-030 `proposal.md` | `890a40585b2898c0fd9e7d2b72f5b2a8e81b515c` |
| CHG-2026-030 `tasks.md` | `7fc3c14bb207facec9d330a8d74b23fb9aefdb58` |
| CHG-2026-030 `verification.md` | `49f284b397006fa8626e76ec2fa51f5d9a88e307` |
| CHG-2026-033 `design.md` | `be556c61967101b1b66c85cb2b19aa7cae428bcd` |
| CHG-2026-033 `proposal.md` | `8a98c95fdb24029c1ac13325578f2800eae8018c` |
| CHG-2026-033 `tasks.md` | `dc021364f6aa0fb221047f1b362c68a3c5f1f56a` |
| CHG-2026-033 `verification.md` | `a8a6dc71221850a3f965e8ee2a964150296262a2` |
| `openspec/governance/enforcement.md` | `e8ff3c130e1b8b15f8405d150ad567e774a0d82b` |
| `openspec/governance/host-loop-runbook.md` | `70e0bcc5b736a896f0329e24a89e273164762558` |

本文件的 blob OID 必然由 readiness merge 改变，不与 capture 值比较；执行时改为固定
merged readiness blob OID。其余表中 blob 必须与 capture 一致。
pin-blobs artifact 为 1,716 bytes，SHA-256
`1d92ff061ddc0047513ee311760bd895982507fcb37fc7ce71d0bb5e15d53e81`。

capture 时存在三个不重叠的开放 PR：

| PR | Head | Overlap decision |
| --- | --- | --- |
| #457 | `agent/au-002-implementation` | 不涉及 `.github/**`、CHG-2026-030/033、governance、ruleset 或目标 refs |
| #459 | `agent/task-au-002-update-runtime` | 不涉及 `.github/**`、CHG-2026-030/033、governance、ruleset 或目标 refs |
| #461 | `agent/rkfui-001a-crlf-readiness` | 只涉及 CHG-2026-026，不涉及本 D2 sensitive inputs、control-plane 或目标 refs |

开放 PR artifact 为 3,271 bytes，SHA-256
`fa85d62b05dd371945dd885c36ce3eae8d07788928cdd9776c1dd0cc826f5eee`。
#461 在 capture 后合入为 readiness base `5b41a15391256d9adcc3a5a316654971c9aab57e`；
其 changed-files 与本 D2 零 overlap，且表中全部 sensitive blob OID 保持不变。
非重叠 PR 不要求关闭；若它们或新 PR 在执行窗口修改上述 pinned inputs、目标 refs、
ruleset/protection/repository setting 或本 readiness，立即停止。capture 时所有远端
branch ref 仅为 `agent/**` 与 `main`，无 non-Agent/non-main ref；remote-ref artifact
为 1,161 bytes，SHA-256
`e782d6268f6410f501f5ad03d9afff37c300f9b7026f7aaec7027d30540e6dea`。

## B. Authenticated before artifacts

canonicalization 为 UTF-8、object keys 排序、separators `(',', ':')`、无 trailing LF。
下表与后续 literal bytes 一一对应：

| Artifact | Bytes | SHA-256 |
| --- | ---: | --- |
| `active_main_rules` | 335 | `560eff7e8ecceb7b044a19634c7e559a8b0411b486717a97c05896246a3c7137` |
| `actor_inventory` | 4,520 | `feb3e80c5b5070136fbc423a459fb8111d9b352c559cb2c09eb8cf041cfddfac` |
| `branch_protection_full` | 1,227 | `e45fb8583eb8002e49fcd402c0d9026f7277a1b823b6fe7410695da5666f0b0c` |
| `organization_settings` | 482 | `db3047ad7868abfb58303681c011c7c6a4ebe79de8a7d0e3166760320d297b09` |
| `repository_settings` | 660 | `8f605ec84f4d83ef6a860c238e1c506cacd1ab8c85ecb90448bdf2a684daf3f7` |
| `ruleset_full` | 702 | `a5725db245d84174090de47e1fc45123219dbf5cfdd00d45856b04d801a3d5f2` |
| `rulesets_full` | 438 | `a603d5a0af93112475f4e92a597b16c515b9eebe320cbab98f7bd26b0d9487b0` |

### `ruleset_full`

```json
{"_links":{"html":{"href":"https://github.com/ArkDeck/ArkDeck/rules/19595282"},"self":{"href":"https://api.github.com/repos/ArkDeck/ArkDeck/rulesets/19595282"}},"bypass_actors":[{"actor_id":4340161,"actor_type":"User","bypass_mode":"always"}],"conditions":{"ref_name":{"exclude":["refs/heads/agent/**"],"include":["~ALL"]}},"created_at":"2026-07-23T10:20:11.391+08:00","current_user_can_bypass":"always","enforcement":"active","id":19595282,"name":"agent-ref-boundary","node_id":"RRS_lACqUmVwb3NpdG9yec5Na16-zgErABI","rules":[{"type":"creation"},{"type":"update"},{"type":"deletion"}],"source":"ArkDeck/ArkDeck","source_type":"Repository","target":"branch","updated_at":"2026-07-23T10:20:11.425+08:00"}
```

### `branch_protection_full`

```json
{"allow_deletions":{"enabled":false},"allow_force_pushes":{"enabled":false},"allow_fork_syncing":{"enabled":false},"block_creations":{"enabled":false},"enforce_admins":{"enabled":false,"url":"https://api.github.com/repos/ArkDeck/ArkDeck/branches/main/protection/enforce_admins"},"lock_branch":{"enabled":false},"required_conversation_resolution":{"enabled":false},"required_linear_history":{"enabled":true},"required_pull_request_reviews":{"dismiss_stale_reviews":true,"require_code_owner_reviews":true,"require_last_push_approval":false,"required_approving_review_count":1,"url":"https://api.github.com/repos/ArkDeck/ArkDeck/branches/main/protection/required_pull_request_reviews"},"required_signatures":{"enabled":false,"url":"https://api.github.com/repos/ArkDeck/ArkDeck/branches/main/protection/required_signatures"},"required_status_checks":{"checks":[{"app_id":15368,"context":"guard"}],"contexts":["guard"],"contexts_url":"https://api.github.com/repos/ArkDeck/ArkDeck/branches/main/protection/required_status_checks/contexts","strict":true,"url":"https://api.github.com/repos/ArkDeck/ArkDeck/branches/main/protection/required_status_checks"},"url":"https://api.github.com/repos/ArkDeck/ArkDeck/branches/main/protection"}
```

### `repository_settings`

```json
{"fields":{"allow_auto_merge":false,"allow_forking":true,"allow_merge_commit":true,"allow_rebase_merge":true,"allow_squash_merge":true,"allow_update_branch":false,"archived":false,"default_branch":"main","delete_branch_on_merge":true,"disabled":false,"full_name":"ArkDeck/ArkDeck","id":1298882238,"is_template":false,"merge_commit_message":"PR_TITLE","merge_commit_title":"MERGE_MESSAGE","name":"ArkDeck","node_id":"R_kgDOTWtevg","private":false,"squash_merge_commit_message":"COMMIT_MESSAGES","squash_merge_commit_title":"COMMIT_OR_PR_TITLE","visibility":"public","web_commit_signoff_required":false},"missing_known_fields":["use_squash_pr_title_as_default"]}
```

### `rulesets_full` and `active_main_rules`

```json
[{"_links":{"html":{"href":"https://github.com/ArkDeck/ArkDeck/rules/19595282"},"self":{"href":"https://api.github.com/repos/ArkDeck/ArkDeck/rulesets/19595282"}},"created_at":"2026-07-23T10:20:11.391+08:00","enforcement":"active","id":19595282,"name":"agent-ref-boundary","node_id":"RRS_lACqUmVwb3NpdG9yec5Na16-zgErABI","source":"ArkDeck/ArkDeck","source_type":"Repository","target":"branch","updated_at":"2026-07-23T10:20:11.425+08:00"}]
```

```json
[{"ruleset_id":19595282,"ruleset_source":"ArkDeck/ArkDeck","ruleset_source_type":"Repository","type":"creation"},{"ruleset_id":19595282,"ruleset_source":"ArkDeck/ArkDeck","ruleset_source_type":"Repository","type":"update"},{"ruleset_id":19595282,"ruleset_source":"ArkDeck/ArkDeck","ruleset_source_type":"Repository","type":"deletion"}]
```

唯一 repository ruleset 不含 `merge_queue` rule，repository
`allow_auto_merge=false`；因此 capture 时 merge queue/auto-merge 均不在方案中。

### `actor_inventory` and `organization_settings`

```json
{"actions_permissions":{"allowed_actions":"all","enabled":true,"sha_pinning_required":false},"collaborators":[{"id":4340161,"login":"lvye","permissions":{"admin":true,"maintain":true,"pull":true,"push":true,"triage":true},"role_name":"admin","site_admin":false,"type":"User"}],"custom_repository_roles":{"endpoint":"/orgs/ArkDeck/custom-repository-roles","items_key":"custom_roles","query_status":"not-available-or-not-authorized-http-404"},"deploy_keys":[{"added_by":"lvye","created_at":"2026-07-23T02:28:34Z","enabled":true,"id":158088026,"last_used":"2026-07-23T02:34:41Z","read_only":false,"title":"arkdeck-agent-writer","verified":true}],"installations":[],"organization_admins":[{"id":4340161,"login":"lvye","site_admin":false,"type":"User"}],"organization_members":[{"id":4340161,"login":"lvye","site_admin":false,"type":"User"}],"organization_roles":{"roles":[{"created_at":"2021-09-10T20:03:57Z","description":"Grants the ability to manage security policies, security alerts, and security configurations for an organization and all its repositories.","id":138,"name":"security_manager","permissions":["delete_alerts_code_scanning","org_bypass_code_scanning_dismissal_requests","org_bypass_dependabot_alert_dismissal_requests","org_bypass_secret_scanning_closure_requests","org_review_and_manage_secret_scanning_bypass_requests","org_review_and_manage_secret_scanning_closure_requests","read_code_quality","read_code_scanning","resolve_dependabot_alerts","resolve_secret_scanning_alerts","review_org_code_scanning_dismissal_requests","review_org_dependabot_alert_dismissal_requests","view_dependabot_alerts","view_org_code_scanning_dismissal_requests","view_org_dependabot_alert_dismissal_requests","view_secret_scanning_alerts","write_code_quality","write_code_scanning"],"teams":[],"updated_at":"2024-05-15T23:50:27Z","users":[]},{"created_at":"2023-06-29T16:47:29Z","description":"Grants read access to all repositories in the organization.","id":8132,"name":"all_repo_read","permissions":[],"teams":[],"updated_at":"2023-06-29T16:47:29Z","users":[]},{"created_at":"2023-06-29T16:47:29Z","description":"Grants triage access to all repositories in the organization.","id":8133,"name":"all_repo_triage","permissions":[],"teams":[],"updated_at":"2023-06-29T16:47:29Z","users":[]},{"created_at":"2023-06-29T16:47:29Z","description":"Grants write access to all repositories in the organization.","id":8134,"name":"all_repo_write","permissions":[],"teams":[],"updated_at":"2023-06-29T16:47:29Z","users":[]},{"created_at":"2023-06-29T16:47:29Z","description":"Grants maintenance access to all repositories in the organization.","id":8135,"name":"all_repo_maintain","permissions":[],"teams":[],"updated_at":"2023-06-29T16:47:29Z","users":[]},{"created_at":"2023-06-29T16:47:29Z","description":"Grants admin access to all repositories in the organization.","id":8136,"name":"all_repo_admin","permissions":[],"teams":[],"updated_at":"2023-06-29T16:47:29Z","users":[]},{"created_at":"2024-09-24T17:57:43Z","description":"Grants admin access to manage Actions policies, runners, runner groups, network configurations, secrets, variables, and usage metrics for an organization.","id":26237,"name":"ci_cd_admin","permissions":["read_organization_actions_usage_metrics","write_organization_actions_secrets","write_organization_actions_settings","write_organization_actions_variables","write_organization_network_configurations","write_organization_runner_custom_images","write_organization_runners_and_runner_groups"],"teams":[],"updated_at":"2024-09-24T17:57:43Z","users":[]},{"created_at":"2025-02-11T14:55:18Z","description":"Grants the ability to manage all GitHub Apps owned by an organization.","id":33679,"name":"app_manager","permissions":[],"teams":[],"updated_at":"2025-02-11T14:55:18Z","users":[]},{"created_at":"2026-06-05T15:17:33Z","description":"Grants the ability to review open-source license compliance closure requests and update repository license policies.","id":82849,"name":"open_source_license_manager","permissions":["review_license_compliance_closure_requests","view_license_compliance_closure_requests","view_repository_license_policy"],"teams":[],"updated_at":"2026-06-05T15:17:33Z","users":[]}],"total_count":9},"outside_collaborators":[],"pending_invitations":[],"repository_permissions_for_authenticated_user":{"admin":true,"maintain":true,"pull":true,"push":true,"triage":true},"teams":[],"workflow_permissions":{"can_approve_pull_request_reviews":true,"default_workflow_permissions":"read"}}
```

```json
{"advanced_security_enabled_for_new_repositories":false,"default_repository_permission":"read","id":304203651,"is_verified":false,"login":"ArkDeck","members_allowed_repository_creation_type":"all","members_can_create_internal_repositories":false,"members_can_create_private_repositories":true,"members_can_create_public_repositories":true,"members_can_create_repositories":true,"members_can_fork_private_repositories":false,"plan_name":"free","two_factor_requirement_enabled":false}
```

解释边界：

- custom repository role endpoint 的 404 与 `plan_name=free` 一致；GitHub Free 不提供
  custom repository role；
- organization role inventory 返回 9 个 built-in role；每个 role 的 users/teams
  assignments 均为空。organization member/admin 均仅 `lvye`，outside collaborators、
  pending invitations、repository teams 与 App installations 均为空；
- Actions `can_approve_pull_request_reviews=true` 是显式记录的 capability，不得被忽略。
  Actions 不是 CODEOWNER、ruleset bypass 或 main push actor；执行负向矩阵仍必须证明
  Agent 无法把该 setting 或 workflow route 变成 human approval；
- Deploy Key `158088026` 为 write key，只允许由 protection topology 将其限制在
  `agent/**`；它不是 bypass、CODEOWNER、admin 或 main push actor。

任一 fresh read 出现第二个 organization member/admin、role assignment、
repository-effective collaborator/team/App、custom repository role、pending
invitation、额外 bypass actor、Actions permission drift 或未解释 capability，停止。

## C. Credential-containment gate

capture 发生在人类 `lvye` authenticated session，仅证明 before。它不证明 execution
containment。capture 时 sensitive environment variable name 列表为空、未查询 keychain
内容，且 `ssh-add -l` 未成功；后者不能升级为“ssh-agent 为空”。

首次 write 前必须在退出 capture session 后，以 fresh Agent session 证明：

1. 所有 `lvye` authenticated Codex/GitHub connector、browser delegation 与 CLI
   session 均已从 ArkDeck 断开；
2. `gh auth status` 不报告 human account；
3. Agent process 的 environment、credential helper、keychain 可达项与 ssh-agent
   均无 human credential；不得读取或输出 credential value；
4. Agent metadata identity 若存在，必须不是 `lvye`，且 repository
   `admin=false`、`maintain=false`、`push=false`；
5. Deploy Key、Actions 与任何 integration 的 stable actor/permission record 与
   Section B 一致，且均非 CODEOWNER、bypass、admin、main-push actor；
6. CHG-2026-030 r7 仍为 current，#449/r6、#435 与任何等价 Agent-operated D2 route
   不可执行。

任一条件不能二值证明：repository/ruleset/protection PUT 数、ref probe 数与 Agent
privileged dispatch 全部为 0。

## D. Exact write payloads

所有 endpoint 使用 `Accept: application/vnd.github+json` 与
`X-GitHub-Api-Version: 2026-03-10`。禁止 UI 手工逐字段编辑、字段追加、payload
重排后重算 hash 或在窗口内临时修正。

### `BP_BEFORE_WRITE_PAYLOAD`

Endpoint: `PUT /repos/ArkDeck/ArkDeck/branches/main/protection`

```json
{"allow_deletions":false,"allow_force_pushes":false,"allow_fork_syncing":false,"block_creations":false,"enforce_admins":false,"lock_branch":false,"required_conversation_resolution":false,"required_linear_history":true,"required_pull_request_reviews":{"bypass_pull_request_allowances":{"apps":[],"teams":[],"users":[]},"dismiss_stale_reviews":true,"dismissal_restrictions":{"apps":[],"teams":[],"users":[]},"require_code_owner_reviews":true,"require_last_push_approval":false,"required_approving_review_count":1},"required_status_checks":{"checks":[{"app_id":15368,"context":"guard"}],"contexts":["guard"],"strict":true},"restrictions":null}
```

```yaml
byte_count: 640
sha256: 78606ef9437dfb40ca17bc351f43f907cc7d5bb5403e1059a556af2044bacba3
```

### `BP_AFTER_WRITE_PAYLOAD`

```json
{"allow_deletions":false,"allow_force_pushes":false,"allow_fork_syncing":false,"block_creations":false,"enforce_admins":true,"lock_branch":false,"required_conversation_resolution":false,"required_linear_history":true,"required_pull_request_reviews":{"bypass_pull_request_allowances":{"apps":[],"teams":[],"users":[]},"dismiss_stale_reviews":true,"dismissal_restrictions":{"apps":[],"teams":[],"users":[]},"require_code_owner_reviews":true,"require_last_push_approval":false,"required_approving_review_count":1},"required_status_checks":{"checks":[{"app_id":15368,"context":"guard"}],"contexts":["guard"],"strict":true},"restrictions":{"apps":[],"teams":[],"users":["lvye"]}}
```

```yaml
byte_count: 674
sha256: f423ce0ca2eb3f667a34dbb7f9bcfa923266928d073ee0e50763b2f69ee2663a
```

### `BP_ROLLBACK_WRITE_PAYLOAD`

与 `BP_BEFORE_WRITE_PAYLOAD` literal bytes 相同：

```yaml
byte_count: 640
sha256: 78606ef9437dfb40ca17bc351f43f907cc7d5bb5403e1059a556af2044bacba3
```

branch protection after 只改变 `enforce_admins false → true` 并新增 restrictions
users `[lvye]`、teams/apps `[]`。它保留 strict `guard` app ID `15368`、PR、1
approval、CODEOWNER、stale-review dismissal、linear history 与全部 false safety
flags。`required_signatures=false` 不是 full-protection PUT 字段，必须在 write 前后
separate authenticated read-back 保持 false；漂移即停止。

### `RULESET_BEFORE_WRITE_PAYLOAD`

Endpoint: `PUT /repos/ArkDeck/ArkDeck/rulesets/19595282`

```json
{"bypass_actors":[{"actor_id":4340161,"actor_type":"User","bypass_mode":"always"}],"conditions":{"ref_name":{"exclude":["refs/heads/agent/**"],"include":["~ALL"]}},"enforcement":"active","name":"agent-ref-boundary","rules":[{"type":"creation"},{"type":"update"},{"type":"deletion"}],"target":"branch"}
```

```yaml
byte_count: 301
sha256: 5943b6ce840cbb385ad83615da15ff2ee4ec5710bd696fae6140b37302042157
```

### `RULESET_AFTER_WRITE_PAYLOAD`

```json
{"bypass_actors":[{"actor_id":4340161,"actor_type":"User","bypass_mode":"always"}],"conditions":{"ref_name":{"exclude":["refs/heads/agent/**","refs/heads/agent/**/*","refs/heads/main"],"include":["~ALL"]}},"enforcement":"active","name":"agent-ref-boundary","rules":[{"type":"creation"},{"type":"update"},{"type":"deletion"}],"target":"branch"}
```

```yaml
byte_count: 343
sha256: 9bb7ef3d62246733ca1dcaac074a3b07f5b4aead6985d645cd58fbf82db62163
```

### `RULESET_ROLLBACK_WRITE_PAYLOAD`

与 `RULESET_BEFORE_WRITE_PAYLOAD` literal bytes 相同：

```yaml
byte_count: 301
sha256: 5943b6ce840cbb385ad83615da15ff2ee4ec5710bd696fae6140b37302042157
```

ruleset after 除 exclusions 增加 `refs/heads/agent/**/*` 与 `refs/heads/main` 外零
差异；`active`、`~ALL`、creation/update/deletion 与唯一 human bypass 必须保持。

### Repository payloads

Endpoint: `PATCH /repos/ArkDeck/ArkDeck`

`REPOSITORY_BEFORE_WRITE_PAYLOAD`、`REPOSITORY_AFTER_WRITE_PAYLOAD` 与
`REPOSITORY_ROLLBACK_WRITE_PAYLOAD` 三者 literal bytes 相同：

```json
{"allow_auto_merge":false}
```

```yaml
byte_count: 26
sha256: 280087f72d1ae343f2490e5b06fa2eaba71307656582fa7804a563a43ce800a5
```

fresh before 若仍为 false，则第 2 步只 read-back，repository mutation count 为 0；
不得为制造 receipt 发送 same-value PATCH。若变为 true，视为 drift 并停止，不在本
readiness 内修复。

## E. Operator, lease and mutation budgets

```yaml
operator: lvye
executor: human
credential_location: isolated, Agent-unreachable
lease_anchor: readiness merge commit committed_at from authenticated GitHub facts
window_start_utc: lease_anchor + 15 minutes
window_end_utc: lease_anchor + 45 minutes
rollback_contact: lvye
maximum_ruleset_mutations: 1 after + 1 rollback
maximum_branch_protection_mutations: 1 after + 1 rollback
maximum_repository_setting_mutations: 0
agent_privileged_dispatch: 0
```

window 只在 readiness merge OID、committed_at 与 merged readiness blob 均二值确认后
计算；采用闭区间 `[start,end)`。过期、系统时钟不可信或窗口中发生 main/pin/control
plane drift，重新 readiness，不顺延、不重算 anchor。

## F. Quiescence, drift and stop conditions

首次 write 前由 isolated human session 重读并 canonicalize：

- readiness merge OID/committed_at 与当前 protected main；
- Section A 全部 pinned blobs；
- 全部 open PR 及 changed-files overlap；
- 全部 remote refs；
- ruleset full JSON/`updated_at` 与 active-main evaluation；
- branch protection full JSON，包括 signatures；
- repository merge settings 与全部 rulesets；
- collaborator/team/App/deploy-key/Actions actor inventory；
- Section H 派生的所有 probe refs 均不存在。

仅开放 PR 本身不阻塞；与本 D2 的 sensitive inputs、control-plane 或目标 refs 重叠才
阻塞。以下任一发生立即停止：

- protected main 不等于 readiness merge OID，或任一 pinned blob drift；
- overlapping PR/control-plane operation；
- non-Agent/non-main ref 未由本 readiness 明确列为 controlled fixture；
- hidden/unexpected actor、custom role、App、team、bypass 或 permission；
- canonical JSON、byte count、hash 或 exact payload mismatch；
- stale probe name、existing derived ref 或 derivation mismatch；
- human credential isolation 不能证明；
- API timeout、ambiguous response、unknown outcome 或 blind retry；
- exact before 无法恢复；
- #449/r6、#435 或等价 Agent-operated D2 capability 可执行或再次出现。

## G. Exact execution order

1. 在 window 内完成 Section C/F preflight；全部 before hash exact。
2. 确认 repository auto-merge 仍为 false；只 read-back，不 PATCH。
3. PUT exact `BP_AFTER_WRITE_PAYLOAD`；立即 full authenticated read-back。
4. 验证 PR/review/CODEOWNER/check/admin/push/force/delete 与 signatures effective
   settings。
5. 旧 ruleset 仍覆盖 main 时，以 Deploy Key 运行 direct-main negative；该 receipt
   只证明 overlap fail-closed。
6. 再次证明 Agent identity containment；human admin session 对 Agent process/tool/
   browser 仍不可达。
7. PUT exact `RULESET_AFTER_WRITE_PAYLOAD`；立即 full authenticated read-back 与
   active-rule evaluation。
8. 立即重复 Deploy Key direct-main negative；必须由 branch protection 明确拒绝。
9. 按 Section H 完成 Deploy Key ref matrix 与 controlled fixture。
10. 完成 Agent/API review、merge、auto-merge、ref/admin negative matrix。
11. fact capture 完成后 cleanup controlled refs；退出 isolated human admin session，
    再次证明无 human credential 可达。
12. 以普通 Agent PR path 创建 execution-evidence PR；`lvye` 在 `guard` success 后
    normal no-bypass squash merge。
13. 后续独立 operability-evidence PR 记录第 12 步。

任何 response 不确定时不重试、不换 probe 名继续。fact capture 前不 cleanup。

## H. Fresh probe derivation and matrix

固定 nonce：

```text
55310649-57be-47ae-b5ff-a07466d7c041
```

名称只在 readiness merged 后生成。对每个 slot，计算：

```text
token = first 24 lowercase hex characters of
        SHA-256("arkdeck-rpt001-probe-v1\n" +
                readiness_merge_oid + "\n" +
                "55310649-57be-47ae-b5ff-a07466d7c041" + "\n" +
                slot)
```

禁止 shell 字符串拼接外部命令；executor 使用固定 argv 与本地 hash library，记录
input、full digest 与派生 ref。slot 与 exact ref 结构：

| Slot | Ref/head after merge | Expected actor/result |
| --- | --- | --- |
| `single-agent` | `refs/heads/agent/rpt001-<token>` | Deploy Key create/update/delete success |
| `multi-agent` | `refs/heads/agent/rpt001/deep/<token>` | Deploy Key create/update/delete success |
| `ordinary-create` | `refs/heads/rpt001-ordinary-<token>` | Deploy Key create reject；永不应存在 |
| `ordinary-fixture` | `refs/heads/rpt001-fixture-<token>` | human isolated session create/delete；Deploy Key update reject |
| `similar-prefix` | `refs/heads/agentx/rpt001-<token>` | Deploy Key create reject；永不应存在 |
| `agent-force-fixture` | `refs/heads/agent/rpt001-force-<token>` | controlled Agent namespace force probe only |
| `unapproved-pr` | `refs/heads/agent/rpt001-unapproved-<token>` | PR number 由 GitHub 返回；merge reject |
| `guard-red-pr` | `refs/heads/agent/rpt001-guard-red-<token>` | PR number 由 GitHub 返回；merge reject |
| `normal-merge-pr` | `refs/heads/agent/rpt001-normal-<token>` | normal human no-bypass squash merge |

`main_probe_commit` 是 parent 等于 locked readiness merge OID 的 fresh empty commit；
其 OID 在窗口内生成并记录。`delete_probe=refs/heads/main`。真实 main force/delete
request 不发送：本 readiness 未证明该 request 在 ref mutation 前必然失败；对应结论
使用 authenticated false settings、non-bypass actor facts 与 direct-main negative。
不得为了“看看会怎样”放宽此限制。

controlled ordinary fixture 只允许 human isolated session 在旧 ruleset bypass 下创建，
固定指向 locked main；Deploy Key negative fact capture 后由同一 human session 删除。
fixture create/delete 与 probe refs 是本 D2 明确列出的唯一 ref side effects。

## I. Rollback

ruleset 尚未修改时失败：

- 旧 ruleset 继续覆盖 main；
- branch protection 只有在 authenticated/hash-verified 且恢复不削弱当时 required
  invariants 时，才 PUT exact `BP_ROLLBACK_WRITE_PAYLOAD`；
- 否则保留更严格 branch protection、退出 session、停链。

ruleset 已修改后失败：

1. 首先 PUT exact `RULESET_ROLLBACK_WRITE_PAYLOAD`；
2. authenticated read-back，验证 active、旧 exclusion 与 main 的
   creation/update/deletion coverage；
3. 只有 restoration 二值通过后，才判断 branch protection rollback；
4. repository setting 始终为 false，无 rollback PATCH；
5. 重读全部 before/pin/actor hashes；
6. 退出 admin session，提交 failure evidence，任务保持 blocked。

无法证明 ruleset restoration 时，不继续编辑来制造“干净外观”，按 governance
incident 处理。rollback 不授权新的 target、payload、blind retry 或窗口延长。

## J. Evidence and done boundary

- execution receipt/evidence PR：facts only，零状态翻转；
- operability-evidence PR：记录上一 PR 的 normal no-bypass merge；
- done PR：只含状态与 merged evidence pointers；
- BAP supersession 与 HLR readiness：TASK-RPT-002 后续独立 PR；
- change verification：最后独立 PR。

本 readiness merge 只授权上述 exact、一次性、human-isolated D2 lease；不构成 task
done、change verified、standing authorization 或 Agent privileged capability。
