# Tasks

## TASK-HOR-001 — Add and verify the explicit in-session HDC refresh route

- Status:done
- Done confirmation(2026-07-29; verification-only closure; only effective
  after maintainer review/merge):
  - **Implementation/evidence merge:**PR #772 exact head
    `25a0d4a3789fdda985f9f13057e7e0dd8f217bde` was approved by maintainer
    `lvye` and merged as protected-main
    `7125cda045cb45ccb992997bcbe43fa5da90bdb3`. Its Agent PR
    open-pr/allowed-paths, SDD Guard and Swift CI checks were `SUCCESS`.
  - **Evidence and AC closure:**protected-main
    `evidence/runs/TASK-HOR-001/implementation-r1.md` (blob
    `c8e104d809d6bcc9813b9ea5977ae64592a27680`) records
    `HOR-UI-001`, `HOR-SESSION-001`, `HOR-BOUNDED-001` and
    `HOR-SAFETY-001` as PASS with accurately separated signed
    `platform` and `contract` evidence. Closure replay is recorded in
    `evidence/runs/TASK-HOR-001/verification-r1.md`.
  - **No drift/no effect:**the six implementation blobs, production
    `HDCProduction.swift`, OpenHarmony registries/profile/lock and macOS
    profile match the #772 evidence. Installed HDC, real device, lifecycle,
    subserver, authorization/adoption, binding/device mutation, destructive
    and non-loopback product-network dispatch remain 0.
  - **Governance transition:**#772 merged before enforcement 2.2.0 made task
    status part of the vertical implementation carrier. Because 2.2.0 now
    forbids a done-only PR, this implementation-free verification closure
    reconciles `ready→done` using only status and concrete evidence
    references. It creates no new scope, risk acceptance or authority.
- Previous status:ready after maintainer review/merge of readiness PR #770;
  before that, blocked until the proposal, approval and D1 readiness gates
  were each closed.
- Fresh readiness review(2026-07-29; contract + signed macOS fixture only;
  zero installed-HDC/device dispatch):
  - **Trust/dependency gate:**proposal PR #766 exact head
    `4e898ce54b37fafbef776da7c0722a8b728046d5` was approved by maintainer
    `lvye` and merged as
    `7938cf67a2749a8d7ddb3c86b44fd244705d3974`; approval-only PR #768
    exact head `7441fd4075830f3169e35715da459f01a2d2dede` was approved by the
    same maintainer and merged as protected main
    `f1214137bd80c2544209dcd95ac32a869982ec06`. Duplicate approval PR
    #767 is closed and unmerged. At the final audit, local `origin/main` and
    the GitHub protected-main API both reported `f1214137...`; open PR count
    was 0.
  - **Unique route and admission:**the only approved route is existing App
    composition → one visible localized/accessible action → a synchronous
    main-actor `HDCStatusViewModel` in-flight guard → the unchanged provider
    `refresh()` → the retained production observation session → its existing
    one-poll actor guard. Startup and manual activation call the same App
    method. While in flight, refresh and executable reselection are disabled;
    duplicate activation is rejected rather than queued. Completion and
    cancellation clear only App admission state and never terminate HDC.
  - **Identity/source boundary:**refresh retains the existing
    candidate-canonical-identity, endpoint and execution-session key and
    capacity-64 buffer. The App cannot construct candidate, endpoint, runner,
    argv, receipt or generation facts. Production remains the single internal
    3.2.0f source at `127.0.0.1:8710`, SHA-256
    `05b2bf7ad30201c082da336db28f8856952a2b2f49ac3404b96fdb4bf1a68f83`,
    exact argv `list targets -v`, 15-second bound and at most one source
    invocation per accepted refresh.
  - **Fixture boundary:**the exact existing UI flag selects a
    presentation-only Workflows actor. Implementation may add only
    fixture-local sequential presentation, delay and call counters below that
    boundary. Production source/registry/profile files, provider interface,
    target/project wiring and signing settings remain byte-identical.
  - **Baseline:**macOS 26.6 (`25G72`) arm64, Xcode 26.6 (`17F113`) and
    Swift 6.3.3. Full ArkDeckKit was 506 tests / 1 skipped / 0 failures.
    The default ad-hoc signed Debug App and UI runner passed strict codesign
    verification; the exact HDC UI suite passed 13/13 after its documented,
    byte-identical visible fake hardlink precondition. SDD was 0 errors /
    0 warnings / 111 AC; checker tests were 56/56; path tests were 50/50;
    the localization catalog parsed and dry-run compiled English plus
    Simplified Chinese. These are readiness baselines, not implementation AC
    evidence.
  - **Closed matrix:**callback/action/locale removal; disconnected App
    composition; delayed duplicate action; provider double-call; second
    discovery/session/source; session clear/replacement; timer, background
    loop, retry or task queue; fixture leakage; OpenHarmony/registry/profile
    drift; lifecycle/subserver/device mutation/destructive effect; and raw
    identifier exposure each have a named contract, signed UI, source/blob or
    effect-counter red path in
    `evidence/runs/TASK-HOR-001/readiness-r1.md`.
  - **Boundary:**this PR contains readiness only. No implementation or
    `HOR-*` AC is claimed. Implementation/evidence, `ready→done` and change
    `verified` remain three later PRs.
- Platform:macos
- Requirements:compatible implementation of `REQ-UX-002`, `REQ-HDC-002`,
  `REQ-HDC-003`, `REQ-HDC-004` and `REQ-I18N-001`
- Acceptance:`HOR-UI-001`, `HOR-SESSION-001`, `HOR-BOUNDED-001`,
  `HOR-SAFETY-001`
- Depends on:proposal PR #766 and approval-only PR #768 merged (satisfied);
  independent D1 readiness (this PR; implementation remains forbidden until
  merge)
- Readiness input pins:

  ```yaml pins
  - commit: f1214137bd80c2544209dcd95ac32a869982ec06
  - commit: 7938cf67a2749a8d7ddb3c86b44fd244705d3974
  - commit: 4e898ce54b37fafbef776da7c0722a8b728046d5
  - commit: 7441fd4075830f3169e35715da459f01a2d2dede
  - path: openspec/constitution.md
    blob: 137d09da7eaa535670a8bd3b0c9537681e6cb21b
  - path: openspec/project.md
    blob: 1d9d746cfb5f1b38dcb7730a9e55f471f3dffd0d
  - path: openspec/governance/enforcement.md
    blob: e8ff3c130e1b8b15f8405d150ad567e774a0d82b
  - path: openspec/verification/policy.md
    blob: ef3b42085ff50b54f1bb70650510f27bdc020cf1
  - path: openspec/changes/chg-2026-045-hdc-observation-refresh/proposal.md
    blob: 695d4317b6e017da77b17ac6984ad0fc422a0ab9
  - path: openspec/changes/chg-2026-045-hdc-observation-refresh/design.md
    blob: 5c778b819e9a193895ae6bf1f9bd8c3348476a8b
  - path: openspec/changes/chg-2026-045-hdc-observation-refresh/tasks.md
    blob: 3bbd5e03942d4c6ef4b7614456f4b571eac943ca
  - path: openspec/changes/chg-2026-045-hdc-observation-refresh/verification.md
    blob: 69aa73e0eac697e9c0f71a1492a946f56b128925
  - path: openspec/changes/chg-2026-045-hdc-observation-refresh/acceptance-cases.yaml
    blob: b99e627b2bce9166cc9fd8abaae9e4ce5c30a141
  - path: openspec/changes/chg-2026-045-hdc-observation-refresh/spec-impact.md
    blob: 6c369f2d44a639ed056c563d1cb5ce51db6e4a85
  - path: openspec/specs/desktop-ux-observability/spec.md
    blob: 8f7613a4443605fcdac2aec0346b925948fcae09
  - path: openspec/specs/toolchain-hdc-server/spec.md
    blob: f5a44a44ca14894d3d966c3333e159ba3f900d35
  - path: openspec/platforms/macos/profile.md
    blob: b7471666b0bbfbfade3fbd510ad831e45b3cf9b8
  - path: openspec/integrations/openharmony/profile.md
    blob: 2ae13490e075f327bb7448ccacf908be5ba7e3aa
  - path: openspec/integrations/INTEGRATION-PROFILES.lock.yaml
    blob: 836d4ccc8c34c5826b6c53dcf9004e678a506d25
  - path: openspec/integrations/openharmony/device-observation-probes.yaml
    blob: 399c5a102c7737bf6466e8a2c4c6a1d1b1bc0b6a
  - path: openspec/integrations/openharmony/supervisor-observation-probes.yaml
    blob: b202b9d34680a0e7bbdba1d02637279ca4819d3f
  - path: ArkDeck.xcodeproj/project.pbxproj
    blob: e7943096688728a22f4b940e536a32f3b8eaaf98
  - path: ArkDeck.xcodeproj/xcshareddata/xcschemes/ArkDeck.xcscheme
    blob: 29d0fb995dd3a28ad535569a4cdc4c3964311def
  - path: ArkDeckApp/App/ArkDeckApp.swift
    blob: 1ec424df02550cc9f79780b7a4b61af28d7faf30
  - path: ArkDeckApp/Features/HDC/HDCStatusView.swift
    blob: 476769d4b5b242a91b2bb4d0661cdb0fb7359d44
  - path: ArkDeckApp/Resources/Localizable.xcstrings
    blob: dfde9a699d0e58168a181a26e8ca31fc2f21ab2d
  - path: Packages/ArkDeckKit/Package.swift
    blob: 292135a2c80c63ddf7182f58e2f81ff7c7d6104d
  - path: Packages/ArkDeckKit/Sources/ArkDeckWorkflows/HDCApplicationDiagnosticsFacade.swift
    blob: fa0bc651382c9b5d1a36a46c59a11af65bc84249
  - path: Packages/ArkDeckKit/Sources/ArkDeckWorkflows/HDCApplicationParticipantRegistry.swift
    blob: a3c17716379824233ec0c4a916d1a4d38c5a6f16
  - path: Packages/ArkDeckKit/Sources/ArkDeckOpenHarmony/HDCProduction.swift
    blob: c7f71e5af90bc3d468d5f0817734d297f0c339a2
  - path: Packages/ArkDeckKit/Sources/ArkDeckOpenHarmony/HDCReadOnlyProbeRegistry.swift
    blob: 2dfe8e9d8290d6e939b4e3531ac81bb332a7cc29
  - path: Packages/ArkDeckKit/Sources/ArkDeckOpenHarmony/HDCSupervisorObservationProbeRegistry.swift
    blob: 589dfec329044b58f4fefec3a70d4af7f9cfd15e
  - path: Packages/ArkDeckKit/Tests/ArkDeckContractTests/HDCDeviceObservationPresentationContractTests.swift
    blob: a54b950a67af564260efe55fb159e63a1847b59d
  - path: Packages/ArkDeckKit/Tests/ArkDeckFakeHDCFixture/main.swift
    blob: bd4b0beb792b8a7989930679a28db9b6ec4db42a
  - path: ArkDeckAppUITests/HDC/HDCStatusUITests.swift
    blob: 6224637fcc083807684a2473785f559b181f0925
  - path: scripts/check-sdd.sh
    blob: 7668f5aea9e8d4aeb4620b3047926a8802c1746a
  - path: scripts/check_sdd.py
    blob: aa7dc6e34d187cb6458689d72ac28564b58fb29b
  - path: scripts/test_check_sdd.py
    blob: 7e6c47044b31065d2752ce78d9185b6a3869732b
  - path: scripts/test_check_pr_paths.py
    blob: bb53f50ec1c198defc2a0439c11cf1dd6132b55c
  - path: .github/workflows/sdd-guard.yml
    blob: 1ab1db896b4ee83207e006b2720cdbe1c0d27e70
  - path: .github/workflows/agent-pr.yml
    blob: a514d9e539964f9e1960acbe4ffaa696629571da
  ```
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

- Proposal, approval, readiness and implementation/evidence used the
  then-current separate carriers. The 2.2.0 transition and final task/change
  status reconciliation are recorded in the verification closure.
- After this change is verified, CHG-2026-006 `TASK-M0B-002` still requires a
  fresh D2 readiness that pins the signed App, exact HDC/device/firmware/USB
  tuple and named exclusive human-operated window.
- Implementation and closure records are under
  `evidence/runs/TASK-HOR-001/`; fixture/platform results remain non-hardware
  evidence and cannot close a hardware AC.
