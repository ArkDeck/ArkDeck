# TASK-HLR-002 D2 identity staging receipt

- Date:2026-07-25.
- Classification:real human-isolated GitHub control-plane execution.
- Executor:human `lvye`; Agent privileged dispatch:0.
- D2 authority:readiness PR #508 exact reviewed head
  `f744a11a72dd405df0797a55445dc3bc2615a563`, merge
  `c7badb73fa3cf12109344731937b88e8bb3611c5`.
- Result:**SUCCESS — identity created, probes completed, all negatives refused,
  cleanup verified; no main incident and no rollback**.
- Task status:remains `ready`. This receipt establishes the D2 facts only; the
  `ready→done` transition requires a separate independent PR.

## Authority and window

```text
readiness PR:      #508
exact reviewed head: f744a11a72dd405df0797a55445dc3bc2615a563
carrier merge:     c7badb73fa3cf12109344731937b88e8bb3611c5
audit base:        901708a7af9893bc91ee654630df6922ea5099f8
merged at:         2026-07-25T00:59:46Z
window:            [2026-07-25T01:04:46Z, 2026-07-25T06:59:46Z)
execution start:   2026-07-25T02:18:25Z
```

`main` advanced four times during the window (#509, #510, #503, #511/#512/#513).
Authority was evaluated as **ancestry of the #508 carrier**, never as equality
with current main; every pinned blob was re-verified unchanged at each observed
main. The carrier's own diff against its parent was exactly
`openspec/changes/chg-2026-030-host-loop-runtime/tasks.md`.

## Preflight rounds (all zero-write)

Three authenticated preflight runs were required. Every round performed GET
requests only; `github_non_get`, `refs`, `prs`, `issues`, `credentials` and
`host_writes` were 0 in all three.

| round | report SHA-256 | outcome |
| --- | --- | --- |
| r1 | `51f2fcb21d5e6ffd002413dd91824f11c1736862b74fbe4b0f636a52d3294474` | **FAIL (tool defect)** — the check-runs endpoint returns an object envelope, not a bare array; the run fail-closed at C1b |
| r2 | `6a0b7e26f8cb40b0a7a537f4641e6d52c04826457c359b6f8fb8ca6af726ac07` | **INVALID (tool defect, fail-open)** — reported ALL PASS, but the installation inventory read had failed and the resulting empty list was judged as "candidate absent". C5's conclusion in this round is void |
| r3 | `b3b8a3f5a563412b4421912ce52b69a7533139232f2c50e17fa9275e3b43dec8` | **PASS** — 12 automated gates, `/orgs/ArkDeck/installations` genuinely read (1 page, 0 installations), C7 hashes byte-identical to the CHG-2026-033 topology evidence |

r2 is recorded as void rather than superseded: an unread inventory can never
establish absence, and the corrected executor turns that condition into a stop.
Executor SHA-256 for r3 = `3cd3362cb06531090840111d084675982e46e2b3c0ce404f6c456a290afd6350`.

Manual confirmations, recorded because REST cannot cover them:

- **C5b** — REST exposes no endpoint listing App *registrations* owned by
  `ArkDeck`; the operator visually confirmed the candidate absent before creation.
- **C8b** — REST does not return Deploy Key fingerprints; the operator confirmed
  `SHA256:HUhfMAcNoDNfZgYKmXjgqpkkjzSs9mWYI+LtyAUuDOI` on key ID `158088026`.

### Protection/ruleset comparison

Authenticated projections and full GETs reproduced the TASK-RPT-001 pins exactly,
with zero mismatches:

```text
branch protection projection: f423ce0ca2eb3f667a34dbb7f9bcfa923266928d073ee0e50763b2f69ee2663a (674 bytes)
branch protection full:       04f09f273fce806afaa44679c9e8257c74cce3e480fe60da27c7dcca06e85f04 (2942 bytes)
ruleset projection:           9bb7ef3d62246733ca1dcaac074a3b07f5b4aead6985d645cd58fbf82db62163 (343 bytes)
ruleset full:                 b172750c1c0764956725393823fa72014146d9e2ec0f1b19c48cf670964d54b5 (744 bytes)
canonicalization:             json.dumps(obj, sort_keys=True, separators=(",", ":"))
```

## Retained identity

```yaml
app_id: 4388667
app_slug: arkdeck-host-loop-runtime-901708a7
bot: arkdeck-host-loop-runtime-901708a7[bot]
owner: ArkDeck
visibility: private
installation_id: 148855345
repository_selection: selected
repositories: [ArkDeck/ArkDeck]
permissions: {metadata: read, contents: read, pull_requests: write, issues: write}
events: []
```

Every other repository/organization/account permission is none; Administration,
Actions, Workflows, Members, Secrets and Contents-write are absent from the
manifest and from the installation projection. The App is **not** a CODEOWNER,
**not** a ruleset bypass actor, and **not** on the main push allowlist
(re-verified after installation).

The single-repository scope was confirmed **authoritatively** with the
installation token via `GET /installation/repositories` = `[ArkDeck/ArkDeck]`.
This was necessary because a user PAT cannot enumerate an installation's
repositories: `/user/installations/{id}/repositories` requires a user-to-server
token and returns HTTP 403 for a PAT, and no org-side REST route returns the
selected repository list. That coverage limit is a platform fact, not a
permission absence.

## Credential and host containment

```text
staging class:   non-repository, non-user-home system directory
path SHA-256:    9b13372c20f89d37145cafce1c103a8606f7c2a0440b950017906f5daaea5eeb
mode/owner:      -rw------- root:wheel
key fingerprint: SHA256:8779fbf2c41ad2deb6475d0ee0d39ec6df3fdfbf8e4109362caf780e9c6ebc66
client secret:   discarded, never emitted
webhook secret:  discarded, never emitted
webhook:         inactive
```

The private key was never read into the executor process: JWT signing was
delegated to `sudo openssl dgst -sha256 -sign`, so the PEM is only ever read by
root. Installation tokens existed in process memory only, were never printed,
logged, written to a receipt, or passed in a child process argv. No raw path,
PEM, token, JWT or shell history appears in any receipt; all receipts were
sanitization-scanned before being written.

Scheduler reservation only: owner short name `arkdeckhlr` and launchd label
`com.arkdeck.host-loop.runtime` are reserved and remain **absent** on the host.
No account, plist, socket or worker executable was created; nothing was loaded,
enabled or kickstarted. **`workerDisabled=true`.**

## Positive sequence

```text
protected main at execution: 177c50086b413536b4b867c9885ecb2f0ce2fee2
probe ref:  refs/heads/agent/host-loop/probes/4020f4b8-19dd-43a7-b8ca-5bc044965b79
probe head: a750c8bf7104f23ccef45c53a05856e2fde18fb0  (empty commit, main tree)
probe PR:   #514   author arkdeck-host-loop-runtime-901708a7[bot], base main
probe Issue:#515   carries Issue-Probe-ID c684f68b-b71a-4c59-8d5f-52d42fae28fd
lease ref:  refs/heads/agent/host-loop/leases/899eb606-e25f-4302-b84c-27a589b41cc2
lease OIDs: create 08c19ee8dd0fe84109a081c45e06b43b9119cd19
            CAS    e5f2b1b2530e33e57c7645653954a592e3e80bff
```

The reserved ref was created, CAS-updated and deleted by the TASK-BAP-003 Deploy
Key with exact `--force-with-lease=<ref>:<expected-oid>` semantics. PR and Issue
were created by the new integration identity. Each mutation was a single intent
followed by an immediate exact read-back.

### Reserved-namespace check coverage — a design gap surfaced and closed in-flight

The readiness requires the probe PR's `pull_request` `guard`/`allowed-paths` and
Swift to reach terminal success. On the reserved namespace this is **not
achievable from the `opened` event alone**:

- `agent-pr.yml` is push-scoped with ordered patterns
  `('agent/**', '!agent/host-loop/**')`, so it does not dispatch for
  `agent/host-loop/**` and its `allowed-paths` job never runs there;
- `sdd-guard.yml` defines an `allowed-paths` job gated
  `if: github.event_name == 'pull_request'` — skipped on every push — and its
  `pull_request` types are `[reopened, edited]`, deliberately excluding bot
  `opened` per design §1H.

The maintainer authorised the minimal in-capability action: **one PR body update
by the integration identity**, which fires `pull_request: edited` and causes
`sdd-guard` to run both `guard` and `allowed-paths` against the PR. Observed
result on the probe head:

| check | conclusions | source |
| --- | --- | --- |
| `guard` | `success`, `success` | push run and `pull_request` run |
| `allowed-paths` | `skipped`, `success` | skipped on push, **success on the `edited` run** |
| `swift` | `success` | push run |

No `action_required` run gated any of these. Legacy creator zero proof on the
reserved head: `agent-pr.yml` run count **0**, all-state PR count **1** (#514).

This is the CHG-2026-030 F1 gap manifesting inside HLR-002. It is recorded here
as a fact and is an input to the TASK-HLR-003 readiness, which must add reserved
`pull_request` allowed-paths coverage in `agent-pr.yml` — `sdd-guard.yml` is a
forbidden path for that task, and §1H forbids reintroducing bot `opened` for the
ordinary lane.

## Negative authority sequence

Seven attempts through the installation token; **every one refused**, zero
severity-1 events.

| probe | route | HTTP | classification |
| --- | --- | ---: | --- |
| direct protected-main ref update | `PATCH /git/refs/heads/main` | 403 | refused-by-permission |
| self-approve own probe PR | `POST /pulls/514/reviews` | 422 | **refused-by-rule** |
| merge own probe PR | `PUT /pulls/514/merge` | 403 | refused-by-permission |
| enable auto-merge | `POST /graphql enablePullRequestAutoMerge` | 200 | refused-by-permission |
| repository admin same-value PATCH | `PATCH /repos/ArkDeck/ArkDeck` | 403 | refused-by-permission |
| branch protection admin | `PUT /branches/main/protection` | 403 | refused-by-permission |
| ruleset admin | `POST /rulesets` | 403 | refused-by-permission |

Five of the REST refusals carried `Resource not accessible by integration`. The
GraphQL auto-merge refusal carried the same message with the PR's **real global
node id resolved**, and REST independently confirmed `auto_merge = null`;
`allow_auto_merge` is `false` on the repository, but the refusal itself was
permission-based, so it does not depend on that setting.

**Honest coverage record:** the self-approval refusal is HTTP 422
(`refused-by-rule`), *not* a permission absence. GitHub's shared
`Pull requests: write` category does reach the review endpoints; what refused the
call is the platform rule that an author cannot approve their own pull request.
This must not be reported as "the review endpoint permission is absent".

A first auto-merge attempt used a fabricated node id (`PR_514`) and failed on
input resolution before reaching authorization. That round is **void**, not a
refusal: receipt `b92766acb3f552793c50221320242ae8bc5521a31aade888eb215c773d9c9bc5`
retains its six valid REST refusals, and the corrected executor now stops rather
than classifying an unresolved node as refused. Valid round:
`6721546981cffec5a46ee597f78c6c5160add64c73bcb66197903166c95e0ed3`.

Stale-fence negative: a CAS against the superseded lease OID
`08c19ee8…` while the remote held `e5f2b1b2…` was refused by the server
precondition. The executor distinguishes a clean `Refused` from an ambiguous
transport failure; only the former is admissible as negative evidence.

Post-negative invariants: `main` OID unchanged at `177c5008…`, PR
`merged=false`, `auto_merge=null`.

## Cleanup and end state

```text
probe Issue #515: closed
probe PR #514:    closed, merged=false, auto_merge=null
lease ref:        absent
probe ref:        absent
read-backs:       two stable observations, both refs absent
```

### Resolved observation — early probe-ref deletion, attributed

The probe ref was created in phase b1 and was **never deleted by this executor**,
yet phase b3 observed it already absent. The #514 timeline attributes it exactly:

```text
event:      head_ref_deleted
actor:      lvye
created_at: 2026-07-25T02:55:42Z
```

That is the authorised operator, acting manually between the negative sequence
(finished 02:54Z) and phase b3's cleanup (started 02:56:40Z). No unauthorised
actor, no automation and no merge is involved; the deletion moved the ref to the
state cleanup required anyway, and b3 recorded it as already absent rather than
claiming to have performed it.

Ruled out by observation before attribution:

- `delete_branch_on_merge` is `true` but applies only on merge, and #514 was
  closed **unmerged**;
- the repository workflow inventory contains only `agent-pr.yml`,
  `sdd-guard.yml` and `swift-ci.yml` — no branch-pruning workflow exists;
- concurrent sessions were demonstrably active in this window (#511, #512, #513
  landed during it), so a foreign actor had to be excluded by evidence rather
  than by assumption.

**No merge occurred.** This is established three independent ways, none of which
relies on the branch's existence:

1. protected `main` remained exactly `177c50086b413536b4b867c9885ecb2f0ce2fee2`
   across b1, b2 and post-cleanup observation;
2. the probe commit `a750c8bf…` is **not** an ancestor of `origin/main`;
3. PR #514 reads `state=closed`, `merged=false`, `auto_merge=null`.

Per design §5 a branch disappearance is never accepted as merge confirmation.
This observation lowers no other gate and does not alter any conclusion above;
it is retained because an unexplained deletion in a governance evidence chain
must be stated, not absorbed into a cleanup "OK".

### Retained state

Exactly the readiness success shape: the private App, its single-repository
installation, the four minimal permissions, and the root-only PEM staging. The
App is not a CODEOWNER, bypass or main-push actor. Scheduler account and launchd
label remain absent. `workerDisabled=true`. All temporary JWTs, installation
tokens, manifest codes and browser callback state were discarded; the operator
logged out.

## Receipt integrity

| artifact | SHA-256 |
| --- | --- |
| preflight r3 report | `b3b8a3f5a563412b4421912ce52b69a7533139232f2c50e17fa9275e3b43dec8` |
| preflight r3 executor | `3cd3362cb06531090840111d084675982e46e2b3c0ce404f6c456a290afd6350` |
| install verify report | `5a5d7832890cfebff653026fe927922c0fed1dbd1aecddafbaf1e21fdd2f43c1` |
| install verify executor | `a8041cdcc94e24d02e51eba42781f34010f19e948ef63bb4b22adae0451ce06e` |
| phase A receipt | `75f1cae2a8eb4bee6de5096634e3a118d8bf8fa6c4c3b5ac6548d429a84b9900` |
| phase A executor | `f55180466d64b05dc6d84ec9a3710168c3438b61edd8f9da3ba2be6f3ed17cda` |
| phase b1 receipt | `808f300bd2db8ffdf18fb8de29a7ae13bbd2c4a0b6083a0f57da52e8f52f15a5` |
| phase b2 receipt (valid) | `6721546981cffec5a46ee597f78c6c5160add64c73bcb66197903166c95e0ed3` |
| phase b3 receipt | `e00c7f81c6c73b1a257e75b817d8d13e6ed25ccf9d720f00f8fa7205267528db` |
| phase b executor (b2 valid, b3) | `dafbd6d08ea3bc0e7fe7c9e6202b48239d21d3626d8295f9af09f743b558d893` |

Void/failed rounds retained deliberately: preflight r1
`51f2fcb2…`, preflight r2 `6a0b7e26…` (fail-open, C5 void), phase b2 first round
`b92766ac…` (auto-merge item void). Credential and absolute-user-path scans
found no token, `Authorization`/`Bearer` value, PEM or `/Users/` path in any
retained receipt.

## Boundary

This receipt does not constitute task `done`, HLR-003/004/005 readiness, or
change `verified`. Worker registration, scheduler enablement and source-hash
binding belong to TASK-HLR-003's separate D2 evidence phase; the worker is still
disabled and no scheduler exists.
