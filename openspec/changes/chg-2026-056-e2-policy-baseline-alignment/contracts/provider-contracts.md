# Provider and Adapter Contract Delta

> Change: `CHG-2026-056-e2-policy-baseline-alignment@r7`
> Target: `openspec/contracts/provider-contracts.md`
> Current version: 2.0.0
> Proposed version: 3.0.0

## MODIFIED Admission rules

A real `deviceMutation` or `destructive` Provider dispatch requires a matching Runtime-owned
`RuntimeCapability` validated and durably reserved by the trusted host before the first external
Step. No E2 classification, standing authorization, campaign confirmation, Git carrier, AUTH-ID,
legacy mode, UI acknowledgement or per-attempt user message is required. Human and Agent execution
use the same gate.

For `destructive`, only protected-main Runtime MAY generate the capability after complete
materialization of an operation already published in Catalog. It SHALL bind operation/version,
stable target identity/binding, exact typed inputs, ordered plan/Step-set digest, archive/Artifact
lease and content digest, Provider/tool facts, expiry and use lineage. Caller, Agent, candidate,
repairer, CLI input, Manifest, evidence or chat text cannot supply, mint, install, revoke, modify or
widen it.

Immediately before dispatch the trusted host SHALL re-materialize the plan, verify Artifact
leases, perform fresh target/binding/tool readback and durably reserve the use. An automation
invocation is limited to sixteen serial destructive epochs in four hours with concurrency one.
Ordinary continuation requires a prior durable `safeToReflash` terminal.

## ADDED Complete-overwrite supersession contract

A Provider MAY declare `completeOverwriteSupersessionSafe` only for an exact published operation/
profile version. The declaration is code-reviewed policy, not a runtime caller flag, and SHALL
define:

- the closed set of partitions, boot metadata, userdata effects, device modes and other state that
  every destructive Step may mutate;
- how durable old intents are conservatively mapped to an `uncertainEffectSet`;
- a typed recovery plan whose ordered actions fully overwrite, reset or semantically close every
  covered effect;
- required stable physical identity, binding, topology, loader, power, Artifact and tool facts;
- per-effect verification and final reboot/rebind/runtime-build postflight;
- every state that cannot be covered and therefore requires a hard stop.

Protected-main Runtime MAY derive `safeToSupersedeByCompleteOverwrite` only when the union of all
outstanding uncertain-effect sets on the target lane is finite and a single exact recovery plan
covers the union. Optional or conditional effects remain in the union unless durable evidence
proves they did not occur. An omitted, protected, partially writable or unverifiable partition
makes the recovery ineligible.

The recovery SHALL use a new RuntimeCapability, reservation and intent. It SHALL NOT reuse the old
capability, reservation or intent, and SHALL NOT append a guessed outcome to the old intent. Only
confirmed per-effect outcomes plus reboot/rebind/postflight success may write a
`SupersedingRecoveryEpoch`. If recovery itself becomes unknown, its possible effects join the union
before any further recovery; the same complete-coverage proof and invocation budget are reevaluated.

A later Flash already recorded in durable history MAY be linked as a superseding epoch without a
new Provider dispatch only when exact same-target identity, temporal ordering, full coverage,
per-effect outcomes and postflight are all present and semantically valid. A terminal state or
process exit code alone never satisfies this contract.

## MODIFIED Fail-closed rules

Unknown identity, an unbounded uncertain-effect set, incomplete recovery coverage, undeclared
Provider support, target/binding/topology/Artifact/tool drift, pending cancellation, expiry or
budget exhaustion stops with zero new dispatch. The product SHALL report the missing proof as a
non-overridable blocker; UI/chat confirmation cannot authorize replay or recovery.

Candidate and repairer cannot provide executable/argv, operation, partition, plan, archive, Step
set, target, Provider selection, coverage declaration or capability fields and have no device
transport. Historical `standingAuthorization`, `evolutionCampaignConfirmation` and one-shot
`chatConfirmation` remain decode/export-only. Evidence records provenance only and never
authorizes a Provider call.
