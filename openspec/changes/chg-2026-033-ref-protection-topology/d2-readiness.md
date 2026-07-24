# TASK-RPT-001 full topology D2 readiness — exhausted #470 record

> Status:EXHAUSTED / NON-EXECUTABLE. This exact file was reviewed and merged
> in #470, executed once, and ended `fail_closed`. Its window, payloads,
> hashes, script and UUIDs must not be rerun, repaired or cited as current
> readiness.
>
> Historical scope below is preserved for audit. #472 records the execution
> facts. A successor is forbidden until CHG-2026-033 r3 is independently
> approved and a new readiness replaces every pin from fresh protected main.

## 0. #470 outcome and successor stop gate

The #470 executor stopped after a successful multi-level ref update because
one immediate Git-ref REST read returned the prior OID. Later `ls-remote` and
the automatically opened #471 head showed the expected updated OID. The run
rolled back; `main` did not change; no topology AC passed.

The old ruleset again covers main. #471 is closed/unmerged. The exact residual
ref remains:

```text
refs/heads/agent/rpt001/deep/7908274d-d874-47d6-b844-c2e35ba9d2a9
2e1e5ce85266f96f54eb60d9f2547398d1c9b3e7
```

Do not delete, move or reuse it outside the successor exact D2 plan. The
successor must use fresh authenticated before JSON, Git/REST bounded
convergence, `[skip actions]` probe tips, workflow/PR side-effect assertions,
conditional pre-rollback ref cleanup and new UUIDs/window/operator hashes.
Nothing below authorizes another write.

## A. Authority and fresh protected-main discovery

```yaml
schema: arkdeck-rpt001-topology-readiness/v1
change: CHG-2026-033-ref-protection-topology@r2
task: TASK-RPT-001
task_status: ready
operator: lvye
executor: human
credential_location: isolated, Agent-unreachable
repository: ArkDeck/ArkDeck
api_version: 2026-03-10
ruleset_id: 19595282
readiness_pr: 470
readiness_title: "governance(TASK-RPT-001): authorize topology D2"
readiness_head_ref: agent/task-rpt-001-topology-readiness
readiness_changed_files:
  - openspec/changes/chg-2026-033-ref-protection-topology/d2-readiness.md
capture_schema: arkdeck-rpt001-discovery/v2
capture_classification: GET-only; zero credential values; zero external writes
capture_timestamp_utc: 2026-07-24T09:55:28.718872Z
capture_main_oid: e36aba91f1d88dd74330a4e61ebde4027071a9f9
capture_canonical_bytes_without_lf: 21078
capture_canonical_sha256: 6accb60b8e04b286eee85501ab9b31d476d0cc9fedd5bb5f0a4a14645e8ab430
capture_file_bytes_with_lf: 21079
capture_file_sha256: 4cd34aa394a440de20d2e180a07fc0bdd2b98deb73ac9fa500169b7d8c3346c6
capture_script_sha256: 487701e6602ddd20a8d18db6bfce59d58f4597dc7ea3b15e171f45e8934d637a
capture_wrapper_sha256: 82e612aaf429e36a3f3ab53b988bc096eb5adf3a8fa54b716f96c9b8117536d8
apply_script_sha256: 124f9b799169fda8e3b0814442accf925f51efffdb2b7165acb7063743dd8f2c
```

The capture was produced in a separate human-controlled Terminal as exact
`lvye` (user ID `4340161`). The human session was logged out before these
bytes returned to the Agent. Independent Agent-side checks after handoff
found no GitHub token environment variable and `gh auth status` reported no
logged-in host.

The capture file itself was independently reparsed and reproduced as
canonical UTF-8 JSON plus one trailing LF. All 11 embedded artifacts
reproduced their declared canonical byte count and SHA-256:

| Artifact | Bytes | SHA-256 |
| --- | ---: | --- |
| `active_main_rules` | 335 | `560eff7e8ecceb7b044a19634c7e559a8b0411b486717a97c05896246a3c7137` |
| `actor_inventory` | 4,520 | `feb3e80c5b5070136fbc423a459fb8111d9b352c559cb2c09eb8cf041cfddfac` |
| `branch_main` | 5,410 | `6cda233d819c4c772d8fd4512e340b87c9d33c4b11dc4aad87b77e6cb9d47ac7` |
| `branch_protection_full` | 1,227 | `e45fb8583eb8002e49fcd402c0d9026f7277a1b823b6fe7410695da5666f0b0c` |
| `open_pull_requests` | 607 | `0a8d7d2b9940e7d12fe129174c8ec00b01d728512e353438817abffb2822ecbb` |
| `organization_settings` | 482 | `db3047ad7868abfb58303681c011c7c6a4ebe79de8a7d0e3166760320d297b09` |
| `pin_blobs` | 1,716 | `4d8319c41877fb0d89811000c5417a576b67f2d1b2538f2413c234cef6dc6734` |
| `remote_refs` | 1,068 | `6c2fd09009f3b9ac5e7071280660d10e8aa70bab96eefe7ca6dd368e0773d7e9` |
| `repository_settings` | 660 | `8f605ec84f4d83ef6a860c238e1c506cacd1ab8c85ecb90448bdf2a684daf3f7` |
| `ruleset_full` | 702 | `a5725db245d84174090de47e1fc45123219dbf5cfdd00d45856b04d801a3d5f2` |
| `rulesets_full` | 438 | `a603d5a0af93112475f4e92a597b16c515b9eebe320cbab98f7bd26b0d9487b0` |

This is a new topology readiness. It does not inherit authority from the
bootstrap recovery or any earlier HLR/readiness.

## B. Current diagnosis and quiescence

Protected main at capture was:

```text
e36aba91f1d88dd74330a4e61ebde4027071a9f9
evidence(TASK-RPT-001): record bootstrap recovery success (#469)
parent: ef13965fb2e0c98a24bffbbf1033f7d34d8076ba
```

The bootstrap evidence proves only that the ordinary bot-authored PR
transport is live again. It does not pass a topology AC.

Exactly one unrelated PR was open:

```json
[{"base_ref":"main","base_sha":"9de9c63f7fe17069ad50ff0a73fc171ce6a14ec8","changed_files":["openspec/changes/chg-2026-026-macos-rockchip-flash-ui/evidence/README.md","openspec/changes/chg-2026-026-macos-rockchip-flash-ui/evidence/runs/TASK-RKFUI-001A/blocked-capability-preflight-maskrom-still-present-2026-07-24.json","openspec/changes/chg-2026-026-macos-rockchip-flash-ui/evidence/runs/TASK-RKFUI-001A/blocked-capability-preflight-maskrom-still-present-2026-07-24.md"],"draft":false,"head_ref":"agent/rkfui-001a-e0-capability-preflight","head_sha":"9ecbb7a1de6a6504b1a72281d4f122a0f7590def","number":468}]
```

It does not overlap this readiness, the settings inputs or any probe ref.
Before execution it must still be the only open PR; merge, close, head/path
change or any additional open PR is drift and stops dispatch.

All captured remote branch refs were:

| Ref | OID |
| --- | --- |
| `refs/heads/main` | `e36aba91f1d88dd74330a4e61ebde4027071a9f9` |
| `refs/heads/agent/chg-2026-029-r5-remediation` | `21be4ce872e9b673712efa1d65f3b934a45f8f46` |
| `refs/heads/agent/obs-001-observability` | `3c7f049bb5dac137351f6f6eb4bbfbbb3ab1d2a0` |
| `refs/heads/agent/rkfui-001-identity-separation-readiness` | `53bbec764c645978accb8020415a64e6fe7ce1b4` |
| `refs/heads/agent/rkfui-001a-e0-capability-preflight` | `9ecbb7a1de6a6504b1a72281d4f122a0f7590def` |
| `refs/heads/agent/task-hlr-002-readiness` | `8c39aab06f03538c9f95bfbc7ccb17b44f110fae` |
| `refs/heads/agent/task-hlr-002a-bootstrap-partition` | `6744d353b42faf8da15314c09f3465749be05f77` |
| `refs/heads/agent/task-mech-002` | `66474de216bc1ae80e59a6ba7d1ea12ca1f76a07` |
| `refs/heads/agent/task-rpt-001-failure-evidence` | `a95d6c879ccc7c3e251a42f98a048ce8123c4659` |
| `refs/heads/agent/task-tr-003` | `bee1f96420f8a70c6652be1ae9bd1c97386405a2` |

There was no main-external ordinary branch. At execution the list must be
identical except that:

- main must be the exact squash merge of this readiness, whose single parent
  is the captured main;
- the readiness branch may already have been deleted by
  `delete_branch_on_merge=true`, or may still exist at the exact reviewed PR
  head;
- no other ref/OID drift is accepted.

## C. Complete authenticated before

Canonicalization is UTF-8, recursively sorted object keys, compact
separators and no trailing LF.

### Ruleset `19595282` full response

```json
{"_links":{"html":{"href":"https://github.com/ArkDeck/ArkDeck/rules/19595282"},"self":{"href":"https://api.github.com/repos/ArkDeck/ArkDeck/rulesets/19595282"}},"bypass_actors":[{"actor_id":4340161,"actor_type":"User","bypass_mode":"always"}],"conditions":{"ref_name":{"exclude":["refs/heads/agent/**"],"include":["~ALL"]}},"created_at":"2026-07-23T10:20:11.391+08:00","current_user_can_bypass":"always","enforcement":"active","id":19595282,"name":"agent-ref-boundary","node_id":"RRS_lACqUmVwb3NpdG9yec5Na16-zgErABI","rules":[{"type":"creation"},{"type":"update"},{"type":"deletion"}],"source":"ArkDeck/ArkDeck","source_type":"Repository","target":"branch","updated_at":"2026-07-23T10:20:11.425+08:00"}
```

```yaml
bytes: 702
sha256: a5725db245d84174090de47e1fc45123219dbf5cfdd00d45856b04d801a3d5f2
current_user_can_bypass: always
sole_bypass_actor: "User 4340161 / lvye"
```

Authenticated active-main evaluation was exactly:

```json
[{"ruleset_id":19595282,"ruleset_source":"ArkDeck/ArkDeck","ruleset_source_type":"Repository","type":"creation"},{"ruleset_id":19595282,"ruleset_source":"ArkDeck/ArkDeck","ruleset_source_type":"Repository","type":"update"},{"ruleset_id":19595282,"ruleset_source":"ArkDeck/ArkDeck","ruleset_source_type":"Repository","type":"deletion"}]
```

### Main branch protection full response

```json
{"allow_deletions":{"enabled":false},"allow_force_pushes":{"enabled":false},"allow_fork_syncing":{"enabled":false},"block_creations":{"enabled":false},"enforce_admins":{"enabled":false,"url":"https://api.github.com/repos/ArkDeck/ArkDeck/branches/main/protection/enforce_admins"},"lock_branch":{"enabled":false},"required_conversation_resolution":{"enabled":false},"required_linear_history":{"enabled":true},"required_pull_request_reviews":{"dismiss_stale_reviews":true,"require_code_owner_reviews":true,"require_last_push_approval":false,"required_approving_review_count":1,"url":"https://api.github.com/repos/ArkDeck/ArkDeck/branches/main/protection/required_pull_request_reviews"},"required_signatures":{"enabled":false,"url":"https://api.github.com/repos/ArkDeck/ArkDeck/branches/main/protection/required_signatures"},"required_status_checks":{"checks":[{"app_id":15368,"context":"guard"}],"contexts":["guard"],"contexts_url":"https://api.github.com/repos/ArkDeck/ArkDeck/branches/main/protection/required_status_checks/contexts","strict":true,"url":"https://api.github.com/repos/ArkDeck/ArkDeck/branches/main/protection/required_status_checks"},"url":"https://api.github.com/repos/ArkDeck/ArkDeck/branches/main/protection"}
```

```yaml
bytes: 1227
sha256: e45fb8583eb8002e49fcd402c0d9026f7277a1b823b6fe7410695da5666f0b0c
```

Known gap: `enforce_admins=false` and push `restrictions` are absent. Existing
PR/review/CODEOWNER/strict App-bound guard/linear history/force/delete
settings are already present. The old ruleset still covers main during this
gap.

### Repository, Actions and actor before

```json
{"fields":{"allow_auto_merge":false,"allow_forking":true,"allow_merge_commit":true,"allow_rebase_merge":true,"allow_squash_merge":true,"allow_update_branch":false,"archived":false,"default_branch":"main","delete_branch_on_merge":true,"disabled":false,"full_name":"ArkDeck/ArkDeck","id":1298882238,"is_template":false,"merge_commit_message":"PR_TITLE","merge_commit_title":"MERGE_MESSAGE","name":"ArkDeck","node_id":"R_kgDOTWtevg","private":false,"squash_merge_commit_message":"COMMIT_MESSAGES","squash_merge_commit_title":"COMMIT_OR_PR_TITLE","visibility":"public","web_commit_signoff_required":false},"missing_known_fields":["use_squash_pr_title_as_default"]}
```

```yaml
bytes: 660
sha256: 8f605ec84f4d83ef6a860c238e1c506cacd1ab8c85ecb90448bdf2a684daf3f7
```

```json
{"can_approve_pull_request_reviews":true,"default_workflow_permissions":"read"}
```

```yaml
bytes: 79
sha256: e4eea28a28f0c12dc5a441d5d6451c4bc7f3f72ed8f0b717c6cb5502e825965d
mutation_budget: 0
```

The full actor artifact records:

- sole collaborator, organization member and administrator:
  `lvye` / ID `4340161`;
- sole Deploy Key: `arkdeck-agent-writer` / ID `158088026`, write-enabled and
  verified;
- repository teams, outside collaborators, pending invitations and GitHub
  App installations: empty;
- every listed organization-role assignment: empty;
- ruleset bypass: only `lvye`;
- main push restrictions before: absent;
- workflow permissions: exact `true/read`.

The full actor artifact is 4,520 bytes with SHA-256
`feb3e80c5b5070136fbc423a459fb8111d9b352c559cb2c09eb8cf041cfddfac`.
Because Deploy Key `last_used` legitimately advances when this readiness is
pushed/fetched, execution compares the complete stable projection with only
Deploy Key `created_at`/`last_used` removed:

```yaml
stable_actor_projection_bytes: 4449
stable_actor_projection_sha256: cdd8fc98d2a1fccbbb619c4ddf987975aa7a97f971754542bd0ccde383b293d0
```

No Deploy Key, Actions identity, App, team, role or integration appears in
ruleset bypass or a main push allowlist.

### Protected-main blob pins

Except for this readiness file, whose reviewed-head blob must equal its merge
tree blob, execution pins:

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
| CHG-2026-033 `proposal.md` | `3a5476dc785a2f824e15caca379f0caf78880233` |
| CHG-2026-033 `design.md` | `99d93a3be78ec0d21d789d0f6824b18f6b1813a1` |
| CHG-2026-033 `tasks.md` | `10b095e34a35c06489cbbaea628502fcd51f230f` |
| CHG-2026-033 `verification.md` | `48a990bba60ea4e7679cf08d01c247fee0a98ac4` |
| `openspec/governance/enforcement.md` | `e8ff3c130e1b8b15f8405d150ad567e774a0d82b` |
| `openspec/governance/host-loop-runbook.md` | `70e0bcc5b736a896f0329e24a89e273164762558` |

`enforcement.md`, `AGENTS.md`, Constitution and Core specs/contracts remain
byte-for-byte unchanged because the high-level invariants do not change.

## D. Exact write, read-back and rollback objects

Every request uses:

```text
Accept: application/vnd.github+json
X-GitHub-Api-Version: 2026-03-10
```

No UI field-by-field edit, endpoint substitution, payload repair, retry with
different JSON or hash recalculation is authorized inside the window.

### Main branch protection

Endpoint:

```text
PUT /repos/ArkDeck/ArkDeck/branches/main/protection
```

Exact after write payload:

```json
{"allow_deletions":false,"allow_force_pushes":false,"allow_fork_syncing":false,"block_creations":false,"enforce_admins":true,"lock_branch":false,"required_conversation_resolution":false,"required_linear_history":true,"required_pull_request_reviews":{"bypass_pull_request_allowances":{"apps":[],"teams":[],"users":[]},"dismiss_stale_reviews":true,"dismissal_restrictions":{"apps":[],"teams":[],"users":[]},"require_code_owner_reviews":true,"require_last_push_approval":false,"required_approving_review_count":1},"required_status_checks":{"checks":[{"app_id":15368,"context":"guard"}],"strict":true},"restrictions":{"apps":[],"teams":[],"users":["lvye"]}}
```

```yaml
bytes: 653
sha256: 7aee2cf84a64bd8e0b9b43d5506b2705456266ae9bd1a9617d4bd3585cead5f9
legacy_contexts_member_in_write_payload: absent
```

This intentionally uses only the App-bound `checks` input alternative. The
exhausted #467 request used `checks` and legacy `contexts` together and was
rejected by GitHub's `anyOf`/`oneOf` schema. The GET response is still
expected to derive and display `contexts:["guard"]`; a response field is not
copied back into the mutually exclusive write payload.

Exact required authenticated read-back projection:

```json
{"allow_deletions":false,"allow_force_pushes":false,"allow_fork_syncing":false,"block_creations":false,"enforce_admins":true,"lock_branch":false,"required_conversation_resolution":false,"required_linear_history":true,"required_pull_request_reviews":{"bypass_pull_request_allowances":{"apps":[],"teams":[],"users":[]},"dismiss_stale_reviews":true,"dismissal_restrictions":{"apps":[],"teams":[],"users":[]},"require_code_owner_reviews":true,"require_last_push_approval":false,"required_approving_review_count":1},"required_status_checks":{"checks":[{"app_id":15368,"context":"guard"}],"contexts":["guard"],"strict":true},"restrictions":{"apps":[],"teams":[],"users":["lvye"]}}
```

```yaml
bytes: 674
sha256: f423ce0ca2eb3f667a34dbb7f9bcfa923266928d073ee0e50763b2f69ee2663a
```

Exact rollback write payload:

```json
{"allow_deletions":false,"allow_force_pushes":false,"allow_fork_syncing":false,"block_creations":false,"enforce_admins":false,"lock_branch":false,"required_conversation_resolution":false,"required_linear_history":true,"required_pull_request_reviews":{"bypass_pull_request_allowances":{"apps":[],"teams":[],"users":[]},"dismiss_stale_reviews":true,"dismissal_restrictions":{"apps":[],"teams":[],"users":[]},"require_code_owner_reviews":true,"require_last_push_approval":false,"required_approving_review_count":1},"required_status_checks":{"checks":[{"app_id":15368,"context":"guard"}],"strict":true},"restrictions":null}
```

```yaml
bytes: 619
sha256: ce1e5c736f50e51efa1429223ddd3b6657103e6e5c87a54fc277058a1486fb94
```

Rollback must reproduce this exact before read-back projection:

```json
{"allow_deletions":false,"allow_force_pushes":false,"allow_fork_syncing":false,"block_creations":false,"enforce_admins":false,"lock_branch":false,"required_conversation_resolution":false,"required_linear_history":true,"required_pull_request_reviews":{"bypass_pull_request_allowances":{"apps":[],"teams":[],"users":[]},"dismiss_stale_reviews":true,"dismissal_restrictions":{"apps":[],"teams":[],"users":[]},"require_code_owner_reviews":true,"require_last_push_approval":false,"required_approving_review_count":1},"required_status_checks":{"checks":[{"app_id":15368,"context":"guard"}],"contexts":["guard"],"strict":true},"restrictions":null}
```

```yaml
bytes: 640
sha256: 78606ef9437dfb40ca17bc351f43f907cc7d5bb5403e1059a556af2044bacba3
```

The script also records the complete after/rollback GET response and hash.
`required_signatures=false` is not a full-protection PUT input and must
remain false in every full GET.

### Ordinary-ref ruleset

Endpoint:

```text
PUT /repos/ArkDeck/ArkDeck/rulesets/19595282
```

Exact after write/read-back projection:

```json
{"bypass_actors":[{"actor_id":4340161,"actor_type":"User","bypass_mode":"always"}],"conditions":{"ref_name":{"exclude":["refs/heads/agent/**","refs/heads/agent/**/*","refs/heads/main"],"include":["~ALL"]}},"enforcement":"active","name":"agent-ref-boundary","rules":[{"type":"creation"},{"type":"update"},{"type":"deletion"}],"target":"branch"}
```

```yaml
bytes: 343
sha256: 9bb7ef3d62246733ca1dcaac074a3b07f5b4aead6985d645cd58fbf82db62163
```

Exact rollback write/read-back projection:

```json
{"bypass_actors":[{"actor_id":4340161,"actor_type":"User","bypass_mode":"always"}],"conditions":{"ref_name":{"exclude":["refs/heads/agent/**"],"include":["~ALL"]}},"enforcement":"active","name":"agent-ref-boundary","rules":[{"type":"creation"},{"type":"update"},{"type":"deletion"}],"target":"branch"}
```

```yaml
bytes: 301
sha256: 5943b6ce840cbb385ad83615da15ff2ee4ec5710bd696fae6140b37302042157
```

The two Agent exclusions are both intentional. Under GitHub's documented
`File::FNM_PATHNAME` matching, `*` does not cross `/`; the single- and
multi-level forms are therefore both retained.

### Zero-write invariant objects

Repository settings, Actions permissions, credentials, collaborators,
teams, Apps/installations, CODEOWNERS, reviews, merges, auto-merge and PR
state have mutation budget zero. In particular:

```json
{"allow_auto_merge":false}
```

remains a read-only invariant; no same-value repository PATCH is sent.

## E. Fresh probe names and mutation budgets

These UUIDs and refs are new and cannot be replaced in-window:

```yaml
single_agent: refs/heads/agent/rpt001-03d9fe72-51e6-4b4b-8064-cb01a632e490
multi_agent: refs/heads/agent/rpt001/deep/7908274d-d874-47d6-b844-c2e35ba9d2a9
ordinary_create: refs/heads/rpt001-ordinary-fb431b8f-7610-451e-a3e6-becb212edc44
ordinary_fixture: refs/heads/rpt001-fixture-7242a248-1925-4508-8a98-befacc875993
similar_prefix: refs/heads/agentx/rpt001-9802866e-1c73-4e37-877f-da22b5ba073f
reserved_execution_evidence: refs/heads/agent/rpt001-evidence-860a6591-9f69-4e28-8c4e-6d3305895484
```

```yaml
window_start_utc: 2026-07-24T10:30:00Z
window_end_utc: 2026-07-24T16:30:00Z
window_semantics: half-open
maximum_branch_protection_mutations: 1 after + 1 rollback
maximum_ruleset_mutations: 1 after + 1 rollback
maximum_ref_probe_attempts: 15
maximum_ref_cleanup_attempts: controlled refs only
maximum_repository_patch_mutations: 0
maximum_actions_setting_mutations: 0
maximum_credential_control_plane_mutations: 0
maximum_review_mutations: 0
maximum_merge_mutations: 0
maximum_auto_merge_mutations: 0
maximum_pr_state_mutations: 0
maximum_force_push_main_requests: 0
maximum_delete_main_requests: 0
agent_privileged_api_dispatch: 0
rollback_contact: lvye
```

The ordinary fixture is created once by isolated `lvye`, updated/deleted
negatively by the Deploy Key, then deleted once by isolated `lvye`. It exists
only long enough to prove update and deletion rejection on an existing
ordinary ref.

## F. Mandatory preflight and stop conditions

Before the first write, the exact executor must prove all of:

1. The readiness PR is the final number pinned above, bot-authored by
   `github-actions[bot]` ID `41898282`, exact title/head ref, changed-file set
   exactly this file, closed/merged, `auto_merge=null`, exact-head
   `lvye`/ID `4340161` approval and exact-head `guard=success` from App
   `15368`.
2. Current main is its single-parent squash merge; the parent is exact
   capture main, subject is exact `READINESS_TITLE (#N)`, associated PR is
   exactly the readiness PR and `mergedBy=lvye`. A nullable
   `merge_commit_sha` is accepted only as absence of a fact; a string must
   equal current main.
3. This executor's SHA-256 appears literally in the merged readiness; the
   readiness blob is identical in the reviewed head and merge tree.
4. The local worktree is clean; its `origin` is exact
   `git@github-arkdeck-agent:ArkDeck/ArkDeck.git`; fetch and `ls-remote` use
   only that Deploy Key transport.
5. All Section C full before objects, stable actor projection, pinned blobs,
   open PR and remote ref inventory match. All probe refs are absent.
6. Ruleset `updated_at` remains
   `2026-07-23T10:20:11.425+08:00`; it is active on main with exactly
   creation/update/deletion.
7. Repository auto-merge is false; Actions is exact `true/read`;
   CODEOWNERS/workflows are pinned and contain no review/merge/auto-merge or
   branch/ruleset administration route.
8. Sole collaborator/admin is `lvye`; sole Deploy Key is ID `158088026`;
   teams, Apps/installations, outside collaborators, invitations and role
   assignments remain empty.
9. The Agent-visible `gh`/connector/browser/environment/keychain/session
   contains no human `lvye` credential. The isolated human Terminal has no
   GitHub token environment variable and requires a typed isolation
   confirmation before authenticated GET.
10. Current UTC is inside the exact half-open window.

Any missing field, unexpected actor, stale exact-head review, main/PR/blob/
ref/settings drift, dirty tree, wrong remote, preexisting probe ref, hash
mismatch, expired window, API ambiguity, network-only negative result or
overlapping control-plane operation means zero first write and stop.

## G. Fail-closed execution order

The executor performs:

1. all Section F GET-only checks;
2. one exact branch-protection after PUT;
3. immediate full authenticated GET and exact after-projection comparison;
4. confirm main unchanged and `required_signatures=false`;
5. create two local unreachable commits with `git commit-tree`: one
   single-parent descendant and one merge-shaped descendant of current main;
6. Deploy Key non-force direct-main negative while both layers overlap;
7. `lvye` non-force direct-main negative while both layers overlap. Because
   `lvye` is the old ruleset's sole always-bypass actor, this rejection is
   attributable to enforced main branch protection;
8. only after both negatives pass, one exact ruleset after PUT;
9. immediate full authenticated GET, exact projection comparison and proof
   that ruleset ID `19595282` no longer evaluates on main;
10. repeat the Deploy Key non-force direct-main negative. With main now
    excluded from the ruleset, this rejection is attributable to branch
    protection alone;
11. run the fixed single/multi Agent create/update/delete matrix;
12. run ordinary-create and `agentx/**` create negatives;
13. create the ordinary fixture as `lvye`, prove Deploy Key update/delete
    rejection, then delete the fixture as `lvye`;
14. re-read main, branch protection, ruleset, repository settings, actors,
    open PRs, refs and all probe cleanup;
15. write a secret-free canonical receipt, logout `lvye`, verify logout.

No refspec uses `+` or `--force`. A main update probe is a fast-forward,
merge-shaped commit so a rejection cannot be attributed to non-fast-forward
Git behavior. A failed push counts only when the server response contains a
GitHub policy rejection marker and the target ref is unchanged; DNS,
authentication, transport or local-hook failure is not a PASS.

## H. Exact rollback and cancellation

There is no blind retry.

- After any ruleset PUT attempt, authenticated GET classifies exact before,
  exact after or unknown.
- If exact after and execution fails, restore the ruleset exact before first,
  authenticate the read-back, and prove ruleset ID `19595282` again evaluates
  on main.
- Only after main ruleset coverage is proven may branch protection be
  restored to exact before. If coverage cannot be proven, retain the stricter
  branch protection.
- After any branch-protection PUT attempt, authenticated GET classifies exact
  before projection, exact after projection or unknown. Exact after may be
  rolled back once only when the ruleset safely covers main.
- An unknown object gets no guessed write. The stricter known layer is
  retained and the task remains blocked.
- Controlled Agent refs are deleted with the Deploy Key; controlled ordinary
  refs are deleted only by isolated `lvye`. Cleanup never converts a failed
  security probe into PASS.
- If any negative main probe unexpectedly succeeds, declare a security
  incident, do not force-rewrite main, restore ruleset coverage if possible,
  retain stricter branch protection and stop.
- Interrupt, timeout, logout failure, unexpected success or cleanup
  uncertainty makes the receipt `fail_closed`.

The complete rollback GET response and hash are recorded. A projection match
with a different complete JSON hash is safe but not exact evidence; it keeps
the task blocked for a new readiness.

## I. Verification boundary

This D2 execution can establish:

- Deploy Key create/update/delete succeeds for single- and multi-level
  `agent/**`;
- Deploy Key ordinary-create, existing ordinary update/delete and
  `agentx/**` operations are rejected;
- Deploy Key direct-main is rejected both under overlap and branch-protection
  only;
- `lvye` direct-main is rejected despite being the sole main push actor;
- branch protection after has PR, one approval, CODEOWNER, strict
  `guard`/App `15368`, admin enforcement, users `[lvye]`, empty teams/apps,
  force/delete false and no PR bypass actors;
- ruleset after keeps `~ALL`, create/update/delete and sole human bypass while
  excluding only the two Agent patterns and exact main;
- Actions, Apps/integrations, repository auto-merge and governance blobs did
  not change;
- migration order never intentionally leaves main without a verified layer.

This execution deliberately sends zero real main force-push or delete
requests. Their false settings plus non-bypass direct-main negatives are the
approved proof boundary.

The following remain for independent evidence/operability PRs and are not
pre-claimed here:

- bot self-approval and any non-human review not satisfying `@lvye`
  CODEOWNER;
- unapproved and guard-red/pending PR merge rejection;
- compliant `lvye` approval + guard-success normal Squash and merge without
  the red bypass selection;
- merge subject, review, `mergedBy` and merge OID audit;
- Agent/API review, merge, enable-auto-merge and Administration routes being
  rejected or unconstructible under the final actor inventory.

The execution-evidence PR records only settings/ref facts. It is then merged
under the new topology. A separate operability-evidence PR records the
no-bypass human merge and remaining route/PR negatives. Only after both are
merged may a separate D0 PR propose `TASK-RPT-001 ready → done`.

## J. Explicit supersession and zero reuse

- #435 and every old HLR-002A OID, window, payload, hash, script, probe UUID
  and ref remain invalid.
- #462, #463 and #467 topology readiness/script/window/payload/probe sets are
  exhausted and cannot be repaired or replayed.
- #459/#466 bootstrap carriers, their captures, OIDs, windows, payloads and
  scripts are transport-recovery history only.
- The successful parser recovery and #469 evidence do not authorize this
  migration.
- CHG-2026-030 r7 remains current and keeps Agent-operated settings mutation
  blocked.
- This readiness has a new protected-main parent, capture, script hash,
  checks-only branch-protection payload, window and UUID set. None may be
  substituted in-window.

Historical BAP-CRED-001 evidence remains true for its execution date, but its
old mechanism description is not sufficient for the post-migration current
claim. Append-only BAP/HLR supersession and a fresh HLR-002A readiness belong
to blocked `TASK-RPT-002`, after TASK-RPT-001 evidence/done. Neither
`enforcement.md` nor `AGENTS.md` is modified: their high-level invariants are
preserved exactly.

## K. Human invocation after merge only

Before execution, independently verify:

```text
shasum -a 256 /private/tmp/arkdeck-rpt001-topology-apply.py
```

It must equal the exact `apply_script_sha256` in Section A. Then, only in a
separate human Terminal inside the window:

```text
python3 /private/tmp/arkdeck-rpt001-topology-apply.py \
  --repo /Users/fuhanfeng/.codex/worktrees/b1b2/ArkDeck
```

The script automatically logs out `lvye` and writes:

```text
/private/tmp/arkdeck-rpt001-topology-apply-report.json
```

Return only the secret-free report and its SHA-256 after
`logout_verified=true`. Do not paste a token, device code, cookie, keychain
entry or raw credential output.
