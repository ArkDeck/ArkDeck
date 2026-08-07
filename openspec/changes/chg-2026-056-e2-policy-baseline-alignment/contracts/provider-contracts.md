# Provider and Adapter Contract Delta

> Change: `CHG-2026-056-e2-policy-baseline-alignment@r5`
> Target: `openspec/contracts/provider-contracts.md`
> Current version: 1.0.0
> Proposed version: 2.0.0

## MODIFIED Rules

A real `deviceMutation` or `destructive` Provider dispatch requires a matching Runtime-owned
`RuntimeCapability` validated and durably reserved by the trusted host before the first external
Step. No E2 classification, standing authorization, campaign confirmation, Git carrier, AUTH-ID,
legacy mode or per-attempt user message is required. A human and an Agent execute through the same
Provider safety gate; UI acknowledgement may communicate data impact but is not authority.

For `destructive`, only protected-main Runtime MAY generate the capability after complete
materialization of an operation already published in Catalog. It SHALL bind operation/version,
stable target identity/binding, exact typed inputs, ordered plan/Step-set digest, archive/Artifact
lease and content digest, provider/tool facts, expiry and use lineage. Caller, Agent, candidate,
repairer, Profile, CLI input, Manifest, evidence or chat text cannot supply, mint, install, revoke,
modify or widen it.

Immediately before dispatch the trusted host SHALL re-materialize the plan, verify Artifact
leases, perform fresh target/binding/tool readback and durably reserve the use. A closed automation
invocation is limited to 16 serial attempts in four hours with concurrency one. Each later use
requires a prior durable `safeToReflash` terminal based on complete outcome/readback. Unknown,
unresolved or unsafe partial outcome, identity/topology drift, cancellation after intent,
missing/drifted facts, expiry or exhausted budget stops permanently with zero new dispatch.

Candidate and repairer cannot provide executable/argv, operation, partition, plan, archive, Step
set, target, Provider selection or capability fields and have no device transport. Historical
`standingAuthorization`, `evolutionCampaignConfirmation` and one-shot `chatConfirmation` remain
decode/export-only. They cannot reserve/admit/dispatch or be migrated into RuntimeCapability.
Evidence records provenance only and never authorizes a Provider call.
