# Tasks — CHG-2026-082

## TASK-NLP-001 — Persist and enforce pretransition hardware identity

- Status: in-progress; approval remains with the maintainer PR.
- Golden Journey: GJ-4 DAYU200 flash and recovery.
- Hardware required: no for implementation; real acceptance remains separate.
- Decision-Grade: D1 (stricter destructive admission).
- Scope: fixed bounded Normal hardware read, private durable observation, planning
  and transition guards, prerequisite readiness, relevant tests and integration docs.
- Allowed paths: rust/**, openspec/integrations/rockchip/profile.md,
  openspec/changes/chg-2026-082-normal-loader-hardware-proof/**.
- Exclusions: unknown replay, historical record rewriting, target rebinding,
  capability/coverage administration, raw device mutation and hardware evidence.

Deliver the tested implementation through protected-main publication before any
device use. Independently assess the current board's safe recovery proof without
claiming that this preventive change repairs its missing historical observation.
