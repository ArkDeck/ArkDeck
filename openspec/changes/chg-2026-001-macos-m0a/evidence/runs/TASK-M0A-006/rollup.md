# TASK-M0A-006 M0A evidence rollup

- Evidence class: `evidenceRollup` (documentation review only; no hardware)
- Source revision: `0abbbaa1a6af080a94b7222ba67f4e7a3f325ab0`
- Core baseline: `CORE-1.0.0`
- Platform input: `PLATFORM-MACOS@0.1.0`
- Integration input: `OPENHARMONY-TOOLS@0.1.0`
- Rollup date: 2026-07-15

## Result

Every row in the M0A acceptance matrix is classified below as `passed`,
`failed`, or `blocked`. No row is pending or unclassified in this rollup.

| Status | Count |
| --- | ---: |
| passed | 5 |
| failed | 0 |
| blocked | 8 |
| total | 13 |

These classifications do not rewrite
`openspec/changes/chg-2026-001-macos-m0a/verification.md`; that authoritative
plan is outside TASK-M0A-006's allowed paths. They are the evidence input for
maintainer review and a separately approved status/profile revision.

## Acceptance matrix

| Evidence ID | Rollup status | Evidence class | Evidence and conclusion |
| --- | --- | --- | --- |
| `MAC-M0A-SHELL-001` | passed | local platform build/smoke | TASK-M0A-001 records a signed clean build and clean-user launch smoke. This does not establish distribution trust. |
| `MAC-M0A-PROC-001` | passed | local platform contract tests | TASK-M0A-002 records 16 passing fixtures for shell-free argv, streams, bounded output, timeout, cancellation, process-tree cancellation, discovery, and semantic failure. |
| `MAC-M0A-HDC-001` | blocked | fixture plus incomplete installed-tool observation | The exact DevEco HDC path/hash is recorded, but `hdc version` can mutate host-wide server lifecycle and the app has no real supervised integration. Client/server/daemon versions, endpoint, and trust remain unknown/unverified. |
| `MAC-M0A-HDC-002` | blocked | local fake/contract tests | TASK-M0A-003 passes its declared ownership/lifecycle fixture cases, including fan-out, endpoint isolation, external/unknown no-mutation, critical-job gates, and stale-confirmation rejection. Its run record explicitly leaves the full row pending because conservative subserver/no-call and real integration evidence are outside that task; partial fixtures cannot upgrade the row. |
| `MAC-M0A-RUNTIME-001` | passed | local two-process contract test | TASK-M0A-004 records exactly one kernel-backed writer and zero HDC/Session behavior in the losing fixture. |
| `MAC-M0A-JOURNAL-001` | passed | local fault-injection/contract tests | TASK-M0A-004 records that failed durable intent prevents dispatch, incomplete records enter recovery, and durable outcome precedes checkpoint. |
| `MAC-M0A-POWER-001` | passed | local unit tests plus maintainer host observation | TASK-M0A-004 records terminal-path/ref-count coverage and the maintainer-observed idle-sleep assertion appearing only during the lease. Lid closure and explicit sleep are not claimed. |
| `MAC-M0A-TRUST-001` | blocked | environment inventory | No clean macOS VM or Developer ID identity was available. The required per-cell Developer ID path/version/server/file/key matrix was not run. |
| `MAC-M0A-TRUST-002` | blocked | environment inventory | No quarantined-HDC clean-VM run exists. ArkDeck performed no xattr mutation, but zero mutation alone does not satisfy the required allow/block observation. |
| `MAC-M0A-TRUST-003` | blocked | environment inventory | The bit-identical no-quarantine clean-VM control was not run. |
| `MAC-M0A-TRUST-004` | blocked | environment inventory | The restored-snapshot Safari → Archive Utility propagation/assessment run was not performed. |
| `MAC-M0A-SANDBOX-001` | blocked | ad-hoc platform prototype plus plan-only protocol | TASK-M0A-005A records a launching ad-hoc Sandboxed app and exact entitlements, not end-to-end access. TASK-M0A-007 is blocked because the app has no supervised read-only probe; no human hardware matrix was run, and the non-Sandbox Developer ID column does not exist. |
| `MAC-M0A-DIST-001` | blocked | ADR draft awaiting manual review and selected-artifact evidence | ADR-0001 selects exactly one path and records entitlements, evidence, rejected alternatives, risks, and triggers. The selected non-Sandbox Developer ID/Hardened Runtime/notarized DMG artifact and its signed evidence do not exist, and the required independent maintainer review is pending. |

## Blocked clean-VM trust submatrix

The acceptance-row classification above does not hide inner trust cells. Each
required M0A trust observation is classified here. The locally observed HDC
path/hash is included only as inventory; it cannot turn a clean-VM cell into a
pass.

| Acceptance row | Required observation | Status | Blocker |
| --- | --- | --- | --- |
| `MAC-M0A-TRUST-001` | Developer ID non-Sandbox app identity, Hardened Runtime, and actual entitlements | blocked | No Developer ID identity or selected artifact exists. |
| `MAC-M0A-TRUST-001` | DevEco HDC path/hash/version/signature/trust on the restored VM | blocked | Only a local-host path/hash inventory exists; the clean-VM trust/version observation was not run. |
| `MAC-M0A-TRUST-001` | client/server/daemon versions, endpoint, ownership, and generation | blocked | There is no real supervised app integration; direct `hdc version` may mutate server lifecycle. |
| `MAC-M0A-TRUST-001` | user-selected key input through the exact signed app/HDC pair | blocked | No selected artifact, clean VM, supervised integration, or approved disposable input exists. |
| `MAC-M0A-TRUST-001` | user-selected image input through the exact signed app/HDC pair | blocked | No selected artifact, clean VM, supervised integration, or approved disposable input exists. |
| `MAC-M0A-TRUST-001` | selected output root through the exact signed app/HDC pair | blocked | No selected artifact, clean VM, supervised integration, or approved disposable output exists. |
| `MAC-M0A-TRUST-002` | quarantined HDC system assessment and user/system allow-or-block path | blocked | No restored clean-VM quarantine run occurred. |
| `MAC-M0A-TRUST-003` | bit-identical no-quarantine control | blocked | No restored clean-VM control run occurred. |
| `MAC-M0A-TRUST-004` | Safari download → Archive Utility propagation and assessment | blocked | No VM snapshot/controller was available, so the chain was not run. |

## Blocked prototype × access/transport submatrix

TASK-M0A-007's frozen plan defines six surfaces for each prototype. All twelve
cells are explicit below; none is inferred from a Terminal command or from the
Sandbox app's successful launch.

| Surface | Ad-hoc Sandboxed prototype | Developer ID non-Sandbox prototype |
| --- | --- | --- |
| USB read-only observation | blocked — app has no supervised probe; no human run | blocked — prototype does not exist |
| UART read-only observation | blocked — app has no supervised probe; no human run | blocked — prototype does not exist |
| TCP read-only observation | blocked — app has no supervised probe; no human run | blocked — prototype does not exist |
| Image fixture read-only selection/use | blocked — app has no supervised file/tool probe; no human run | blocked — prototype does not exist |
| Public-key fixture read-only selection/use | blocked — app has no supervised file/tool probe; no human run | blocked — prototype does not exist |
| Output-directory bounded diagnostic write | blocked — app has no supervised output probe; no human run | blocked — prototype does not exist |

## Exact tool and prototype identities

| Item | Identity | Classification |
| --- | --- | --- |
| Installed DevEco HDC | `/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc`; SHA-256 `48395ba8d87115dffca47df2a640a6c868bc9a2bd4eb49611e4138ff88d8d260` | Path/hash only. Version, signature/trust, endpoint, server/daemon, and lifecycle-safe execution are unknown/unverified. |
| TASK-M0A-005A Sandboxed app executable | SHA-256 `f9478493480c715b7610fa4aafd58e280798e6ebdc82d4d10491ddcdafb8242a`; universal `x86_64` + `arm64` | Local ad-hoc Release prototype. Not Developer ID, Hardened Runtime, notarized, Gatekeeper-assessed, or hardware evidence. |
| Selected v1 non-Sandbox app/DMG | no artifact; no hash | Blocked until Developer ID, Hardened Runtime, notarization, clean-VM, and supervised integration prerequisites exist. |

## Sandbox prototype entitlement observation

The actual TASK-M0A-005A Release dump contained exactly:

- `com.apple.security.app-sandbox`;
- `com.apple.security.device.serial`;
- `com.apple.security.device.usb`;
- `com.apple.security.files.bookmarks.app-scope`;
- `com.apple.security.files.user-selected.read-write`; and
- `com.apple.security.network.client`.

`com.apple.security.get-task-allow` was absent. This observed set belongs only
to the rejected-for-v1 ad-hoc Sandbox prototype. ADR-0001 selects a prospective
non-Sandbox release with an empty entitlement set; no selected artifact has
yet demonstrated that set.

## Safety and evidence boundary

- No HDC or device command was executed for TASK-M0A-006.
- No USB/UART/TCP endpoint or real device was accessed.
- No Flash, erase, format, unlock, update, lifecycle, or destructive dispatch
  occurred; destructive dispatch count for this task is `0`.
- No quarantine/xattr, signing identity, system security, or host trust setting
  was changed.
- Fake, plan-only, ad-hoc launch, and documentation evidence are not counted as
  real hardware, Gatekeeper, Developer ID, notarization, or release evidence.

## Review handoff

The maintainer must independently review ADR-0001 and this classification.
Review can accept explicit blockers and the distribution direction, but it
must not convert blocked rows into passes. Platform conformance remains
`notStarted`, and the change is not verified by this rollup.
