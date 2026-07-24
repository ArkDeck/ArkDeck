# TASK-RPT-001 r3 full topology D2 readiness

> Status:DRAFT / NON-EXECUTABLE until this exact file is reviewed and merged
> by `lvye`. This document replaces the exhausted #470 readiness; it does not
> mark TASK-RPT-001 approved, done or verified.

## A. Authority and fresh protected-main discovery

```yaml
schema: arkdeck-rpt001-topology-readiness/v2
change: CHG-2026-033-ref-protection-topology@r3
task: TASK-RPT-001
task_status: ready
operator: lvye
executor: human
credential_location: isolated, Agent-unreachable
repository: ArkDeck/ArkDeck
api_version: 2026-03-10
ruleset_id: 19595282
readiness_pr: 0
readiness_title: "governance(TASK-RPT-001): authorize r3 topology D2"
readiness_head_ref: agent/task-rpt-001-r3-topology-readiness
readiness_changed_files:
  - openspec/changes/chg-2026-033-ref-protection-topology/d2-readiness.md
capture_schema: arkdeck-rpt001-discovery/v3
capture_classification: GET-only; zero credential values; zero external writes
capture_timestamp_utc: 2026-07-24T11:34:10.230244Z
capture_main_oid: d94e8f8378fabd14323dddc1ba138391d9dad09c
capture_canonical_bytes_without_lf: 31408
capture_canonical_sha256: 35f2f73aa8bd8b5c2f157a19c489aac166b73a49bb3edd85e484317ee7675782
capture_file_bytes_with_lf: 31409
capture_file_sha256: 715029efd426f1d1f461f974667c320a2c1847cc08e378bf7079dc8de4708ca7
capture_script_sha256: 0f72c5b7485814cfdd11282b75d53585ed16db6e8b2d7ee28fb25d3640ed2d2d
capture_wrapper_sha256: 2016cbbfa14bdc6590e1eee3f00f25c64114d0e35e3af41b2d7638158854469b
apply_script_sha256: ececc4a5edd485cae8ec98982adee1d308aad7084d5a6d55e3a9371803c32917
```

The capture was produced in a separate human Terminal as exact `lvye`
(user ID `4340161`). It declared zero credential values and zero writes,
contained no sensitive credential environment-variable name, and was returned
only after the wrapper logged out. Independent Agent-side `gh auth status`
then reported no logged-in GitHub host.

The capture reparses as canonical UTF-8 JSON plus one trailing LF. Every
embedded artifact reproduces its declared byte count and SHA-256:

| Artifact | Bytes | SHA-256 |
| --- | ---: | --- |
| `active_main_rules` | 335 | `560eff7e8ecceb7b044a19634c7e559a8b0411b486717a97c05896246a3c7137` |
| `actor_inventory` | 4,520 | `feb3e80c5b5070136fbc423a459fb8111d9b352c559cb2c09eb8cf041cfddfac` |
| `branch_main` | 5,390 | `71e3915860d8b319e05e4bb213c4615bdff81bb1d965b1901c597e6906eb52df` |
| `branch_protection_full` | 1,613 | `7e30197b45effc98224943ebe383c45993cecf31a105dcd52f4a14103e5ea7ab` |
| `open_pull_requests` | 607 | `0a8d7d2b9940e7d12fe129174c8ec00b01d728512e353438817abffb2822ecbb` |
| `organization_settings` | 482 | `db3047ad7868abfb58303681c011c7c6a4ebe79de8a7d0e3166760320d297b09` |
| `pin_blobs` | 1,812 | `41d8a48eb13c01b62d852a6c317d4c415e65fdc9b5fe61a5adbdbd5d27955072` |
| `relevant_pull_requests` | 7,720 | `ee838ed507ac9be5a1d30af7ee4768d85e21c88fdd059854a41f35c9257c6f28` |
| `remote_refs` | 1,200 | `0db696c1bdffb7ed5dda82399122755e07bc480a284b40082dc907f931d7d79c` |
| `repository_settings` | 660 | `8f605ec84f4d83ef6a860c238e1c506cacd1ab8c85ecb90448bdf2a684daf3f7` |
| `ruleset_full` | 702 | `0fd4b6393837e82d6f211ba826728f0db612bad0e200194bf341e5d977676e9b` |
| `rulesets_full` | 438 | `02994ffbe52d928dd2ec8c41ae9bbee9d6e6456dac7e06fb1008658c97c4cbd2` |
| `workflow_files` | 435 | `05d9f262a2d76581ca925bddd937e775ac4a5ef594deb1022fa3816036f97f78` |

This is independent r3 readiness. It inherits no execution authority from
#435, #467, #470, either bootstrap carrier, or any earlier HLR readiness.

## B. Current diagnosis, history and quiescence

Protected main at capture:

```text
d94e8f8378fabd14323dddc1ba138391d9dad09c
governance(CHG-2026-033): approve ref probe remediation (#474)
parent: 6153d581d7caf1bd1ed3335171318b3e92250926
```

#474 was bot-authored, changed only the approved r3 governance paths, had
exact-head `lvye` approval and App `15368` `guard=success`, and was merged by
`lvye` at `2026-07-24T11:26:53Z`. It authorizes drafting this fresh readiness,
not the writes in this file before this file itself is reviewed and merged.

Historical boundaries are fixed:

- #470 was merged and executed once; its script, window, hashes, payload
  instance and UUIDs are exhausted.
- #470 ended `fail_closed`; its partial probe success is not an AC PASS.
- #471 is closed, unmerged and has no changed files.
- #472 preserves the #470 failure facts.
- #473 and #474 are the r3 proposal and approval-only gates.

Exactly one unrelated PR was open:

```json
[{"base_ref":"main","base_sha":"9de9c63f7fe17069ad50ff0a73fc171ce6a14ec8","changed_files":["openspec/changes/chg-2026-026-macos-rockchip-flash-ui/evidence/README.md","openspec/changes/chg-2026-026-macos-rockchip-flash-ui/evidence/runs/TASK-RKFUI-001A/blocked-capability-preflight-maskrom-still-present-2026-07-24.json","openspec/changes/chg-2026-026-macos-rockchip-flash-ui/evidence/runs/TASK-RKFUI-001A/blocked-capability-preflight-maskrom-still-present-2026-07-24.md"],"draft":false,"head_ref":"agent/rkfui-001a-e0-capability-preflight","head_sha":"9ecbb7a1de6a6504b1a72281d4f122a0f7590def","number":468}]
```

It does not overlap this topology. At execution it must still be the only
open PR with this exact projection; any merge, close, head/path change or
additional open PR is drift and stops before the first write.

All remote branches at capture:

| Ref | OID |
| --- | --- |
| `refs/heads/main` | `d94e8f8378fabd14323dddc1ba138391d9dad09c` |
| `refs/heads/agent/chg-2026-029-r5-remediation` | `21be4ce872e9b673712efa1d65f3b934a45f8f46` |
| `refs/heads/agent/obs-001-observability` | `3c7f049bb5dac137351f6f6eb4bbfbbb3ab1d2a0` |
| `refs/heads/agent/rkfui-001-identity-separation-readiness` | `53bbec764c645978accb8020415a64e6fe7ce1b4` |
| `refs/heads/agent/rkfui-001a-e0-capability-preflight` | `9ecbb7a1de6a6504b1a72281d4f122a0f7590def` |
| `refs/heads/agent/rpt001/deep/7908274d-d874-47d6-b844-c2e35ba9d2a9` | `2e1e5ce85266f96f54eb60d9f2547398d1c9b3e7` |
| `refs/heads/agent/task-hlr-002-readiness` | `8c39aab06f03538c9f95bfbc7ccb17b44f110fae` |
| `refs/heads/agent/task-hlr-002a-bootstrap-partition` | `6744d353b42faf8da15314c09f3465749be05f77` |
| `refs/heads/agent/task-mech-002` | `66474de216bc1ae80e59a6ba7d1ea12ca1f76a07` |
| `refs/heads/agent/task-rpt-001-failure-evidence` | `a95d6c879ccc7c3e251a42f98a048ce8123c4659` |
| `refs/heads/agent/task-tr-003` | `bee1f96420f8a70c6652be1ae9bd1c97386405a2` |

There is no non-main ordinary branch. At execution the list must be identical
except that main is the single-parent squash merge of this readiness and the
readiness branch may be deleted or remain at its exact reviewed head.

## C. Complete authenticated before

Canonicalization is UTF-8, recursively sorted object keys, compact separators
and no trailing LF.

### Ruleset `19595282`

```json
{"_links":{"html":{"href":"https://github.com/ArkDeck/ArkDeck/rules/19595282"},"self":{"href":"https://api.github.com/repos/ArkDeck/ArkDeck/rulesets/19595282"}},"bypass_actors":[{"actor_id":4340161,"actor_type":"User","bypass_mode":"always"}],"conditions":{"ref_name":{"exclude":["refs/heads/agent/**"],"include":["~ALL"]}},"created_at":"2026-07-23T10:20:11.391+08:00","current_user_can_bypass":"always","enforcement":"active","id":19595282,"name":"agent-ref-boundary","node_id":"RRS_lACqUmVwb3NpdG9yec5Na16-zgErABI","rules":[{"type":"creation"},{"type":"update"},{"type":"deletion"}],"source":"ArkDeck/ArkDeck","source_type":"Repository","target":"branch","updated_at":"2026-07-24T18:45:53.061+08:00"}
```

```yaml
bytes: 702
sha256: 0fd4b6393837e82d6f211ba826728f0db612bad0e200194bf341e5d977676e9b
current_user_can_bypass: always
sole_bypass_actor: "User 4340161 / lvye"
```

Authenticated active-main evaluation is exactly the three rules
`creation`, `update` and `deletion` from ruleset `19595282`; canonical bytes
`335`, SHA-256
`560eff7e8ecceb7b044a19634c7e559a8b0411b486717a97c05896246a3c7137`.

### Main branch protection

```json
{"allow_deletions":{"enabled":false},"allow_force_pushes":{"enabled":false},"allow_fork_syncing":{"enabled":false},"block_creations":{"enabled":false},"enforce_admins":{"enabled":false,"url":"https://api.github.com/repos/ArkDeck/ArkDeck/branches/main/protection/enforce_admins"},"lock_branch":{"enabled":false},"required_conversation_resolution":{"enabled":false},"required_linear_history":{"enabled":true},"required_pull_request_reviews":{"dismiss_stale_reviews":true,"dismissal_restrictions":{"apps":[],"teams":[],"teams_url":"https://api.github.com/repos/ArkDeck/ArkDeck/branches/main/protection/dismissal_restrictions/teams","url":"https://api.github.com/repos/ArkDeck/ArkDeck/branches/main/protection/dismissal_restrictions","users":[],"users_url":"https://api.github.com/repos/ArkDeck/ArkDeck/branches/main/protection/dismissal_restrictions/users"},"require_code_owner_reviews":true,"require_last_push_approval":false,"required_approving_review_count":1,"url":"https://api.github.com/repos/ArkDeck/ArkDeck/branches/main/protection/required_pull_request_reviews"},"required_signatures":{"enabled":false,"url":"https://api.github.com/repos/ArkDeck/ArkDeck/branches/main/protection/required_signatures"},"required_status_checks":{"checks":[{"app_id":15368,"context":"guard"}],"contexts":["guard"],"contexts_url":"https://api.github.com/repos/ArkDeck/ArkDeck/branches/main/protection/required_status_checks/contexts","strict":true,"url":"https://api.github.com/repos/ArkDeck/ArkDeck/branches/main/protection/required_status_checks"},"url":"https://api.github.com/repos/ArkDeck/ArkDeck/branches/main/protection"}
```

```yaml
bytes: 1613
sha256: 7e30197b45effc98224943ebe383c45993cecf31a105dcd52f4a14103e5ea7ab
```

The complete GET proves the current gap is only
`enforce_admins=false` plus absent push restrictions. PR review,
CODEOWNER, strict App-bound `guard`, linear history, force-push false and
delete false already exist. The old ruleset still covers main during this
gap. The full before differs from #470 because GitHub has materialized empty
`dismissal_restrictions`; #470's full hash is not reused.

### Repository, Actions and actor before

```json
{"fields":{"allow_auto_merge":false,"allow_forking":true,"allow_merge_commit":true,"allow_rebase_merge":true,"allow_squash_merge":true,"allow_update_branch":false,"archived":false,"default_branch":"main","delete_branch_on_merge":true,"disabled":false,"full_name":"ArkDeck/ArkDeck","id":1298882238,"is_template":false,"merge_commit_message":"PR_TITLE","merge_commit_title":"MERGE_MESSAGE","name":"ArkDeck","node_id":"R_kgDOTWtevg","private":false,"squash_merge_commit_message":"COMMIT_MESSAGES","squash_merge_commit_title":"COMMIT_OR_PR_TITLE","visibility":"public","web_commit_signoff_required":false},"missing_known_fields":["use_squash_pr_title_as_default"]}
```

Repository projection: 660 bytes, SHA-256
`8f605ec84f4d83ef6a860c238e1c506cacd1ab8c85ecb90448bdf2a684daf3f7`.

```json
{"can_approve_pull_request_reviews":true,"default_workflow_permissions":"read"}
```

Actions workflow permission: 79 bytes, SHA-256
`e4eea28a28f0c12dc5a441d5d6451c4bc7f3f72ed8f0b717c6cb5502e825965d`;
mutation budget zero.

The complete actor artifact proves:

- sole collaborator, organization member and administrator:
  `lvye` / ID `4340161`;
- sole Deploy Key: `arkdeck-agent-writer` / ID `158088026`, write-enabled,
  enabled and verified;
- repository teams, outside collaborators, pending invitations and GitHub
  App installations are empty;
- every listed organization-role assignment is empty;
- ruleset bypass contains only `lvye`;
- main push restrictions are absent before;
- workflow defaults remain exact `true/read`.

The full actor artifact is 4,520 bytes with SHA-256
`feb3e80c5b5070136fbc423a459fb8111d9b352c559cb2c09eb8cf041cfddfac`.
After removing only Deploy Key `created_at` and `last_used`, the stable
projection is 4,449 bytes with SHA-256
`cdd8fc98d2a1fccbbb619c4ddf987975aa7a97f971754542bd0ccde383b293d0`.
No Deploy Key, Actions identity, App, team, role or integration appears in
ruleset bypass or a main push allowlist.

### Protected-main pins

Except for this readiness file, whose reviewed-head blob must equal its merge
tree blob, execution pins:

| Path | Blob OID |
| --- | --- |
| `.github/CODEOWNERS` | `f4edd22f87965efcfc27ea512283a0c2252bf0fb` |
| `.github/workflows/agent-pr.yml` | `41426544637db25224dc6c6b3718abd4ebbfca7c` |
| `.github/workflows/sdd-guard.yml` | `809147e462512d970813d1992a3fcdf41f8b4b10` |
| `.github/workflows/swift-ci.yml` | `640065f3f3849e1add0cc6bfa92078873eb315ef` |
| `AGENTS.md` | `3c2d3c6a01d3eaa31cd9e3ee333f3153552f4164` |
| CHG-2026-030 `proposal.md` | `890a40585b2898c0fd9e7d2b72f5b2a8e81b515c` |
| CHG-2026-030 `design.md` | `7e2e20bfb884875de32cbbeb5f0399df7a137056` |
| CHG-2026-030 `tasks.md` | `7fc3c14bb207facec9d330a8d74b23fb9aefdb58` |
| CHG-2026-030 `verification.md` | `49f284b397006fa8626e76ec2fa51f5d9a88e307` |
| CHG-2026-033 `proposal.md` | `765e6f5fdba0cb616ffaad33fa6dc7a472555bd3` |
| CHG-2026-033 `design.md` | `53f3aec7d26f5f1db8a461bacea73c9707c116f6` |
| CHG-2026-033 `tasks.md` | `b73a543333873298228c602b28b2639852947c56` |
| CHG-2026-033 `verification.md` | `d44ff4d6610a1727b7c8587978f563e42ae57407` |
| `openspec/governance/enforcement.md` | `e8ff3c130e1b8b15f8405d150ad567e774a0d82b` |
| `openspec/governance/host-loop-runbook.md` | `70e0bcc5b736a896f0329e24a89e273164762558` |

The workflow inventory is exactly those three workflow files. Their pinned
events are only `push` and/or `pull_request`; none has
`pull_request_target`, `workflow_run`, `workflow_dispatch`,
`repository_dispatch`, `schedule` or an administration/review/merge route.

## D. Exact writes, read-back projections and rollback

Every request uses:

```text
Accept: application/vnd.github+json
X-GitHub-Api-Version: 2026-03-10
```

No UI edit, endpoint substitution, payload repair, blind retry or in-window
hash recalculation is authorized.

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

Exact required authenticated read-back projection:

```json
{"allow_deletions":false,"allow_force_pushes":false,"allow_fork_syncing":false,"block_creations":false,"enforce_admins":true,"lock_branch":false,"required_conversation_resolution":false,"required_linear_history":true,"required_pull_request_reviews":{"bypass_pull_request_allowances":{"apps":[],"teams":[],"users":[]},"dismiss_stale_reviews":true,"dismissal_restrictions":{"apps":[],"teams":[],"users":[]},"require_code_owner_reviews":true,"require_last_push_approval":false,"required_approving_review_count":1},"required_status_checks":{"checks":[{"app_id":15368,"context":"guard"}],"contexts":["guard"],"strict":true},"restrictions":{"apps":[],"teams":[],"users":["lvye"]}}
```

Projection: 674 bytes, SHA-256
`f423ce0ca2eb3f667a34dbb7f9bcfa923266928d073ee0e50763b2f69ee2663a`.
The full server-normalized after response is also recorded and hashed.

Exact rollback write payload:

```json
{"allow_deletions":false,"allow_force_pushes":false,"allow_fork_syncing":false,"block_creations":false,"enforce_admins":false,"lock_branch":false,"required_conversation_resolution":false,"required_linear_history":true,"required_pull_request_reviews":{"bypass_pull_request_allowances":{"apps":[],"teams":[],"users":[]},"dismiss_stale_reviews":true,"dismissal_restrictions":{"apps":[],"teams":[],"users":[]},"require_code_owner_reviews":true,"require_last_push_approval":false,"required_approving_review_count":1},"required_status_checks":{"checks":[{"app_id":15368,"context":"guard"}],"strict":true},"restrictions":null}
```

Write payload: 619 bytes, SHA-256
`ce1e5c736f50e51efa1429223ddd3b6657103e6e5c87a54fc277058a1486fb94`.

Exact rollback read-back projection:

```json
{"allow_deletions":false,"allow_force_pushes":false,"allow_fork_syncing":false,"block_creations":false,"enforce_admins":false,"lock_branch":false,"required_conversation_resolution":false,"required_linear_history":true,"required_pull_request_reviews":{"bypass_pull_request_allowances":{"apps":[],"teams":[],"users":[]},"dismiss_stale_reviews":true,"dismissal_restrictions":{"apps":[],"teams":[],"users":[]},"require_code_owner_reviews":true,"require_last_push_approval":false,"required_approving_review_count":1},"required_status_checks":{"checks":[{"app_id":15368,"context":"guard"}],"contexts":["guard"],"strict":true},"restrictions":null}
```

Projection: 640 bytes, SHA-256
`78606ef9437dfb40ca17bc351f43f907cc7d5bb5403e1059a556af2044bacba3`.
Rollback must additionally reproduce the complete current before response:
1,613 bytes and SHA-256
`7e30197b45effc98224943ebe383c45993cecf31a105dcd52f4a14103e5ea7ab`.

Only the App-bound `checks` input alternative is sent. The GET-derived
`contexts:["guard"]` member is not copied into the mutually exclusive write
payload.

### Ordinary-ref ruleset

Endpoint:

```text
PUT /repos/ArkDeck/ArkDeck/rulesets/19595282
```

Exact after write/read-back projection:

```json
{"bypass_actors":[{"actor_id":4340161,"actor_type":"User","bypass_mode":"always"}],"conditions":{"ref_name":{"exclude":["refs/heads/agent/**","refs/heads/agent/**/*","refs/heads/main"],"include":["~ALL"]}},"enforcement":"active","name":"agent-ref-boundary","rules":[{"type":"creation"},{"type":"update"},{"type":"deletion"}],"target":"branch"}
```

Projection: 343 bytes, SHA-256
`9bb7ef3d62246733ca1dcaac074a3b07f5b4aead6985d645cd58fbf82db62163`.

Exact rollback write/read-back projection:

```json
{"bypass_actors":[{"actor_id":4340161,"actor_type":"User","bypass_mode":"always"}],"conditions":{"ref_name":{"exclude":["refs/heads/agent/**"],"include":["~ALL"]}},"enforcement":"active","name":"agent-ref-boundary","rules":[{"type":"creation"},{"type":"update"},{"type":"deletion"}],"target":"branch"}
```

Projection: 301 bytes, SHA-256
`5943b6ce840cbb385ad83615da15ff2ee4ec5710bd696fae6140b37302042157`.
The complete GET is recorded; `updated_at` is expected to advance on a
successful PUT and is never fabricated as an exact rollback value.

Repository settings, Actions permissions, credentials, collaborators, teams,
Apps/installations, CODEOWNERS, reviews, merges, auto-merge and PR state have
mutation budget zero.

## E. Fresh probes, convergence and mutation budgets

Fresh, non-substitutable refs:

```yaml
single_agent: refs/heads/agent/rpt001-7be86404-3716-4588-87db-b74b90604188
multi_agent: refs/heads/agent/host-loop/rpt001/f3a923fa-01bb-4375-9c62-75ccc7c6f4e3
ordinary_create: refs/heads/rpt001-ordinary-b595ba40-7845-4756-88d1-9602e9734831
ordinary_fixture: refs/heads/rpt001-fixture-0839caf8-adf2-49d5-a12a-d97f92e579ad
similar_prefix: refs/heads/agentx/rpt001-af0a1a0d-014d-4702-90be-07c0713dadc2
reserved_execution_evidence: refs/heads/agent/rpt001-evidence-fb7a0b0a-f73e-4d70-91a0-bff2680a0c78
pinned_residual: refs/heads/agent/rpt001/deep/7908274d-d874-47d6-b844-c2e35ba9d2a9
pinned_residual_oid: 2e1e5ce85266f96f54eb60d9f2547398d1c9b3e7
```

```yaml
window_start_utc: 2026-07-24T12:00:00Z
window_end_utc: 2026-07-24T20:00:00Z
window_semantics: half-open
git_rest_convergence_attempts: 12
git_rest_convergence_interval_seconds: 1
required_consecutive_ls_remote_observations: 2
side_effect_observations: 2
side_effect_interval_seconds: 3
maximum_branch_protection_mutations: 1 after + 1 rollback
maximum_ruleset_mutations: 1 after + 1 rollback
exact_success_path_ref_probe_attempts: 16
exact_success_path_ref_probe_successes: 9
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

Every positive create/update tip is an exact descendant of the readiness
merge and its commit subject contains `[skip actions]`. Each success requires:

1. Git exit 0 and a target-ref server receipt;
2. two consecutive exact `git ls-remote --refs` observations;
3. authenticated REST convergence within the same 12-attempt budget;
4. two zero-run/zero-PR observations for the exact branch.

The prior expected OID or absence may be observed while converging; any third
OID fails immediately. One or more bounded stale REST reads are recorded and
do not become PASS until convergence. Delete requires symmetric stable
absence plus REST 404. Timeout or persistent disagreement fails closed.

The residual ref uses its historical workflow/PR inventory as a baseline;
deletion must not add any run or PR, and #471 must remain closed/unmerged.

## F. Mandatory preflight and stop conditions

Before the first write, the exact executor proves:

1. The final readiness PR number replaces the placeholder in Section A and
   in the executor. It is bot-authored by `github-actions[bot]` ID
   `41898282`, has the exact title/head ref, changes only this file, is
   closed/merged with `auto_merge=null`, and has exact-head `lvye` approval
   plus exact-head App `15368` `guard=success`.
2. Current main is that PR's single-parent squash merge; its parent is
   capture main, subject is exact `READINESS_TITLE (#N)`, associated PR is
   exactly the readiness PR and `mergedBy=lvye`. A nullable
   `merge_commit_sha` is only absence of a fact; a string must equal main.
3. This executor's SHA-256 appears literally in merged readiness; the
   readiness blob is identical in the reviewed head and merge tree.
4. The local worktree is clean; `origin` is exact
   `git@github-arkdeck-agent:ArkDeck/ArkDeck.git`; all Git ref transport uses
   that Deploy Key except the one explicit `lvye` HTTPS negative.
5. All complete before objects, stable actor projection, pinned blobs,
   workflow inventory, historical PRs, open PR and remote refs match.
6. The sole pinned residual ref/OID exists; every fresh probe ref and its
   run/PR inventory is absent.
7. Ruleset `updated_at` is exactly
   `2026-07-24T18:45:53.061+08:00`; it evaluates on main with only
   creation/update/deletion.
8. Repository auto-merge is false; Actions is exact `true/read`; sole
   collaborator/admin is `lvye`; sole Deploy Key is ID `158088026`; teams,
   Apps/installations, outside collaborators, invitations and role
   assignments remain empty.
9. No human `lvye` credential/session is Agent-visible. The isolated
   Terminal contains no GitHub token environment-variable name and requires
   typed confirmation.
10. UTC is within the exact half-open window.

Any missing field, hidden actor, stale approval, main/PR/blob/ref/settings
drift, dirty tree, wrong remote, preexisting fresh probe, hash mismatch,
expired window, API ambiguity, network-only negative, unexpected workflow/PR
or overlapping control operation means zero first write and stop.

## G. Fail-closed execution order

1. Complete all GET-only preflight checks.
2. PUT the exact branch-protection after payload.
3. Read back complete protection and exact after projection; prove main
   unchanged and required signatures still false.
4. Build create/update and merge-shaped fast-forward commits; every commit
   contains `[skip actions]`.
5. Deploy Key direct-main negative while both layers overlap.
6. `lvye` direct-main negative while both layers overlap. Since `lvye` is the
   ruleset's sole bypass actor, rejection is attributable to enforced branch
   protection.
7. PUT the exact ruleset after payload only after both negatives.
8. Read back complete ruleset and exact projection; prove ruleset
   `19595282` no longer evaluates on main.
9. Repeat Deploy Key direct-main negative, now attributable to branch
   protection alone.
10. Repeat the pinned read-only actor/repository/workflow/PR inventory.
11. Confirm #471 closed/unmerged, then delete the exact residual ref with the
    Deploy Key and prove stable absence, REST 404 and unchanged side effects.
12. Run single- and multi-level Agent create/update/delete positives with
    Git/REST convergence and zero side effects.
13. Run ordinary-create and `agentx/**` create negatives.
14. Create the ordinary fixture with isolated `lvye` at a `[skip actions]`
    tip, prove Deploy Key update/delete rejection, then delete it with
    isolated `lvye`.
15. Re-read main, both protection layers, repository/Actions/actor
    invariants, open/historical PRs, remote refs and every side-effect gate.
16. Write a secret-free canonical report, log out `lvye`, and verify logout.

No refspec uses `+` or `--force`. Main probes are non-force, fast-forward,
merge-shaped commits, so rejection cannot be a non-fast-forward artifact. A
negative counts only with an explicit GitHub policy marker and unchanged
target; DNS, authentication, transport or local-hook failure is never PASS.
No force-push or delete request is sent to main.

## H. Recovery and cancellation

There is no blind retry.

- Every settings PUT is followed by authenticated GET classification as exact
  before, exact after or unknown.
- If main is unchanged, branch protection is exact after and no main
  negative unexpectedly succeeded, all known controlled Agent/ordinary refs
  are cleaned while the after-ruleset still permits deeper Agent deletion.
- Only then is ruleset exact-before restored and verified active on main;
  branch protection may then be restored with the exact rollback payload and
  complete full-before hash.
- If main or branch-protection state is unknown, or a main negative
  unexpectedly succeeds, main recovery takes priority: restore ruleset
  coverage if classifiable, retain stricter protection and do not delay for
  ref cleanup.
- Unknown mutation outcome is resolved only by GET/`ls-remote`; no guessed
  repeat is sent. Uncleanable refs are exact residuals and keep the task
  blocked.
- No unexpected main update is force-rewritten. It is a security incident.
- Interrupt, timeout, logout failure, cleanup uncertainty or rollback hash
  mismatch yields `fail_closed`.

Cleanup never converts a failed security probe into PASS. The report records
all complete settings responses, projections, convergence traces, server
receipts, side-effect observations, rollback decisions and remaining refs.

## I. Verification boundary

This execution may establish:

- Deploy Key create/update/delete for single- and multi-level `agent/**`;
- Deploy Key ordinary-create, existing ordinary update/delete and
  `agentx/**` rejection;
- Deploy Key direct-main rejection under overlap and branch-protection only;
- `lvye` direct-main rejection despite sole push-allowlist membership;
- branch protection exact after: PR, one approval, CODEOWNER, strict
  `guard`/App `15368`, admin enforcement, users `[lvye]`, empty teams/apps,
  no PR bypass actor, force/delete false;
- ruleset exact after: `~ALL`, creation/update/deletion, only `lvye` bypass,
  exactly two Agent exclusions plus exact main;
- residual #470 ref removal without new workflow/PR side effects;
- settings/actor/Actions/auto-merge invariants and overlap-first migration.

This execution intentionally sends zero real main force-push/delete, review,
merge, auto-merge or PR-state mutations.

Independent execution-evidence and operability-evidence PRs must still prove:

- bot self-approval and non-human CODEOWNER satisfaction are rejected;
- unapproved and guard-red/pending PRs cannot merge;
- compliant `lvye` approval plus `guard=success` can Squash and merge without
  selecting bypass;
- merge subject, review, `mergedBy` and merge OID are auditable;
- Agent/API review, merge, enable-auto-merge and Administration routes are
  rejected or unconstructible under the final actor inventory.

The execution-evidence PR records only facts. A second operability-evidence PR
records its normal no-bypass merge and remaining route negatives. Only after
both are merged may a separate D0 PR propose TASK-RPT-001 `ready → done`.

## J. Explicit supersession and zero reuse

- #435 and all old HLR-002A OIDs, windows, payloads, hashes, scripts, refs and
  UUIDs remain invalid.
- #462, #463 and #467 topology readiness/script/window/payload/probe sets are
  exhausted.
- #459/#466 bootstrap captures, carriers, windows, payloads and scripts are
  transport-recovery history only.
- #470 readiness/head `c5cb4757065a9a3c65b5f98351e56a3236eda396`,
  merge `928d6e06b928e16874df9137950a9830aa38d8d0`, executor
  `124f9b799169fda8e3b0814442accf925f51efffdb2b7165acb7063743dd8f2c`,
  window, hashes, payload instance and UUIDs are exhausted.
- #471 remains closed/unmerged and is used only as the pinned residual
  cleanup target.
- #472 preserves failure facts but creates no AC PASS.
- This readiness alone supplies the fresh capture, main parent, complete
  before, window, script and UUIDs for a new single execution.

Historical BAP-CRED-001 evidence remains true for its date. Its old mechanism
description is not sufficient for the post-migration current claim.
Append-only BAP/HLR supersession and fresh HLR-002A readiness belong to
TASK-RPT-002 after TASK-RPT-001 is done. `enforcement.md`, `AGENTS.md`,
Constitution and Core specs/contracts remain unchanged because the high-level
governance invariants do not change.

## K. Human invocation after merge only

Before execution:

```text
shasum -a 256 /private/tmp/arkdeck-rpt001-r3-apply.py
```

It must equal the final `apply_script_sha256` in Section A. Only in a separate
human Terminal inside the window:

```text
python3 /private/tmp/arkdeck-rpt001-r3-apply.py \
  --repo /Users/fuhanfeng/.codex/worktrees/b1b2/ArkDeck
```

The script requires typed
`HUMAN-ISOLATED-LVYE-TOPOLOGY`, automatically logs out `lvye`, and writes:

```text
/private/tmp/arkdeck-rpt001-r3-apply-report.json
```

Return only that secret-free report and its SHA-256 after
`logout_verified=true`. Never paste a token, device code, cookie, keychain
record, browser storage, public/private key body or raw credential output.
