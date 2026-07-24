# TASK-RPT-001 one-time bootstrap recovery D2 readiness

> Status:PROPOSED / NON-EXECUTABLE UNTIL THIS EXACT FILE IS REVIEWED AND MERGED
> IN THE REPURPOSED BOT-AUTHORED PR #459
>
> Scope:restore the ordinary `agent-pr` transport only. This readiness does
> **not** authorize a ruleset, main branch-protection, repository merge
> setting, credential, ref probe, review, merge, auto-merge or PR-state
> mutation.

## A. Why this exceptional carrier is necessary

#467 / merge `9de9c63f7fe17069ad50ff0a73fc171ce6a14ec8` authorized a
fail-closed topology migration. Its human execution changed the GitHub Actions
workflow setting from `true/read` to `false/read`, then stopped when the exact
branch-protection payload was rejected with HTTP 422 because it sent both
legacy `contexts` and App-bound `checks`.

No branch-protection or ruleset write succeeded. The old ruleset still covers
main, but GitHub exposes `can_approve_pull_request_reviews` as one combined
“create and approve pull requests” switch. Setting it to false also prevented
the pinned `.github/workflows/agent-pr.yml` from creating new bot-authored PRs.
The failure-evidence branch received `guard=success`, `open-pr=failure`, and no
PR.

The user then explicitly authorized still-open, bot-authored PR #459 as a
one-time bootstrap carrier, with exact expected old head:

```text
PR: 459
author: github-actions[bot]
head ref: agent/task-au-002-update-runtime
expected old head: d3aeeaaa8eba79526474580208dc253c4c46d26a
```

That authorization permits an expected-head branch replacement only. D2
authority begins only when `lvye` reviews and merges the updated #459 exact
head. The old product diff and old OID remain historical evidence.

The usual proposal / approval-only / independent-readiness separation is
collapsed once for this bootstrap because the mechanism that creates those
new PRs is unavailable. The exception is narrow and disclosed in the carrier;
normal PR separation resumes immediately after transport recovery.

## B. Authority and fresh capture pins

```yaml
schema: arkdeck-rpt001-bootstrap-readiness/v1
change: CHG-2026-033-ref-protection-topology@r2
task: TASK-RPT-001
operator: lvye
executor: human
credential_location: isolated, Agent-unreachable
repository: ArkDeck/ArkDeck
api_version: 2026-03-10
ruleset_id: 19595282
capture_schema: arkdeck-rpt001-discovery/v2
capture_request_semantics: GET-only
capture_timestamp_utc: 2026-07-24T07:59:50.411399Z
capture_main_oid: 9de9c63f7fe17069ad50ff0a73fc171ce6a14ec8
capture_canonical_bytes_without_lf: 22535
capture_canonical_sha256: 16e66c6675188cb48ddbdf9cf7df105a7af9227aedc64ff2620b98dcf72816e2
capture_file_bytes_with_lf: 22536
capture_file_sha256: 0af8f98938a9c230fa8a77c4c544c2d268b4093062b1f7714c04dabfb94abfc9
capture_script_sha256: 487701e6602ddd20a8d18db6bfce59d58f4597dc7ea3b15e171f45e8934d637a
capture_wrapper_sha256: eb37c969a71d90ab7c23c483d35b05cd4d11c779f5b6c4c92cb149e8b6520397
bootstrap_apply_script_sha256: 96f8fefb793d5cc0d0de09699cd8f9fe6d1a4a2d597b8ce8121e1cb031c262bf
superseded_carrier_head_oid: d3aeeaaa8eba79526474580208dc253c4c46d26a
exhausted_readiness_merge_oid: 9de9c63f7fe17069ad50ff0a73fc171ce6a14ec8
declared_open_control_plane_operations: []
non_agent_non_main_remote_refs: []
```

The authenticated capture was produced by `lvye` after the old D2 failure and
before carrier replacement. All 11 embedded canonical artifacts independently
recalculated to their declared byte counts and SHA-256 values.

### Capture artifact hashes

| Artifact | Bytes | SHA-256 |
| --- | ---: | --- |
| `active_main_rules` | 335 | `560eff7e8ecceb7b044a19634c7e559a8b0411b486717a97c05896246a3c7137` |
| `actor_inventory` | 4,521 | `107c011df3b617fb1982ad0e61472bf238037b05574fc2d7ced050ca44ea7101` |
| `branch_main` | 5,152 | `63d4787938352d4e8ac5fae635604753502818463fcf56a5058b8f40af2b043c` |
| `branch_protection_full` | 1,227 | `e45fb8583eb8002e49fcd402c0d9026f7277a1b823b6fe7410695da5666f0b0c` |
| `open_pull_requests` | 2,028 | `0e67143c27f5f87d23342ffcaa3f01568a80d3be2355e920237144deada69845` |
| `organization_settings` | 482 | `db3047ad7868abfb58303681c011c7c6a4ebe79de8a7d0e3166760320d297b09` |
| `pin_blobs` | 1,716 | `14dc91731d9a2c96cb06ae646e106f7c080958f14503631682d7af27e382bbfd` |
| `remote_refs` | 1,278 | `6b01357566245bdb78572b82c3d52aa52bf7b72a52817e90862a8f1abbc3ae8c` |
| `repository_settings` | 660 | `8f605ec84f4d83ef6a860c238e1c506cacd1ab8c85ecb90448bdf2a684daf3f7` |
| `ruleset_full` | 702 | `a5725db245d84174090de47e1fc45123219dbf5cfdd00d45856b04d801a3d5f2` |
| `rulesets_full` | 438 | `a603d5a0af93112475f4e92a597b16c515b9eebe320cbab98f7bd26b0d9487b0` |

### Carrier blob pins

Execution must read these blobs from the reviewed #459 head and from its merge
tree. Every value must be exact. This file's own blob is instead bound by the
exact reviewed PR head and merge facts, avoiding a self-reference.

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
| CHG-2026-033 `tasks.md` | `9ff1addd3ccda3ee537eddbb017ef7a093dfb6b5` |
| CHG-2026-033 `verification.md` | `48a990bba60ea4e7679cf08d01c247fee0a98ac4` |
| CHG-2026-033 `acceptance-cases.yaml` | `3f0355894d0c18c26576042d11b34b9cb3732297` |
| TASK-RPT-001 fail-closed evidence | `6637ae3d190aca9afcd1557dbbf5275a54047d7a` |
| `openspec/governance/enforcement.md` | `e8ff3c130e1b8b15f8405d150ad567e774a0d82b` |
| `openspec/governance/host-loop-runbook.md` | `70e0bcc5b736a896f0329e24a89e273164762558` |

## C. Fresh exact before

Canonicalization is UTF-8, recursively sorted object keys, compact separators,
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

The GET response contains no `restrictions`, and `enforce_admins=false`.
Those are known topology gaps still covered by the old ruleset. This bootstrap
must not repair them.

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

Only `lvye` is a collaborator/admin/member and ruleset bypass actor. Deploy Key
`158088026` is write-enabled but is not a collaborator, CODEOWNER, bypass or
main-push actor. Volatile informational fields such as Deploy Key `last_used`
are retained in the full capture but deliberately excluded from this stable
execution projection. Teams, App installations, outside collaborators,
invitations and all organization-role assignments are empty.

## D. Exact authorized payloads

All requests use:

```text
Accept: application/vnd.github+json
X-GitHub-Api-Version: 2026-03-10
```

Endpoint:

```text
PUT /repos/ArkDeck/ArkDeck/actions/permissions/workflow
```

### Exact before and rollback payload

```json
{"can_approve_pull_request_reviews":false,"default_workflow_permissions":"read"}
```

```yaml
bytes: 80
sha256: fb00f7e1aab4200684b287b484155d5521381f4593552beed4bbb5f9b1622ede
```

### Exact after payload

```json
{"can_approve_pull_request_reviews":true,"default_workflow_permissions":"read"}
```

```yaml
bytes: 79
sha256: e4eea28a28f0c12dc5a441d5d6451c4bc7f3f72ed8f0b717c6cb5502e825965d
```

This after value is required by the existing `GITHUB_TOKEN` PR creator. It
does not place Actions in ruleset bypass or main push restrictions, does not
make the bot a CODEOWNER/admin, and does not bypass the GitHub rule that a PR
author cannot approve its own PR.

Future topology D2 must separately use `required_status_checks.checks` without
also sending legacy `contexts`. That future payload is deliberately absent
from this readiness.

## E. Window and mutation budgets

```yaml
window_start_utc: 2026-07-24T08:30:00Z
window_end_utc: 2026-07-24T14:00:00Z
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

Expiry, clock uncertainty or any drift requires another merged recovery
authority. The window must not be extended in place.

## F. Preflight and stop conditions

Before the single PUT, the isolated human session must prove all of:

1. #459 is merged, was authored by `github-actions[bot]`, has exact title
   `governance(TASK-RPT-001): recover bot-authored PR transport`, and its exact
   reviewed head received an approving review from `lvye` plus `guard=success`.
2. Current protected main equals #459's full merge OID; the merge commit has
   the single exact parent
   `9de9c63f7fe17069ad50ff0a73fc171ce6a14ec8`, subject with `(#459)`,
   associated PR and `mergedBy`.
3. The updated #459 diff contains exactly:
   - CHG-2026-033 proposal/design/tasks/verification/acceptance revision;
   - this bootstrap readiness;
   - TASK-RPT-001 fail-closed/bootstrap evidence.
4. Every carrier blob in Section B matches. `AGENTS.md`,
   `enforcement.md`, `.github/**`, CHG-2026-030, Core/spec/contracts and product
   files have zero diff.
5. The full Actions before, ruleset, branch protection, repository settings and
   actor projection match Sections C/D byte-for-byte and hash-for-hash.
6. Ruleset `updated_at` remains
   `2026-07-23T10:20:11.425+08:00`; its active main evaluation still contains
   creation/update/deletion.
7. `allow_auto_merge=false`; no merge-queue rule is present.
8. Every open PR is authored by exact `github-actions[bot]`. #466/#468 may
   remain only if their exact heads and changed paths remain non-overlapping;
   any new PR receives a full path/actor overlap classification.
9. Every non-main branch is under `refs/heads/agent/**`; no unexpected
   collaborator/team/App/role assignment/bypass/main-push actor exists.
10. Human credential/session is absent from every Agent-reachable connector,
    process, environment, helper, keychain, browser and tool surface.

Any missing field, unexpected actor, main/blob/ref/PR/control-plane drift,
ambiguous response, timeout, hash mismatch, expired window or inability to
explain rollback means zero PUT and stop.

The old #467 apply scripts, payload, window, nonce, derived refs and execution
receipt are not valid preflight inputs.

## G. Exact execution order

1. Verify the executor bytes have SHA-256
   `96f8fefb793d5cc0d0de09699cd8f9fe6d1a4a2d597b8ce8121e1cb031c262bf`,
   enter the window in a separate human Terminal and authenticate as exact
   `lvye`; no credential value may be copied to Agent-visible output.
2. Perform all Section F GET-only checks. Mutation counters remain zero until
   all pass.
3. Send the exact Section D after payload once.
4. Immediately authenticated GET the same endpoint. Canonical projection must
   equal 79 bytes and SHA-256
   `e4eea28a28f0c12dc5a441d5d6451c4bc7f3f72ed8f0b717c6cb5502e825965d`.
5. Re-read ruleset, branch protection, repository auto-merge and actor
   inventory. They must remain exactly at the pinned read-only state.
6. Write a secret-free receipt, logout `lvye`, and verify the Agent has no
   human credential/session.
7. Only after logout may the Agent add the execution receipt to the preserved
   failure-evidence branch and push that `agent/**` ref. The restored
   `agent-pr` workflow must create exactly one PR authored by
   `github-actions[bot]`.
8. That evidence PR remains unapproved until `lvye` reviews it. Its existence
   proves creator liveness only; it is not topology evidence or task `done`.

No branch-protection/ruleset fix, no review probe and no ref probe may be
“added while the session is open”.

## H. Rollback and unexpected outcomes

- If the PUT response is timeout/nonzero/ambiguous, do not blindly retry. GET
  the endpoint once and classify exact false/read, exact true/read or unknown.
- Exact false/read means no successful change; stop with mutation attempt
  recorded.
- Exact true/read after a non-success response is still an ambiguous dispatch:
  send exact false/read rollback once, verify it and stop. Only an unambiguous
  success response plus exact true/read may continue to post-invariant checks.
- Any other value is unknown/incident: send the exact rollback payload at most
  once only if its target state and safety can still be established, then
  authenticated read-back and stop.
- If a pinned read-only invariant drifts after the successful Actions write,
  send exact false/read rollback once, verify it, and stop. Do not edit the
  drifted object.
- If rollback outcome is ambiguous, retain the full response classification,
  logout and treat the task as blocked. Do not claim a clean state.
- If subsequent bot PR creation fails, do not toggle repeatedly. Within the
  same still-valid window the human may execute the exact false/read rollback
  once after a fresh full preflight; otherwise a new merged readiness is
  required.

Rollback never authorizes a ruleset, protection, repository, credential, ref,
review, merge or PR-state write.

## I. Evidence and acceptance boundary

The bootstrap receipt must record:

- #459 reviewed head, review/check/merge facts and current main OID;
- exact bootstrap executor SHA-256;
- before/after/read-back canonical bytes and hashes;
- all mutation counters;
- pinned read-only object hashes before and after;
- executor `human`, time/window and confirmed logout;
- bot-authored evidence PR number/head and its creator check result.

This recovery proves only governance transport availability and preserves the
human-approval architecture. It does **not** pass
`RPT-BOUNDARY-001`, `RPT-MAIN-001`, `RPT-IDENTITY-001` or
`RPT-MIGRATION-001`, does not mark TASK-RPT-001 done, and does not verify the
change.

After the bootstrap evidence is merged, a new independent topology D2
readiness must recapture current main and every control object, use a new
window/nonce/probe set, use a schema-valid checks-only branch-protection
payload, and retain overlap-first migration and ruleset-first rollback.

## J. Explicit supersession and zero reuse

- #435 / old HLR-002A OID, window, payload/hash, script, UUID and probe refs
  remain permanently invalid.
- #462, #463 and #467 topology readiness revisions are exhausted and
  non-executable.
- Both failed apply scripts and all reports are evidence only; they must not be
  rerun.
- This bootstrap's capture, window, payload and merge authority cannot be
  reused for the later topology migration.
- PR #459 old head
  `d3aeeaaa8eba79526474580208dc253c4c46d26a` remains a superseded carrier
  provenance fact, not an implementation candidate.
