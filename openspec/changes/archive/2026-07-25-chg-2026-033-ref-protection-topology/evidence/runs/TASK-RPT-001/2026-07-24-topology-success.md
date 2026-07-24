# TASK-RPT-001 r3 topology execution receipt

- Date:2026-07-24.
- Classification:real human-isolated GitHub control-plane execution.
- Executor:human `lvye`; Agent privileged dispatch:0.
- D2 authority:PR #475 exact reviewed head
  `be1a961694afdb70295fecdf92d375bcbaf3c77a`.
- Result:**SUCCESS — settings and ref matrix completed; no rollback or main
  incident**.
- Task status:remains `ready`.
- Acceptance boundary:this receipt establishes the settings/ref migration
  facts only. Normal no-bypass PR merge and remaining Agent/API route
  negatives require the independent operability-evidence PR.

## Authority and receipt integrity

The executor verified:

```text
readiness base: d94e8f8378fabd14323dddc1ba138391d9dad09c
reviewed head:  be1a961694afdb70295fecdf92d375bcbaf3c77a
merge main:     b69170f573890661dbd731eac8ed99d82e807919
readiness blob: 4283d7c48ae6ec2854f69b608b53b65910e08247
merged at:      2026-07-24T12:08:58Z
subject:        governance(TASK-RPT-001): authorize r3 topology D2 (#475)
```

The nullable PR `merge_commit_sha` observation was `null` and contributed no
authority. Current main, its single parent and subject, associated PR,
bot-authored exact head, exact-head `lvye` approval, `mergedBy=lvye` and
App `15368` `guard=success` formed the authority proof.

Executor:

```text
path class: human-isolated temporary executor
SHA-256: a19a4c538415db7fecbd72845c3e518864b518b355f9651c1f3a5a5f17511260
window: [2026-07-24T12:00:00Z, 2026-07-24T20:00:00Z)
started: 2026-07-24T12:13:48.805984Z
finished: 2026-07-24T12:21:20.191210Z
logout verified: true
```

The byte-identical sanitized JSON receipt is
`2026-07-24-topology-success.json`:

```text
bytes (with trailing LF): 40741
SHA-256: 9340eae63e4b4586a07525340e1c6a4b9fe39c0a5958bda1cda55dda16df9d9f
canonical bytes (without trailing LF): 40740
canonical SHA-256: 188bcf66520c10c721664e3595af9536be1aa9dbe74de1bc76f81320cf87ada0
schema: arkdeck-rpt001-r3-topology-apply-report/v1
status: success-settings-and-ref-matrix
```

The checked-in JSON is byte-identical to the returned report. Credential and
absolute-user-path scans found no token, Authorization/Bearer value or
`/Users/` path.

## Authenticated before

Preflight reproduced every r3 readiness pin:

| Object | Canonical bytes | SHA-256 |
| --- | ---: | --- |
| ruleset full JSON | 702 | `0fd4b6393837e82d6f211ba826728f0db612bad0e200194bf341e5d977676e9b` |
| branch protection full JSON | 1,613 | `7e30197b45effc98224943ebe383c45993cecf31a105dcd52f4a14103e5ea7ab` |
| repository settings | 660 | `8f605ec84f4d83ef6a860c238e1c506cacd1ab8c85ecb90448bdf2a684daf3f7` |
| stable actor projection | 4,449 | `cdd8fc98d2a1fccbbb619c4ddf987975aa7a97f971754542bd0ccde383b293d0` |
| open PR projection | 607 | `0a8d7d2b9940e7d12fe129174c8ec00b01d728512e353438817abffb2822ecbb` |

The operator was authenticated as exact `lvye` / ID `4340161`. The complete
workflow inventory contained only `agent-pr.yml`, `sdd-guard.yml` and
`swift-ci.yml`; the pinned route scan found no forbidden event, review,
merge, auto-merge or governance-administration route. Every fresh probe ref
had zero preexisting workflow run and PR.

The exact #470 residual existed before mutation:

```text
refs/heads/agent/rpt001/deep/7908274d-d874-47d6-b844-c2e35ba9d2a9
2e1e5ce85266f96f54eb60d9f2547398d1c9b3e7
```

#471 was closed/unmerged at that exact head. Its historical run/PR inventory
was captured before cleanup.

## Applied topology

### Main branch protection

The single after PUT succeeded and authenticated read-back matched the exact
projection:

```text
projection bytes: 674
projection SHA-256: f423ce0ca2eb3f667a34dbb7f9bcfa923266928d073ee0e50763b2f69ee2663a
full GET bytes: 2942
full GET SHA-256: 04f09f273fce806afaa44679c9e8257c74cce3e480fe60da27c7dcca06e85f04
```

It requires:

- pull request;
- one approving review and CODEOWNER review;
- strict `guard`, fixed to App ID `15368`;
- administrator enforcement;
- linear history;
- push restrictions users exactly `[lvye]`, teams/apps empty;
- no PR bypass actor;
- force-push false and deletion false.

### Ordinary-ref ruleset

The single after PUT succeeded and authenticated read-back matched:

```text
projection bytes: 343
projection SHA-256: 9bb7ef3d62246733ca1dcaac074a3b07f5b4aead6985d645cd58fbf82db62163
full GET bytes: 744
full GET SHA-256: b172750c1c0764956725393823fa72014146d9e2ec0f1b19c48cf670964d54b5
updated_at: 2026-07-24T20:15:32.888+08:00
```

Exact exclusions:

```text
refs/heads/agent/**
refs/heads/agent/**/*
refs/heads/main
```

The rules remain active `creation`, `update` and `deletion`; the sole bypass
actor remains human `lvye`. Authenticated evaluation for `main` was the empty
array, so the post-switch Deploy Key main rejection was attributable to
branch protection rather than the ordinary-ref ruleset.

## Main and ref verification matrix

Every main observation remained:

```text
b69170f573890661dbd731eac8ed99d82e807919
```

Server-policy rejection facts:

| Probe | Result |
| --- | --- |
| Deploy Key direct-main during overlap | rejected by GH013; target unchanged |
| `lvye` direct-main during overlap | rejected by GH013; PR and `guard` requirements reported |
| Deploy Key direct-main after main exclusion | rejected by GH006 branch protection; PR and `guard` requirements reported |
| Deploy Key ordinary ref creation | rejected by GH013 creation restriction |
| Deploy Key `agentx/**` creation | rejected by GH013 creation restriction |
| Deploy Key existing ordinary ref update | rejected by GH013 update restriction |
| Deploy Key existing ordinary ref deletion | rejected by GH013 deletion restriction |

Positive facts:

| Probe | Create | Update | Delete |
| --- | --- | --- | --- |
| single `agent/**` | success | success | success |
| multi `agent/host-loop/**` | success | success | success |

Positive commit OIDs:

```text
create: 5ceb80709fde44b3717d46296217e8d008439325
update: 6cced5f5e5624719f23424f0ed5594d45db848bf
merge-shaped main negative: d0ca9ef7720ce994a489e01f989ec51ed77f5e1e
```

Every synthetic commit contained exact `[skip actions]`. Each successful
create/update/delete had a Git server receipt, two consecutive matching
`ls-remote` observations and matching authenticated REST state. No
convergence needed more than the bounded budget; no third OID occurred.

The pinned residual deletion succeeded through the Deploy Key. Stable
`ls-remote` absence and REST 404 were observed twice, and the historical
#471/run baseline was unchanged. Every fresh probe produced zero workflow
run and zero PR in both immediate and final observations. All controlled refs
were absent at completion.

## Identity and invariant read-back

Final complete authenticated objects:

| Object | Canonical bytes | SHA-256 |
| --- | ---: | --- |
| branch protection full | 2,942 | `04f09f273fce806afaa44679c9e8257c74cce3e480fe60da27c7dcca06e85f04` |
| ruleset full | 744 | `b172750c1c0764956725393823fa72014146d9e2ec0f1b19c48cf670964d54b5` |
| actor inventory | 4,520 | `feb3e80c5b5070136fbc423a459fb8111d9b352c559cb2c09eb8cf041cfddfac` |
| repository settings | 660 | `8f605ec84f4d83ef6a860c238e1c506cacd1ab8c85ecb90448bdf2a684daf3f7` |

The actor inventory still contains only:

- human collaborator/admin/CODEOWNER `lvye`;
- Deploy Key ID `158088026`;
- no team, App installation, outside collaborator, invitation or assigned
  organization role.

Actions remained `true/read`; repository auto-merge remained false. No
credential setting, Actions setting, review, merge, auto-merge or PR state
was mutated. The isolated `lvye` CLI session was logged out in `finally`;
Agent-side post-handoff status reported no authenticated GitHub host.

Exact mutation counters:

```text
branch-protection after / rollback: 1 / 0
ruleset after / rollback: 1 / 0
ref probe attempts / expected successes: 16 / 9
ref cleanup attempts: 0
Actions setting attempts: 0
credential control-plane attempts: 0
review attempts: 0
merge attempts: 0
auto-merge attempts: 0
PR-state attempts: 0
force-push-main attempts: 0
main incident: false
controlled refs remaining: 0
```

## Post-logout public read-back

At `2026-07-24T12:23:44Z`, Agent-side public/read-only checks found:

```text
main: b69170f573890661dbd731eac8ed99d82e807919
main protected: true
guard enforcement level: everyone
guard context/app: guard / 15368
ruleset ID/enforcement: 19595282 / active
ruleset exclusions: agent/**, agent/**/*, main
remote residual/probe refs: absent
open PRs: only unrelated #468
```

The unauthenticated ruleset projection intentionally omits bypass actors;
the complete authenticated after object in the receipt remains authoritative
for the sole-human bypass fact.

## Acceptance boundary and required next evidence

This run supports:

- `RPT-BOUNDARY-001`: complete live ref matrix and exact ruleset after;
- `RPT-MIGRATION-001`: branch protection first, overlap negatives, ruleset
  second, exact read-backs, main unchanged, no rollback;
- the settings/direct-push portion of `RPT-MAIN-001`;
- the actor/settings/credential-containment portion of
  `RPT-IDENTITY-001`.

It does **not** by itself complete TASK-RPT-001 or the change:

- this evidence PR must first merge through the new topology;
- a separate operability-evidence PR must record that normal compliant
  Squash and merge required no bypass;
- unapproved/guard-pending and Agent/API review/merge/auto-merge/admin route
  negatives remain for that operability evidence;
- `RPT-AUDIT-001` and BAP/HLR current-pointer supersession remain blocked
  under TASK-RPT-002;
- only after execution and operability evidence are merged may a separate D0
  PR propose TASK-RPT-001 `ready → done`.

No rollback is authorized or required by this successful receipt. Any
subsequent authenticated drift requires a new governance decision; this
execution's window, script and UUIDs are now exhausted.
