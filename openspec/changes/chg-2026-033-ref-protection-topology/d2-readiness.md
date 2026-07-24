# TASK-RPT-001 D2 readiness

> Status:SECOND SUPERSEDING REVISION PROPOSED / NON-EXECUTABLE UNTIL THIS EXACT FILE IS
> REVIEWED AND MERGED
>
> 本文件只固定一次性、human-isolated D2 plan。PR 合入前 GitHub control-plane
> write、probe ref mutation、PR state mutation 与 Agent privileged dispatch 均为 0。
> 合入后仍须通过全部 credential-containment、fresh read-back、drift、quiescence 与
> window gates；任一失败均为零 dispatch，或按 Section I fail closed。

## A. Authority, capture and concurrency pins

```yaml
schema: arkdeck-rpt001-readiness/v1
human_capture_schema: arkdeck-rpt001-human-capture-v1
human_capture_api_version: 2026-03-10
human_capture_started_utc: 2026-07-24T04:47:25Z
human_capture_finished_utc: 2026-07-24T04:47:59Z
human_capture_request_semantics: GET-only
human_capture_canonical_bytes: 22179
human_capture_sha256: 0a10b79fae6908b3be1fe57fecb2de9165ab7e4eeb331a25f390f3b8af560d14
captured_by:
  login: lvye
  id: 4340161
  type: User
  site_admin: false
protected_main_oid_at_capture: 60ea5266e506f88b81c0ef8a2c6744c770b5b3d5
readiness_base_oid: 2e449569a3dda7c5b6bad7ad083df9934169c840
superseded_pr462_readiness_merge_oid: f14d9de8d5f32d0998837466674adeff9516e5b5
superseded_pr463_readiness_merge_oid: 90b05a5b0823277f0fcf7c9af77f319f9861f364
change_approval_merge_oid: c86f07ae6b843affaaa3f698e2f9f08a6f4c96cd
compatible_chg030_r7_merge_oid: c5a1a9f0f1c0a9bc0dd3d04275ac01a5738697f7
task_ready_merge_oid: 298ffa4867f5c0588b8d8adba1a2cb4fb76d5cd8
ruleset_id: 19595282
declared_open_control_plane_operations: []
non_agent_non_main_remote_refs: []
```

capture 后，非重叠 PR #461 以
`5b41a15391256d9adcc3a5a316654971c9aab57e` 合入。随后 PR #462 在本轮
self-approval capability 审计完成前，以旧 head
`1839b1ec4009eee6d371217ba8ee35f189a3ca64` 合入为
`f14d9de8d5f32d0998837466674adeff9516e5b5`。#462 没有固定或关闭
`can_approve_pull_request_reviews=true`，因此其 readiness 失效。PR #463 的 exact
head `9ef4e5ae6297b6657d1ae0b41c9871855011e11f` 随后由 `lvye` APPROVED，
`guard`/`allowed-paths` 通过，并以
`90b05a5b0823277f0fcf7c9af77f319f9861f364` 合入；但在任何 D2 write 或 probe
之前，#465 又把 protected `main` 推进为
`2e449569a3dda7c5b6bad7ad083df9934169c840`。Section F 的 exact-main gate 因而
使 #463 readiness 自动失效，旧 execution dispatch 必须为 0。

本 second superseding revision 以 `2e449569a3dda7c5b6bad7ad083df9934169c840`
为新 readiness base；#465 只修改
`openspec/changes/chg-2026-026-macos-rockchip-flash-ui/tasks.md`，与本任务 pinned
inputs 和 target 零重叠。capture main、#462 merge 与 #463 merge 均只保留为
provenance，**不是 execution pin**。本 readiness PR 合入前
`readiness_merge_oid` 不存在；执行 preflight 必须从 GitHub 的 protected-main
merge facts 取得本 PR 的完整 merge OID，并证明当时 `main` 正好等于该 OID。PR
head、短 SHA、本地推测、旧 capture main 或任何 superseded readiness merge OID
均不能替代。

固定 blob：

| Path | Blob OID |
| --- | --- |
| `.github/CODEOWNERS` | `f4edd22f87965efcfc27ea512283a0c2252bf0fb` |
| `.github/workflows/agent-pr.yml` | `41426544637db25224dc6c6b3718abd4ebbfca7c` |
| `.github/workflows/sdd-guard.yml` | `809147e462512d970813d1992a3fcdf41f8b4b10` |
| `AGENTS.md` | `3c2d3c6a01d3eaa31cd9e3ee333f3153552f4164` |
| CHG-2026-030 `proposal.md` | `890a40585b2898c0fd9e7d2b72f5b2a8e81b515c` |
| CHG-2026-030 `design.md` | `7e2e20bfb884875de32cbbeb5f0399df7a137056` |
| CHG-2026-030 `tasks.md` | `7fc3c14bb207facec9d330a8d74b23fb9aefdb58` |
| CHG-2026-030 `verification.md` | `49f284b397006fa8626e76ec2fa51f5d9a88e307` |
| CHG-2026-033 `proposal.md` | `8a98c95fdb24029c1ac13325578f2800eae8018c` |
| CHG-2026-033 `design.md` | `be556c61967101b1b66c85cb2b19aa7cae428bcd` |
| CHG-2026-033 `tasks.md` | `dc021364f6aa0fb221047f1b362c68a3c5f1f56a` |
| CHG-2026-033 `verification.md` | `a8a6dc71221850a3f965e8ee2a964150296262a2` |
| `openspec/governance/enforcement.md` | `e8ff3c130e1b8b15f8405d150ad567e774a0d82b` |
| `openspec/governance/host-loop-runbook.md` | `70e0bcc5b736a896f0329e24a89e273164762558` |

本文件自身的 blob 只能在 readiness merge 后固定。执行时必须固定 merged readiness
blob，并证明其内容等于维护者 approved head；表中其余 blob 必须逐项相等。

`2026-07-24T06:24:44Z` 的 public refresh 发现：

| PR | Head OID | Decision |
| --- | --- | --- |
| #459 | `d3aeeaaa8eba79526474580208dc253c4c46d26a` | product/updater 与 CHG-2026-023 paths；零 D2 overlap |
| #466 | `3fda06cc3e5e91e06890845f2a760a9a3fec592c` | 只修改 CHG-2026-023 `tasks.md`；零 D2 overlap |
| 本 PR | 本 second superseding readiness 的 exact reviewed head | 必须先由 `lvye` review/merge；其 merge OID 才是 execution pin |

全部远端 branch ref：

```text
refs/heads/agent/chg-2026-029-r5-remediation
refs/heads/agent/obs-001-observability
refs/heads/agent/rkfui-001-identity-separation-readiness
refs/heads/agent/task-au-002-done
refs/heads/agent/task-au-002-update-runtime
refs/heads/agent/task-hlr-002-readiness
refs/heads/agent/task-hlr-002a-bootstrap-partition
refs/heads/agent/task-mech-002
refs/heads/agent/task-rpt-001-d2-rereadiness
refs/heads/agent/task-tr-003
refs/heads/main
```

除 `main` 外均为 `agent/**`。非重叠 PR 不要求关闭；若 execution preflight 发现它们
或新 PR 修改 pinned inputs、目标 refs、ruleset/protection/repository/Actions setting、
credential authority 或本 readiness，立即停止。

## B. Authenticated before artifacts

canonicalization：UTF-8、递归排序 object keys、separators `(',', ':')`、无 trailing
LF。完整 human capture 由 Section A 的 bytes/hash 固定；本节嵌入执行所需的 full
control objects 与 enforcement projection。

| Artifact | Bytes | SHA-256 |
| --- | ---: | --- |
| `ruleset_full` | 702 | `a5725db245d84174090de47e1fc45123219dbf5cfdd00d45856b04d801a3d5f2` |
| `branch_protection_full` | 1,227 | `e45fb8583eb8002e49fcd402c0d9026f7277a1b823b6fe7410695da5666f0b0c` |
| `repository_settings_full` | 648 | `ec3df4f619d474d83acc3199ae677104149e56bb45e05ea0eb67dee49a3b0e9d` |
| `actions_full` | 212 | `61c9241c4a9f27565c00d7e5938852390934b174f75983b0df247ecb8e1b13ee` |
| `actor_enforcement_projection` | 1,294 | `eba50756ae888703531e39fbf85c09d6e8324109de2927cb19ef7a5f10f1aca9` |

### `ruleset_full`

```json
{"_links":{"html":{"href":"https://github.com/ArkDeck/ArkDeck/rules/19595282"},"self":{"href":"https://api.github.com/repos/ArkDeck/ArkDeck/rulesets/19595282"}},"bypass_actors":[{"actor_id":4340161,"actor_type":"User","bypass_mode":"always"}],"conditions":{"ref_name":{"exclude":["refs/heads/agent/**"],"include":["~ALL"]}},"created_at":"2026-07-23T10:20:11.391+08:00","current_user_can_bypass":"always","enforcement":"active","id":19595282,"name":"agent-ref-boundary","node_id":"RRS_lACqUmVwb3NpdG9yec5Na16-zgErABI","rules":[{"type":"creation"},{"type":"update"},{"type":"deletion"}],"source":"ArkDeck/ArkDeck","source_type":"Repository","target":"branch","updated_at":"2026-07-23T10:20:11.425+08:00"}
```

### `branch_protection_full`

```json
{"allow_deletions":{"enabled":false},"allow_force_pushes":{"enabled":false},"allow_fork_syncing":{"enabled":false},"block_creations":{"enabled":false},"enforce_admins":{"enabled":false,"url":"https://api.github.com/repos/ArkDeck/ArkDeck/branches/main/protection/enforce_admins"},"lock_branch":{"enabled":false},"required_conversation_resolution":{"enabled":false},"required_linear_history":{"enabled":true},"required_pull_request_reviews":{"dismiss_stale_reviews":true,"require_code_owner_reviews":true,"require_last_push_approval":false,"required_approving_review_count":1,"url":"https://api.github.com/repos/ArkDeck/ArkDeck/branches/main/protection/required_pull_request_reviews"},"required_signatures":{"enabled":false,"url":"https://api.github.com/repos/ArkDeck/ArkDeck/branches/main/protection/required_signatures"},"required_status_checks":{"checks":[{"app_id":15368,"context":"guard"}],"contexts":["guard"],"contexts_url":"https://api.github.com/repos/ArkDeck/ArkDeck/branches/main/protection/required_status_checks/contexts","strict":true,"url":"https://api.github.com/repos/ArkDeck/ArkDeck/branches/main/protection/required_status_checks"},"url":"https://api.github.com/repos/ArkDeck/ArkDeck/branches/main/protection"}
```

GET response 不含 `restrictions`，即 before 无 push allowlist；after 必须变为 users
恰为 `[lvye]`、teams/apps 为空。

### `repository_settings_full`

```json
{"allow_auto_merge":false,"allow_merge_commit":true,"allow_rebase_merge":true,"allow_squash_merge":true,"archived":false,"default_branch":"main","delete_branch_on_merge":true,"disabled":false,"full_name":"ArkDeck/ArkDeck","id":1298882238,"node_id":"R_kgDOTWtevg","owner":{"id":304203651,"login":"ArkDeck","node_id":"O_kgDOEiHHgw","site_admin":false,"type":"Organization"},"permissions":{"admin":true,"maintain":true,"pull":true,"push":true,"triage":true},"squash_merge_commit_message":"COMMIT_MESSAGES","squash_merge_commit_title":"COMMIT_OR_PR_TITLE","use_squash_pr_title_as_default":null,"visibility":"public","web_commit_signoff_required":false}
```

### `actions_full`

```json
{"permissions":{"allowed_actions":"all","enabled":true,"sha_pinning_required":false},"selected_actions":null,"workflow_permissions":{"can_approve_pull_request_reviews":true,"default_workflow_permissions":"read"}}
```

`can_approve_pull_request_reviews=true` 是 before 中必须闭合的 capability 缺口。仅扫描
workflow source、承诺不调用 review API 或把 Actions 排除出 CODEOWNERS，均不能替代
把该 repository setting 改为 false。

### `actor_enforcement_projection`

```json
{"authenticated_identity":{"id":4340161,"login":"lvye","node_id":"MDQ6VXNlcjQzNDAxNjE=","site_admin":false,"type":"User"},"collaborators":[{"id":4340161,"login":"lvye","node_id":"MDQ6VXNlcjQzNDAxNjE=","permissions":{"admin":true,"maintain":true,"pull":true,"push":true,"triage":true},"role_name":"admin","site_admin":false,"type":"User"}],"custom_repository_roles":{"availability":"feature-not-available","feature":"custom-repository-roles","http_status":404,"message":"Feature not available for the ArkDeck organization."},"deploy_keys":[{"added_by":"lvye","created_at":"2026-07-23T02:28:34Z","enabled":true,"id":158088026,"last_used":"2026-07-23T02:34:41Z","read_only":false,"title":"arkdeck-agent-writer","verified":true}],"org_installations":{"installations":[],"total_count":0},"organization_role_assignments":[{"role_id":138,"teams":[],"users":[]},{"role_id":8132,"teams":[],"users":[]},{"role_id":8133,"teams":[],"users":[]},{"role_id":8134,"teams":[],"users":[]},{"role_id":8135,"teams":[],"users":[]},{"role_id":8136,"teams":[],"users":[]},{"role_id":26237,"teams":[],"users":[]},{"role_id":33679,"teams":[],"users":[]},{"role_id":82849,"teams":[],"users":[]}],"organization_role_ids":[138,8132,8133,8134,8135,8136,26237,33679,82849],"selected_installation_repositories":[],"teams":[]}
```

结论：

- ruleset bypass 只有 human `lvye`（user ID `4340161`）；Deploy Key、Actions、
  Integration、App、team 与 repository role 均不在 bypass；
- Deploy Key `158088026` 是 write key，但不是 collaborator/admin/CODEOWNER/main
  push actor；
- repository collaborators 只有 `lvye`，teams 为空；organization role assignments
  全空；organization App installations 与 selected installation repositories 全空；
- custom repository role endpoint 精确返回 feature-unavailable HTTP 404，不能把它
  猜成 hidden actor；
- before 尚无 main push allowlist；after 只能出现 `lvye`。

## C. Credential-containment gate

human capture 只证明 before，不证明 execution containment。首次 write 前必须在已退出
capture session 后，以 fresh Agent session 二值证明：

1. 所有以 `lvye` 认证的 Codex/GitHub connector、browser delegation、CLI session
   已从 ArkDeck 断开，且 Agent tools 中不存在可用 human session；
2. `gh auth status` 不报告 human account；
3. Agent process 的 environment、credential helper、keychain 可达项与 ssh-agent
   均无 human credential；只记录 presence/result，不读取或输出 credential value；
4. Agent metadata identity 若存在，必须不是 `lvye`，且 `admin=false`、
   `maintain=false`、`push=false`；
5. Deploy Key、Actions 与任何 future integration 均有 stable actor/permission record，
   且非 CODEOWNER、bypass、admin、main-push；
6. CHG-2026-030 r7 仍为 current；#449/r6、#435 及等价 Agent-operated D2 route
   均不可执行。

任一条件不能证明：Actions/repository/branch-protection/ruleset write 数、ref probe 数
与 Agent privileged dispatch 全部为 0。

## D. Exact write payloads

所有 endpoint 使用：

```text
Accept: application/vnd.github+json
X-GitHub-Api-Version: 2026-03-10
```

禁止 UI 手工逐字段编辑、临时追加字段、改序后重算 hash 或在窗口内修订 payload。
write 后必须 full GET；同时把 response 归一化为对应 write contract projection，
其 bytes/hash 必须等于本节固定值。

### Branch protection

Endpoint: `PUT /repos/ArkDeck/ArkDeck/branches/main/protection`

`BP_BEFORE_WRITE_PAYLOAD`：

```json
{"allow_deletions":false,"allow_force_pushes":false,"allow_fork_syncing":false,"block_creations":false,"enforce_admins":false,"lock_branch":false,"required_conversation_resolution":false,"required_linear_history":true,"required_pull_request_reviews":{"bypass_pull_request_allowances":{"apps":[],"teams":[],"users":[]},"dismiss_stale_reviews":true,"dismissal_restrictions":{"apps":[],"teams":[],"users":[]},"require_code_owner_reviews":true,"require_last_push_approval":false,"required_approving_review_count":1},"required_status_checks":{"checks":[{"app_id":15368,"context":"guard"}],"contexts":["guard"],"strict":true},"restrictions":null}
```

```yaml
byte_count: 640
sha256: 78606ef9437dfb40ca17bc351f43f907cc7d5bb5403e1059a556af2044bacba3
```

`BP_AFTER_WRITE_PAYLOAD`：

```json
{"allow_deletions":false,"allow_force_pushes":false,"allow_fork_syncing":false,"block_creations":false,"enforce_admins":true,"lock_branch":false,"required_conversation_resolution":false,"required_linear_history":true,"required_pull_request_reviews":{"bypass_pull_request_allowances":{"apps":[],"teams":[],"users":[]},"dismiss_stale_reviews":true,"dismissal_restrictions":{"apps":[],"teams":[],"users":[]},"require_code_owner_reviews":true,"require_last_push_approval":false,"required_approving_review_count":1},"required_status_checks":{"checks":[{"app_id":15368,"context":"guard"}],"contexts":["guard"],"strict":true},"restrictions":{"apps":[],"teams":[],"users":["lvye"]}}
```

```yaml
byte_count: 674
sha256: f423ce0ca2eb3f667a34dbb7f9bcfa923266928d073ee0e50763b2f69ee2663a
```

`BP_ROLLBACK_WRITE_PAYLOAD` 与 before literal bytes 相同：

```yaml
byte_count: 640
sha256: 78606ef9437dfb40ca17bc351f43f907cc7d5bb5403e1059a556af2044bacba3
```

after 只改变 `enforce_admins false → true` 并新增 restrictions users `[lvye]`、
teams/apps `[]`；PR、1 approval、CODEOWNER、strict `guard` app ID `15368`、
stale-review dismissal、linear history 与全部 false safety flags 保持。commit
signature protection 不属于该 PUT；其 authenticated before/after 必须保持 false，
漂移即停止。

### Ordinary-ref ruleset

Endpoint: `PUT /repos/ArkDeck/ArkDeck/rulesets/19595282`

`RULESET_BEFORE_WRITE_PAYLOAD`：

```json
{"bypass_actors":[{"actor_id":4340161,"actor_type":"User","bypass_mode":"always"}],"conditions":{"ref_name":{"exclude":["refs/heads/agent/**"],"include":["~ALL"]}},"enforcement":"active","name":"agent-ref-boundary","rules":[{"type":"creation"},{"type":"update"},{"type":"deletion"}],"target":"branch"}
```

```yaml
byte_count: 301
sha256: 5943b6ce840cbb385ad83615da15ff2ee4ec5710bd696fae6140b37302042157
```

`RULESET_AFTER_WRITE_PAYLOAD`：

```json
{"bypass_actors":[{"actor_id":4340161,"actor_type":"User","bypass_mode":"always"}],"conditions":{"ref_name":{"exclude":["refs/heads/agent/**","refs/heads/agent/**/*","refs/heads/main"],"include":["~ALL"]}},"enforcement":"active","name":"agent-ref-boundary","rules":[{"type":"creation"},{"type":"update"},{"type":"deletion"}],"target":"branch"}
```

```yaml
byte_count: 343
sha256: 9bb7ef3d62246733ca1dcaac074a3b07f5b4aead6985d645cd58fbf82db62163
```

`RULESET_ROLLBACK_WRITE_PAYLOAD` 与 before literal bytes 相同：

```yaml
byte_count: 301
sha256: 5943b6ce840cbb385ad83615da15ff2ee4ec5710bd696fae6140b37302042157
```

after 除 exclusions 增加 `refs/heads/agent/**/*` 与 exact main 外零差异。

### Repository merge setting

Endpoint（本 plan 不 dispatch）：`PATCH /repos/ArkDeck/ArkDeck`

`REPOSITORY_BEFORE_WRITE_PAYLOAD`、`REPOSITORY_AFTER_WRITE_PAYLOAD` 与
`REPOSITORY_ROLLBACK_WRITE_PAYLOAD` 三者相同：

```json
{"allow_auto_merge":false}
```

```yaml
byte_count: 26
sha256: 280087f72d1ae343f2490e5b06fa2eaba71307656582fa7804a563a43ce800a5
```

fresh before 必须仍为 false；只 read-back，不发送 same-value PATCH。若变为 true，
视为 drift 并停止，不在本 readiness 内临时修复。唯一 ruleset 不含 merge-queue
rule；fresh applicable/full ruleset inventory 出现 merge queue 即停止。

### Actions workflow approval capability

Endpoint:
`PUT /repos/ArkDeck/ArkDeck/actions/permissions/workflow`

`ACTIONS_WORKFLOW_BEFORE_WRITE_PAYLOAD`：

```json
{"can_approve_pull_request_reviews":true,"default_workflow_permissions":"read"}
```

```yaml
byte_count: 79
sha256: e4eea28a28f0c12dc5a441d5d6451c4bc7f3f72ed8f0b717c6cb5502e825965d
```

`ACTIONS_WORKFLOW_AFTER_WRITE_PAYLOAD`：

```json
{"can_approve_pull_request_reviews":false,"default_workflow_permissions":"read"}
```

```yaml
byte_count: 80
sha256: fb00f7e1aab4200684b287b484155d5521381f4593552beed4bbb5f9b1622ede
```

`ACTIONS_WORKFLOW_ROLLBACK_WRITE_PAYLOAD` 与 before literal bytes 相同：

```yaml
byte_count: 79
sha256: e4eea28a28f0c12dc5a441d5d6451c4bc7f3f72ed8f0b717c6cb5502e825965d
dispatch_under_this_readiness: forbidden
```

把 Actions approval 从 false 恢复为 true 会重新打开 Agent self-approval capability，
违反不变量；因此 payload 为 exact forensic rollback 记录，但本 readiness 不授权发送。
任一后续失败均保留更严格的 false。

## E. Operator, window and budgets

```yaml
operator: lvye
executor: human
credential_location: isolated, Agent-unreachable
window_start_utc: 2026-07-24T07:00:00Z
window_end_utc: 2026-07-24T12:00:00Z
rollback_contact: lvye
maximum_actions_workflow_mutations: 1 after + 0 rollback
maximum_repository_patch_mutations: 0
maximum_branch_protection_mutations: 1 after + 1 rollback
maximum_ruleset_mutations: 1 after + 1 rollback
agent_privileged_dispatch: 0
```

采用半开区间 `[start,end)`。window 只在 readiness 已 merge、当前 main 正好等于该
merge OID 且全部 preflight 通过时有效。过期、系统时钟不可信、main/pin/control-plane
drift 或中途出现 overlap，重新 readiness；不顺延、不换 target、不重算 hash。

## F. Quiescence, read-back and stop conditions

首次 write 前，由 isolated human session fresh GET 并 canonicalize：

- readiness PR exact approved head、`lvye` approving review、`guard` success、
  mergedBy、merge OID/committed_at 与当前 protected main；
- Section A 全部 pinned blobs；
- 全部 open PR、changed files、remote refs 与 announced control-plane operation；
- ruleset full JSON、`updated_at`、applicable rulesets 与 main active-rule evaluation；
- branch protection full JSON，包括 restrictions、review bypass allowances 与 signatures；
- repository merge settings、Actions permissions 与 workflow permissions；
- collaborator、team、custom-role、organization-role assignment、App installation、
  selected-repository 与 Deploy Key inventory；
- Section H 按 merged readiness OID 派生的全部 refs 均不存在。

仅开放 PR 本身不阻塞；与 sensitive inputs/control-plane/targets 重叠才阻塞。以下任一
发生立即停止：

- current main 不等于 readiness merge OID，approved head/merge facts 不完整，或
  pinned blob drift；
- overlapping PR、ref owner、credential rotation 或 control-plane operation；
- 未在 Section H 列出的 non-Agent/non-main ref；
- hidden/unexpected actor、role assignment、team、App、bypass、main-push actor
  或 permission；
- full JSON、canonical byte count、hash、`updated_at` 或 exact payload mismatch；
- Actions approval capability不能先关闭或 after read-back 不为 false；
- stale probe name、derived ref 已存在、nonce/derivation mismatch；
- human credential isolation 不能证明；
- API/Git timeout、ambiguous response、unknown outcome 或 blind retry；
- exact before/rollback 无法解释或恢复；
- #449/r6、#435 或等价 Agent-operated D2 capability 可执行/再次出现。

## G. Exact execution order

1. 在 window 内完成 Section C/F preflight；全部 before bytes/hash exact。
2. PUT exact `ACTIONS_WORKFLOW_AFTER_WRITE_PAYLOAD`；立即 GET，确认
   `can_approve_pull_request_reviews=false` 与 default `read`。
3. 确认 repository `allow_auto_merge=false` 且无 merge queue；只 read-back。
4. PUT exact `BP_AFTER_WRITE_PAYLOAD`；立即 full authenticated GET，并验证
   contract projection/hash、signatures 与未声明字段。
5. 验证 PR/review/CODEOWNER/strict check/admin/push/force/delete effective settings。
6. 旧 ruleset 仍覆盖 main 时：
   - Deploy Key direct-main negative 必须拒绝，只证明 overlap fail closed；
   - `lvye` 作为 ruleset bypass/admin 的 direct-main negative 也必须拒绝，用于证明
     branch protection 的 PR/admin enforcement；probe 使用 Section H 的受控 commit。
7. 再次证明 Agent identity containment；human admin session 对 Agent process/tool/
   browser 仍不可达。
8. PUT exact `RULESET_AFTER_WRITE_PAYLOAD`；立即 full authenticated GET、contract
   projection/hash 与 main active-rule evaluation，证明 main 不再命中该 ruleset。
9. 立即重复 Deploy Key direct-main negative；必须由 branch protection 拒绝。
10. 按 Section H 完成 Deploy Key single/multi positive、ordinary/fixture/agentx
    negative 与受控 cleanup。
11. 完成 Agent/API review、merge、auto-merge、ref/admin route negatives。Actions
    approval 以 false read-back + workflow route inventory 证明不可构造；Deploy Key
    只有 SSH Git transport，不伪造 HTTP token。
12. fact capture 后 cleanup controlled refs；退出 isolated admin session，再次证明
    无 human credential 可达。
13. 以普通 Agent PR path 创建 execution-evidence PR；同一 PR 依次记录未审批、
    `guard` non-green 与 ready 状态；只有 `guard` success + `lvye` approval 后由
    `lvye` normal no-bypass squash merge。
14. 后续独立 operability-evidence PR 记录第 13 步 review/check/mergedBy/merge OID、
    subject `(#N)` 与无 bypass UI fact。

任何 response 不确定时不重试、不换 probe 名继续。fact capture 前不 cleanup。

## H. Fresh probe derivation and matrix

固定 nonce：

```text
4c894164-9966-46f8-96de-e083a3e3771d
```

readiness merge 后，对每个 slot 计算：

```text
token = first 24 lowercase hex characters of
        SHA-256("arkdeck-rpt001-probe-v1\n" +
                readiness_merge_oid + "\n" +
                "4c894164-9966-46f8-96de-e083a3e3771d" + "\n" +
                slot)
```

executor 使用固定 argv 与本地 hash library，不以 shell 拼接外部命令；evidence 记录
input、full digest 与派生 ref。

| Slot | Exact ref/head form | Expected actor/result |
| --- | --- | --- |
| `single-agent` | `refs/heads/agent/rpt001-<token>` | Deploy Key create/update/delete success |
| `multi-agent` | `refs/heads/agent/rpt001/deep/<token>` | Deploy Key create/update/delete success |
| `ordinary-create` | `refs/heads/rpt001-ordinary-<token>` | Deploy Key create reject；永不应存在 |
| `ordinary-fixture` | `refs/heads/rpt001-fixture-<token>` | human create/delete；Deploy Key update/delete reject |
| `similar-prefix` | `refs/heads/agentx/rpt001-<token>` | Deploy Key create reject；永不应存在 |
| `execution-evidence-pr` | `refs/heads/agent/rpt001-evidence-<token>` | unapproved/non-green merge reject；最终 normal merge |

`main_probe_commit` 在 window 内生成：tree 与 locked readiness merge 相同，第一 parent
为 locked main，第二 parent 为从 locked main 派生的 fresh empty commit，subject
固定为 `test(TASK-RPT-001): unauthorized merge-shaped main probe`。同一 OID 用于
Deploy Key overlap negative、`lvye` direct-push negative 与 ruleset-after Deploy Key
negative；不得换 commit 绕过失败。

controlled ordinary fixture 由 human isolated session 在旧 ruleset bypass 下创建，
固定指向 locked main；Deploy Key update/delete negatives fact capture 后，再由同一
human session删除。

真实 main force-push/delete request **不发送**：本 readiness 不把可能成功的 destructive
request 当测试。其禁止结论由 authenticated `allow_force_pushes=false`、
`allow_deletions=false`、human-only restriction、admin enforcement、linear history、
Deploy Key/human direct-main negatives共同验证。任一 reviewer 认为仍需 live
force/delete 才能判 PASS，则对应 AC 保持 blocked，并另起 readiness；不得在本 window
临时补发。

Agent/API identity matrix：

- Deploy Key：仅 SSH Git；普通 ref、fixture update/delete、agentx、main 拒绝；
- Actions：workflow approval setting false，default token read，workflow sources
  不含 review/merge/admin route；
- GitHub App/integration：authenticated inventory 为空；出现任何 installation 即 stop；
- disconnected Agent metadata surface：无 human credential；review、merge、
  enable-auto-merge、update-ref 与 admin route 不可构造或 unauthenticated 拒绝；
- `lvye`：只在 isolated session 操作 exact payload/probes；direct main 拒绝，合规 PR
  只能在 review/check 后 normal merge。

## I. Rollback and unexpected success

Actions after 已写：

- 不恢复 `can_approve_pull_request_reviews=true`；保留更严格 false；
- false read-back 不明确时，不继续 protection/ruleset。

ruleset 尚未修改时失败：

- 旧 ruleset 继续覆盖 main；
- branch protection 只有在 exact authenticated before/hash 可恢复，且恢复不削弱当时
  required invariants 时，才 PUT `BP_ROLLBACK_WRITE_PAYLOAD`；
- 否则保留更严格 branch protection、退出 session、停链。

ruleset 已修改后失败：

1. 首先 PUT exact `RULESET_ROLLBACK_WRITE_PAYLOAD`；
2. authenticated GET，验证 active、旧 exclusion、updated timestamp 与 main 的
   creation/update/deletion coverage；
3. restoration 二值通过后，才判断 branch protection rollback；
4. repository 始终保持 auto-merge false，Actions approval 始终保持 false；
5. 重读全部 before/pin/actor facts；
6. 退出 admin session，提交 failure evidence，任务保持 blocked。

任一 negative probe unexpected success：

- 立即记录 exact request/response/OID/ref/time，停止后续 matrix；
- 不 force-reset、不删除 main、不用另一个名字重试；
- 若 ordinary/agentx fixture 意外创建，由 human isolated session 在 main coverage
  已确认后按 exact ref cleanup；cleanup 不把 FAIL 改为 PASS；
- 若 main 意外更新/删除，按 governance incident 处理，不能用本 readiness 自行修复。

无法证明 ruleset restoration 时，不继续编辑来制造“干净外观”。rollback 不授权新
target、payload、blind retry 或 window extension。

## J. Evidence and done boundary

- execution receipt/evidence PR：facts only，零状态翻转；
- operability-evidence PR：记录上一 PR 的 normal no-bypass merge；
- done PR：只含状态与 merged evidence pointers；
- BAP supersession 与 HLR readiness：TASK-RPT-002 后续独立 PR；
- change verification：最后独立 PR。

本 second superseding readiness merge 只授权上述 exact、一次性、human-isolated D2
window；不构成
task done、change verified、standing authorization 或 Agent privileged capability。

## K. Explicit supersession and zero-reuse statement

#435、旧 HLR-002A readiness、CHG-2026-030 r6/#449 gateway，以及其 OID、window、
payload、hash、probe UUID/ref、script 与 receipt 全部不可执行、不可重放、不可作为
current mechanism evidence。

PR #462 / merge `f14d9de8d5f32d0998837466674adeff9516e5b5` 的 readiness 由
#463 supersede：它没有关闭 Actions 的 review approval capability，不得执行其中
window/payload/probe。

PR #463 / merge `90b05a5b0823277f0fcf7c9af77f319f9861f364` 的 readiness 由本
revision 显式 supersede：#465 导致 current main 与 readiness merge OID 不相等。
#463 的 execution OID、`[2026-07-24T05:30:00Z,2026-07-24T09:30:00Z)` window、
nonce `55310649-57be-47ae-b5ff-a07466d7c041`、任何 derived ref/script/receipt
全部不可执行或重放。Section D 的 canonical payload literals 因目标机制未变而逐字
相同，但只能在本 revision 独立 review/merge、fresh before exact-match 后获得新的
一次性授权；不得把 #463 的批准或 preflight 作为授权来源。

只有本 revision 的 exact head 经本独立 PR 由 `lvye` review/merge 后，才可进入
Section C/F preflight。

本文件的 before 来自
`arkdeck-rpt001-human-capture-v1`；payload/hash 在本 revision 中被重新逐项
授权，nonce/derived refs、execution pin 与 window 均为本 readiness 独有。
