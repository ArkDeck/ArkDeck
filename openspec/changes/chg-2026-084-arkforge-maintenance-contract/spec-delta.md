# Proposed scoped delta — CHG-2026-084 revision 2

## Default Runtime-owned ramdisk restoration

After explicit maintainer approval and protected-main publication of this revision,
`flash.restore-boot-loop@1` MAY use its existing default Runtime-owned capability
issuance policy. Its minimum effect SHALL remain `destructive`; it SHALL retain
the confirmed-device binding, exclusive target lane, one mutation attempt and
bounded 1,000–600,000 ms maintenance budget.

Runtime SHALL derive the exact original-ramdisk plan from the eligible latest
durable primary Flash source and immutable original-image lease. Before any device
mutation it SHALL revalidate source outcome, target identity/binding, Artifact,
materialized plan and tools, reserve and consume one exact capability use, and
durably record intent. Caller-supplied authority SHALL remain refused.

The restoration plan SHALL write only the pinned original ramdisk's complete
4 MiB range. Success SHALL require its own succeeded Provider Job and independent
full-range hash verification. Missing or skipped ramdisk readback SHALL NOT become
success. The operation SHALL NOT write userdata, replay an uncertain intent or
substitute for complete-overwrite recovery. Unknown effects SHALL remain unknown.

Old Catalogs, Jobs, plans, receipts, capability uses and supersession histories
SHALL retain their original digests and semantics. The new Catalog changes no input
schema; read-only input-reference compatibility MAY recognize the exact prior
Catalogs without granting them new execution authority or settling retained inputs.

## Acceptance scenarios

- An eligible confirmed source and fresh complete plan admit one Runtime-owned
  capability use; restoration writes only original ramdisk, independently verifies
  the complete range, and produces a separate succeeded Job.
- Invalid inputs, supplied authority, stale source/plan/Artifact, identity or binding
  drift, and incomplete owner composition refuse before new destructive dispatch.
- A duplicate admitted request answers the same Job. A consumed or uncertain
  restoration intent cannot dispatch again, including after owner restart.
- Failed or skipped independent readback cannot report successful restoration.
  An unknown Provider effect preserves its original uncertainty and blocks replay.
- Every immutable prior Catalog retains its original default policy. An old
  unsettled input owner remains retained; input-schema compatibility changes no
  old Job, journal, capability or authority record.

Host tests verify the production owners over synthetic ports; they are not hardware
evidence. Positive entry-point acceptance requires published code and the real typed
Runtime path. A new ordinary nine-partition source Flash, including userdata, is
outside this policy-only decision and requires its own explicit scope approval.
