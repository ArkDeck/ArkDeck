# Runtime-owned recommissioning

This proposed GJ-4 increment admits only `flash.recommission@1` for the archived,
expired unknown DAYU200 case. Its typed inputs name an existing retained Job,
the full image lease, the DAYU200 profile, full-restore intent and full verification.
No input supplies a proof, identity override, budget or capability. The ordinary
Flash operation and compatibility alias keep their existing admission behavior.

## Source and identity proof

Runtime reads the completed retained archive, its publication receipt and exact
Manifest at the original private Session root. It validates the original
capability lineage, four-hour expiry and correlated ArkForge execution. The
retained Session's Journal must be an unchanged prefix of its owned Job Journal;
all other unknown Sessions continue to fail the continuity check. A fresh
Provider census must include that exact historical daemon Job and plan as
terminal, with no live Provider Job. Windows process containment supplies the
legacy HDC child-lifetime guarantee; macOS reports this operation unavailable.

The original binding must be revision 1, Normal-only, and still name the exact
Normal CID. Bounded reads establish CPU serial, CID, board profile, boot-tree SN,
the uniquely selected current vendor-slot SN, and USB connector. CPU and USB are
read again. The two SN sources must agree. These stable fields and the original
binding digest enter the materialized plan; varying observation timestamps do not.
The retained binding's USB topology remains historical evidence. Recommissioning
uses the freshly proved attachment for its plan and execution route; that route
must match the identity chain, and subsequent connector drift still refuses.
Windows location-path topology identifies only one attachment and can change
between the USB 2/3 endpoints of the same physical connector. Cross-allocation
and post-reboot checks compare every stable identity field, including the
independently observed connector and original binding digest. Each materialized
plan still pins its exact current attachment; a readback's before/after chains
must also match that attachment exactly.

The Provider receives the proved Loader SN while Runtime history remains anchored
to the original CID and revision. Managed transition controls carry the consumed
identity/budget pins, require a fresh Normal observation and reject the
already-Loader shortcut. The existing exact Loader readback and connector proof
still gate the first partition write. Postflight repeats the whole hardware
chain and cannot publish an early alias.

## Independent allocation and completion

The private allocation ledger serializes reservation and consumption. It records
one initial allocation per original Normal identity, pinning the unchanged source record,
Journal and Provider-state bytes, new request/Job/plan/Artifact, coverage and identity
chain. The deadline is fixed at reservation plus 1,800 seconds. Changing IDs,
restarting, cancelling, archiving or encountering another unknown never refunds
or extends it. Clock rollback or observed expiry permanently closes the budget.
Consumption precedes capability consumption and Provider preparation; a crash in
between burns the allocation. Step permits are clipped to its deadline, including
cached retransmissions; no new managed control is performed after expiry.

All nine mapped partitions, semantic readback, reboot, HDC rebind and postflight
remain required. Only a complete-plan receipt plus a matching fresh postflight
can persist the private completion proof. Runtime then appends the ordinary
SupersedingRecoveryEpoch and advances the same Target from CID/revision 1 to the
proved Loader SN/revision 2. The original binding snapshot, unknown outcomes,
capability use and budget stay unchanged. Restart may complete only these durable
projections, with no device dispatch. Ordinary mutation continuity recognizes the
retained Session only after that successful supersession, never from allocation
or consumed authority alone.

## Controlled retry after the first unknown

Revision 2 adds two optional typed references to the same operation:
`failedRecommissionJobId` and `restorationArtifactLease`. They must appear
together. An ordinary request does not become a retry when an earlier run fails.
The first allocation must be consumed and expired; its exact failed Job must
remain a durable unknown with no resident writer. Runtime checks both historical
Provider joins, the unchanged root archive and the whole fresh identity chain.
The coverage census includes exactly both source Jobs and rejects any other open
Job or unbounded effect. The second ledger entry pins both history digests and
the first allocation digest without changing any field of that first entry.
There can be at most two entries for the original Normal identity.

Before allocation, Runtime validates two immutable full bundles, permitting only
the ramdisk bytes to differ. The primary ramdisk must match the pinned ArkForge
preboot construction and encode a fresh nonce; the restoration image must match
the pinned original 4 MiB image. Both sealed Provider plans, immutable artifact
hashes, identity chain and request fingerprint are stored in the private Runtime
program cache and included in the materialized plan digest. No proof-import or
capability-management input is added.

The primary plan writes all nine partitions. Loader read-window skips remain in
their original receipts. Runtime first fetches the nonce-bound RAM report for
the complete userdata range measured before stock init mounts it. The closed
reader checks the RAM-backed descriptor, root-only ownership, bounded length,
current boot ID, storage CID, exact range and unmounted preboot observation; it
never supplies the expected hash to the device. Runtime independently hashes the
eight static ranges with before/after metadata checks and rejects writable mounts.
Every measurement is compared to the sealed effect and immutable image digest.

Only after all nine primary ranges verify does Runtime run the already sealed
restoration plan under a distinct child correlation, the same consumed authority
and the same absolute deadline. It writes the entire original 4 MiB ramdisk,
reboots, verifies that complete range and repeats the full identity chain. Durable
primary measurement, restoration intent/execution/completion and final proof
records must agree. Passive reconciliation validates these records and both
Provider plans/receipt sets; it never resumes a missing phase. Failure keeps both
old unknowns and the new unknown, and cannot allocate a third budget.
The restoration intent records its fresh complete identity chain and observation
digest before dispatch, and its exact attachment must match the restoration
execution. Version-1 intents remain readable only with the original admission
attachment; version 2 carries this fresh proof. Neither form changes an old
allocation or substitutes a route string for the physical connector proof.

## Compatibility and validation

Catalog generators, the Swift durable-record reader, the Rust lifecycle/result
readers and embedded App catalog-review digests are updated together. This does
not add an App action or reinterpret recommissioning as a full-restore alias.
The descriptor response schema also declares the new example inputs, with the
Windows ClientKit generated from the same contract. The test router accepts the
exact additive Catalog digest and retains mandatory frozen c6/e4 input views;
oracles carrying those Catalogs' authority run in their original view. New
operation cases execute only where that operation exists.
Historical request, authority and result fixture bytes are not rewritten.
The original recommission Catalog remains a separate view. Only the new exact
Catalog runs controlled-retry cases; deleting its two optional fields recovers
the original recommission Catalog digest. Import retention can read the old
recommission input schema but cannot add the new fields to an old request.

Synthetic owner/Provider tests cover success, immutable history, one-use allocation,
expiry/clock rollback, concurrency, restart, another unknown, changed archives,
identity drift and delayed binding publication. They do not constitute hardware
acceptance. The maintainer explicitly authorized the scoped revision-2 policy
change, PR/CI/merge and continued acceptance on 2026-10-18. Required CI and
protected-main publication still precede any device execution.
