# AGENTS.md Delta

> Change: `CHG-2026-056-e2-policy-baseline-alignment@r5`
> Target: `AGENTS.md`
> Applies only after this Core/Safety revision is explicitly approved and merged.

## MODIFIED Authority order and governance carrier

The highest authority SHALL describe the device boundary as typed effect admission, device
identity, fail-closed recovery and privacy, not as E0/E1/E2 authorization tiers. Future changes to
destructive automation admission remain one of the four changes that require OpenSpec + maintainer
PR review; removing the E2 name does not remove that governance carrier.

## MODIFIED Device Agent Runtime Plane

The Device Agent Runtime Plane executes only operations published on protected `main` and creates
Runtime Job/Session/Artifact records. Execution never requires a Git Task, change ID, PR,
readiness packet, AUTH-ID, legacy mode or a human to retype the plan.

- `hostOnly` / `readOnly` use the bounded default read-only policy.
- `deviceMutation` / `destructive` use a Runtime-owned `RuntimeCapability` matching the exact
  operation/version, target/binding, inputs, plan and applicable Artifact facts.
- For a destructive request, only protected-main Runtime may deterministically mint that short-
  lived capability after complete plan materialization from published Catalog policy and trusted
  facts. Caller/Agent/candidate/repairer cannot install, revoke, forge or widen it.
- `standingAuthorization` and `evolutionCampaignConfirmation` are legacy decode/export kinds and
  cannot admit, reserve or dispatch a new operation.

The Runtime gate SHALL re-materialize the published typed plan, verify Artifact leases, read fresh
target/binding facts and reserve each use immediately before the first external effect. A closed
automation invocation remains limited to 16 serial attempts, four hours and concurrency one;
continuation requires a prior durable `safeToReflash` terminal. Missing/drifted facts, unknown
identity/outcome, unsafe partial state, unresolved intent, cancellation after intent or exhausted
budget SHALL fail closed with zero new dispatch.

Candidate and repairer remain isolated from device transport, Runtime and capability admin. A
Runtime Agent SHALL NOT execute raw shell/HDC/RockUSB strings, undeclared operations or caller-
supplied argv. UI acknowledgement may communicate userdata impact but is not execution authority
and is not required for headless Agent execution.

## MODIFIED Agent prohibition

Agents SHALL NOT create or alter trusted target facts, RuntimeCapability records, durable
reservation/outcome records or hardware evidence to make a destructive request pass. Historical
E2 authority bytes SHALL NOT be migrated into RuntimeCapability. Simulation, fake and plan-only
results SHALL NOT be represented as real hardware.

`scripts/host_loop` remains Repo Agent Plane only and SHALL NOT execute device Runtime jobs. Its
device ban does not prevent the separately composed protected-main Device Runtime from executing a
request that passes the Runtime-owned gate.

## REMOVED Ambiguities

- Do not state that real destructive Agent execution requires E2, standing authorization,
  campaign confirmation, per-attempt user text or a maintainer PR carrying an authority instance.
- Do not lower `destructive` to another effect to obtain RuntimeCapability admission.
- Do not interpret a UI click, evidence record, connected USB target or schema-valid request as a
  trusted fact or capability.
