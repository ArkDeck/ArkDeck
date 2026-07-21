# TASK-M1-009 implementation run

## Run identity

- Task: `TASK-M1-009`
- Change: `CHG-2026-002-macos-m1-infrastructure`
- Base revision: `cb72964b067466f070df47b0bcbf1a874740a3e4`
- Branch: `agent/TASK-M1-009`
- Run time: `2026-07-18T02:16:51Z` (`2026-07-18T10:16:51+0800`, Asia/Shanghai)
- Evidence class: `contract` + `macOS platform`
- Environment: macOS `26.5.2` (`25F84`), arm64, APFS; Swift `6.3.3`
- Hardware/network classification: local generated fixtures only; no real HDC, device, external
  network, destructive/device dispatch, upload, or hardware evidence.

## Locked/readiness inputs

| Input | SHA-256 |
| --- | --- |
| `openspec/constitution.md` | `38c8e1613f251706ebb74019840bbf42a82b11720dd4efc44966ec451c793418` |
| `openspec/specs/desktop-ux-observability/spec.md` | `5942039c0512cf04e030b21a6e64175eaa8a89a984dc4f6e62ce767bc263d426` |
| `openspec/architecture/platform-ports.md` | `47752d0cc767867762ef1bc2f65d4aafbd20e81a5622e43320509ffac27a9962` |
| `openspec/platforms/macos/profile.md` | `54bd9b295799cb8d93bf397eeb585f24828463f4f1fce1e59a0693f65369d0bf` |
| `openspec/platforms/macos/verification.md` | `0e3de8749ec5e974ed96ceed1760ee7e049a92eecb052c2cfb47658390ca7072` |
| `openspec/verification/acceptance-cases.yaml` | `a8b4e9c0e9fd0bdeb369db18261a8be31324151a68fa710a30e29183b50a476d` |
| `openspec/verification/core-conformance.yaml` | `293cc22936c1079d434c52e23572b6f575c71715d98d32018cde4ecf0deba839` |
| change `proposal.md` | `fd44eb9eb90da950eecd2db3ab79a191c8c9f3ca38222db0d57cdcf045bee099` |
| change `tasks.md` (pre-run) | `00d3498657a2e24b06c3634d6bf7116b11f87e648a67d8f3dc0c6fd780db9183` |
| change `verification.md` | `c9346c913ef1f91d950f9f9f0dd36097c6b1674cdc1965d5fd638000c0dc5186` |
| change `scope.yaml` | `ad60766a364a8e0682802924b080e1a7ea06b0f1d2e2a62231f2f267386fa7b5` |
| M1-005 `RetentionAndExport.swift` | `a620eb3224660a2ec047b8cf32c591379ebe77beff66990bb341beac652b8e9b` |

## Implementation and measured results

- Added the macOS `SystemLogger` port with the canonical `app`, `hdcServer`, `workflow`,
  `storage`, and `ui` categories, correlation IDs, write-time typed privacy classification, and
  dual sinks: Unified Logging plus durable structured JSONL.
- Added an owner-only, single-writer structured log store. It uses bounded records, 1 MiB default
  segments, a 16 MiB default quota, segment rotation/oldest cleanup, descriptor/path binding,
  durable append, and reopen-time torn-tail truncation. The fault vector wrote 200 records under a
  4,096-byte quota and retained 3,212 bytes in 2 complete segments; an injected
  `torn-sensitive-tail` was removed on reopen.
- The redaction vector sent all five categories through both sinks. Synthetic input values were:
  device ID `fixture-device-serial-009`, user path
  `/Users/fixture/Secret Workspace/capture.trace`, and business string
  `customer-visible secret payload`. Both sinks contained only
  `[REDACTED-DEVICE-ID]`, `[REDACTED-USER-PATH]`, and
  `[REDACTED-BUSINESS-STRING]`; byte searches found none of the three inputs. All five distinct
  correlation IDs and categories remained present.
- Added a bounded local diagnostic bundle exporter with a no-write preview, destination-bound
  scope SHA-256, and explicit `userInitiated` trigger gate. `appCrash` and `jobFailure` attempts
  both returned `explicitUserInitiationRequired` with no destination created. The successful
  explicit export writes owner-only local files and records `automaticUploadEnabled:false`.
- Recent Session input is a materialized M1-005 `SessionDiagnosticExporter` result. The exporter
  requires its `.redact` policy and rejects any exported manifest retaining `raw`/`partial`
  Artifact roles. It copies only structural manifest/journal summaries; Artifact bytes and journal
  payload strings are not copied. The platform vector's M1-005 source excluded 1 raw Artifact.
- Platform vector used an 8,192-byte log quota and retained 1,403 bytes. The final bundle contained
  exactly these 10 paths/entries (including directories):
  `bundle.json`, `hdc/`, `hdc/tool-placeholder.json`, `logs/`,
  `logs/diagnostics-00000000000000000000.jsonl`, `metadata.json`, `sessions/`,
  `sessions/recent-0000/`, `sessions/recent-0000/journal-summary.json`, and
  `sessions/recent-0000/manifest-summary.json`. No `.trace`, `artifacts/raw`, synthetic raw bytes,
  journal payload `device-1`, or the three sensitive fixture inputs appeared.
- Static source scan found no `URLSession`, Network framework/NWConnection, external Process,
  shell, real HDC execution, connectKey, device mutation, or destructive dispatch path. The only
  HDC references are the canonical `hdcServer` category and an unknown/unverified local placeholder.
- Cross-deliverable disclosure: none. M1-005 source files and public behavior were not modified;
  TASK-M1-009 added one new `ArkDeckStorage` composition file that consumes the existing
  `MaterializedSessionExport` result.

## Commands

| Command | Result |
| --- | --- |
| `swift build --package-path Packages/ArkDeckKit --build-tests` | passed |
| `swift format lint <four TASK-M1-009 Swift files>` | passed, 0 diagnostics |
| `swift test --package-path Packages/ArkDeckKit --filter DiagnosticsContractTests` | 4 tests, 0 failures |
| `swift test --package-path Packages/ArkDeckKit` | 173 tests, 0 failures, 1 pre-existing opt-in manual sleep/wake skip |
| `scripts/check-sdd.sh` | 0 errors, 0 warnings, 111 acceptance IDs |
| `git diff --check` | passed |
| static no-network/process/device scan of the two production files | passed; only category/placeholder references described above |

## Acceptance conclusions

| Test ID | Evidence | Conclusion |
| --- | --- | --- |
| `TEST-AC-DIAG-001-01` | quota/rotation/cleanup and torn-tail reopen vector | PASS (`platform`) |
| `TEST-AC-DIAG-001-02` | five-category, correlation, two-sink byte-level redaction vector | PASS (`platform`) |
| `TEST-AC-DIAG-002-01` | crash/job-failure zero-export and previewed user-trigger vector | PASS (`platform`) |
| `TEST-MAC-M1-DIAG-001` | production Unified Logging invocation + bounded store + M1-005-derived bundle/raw exclusion | PASS (`platform`) |

## Deviations and residual risk

- No scope, Requirement, AC, locked contract/schema, baseline, platform/integration profile,
  conformance, or release status changed.
- Unified Logging delivery/retention remains controlled by macOS; the platform test executes the
  production sink and proves ArkDeck's category/redaction input boundary, not persistence policy of
  the OS log database.
- HDC/tool/server values remain explicit `unknown`/`unverified` placeholders until TASK-M1-006;
  this run makes no HDC capability claim.
- The evidence is local host/platform evidence only. It is not real-hardware evidence, complete
  macOS conformance, a release claim, or change-level verification.

## Post-rebase verification addendum (2026-07-18, pre-PR)

Appended after the four remediation rounds; the original text above is unchanged.
The branch was rebased onto main `6c92aa5` (CHG-2026-003 archive; includes the
I5-001 golden fixture registration merged after this run's original base). All
verification was re-executed on the rebased tree by an independent review session:
dedicated `DiagnosticsContractTests` 16 tests / 0 failures; full suite 188 tests /
0 failures (1 pre-existing opt-in manual sleep/wake skip; +3 tests are I5-001's
`HDCGoldenResourceContractTests` from main); `swift format lint --strict` on the
four TASK-M1-009 files 0 diagnostics; `scripts/check-sdd.sh` 0 errors / 0 warnings /
111 acceptance IDs; `git diff --check` clean; static no-network/no-process scan of
both production files clean. `tasks.md` remains `Status:ready`; `ready→done` is
reserved for a separate status PR after maintainer review.
