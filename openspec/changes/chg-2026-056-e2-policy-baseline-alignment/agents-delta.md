# AGENTS.md Delta

> Change: `CHG-2026-056-e2-policy-baseline-alignment@r7`
> Target: `AGENTS.md`
> Applies only after this Core/Safety revision is explicitly approved and merged.

## MODIFIED Device Agent Runtime Plane

Device Agent Runtime executes operations published on protected `main` and creates Runtime
Job/Session/Artifact records. Execution and mechanically proven recovery never require a Git Task,
change ID, PR, readiness packet, AUTH-ID, legacy mode, UI acknowledgement or a human to retype or
approve the plan.

- `hostOnly` / `readOnly` use the bounded default read-only policy.
- `deviceMutation` / `destructive` use an exact Runtime-owned `RuntimeCapability`.
- Only protected-main Runtime may mint, reserve and consume a destructive capability after complete
  plan materialization from published Catalog and trusted facts.
- `standingAuthorization` and `evolutionCampaignConfirmation` are legacy decode/export kinds and
  cannot admit a new operation or recovery.

The Runtime gate SHALL re-materialize the published typed plan, verify Artifact leases, read fresh
target/binding/tool facts and reserve each use immediately before its first external effect. A
closed automation invocation is limited to sixteen serial destructive epochs, four hours and
concurrency one.

An unknown destructive intent SHALL never be resent. If protected-main Runtime can conservatively
bound all possible effects and a reviewed Provider contract proves a distinct complete-overwrite
plan covers all of them, fresh facts MAY produce `safeToSupersedeByCompleteOverwrite` and Runtime
MAY execute that recovery automatically. Success records a durable `SupersedingRecoveryEpoch`,
preserves the original unknown outcome and releases only the proven target lane. Existing later
Flash history may be linked only from complete durable identity, coverage, outcome and postflight
proof.

Identity uncertainty, unbounded or incomplete effect coverage, trusted-fact drift, an undeclared
Provider recovery path, cancellation, expiry or budget exhaustion SHALL fail closed with zero new
dispatch. The Runtime reports a non-overridable blocker and SHALL NOT ask the user for an approval
that cannot supply the missing proof.

## MODIFIED Agent prohibition

Agents SHALL NOT create or alter trusted target facts, RuntimeCapability records, uncertain-effect
sets, Provider coverage declarations, durable reservation/outcome/supersession records or hardware
evidence to make a destructive request pass. They SHALL NOT relabel a replay as recovery, treat a
later success string as coverage proof or migrate legacy authority bytes. Simulation, fake and
plan-only results SHALL NOT be represented as real hardware.

Candidate and repairer remain isolated from device transport, Runtime and capability admin. A
Runtime Agent SHALL NOT execute raw shell/HDC/RockUSB strings, undeclared operations or caller-
supplied argv. UI acknowledgement communicates userdata impact only. `scripts/host_loop` remains
Repo Agent Plane only and SHALL NOT execute device Runtime jobs.

## REMOVED Ambiguities

- `outcomeUnknown` means the original effect can never be replayed; it does not mean a mechanically
  proven full-device recovery must wait for a human.
- A user click or chat message cannot authorize either retry or recovery.
- A later Flash supersedes old target hazards only through an exact durable identity/coverage/
  verification relation; temporal ordering or `succeeded` alone is insufficient.
- A true wrong-target, unbounded-effect or incomplete-coverage condition remains a hard stop rather
  than an interactive override.
