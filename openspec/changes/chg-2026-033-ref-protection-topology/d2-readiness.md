# TASK-RPT-001 D2 readiness template

> Status:DRAFT / NON-EXECUTABLE
> 本文件故意保留 placeholders。填入部分字段不使任务 `ready`；只有 change
> approved、cross-change stop gate 闭合且独立 readiness PR 由 `lvye` review/merge
> 后，exact plan 才可能生效。

## A. Fresh authority and concurrency pins

```yaml
audit_time_utc: <fresh ISO-8601>
protected_main_oid: <fresh 40-hex>
readiness_base_oid: <fresh 40-hex>
change_approval_merge_oid: <fresh 40-hex>
compatible_chg030_r7_merge_oid: <fresh 40-hex>
codeowners_blob_oid: <fresh 40-hex>
enforcement_blob_oid: <fresh 40-hex>
agents_blob_oid: <fresh 40-hex>
host_loop_runbook_blob_oid: <fresh 40-hex>
ruleset_id: 19595282
open_prs: []
open_control_plane_operations: []
non_agent_non_main_remote_refs: []
```

proposal discovery OID
`e8eaef86acc13ef76270e29f7a63873d0b2fa6cb` 仅为历史输入，不是 execution pin。

## B. Mandatory human-controlled authenticated before exports

由人类在 Agent 不可达的隔离 session 中采集 secret-free full response：

1. ruleset `19595282`：conditions、rules、`bypass_actors`、
   `current_user_can_bypass`、created/updated times 与所有 extra fields；
2. main branch protection：reviews、CODEOWNER、checks/strictness、admin enforcement、
   restrictions users/teams/apps、force/delete 与所有 extra fields；
3. repository merge settings：`allow_auto_merge`、merge methods、merge queue；
4. repository/organization actor、custom role、App installation permission；
5. deploy-key inventory：ID/title/read-only flag，不含 key material。

每份 JSON：

```yaml
canonicalization: UTF-8, sorted object keys, separators=(',', ':'), no trailing LF
byte_count: <decimal>
sha256: <64-hex>
captured_by: lvye
captured_at: <ISO-8601>
```

人类采集后退出 admin session；token、cookie、keychain record、browser storage 与
Authorization header 均不提供给 Agent。

## C. Credential-containment gate

首次 protection write 前必须证明：

- 以 `lvye` 认证的 Codex/GitHub connector 已从 ArkDeck 断开；
- fresh Agent session 的 GitHub identity 不是 `lvye`，且
  `admin=false`、`maintain=false`、`push=false`；
- `gh auth status` 无 human account；
- environment、credential helper、keychain、ssh-agent 无 human credential；
- Actions、Deploy Key 与 future integration 全部有 stable actor/permission record，
  且均非 CODEOWNER、bypass、admin、main-push；
- CHG-2026-030 r7 已 supersede #449/r6，且不存在 Agent-operated D2 route。

任一失败：旧 ruleset 不变，PUT/probe 数全部为 0。

## D. Exact payload set

readiness 必须嵌入 literal canonical bytes、byte count 与 SHA-256：

```text
BP_BEFORE_WRITE_PAYLOAD
BP_AFTER_WRITE_PAYLOAD
BP_ROLLBACK_WRITE_PAYLOAD
RULESET_BEFORE_WRITE_PAYLOAD
RULESET_AFTER_WRITE_PAYLOAD
RULESET_ROLLBACK_WRITE_PAYLOAD
REPOSITORY_BEFORE_WRITE_PAYLOAD
REPOSITORY_AFTER_WRITE_PAYLOAD
REPOSITORY_ROLLBACK_WRITE_PAYLOAD
```

payload 由 fresh authenticated full JSON 派生，不能沿用 #435。readiness 必须逐字段
证明：

- BP after：PR、1 approval、CODEOWNER、`guard` app ID `15368`、
  `enforce_admins=true`、users `[lvye]`、teams/apps `[]`、force/delete false；
- ruleset after：保留 active、`~ALL`、creation/update/deletion、human-only bypass，
  exact exclusions 为 `agent/**`、`agent/**/*`、main；
- repository after：auto-merge false、merge queue disabled；
- 未声明字段与 before 一致，或经 proposal/approval 明确证明更严格且 compatible。

## E. Operator and window

```yaml
operator: lvye
executor: human
credential_location: isolated, Agent-unreachable
window_start_utc: <fresh>
window_end_utc: <fresh>
rollback_contact: lvye
maximum_ruleset_mutations: 1 after + 1 rollback
maximum_branch_protection_mutations: 1 after + 1 rollback
maximum_repository_setting_mutations: 1 after + 1 rollback
agent_privileged_dispatch: 0
```

window 必须在 readiness merge 后由维护者重新确认；过期即重新 readiness，不顺延。

## F. Quiescence and stop conditions

首次 write 前重读：

- latest main OID；
- 全部 open PR 与 changed-files overlap；
- 全部 remote refs；
- ruleset full JSON/updated_at；
- branch protection full JSON；
- repository merge settings；
- actor/installation/deploy-key inventory；
- 所有 fresh probe ref 均不存在。

Stop on：

- main/pinned blob drift；
- overlapping PR/control-plane operation；
- non-Agent/non-main ref 未处置；
- hidden/unexpected actor；
- JSON/hash mismatch；
- stale probe name 或 reused UUID；
- human credential isolation 不能证明；
- API timeout/ambiguous response；
- exact before 无法恢复；
- #449/r6 或等价 Agent-operated D2 capability 仍可执行或再次出现。

## G. Exact execution order

1. Human authenticated preflight：全部 before hash exact。
2. 设置 repository auto-merge disabled；immediate read-back。
3. PUT exact branch-protection after；immediate full authenticated read-back。
4. 验证 PR/review/check/admin/push/force/delete effective settings。
5. 旧 ruleset 仍覆盖 main 时，以 Deploy Key 运行 direct-main negative；该 receipt 只
   证明 overlap fail-closed。
6. 再次证明 Agent identity containment；人类隔离 admin session 可继续用于下一 write，
   但对 Agent process/tool/browser 仍不可达。
7. PUT exact ruleset after；immediate full authenticated read-back 与 active-rule
   evaluation。
8. 立即重复 direct-main negative；此时必须由 branch protection 明确拒绝。
9. 执行其余 Deploy Key ref matrix。
10. 执行 Agent/API review/merge/auto-merge/ref/admin negative matrix。
11. 退出 isolated human admin session，再次证明无 human credential 可达。
12. 经普通 Agent PR path 创建 execution-evidence PR；`lvye` 在 `guard` success 后正常
    no-bypass squash merge。
13. 后续独立 operability-evidence PR 记录第 12 步。

fact capture 前不 cleanup。

## H. Fresh probe matrix

所有名称只在 readiness merged 后生成：

```yaml
single_agent_ref: <agent/<fresh-uuid>>
multi_agent_ref: <agent/<segment>/<segment>/<fresh-uuid>>
ordinary_create_ref: <fresh ordinary name>
ordinary_existing_ref: <freshly selected existing non-agent ref or controlled fixture>
similar_prefix_ref: <agentx/<segment>/<fresh-uuid>>
main_probe_commit: <fresh empty commit, parent = locked main>
force_probe: <fresh controlled target>
delete_probe: refs/heads/main
unapproved_pr: <fresh number/head>
guard_red_pr: <fresh number/head>
normal_merge_pr: <fresh number/head>
```

不得为了“看看会怎样”发送可能成功的真实 main force/delete。只有 exact readiness 能
证明 request 在 mutation 前被拒且 rollback 可执行时才允许；不确定则省略 probe，并让
对应 AC 保持 blocked。

## I. Rollback

ruleset 尚未修改时失败：

- 旧 ruleset 保持覆盖 main；
- branch protection/repository exact before 只有在 authenticated/hash-verified 且不削弱
  required invariants 时恢复；否则保留更严格状态、退出 session、停链。

ruleset 已修改后失败：

1. 首先 PUT exact `RULESET_ROLLBACK_WRITE_PAYLOAD`；
2. authenticated read-back 并复现 hash；
3. 确认 main 再次命中 ruleset creation/update/deletion；
4. 仅在不削弱 required invariant 时恢复 branch protection/repository before；
5. 重读全部 before hash；
6. 退出 admin session，停止并提交 failure evidence。

无法证明 ruleset restoration 时，不继续编辑来制造“干净外观”，按 governance incident
处理。

## J. Evidence/done boundary

- execution receipt/evidence PR：facts only，零状态翻转；
- operability-evidence PR：记录上一 PR normal merge；
- done PR：只含状态/evidence pointers；
- BAP supersession 与 HLR readiness：后续独立 PR；
- change verification：最后独立 PR。
