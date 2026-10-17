# Tasks — CHG-2026-085

## TASK-RAM-001 — Safely restart with a completed retained-risk archive

- Status: in-progress; implementation and local targeted checks complete;
  selected PR CI and maintainer review remain pending.
- Golden Journey: GJ-4 DAYU200 flash and recovery.
- Hardware required: no for implementation; published typed-operation acceptance is separate.
- Decision-Grade: D1 (unknown destructive lineage must remain blocked).
- Scope: shared maintenance predicate, macOS/Windows consumers, focused owner and
  process tests, shared preflight table and this scoped OpenSpec change.
- Exclusions: device admission changes, replay, budget renewal, new capabilities,
  HDC ownership exceptions, historical identity backfill and hardware-pass claims.

- [x] Add fresh durable-archive proof to both platform maintenance preflights.
- [x] Preserve all existing closure checks and compare archive digests after restart.
- [x] Cover incomplete proof, active jobs, retained admission blockers and real process restart.
- [x] Complete local targeted checks and record results.
- [ ] Complete selected PR CI and maintainer review before protected-main publication.
