# TASK-RPT-001 topology execution receipt — ref read-after-write stop

- Date:2026-07-24.
- Classification:real human-isolated GitHub control-plane execution.
- Executor:human `lvye`; Agent privileged dispatch:0.
- D2 authority:PR #470 exact reviewed head
  `c5cb4757065a9a3c65b5f98351e56a3236eda396`.
- Result:**FAIL CLOSED — topology rolled back; no main incident**.
- Task status:remains `ready`.
- Acceptance boundary:no topology AC is marked PASS by this receipt.

## Authority and execution envelope

The executor pinned and verified:

```text
readiness base: e36aba91f1d88dd74330a4e61ebde4027071a9f9
reviewed head:  c5cb4757065a9a3c65b5f98351e56a3236eda396
merge main:     928d6e06b928e16874df9137950a9830aa38d8d0
readiness blob: c57b4781bc1f1cd74fe64f8023bfee1e603cb904
merged at:      2026-07-24T10:31:49Z
subject:        governance(TASK-RPT-001): authorize topology D2 (#470)
```

The optional PR `merge_commit_sha` observation was `null`; it contributed no
authority. The current protected-main commit, its parent and subject,
associated PR, exact bot-authored head, exact-head `lvye` approval,
`mergedBy=lvye` and `guard=success` closed the merge proof.

Executor:

```text
path class: human-isolated temporary executor
SHA-256: 124f9b799169fda8e3b0814442accf925f51efffdb2b7165acb7063743dd8f2c
window: [2026-07-24T10:30:00Z, 2026-07-24T16:30:00Z)
started: 2026-07-24T10:44:25.043597Z
finished: 2026-07-24T10:45:59.927776Z
logout verified: true
```

The #470 executor, payload, hashes, UUIDs and window are exhausted by this
failure and must not be reused.

## Preflight

The authenticated preflight matched all pinned inputs:

| Object | Canonical bytes | SHA-256 |
| --- | ---: | --- |
| ruleset full JSON | 702 | `a5725db245d84174090de47e1fc45123219dbf5cfdd00d45856b04d801a3d5f2` |
| branch protection full JSON | 1,227 | `e45fb8583eb8002e49fcd402c0d9026f7277a1b823b6fe7410695da5666f0b0c` |
| repository settings | 660 | `8f605ec84f4d83ef6a860c238e1c506cacd1ab8c85ecb90448bdf2a684daf3f7` |
| actor projection | 4,449 | `cdd8fc98d2a1fccbbb619c4ddf987975aa7a97f971754542bd0ccde383b293d0` |
| open PR projection | 607 | `0a8d7d2b9940e7d12fe129174c8ec00b01d728512e353438817abffb2822ecbb` |

The operator was authenticated as `lvye` / ID `4340161`. The workflow route
scan found no review or privileged governance route in
`.github/workflows/agent-pr.yml` or `.github/workflows/sdd-guard.yml`.

## Applied protections and authenticated read-back

The branch-protection PUT succeeded. Its authenticated after projection was:

```text
bytes: 674
SHA-256: f423ce0ca2eb3f667a34dbb7f9bcfa923266928d073ee0e50763b2f69ee2663a
```

It required a pull request, one approving review, CODEOWNER review, strict
App-bound `guard` (`app_id=15368`), linear history and administrator
enforcement. Its push restrictions contained only user `lvye`; teams and
Apps were empty. Force-push and deletion remained disabled. The full
authenticated after object was 2,942 canonical bytes with SHA-256
`04f09f273fce806afaa44679c9e8257c74cce3e480fe60da27c7dcca06e85f04`.

The ruleset PUT then succeeded. Its authenticated after projection was:

```text
bytes: 343
SHA-256: 9bb7ef3d62246733ca1dcaac074a3b07f5b4aead6985d645cd58fbf82db62163
exclude:
  - refs/heads/agent/**
  - refs/heads/agent/**/*
  - refs/heads/main
```

The rules remained active `creation`, `update` and `deletion`; the sole
bypass actor remained human user `lvye`. The full authenticated after object
was 744 canonical bytes with SHA-256
`d281e19936fe6cc656ade7b678f42cf884b01cf7e51554c3a93ece637ee55503`.
The authenticated effective-rules read for `main` was empty at this point,
so the subsequent branch-protection-only probe did not rely on ruleset
overlap.

## Completed probes before the stop

All main observations stayed at:

```text
928d6e06b928e16874df9137950a9830aa38d8d0
```

The server rejected:

- Deploy Key update of `main` while both ruleset and branch protection
  overlapped (`GH013`);
- direct `lvye` update of `main` while both protections overlapped
  (`GH013`, including “Changes must be made through a pull request”);
- Deploy Key update of `main` after the ruleset excluded `main`
  (`GH006`, including pull-request and required-`guard` violations).

The last rejection is the direct negative evidence that branch protection
alone rejected the Deploy Key. None of these attempts changed `main`.

The Deploy Key successfully created, updated and deleted the single-layer
ref:

```text
refs/heads/agent/rpt001-03d9fe72-51e6-4b4b-8064-cb01a632e490
```

It also successfully created and updated the multi-layer ref:

```text
ref: refs/heads/agent/rpt001/deep/7908274d-d874-47d6-b844-c2e35ba9d2a9
create OID: 928d6e06b928e16874df9137950a9830aa38d8d0
update OID: 2e1e5ce85266f96f54eb60d9f2547398d1c9b3e7
```

## Fail-closed trigger

Immediately after the successful multi-layer update push, the executor's
single Git-ref REST read returned the prior OID
`928d6e06b928e16874df9137950a9830aa38d8d0` instead of the expected
`2e1e5ce85266f96f54eb60d9f2547398d1c9b3e7`. The executor treated this as
ref drift and stopped.

A later read-only `git ls-remote` returned the expected updated OID
`2e1e5ce85266f96f54eb60d9f2547398d1c9b3e7`. Together with the successful
push receipt, this is consistent with transient REST read-after-write
visibility lag. That explanation is an inference, not a converted PASS:
the approved executor required immediate equality and therefore failed
correctly.

The remaining ordinary-ref, `agentx/**`, API identity, PR-state and normal
no-bypass merge matrix was not reached. Multi-layer deletion was not
successfully completed. The run cannot establish the task acceptance
criteria as a whole.

## Rollback and current public state

The executor restored:

- ruleset write projection: exact pinned before;
- branch-protection write projection: exact pinned before;
- `main`: unchanged at
  `928d6e06b928e16874df9137950a9830aa38d8d0`.

The branch-protection full-object hash did not return byte-for-byte to the
capture hash because GitHub materialized a server-normalized empty
`dismissal_restrictions` object during the PUT/rollback cycle. The write
projection was exact, but a fresh authenticated full capture is mandatory;
this receipt does not infer full-object identity from semantic equivalence.

Post-logout public read-only checks confirmed:

```text
main OID: 928d6e06b928e16874df9137950a9830aa38d8d0
main protected: true
guard context: guard / App ID 15368
public admin enforcement summary: non_admins
ruleset ID: 19595282
ruleset enforcement: active
ruleset exclude: ["refs/heads/agent/**"]
ruleset rules: creation, update, deletion
ruleset updated_at: 2026-07-24T10:45:53.061Z
effective ruleset rules on main: creation, update, deletion
```

The proposed two-layer topology is therefore **not** the current state.
The old ruleset again covers `main`, so the original ordinary-merge bypass
friction remains. This is stricter than the target topology and did not
create an unprotected interval.

Mutation counters:

```text
Actions setting attempts: 0
branch-protection after / rollback: 1 / 1
ruleset after / rollback: 1 / 1
ref probe attempts / successes: 8 / 5
ref cleanup attempts: 1
review attempts: 0
merge attempts: 0
auto-merge attempts: 0
PR-state attempts: 0
credential control-plane attempts: 0
force-push-main attempts: 0
main incident: false
```

## Residual controlled ref and automatic PR side effect

Rollback restored the old ruleset before cleanup. That ruleset excludes only
`refs/heads/agent/**`; it rejected Deploy Key deletion of the deeper ref with
`GH013: Cannot delete this branch`. Read-only observation after logout
confirmed the controlled ref remains:

```text
refs/heads/agent/rpt001/deep/7908274d-d874-47d6-b844-c2e35ba9d2a9
OID: 2e1e5ce85266f96f54eb60d9f2547398d1c9b3e7
```

Creation of that ref also triggered the pinned `agent-pr` workflow before
the update completed. It automatically opened:

```text
PR: #471
state: open
draft: false
author: github-actions[bot] (ID 41898282)
created_at: 2026-07-24T10:45:59Z
head: agent/rpt001/deep/7908274d-d874-47d6-b844-c2e35ba9d2a9
head OID: 2e1e5ce85266f96f54eb60d9f2547398d1c9b3e7
base: main
base OID: 928d6e06b928e16874df9137950a9830aa38d8d0
title: governance(TASK-RPT-001): authorize topology D2 (#470)
changed files: 0
merged: false
auto_merge: null
```

PR #471 is an unintended, obsolete probe side effect. Its copied title has
no new governance authority. It **must never be approved or merged** and
must be closed by the human maintainer under the existing obsolete-PR rule.
This evidence PR does not mutate PR state or delete the ref.

## Receipt integrity and credential containment

The byte-identical sanitized JSON receipt is
`2026-07-24-topology-fail-closed.json`:

```text
bytes (with trailing LF): 14259
SHA-256: a7e6211f3bf7088f0c0147e1b4d35636b369af65d1f11f0cb37df7b85c1dc2c9
canonical bytes (without trailing LF): 14258
canonical SHA-256: fbc701477328648bbf185a32e3b86a8a4db1b936beac1cb6329398207f2d989a
schema: arkdeck-rpt001-topology-apply-report/v1
status: fail_closed
```

The human executor logged out in `finally`; the Agent-side `gh` session had
no authenticated host and no human credential was transferred into the
Agent environment.

## Stop conditions and required successor gate

Until an independently reviewed remediation is merged:

- do not rerun or edit the #470 executor;
- do not reuse its OID, window, UUIDs, payloads or hashes;
- do not treat any individual successful probe as an AC PASS;
- do not manually complete the topology from its transient after state;
- do not delete the residual ref through an unpinned bypass path;
- do not approve or merge #471;
- do not move `TASK-RPT-001` to `done`.

After this facts-only evidence PR is merged, a separate mechanism revision
must:

1. start from then-current protected `main` and fresh authenticated full
   control-plane JSON;
2. use bounded, multi-observation ref verification instead of a single
   immediate REST equality check;
3. account for `agent-pr` side effects, including the existing
   `!agent/host-loop/**` workflow exclusion for suitable multi-level probe
   refs;
4. clean all controlled refs while the after-ruleset still permits their
   deletion, before restoring the old ruleset on any later failure;
5. explicitly authorize cleanup of the residual ref and verify #471 closed;
6. issue new probe UUIDs, exact after/rollback payloads, hashes, operator and
   half-open window in a new independent D2 readiness.

Only a later complete run and independent evidence PR may determine the
topology acceptance criteria.
