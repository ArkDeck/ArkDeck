# Hardware Evidence Contract Delta

> Change: `CHG-2026-056-e2-policy-baseline-alignment@r7`
> Target: `openspec/contracts/hardware-evidence.schema.json`
> Current version: 5.0.0
> Proposed version: 6.0.0

## MODIFIED Contract

For new Agent evidence, the closed `executor.authority.kind` vocabulary remains:

- `defaultReadOnlyPolicy` for `hostOnly` / `readOnly`; and
- `runtimeCapability` for `deviceMutation` / `destructive`.

A destructive `runtimeCapability` record is valid only when capability reference/use ordinal,
reservation, operation/version, Catalog, plan/Step-set, stable target/binding, immutable
archive/Artifact, fresh readback and every actual intent/outcome correlate with the same durable
real-hardware Job. The recorded effect equals the maximum actual Step effect and is never lowered.

## ADDED Superseding recovery evidence

V6 SHALL add a closed recovery object that is present only for a distinct complete-overwrite
recovery or a durably recognized historical supersession. It SHALL contain:

- `disposition = supersedingRecoveryEpoch` and a unique recovery epoch reference;
- every covered unknown intent reference without changing its original outcome;
- conservative uncertain-effect-set digest and reviewed Provider coverage-contract version;
- exact recovery operation/profile/plan/Step-set, archive/Artifact and tool correlation;
- fresh same-physical-target identity, binding and topology confirmation;
- recovery capability reference, reservation/use ordinal and every actual typed effect outcome;
- reboot/rebind/runtime-build postflight facts and resulting target-state epoch;
- explicit statement that original outcomes remain unknown and original Jobs are not succeeded.

V6 semantic validation SHALL accept the object only when coverage includes every possible effect
and all recovery outcomes/postflight are confirmed. Incomplete identity, coverage, outcome or
postflight produces no V6 realHardware evidence and no target-lane release.

V1–V5 evidence remains immutable and decodable through versioned readers. A later V5 real Flash
may be referenced by a new V6 supersession relation only if all required trusted facts are already
durable and semantically valid; V5 bytes are not rewritten. Historical standing/campaign/chat
authority cannot mint capability, coverage or recovery evidence.

Unknown kinds, missing/different correlation, raw device identity, caller/UI/chat-supplied trusted
facts or effect mismatches SHALL make evidence invalid. Evidence records provenance only and never
authorizes a Provider call.
