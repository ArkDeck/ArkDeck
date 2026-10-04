---
id: CHG-2026-079-diagnostic-session-control
revision: 1
status: proposed
class: capability
core_change_level: none
owner: fuhanfeng
core_baseline: CORE-3.0.0
platforms: [macos]
---

# Bounded interactive Diagnostic Sessions

The macOS Diagnostics workspace can read completed captures but cannot start, mark or stop a recording. Add `capture.diagnostic-session@1`, its bounded Runtime control methods and the App controls in the same implementation PR. Maintainer review and merge into protected main are required before device execution; this file is not approval.

The new operation requires a trace ring and records host-timed annotations while that ring is verifiably active. HiLog is an optional retrospective drain after the trace snapshot: neither continuous log coverage nor clock alignment is asserted. The existing `capture.diagnostics@1` plan and semantics remain unchanged.

## Scope

- A complete materialized plan owns the trace begin, a unique verified anchor, a host wait of at most 120 seconds, dump, finish, receive and cleanup. Stop may only shorten that host wait.
- `diagnostic.session.status`, `.mark` and `.stop` accept exact Job references. Marker count is fixed at admission, at most 200; Runtime supplies wall and monotonic times. Marker IDs make retries idempotent.
- Readiness requires the provider's anchor readback, never a submitted Job or local App state. An absent receipt, restart, identity drift or uncertain outcome stops further dispatch and preserves recovery state.
- Raw output remains immutable. Runtime annotations are durably acknowledged, frozen before finalization and published with the Job's products.
- Typed CLI leaves `diagnostics session status|mark|stop` expose the same exact-Job controls, with bounded marker IDs and labels and no caller timestamps or target overrides.
- App shows preparing, recording, finalizing, result and recovery states; provides explicit start, mark and stop actions; and opens the resulting immutable Session.

## Boundaries

This change does not add device key/text injection, in-session screenshots/input, automatic cross-clock calibration, new device profiles or hardware evidence. Marker screenshots require a separately reviewed in-session admission plan; calibration remains gated on ground-truth measurement. The five real-device Golden Journey acceptances are excluded by the current user request. Ordinary implementation and fixture verification proceed under AGENTS.md; old proposal-first wording in CHG-2026-071 does not require a separate governance PR.
