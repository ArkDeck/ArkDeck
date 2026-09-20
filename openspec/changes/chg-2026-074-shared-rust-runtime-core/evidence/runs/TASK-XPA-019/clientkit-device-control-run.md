# Device control ClientKit extraction

Base: protected main `42d1fb97`, the merge of the workspace continuation slice (#2067). TASK-XPA-019 / SPK-8 remain incomplete. This slice moves ownership only.

The coordination session put DeviceControl next, after the three subsystems the App and the Swift
CLI share. It is the first slice since the Settings seam whose subsystem the App's feature views
use directly, so it is also the first to free more than one App file at once.

## Acceptance: App files that stop importing `ArkDeckWorkflows`

| | On `42d1fb97` | At this head |
| --- | --- | --- |
| ArkDeckApp files importing `ArkDeckWorkflows` | 15 | 12 |

The three files of the Device feature import ClientKit instead:
- `ArkDeckApp/Features/Device/DeviceWorkspaceView.swift`;
- `ArkDeckApp/Features/Device/DeviceWorkspaceViewModel.swift`, which already imported ClientKit and
  only drops Workflows;
- `ArkDeckApp/Features/Device/DeviceRecordingViewModel.swift`.

They name nothing else from Workflows. `ArkDeckApp.swift` still composes the facade from Workflows'
side of the App and keeps its import.

## What moved

Eleven files move from `Sources/ArkDeckWorkflows/` to `Sources/ArkDeckClientKit/`:

| File | What it holds |
| --- | --- |
| `DeviceControlFacade.swift` | the screen frame, gesture, gesture request and target presentation models, `DeviceControlProviding`, `DeviceControlFacade.make()`, the production provider, screenshot integrity and the Artifact index |
| `DeviceFrameArchive.swift` | the recorded frame archive and its readers |
| `DeviceRecordingBudget.swift` | the byte budget a recording is allowed |
| `DeviceRecordingComposer.swift` | frames to a movie |
| `DeviceRecordingValidation.swift` | what a composed recording must satisfy |
| `DeviceRecordingExport.swift` | the export naming |
| `DeviceRecordingFixture.swift` | the UI-test provider that replays frames |
| `DeviceFrameLiveness.swift` | whether the stream is still moving |
| `DeviceGestureClassification.swift` | a drag to one of the three gestures |
| `RuntimeWorkspaceThread.swift` | the thread identifier and client context a workspace submit carries |
| `DiagnosticCapturePreset.swift` | the typed inputs of the diagnostic capture operations |

- The facade's production provider speaks only through ClientKit's `RuntimeXPCRequestTransport`.
  It needs no ArkDeckRuntime, ArkDeckStorage or ArkDeckOpenHarmony type, so nothing stays behind
  as production assembly.
- Three import lines change, and one call:
  - `DeviceControlFacade.swift` drops `import ArkDeckClientKit` (a self-import now) and
    `import ArkDeckRuntime`, which has been dead since #2058 moved the request contract to Core.
  - `DiagnosticCapturePreset.swift` drops its now-self ClientKit import.
  - `RuntimeWorkspaceThread.swift` drops the same Runtime import, for the same reason: the
    `RuntimeClientContext` it builds is in Core.
  - `DeviceControlFacade.swift` called `RuntimeJobRecord.sha256Hex(data)`, its one remaining
    Workflows name. That function is one line, `SHA256Hex.string(of: data)`, and `SHA256Hex` is
    Core's. The facade now calls Core directly. Same bytes, same digest.
- `RuntimeWorkspaceThread` and `DiagnosticCapturePreset` are shared. Workflows' Debug, Flash, Trace
  and UIDump facades and the CLI's `ArkDeckRuntimeCommands.swift` keep using the one copy over
  edges that already exist: Workflows → ClientKit, and the CLI's transitional edge from #2054. All
  five already import ClientKit, so no import changes there.
- No dependency edge, `Package.swift`, access level or Xcode project changes.
  `docs/ArchitectureRules.md` records the move.

## Behaviour

Nothing changes. Every moved file is byte-identical apart from the imports listed above and the
digest call, which resolves to the same Core function it always reached through Workflows.

## Tests

- Five classes move to `ArkDeckClientKitTests` with `@testable import ArkDeckClientKit`:
  `DeviceControlFacadeContractTests` (which also drops a dead Runtime import),
  `DeviceGestureClassificationContractTests`, `DeviceFrameLivenessContractTests`,
  `DeviceRecordingContractTests` and `DeviceRecordingExportTests`. None of them names a Workflows
  or Runtime type any more.
- Four classes stay in ContractTests and add `@testable import ArkDeckClientKit`, because each
  still needs Workflows, the daemon or the CLI: `ScreenshotEncodingContractTests` (HDC file magic
  and the observation provider adapters), `RecordingQuotaPreflightContractTests` (Storage,
  OpenHarmony and the Runtime engine), `AgentXPCTransportContractTests` and
  `CLITypedCapturePresetContractTests`.
- `RuntimeWorkspaceThreadContractTests` and `DebugWindowInventoryJobRunnerContractTests` already
  imported ClientKit and are unchanged.

## Local targeted checks

These ran on this change over `42d1fb97`, before the check sections were written. The full local
unified gate is not run (AGENTS.md "验证与完成"); the PR's CI is the gate.

| Check | Command | Result |
| --- | --- | --- |
| Swift, the affected classes | `sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --filter` over the fourteen affected classes | r2 exit 0. 134 passed, 0 failed, 3 skipped. ClientKitTests: `DeviceControlFacadeContractTests` 8, `DeviceFrameLivenessContractTests` 8, `DeviceGestureClassificationContractTests` 10, `DeviceProductionProviderContractTests` 4, `DeviceRecordingContractTests` 14, `DeviceRecordingExportTests` 4. ContractTests: `AgentXPCTransportContractTests` 12, `ArchitectureBoundaryContractTests` 16, `ArkDeckContractTests` 4, `ArtifactResourcesContractTests` 20, `CLITypedCapturePresetContractTests` 7, `RecordingQuotaPreflightContractTests` 10, `RuntimeWorkspaceThreadContractTests` 7, `ScreenshotEncodingContractTests` 10. The three skips are opt-in and need a real capture: two want `ARKDECK_TEST_FRAME_ARCHIVE`, one wants `ARKDECK_TEST_DEVICE_JPEG`. The run builds every test target of the package. No warning names a changed file. Log `/private/tmp/claude-501/-Users-fuhanfeng-Dropbox-Code-Github-ArkDeck--claude-worktrees-blissful-goldstine-c7d922/26822f74-e8f8-4647-9226-2234ed41e115/scratchpad/logs/dev-swift-r2.log`, SHA-256 `0114785ea2ff4fa672025613e4d644c520c69e38d541a6e06fcd133a73e247cd` |
| | the same, r1 | Failed to compile: `DeviceProductionProviderContractTests` could not see `DeviceTargetPresentation`. Two test files named moved types that the first scan missed, because it searched for the file-level type names and these use others. r2 moves that class to ClientKitTests and gives `ArtifactResourcesContractTests` the ClientKit import. Log `/private/tmp/claude-501/-Users-fuhanfeng-Dropbox-Code-Github-ArkDeck--claude-worktrees-blissful-goldstine-c7d922/26822f74-e8f8-4647-9226-2234ed41e115/scratchpad/logs/dev-swift-r1.log`, SHA-256 `460f87e7901d2d492ea1b3fd6103245d78a16b4fd30d584449e3df440a8d9d68` |
| App build-for-testing | `sh scripts/ci/run-xcodebuild.sh` | exit 0, `** TEST BUILD SUCCEEDED **` for the App and its UI runner. The three Device views compile without Workflows. The only warnings on a Device file are `DeviceRecordingUITests.swift`'s existing main-actor isolation warnings: 147 of them, the same count as the previous slice's build. Log `/private/tmp/claude-501/-Users-fuhanfeng-Dropbox-Code-Github-ArkDeck--claude-worktrees-blissful-goldstine-c7d922/26822f74-e8f8-4647-9226-2234ed41e115/scratchpad/logs/dev-app-build-r1.log`, SHA-256 `7739191a72bbc75098373fe9fe341d926d0f79ba1548c6f9e8073062d9b9bdef` |
| SDD | `sh scripts/check-sdd.sh` | exit 0: 0 errors, 0 warnings |

## CI

Recorded by the next slice, because a green head is merged without an amend. The workspace
continuation slice's CI (#2067) is recorded in its own run record by this commit.

## Not run

- The Device workspace UI walks through `run-ui-tests.sh`, including the recording fixture's. The
  App build-for-testing compiles the App and its UI runner.
- A device: the screenshot, gesture and recording paths need one, and CI has none.
