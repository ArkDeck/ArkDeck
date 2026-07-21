# macOS M0A Design

> Status：draft  
> Proposal：CHG-2026-001-macos-m0a@r1  
> Core baseline：CORE-1.0.0

## Components

```text
SwiftUI shell
  → App composition
  → ArkDeckCore protocols
  → ArkDeckProcess prototype
  → ArkDeckRuntime prototype
  → ArkDeckOpenHarmony HDC discovery/supervisor probe
  → temporary Session/journal evidence
```

No feature workflow may bypass the Core protocols. Prototype UI only exposes diagnostics and non-destructive test actions.

Host/clean-VM prototype construction and the real USB/UART/TCP matrix are separate Tasks. An Agent may build the prototypes and the canonical read-only plan, but only `TASK-M0A-007` may produce hardware evidence, executed by the human maintainer against the frozen plan with operator/device identity recorded in evidence. It is read-only: device mutation, destructive mutation and host elevation are excluded.

## Requirement mapping

| Requirement/Port | Prototype evidence |
| --- | --- |
| PORT-PROCESS-001、REQ-JOB-005、REQ-NFR-002；AC-JOB-005-01、AC-NFR-002-01 | argv/no-shell, stdout/stderr, timeout/cancel and bounded streaming fixtures |
| REQ-JOB-008、AC-JOB-008-01 / SingleInstanceGuard | two-process contention and zero side effects in second instance |
| REQ-HDC-001、REQ-HDC-002、REQ-HDC-003、REQ-HDC-004、REQ-HDC-009、REQ-HDC-010；AC-HDC-001-01、AC-HDC-001-02、AC-HDC-002-01、AC-HDC-003-01、AC-HDC-003-02、AC-HDC-004-01、AC-HDC-009-01、AC-HDC-010-01、AC-HDC-010-02、AC-HDC-010-03 | discovery, complete toolchain diagnostics, semantic compatibility, endpoint isolation, subserver no-call, ownership, host-wide impact preview and lifecycle counters（AC-HDC-005-01 parserGolden 已移出本 change 范围；fixture 由本 change 产出、后续 change 认领） |
| REQ-JOB-002、AC-JOB-002-01 | durable intent/checkpoint failure prototype |
| PORT-POWER-001 | acquire/release on success/failure/cancel/throw |
| PORT-FILE-ACCESS-001、REQ-HDC-006、AC-HDC-006-01 | external tool/image/key/output and denied-key access end-to-end in both prototypes |
| PORT-TOOL-TRUST-001 | signed/unsigned/quarantined/blocked matrix |
| POL-AGENT-002、PORT-DEVICE-ACCESS-001、MAC-M0A-SANDBOX-001 | separately authorized read-only lab run; owner/plan/target-bound evidence; destructive dispatch count 0 |

## Distribution experiment

Build the same minimal capability surface as:

1. Sandboxed prototype with only candidate entitlements justified by the test matrix；
2. Developer ID direct-distribution prototype with Hardened Runtime and no unnecessary exceptions。

Restore VM snapshots between Gatekeeper scenarios. Do not manufacture a clean control by having ArkDeck remove quarantine.

## Decision record output

The final record chooses Sandbox or non-Sandbox for v1, lists rejected alternatives, actual signed entitlements, evidence, remaining risks and revalidation triggers. It cannot alter Core behavior.
