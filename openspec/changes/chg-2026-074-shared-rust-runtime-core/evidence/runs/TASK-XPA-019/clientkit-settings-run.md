# Settings ClientKit extraction

Base: protected main `7b5872f1`. TASK-XPA-019 / SPK-8 remain incomplete. This slice moves
ownership only. The App still reaches the Swift daemon, and the isolated Rust daemon's App ingress
does not admit these methods yet (see "Rust readiness").

| Already on `main` | This slice | Still remaining (TASK-XPA-019) |
|---|---|---|
| ClientKit transport and History filter (#1976), History readers and JobControl (#1982), Device list (#1991), Trace cache (#1997), Overview capability (#2007) | `SettingsApplicationFacade` — the Settings presentation models, the provider protocol and facade, the production provider's `runtime.storage.*` requests, exact-shape validation and mapping — moves from Workflows to ClientKit. The diagnostic bundle exporter and the UI-automation storage owner stay in Workflows behind two ClientKit protocols the App composes | eight Workflows facade files, SPK-8 signed standalone App acceptance, the UI suites per facade |

## Why Settings

The pick follows the lane's rule: move the facade whose methods the isolated Rust daemon already
serves. Each remaining Workflows facade was checked against `handle_frame` in
`rust/crates/arkdeck-control/src/lib.rs`:

| Facade | Runtime methods it sends | On the Rust daemon |
| --- | --- | --- |
| Settings | `runtime.storage.status`, `.policy`, `.root`; no Job | all routed (the storage owner, TASK-XPA-012) |
| UIDump, DeviceControl | Job and Artifact methods | routed, but the operations they submit are not executable in Rust |
| Trace | Job methods and `trace.probe` | `trace.probe` not routed |
| Debug | Job methods and `debug.probe` | `debug.probe` not routed |
| Flash | Job methods and `flash.*` | `flash.*` not routed |
| RockchipDeviceAccess | `flash.device-access` | not routed |
| RuntimeSupportBundle | none; a local exporter | its exporter reads host files through ArkDeckStorage, which ClientKit may not import |
| RuntimeUpdate | none; the local AutoUpdate lifecycle | moving it moves the AutoUpdate subsystem |
| RemoteBuildSource | none; SSH through Citadel/NIO | not a Runtime facade |

Settings is the only one whose Runtime methods are all routed. The same holds for the Trace cache
facade (#1997): the Rust App ingress (`app_ingress.rs`) admits neither family yet.

## What moved and what stayed

- `Sources/ArkDeckClientKit/SettingsApplicationFacade.swift` is the former Workflows file (a Git
  rename). It imports only `ArkDeckCore` and Foundation. The two `import`s it no longer needs are
  gone: ClientKit's own module and `ArkDeckStorage`, which it did not use. There is no re-export
  shim.
- The facade used two Workflows-only things. Each now sits behind a ClientKit protocol the App
  composes, as the Overview's window-inventory runner does (#2007):
  - `RuntimeSupportBundleApplicationFacade`, the support-bundle exporter the CLI shares. It reads
    host files through ArkDeckStorage. ClientKit declares `SettingsDiagnosticBundleExporting`
    (`preview(at:)`, `export(to:approvedScopeSHA256:)`). The new
    `Sources/ArkDeckWorkflows/Settings/RuntimeSupportBundleSettingsExporter.swift` adapts the
    exporter to it, carrying the preview and receipt mapping the provider used to do inline.
    `RuntimeSupportBundleApplicationFacade.make(bundle:)` lost its only caller and is removed;
    `make()`, which the adapter and the CLI use, is unchanged.
  - `SettingsStorageUIFixture`, the owner that answers `runtime.storage.*` for a
    `--ui-test-runtime-history` launch from the daemon's own `RuntimeSessionStorageStore`.
    ClientKit declares `SettingsRuntimeStorageFixture` (`runtimeStorageReply`, `nil` while
    unreachable). The fixture's `Owner` conforms, and `SettingsStorageUIFixture.runtimeStorage()`
    gives the App the owner for a selecting launch and `nil` otherwise.
- `SettingsApplicationFacade.make(diagnosticBundles:storageFixture:)` replaces
  `make(arguments:)`. The test seam `make(reply:)` now also takes the exporter. The seam
  `make(arguments:fixtureRoot:)` is gone, because the fixture no longer lives beside the facade.
- No dependency edge changes: ClientKit → Core, and Workflows → ClientKit already existed.
  `Package.swift`, `ArchitectureBoundaryContractTests.allowedImports` and the Xcode project are
  untouched. `docs/ArchitectureRules.md` records the split.
- App changes:
  - `ArkDeckApp/App/ArkDeckApp.swift` composes
    `SettingsApplicationFacade.make(diagnosticBundles: RuntimeSupportBundleSettingsExporter(),
    storageFixture: SettingsStorageUIFixture.runtimeStorage())`. It already imported both modules.
  - `SettingsRootView.swift` and `SettingsWorkspaceViewModel.swift` already imported ClientKit.
    Both still import Workflows for Remote build source and HDC diagnostics types.
  - `ArkDeckAppUITests/SettingsStorageStateTests.swift`, which builds Settings presentations for
    the view model compiled into the UI runner, imports ClientKit.

## Behaviour

The production provider's code is the former file's apart from the transport and exporter
injection:
- The requests and parameters are unchanged: `runtime.storage.status` without parameters,
  `.policy` and `.root` with the expected generation. A `resourceConflict` is still reconciled by
  reading the status back, never re-sent.
- The exact-shape validation, the presentation mapping and the General presentation are unchanged.
- A fixture launch asks the owner once per request (`runtimeStorageReply`) instead of twice
  (`isReachable()`, then `reply`). The answers are the same, and an unreachable owner is still the
  `unavailable` transport failure, so the pane still reports `runtimeStorageUnavailable`.
- The diagnostic preview and export map the same fields, now in the adapter.
- No UI copy, row, state or request name changes.

## Tests

- `ArkDeckClientKitTests/SettingsApplicationFacadeContractTests` (new), against ClientKit alone:
  - A composed storage fixture answers in the Runtime's place through the same validation, and one
    that does not answer reads as `runtimeStorageUnavailable`.
  - The diagnostic bundle goes through the composed exporter only, and an export carries exactly
    the approved scope digest.
  - Two tests moved from `ArkDeckContractTests/SettingsApplicationFacadeContractTests.swift`:
    unusable replies are refused, and the production source reads Runtime storage. The source
    test now reads the ClientKit path and also checks that the facade imports none of
    ArkDeckWorkflows, ArkDeckStorage or ArkDeckRuntime.
- `ArkDeckContractTests/SettingsApplicationFacadeContractTests.swift` keeps the tests that need
  the Workflows pieces:
  - The diagnostics export runs over the real exporter.
  - The scene test pins the App's new composition.
  - The source test reads the facade's new path beside the support-bundle facade.
  - The storage-domain tests go through the composition the App makes. A test-module helper,
    `SettingsApplicationFacade.composed(arguments:fixtureRoot:)`, keeps each owner under its own
    root.
- `ArkDeckContractTests/SettingsStorageUIFixtureContractTests.swift` uses the same helper and
  also pins `runtimeStorage(arguments:)`: `nil` for an ordinary launch, an owner for a selecting
  one.
- `RuntimeSupportBundleApplicationContractTests` is unchanged.

## Rust readiness

- `runtime.storage.status`, `.policy` and `.root` are routed by `arkdeck-control` to the isolated
  owner's storage handler.
- The standalone Rust App ingress (`ARKDECK_APP_INGRESS=history`) admits only `health`, History
  filter and the History reads. So a pure Rust daemon still refuses this facade's requests from the
  App, as it does the Trace cache facade's.

## Counts

By the dashboard's PYCOUNT rule (`*ApplicationFacade.swift` under each target), at this head:
- ClientKit has 7 facade files (was 6).
- Workflows has 8 (was 9): RuntimeUpdate, Debug, Flash, RemoteBuildSource, RockchipDeviceAccess,
  RuntimeSupportBundle, Trace and UIDump.
- ArkDeckApp files importing `ArkDeckWorkflows`: still 19. ArkDeckApp files importing
  `ArkDeckClientKit`: still 18.

## Local targeted checks

On `5c7f4cf6`, this change rebased on `7b5872f1`, before the check sections were written. The
full local unified gate is not run (AGENTS.md "验证与完成"); the PR's CI is the gate.

| Check | Command | Result |
| --- | --- | --- |
| Swift, the affected classes | `sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --filter 'SettingsApplicationFacadeContractTests\|SettingsStorageDomainContractTests\|SettingsStorageUIFixtureContractTests\|RuntimeSupportBundleApplicationContractTests\|ArchitectureBoundaryContractTests'` | exit 0. 32 tests, 0 failures: ClientKit `SettingsApplicationFacadeContractTests` 4; ContractTests `SettingsApplicationFacadeContractTests` 3, `SettingsStorageDomainContractTests` 3, `SettingsStorageUIFixtureContractTests` 4, `RuntimeSupportBundleApplicationContractTests` 3, `ArchitectureBoundaryContractTests` 15. The run builds every test target of the package. Log `/private/tmp/claude-501/-Users-fuhanfeng-Dropbox-Code-Github-ArkDeck--claude-worktrees-blissful-goldstine-c7d922/26822f74-e8f8-4647-9226-2234ed41e115/scratchpad/logs/settings-swift-r1.log`, SHA-256 `16983fa58454f19ba0a9cdf4ef3ed6976b95cf4363f9fd6b1063a1e666b361ad` |
| App build-for-testing | `sh scripts/ci/run-xcodebuild.sh` | exit 0, `** TEST BUILD SUCCEEDED **` for the App and its UI runner. No warning names a changed file. Log `/private/tmp/claude-501/-Users-fuhanfeng-Dropbox-Code-Github-ArkDeck--claude-worktrees-blissful-goldstine-c7d922/26822f74-e8f8-4647-9226-2234ed41e115/scratchpad/logs/settings-app-build-r1.log`, SHA-256 `f301b788eb71230851b1db4e60d6027c94a435a9907970a099012caf644638bf` |
| SDD | `sh scripts/check-sdd.sh` | exit 0: 0 errors, 0 warnings |

## CI

PR #2036, merged as `cb246207`. On head `6c880be9` (base `7b5872f1`) every check passed:

| Workflow run | Jobs | Conclusion |
| --- | --- | --- |
| Swift CI `35446522904` | `plan`, `swift-tests`, `app-build`, `ds-interactions` and the required `swift` aggregate; `rust-checks` skipped, as the plan selected no Rust lane | success |
| SDD Guard `35446522799` | the required `guard`, `ds-tokens` | success |
| Agent PR `35446522776` | `open-pr` | success |

A green head is merged without an amend, so the Remote build source slice records this section.

## Not run

- The Settings UI suite (`AppShellUITests` Storage walks through `run-ui-tests.sh`). This slice
  was not assigned the host's shared UI runway. The App build-for-testing compiles the App and its
  UI runner, and the fixture owner those walks launch with answers exactly as before.
- Signed standalone Rust App acceptance, installed activation, a device.
