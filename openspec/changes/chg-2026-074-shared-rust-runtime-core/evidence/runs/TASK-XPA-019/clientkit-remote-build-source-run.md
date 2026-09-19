# Remote build source ClientKit extraction

Base: protected main `cb246207`. TASK-XPA-019 / SPK-8 remain incomplete. This slice moves
ownership only. TASK-XPA-019 is done when the App no longer imports `ArkDeckWorkflows`, so the
App-local subsystems that call no Runtime method move whether or not the Rust daemon is ready.
Ordered by how much they depend on Workflows, this is the first of three.

| Already on `main` | This slice | Still remaining (TASK-XPA-019) |
|---|---|---|
| ClientKit transport and History filter (#1976), History readers and JobControl (#1982), Device list (#1991), Trace cache (#1997), Overview capability (#2007), Settings (#2036) | The SSH remote build source (`RemoteBuildSourceApplicationFacade`) and `DebugTypedValueValidator` move from Workflows to ClientKit, with the SSH package products | AutoUpdate, RuntimeSupportBundle, then DeviceControl and UIDump ownership; seven Workflows facade files; SPK-8 signed standalone App acceptance; the UI suites per facade |

## Acceptance: App files that stop importing `ArkDeckWorkflows`

| | On `cb246207` | At this head |
| --- | --- | --- |
| ArkDeckApp files importing `ArkDeckWorkflows` | 19 | 17 |
| ArkDeckApp files importing `ArkDeckClientKit` | 18 | 19 |

- `ArkDeckApp/Features/Debug/DebugRemoteBuildBrowserViewModel.swift` imports ClientKit instead.
- `ArkDeckApp/Features/Settings/SettingsWorkspaceViewModel.swift` drops the import. Since #2036
  and #1997 its other types are ClientKit's too.
- Still importing Workflows for other types: `OverviewRecordView.swift` (Overview run records and
  actions), `DebugWorkspaceView.swift` (the Debug workspace) and `SettingsRootView.swift` (HDC
  diagnostics).

## Why this one first

| Subsystem | Workflows ties | Other consumers |
| --- | --- | --- |
| RemoteBuildSource | imports only ArkDeckCore and the SSH packages. One same-module use, `DebugTypedValueValidator`, a Foundation-only validator; the compiler found it, and it moves too | the App (5 files), the Workflows Debug facade (Workflows → ClientKit exists); not the CLI |
| AutoUpdate | uses ArkDeckRuntime's `SystemLogger`, which ClientKit may not import | the CLI's `update-feed` and `runtime update` use it, and the CLI may not import ClientKit |
| RuntimeSupportBundle | its exporter is ArkDeckStorage's | the CLI; the App side has been behind the #2036 seam since |

The cross-platform design's retain table (E.2) keeps RemoteBuildSource "App side" (DEC-013
platformService) and Citadel/swift-nio-ssh "App side". ClientKit is the App's client library.

## What moved and what stayed

- `Sources/ArkDeckClientKit/RemoteBuildSourceApplicationFacade.swift` is the former
  `Sources/ArkDeckWorkflows/RemoteBuildSource/RemoteBuildSourceApplicationFacade.swift`, a rename
  with no content change. It holds the source and binding facades, the presentation models, the
  SSH/SFTP client, the Keychain credential store and the record, binding and audit files. The
  now-empty `RemoteBuildSource/` directory is gone.
- `Sources/ArkDeckClientKit/DebugTypedValueValidator.swift` holds the validator, moved verbatim
  out of `DebugApplicationFacade.swift`. Its users read the one copy from ClientKit:
  - the Debug facade and `DiagnosticCapturePreset` in Workflows (the latter now imports
    ClientKit);
  - the daemon (`AgentDaemon.swift`);
  - the App's Debug view;
  - `DebugApplicationFacadeContractTests`, which now imports ClientKit.
  Copying its native-library file-name rule into the source would have been a second copy
  to drift.
- `Package.swift`: the Citadel, Crypto (swift-crypto), NIOCore, NIOSSH and Logging (swift-log)
  products move from the Workflows target to the ClientKit target. No other Workflows file imported
  them.
- No ArkDeck dependency edge changes. `ArchitectureBoundaryContractTests.allowedImports`,
  `ArkDeckContractTests.declaredPackageDependencies` and the Xcode project are untouched.
  `docs/ArchitectureRules.md` records the split.
- UI runner:
  - `RemoteBuildSourceStateTests` uses `@testable import ArkDeckClientKit`, because the moved
    presentation types' memberwise initializers are internal.
  - `SettingsStorageStateTests` no longer imports Workflows.

## Behaviour

Nothing changes:
- Both files are byte-identical moves. The validator's new file only adds `import Foundation`.
- The persisted state is where it was: `Application Support/com.arkdeck.ArkDeck/RemoteBuildSources`,
  with `sources-v1.json`, `target-bindings-v1.json` and `audit-v1.jsonl`.
- The Keychain service (`com.arkdeck.remote-build-source.v1`) and the SFTP logger label are string
  literals. Nothing depends on the module name, so saved sources and credentials read back as
  before.

## Tests

- `RemoteBuildSourceContractTests` moves to `ArkDeckClientKitTests` (a rename, now
  `@testable import ArkDeckClientKit`). Its six tests need nothing but ClientKit: Keychain round
  trip, bounds, private profile and audit files, target binding, the system SSH identity resolver,
  and the App sandbox's SSH exceptions.
- Its live SFTP test moves to `ArkDeckContractTests/RemoteBuildSourceLiveFetchContractTests`, with
  its in-memory credential store. It checks the fetched library with Workflows'
  `NativeLibraryArtifactValidator` and the `NativeLibraryTestFixture` ELF. It runs only with
  `ARKDECK_TEST_SSH_*` set.

## Local targeted checks

On this change over `cb246207`, before the check sections were written. The full local unified
gate is not run (AGENTS.md "验证与完成"); the PR's CI is the gate.

| Check | Command | Result |
| --- | --- | --- |
| Swift, the affected classes | `sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --filter 'RemoteBuildSourceContractTests\|RemoteBuildSourceLiveFetchContractTests\|DebugApplicationFacadeContractTests\|ArchitectureBoundaryContractTests\|ArkDeckContractTests\.ArkDeckContractTests/\|AutoUpdateContractTests\|SettingsApplicationFacadeContractTests'` | r3 exit 0. 85 passed, 0 failed, and the live SFTP test skipped (no `ARKDECK_TEST_SSH_*`): ClientKit `RemoteBuildSourceContractTests` 6 and `SettingsApplicationFacadeContractTests` 4; ContractTests `ArchitectureBoundaryContractTests` 15, `ArkDeckContractTests` 4, `AutoUpdateContractTests` 24, `DebugApplicationFacadeContractTests` 29, `SettingsApplicationFacadeContractTests` 3. The run builds every test target of the package. Log `/private/tmp/claude-501/-Users-fuhanfeng-Dropbox-Code-Github-ArkDeck--claude-worktrees-blissful-goldstine-c7d922/26822f74-e8f8-4647-9226-2234ed41e115/scratchpad/logs/rbs-swift-r3.log`, SHA-256 `d414e00fdc753f289eb5c8219fc4b856e8bf7bb380e1c4be53597ac4b92c15b5` |
| | the same, r1 and r2 | Both failed to compile, and each failure changed this slice. r1: the moved source used `DebugTypedValueValidator`, so the validator moved too. r2: the live SFTP test needed Workflows' validator and the ELF fixture, so it moved back to ContractTests |
| App build-for-testing | `sh scripts/ci/run-xcodebuild.sh` | exit 0, `** TEST BUILD SUCCEEDED **` for the App and its UI runner. No warning names a changed file. Log `/private/tmp/claude-501/-Users-fuhanfeng-Dropbox-Code-Github-ArkDeck--claude-worktrees-blissful-goldstine-c7d922/26822f74-e8f8-4647-9226-2234ed41e115/scratchpad/logs/rbs-app-build-r1.log`, SHA-256 `a6bcaad8fc68489956881695a1a22f472959a5d9e275abc4876f8b19b0259fe4` |
| SDD | `sh scripts/check-sdd.sh` | exit 0: 0 errors, 0 warnings |

## CI

Recorded by the next slice: a green head is merged without an amend.

## Not run

- The Settings Remote build source UI walks through `run-ui-tests.sh`. The App build-for-testing
  compiles the App and its UI runner.
- A live SSH endpoint (`ARKDECK_TEST_SSH_*`), signed standalone Rust App acceptance, a device.
