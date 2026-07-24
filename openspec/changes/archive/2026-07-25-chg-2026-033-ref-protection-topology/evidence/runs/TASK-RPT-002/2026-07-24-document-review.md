# TASK-RPT-002 current-mechanism supersession document review

- Date:2026-07-24.
- Classification:protected-main Git/public metadata/document review.
- Executor:Agent.
- Audit base:`d869f9a36ec95e30bc1fba3c649ed414ca36bf0a`.
- Readiness authority:TASK-RPT-002 readiness #479 exact head
  `8096397bcc66890cb496a36d4cecb5e601f37daf`, squash merge
  `d869f9a36ec95e30bc1fba3c649ed414ca36bf0a`, parent
  `94c23c4123712a46e7fb2f96a0509f84f5f49ba7`.
- GitHub control-plane/ref/probe/credential/PR-state mutation by this review:0.
- Task status:remains `ready`; this record is candidate evidence until its PR is
  reviewed and merged.

## Dependency and evidence review

The following TASK-RPT-001 facts are protected-main ancestors:

```text
execution evidence #476:
6f874efc5c4e9fdd39bcdcc91cfcaa6a862e1961
no-bypass operability #477:
7a221d24133eefed38aa616fcda376fef33f6cf3
done #478:
94c23c4123712a46e7fb2f96a0509f84f5f49ba7
```

Current live-evidence pins:

```text
topology JSON blob:
8eb63bf170e993785acda6345a80558fb6871b76
topology JSON file SHA-256:
9340eae63e4b4586a07525340e1c6a4b9fe39c0a5958bda1cda55dda16df9d9f
topology narrative blob:
6c4541d41c8a166edd201883d10190be031d0bea
no-bypass narrative blob:
73005c421eb3fc36a16b435873a18f6e84b97369
branch-protection projection/full SHA-256:
f423ce0ca2eb3f667a34dbb7f9bcfa923266928d073ee0e50763b2f69ee2663a
04f09f273fce806afaa44679c9e8257c74cce3e480fe60da27c7dcca06e85f04
ruleset projection/full SHA-256:
9bb7ef3d62246733ca1dcaac074a3b07f5b4aead6985d645cd58fbf82db62163
b172750c1c0764956725393823fa72014146d9e2ec0f1b19c48cf670964d54b5
```

The review does not obtain or infer hidden actor state from an anonymous
projection. The complete authenticated objects in the merged TASK-RPT-001
receipt remain authoritative. Agent-side `gh auth status` reports zero
logged-in hosts; no maintainer credential was introduced for this review.

## Historical evidence immutability

The historical files remain byte-for-byte unchanged:

```text
CHG-2026-027 TASK-BAP-003 original run blob:
d6eaf28e188b1f5f64317ce4eacad22eae10ab10
CHG-2026-030 #419 contract evidence blob:
610fad98fe97f0618d04adafd313ebb72bdd0549
CHG-2026-030 #421 failure evidence blob:
9fc841f46c9b62ff74eede541b00890e1c6f6dbe
```

The new CHG-2026-027 addendum preserves the 2026-07-23 GH013 direct-main
transcript as true for its original topology while replacing only the current
causal pointer. The CHG-2026-030 r8 text likewise preserves #419 as source/
repository PASS and #421 as live FAIL. No old run is deleted, edited or
retroactively relabeled.

## Current mechanism mapping

Document review confirms one unambiguous current mapping:

| Concern | Current enforcement | Merged evidence |
| --- | --- | --- |
| single/multi-level `agent/**` writes | non-bypass Deploy Key permitted by the ordinary-ref ruleset exclusions | TASK-RPT-001 ref matrix |
| ordinary and `agentx/**` refs | active ruleset `19595282` creation/update/deletion restrictions | TASK-RPT-001 ref matrix/read-back |
| exact `main` | branch protection requiring PR, human CODEOWNER, App-bound `guard`, admin enforcement and human-only push allowlist | TASK-RPT-001 authenticated after + direct-main negatives |
| human approval | exact-head `lvye` review followed by normal squash merge | #476 no-bypass pilot |
| alternate Agent/API routes | non-CODEOWNER/non-bypass identities, no Agent human credential, no contents/admin/merge route | TASK-RPT-001 actor/route inventory |

The host-loop runbook now uses the same two-layer attribution and explicitly
states that `lvye` in the push allowlist is still subject to PR/review/check.
`openspec/governance/enforcement.md` and `AGENTS.md` retain their audit-base
blobs `e8ff3c130e1b8b15f8405d150ad567e774a0d82b` and
`3c2d3c6a01d3eaa31cd9e3ee333f3153552f4164`; their high-level semantics did
not depend on the old single-ruleset mechanism.

## CHG-2026-030 r8 readiness review

The compatible r8 revision consumes the merged topology evidence and fixes
fresh canary-only targets:

```text
reserved:
agent/host-loop/probes/8bd61cc3-d7c7-41ff-bfc8-0c62952afba3
ordinary:
agent/hlr-002a-control/5a2570ed-5916-4cc8-ac84-4afa294e4b9e
evidence branch:
agent/task-hlr-002a-canary-evidence-r8
```

Read-only discovery found each target and planned branch absent, no remote
`agent/host-loop/**` ref, and only open PR #468. Its complete public diff is
limited to three CHG-2026-026 TASK-RKFUI-001A evidence paths and has no
overlap with RPT/HLR governance, workflows, parsers or target refs.

HLR-002A becomes `ready` only if this exact revision/readiness carrier is
reviewed and merged. It authorizes only reserved-first/ordinary-second
creator canary, read-only run/PR/check observation, Deploy Key cleanup and a
separate evidence PR. It authorizes zero ruleset/branch-protection/repository-
setting/credential/gateway/authorization/integration/scheduler writes and no
review, merge or auto-merge.

#435 OID/window/payload/hash/ref/UUID/executor, #449/r6 gateway and #454
readiness/pins/branch remain permanently superseded. TASK-HLR-002B remains a
`blocked` tombstone; HLR-002/003 remain blocked until HLR-002A has separate
merged evidence and a separate done PR.

## RPT-AUDIT-001 conclusion

Candidate PASS:

- CHG-2026-027 has append-only current-mechanism pointers and a new addendum;
- historical BAP/HLR evidence bytes are unchanged;
- the runbook attributes ordinary refs and main to the correct independent
  enforcement layers;
- CHG-2026-030 r8 consumes actual merged topology evidence and contains a
  fresh, canary-only readiness with new refs and explicit zero-admin scope;
- `enforcement.md`, `AGENTS.md`, Constitution, Core specs/contracts,
  `.github/**`, product source/tests and historical evidence have zero diff.

This candidate conclusion becomes merged evidence only after maintainer
review/merge. TASK-RPT-002 still requires a later independent D0
`ready→done` PR; this record does not mark it done or mark CHG-2026-033
verified.
