# TASK-RPT-001 second bootstrap parser-recovery D2 readiness

> Status:PROPOSED / NON-EXECUTABLE UNTIL THIS EXACT FILE IS REVIEWED AND MERGED
> IN THE REPURPOSED BOT-AUTHORED PR #466
>
> Scope:correct the nullable `merge_commit_sha` preflight and restore the
> ordinary `agent-pr` transport only. This readiness does **not** authorize a
> ruleset, main branch-protection, repository merge setting, credential, ref
> probe, review, merge, auto-merge or PR-state mutation.

## A. Why a second exceptional carrier is necessary

The first bootstrap carrier #459 was reviewed and squash-merged as
`ced32841a39147e3de74787f755d2377ccfba460`. Its executor then stopped before
all writes because GitHub omitted the optional `merge_commit_sha` field and
the parser incorrectly required that field itself to equal current main.

Independent merge facts were exact: current main, single parent, subject,
associated PR, `mergedBy`, exact bot-authored head, exact-head `lvye`
approval and pinned `guard=success`. The failure was parser-only:

```text
Actions mutations: 0
ruleset mutations: 0
branch-protection mutations: 0
repository/ref/review/merge/PR-state mutations: 0
logout verified: true
```

The user explicitly authorized still-open, bot-authored #466 as a second
one-time parser-recovery carrier. Its original head is
`3fda06cc3e5e91e06890845f2a760a9a3fec592c`; that OID is retained as
provenance and may be used only as the expected value of the authorized
`force-with-lease`.

The ordinary PR creator remains unavailable because Actions is still exact
`false/read`. The usual PR separation is therefore collapsed once more for
this parser-only correction. Normal separation resumes immediately after
transport recovery.

## B. Authority and fresh capture pins

```yaml
schema: arkdeck-rpt001-parser-recovery-readiness/v1
change: CHG-2026-033-ref-protection-topology@r2
task: TASK-RPT-001
operator: lvye
executor: human
credential_location: isolated, Agent-unreachable
repository: ArkDeck/ArkDeck
api_version: 2026-03-10
ruleset_id: 19595282
carrier_pr: 466
carrier_head_ref: agent/task-au-002-done
carrier_expected_old_head: 3fda06cc3e5e91e06890845f2a760a9a3fec592c
carrier_required_title: "governance(TASK-RPT-001): recover nullable merge parser"
capture_schema: arkdeck-rpt001-discovery/v2
capture_request_semantics: GET-only
capture_timestamp_utc: 2026-07-24T08:57:31.008065Z
capture_main_oid: ced32841a39147e3de74787f755d2377ccfba460
capture_canonical_bytes_without_lf: 21730
capture_canonical_sha256: 68decddf9505cb7527e472061c27c70948ba4ee7bd4de59912772a61b6d4e40f
capture_file_bytes_with_lf: 21731
capture_file_sha256: 56f282e4628f6ffb75c765176fcc548569239e16db5295640951f69888ab5fc8
capture_script_sha256: 487701e6602ddd20a8d18db6bfce59d58f4597dc7ea3b15e171f45e8934d637a
capture_wrapper_sha256: 849f9c83c2b44f9f1404bc7793699343371192ef3c42228d75cfa89d49a47b72
apply_script_sha256: 41230cb2edec90f1685d9c62eefa1b690d736d378db9ec657a34042624ed05f5
previous_zero_write_report_sha256: ae228dbed662fa42b6200f2acb1387c2f4b1e474d9561c450e32180cfc73d347
exhausted_first_bootstrap_merge_oid: ced32841a39147e3de74787f755d2377ccfba460
declared_open_control_plane_operations: []
non_agent_non_main_remote_refs: []
```

All 11 embedded canonical artifacts independently recalculated to their
declared byte counts and SHA-256 values:

| Artifact | Bytes | SHA-256 |
| --- | ---: | --- |
| `active_main_rules` | 335 | `560eff7e8ecceb7b044a19634c7e559a8b0411b486717a97c05896246a3c7137` |
| `actor_inventory` | 4,521 | `107c011df3b617fb1982ad0e61472bf238037b05574fc2d7ced050ca44ea7101` |
| `branch_main` | 5,656 | `3b8b9123dd186cedc1b9ae36daca9c760ac6f8b532e99c67791767ad5ef0fe1b` |
| `branch_protection_full` | 1,227 | `e45fb8583eb8002e49fcd402c0d9026f7277a1b823b6fe7410695da5666f0b0c` |
| `open_pull_requests` | 875 | `e6653448d4eaa30d464dbc5e1294ca5f14eb7ddcd032e3d364f400ece8f0939b` |
| `organization_settings` | 482 | `db3047ad7868abfb58303681c011c7c6a4ebe79de8a7d0e3166760320d297b09` |
| `pin_blobs` | 1,716 | `28c7be6bccacb0ef30a62ad9be9a34c318fb529ee312ef19e01a4b65d4cbb68b` |
| `remote_refs` | 1,168 | `76d81bdc7ec84fd2765d497d9e6e8b21a242af5f3239c2df8cc838a3eea64520` |
| `repository_settings` | 660 | `8f605ec84f4d83ef6a860c238e1c506cacd1ab8c85ecb90448bdf2a684daf3f7` |
| `ruleset_full` | 702 | `a5725db245d84174090de47e1fc45123219dbf5cfdd00d45856b04d801a3d5f2` |
| `rulesets_full` | 438 | `a603d5a0af93112475f4e92a597b16c515b9eebe320cbab98f7bd26b0d9487b0` |

### Carrier blob pins

Every value must match both the reviewed #466 head and its merge tree. This
readiness file binds itself through the exact reviewed head and merge facts.

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
| CHG-2026-033 `acceptance-cases.yaml` | `3f0355894d0c18c26576042d11b34b9cb3732297` |
| TASK-RPT-001 fail-closed evidence | `f3e74f97b580a3ea87540723c5824f767a33bee6` |
| `openspec/governance/enforcement.md` | `e8ff3c130e1b8b15f8405d150ad567e774a0d82b` |
| `openspec/governance/host-loop-runbook.md` | `70e0bcc5b736a896f0329e24a89e273164762558` |

## C. Fresh exact before

Canonicalization is UTF-8, recursively sorted object keys, compact separators
and no trailing LF.

### Actions workflow setting

```json
{"can_approve_pull_request_reviews":false,"default_workflow_permissions":"read"}
```

```yaml
bytes: 80
sha256: fb00f7e1aab4200684b287b484155d5521381f4593552beed4bbb5f9b1622ede
```

### Ruleset full JSON — read-only invariant

```json
{"_links":{"html":{"href":"https://github.com/ArkDeck/ArkDeck/rules/19595282"},"self":{"href":"https://api.github.com/repos/ArkDeck/ArkDeck/rulesets/19595282"}},"bypass_actors":[{"actor_id":4340161,"actor_type":"User","bypass_mode":"always"}],"conditions":{"ref_name":{"exclude":["refs/heads/agent/**"],"include":["~ALL"]}},"created_at":"2026-07-23T10:20:11.391+08:00","current_user_can_bypass":"always","enforcement":"active","id":19595282,"name":"agent-ref-boundary","node_id":"RRS_lACqUmVwb3NpdG9yec5Na16-zgErABI","rules":[{"type":"creation"},{"type":"update"},{"type":"deletion"}],"source":"ArkDeck/ArkDeck","source_type":"Repository","target":"branch","updated_at":"2026-07-23T10:20:11.425+08:00"}
```

```yaml
bytes: 702
sha256: a5725db245d84174090de47e1fc45123219dbf5cfdd00d45856b04d801a3d5f2
mutation_budget: 0
```

### Main branch protection full JSON — read-only invariant

```json
{"allow_deletions":{"enabled":false},"allow_force_pushes":{"enabled":false},"allow_fork_syncing":{"enabled":false},"block_creations":{"enabled":false},"enforce_admins":{"enabled":false,"url":"https://api.github.com/repos/ArkDeck/ArkDeck/branches/main/protection/enforce_admins"},"lock_branch":{"enabled":false},"required_conversation_resolution":{"enabled":false},"required_linear_history":{"enabled":true},"required_pull_request_reviews":{"dismiss_stale_reviews":true,"require_code_owner_reviews":true,"require_last_push_approval":false,"required_approving_review_count":1,"url":"https://api.github.com/repos/ArkDeck/ArkDeck/branches/main/protection/required_pull_request_reviews"},"required_signatures":{"enabled":false,"url":"https://api.github.com/repos/ArkDeck/ArkDeck/branches/main/protection/required_signatures"},"required_status_checks":{"checks":[{"app_id":15368,"context":"guard"}],"contexts":["guard"],"contexts_url":"https://api.github.com/repos/ArkDeck/ArkDeck/branches/main/protection/required_status_checks/contexts","strict":true,"url":"https://api.github.com/repos/ArkDeck/ArkDeck/branches/main/protection/required_status_checks"},"url":"https://api.github.com/repos/ArkDeck/ArkDeck/branches/main/protection"}
```

```yaml
bytes: 1227
sha256: e45fb8583eb8002e49fcd402c0d9026f7277a1b823b6fe7410695da5666f0b0c
mutation_budget: 0
```

The response still has no push `restrictions` and has
`enforce_admins=false`. Those known topology gaps remain covered by the old
ruleset and must not be repaired in this bootstrap.

### Repository settings projection — read-only invariant

```json
{"fields":{"allow_auto_merge":false,"allow_forking":true,"allow_merge_commit":true,"allow_rebase_merge":true,"allow_squash_merge":true,"allow_update_branch":false,"archived":false,"default_branch":"main","delete_branch_on_merge":true,"disabled":false,"full_name":"ArkDeck/ArkDeck","id":1298882238,"is_template":false,"merge_commit_message":"PR_TITLE","merge_commit_title":"MERGE_MESSAGE","name":"ArkDeck","node_id":"R_kgDOTWtevg","private":false,"squash_merge_commit_message":"COMMIT_MESSAGES","squash_merge_commit_title":"COMMIT_OR_PR_TITLE","visibility":"public","web_commit_signoff_required":false},"missing_known_fields":["use_squash_pr_title_as_default"]}
```

```yaml
bytes: 660
sha256: 8f605ec84f4d83ef6a860c238e1c506cacd1ab8c85ecb90448bdf2a684daf3f7
repository_patch_budget: 0
```

### Stable actor enforcement projection — read-only invariant

```json
{"actions_permissions":{"allowed_actions":"all","enabled":true,"sha_pinning_required":false},"collaborators":[{"id":4340161,"login":"lvye","permissions":{"admin":true,"maintain":true,"pull":true,"push":true,"triage":true},"role_name":"admin","site_admin":false,"type":"User"}],"custom_repository_roles":{"endpoint":"/orgs/ArkDeck/custom-repository-roles","items_key":"custom_roles","query_status":"not-available-or-not-authorized-http-404"},"deploy_keys":[{"added_by":"lvye","enabled":true,"id":158088026,"read_only":false,"title":"arkdeck-agent-writer","verified":true}],"installations":[],"organization_admins":[{"id":4340161,"login":"lvye","site_admin":false,"type":"User"}],"organization_members":[{"id":4340161,"login":"lvye","site_admin":false,"type":"User"}],"organization_role_assignments":[{"role_id":138,"teams":[],"users":[]},{"role_id":8132,"teams":[],"users":[]},{"role_id":8133,"teams":[],"users":[]},{"role_id":8134,"teams":[],"users":[]},{"role_id":8135,"teams":[],"users":[]},{"role_id":8136,"teams":[],"users":[]},{"role_id":26237,"teams":[],"users":[]},{"role_id":33679,"teams":[],"users":[]},{"role_id":82849,"teams":[],"users":[]}],"outside_collaborators":[],"pending_invitations":[],"repository_permissions_for_authenticated_user":{"admin":true,"maintain":true,"pull":true,"push":true,"triage":true},"teams":[],"workflow_permissions":{"can_approve_pull_request_reviews":false,"default_workflow_permissions":"read"}}
```

```yaml
bytes: 1437
sha256: a621fdb55dd5ef0e9e2888f8c47b00b3a241a97d63565645253df2015f4096d9
```

Only `lvye` is a collaborator/admin/member and ruleset bypass actor. Deploy
Key `158088026` remains write-enabled but non-bypass. Teams, Apps, outside
collaborators, invitations and organization-role assignments are empty.

## D. Nullable merge-field rule and exact authorized payload

`merge_commit_sha` is optional evidence:

- absent or JSON `null`:accepted only as “no fact”; all independent mandatory
  merge facts below remain required;
- string:must equal current protected main;
- any other type or mismatching string:zero-write stop.

This correction does not weaken the merge proof. Current main must still be a
single-parent squash commit whose parent is the captured main, whose subject
is exact, whose associated PR is #466, whose `mergedBy` is `lvye`, and whose
exact head has the required review and `guard`.

All requests use:

```text
Accept: application/vnd.github+json
X-GitHub-Api-Version: 2026-03-10
```

The sole authorized write endpoint is:

```text
PUT /repos/ArkDeck/ArkDeck/actions/permissions/workflow
```

Exact before and rollback:

```json
{"can_approve_pull_request_reviews":false,"default_workflow_permissions":"read"}
```

```yaml
bytes: 80
sha256: fb00f7e1aab4200684b287b484155d5521381f4593552beed4bbb5f9b1622ede
```

Exact after:

```json
{"can_approve_pull_request_reviews":true,"default_workflow_permissions":"read"}
```

```yaml
bytes: 79
sha256: e4eea28a28f0c12dc5a441d5d6451c4bc7f3f72ed8f0b717c6cb5502e825965d
```

This restores the existing bot-authored PR transport. It does not add Actions
to ruleset bypass or a main push allowlist, make the bot a CODEOWNER/admin, or
make self-approval effective.

## E. Window and mutation budgets

```yaml
window_start_utc: 2026-07-24T09:30:00Z
window_end_utc: 2026-07-24T15:00:00Z
window_semantics: half-open
maximum_actions_workflow_mutations: 1 after + 1 rollback
maximum_ruleset_mutations: 0
maximum_branch_protection_mutations: 0
maximum_repository_patch_mutations: 0
maximum_credential_mutations: 0
maximum_ref_probe_mutations: 0
maximum_review_mutations: 0
maximum_merge_mutations: 0
maximum_pr_state_mutations: 0
agent_privileged_dispatch: 0
rollback_contact: lvye
```

Expiry, clock uncertainty or drift requires another merged recovery
authority. This window may not be extended in place.

## F. Preflight and stop conditions

Before the single PUT, the isolated human executor must prove all of:

1. #466 is merged, was authored by exact `github-actions[bot]` ID `41898282`,
   has exact title
   `governance(TASK-RPT-001): recover nullable merge parser`, exact head ref
   `agent/task-au-002-done`, and its exact reviewed head has `lvye`
   `APPROVED` plus `guard=success` from App ID `15368`.
2. Optional `merge_commit_sha` follows Section D. Independently, current main
   is the exact #466 squash commit with the single parent
   `ced32841a39147e3de74787f755d2377ccfba460`, exact subject ending `(#466)`,
   associated PR #466 and exact `mergedBy=lvye`.
3. The #466 changed-file set is exactly this readiness plus
   `evidence/runs/TASK-RPT-001/2026-07-24-d2-fail-closed.md`.
4. The local carrier worktree is clean and remains at the exact reviewed #466
   head. Every Section B carrier blob matches the reviewed head and merge
   tree.
5. Full Actions before, ruleset, active-main rules, branch protection,
   repository settings, organization settings and stable actor projection
   match Sections B/C byte-for-byte and hash-for-hash.
6. Ruleset `updated_at` remains
   `2026-07-23T10:20:11.425+08:00`; its active main evaluation is exactly
   creation/update/deletion. `allow_auto_merge=false`.
7. If #468 remains open, it is exact bot-authored head
   `9ecbb7a1de6a6504b1a72281d4f122a0f7590def` with only its three captured,
   non-overlapping evidence paths. No other open PR is allowed.
8. Every non-main branch is under `refs/heads/agent/**`; no unexpected
   collaborator/team/App/role assignment/bypass/main-push actor exists.
9. Human credential/session is absent from every Agent-reachable connector,
   process, environment, helper, keychain, browser and tool surface.

Any missing field other than the explicitly nullable merge field, unexpected
actor, main/blob/ref/PR/control drift, ambiguity, timeout, hash mismatch,
expired window or rollback uncertainty means zero PUT and stop.

## G. Exact execution order

1. Verify executor SHA-256
   `41230cb2edec90f1685d9c62eefa1b690d736d378db9ec657a34042624ed05f5`.
2. In a separate human Terminal inside the window authenticate as exact
   `lvye`; no credential value may enter Agent-visible output.
3. Perform every Section F GET-only check. Mutation counters remain zero until
   all pass.
4. Send the exact Section D after payload once.
5. Immediately authenticated GET the same endpoint. It must equal 79 bytes
   and SHA-256
   `e4eea28a28f0c12dc5a441d5d6451c4bc7f3f72ed8f0b717c6cb5502e825965d`.
6. Re-read ruleset, active rules, branch protection, repository settings and
   actor inventory. Only the approved workflow field may differ.
7. Write a secret-free receipt, logout `lvye`, and verify logout.
8. Only after logout may the Agent push an execution-evidence branch. The
   restored workflow must create exactly one bot-authored PR.

No topology repair, review probe or ref probe may be added while the session
is open.

## H. Rollback and unexpected outcomes

- A timeout/nonzero/ambiguous PUT is never retried. GET once and classify
  exact false/read, exact true/read or unknown.
- Exact false/read means no successful change; record and stop.
- Exact true/read after a non-success response is an ambiguous dispatch:
  rollback once to exact false/read, verify and stop.
- Any unexpected state permits at most one exact false/read rollback when its
  safety remains established, followed by read-back and stop.
- Any post-write pinned-invariant drift triggers the same single rollback;
  the drifted object itself must not be edited.
- Ambiguous rollback means blocked. Logout and make no clean-state claim.
- Failure of subsequent bot PR creation does not permit repeated toggling.

Rollback never authorizes a ruleset, protection, repository, credential, ref,
review, merge or PR-state write.

## I. Evidence and acceptance boundary

The receipt must record the exact #466 head, review/check/merge facts, nullable
field observation, current main, executor hash, before/after/read-back hashes,
all mutation counters, invariant hashes, human executor/window and logout.

This recovery proves only PR-transport availability. It does not pass any
topology AC, mark TASK-RPT-001 done or verify the change. After the independent
bootstrap evidence is merged, the topology migration requires another fresh,
independent D2 readiness with a new main/OID/window/payload/probe set.

## J. Explicit supersession and zero reuse

- #435 and every old HLR-002A OID/window/payload/hash/script/UUID/ref remain
  invalid.
- #462, #463 and #467 topology readiness revisions remain exhausted.
- The #459 bootstrap capture/readiness/window/executors and zero-write report
  are evidence only and must not be rerun.
- PR #459 heads
  `d3aeeaaa8eba79526474580208dc253c4c46d26a`,
  `e00d25954377200e73e7956c3f7a264dbd63bb7d` and
  `6bc5876b8cdd4fadc6e83e8812a0a995333cf9bf` are provenance only.
- PR #466 old head
  `3fda06cc3e5e91e06890845f2a760a9a3fec592c` is provenance and the one-time
  lease expectation only.
- This capture, window, payload and merge authority cannot be reused for the
  later topology migration.
