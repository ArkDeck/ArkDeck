# Tasks — CHG-2026-083

## TASK-LFF-001 — Adopt and verify a board first attached in Loader

- Status: in-progress; implementation and local checks complete; selected PR CI and maintainer
  review remain pending. Real-device acceptance remains separate.
- Golden Journey: GJ-4 DAYU200 flash and recovery.
- Hardware required: no for implementation; real acceptance remains separate.
- Decision-Grade: D1 (identity-bound destructive workflow).
- Scope: initial Loader adoption, hardware-bound postflight, CLI/control extension,
  immutable proof records, focused failure-path tests and integration documentation.
- Allowed paths: rust/**, openspec/contracts/**, spec/control/methods/**,
  Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/**,
  openspec/integrations/rockchip/profile.md, openspec/changes/chg-2026-083-loader-first-flash/**.
- Exclusions: unknown replay, historical record rewriting, capability or coverage
  administration, raw device mutation and hardware evidence.

Validate changed crates and their direct consumers; the PR runs selected CI lanes.
Real execution follows only from the published protected-main Runtime with fresh
admission and recovery proof. A blocked historical Normal-only unknown stays blocked.
