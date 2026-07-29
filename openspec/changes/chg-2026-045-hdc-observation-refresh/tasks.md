# Tasks

## TASK-HOR-001 — Add and verify the explicit in-session HDC refresh route

- Status:blocked
- Platform:macos
- Requirements:compatible implementation of `REQ-UX-002`, `REQ-HDC-002`,
  `REQ-HDC-003`, `REQ-HDC-004` and `REQ-I18N-001`
- Acceptance:`HOR-UI-001`, `HOR-SESSION-001`, `HOR-BOUNDED-001`,
  `HOR-SAFETY-001`
- Depends on:proposal and subsequent approval-only PR merged; independent D1
  readiness merged (all currently unsatisfied)
- Readiness input pins:pending. The proposal base and source blobs are
  reference context only; the fresh readiness PR must replace this sentence
  with a complete `yaml pins` block from then-current protected main.
- Applicable failure patterns:`AF-001` (complete App/fixture/test/localization
  consumer surface), `AF-002` (visible production root through the real
  provider), `AF-004` (signed UI producer-to-consumer path plus session
  contract), `AF-005` (fixture/platform evidence is not hardware evidence),
  `AF-006` (fresh revision/status/source pins), `AF-008` (duplicate action,
  session replacement and forbidden-effect matrix), `AF-010` (callback and
  in-flight mutations must turn tests red), `AF-013` (reuse the exact
  registered source rather than copying a nearby refresh design), `AF-016`
  (first-hand protected-main and CI audit), `AF-018` (open-PR/shared-source
  overlap review)
- Production reachability:
  `ArkDeckApp` composition
  → `HDCStatusView` explicit refresh action
  → App-owned `HDCStatusViewModel.refresh`
  → existing `HDCApplicationDiagnosticsProviding.refresh`
  → retained `HDCDeviceObservationApplicationSession.refresh`
  → exact registered 3.2.0f source
  → at most one read-only `list targets -v`
  → same bounded presentation buffer
- Trusted fact sources:selected candidate and endpoint are produced by the
  existing Workflows production discovery/session composition; executable
  bytes and process/listener identity are checked by existing verifiers and
  the system observer; registry authority remains protected-main data. The
  App callback and UI fixture cannot supply candidate/session/receipt/runner
  facts.
- Allowed paths after readiness:
  - `ArkDeckApp/App/ArkDeckApp.swift`
  - `ArkDeckApp/Features/HDC/HDCStatusView.swift`
  - `ArkDeckApp/Resources/Localizable.xcstrings`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/HDCApplicationDiagnosticsFacade.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/HDCDeviceObservationPresentationContractTests.swift`
  - `ArkDeckAppUITests/HDC/HDCStatusUITests.swift`
  - `openspec/changes/chg-2026-045-hdc-observation-refresh/evidence/**`
  - this change `tasks.md` (only this task status/evidence references)
- Forbidden paths:
  - `openspec/constitution.md`, `openspec/specs/**`,
    `openspec/contracts/**`, `openspec/baselines/**`
  - `openspec/integrations/**`, `openspec/platforms/**`,
    `openspec/verification/**`
  - `Packages/ArkDeckKit/Sources/ArkDeckOpenHarmony/**`
  - `Packages/ArkDeckKit/Sources/ArkDeckCore/**`
  - `ArkDeck.xcodeproj/**`, `.github/**`, `scripts/**`
  - CHG-2026-006/022/043 tasks/evidence and every other change package
- Risk:high (incorrect App wiring could introduce repeated HDC child
  execution, replace observation identity, leak fixture behavior or weaken
  shared-server protections)
- Hardware required:no. Implementation evidence is contract plus signed
  macOS UI fixture only; installed HDC and real device execution are
  forbidden.
- Decision-Grade:D1 (future readiness fixes source pins, admission semantics
  and the complete verification matrix)

### Deliverables

- localized, accessible refresh control and App callback wiring;
- synchronous App-level in-flight admission and disabled-state presentation;
- unchanged public provider interface and unchanged OpenHarmony production
  source/registry/argv;
- exact UI-test-only sequential presentation fixture isolated below the
  production boundary;
- contract and signed UI tests for visible reachability, same-session event
  progression, one-call bounds, duplicate suppression and forbidden effects;
- same-revision host-only run record.

### Verification

- `HOR-UI-001` → signed English/Simplified-Chinese macOS UI tests and
  accessibility lookup → visible control exists, is keyboard/AX reachable,
  and a user action changes the deterministic fixture presentation.
- `HOR-SESSION-001` → sequential snapshot actor contract plus production-root
  source audit → accepted refreshes retain candidate/endpoint/session and
  produce appeared then disappeared in one bounded buffer.
- `HOR-BOUNDED-001` → delayed fixture, App admission spies, source occurrence
  audit and mutations → one accepted action calls the provider once and
  permits at most one registered snapshot; in-flight duplicates, timers,
  retries and queues are absent.
- `HOR-SAFETY-001` → effect counters, forbidden-source blob audit, fixture
  separation and full HDC regression suites → no lifecycle/adoption,
  subserver, binding/device mutation, destructive effect, second discovery
  or raw identifier exposure.
- Regression → ArkDeckKit full tests, focused HDC contract suites, signed
  Debug App build/UI suite, strict codesign verification, localization
  catalog parse, SDD/checker/path suites and `git diff --check`.

### Notes / handoff

- Proposal, approval, readiness, implementation/evidence, `ready→done` and
  change `verified` use separate PRs.
- After this change is verified, CHG-2026-006 `TASK-M0B-002` still requires a
  fresh D2 readiness that pins the signed App, exact HDC/device/firmware/USB
  tuple and named exclusive human-operated window.
- Add the implementation run under
  `evidence/runs/TASK-HOR-001/run.md`; fixture/platform results must be
  labeled accurately and cannot close a hardware AC.
