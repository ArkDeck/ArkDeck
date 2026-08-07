# Hardware Evidence Contract Delta

> Change: `CHG-2026-056-e2-policy-baseline-alignment@r5`
> Target: `openspec/contracts/hardware-evidence.schema.json`
> Current version: 4.0.0
> Proposed version: 5.0.0

## MODIFIED Contract

For new Agent evidence, the closed `executor.authority.kind` vocabulary SHALL contain only:

- `defaultReadOnlyPolicy` for `hostOnly` / `readOnly`; and
- `runtimeCapability` for `deviceMutation` / `destructive`.

A destructive `runtimeCapability` record is valid only when all of the following correlate with
the same durable real-hardware Job:

- `reference` identifies the Runtime-owned capability record;
- positive `useOrdinal` and non-empty `reservationId` identify the durably reserved use;
- operation/version, Catalog digest, plan/Step-set digest, target binding digest and
  archive/Artifact lease/content digests match trusted Runtime admission facts;
- target confirmation is a fresh same-use trusted readback, not caller/UI/chat text;
- every actual external Step has a durable intent and terminal outcome linked to the reservation;
- the recorded effect equals the actual maximum Step effect and is never downgraded.

V5 writers SHALL reject `standingAuthorization`, `evolutionCampaignConfirmation` and
`chatConfirmation`. V1-V4 evidence containing those kinds remains immutable and decodable through
versioned legacy readers, but cannot be re-emitted as V5, migrated into RuntimeCapability or used
to admit/reserve/dispatch a new Step.

Unknown authority kinds, missing/different correlation, raw device identity, caller-supplied
trusted facts or effect mismatches SHALL make evidence invalid. Validation records provenance
only: no valid or invalid evidence instance can mint, modify, consume or retrospectively provide
a RuntimeCapability.
