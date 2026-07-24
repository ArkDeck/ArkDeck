# TASK-RPT-001 D2 fail-closed receipt — preflight parser and branch-protection 422

- Date:2026-07-24.
- Executor:human (`lvye`) in an isolated maintainer-controlled session.
- Readiness authority:PR #467 exact head
  `a8ede4ab34e87f0e5f7270b7d37d2f6961ca0020`, merged as
  `9de9c63f7fe17069ad50ff0a73fc171ce6a14ec8`.
- Classification:real GitHub control-plane execution failure; no simulation.
- Task status:this evidence does not change `TASK-RPT-001` from `ready`.
- Result:**FAIL CLOSED**. The #467 D2 execution is exhausted and must not be
  retried or repaired by changing its approved payload.

## Credential boundary

Before each human attempt, the Agent-side containment check reported:

```text
gh authenticated hosts: none
GH_TOKEN: absent
GITHUB_TOKEN: absent
GH_ENTERPRISE_TOKEN: absent
GITHUB_ENTERPRISE_TOKEN: absent
ssh-agent identities: none
```

The human script rejected credential environment variables, required
authenticated identity `lvye` / user ID `4340161`, and emitted no token,
cookie, Authorization header, key material, keychain contents or browser
storage. After each attempt the human session was logged out before this
evidence was drafted.

## Attempt 1 — parser stop before dispatch

At `2026-07-24T07:13:29Z`, script SHA-256
`86d6461ee472348fc2731ea81d60f8cb7fb1ca951501fb63294b31a5eca50512`
started preflight. It verified:

- authenticated identity `lvye`;
- local and authenticated `main` equal
  `9de9c63f7fe17069ad50ff0a73fc171ce6a14ec8`;
- all remote branches other than `main` were under `agent/**`.

The GitHub pull response omitted `merge_commit_sha`; a local parser indexed
that absent field and raised `KeyError('merge_commit_sha')`. The failure
occurred before the Actions, branch-protection and ruleset mutation functions
were entered.

```text
Actions mutation attempts: 0
branch-protection mutation attempts: 0
ruleset mutation attempts: 0
probe ref mutations: 0
recovery main OID: 9de9c63f7fe17069ad50ff0a73fc171ce6a14ec8
```

The parser was then changed to require the same merge fact from three
independent authenticated facts when the optional PR field is absent:
current `main`, the exact merge commit/parent/subject, and its associated PR.
This was a local executor correction only; no approved payload changed.

## Attempt 2 — complete preflight, partial stricter state, HTTP 422

At `2026-07-24T07:19:30Z`, corrected script SHA-256
`f108a16f80e5b55f1a6e2c1fd0d54649540a73498e0f02195cff3de48393b4bf`
completed the full authenticated preflight.

### Authority and concurrency

- #467 was closed/merged, exact head
  `a8ede4ab34e87f0e5f7270b7d37d2f6961ca0020`, exact base
  `2e449569a3dda7c5b6bad7ad083df9934169c840`, merged by `lvye` at
  `2026-07-24T06:29:55Z`.
- Exact-head `lvye` APPROVED review was present.
- Required `guard` from App ID `15368` was `success`; `swift` and `open-pr`
  were also `success`.
- Merge fallback facts were exact:

  ```text
  merge OID: 9de9c63f7fe17069ad50ff0a73fc171ce6a14ec8
  parent:    2e449569a3dda7c5b6bad7ad083df9934169c840
  subject:   governance(TASK-RPT-001): repin D2 readiness after main drift (#467)
  associated PRs: [467]
  ```

- Open PRs #459, #466 and #468 were inspected path-by-path. None modified a
  pinned input, `.github/**`, CHG-2026-027/030/033 or governance path.
- Every controlled derived probe ref was absent.
- All 15 pinned blobs matched #467 readiness.

### Exact before

```text
ruleset_full:
  bytes: 702
  sha256: a5725db245d84174090de47e1fc45123219dbf5cfdd00d45856b04d801a3d5f2
ruleset_write_projection:
  bytes: 301
  sha256: 5943b6ce840cbb385ad83615da15ff2ee4ec5710bd696fae6140b37302042157
branch_protection_full:
  bytes: 1227
  sha256: e45fb8583eb8002e49fcd402c0d9026f7277a1b823b6fe7410695da5666f0b0c
branch_protection_write_projection:
  bytes: 640
  sha256: 78606ef9437dfb40ca17bc351f43f907cc7d5bb5403e1059a556af2044bacba3
repository_settings_full:
  bytes: 648
  sha256: ec3df4f619d474d83acc3199ae677104149e56bb45e05ea0eb67dee49a3b0e9d
actions_full:
  bytes: 212
  sha256: 61c9241c4a9f27565c00d7e5938852390934b174f75983b0df247ecb8e1b13ee
actor_enforcement_projection:
  bytes: 1294
  sha256: eba50756ae888703531e39fbf85c09d6e8324109de2927cb19ef7a5f10f1aca9
```

Authenticated actor inventory remained closed:

- only collaborator/member/admin `lvye`;
- ruleset bypass only `lvye`;
- Deploy Key ID `158088026`, title `arkdeck-agent-writer`, write-enabled but
  absent from bypass/admin/main-push actors;
- repository teams, App installations, custom repository roles, organization
  role assignments, outside collaborators and pending invitations: empty
  (custom repository roles returned the expected feature-unavailable 404);
- workflow review/merge/admin route scan: empty.

### Applied Actions restriction

The exact approved Actions payload was sent once:

```json
{"can_approve_pull_request_reviews":false,"default_workflow_permissions":"read"}
```

```text
bytes: 80
sha256: fb00f7e1aab4200684b287b484155d5521381f4593552beed4bbb5f9b1622ede
```

Immediate authenticated GET returned the exact same canonical object and
hash. Per readiness rollback policy, `can_approve_pull_request_reviews=false`
was retained; restoring `true` is forbidden because it would reopen Agent
self-approval capability.

### Rejected branch-protection request

The script sent the exact #467-approved branch-protection after payload once:

```text
bytes: 674
sha256: f423ce0ca2eb3f667a34dbb7f9bcfa923266928d073ee0e50763b2f69ee2663a
```

GitHub rejected it deterministically with HTTP 422:

```text
Invalid request.
No subschema in "anyOf" matched.
More than one subschema in "oneOf" matched.
Not all subschemas of "allOf" matched.
For 'anyOf/1', {"checks" => [{"app_id" => 15368, "context" => "guard"}],
"contexts" => ["guard"], "strict" => true} is not a null.
```

The request contained both `required_status_checks.contexts` and
`required_status_checks.checks`. GitHub's current API schema treats the
legacy context list and fine-grained App-bound check list as alternative
inputs. The approved payload therefore cannot be made executable without a
new governance revision. No field was removed and no substitute request was
sent inside the failed window.

The failure receipt did not perform an authenticated branch-protection GET
after the 422. A fresh authenticated discovery is therefore mandatory before
any new readiness; the next plan must not infer post-state solely from the
HTTP error.

### Stop and final facts

```text
Actions mutation attempts: 1
Actions exact after read-back: PASS
branch-protection mutation attempts: 1
branch-protection response: HTTP 422 validation failure
ruleset mutation attempts: 0
repository PATCH mutations: 0
Deploy Key/human probe ref mutations: 0
main force-push requests: 0
main delete requests: 0
recovery main OID: 9de9c63f7fe17069ad50ff0a73fc171ce6a14ec8
```

The old ruleset covered `main` at preflight and no ruleset request was sent.
No protection was intentionally relaxed. The known partial state is stricter
for Actions; branch protection and ruleset require fresh authenticated
read-back before another D2 readiness.

The secret-free sanitized attempt-2 report at handoff had:

```text
sha256: 49e00088529e5f4b22de604a3d9250b76d33594255af7e8bc9cdfa520817f843
```

## Remediation boundary

- Do not rerun either script or reuse #467's OID, window, payload/hash,
  nonce, derived refs or authorization.
- Do not restore Actions review approval to `true`.
- First merge this facts-only failure evidence.
- Then capture a fresh authenticated full before from the new protected main.
- A new independent superseding D2 readiness must:
  - treat Actions approval `false` as before and after, with zero Actions
    mutation;
  - use an API-schema-valid required-status-check write form while preserving
    `guard` and its App ID `15368` binding;
  - provide new exact before/after/rollback payloads, hashes, window and nonce;
  - retain the fail-closed order: strengthen/read back main first, exclude main
    from the ruleset only after branch protection and direct-main negatives
    pass.

This run proves only fail-closed behavior and the Actions capability
reduction. `RPT-BOUNDARY-001`, `RPT-MAIN-001`, `RPT-IDENTITY-001` and
`RPT-MIGRATION-001` remain unverified.
