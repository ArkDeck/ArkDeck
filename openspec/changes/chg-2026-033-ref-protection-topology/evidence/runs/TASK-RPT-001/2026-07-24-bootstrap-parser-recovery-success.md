# TASK-RPT-001 bootstrap parser-recovery execution receipt

- Date:2026-07-24.
- Classification:real human-isolated GitHub control-plane execution.
- Executor:human `lvye`; Agent privileged dispatch:0.
- D2 authority:PR #466 exact reviewed head
  `bad15fc2ac5e54f684e325e97170857ced9ffd61`.
- Result:**SUCCESS — PR transport setting restored**.
- Task status:remains `ready`.
- Acceptance boundary:no topology AC is marked PASS by this receipt.

## Authority and merge facts

Public GitHub facts and authenticated preflight agreed:

```text
carrier PR: 466
author: github-actions[bot] (ID 41898282)
reviewed head: bad15fc2ac5e54f684e325e97170857ced9ffd61
reviewer: lvye / APPROVED
merged by: lvye
merged at: 2026-07-24T09:17:55Z
merge_commit_sha observation: null
current main: ef13965fb2e0c98a24bffbbf1033f7d34d8076ba
single parent: ced32841a39147e3de74787f755d2377ccfba460
subject: governance(TASK-RPT-001): recover nullable merge parser (#466)
```

The nullable field contributed no authority. Current main, parent, exact
subject, associated PR, `mergedBy`, exact bot-authored head, exact-head human
approval and `guard=success` independently closed the merge proof.

Executor:

```text
path class: human-isolated temporary executor
SHA-256: 41230cb2edec90f1685d9c62eefa1b690d736d378db9ec657a34042624ed05f5
window: [2026-07-24T09:30:00Z, 2026-07-24T15:00:00Z)
started: 2026-07-24T09:33:29.338538Z
finished: 2026-07-24T09:34:51.620344Z
```

## Exact authorized change

Before and rollback:

```json
{"can_approve_pull_request_reviews":false,"default_workflow_permissions":"read"}
```

```text
bytes: 80
SHA-256: fb00f7e1aab4200684b287b484155d5521381f4593552beed4bbb5f9b1622ede
```

After and immediate authenticated read-back:

```json
{"can_approve_pull_request_reviews":true,"default_workflow_permissions":"read"}
```

```text
bytes: 79
SHA-256: e4eea28a28f0c12dc5a441d5d6451c4bc7f3f72ed8f0b717c6cb5502e825965d
PUT exit code: 0
```

The sole write target was:

```text
PUT /repos/ArkDeck/ArkDeck/actions/permissions/workflow
```

## Mutation counters

```text
Actions after attempts: 1
Actions rollback attempts: 0
branch-protection attempts: 0
ruleset attempts: 0
repository PATCH attempts: 0
credential mutations: 0
ref-probe mutations: 0
review mutations: 0
merge mutations: 0
PR-state mutations: 0
```

No rollback was needed.

## Pinned invariant read-back

| Object | Before SHA-256 | After SHA-256 | Result |
| --- | --- | --- | --- |
| branch protection | `e45fb8583eb8002e49fcd402c0d9026f7277a1b823b6fe7410695da5666f0b0c` | same | unchanged |
| repository settings | `8f605ec84f4d83ef6a860c238e1c506cacd1ab8c85ecb90448bdf2a684daf3f7` | same | unchanged |
| ruleset | `a5725db245d84174090de47e1fc45123219dbf5cfdd00d45856b04d801a3d5f2` | same | unchanged |
| stable actor projection | `a621fdb55dd5ef0e9e2888f8c47b00b3a241a97d63565645253df2015f4096d9` | `1ba1f35c93af18e4c8ec3e765150f0060cb2e196bb300001f6cd92e7ff52dd81` | exact approved workflow-field change only |

The stable actor projection changed from 1,437 to 1,436 canonical bytes only
because JSON `false` became `true`. Its comparison projection with the
workflow field normalized to exact before remained pinned by the executor.
Deploy Key, collaborator, team, App, role and bypass inventories did not
change.

## Credential boundary and receipt integrity

The executor rejected credential environment variables, authenticated exact
`lvye`, emitted no credential value, logged out in `finally`, and verified:

```text
logout_verified: true
Agent-side gh authenticated hosts: none
Agent-side GitHub token environment variables: absent
```

The exact JSON receipt is
`2026-07-24-bootstrap-parser-recovery-success.json`:

```text
bytes: 2524
SHA-256: d457037e126de1464895fb834a0b4e85b8977f4290f2c9bde5f4af345e03e8bc
schema: arkdeck-rpt001-parser-recovery-apply-report/v1
status: success
```

## Restored PR-transport liveness

After logout, the Agent created only the new ref
`refs/heads/agent/task-rpt-001-bootstrap-execution-evidence` and pushed the
initial evidence commit:

```text
initial head: b7c66851a63c584a9078326fc92af010980c84f9
base main: ef13965fb2e0c98a24bffbbf1033f7d34d8076ba
```

The restored pinned `.github/workflows/agent-pr.yml` created exactly one PR:

```text
PR: 469
state: open
draft: false
created at: 2026-07-24T09:42:50Z
author: github-actions[bot] (ID 41898282)
head ref: agent/task-rpt-001-bootstrap-execution-evidence
head OID at creation: b7c66851a63c584a9078326fc92af010980c84f9
base OID at creation: ef13965fb2e0c98a24bffbbf1033f7d34d8076ba
title: evidence(TASK-RPT-001): record bootstrap recovery success
open-pr (push): success
guard (push): success / App ID 15368
```

No second PR was created. The follow-up evidence append stays on the same
branch; `open-pr` must observe the existing PR and succeed without creating a
duplicate. PR #469 remains unapproved and unmerged at this evidence boundary.

## Acceptance and next gate

This run proves only:

- the exact Actions combined create/approve setting is restored;
- pinned control objects remained unchanged;
- the isolated human credential was removed after execution.

It does not prove `RPT-BOUNDARY-001`, `RPT-MAIN-001`,
`RPT-IDENTITY-001` or `RPT-MIGRATION-001`; it does not mark TASK-RPT-001
`done` or the change `verified`.

The first push of this evidence branch was the authorized liveness probe for
the restored `agent-pr` channel. Only after this evidence PR is reviewed and
merged may a new, independent topology D2 readiness be drafted from
then-current protected main.
