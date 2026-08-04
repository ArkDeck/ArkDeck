# AGENTS.md Delta

> Change: `CHG-2026-056-e2-policy-baseline-alignment`
> Target: `AGENTS.md`
> Applies only after this Core/Safety scope is explicitly approved and the implementation task is
> reviewed; it does not alter the instructions of the unmerged proposal branch.

## MODIFIED Runtime Agent execution rule

The Device Agent Runtime Plane is the only Agent path that executes a published Catalog
operation. It creates Runtime Job/Session/Artifact records and SHALL NOT require a Git Task,
change ID, PR, readiness packet or a human to retype the typed plan before it can run.

- **E0/readOnly:** a Runtime Agent MAY execute a published read-only operation under the default
  read-only policy after normal target, tool, timeout, byte-limit and privacy admission. A Git
  task/PR is not an execution authority and is not a prerequisite.
- **E1/deviceMutation:** a Runtime Agent MAY execute only with a matching per-device
  `RuntimeCapability`; scope, target/binding, validity, use count and compensation semantics are
  checked immediately before the first mutation.
- **E2/destructive:** a Runtime Agent MAY execute only with an exact
  `standingAuthorization` or same-session `evolutionCampaignConfirmation`, as defined by the
  modified `POL-AGENT-002` and `REQ-FLASH-015`. A valid bounded campaign is an execution
  authority; it SHALL NOT require an extra human handoff, `AUTH-ID`, legacy chat confirmation,
  normal/evolution mode selection, Git Task or per-attempt user message.

The execution gate SHALL re-materialize the published typed plan and read fresh target/binding
facts immediately before each external effect. Missing, consumed, expired or drifted authority;
unknown identity/outcome; a missing fresh reservation; an unsafe/non-terminal predecessor; or a
candidate/budget violation SHALL fail closed with zero new dispatch. A valid immutable candidate
pin follows its fixed isolated build and closed strategy-output validation; independent
adversarial review is not an E2 admission requirement and a candidate change SHALL NOT launch a
runtime review session. A Runtime Agent SHALL
not execute raw shell/HDC/RockUSB strings or an undeclared operation, and SHALL not forge user
confirmation, authority provenance or evidence.

`scripts/host_loop` remains a Repo Agent Plane worker. Its ban on device Runtime jobs does not
limit the Device Agent Runtime Plane; it prevents a repository-development dispatcher from
becoming an untracked device executor. Candidate and repairer remain isolated from device
transport and authority, while the protected-main broker remains the only component that can
dispatch an E2 plan.

## REMOVED Ambiguities

- Do not describe a Runtime Agent E0 operation as requiring an approved change's ready task.
- Do not describe a valid campaign as requiring a second human handoff, `AUTH-ID`, legacy
  `chatConfirmation`, `normal|evolution` selection or a Git carrier.
- Do not use "autonomous Agent never executes" or "human-only destructive evidence" for a
  Runtime Agent that passed the exact E2 gate.
- Do not interpret the `host_loop` device ban as a prohibition on a separately admitted Runtime
  Agent Job.

## Unchanged safety boundaries

This delta does not authorize an Agent with no E2 authority, permit mutable/unknown plan or
target facts, replay an unknown destructive outcome, grant candidate/repairer device access, or
relax typed-only, identity, durability, privacy or truthful-evidence requirements.
