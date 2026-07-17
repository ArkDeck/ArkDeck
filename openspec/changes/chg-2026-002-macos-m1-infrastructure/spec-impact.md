# Spec Impact

> Change：CHG-2026-002-macos-m1-infrastructure@r3
> Core baseline：CORE-2.0.0（ratification 状态见 `openspec/baselines/CORE-2.0.0.yaml`）
> Exact affected scope：`scope.yaml`

This shared-infrastructure implementation change does not add, modify, remove, or rename any Core/capability Requirement, Acceptance Scenario, or contract. It implements a host-verifiable subset of the existing baseline.

`scope.yaml` is the single exact Requirement/AC/Policy/Port set affected by this change and is hash-locked with this document. This file intentionally does not duplicate that list; a second hand-maintained list could drift.

Deliberately excluded from this change (later changes must cover them before any release includes
their capability): `AC-DEV-007-01` (parserGolden capability probing), all realHardware acceptance,
the `REQ-UX-*`/`REQ-I18N-001` user-interface subset of desktop-ux-observability, and all
UI Dump/Trace/Debug/Flash product UI.

The minimal macOS HDC diagnostics/safety surface is not part of that exclusion: it exists only to
close the user-visible results already required by the in-scope `AC-HDC-001-02`,
`AC-HDC-003-01`, `AC-HDC-006-01`, `AC-HDC-007-02`, `AC-HDC-008-01`,
`AC-HDC-009-01`, `AC-HDC-010-01` and the REQ-HDC-010 lifecycle preview. It does not claim
general navigation, History, feature UI, or i18n acceptance.

If implementation discovers that any Requirement/AC/contract must change, this change stops and a separate `arkdeck-behavior` proposal is required.
