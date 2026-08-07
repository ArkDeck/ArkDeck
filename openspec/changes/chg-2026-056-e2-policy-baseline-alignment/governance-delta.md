# Governance and Verification Policy Delta

> Change: `CHG-2026-056-e2-policy-baseline-alignment@r5`
> Targets: `openspec/governance/enforcement.md`, `openspec/verification/policy.md`

## MODIFIED Control-plane rule

Future changes to destructive automation admission remain one of the four Repo-plane changes that
require OpenSpec + human maintainer review/merge. The carrier SHALL be described as
“destructive automation safety policy” rather than “E2 safety policy”. Published Runtime
operations continue to create Job/Session/Artifact records rather than Git tasks or PRs.

The runtime execution policy SHALL use effect semantics rather than E0/E1/E2 authorization tiers:

- `hostOnly` / `readOnly`: bounded default read-only policy;
- `deviceMutation` / `destructive`: matching Runtime-owned `RuntimeCapability`;
- destructive capability: deterministically generated only by protected-main Runtime after full
  typed plan materialization and fresh trusted facts, never supplied or administered by an Agent.

The D0/D1/D2 decision grades remain unchanged and orthogonal to device effects. Approval of this
r5 Core delta is D1. A physical device window or credential/permission change remains D2. There is
no new standing-authorization creation/modification/revocation decision after migration because
new destructive admission no longer consumes that authority kind.

## MODIFIED Destructive execution and evidence policy

No standing authorization, campaign confirmation, Git carrier, AUTH-ID, legacy mode or
per-attempt user message is required for a new destructive Agent request. The gate SHALL still
enforce published typed operation/Step closure, exact target/binding/inputs/plan/archive/artifact
facts, fresh readback, Artifact lease validation, durable reservation, intent-before-effect and
truthful terminal outcome. A closed automation invocation remains bounded to 16 serial attempts,
four hours and concurrency one, and continuation remains `safeToReflash` only.

Unknown identity/outcome, unresolved intent, unsafe partial write, drift, cancellation after
intent, expiry or exhausted budget SHALL produce zero new dispatch. Candidate and repairer remain
unable to reach device transport, Runtime or capability administration. Simulation/fake/plan-only
never counts as real hardware.

New Agent evidence SHALL record `defaultReadOnlyPolicy` for read-only and `runtimeCapability` for
mutation/destructive effects, with exact plan/target/reservation/Artifact correlation.
`standingAuthorization` and `evolutionCampaignConfirmation` remain valid only when decoding or
exporting immutable historical evidence; neither can authorize a new dispatch or be migrated.

## Approval boundary

This r5 text is not effective while `proposal.md` says `proposed`. Earlier approvals of r1-r4 do
not cover it. Maintainer approval requires the same PR to carry `status: approved` before protected-
main merge; implementation and any device execution remain forbidden until that merge exists.
