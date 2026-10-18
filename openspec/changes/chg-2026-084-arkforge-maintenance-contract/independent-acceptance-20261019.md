# Independent Flash maintenance acceptance — 2026-10-19

This run is incomplete. Neither maintenance operation has a positive hardware
acceptance result. The earlier recommission result does not substitute for either
entry point. Raw Runtime records and device observations remain local.

## Findings and implementation

The published Rust executor implements both maintenance operations, but
`operation.list` and `operation.describe` reported `operation_not_supported` because
the Flash availability matcher omitted their references. The fix recognizes both
references and preserves the existing executor, Job owner, Artifact owner, tool
identity and platform qualification checks. Both maintenance paths still need the
shared mutation owner for admission's history and target-hold checks; verification
then selects its default read-only policy without consuming a capability.

The failing regression was reproduced before the fix. After the fix, all four
availability tests passed, including missing-owner refusals. No Catalog policy or
capability administration changed.

## Published Runtime observations

The existing installed Runtime was verified against protected-main source
`0c36ffe83a9e9147d74a01e609d281326202f70d` and Catalog
`9b184df93d8130d0c7448301844f9afa61137e08f111c77bcaa57261303f319a`.
Both typed `agent.run` maintenance entry points independently refused the recovered
recommission Job as their source, with `admissionDenied`, `phase: preAdmission`
and `newDispatchCount: 0`. The restoration refusal retained its own stopped record.
Neither response is a successful verification or restoration.

The maintenance source contract requires an eligible latest ordinary primary Flash
Job. It intentionally rejects a superseding-recovery execution. The current binding
also differs from the old import's binding. A fresh host-only import of the immutable
original-image bundle succeeded through the published Runtime, and its inspection
succeeded. A read-only `flash.full-restore@1` plan then returned
`jobAdmitted: false`, `dispatchDisposition: notDispatched`, and no Provider blocker.
The plan was not submitted or executed.

Inspecting the old import exposed an additional existing defect: the recovered Job
has no finalized Session because the Manifest publisher rejects `recovered`. The
original Job, journal, capability allocations and unknown histories were preserved.
The fresh import provides the current-binding lease required by this acceptance;
it does not repair or release the retained old import.

## Remaining decision and acceptance scope

The published `flash.restore-boot-loop@1` descriptor explicitly retains
`defaultPolicyIssuance: disabled`. CHG-2026-084's proposal reserves enabling it for a
separate explicit approval decision. A candidate change would enable only this
descriptor's existing Runtime-owned policy. Its typed source/Artifact checks,
one-use exact-plan capability, target exclusion, durable intent, budget, refusal
record and no-replay rules must remain enforced. Such a policy change requires
its scoped OpenSpec update and maintainer PR review before any device execution.

The current source contract means setup needs a new ordinary primary Flash using
the original-image bundle. Its published DAYU200 plan covers `uboot`, `resource`,
`boot_linux`, `ramdisk`, `system`, `vendor`, `updater`, `chip_ckm` and `userdata`;
userdata would be overwritten. The subsequent independent verify entry is read-only.
The restore entry writes only the original ramdisk and independently hashes its
complete 4 MiB range; it does not write userdata or perform complete-overwrite
recovery. This setup has not been executed under an old recommission allocation.

## Local targeted checks

- Availability regression: baseline exit 101, fixed exit 0; four tests passed.
  The final regression retains the actual shared admission owner's requirement.
  Logs: `D:/src/ArkDeck-wt/tools/flash-maintenance-checks-20261018/owners-final/discovery-red.log`
  and `test-arkdeck-hoststore.log` in that same directory.
- `run-cargo.py clippy -p <crate> --all-targets -- -D warnings` for hoststore,
  agentd and soak: exit 0. Logs under
  `D:/src/ArkDeck-wt/tools/flash-maintenance-checks-20261018/owners-final/clippy-<crate>.log`.
- `run-cargo.py test -p arkdeck-hoststore --lib`: exit 0, 426 passed, five existing
  ignored. `run-cargo.py test -p arkdeck-agentd --lib`: exit 0, three passed.
  `run-cargo.py test -p arkdeck-soak`: exit 0, five passed and one existing signer
  dependent test ignored. Corresponding `test-<crate>.log` files are in the same
  local checks directory.
- Test routing Python suite: exit 0, 35 passed, after placing its temporary files
  inside the writable workspace. The first sandbox temporary-directory attempt
  failed with permission errors; no assertion was changed.
- `run-cargo.py fmt --all --check`: exit 1, Windows process argument limit (OS 206).
  Direct `rustfmt --edition 2024 --check` on the changed Rust source: exit 0.
  The existing batched Windows formatter then checked all workspace targets:
  exit 0. Logs: `fmt-all.log`, `fmt-operation-availability.log` and
  `fmt-workspace-batched.log` in the checks directory.
- `sh scripts/check-sdd.sh`: exit 0; local log `sdd.log` in the checks directory.
  Swift and App builds are not run locally for this Rust-only implementation fix.
  The complete CI selection remains the PR's responsibility.

## CI

Pending the discovery fix PR's current-head `guard` and `swift` checks. Required
protected-main contexts were read back as both `guard` and `swift`. CI success
will not establish either operation's hardware acceptance or approve a policy change.
