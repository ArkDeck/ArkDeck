# TASK-RPT-001 r3 no-bypass operability evidence

- Date:2026-07-24.
- Classification:public read-only GitHub metadata, protected-main Git facts,
  protected repository blobs and human UI observation.
- Executor:Agent for read-only collection and document drafting; human `lvye`
  for the observed review and merge.
- Control-plane/ref/credential mutation by this evidence run:0.
- Task status:remains `ready`.
- Acceptance boundary:this addendum records the normal no-bypass merge of the
  independent execution-evidence PR and the remaining PR/API route negatives.
  It does not mark TASK-RPT-001 done or CHG-2026-033 verified.

## Normal no-bypass merge pilot

PR #476 carried only the preceding r3 execution receipt. Public GitHub
metadata and protected-main Git history establish:

```text
PR:             476
title:          evidence(TASK-RPT-001): record r3 topology success
author:         github-actions[bot] / 41898282
base OID:       b69170f573890661dbd731eac8ed99d82e807919
exact head OID: 537af9d6eab05176575da291f67841d1335d9c55
created at:     2026-07-24T12:28:47Z
approval:       lvye / 4340161 / APPROVED
reviewed OID:   537af9d6eab05176575da291f67841d1335d9c55
approved at:    2026-07-24T12:30:59Z
required check: guard / App 15368 / success
guard finished: 2026-07-24T12:28:49Z
merged by:      lvye / 4340161
merged at:      2026-07-24T12:31:10Z
merge OID:      6f874efc5c4e9fdd39bcdcc91cfcaa6a862e1961
merge parent:   b69170f573890661dbd731eac8ed99d82e807919
commit subject: evidence(TASK-RPT-001): record r3 topology success (#476)
auto_merge:     null
```

The human operator reports that #476 was merged with the normal **Squash and
merge** action and did not select
`Merge without waiting for requirements to be met (bypass rules)`. This UI
choice is a human observation rather than an API field. It is corroborated by
the ordering above: App `15368` `guard=success` and the exact-head human
CODEOWNER approval both preceded the human merge, while `auto_merge` remained
null.

The merge advanced main from the exact PR base to the single-parent squash
commit above. It therefore also supplies an auditable PR number in the commit
subject, exact review OID, `mergedBy` identity and resulting main OID.

## Current enforcement at the pilot boundary

The successful D2 receipt immediately preceding #476 fixed and authenticated
the following live topology:

- main requires a PR, one approval, CODEOWNER review, strict `guard` from App
  `15368`, administrator enforcement and linear history;
- main push restrictions contain user `lvye` only; teams/apps and PR bypass
  allowances are empty;
- main force-push and deletion are disabled;
- ruleset `19595282` excludes main and both single- and multi-level
  `agent/**`, while retaining active creation/update/deletion restrictions for
  every other branch and retaining only `lvye` as bypass actor;
- repository auto-merge is disabled;
- Actions is enabled with repository default workflow permission `read`;
- the authenticated installation inventory contains no repository GitHub App
  installation and the actor inventory contains no team or hidden alternate
  maintainer identity.

#476 changed only the two execution-evidence files and the evidence index. It
did not modify workflows, settings, protection policy, credentials or refs
other than its ordinary Agent branch and protected-main squash merge.

## Agent/API route analysis

The route conclusion distinguishes endpoint category from effective approval
authority. Repository Actions permits workflows to create or submit PR
reviews, but neither fact gives the bot the `@lvye` identity or a main update
route.

| Surface | Effective capability | Main/review outcome |
| --- | --- | --- |
| Deploy Key ID `158088026` | SSH Git transport; direct ref operations only | post-switch direct-main probe was rejected by GH006 for PR/`guard`; it has no HTTP review, merge, auto-merge or Administration credential |
| Agent-side CLI/connector | no authenticated GitHub host after the human session logout | review, merge, auto-merge and Administration calls are not constructible |
| `agent-pr.yml` `GITHUB_TOKEN` | `contents:read`, `pull-requests:write`; workflow code only lists and creates PRs | PR author is `github-actions[bot]`; a bot review cannot be `@lvye`, and author self-approval cannot satisfy the required approving CODEOWNER review |
| `sdd-guard.yml` and `swift-ci.yml` tokens | `contents:read` only | no PR-write, contents-write, merge or Administration route |
| GitHub App/integration | authenticated inventory contains no repository installation; main restriction apps are empty | no App can push main or bypass the review gate |
| hand-built merge commit | Git push is the only Agent transport | direct-main and merge-shaped direct-main probes were rejected; linear history, PR and `guard` were explicitly reported |

The broad permissions displayed on the public GitHub Actions App object are
App-manifest metadata, not the effective per-job `GITHUB_TOKEN` grant. The
repository blobs above and default `read` setting determine the effective
workflow grants:

- no workflow grants `contents:write`, so no workflow has a merge/direct-main
  write route;
- no workflow grants Administration write, so repository, ruleset and branch
  protection routes are not constructible;
- the only `pull-requests:write` workflow has no review, merge or auto-merge
  command. Even if that PR-write category were used to submit a review, the
  reviewer would be `github-actions[bot]`, not human CODEOWNER `lvye`, and a
  review on its own authored PR cannot satisfy the gate;
- repository `allow_auto_merge=false`, there is no workflow auto-merge route,
  and no Agent Administration route exists to enable the feature.

Thus the Agent-visible identities can create governance PRs but cannot
provide the required human approval, update main, merge, enable auto-merge or
alter either protection layer.

## Independent blocked-state observation

This operability-evidence PR itself is the bounded negative pilot. Its initial
exact head is intentionally observed through public GET only before any human
review. The following facts will be appended on a later commit of this same
PR:

- initial exact head and PR number;
- zero approving reviews;
- `guard` pending/absent or its exact completion state;
- GitHub `mergeable_state=blocked` after mergeability computation.

No merge, review, auto-merge, PR-state, ref-probe, credential or control-plane
write is attempted to obtain that observation.

## Acceptance conclusion at initial commit

- `RPT-MAIN-001`:the positive no-bypass merge path is evidenced by #476; the
  independent unapproved/guard-state negative remains to be appended.
- `RPT-IDENTITY-001`:PASS for the enumerated Agent/API route inventory and
  negative/unconstructible routes; the PR-write category is recorded without
  upgrading it to CODEOWNER authority.
- TASK-RPT-001 remains `ready`; no done or verified claim is made here.
