# Proposed scoped delta — CHG-2026-086

## POL-AGENT-002: independently bounded recommissioning

The original invocation's four-hour and sixteen-epoch limits SHALL remain
immutable. After that invocation expires, `flash.recommission@1` MAY obtain one
independent Runtime-owned allocation only for one completed, published
retained-risk archive with an unknown destructive Flash on a DAYU200 revision-1
Normal-only binding. It SHALL NOT replay an old intent or manufacture its outcome.
Ordinary `flash.full-restore@1` and its alias SHALL retain their existing limits.

The allocation SHALL be durably keyed by the retained source and its identity,
pin the complete source record/journal digest, new Job/request/plan/Artifact,
coverage and fresh identity chain, and allow one epoch, concurrency one and at
most 1,800 seconds from reservation. Reservation is irreversible. Restart,
duplicate/new request IDs, cancellation, abandonment, failed verification or a
new unknown alone SHALL NOT allocate another budget. No new Provider step permit SHALL
be issued after expiry. An already dispatched critical step may settle honestly.

Revision 2 permits exactly one controlled retry after this first allocation is
consumed, expired and represented by a durable unknown recommission Job. The
request SHALL explicitly name that Job in `failedRecommissionJobId` and supply
`restorationArtifactLease`; these are references, never authority or proof.
Runtime SHALL bind the archived source, the failed Job and the first allocation,
prove both historical Provider executions terminal and their writers ended, and
cover all uncertain effects from both Jobs. It SHALL pin both unchanged history
digests, the first allocation digest, the complete fresh identity chain and the
whole retry program before reserving another one-epoch, concurrency-one,
1,800-second allocation. Every field of the first allocation SHALL remain
unchanged. No third allocation is permitted for the original Normal identity.

The retry program SHALL materialize both Provider plans before reservation:
the full nine-partition overwrite with the pinned preboot ramdisk, and restoration
of the pinned original ramdisk over the entire 4 MiB range. Both immutable
bundles SHALL contain identical non-ramdisk images. Runtime SHALL independently
measure every complete primary range, reading userdata's nonce-bound RAM report
from its pre-mount measurement and reading the eight static ranges through the
bounded Normal Provider. It SHALL then restore the original ramdisk, verify its
complete 4 MiB range, reboot and repeat the complete identity chain within the
same allocation. Restoration SHALL NOT allocate another capability or epoch.

The original Provider typed-skip receipts SHALL remain unchanged. A skip is not
readback evidence; only the separate complete measurements, exact sealed plans,
all successful write receipts and both canonical postflights can establish the
retry's completion proof. Every subphase SHALL be durable and bound to the same
program and allocation. Missing, short, mismatched, stale or substituted proof
SHALL retain unknown and prohibit replay, including after a Runtime restart.

## Identity, coverage and publication

Runtime SHALL prove the old binding's exact Normal CID, fresh non-default CPU
serial, independent boot-tree/current vendor-slot SN agreement, and stable USB
connector across repeated bounded reads. Before the first partition write the
actual Loader SHALL match that SN and connector through the Provider's existing
dual-source observation. Caller-supplied proofs, topology alone and user consent
SHALL NOT substitute for this chain. A different CPU, CID, SN, connector, ambiguous
slot, malformed record, active old process, additional unresolved Job/effect or
unverifiable archive SHALL result in zero new destructive dispatch.

The first production implementation admits this path on Windows only: the
source Runtime writer has ended, its HDC clients were contained in kernel
kill-on-close Job Objects, and a fresh Provider census must include the exact
historical daemon Job as terminal with no live Job. An empty or unrelated
Provider census is not proof. macOS remains blocked with
`recommission.legacyHostProcessLifetimeUnproven` because its legacy process
groups do not prove child termination after Runtime death. This is an
unavailable operation, not an exception to the quiescence requirement.

The operation SHALL overwrite the complete published nine-partition DAYU200 map,
use full per-item semantic verification, reboot and postflight. Postflight SHALL
prove the same CPU/CID/SN/connector chain as admission. Only then MAY Runtime append
a SupersedingRecoveryEpoch and a new binding-lineage record. Original records,
unknown outcomes, budget bytes and binding snapshot SHALL remain unchanged.
Crashes before complete proof SHALL retain blockers; crashes during publication
SHALL be reconciled from durable proof without device replay or a new allocation.

## Acceptance scenarios

- A valid expired retained archive and complete fresh chain can obtain exactly
  one independent allocation; complete write/readback/reboot/postflight publishes
  supersession and a usable binding while the historical bytes stay unchanged.
- Ordinary recovery remains rejected after the original four-hour deadline.
- Missing/unpublished/tampered archive, incomplete coverage, extra uncertain
  effects, live/unknown provider activity, or any identity drift refuses before
  capability consumption or device mutation.
- Duplicate requests are idempotent. New IDs, process restarts, expiry, failed
  postflight and a new unknown cannot implicitly obtain a second allocation.
- Only an explicit eligible controlled retry can obtain the second allocation.
  Its success covers both unknown histories while preserving the first ledger
  entry and source bytes. Failure, expiry, cancellation and restart cannot obtain
  a third allocation.
- A missing preboot report, incorrect range/hash, changed identity, incomplete
  write receipt, unknown restoration or missing restoration readback leaves the
  second Job unknown, with no supersession or binding upgrade.
- Every crash window retains either the old blockers or a mechanically verified
  durable supersession, with zero replay and no manufactured hardware evidence.

Verification uses focused owner/Provider tests and selected PR CI. Real-device
acceptance runs only after maintainer approval and protected-main publication.
