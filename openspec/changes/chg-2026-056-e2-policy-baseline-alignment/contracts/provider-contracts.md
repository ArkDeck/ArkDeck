# Provider and Adapter Contract Delta

> Change: `CHG-2026-056-e2-policy-baseline-alignment`
> Target: `openspec/contracts/provider-contracts.md`
> Current version: 1.0.0
> Proposed version: 2.0.0

## MODIFIED Rules

A destructive dispatch requires a durable `executionAuthority` validated by the trusted host
before the first real-device Step. `standardAgent` and ordinary CI always refuse real destructive
Steps. A human operator may personally execute an exact confirmed plan. An autonomous Agent MAY
dispatch only with either:

- `standingAuthorization`: an authority carried by a maintainer-merged PR and exactly matching
  device identity/binding revision, firmware, transport, HDC, Provider, plan/Step set, recovery
  path, validity and use limit; or
- `evolutionCampaignConfirmation`: an unconsumed confirmation from the same supervised interactive
  Agent session, matching the exact plan/target/data impact and the protected-main base,
  candidate allowed paths/diff budget, build target/toolchain, validity and attempt budget.

The trusted host SHALL re-materialize the typed plan, perform fresh target/binding readback and
durably reserve the attempt immediately before dispatch. Campaign dispatch SHALL be limited to 16
serial attempts in four hours, concurrency one. Each subsequent attempt requires a new reservation
and a prior durable `safeToReflash` terminal based on complete outcome/readback. Unknown,
unresolved or unsafe partial outcomes, identity/topology drift, expired/consumed authority,
missing pins or non-PASS review stop permanently with zero new dispatch.

Candidate, repairer and reviewer cannot supply `executionAuthority`, executable/argv, operation,
partition, plan, archive, Step set or target; they have no device transport capability. A Profile,
CLI argument, Task payload, imported Manifest, evidence record or post-hoc chat text cannot
promote `standardAgent`, mint/expand either E2 authority, or retroactively authorize dispatch.
Historical one-shot `chatConfirmation` remains decode/export-only. Authority issuance and evidence
provenance are separate: a valid evidence record never authorizes a Provider call.
