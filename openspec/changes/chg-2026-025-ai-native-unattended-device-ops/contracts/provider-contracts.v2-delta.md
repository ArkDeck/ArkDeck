# Provider and Adapter Contracts v2 Delta (change-local draft)

> Target version: 2.0.0
> Base: `openspec/contracts/provider-contracts.md` v1.0.0
> Scope: TASK-AIN-005 persistence/semantic closure only
> Status: draft; this file does not replace the current contract and grants no dispatch authority

## Unchanged rules

Every v1 typed-Step, catalog, argv-free lowering, target binding, outcome, recovery,
Artifact, platform-port and fail-closed rule remains normative. In particular,
`standardAgent` and ordinary CI cannot produce a destructive-success record, plan-only and
simulation cannot be represented as real execution, and recovery-abandon remains an interactive
human confirmation.

## Closed authorization reference

`authorizationRef` is a closed object containing exactly:

```text
authorizationId
mainCommitOID             # full 40-character lowercase Git OID
authorizationBlobOID      # full 40-character lowercase Git OID
approvalPRNumber          # positive integer
```

A branch, tag, abbreviated OID, filesystem path, string carrier, caller JSON or imported Manifest
cannot substitute for this object. TASK-AIN-005 validates only shape and correlation. It does not
resolve GitHub provenance and cannot mint a production grant.

## Manifest v2

Manifest `schemaVersion=2.0.0` adds required nullable `authorization`.

- `executionAuthority=authorizedAgent` requires
  `{authorizationRef, usageReservationId, destructiveIntentEventIds}`.
- Every executed or `outcomeUnknown` destructive Step maps to exactly one durable v2
  `stepIntent`; the listed IDs equal that set with no duplicate, missing or ghost reference.
- Every other authority requires `authorization=null`.
- Confirmation `actor` is either `{kind:interactiveUser}` or
  `{kind:authorizedAgent, authorizationRef}`. The latter is allowed only for `authorizedAgent` and
  its reference must equal the Manifest, journal and usage reference.
- Export/redaction preserves authorization OIDs, authorization/reservation IDs and intent IDs;
  they are non-device provenance. Target identity bytes remain subject to redaction.

## Journal event v2

A v2 `authorizedAgent` `jobCreated` carries `authorizationRef` and `usageReservationId`.
Every destructive `stepIntent` and its matching `stepOutcome` carries the same pair, and the
outcome still references the exact intent event. Replay and append validation reject:

- missing or drifted reference/reservation fields;
- authorization fields on a non-destructive or non-authorized event;
- duplicate/ghost outcome correlations;
- a mixed v1/v2 Session.

Historical v1 bytes keep their v1 reader behavior. Only v2 can express authorized-agent
destructive success.

## Authorization usage ledger v1

Before any destructive intent is appended, the host must durably reserve one usage in
`authorization-usage-1.0.0` under a stable host-wide lock. Persistence order is:

1. validate the owner-safe root, lock and current regular-file binding;
2. acquire the host-wide lock and revalidate path/inode bindings;
3. write a same-directory exclusive temporary file;
4. full-sync the file;
5. atomically replace the ledger and validate the resulting binding;
6. sync the parent directory.

The ledger rejects duplicate IDs, non-monotonic ordinals, reference/maxRuns drift, unknown JSON
members, symlinks, hardlinks and path replacement. `maxRuns > 0` is a hard ceiling;
`maxRuns = 0` is unbounded. A durable reserve consumes the ordinal permanently. Failure,
cancel, interruption, `outcomeUnknown` and crash do not refund it. An identical reservation retry
returns the same receipt; any field drift fails. Terminal state may only close an existing
reservation and cannot rewrite usage history.

## Dispatch boundary

These persistence types do not dispatch device commands and are not an authorization verifier.
The trusted provenance/facts/usage gate and the product executor integration remain scoped to
TASK-AIN-006 and TASK-AIN-007. Until those independently approved changes land, production
`authorizedAgent` destructive dispatch remains unavailable.
