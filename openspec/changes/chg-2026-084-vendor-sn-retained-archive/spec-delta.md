# Scoped delta for GJ-4

## Factory SN cross-mode evidence

Extend the current Rockchip integration's normal identity producer. When the
canonical kernel CPU serial already matches the bound Loader, retain the existing
single-read path. Otherwise the Runtime may use the fixed DAYU200 eMMC vendor
reader only when all of the following hold:

1. The exact USB Normal identity is a canonical eMMC CID and equals the fixed
   `mmcblk0` CID; the device-tree compatibility identifies the registered board.
2. The boot device-tree serial is sixteen nondefault lowercase hex digits, with
   at most one NUL terminator, and hashes to the already bound Loader identity.
3. Of the four 64 KiB vendor slots at eMMC LBA 7168, exactly one has the highest
   valid version. Tag, matching footer version, header bounds and the item table
   validate. Item IDs and nonempty ranges are unique and do not overlap. Only the
   bounded SN_ID=1 payload is read; it exactly matches the boot serial.
4. Slot headers/footers, selected item metadata, SN payload and boot serial do not
   change across capture. CPU serial, exact Normal attachment and physical USB
   connector do not change. Capture stays within 30 seconds.
5. The Runtime persists and reads back the target/revision/provider-scoped
   observation before transition; the immediate pre-dispatch freshness, tool,
   attachment and subsequent exact Loader/connector checks still apply.

Persist CPU and Loader serial digests under distinct names, together with the
source digests and byte counts. No raw serial, CID, vendor payload or CPU output
enters public receipts. Loader-first postflight and diagnostic callbacks use the
same producer, plus their existing exact model/build and connector checks.
Unknown history, capability lineage and original target snapshots are immutable.

## REQ-JOB-007: terminal archive with retained hazards

Add `archivedWithHazards` to `abandonOutcome.result`, using the existing
`waitingForRecovery -> userAbandonRequested -> interrupted` state path. This
result MUST set `releaseAuthorized: false`. It authorizes terminal bookkeeping
and truthful Session publication only; it never authorizes release or recovery.
The original `archivedInterrupted` path and confirmed quiescence proof remain.

Runtime may select the new path only for a nonresident unknown DAYU200
full-restore with a durable untorn journal, retained materialized identity/binding
and capability lineage, explicit unresolved device hazards, and an expired shared
four-hour recovery budget. Missing/invalid clock facts block the decision. This
increment excludes compensation workflows whose lifecycle is not represented by
the retained Flash projection. A held journal or active Runtime Job blocks.

The existing preview exposes retained hazards and resource-release status. The
commit rechecks its review hash under the journal writer lock and preserves the
original user confirmation on retry. The intent records `outcomeUnknown`, all
hazards and managed process state `unknown`; no process is presumed stopped.
The correlated outcome and terminal transition are durable before publication.
Restart may finish only that audit, with no provider call. A failure keeps all
holds and the durable prefix. Repeated publication is idempotent.
The App review and receipt must retain the Runtime's unknown flag, hazard list
and resource-release status. They must reject a purported success that clears
unknown, drops hazards or authorizes release, including on audit/publication retry.

Archive MUST NOT alter the recovery clock anchor, old step outcomes, outstanding
intents, materialized plan, binding, capability/reservation/use or supersession
records. A missing step outcome appears as `outcomeUnknown`, never skipped or
successful. Session certainty remains unknown, recovery is unavailable, hazards
remain blocking, and resources remain held. Retention, current-job inspection,
target rebinding/adoption census and new Flash admission include terminal unknown
Jobs. A later successful SupersedingRecoveryEpoch remains the only mechanism that
can release covered uncertain intents under POL-AGENT-002.

An archived unknown Session uses an `unresolved` target summary with the original
target ID, materialized identity digest and binding revision. It has no usable
connect route or invented binding history; transport is `unknown`. Its toolchain
is explicitly `unavailable`, with the original provider/profile and a reason.
The original capability audit is retained as historical metadata. This Manifest
branch is valid only for an executed, archived, interrupted, outcome-unknown
Session with blocking hazards and no automatic recovery. It cannot encode success
or provide admission evidence. Original Journal bindings and tool facts, where
present, remain in the retained source history; current observations cannot fill
historical gaps.

## Acceptance cases

- Different CPU and factory SN with all independent sources consistent permits
  cross-mode proof without changing the CPU fact; matching CPU boards are unchanged.
- Wrong/missing/duplicate/malformed vendor metadata or sources, connector/CPU/SN
  drift, truncation, stderr and timeout produce no mode-changing dispatch.
- Expired unknown Flash archives and publishes an unknown interrupted Session;
  original bytes remain a prefix and all protected lineage/budget values remain.
- Active budgets, malformed clocks, held jobs, torn journals, stale review hashes,
  changed confirmations and unrepresented compensations produce no new audit.
- Every append-failure boundary and publication failure is restartable without
  dispatch, duplicate decisions, inferred success or resource release.
- Archived unknowns still block conflicting Flash, target rebinding and new
  Loader adoption; an archive cannot establish supersession or a new budget.
