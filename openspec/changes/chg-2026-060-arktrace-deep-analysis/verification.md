# Verification Plan

> Change:CHG-2026-060-arktrace-deep-analysis@r1
> Status: in-progress; implementation and evidence share this vertical PR.

| AC | Method | Pass condition |
|---|---|---|
| ATD-AC-1 | Catalog generator + blob lock | new operation present; summary blob unchanged |
| ATD-AC-2 | submit/plan-only negative matrix | invalid typed inputs rejected before Job/spawn |
| ATD-AC-3 | exact process-plan goldens | context/analyze argv fixed; one source token |
| ATD-AC-4 | profile/drift matrix | both refs resolve exact same reviewed generation or unavailable |
| ATD-AC-5 | envelope fixtures + mutations | only exact matching context/analyze JSON succeeds |
| ATD-AC-6 | publish/restart byte comparison | exact bytes/hash and complete path-free lineage survive |
| ATD-AC-7 | cancel/timeout/fault injection | no partial publication or blind redispatch |
| ATD-AC-8 | existing analyzer/full suite | summary/crash/hilog compatibility remains green |

## Negative matrix

- unknown kind, mixed/missing timestamp/range, degenerate/overflow range;
- processKey+pid, threadKey+tid, stable key zero, limit above global budgets;
- wrong command/kind/time/filter/limits/trace/tool/parser/provenance;
- extra/missing/duplicate JSON key, fractional integer token, malformed/truncated/oversized bytes;
- result section count/budget mismatch and embedded physical path;
- source replacement, profile/resource drift, cancel before spawn/in flight/before publication;
- restart at WAL/outcome/Artifact commit windows with zero blind redispatch.

## Evidence classes

- Contract/fault-injection: deterministic Swift tests.
- Platform: real Developer ID/notarized ArkTrace distribution loaded through the daemon-private
  generation and used for context/analyze smoke.
- Real Artifact: deferred to ArkTrace P5-T09/Gate 9; it is not claimed by synthetic leases.

## Result gate

- [ ] Maintainer reviewed/merged operation + implementation in one PR.
- [x] ATD-AC-1..8 pass in the candidate implementation and reviewable evidence.
- [x] Signed profile replay passes through the production daemon-private generation.
- [x] Summary descriptor and existing analyzer behavior remain unchanged.
- [x] Large Trace and real capture Artifact are explicitly deferred rather than falsely claimed.
