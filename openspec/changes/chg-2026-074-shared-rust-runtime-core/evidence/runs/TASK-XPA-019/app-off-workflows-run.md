# The App stops linking ArkDeckWorkflows

TASK-XPA-019 / CHG-2026-074, G5 slice 17 (M5: the App leaves the Swift Runtime).
Base: protected main `a7229512d` (#2138).

Ruling Q5=B, made on 2026-09-24 by the coordination session under the maintainer's delegation:
the support bundle's writing logic moves into ClientKit, writes only the directory the user
chose, and reads no Runtime private storage; `docs/ArchitectureRules.md` follows. The same
ruling restates that the App is presentation-only: it neither makes up Runtime state nor
repeats Runtime validation.

## Acceptance

| | On `a7229512d` | At this head |
| --- | --- | --- |
| Swift files under `ArkDeckApp/` or `ArkDeckAppUITests/` importing `ArkDeckWorkflows` | 1 (`ArkDeckApp.swift`) | 0 |
| Xcode targets linking the `ArkDeckWorkflows` product | 2 (`ArkDeck`, `ArkDeckHDCUITests`) | 0 |
| `ArkDeckWorkflows` references in `ArkDeck.xcodeproj/project.pbxproj` | 7 (11 lines) | 0 |

The seven references were two `PBXBuildFile` entries, two Frameworks-phase entries, two
`packageProductDependencies` entries and the `XCSwiftPackageProductDependency` declaration.
The UI-test target linked the product without any UI-test source importing it, so it loses the
link too. `Package.swift` and every ArkDeck dependency edge are unchanged. ClientKit still depends
on Core alone, plus the external SSH packages it already linked.

## What the App still took from Workflows

Removing the import and the link and building the App named two symbols, both in the
composition root `ArkDeckApp.swift`:

- `RuntimeSupportBundleSettingsExporter()`, the Settings pane's support-bundle adapter;
- `AutoUpdateApplicationFacade.make()`, the updater's production assembly, which Workflows
  declared as an extension of ClientKit's facade.

A clean recompile of both Xcode targets after the moves (the App's intermediates removed first,
so no file was skipped as up to date) builds with neither import nor link. No other App or
UI-test source used Workflows.

Checked, and nothing moved:

- HDC diagnostics. The App reads them through ClientKit's `HDCClientDiagnosticsApplicationFacade`,
  and its fixture and presentation live in ClientKit as well. Workflows'
  `HDCApplicationDiagnosticsFacade` has no App or production caller; only contract tests compose
  it. Its header still said "The App links and imports Workflows only". The comment is corrected
  and the code is unchanged.
- `SettingsStorageUIFixture`. The App stopped composing it in #2127. It stays in Workflows for
  the contract tests that check the Swift storage owner's replies.

## Where each piece went

| Piece | From | To |
| --- | --- | --- |
| `RuntimeSupportBundleSettingsExporter` | `ArkDeckWorkflows/Settings/` | `ArkDeckClientKit/` |
| `RuntimeSupportBundleApplicationFacade.make()` and its production provider | `ArkDeckWorkflows/Settings/` | `ArkDeckClientKit/` |
| The bundle writer `LocalDiagnosticBundleExporter`, its request, preview, errors and staging | `ArkDeckStorage/` | `ArkDeckClientKit/`, without its Session input |
| `AutoUpdateApplicationFacade.make()` and `SystemAutoUpdateEventLogger` | `ArkDeckWorkflows/AutoUpdate/` | `ArkDeckClientKit/AutoUpdate/` |
| `SystemLogger`, `StructuredDiagnosticLogStore` and their record, redaction and error types (`PORT-LOGGING-001`) | `ArkDeckRuntime/` | `ArkDeckClientKit/` |

All five moves are `git mv`s. The App's call sites read exactly as before.

### The support bundle (Q5=B)

- The bytes the product writes are unchanged. There are three entries — `metadata.json`,
  `hdc/tool-placeholder.json` and `bundle.json` — with the same canonical JSON. The scope hash
  covers the same inputs: the destination path, the parent directory's device and inode, and
  each entry's path and SHA-256. Staging, `RENAME_EXCL` publication, cleanup, the quota, the
  explicit-user-initiation check and the error mapping are the same code. The
  `sensitiveDataWarning` text is unchanged too. It still mentions App logs and structured Job
  summaries, which production never included; that user-visible text is out of scope here.
- Removed: the Session input (`RecentSessionDiagnosticSource`, `recentSessions`, the
  manifest and journal summaries, and the bounded manifest reader) and the
  `deviceRawNotExcluded` error that only it could throw. Production always passed
  `recentSessions: []`. With no Session, journal or Artifact input, the writer has no way to read
  Runtime storage, and no way for device raw to reach a bundle.
- Kept: App diagnostic log snapshots (`RedactedDiagnosticLogFile` and its closed-catalog
  sanitizer). They are the App's own files, and `AC-DIAG-001-02` exercises that export path.
  Production passes `logs: []`, as before.
- ClientKit cannot import ArkDeckStorage, so the writer carries its own copies of the two checks
  it used from Storage's Session validation: a plain relative path, and an RFC 3339 timestamp.
  The rules are identical. A path failure is still not a bundle error, so the facade reports it
  as the `ioFailure` it always was.
- If a bundle is ever to carry Runtime facts, such as recent Job summaries, they have to come
  through a Runtime-published resource interface, not by reading its storage.
  `docs/ArchitectureRules.md` says so.

### AutoUpdate and `SystemLogger`

`make()` needed only ArkDeckRuntime's `SystemLogger`. Dropping that logger would have dropped the
updater's bounded structured records, which `REQ-DIAG-001` requires besides the system log.
So the logger moved with it. `PORT-LOGGING-001` describes it as the App's own diagnostics. Its
only writers are the App and the Swift CLI (the updater), and no daemon code uses it.
`docs/design/cross-platform/rust-core-cross-platform-architecture.md` already puts the App half
of `SystemLogger` in each platform App. The Runtime clock it used, `AuditClock`, is replaced by
`DiagnosticAuditClock`, a ClientKit protocol of the same shape. The log directory
(`~/Library/Application Support/ArkDeck/Diagnostics`), the Unified Logging subsystem, the event
mapping and the fallback to `NoOpAutoUpdateEventLogger` are unchanged.

## The boundary assertion

- `ArchitectureBoundaryContractTests.testTheAppNeitherLinksNorImportsArkDeckWorkflows`
  (section 10) reads `ArkDeck.xcodeproj/project.pbxproj`. It fails if:
  - the project declares a `productName = ArkDeckWorkflows;` product at all;
  - any native target's `packageProductDependencies` names an ArkDeckKit product outside its
    row (`ArkDeck`: ClientKit, Core, TraceAdapter; `ArkDeckHDCUITests`: ClientKit, Core);
  - the table stops covering every native target;
  - any Swift file under `ArkDeckApp/` or `ArkDeckAppUITests/` imports Workflows, or imports an
    ArkDeckKit module its target does not link.
- `ArkDeckContractTests.testAppTargetImportsOnlyApprovedCompositionModulesFromArkDeckKit`
  drops `ArkDeckWorkflows` from its allow list.
- `docs/ArchitectureRules.md` gains the App row of the matrix, an App node in the diagram, the
  presentation-only rule and the Q5=B paragraph. It also corrects two stale sentences: the one
  claiming App façades were not yet decoupled, and the one naming a Workflows
  `DebugWindowInventoryJobRunner`, which has been in ClientKit since #2115.

## The trust-wait verdict (S7's observation)

S7 noted this without verifying it in the UI. Reading the code confirms it is a defect.
`DeviceListViewModel.finishRefresh` published every read — the startup read, the 10 s live
ticks and Re-check — and never looked at `authorizationWait`. After a wait timed out, a tick
could show the device Connected. The Unauthorized-only block hid the stale `.timedOut` there,
but when the device later read Unauthorized again, the old banner came back. So did the
"retry" label and the Overview recovery button, all for a wait that no longer applied.

The fix follows the ruling that a change in the device's state ends the previous wait's verdict:

- ClientKit decides what counts as a change:
  `DeviceListPresentation.endsTrustWaitVerdict(on:concludedFrom:)` compares a later
  observation with the one the verdict was drawn from. A successful read that shows the device
  in another state, gone, or visible again after the concluding read could not see it ends the
  verdict. A failed or still-loading read ends nothing. A read in the same state keeps the
  verdict, which still describes the device on screen.
- The App keeps the concluding observation beside a timed-out or unavailable verdict, and
  `finishRefresh` applies the rule to every read it publishes. A wait that is still polling is
  left alone, because its own result settles it. The App invents no state and classifies
  nothing; it drops a presentation that no longer holds.
- Tests:
  - `DeviceListApplicationContractTests.testALaterReadInAnotherStateEndsATimedOutVerdict`
    replays S7's timeline through the fixture provider (timeout, trusted, Unauthorized again).
    It also pins the App's wiring by source shape, since the App model is not unit-testable.
  - `testOnlyASuccessfulReadInAnotherStateEndsAWaitVerdict` covers the rule case by case.
  - The English UI sweep gains one step after S7's retry read-back: time the wait out, trust
    the device through Re-check, return it to Unauthorized, and require no timed-out banner and
    no recovery button.
- One consequence for S7's read-back. It could previously tell a retried wait that ended ready
  from one that timed out before the device flipped, because a timed-out verdict survived the
  Connected read. It can no longer tell them apart: any Connected read now ends the verdict.
  Its message now claims only what it shows. The provider's ready verdict is still covered by
  `testApplicationFacadeOwnsTheBoundedAuthorizationTimeoutAndReadyVerdict`.

No App text changed. No localization key was added, removed or reworded, so the design mirror
needs no update.

## Tests moved or changed

- `DiagnosticsContractTests`, its fixtures and `AutoUpdateDiagnosticsContractTests` move from
  ContractTests to `ArkDeckClientKitTests`, since everything they exercise is now in ClientKit.
  Two tests are removed because the input they exercised is gone:
  - `testTEST_AC_DIAG_002_01_exportUsesThePreparedBytesApprovedForPublication`, which checked a
    Session manifest changed after preview;
  - `testTEST_AC_DIAG_002_01_rejectsMismatchedJournalSummaryIdentity`, which checked journal
    summaries.
  The other bundle tests drop their Session filler and are otherwise unchanged. That covers the
  crash and Job-failure triggers, the parent replacement before and after approval, the quota
  boundary, the post-rename failure and move-away, and the FIFO substitution. The platform test
  now requires the preview to name exactly `bundle.json`, `hdc/tool-placeholder.json`, the log
  segment and `metadata.json`, and the tree to hold nothing else.
- `SettingsApplicationFacadeContractTests` (ContractTests) reads the ClientKit provider and
  writer. `recentSessions: []` gave way to two checks: the production request passes
  `logs: []`, and the writer source names no Session input.
- `RuntimeSupportBundleApplicationContractTests` stays in ContractTests, because it runs the
  built `arkdeck` CLI, and imports ClientKit only. `AutoUpdateContractTests` stops scanning the
  former Workflows AutoUpdate folder.

## Local targeted checks

- Swift, affected classes (`ARKDECK_SWIFTPM_CACHE_ROOT=/private/tmp/arkdeck-e190-swift sh
  Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --filter …`): exit 0. The run executed 191
  tests with 0 failures. One skip is the opt-in real-device latency case in
  `DeviceCandidatesContractTests`.
  - ClientKitTests: `DiagnosticsContractTests` 14, `AutoUpdateDiagnosticsContractTests` 1,
    `AutoUpdateContractTests` 23, `DeviceListApplicationContractTests` 7,
    `SettingsApplicationFacadeContractTests` 9.
  - ContractTests: `ArchitectureBoundaryContractTests` 17, `ArkDeckContractTests` 4,
    `RuntimeSupportBundleApplicationContractTests` 3, `SettingsApplicationFacadeContractTests`
    3, `SettingsStorageDomainContractTests` 3, `SettingsStorageUIFixtureContractTests` 4,
    `CLIRuntimeUpdateContractTests` 4, `DeviceCandidatesContractTests` 12,
    `APIBaselineGateContractTests` 1, `CLIArgumentParserContractTests` 81,
    `OwnerLockSpawnWindowContractTests` 5.

  The filtered run builds every target of the package, the CLI and the daemon among them. No
  warning names a changed file. Log: `/private/tmp/arkdeck-e190-s16-swift-tests-r1.log`.
- Mutations, each restored by checksum afterwards:
  - Re-adding the import, restoring the old `project.pbxproj` and dropping the App's call to the
    rule, in one run: exit 1. The boundary test reports all five violations, the old App-import
    test fails, and the source-shape check fails.
    Log: `/private/tmp/arkdeck-e190-s16-mutation-abd.log`.
  - A rule that never ends a verdict (the defect): exit 1, both new DeviceList tests fail.
    Log: `/private/tmp/arkdeck-e190-s16-mutation-c1.log`.
  - A rule that ends every verdict unless the device reads Unauthorized, ignoring the concluding
    observation: exit 1, three cases fail. Log: `/private/tmp/arkdeck-e190-s16-mutation-c2.log`.
- `ARKDECK_XCODE_CACHE_ROOT=/private/tmp/arkdeck-e190-xcode ARKDECK_XCODE_JOBS=2 sh
  scripts/ci/run-xcodebuild.sh` (ArkDeck build-for-testing, App intermediates removed first):
  exit 0, `** TEST BUILD SUCCEEDED **`. No warning names a changed file, and `Package.resolved`
  was not rewritten. Log: `/private/tmp/arkdeck-e190-s16-app-build.log`. The same build before
  the moves failed on exactly the two symbols above:
  `/private/tmp/arkdeck-e190-s16-probe-build.log`.
- `npm test` in `docs/design/arkdeck-ds`: exit 0, 83 passed. Its dependencies were copied
  locally from the main checkout, whose lock file is identical.
  Log: `/private/tmp/arkdeck-e190-s16-ds.log`.
- `ARKDECK_PYTHON=/private/tmp/arkdeck-validation-venv/bin/python sh scripts/check-sdd.sh`:
  exit 0, 0 errors and 0 warnings. Log: `/private/tmp/arkdeck-e190-s16-sdd.log`.
- UI tests did not run. The console was locked (`CGSSessionScreenIsLocked=1`) at both checks.
  The English sweep (`AppShellUITests.testEnglishSweepOfEveryWorkspace`) walks the Settings
  diagnostics pane, the updater states and the new verdict step. It needs the slow lane:
  `gh workflow run swift-slow-lanes.yml --ref agent/xpa-019-app-off-workflows -f job=ui-tests`.

## CI

Pending.
