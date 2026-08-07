# Governance and Verification Policy Delta

> Change: `CHG-2026-056-e2-policy-baseline-alignment@r7`
> Targets: `openspec/governance/enforcement.md`, `openspec/verification/policy.md`

## MODIFIED Control-plane rule

Future changes to destructive automation admission or the complete-overwrite recovery coverage
domain remain Repo-plane Safety changes requiring OpenSpec plus human maintainer review/merge.
Published Runtime executions and recovery epochs create Job/Session/Artifact records, not Git tasks
or PRs.

No standing authorization, campaign confirmation, Git carrier, AUTH-ID, legacy mode, UI click or
per-attempt user message is required for a new destructive Agent request, ordinary continuation or
mechanically eligible recovery. Only protected-main Runtime may derive the capability and
`safeToReflash` / `safeToSupersedeByCompleteOverwrite` classification from published policy and
trusted facts. Caller/Agent/evidence/human text cannot supply either classification.

D0/D1/D2 decision grades remain orthogonal to Runtime effects. Approval of this r7 Core delta is a
D1 product/Safety decision. After implementation, each physical recovery dispatch is governed by
the published Runtime policy and its own durable run record; it does not require a new D2 chat
decision or authority artifact.

## MODIFIED Destructive execution and evidence policy

The gate SHALL enforce published typed operation/Step closure, exact target/binding/inputs/plan/
archive/artifact facts, fresh readback, Artifact lease validation, durable reservation,
intent-before-effect and truthful terminal outcome. A closed automation invocation remains bounded
to sixteen serial destructive epochs, four hours and concurrency one.

Unknown effects SHALL never cause replay of their original intent. A distinct complete-overwrite
recovery MAY dispatch only after Runtime conservatively derives every possible effect and proves a
reviewed Provider plan covers the union with fresh same-target facts. Recovery gets a new
capability/reservation/intent. Only confirmed writes plus reboot/rebind/postflight may create a
durable `SupersedingRecoveryEpoch` and release the target lane; the old outcome stays unknown.

Existing later real Flash history may be recognized without hardware dispatch only from complete
durable identity, ordering, coverage, outcome and postflight facts. Missing proof, unknown identity,
incomplete coverage, drift, cancellation or exhausted budget produces zero new dispatch and a
non-overridable diagnostic. Human confirmation cannot substitute for proof.

New evidence SHALL record exact recovery lineage, uncertain-effect and coverage digests, actual
typed Steps and resulting target epoch. Simulation/fake/plan-only never counts as target recovery
or real hardware. Historical authority bytes remain decode/export-only and cannot admit recovery.

## Approval boundary

This r7 text is not effective while `proposal.md` says `proposed`. Approval requires human
maintainer review and merge to protected `main`; this proposal PR performs no Runtime capability,
device, recovery or history-migration action.
