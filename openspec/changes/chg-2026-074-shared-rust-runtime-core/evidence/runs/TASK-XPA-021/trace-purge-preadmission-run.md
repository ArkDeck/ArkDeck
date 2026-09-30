# TASK-XPA-021: Trace cache purge refused before admission without its retention owners. Local run, 2026-09-30

**Ruling 18 shape, maintainer-delegated 2026-09-30.** The lead approved this
on the maintainer's delegation: `trace.cache.purge` without the Job owner
becomes an `operationUnavailable` refusal before admission with
`newDispatchCount` 0. It applies to macOS and Windows alike, in the shape #2350
gave `target.adopt` without a registered HDC. Ruling 18's text is not yet in
`evidence/windows-maintainer-rulings-20260930.md` on `origin/main` `65c4ba33`.

Checkout: branch `agent/xpa-021-trace-purge-preadmission-20260930` on
`origin/main` `65c4ba33`. Host: Windows 11 Pro 10.0.26200 x64, non-elevated.
This is a host-only software change. No device, `hdc` or ArkTrace was
involved.

## Why

A daemon that composes the Trace cache owner but not the Job and Artifact
retention owners used to answer `trace.cache.purge` with `rejected` and no
details. The published CLI failure mapping reads an unproven refusal of a
mutation-capable method as `outcomeUnknown` (exit 75), so the CLI reported an
unknown outcome for a purge that had done nothing. On Windows the daemon
composes the cache owner in a development root but no Job owner (#2367). On
macOS the same answer comes from any composition without those owners.

## What changed

- `arkdeck_hoststore::TraceCacheStore::purge_unavailable()` returns:
  - code `operationUnavailable`;
  - message "Trace cache purge needs the Job and Artifact retention owners;
    nothing was purged";
  - details `{"phase": "preAdmission", "newDispatchCount": 0, "purgeScope":
    "inactiveDerivedDatabases"}`.

  The details are the purge's published error details (all three required
  members), with the pre-admission proof the CLI reads.
- `Host::trace_cache_purge` (macOS) answers it when the Job owner or the
  Artifact owner is missing. A daemon without the Trace cache owner itself keeps
  `rejected` "Trace cache owner is not configured", which is the same answer
  `trace.cache.status` gives. That keeps #2360's Windows offline test and the
  Control default unchanged. The Windows form of the purge lands with #2367,
  which will use the same function once it merges `main`.
- The published contract of `trace.cache.purge` now admits
  `operationUnavailable`. It was produced by the repository generators, not by
  hand:
  1. `Packages/ArkDeckKit/Scripts/generate-control-contract.py` gains
     `TRACE_CACHE_PURGE_OWNER_ERROR_CODES = ["operationUnavailable"]`, joined to
     the method's codes as the other owner vocabularies are.
  2. `--derive-method-schemas` was run over the method's committed corpus
     (`Fixtures/ControlFrames/trace.cache.purge.jsonl`, 4 frames, and nothing
     else). It rewrote `spec/control/methods/trace.cache.purge.json` and the
     same corpus file.
  3. `rust/scripts/generate-contract.py --write` refreshed
     `spec/baselines/swift-single-v1.json`. `--check` passes afterwards.

  Derived with the owner code and then without it, the schema differs only in
  `errorCode.enum` gaining `operationUnavailable`. Deriving from the committed
  corpus (the Swift daemon that recorded the full frame logs has been removed)
  also moves `x-arkdeck-sampleCounts` from 6/8/2 to 3/4/1. That is the
  generator's count of the frames it was given; no shape changes.
  Deriving every method from the whole committed corpus would drift 116
  schemas the same way, so only this method was derived. The generator writes
  CRLF on Windows. The written files were normalised to LF, and the two files
  whose only change was line endings (`ControlProtocolGenerated.swift` and the
  corpus `.jsonl`) were restored.
- CLI: no code change. `wire_code` already reads `operationUnavailable` with
  `phase: preAdmission` and `newDispatchCount: 0` as the named refusal
  `operationUnavailable` (exit 69).

## Tests

- `arkdeck-cli` `tests/client_failure_mapping.rs`
  `a_trace_cache_purge_refused_before_admission_is_a_refusal` (runs on
  Windows):
  - the published contract admits the code and the details;
  - the CLI maps the refusal to `operationUnavailable` with exit 69, and keeps
    the Runtime's details plus `method`/`wireCode`;
  - the earlier detail-less `rejected` still maps to `outcomeUnknown`.
- `arkdeck-agentd` `host_tests.rs`
  `a_trace_cache_purge_without_its_retention_owners_is_refused_before_admission`
  (macOS only):
  - a Host with only the Trace cache owner, through the real `Control` and
    `decode_response` (schema-validated), answers exactly `purge_unavailable()`;
  - the cache directory is untouched.

  Not run here; CI's macOS lane runs it.

## Local targeted checks (Windows 11 x64)

| Command | Result |
| --- | --- |
| `cargo fmt --all --check` | pass |
| `cargo clippy --workspace --all-targets -- -D warnings` | exit 0 |
| `cargo test -p arkdeck-contract -p arkdeck-control -p arkdeck-cli -p arkdeck-hoststore -p arkdeck-agentd` | exit 0 |
| `python rust/scripts/generate-contract.py --check` | pass |
| `PYTHONUTF8=1 sh scripts/check-sdd.sh` | 0 errors, 0 warnings |
| `git diff --check` | clean |
| `python rust/scripts/check-contracts.py` (optional, not required for this diff) | failed in its **published** view: `cargo test --workspace --locked` of unmodified `origin/main` `65c4ba33` on this Windows host exited 101 before the candidate view ran. That view is the baseline, not this change; the dual check is left to CI |

macOS and Linux were not built here. The changed macOS code is
`Host::trace_cache_purge` and a macOS-gated test. `trace_owner` stays
macOS-only on `main`, so Windows and Linux build what they built before. CI
decides.

## CI

To be recorded, not verified.
