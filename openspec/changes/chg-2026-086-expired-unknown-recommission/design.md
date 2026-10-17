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

The Provider receives the proved Loader SN while Runtime history remains anchored
to the original CID and revision. Managed transition controls carry the consumed
identity/budget pins, require a fresh Normal observation and reject the
already-Loader shortcut. The existing exact Loader readback and connector proof
still gate the first partition write. Postflight repeats the whole hardware
chain and cannot publish an early alias.

## Independent allocation and completion

The private allocation ledger serializes reservation and consumption. It records
one allocation per original Normal identity, pinning the unchanged source record,
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

Synthetic owner/Provider tests cover success, immutable history, one-use allocation,
expiry/clock rollback, concurrency, restart, another unknown, changed archives,
identity drift and delayed binding publication. They do not constitute hardware
acceptance. The proposed Constitution delta and implementation require maintainer
review and protected-main publication before this board is exercised.
