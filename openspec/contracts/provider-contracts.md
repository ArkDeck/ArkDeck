# Provider and Adapter Contracts

> Version：1.0.0  
> Status：in baseline CORE-1.0.0（ratification 状态见 `openspec/baselines/CORE-1.0.0.yaml`）  
> Baseline：CORE-1.0.0

## Typed Step

```text
WorkflowStep
  id
  kind: closed enum
  effect: hostOnly | readOnly | deviceMutation | destructive
  cancellation: immediate | atSafeBoundary | criticalNonInterruptible
  bindingRequirement: none | confirmedDevice
  arguments: validated typed payload
  compensation: optional typed descriptor
```

The registry is `workflow-step-registry.yaml`; the executable shape is `workflow-step.schema.json`. Provider plans SHALL validate against `#/$defs/workflowStep`, and persisted Manifest records SHALL validate against the same contract's `#/$defs/executionRecord`. Core owns each kind's minimum effect, cancellation policy, binding requirement, typed argument shape, and whether a Profile may expose it. Provider/Profile may strengthen but never lower them. Unknown kind is rejected as destructive/unsupported.

Generic `runHDC(arguments)` and `runRemoteTool(arguments)` are not Profile step kinds. `executable`, `shell`, `argv`, raw HDC arguments, and equivalent command-bearing fields are also forbidden in Profile payloads. They are private Adapter execution details reached only after a registered typed kind and its catalog/provider operation ID have been validated. This prevents wrapping flash/erase or an unknown command as readOnly.

Every catalog-bearing Step SHALL match the closed catalog/action pairs encoded in
`workflow-step.schema.json`. The matching human-readable catalogs are hash-pinned
inputs; `remote-operations.yaml` additionally fixes operation → kind/minimum effect,
cancellation and binding. An Adapter SHALL reject unknown catalog/action pairs and
undeclared parameters before lowering an operation to argv. The word “approved” in
a type or UI label is never authorization by itself.

## Manifest semantic validation

`manifest.schema.json` validates record shape and mode/status invariants. Before atomic publication, the Manifest validator SHALL additionally verify relationships JSON Schema cannot express by itself:

- IDs for steps, Artifacts, compensations and confirmations are unique in the Session;
- binding revisions are strictly increasing, and every non-null step binding revision exists in `bindingHistory`;
- every compensation references its source step and a descriptor declared by that step; confirmation, journal-event and `derivedFrom` references resolve;
- every Artifact path is canonical, remains beneath the Session root after platform-native resolution, and refers to the bytes whose size/hash are recorded;
- `argumentsHash` and compensation hashes match the canonical serialized typed arguments;
- a parameter recorded as `restored` has known `value` states before and after restore, and the restored value is byte-for-byte equal to the captured original; `missing`/`unreadable` is never synthesized as `false`, `0`, an empty string or a delete operation;
- an `outcomeUnknown` journal intent cannot be converted to a confirmed Manifest record without durable reconcile evidence.

Publication fails closed if any structural or relational validation fails.

## Journal and lifecycle semantic validation

Before a journal event is durably accepted, the validator SHALL resolve external schema references and validate the embedded shared typed step/compensation contract. It SHALL additionally prove relationships JSON Schema cannot compare directly:

- envelope `stepId` equals `payload.step.id` or `payload.descriptor.id` as applicable；
- `argumentsHash` equals canonical serialized typed arguments, and binding revision/target equals the durable binding used for dispatch；
- every `stateTransition` is an allowed Core graph edge and its reason/trigger evidence matches the transition guard；
- reconcile result, next state, certainty, safe-boundary evidence and binding revision agree；
- finalized status/certainty agrees with the validated Manifest hash。

For a stop/restart `mutateHDCServerLifecycle` action, dispatch additionally requires an accepted `serverLifecycle` confirmation whose `scopeHash` equals the step `impactSnapshotHash`, whose related action/endpoint/generation matches the typed arguments, and whose impact/critical-Job gate was revalidated after confirmation. `startManaged` instead requires the typed absent-endpoint/ownership precondition and a null confirmation ID. The lifecycle intent/outcome and all affected coordinator broadcasts SHALL correlate to the same step/audit IDs. Any missing or mismatched relationship blocks dispatch or finalization；it cannot be repaired by treating the operation as a lower effect。

## Trace Adapter

```text
TraceToolAdapter
  probe(binding, toolchain) -> TraceCapabilities
  validate(configuration, capabilities) -> Issues
  makeCapturePlan(configuration, binding) -> [WorkflowStep]
  parseProgress(output) -> ProgressEvent?
  validateArtifact(url) -> ArtifactValidation
```

Adapter must be selected from actual tool/help evidence. Unknown output returns unsupported/raw detail rather than guessed behavior.

## Flash Provider

```text
FlashProvider
  identity -> ProviderIdentity
  probe(binding, toolchain) -> ProviderCapabilities
  validate(imageSet, device) -> [Issue]
  prerequisites(device, imageSet) -> [FlashPrerequisite]
  makePlan(imageSet, device, mode) -> [FlashStep]
  parseProgress(output) -> ProgressEvent?
  postflight(context) -> PostflightResult
  recover(failureContext) -> RecoveryGuide
```

```text
FlashPrerequisite
  capability: root | updater | flashd | unlocked | stablePower | recoveryPath | providerSpecific
  requirement: required | optional | notApplicable
  state: satisfied | unsatisfied | unknown
  evidence
```

Rules:

- Any required prerequisite that is unsatisfied or unknown blocks execute.
- Plan-only retains all planned steps but never dispatches deviceMutation/destructive.
- Simulated Provider never receives a real binding or process executor.
- Success requires semantic output validation and postflight, not exit code alone.
- RecoveryGuide is guidance, not a claim that automatic recovery is possible.
- A destructive dispatch requires durable `executionAuthority`. `standardAgent`
  always refuses real destructive steps; `controlledHardwareLab` means a human
  operator personally executes against a plan they confirmed: device identity +
  binding revision, firmware, transport, HDC, Provider and the Step-kind set of
  the pending dispatch SHALL match the human-confirmed plan, and the executor
  SHALL revalidate them immediately before the first real-device Step. Human
  confirmation SHALL precede the first dispatch; the executor SHALL stop when
  any field drifts, and a run record or after-the-fact evidence cannot
  retroactively authorize dispatch. `interactiveUser` follows normal product
  confirmation but cannot mint support-matrix evidence. Authority is issued by
  the trusted host entry point and journaled at Job creation; a Profile, CLI
  argument, Task payload or imported Manifest cannot promote `standardAgent`
  to either stronger authority.

## Platform ports

Provider and Adapter code may depend on `ProcessExecutor`, storage, clock and logging interfaces from `architecture/platform-ports.md`. They must not depend directly on a UI toolkit.
