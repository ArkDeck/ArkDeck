# Spec Impact

> Change：CHG-2026-002-macos-m1-infrastructure@r1  
> Core baseline：CORE-1.0.0（ratification 状态见 `openspec/baselines/CORE-1.0.0.yaml`）
> Exact affected scope：`scope.yaml`

This shared-infrastructure implementation change does not add, modify, remove, or rename any Core/capability Requirement, Acceptance Scenario, or contract. It implements a host-verifiable subset of the existing baseline.

`scope.yaml` is the single exact Requirement/AC/Policy/Port set affected by this change and is hash-locked with this document. This file intentionally does not duplicate that list; a second hand-maintained list could drift.

Deliberately excluded from this change (later changes must cover them before any release includes their capability): `AC-DEV-007-01` (parserGolden capability probing), all realHardware acceptance, and the `REQ-UX-*`/`REQ-I18N-001` user-interface subset of desktop-ux-observability.

If implementation discovers that any Requirement/AC/contract must change, this change stops and a separate `arkdeck-behavior` proposal is required.
