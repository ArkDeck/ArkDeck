# Tasks — CHG-2026-084

## TASK-VSA-001 — Verify factory serials and archive expired unknown Jobs

- Status: in-progress; implementation and local targeted checks complete;
  selected PR CI and maintainer review remain pending. Real-device acceptance is separate.
- Golden Journey: GJ-4 DAYU200 flash and recovery.
- Hardware required: no for implementation; real acceptance remains separate.
- Decision-Grade: D1 (identity-bound destructive workflow).
- Scope: fixed vendor-SN evidence, existing transition and postflight consumers,
  retained-risk archive and recovery, Session contracts, the existing App archive
  review/receipt, generated strings/pins, focused tests and integration documentation.
- Exclusions: device mutation, historical proof import, capability administration,
  budget reset, baseline ratification and hardware-pass claims.

- [x] Add bounded factory-SN evidence and wire transition, facts and postflight consumers.
- [x] Add retained-risk archive journal/replay, Runtime preview/commit and honest Session publication.
- [x] Preserve unknown and retained hazards through the App review and receipt.
- [x] Cover malformed/drifting identity sources, archive failure/restart and retained admission blockers.
- [x] Run targeted local checks and record actual outcomes in verification.md.
- [ ] Run selected PR CI and complete maintainer review before protected-main publication.

Scope: current HDC/Rockchip and archive/recovery owners, their public contracts,
generated pins, tests, the integration profile and this scoped change. No device
mutation, historical proof import, capability administration, budget reset,
baseline ratification or hardware-pass claim is part of implementation testing.
