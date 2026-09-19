# AutoUpdate ClientKit extraction, with the CLI → ClientKit transitional edge

Base: protected main `0ae927d1`, which includes the Overview projections slice (#2048, merged as
`b6bf1536`). TASK-XPA-019 / SPK-8 remain incomplete. This slice moves ownership, and it adds
the one dependency edge the move needs.

## The ruling and the edge

On 2026-09-19 the coordination session ruled, under authority the maintainer delegated to it,
that `ArkDeckCLI` may depend on `ArkDeckClientKit` as a transitional edge. It first set the edge
to land in a slice of its own. It was then asked about `docs/ArchitectureRules.md` §6 example 5,
which says a matrix widening lands in the same PR as the code that needs it. Its answer: the
repository's governance rule takes precedence over its ruling, so the edge lands with the
AutoUpdate move, the first CLI code that imports ClientKit. The maintainer can veto this slice
as a whole.

| Condition of the ruling | Here |
| --- | --- |
| ① ClientKit still depends only on Core, and the edge graph stays acyclic | ClientKit's ArkDeck dependencies are unchanged: `ArkDeckCore`, plus the external SSH packages from #2044. Only test targets depend on the CLI, so the new edge closes no cycle. SwiftPM also refuses a cyclic target graph when it loads the manifest. |
| ② The matrix and `ArchitectureBoundaryContractTests` change in the same PR, and the commit body says the edge is transitional and disappears when the Swift CLI is deleted at M5 | Both change here. `docs/ArchitectureRules.md` gets a dotted, labelled diagram edge, a pointer from the §2 matrix and a §2 paragraph. `allowedImports["ArkDeckCLI"]` gains `ArkDeckClientKit`, with a comment. The commit body carries the sentence. |
| ③ Production assembly stays in Workflows: `SystemAutoUpdateEventLogger` and `make()` | Both stay, in `Sources/ArkDeckWorkflows/AutoUpdate/AutoUpdateProductionAssembly.swift`. |
| ④ AutoUpdate, RuntimeSupportBundle and `RuntimeWorkspaceContinuation` each get their own slice | This is the AutoUpdate slice. The edge comes with it under §6 example 5, as ruled above. |

These CLI files need the edge:

| When | CLI file | What it names |
| --- | --- | --- |
| This slice | `CLIRuntimeUpdate.swift` | `RuntimeUpdateCommandOperating` names `UpdateProductIdentity`, `AutoUpdateState`, `RuntimeUpdateStatusProjection` and `RuntimeUpdateCleanupReceipt`. |
| This slice | `ArkDeckCLIMain.swift` | `runUpdateFeed`, `prepareUpdateFeed` and `assembleUpdateFeed` name `UpdateFeedPayload`, `UpdateFeedVerifier`, `UpdateFeedCodec`, `UpdateFeedTrust` and `UpdateFeedError`. |
| The RuntimeSupportBundle slice | `ArkDeckRuntimeCommands.swift` | `runRuntimeSupportBundle` names `RuntimeSupportBundleApplicationFacade`, `RuntimeSupportBundleProviding` and `RuntimeSupportBundleServiceError`. |
| The `RuntimeWorkspaceContinuation` slice | `CLIWorkspaceContinuation.swift` | `RuntimeWorkspaceContinuation`. |

`CLICommandRegistry.swift` needs no import, because it names only the `maintainer update-feed`
node and none of the moved types. The CLI already links ClientKit through
`ArkDeckWorkflows` → `ArkDeckClientKit`, so the edge adds no library to the executable. It only
lets CLI sources import ClientKit.

## Acceptance: App files that stop importing `ArkDeckWorkflows`

| | On `0ae927d1` | At this head |
| --- | --- | --- |
| ArkDeckApp files importing `ArkDeckWorkflows` | 16 | 16 |

No App file is freed. Only the composition root, `ArkDeckApp.swift`, uses the updater. It keeps
importing Workflows for `AutoUpdateApplicationFacade.make()` and for the facades still there. The
coordination session knew this when it set the order: the three subsystems the App and CLI share
move first because they depend least on Workflows internals. The slice still shrinks what the App
reaches through Workflows. Every updater type the composition root names now comes from ClientKit,
except `make()`.

## What moved and what stayed

- `Sources/ArkDeckClientKit/AutoUpdate/` holds the ten files of the former
  `Sources/ArkDeckWorkflows/AutoUpdate/`, renamed:
  - feed parsing and signature verification;
  - download;
  - the state, artifact and replay file stores;
  - the URLSession streamer;
  - the Security code-signing validator;
  - preferences;
  - the service state machine;
  - `RuntimeUpdateApplicationFacade`;
  - the UI fixture.

  Eight files are byte-identical. Two lose only what needs ArkDeckRuntime:
  - `UpdateLogging.swift` keeps `AutoUpdateLogEvent`, `AutoUpdateEventLogging` and
    `NoOpAutoUpdateEventLogger`. It loses `SystemAutoUpdateEventLogger` and its
    `import ArkDeckRuntime`.
  - `AutoUpdateService.swift` keeps the service and
    `AutoUpdateApplicationFacade.currentProductIdentity`. It loses `make()` and its
    `import ArkDeckRuntime`.
- `Sources/ArkDeckWorkflows/AutoUpdate/AutoUpdateProductionAssembly.swift` holds those two,
  moved verbatim.
  - `make()` is now an extension of ClientKit's `AutoUpdateApplicationFacade`, so every call
    site still reads `AutoUpdateApplicationFacade.make()`: the App's composition root and
    `CLIRuntimeUpdate.swift`.
  - `make()` reaches the stores, streamer, validator and preferences through their existing
    `public` and `package` declarations. No access level changes.
- The moved code imports only Foundation, Darwin, Security, CryptoKit and ArkDeckCore. Importing
  Security autolinks the framework, as it already does for the Keychain code moved in #2044, so
  the ClientKit target needs no linker setting.
- Other users need no change. Workflows' `ViewerUIFixture.swift` uses `AutoUpdateUIFixture` and
  already imports ClientKit. The App's `ArkDeckApp.swift` imports both modules.
  `DeviceCandidatesContractTests` checks the App source for the text
  `AutoUpdateApplicationFacade.make()`, which is unchanged.

## Behaviour

Nothing changes. The persisted file names, the Application Support paths, the UserDefaults key,
the feed trust pin, the allowed network hosts and the diagnostic event mapping are all literals.
They moved verbatim.

## Tests

- `AutoUpdateContractTests` moves to `ArkDeckClientKitTests` and now uses
  `@testable import ArkDeckClientKit`. It loses one test. Its source checks now read
  `Sources/ArkDeckClientKit/AutoUpdate/UpdateFeed.swift` and scan both AutoUpdate folders for
  private-key material.
- The test it loses, the diagnostics test, needs `SystemAutoUpdateEventLogger` and
  ArkDeckRuntime's `SystemLogger`. It stays in ContractTests as
  `AutoUpdateDiagnosticsContractTests`.
- `RuntimeUpdateStateStoreContractTests` moves to `ArkDeckClientKitTests`. It uses only ClientKit
  types.
- `CLIRuntimeUpdateContractTests` and `OwnerLockSpawnWindowContractTests` add
  `@testable import ArkDeckClientKit`.

## Local targeted checks

These ran on this change over `71660181`, #2048's head, before the check sections were written.
The rebase onto `0ae927d1` replayed without conflict. No path this slice touches, old or new,
differs between the two bases. The three Swift files changed between them name no moved type. The
full local unified gate is not run (AGENTS.md "验证与完成"); the PR's CI is the gate and runs on the
rebased head.

| Check | Command | Result |
| --- | --- | --- |
| Swift, the affected classes | `sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --filter 'AutoUpdateContractTests\|RuntimeUpdateStateStoreContractTests\|AutoUpdateDiagnosticsContractTests\|CLIRuntimeUpdateContractTests\|OwnerLockSpawnWindowContractTests\|DeviceCandidatesContractTests\|ArchitectureBoundaryContractTests\|ArkDeckContractTests\.ArkDeckContractTests/\|CLICommandRegistryCoverageContractTests'` | r1 exit 0, compiling on the first run. 84 passed and 0 failed. One test was skipped: `DeviceCandidatesContractTests.testRealRuntimePublishesConnectedDeviceInformationWithinStartupBudget`, the opt-in real-device latency acceptance, which needs `ARKDECK_REAL_DEVICE_CANDIDATE_LATENCY_ACCEPTANCE=1`. Counts by class: ClientKitTests `AutoUpdateContractTests` 23 and `RuntimeUpdateStateStoreContractTests` 5; ContractTests `ArchitectureBoundaryContractTests` 15, `ArkDeckContractTests` 4, `AutoUpdateDiagnosticsContractTests` 1, `CLICommandRegistryCoverageContractTests` 16, `CLIRuntimeUpdateContractTests` 4, `DeviceCandidatesContractTests` 11 and `OwnerLockSpawnWindowContractTests` 5. The run builds every test target of the package, the CLI among them. No warning names a changed file. Log `/private/tmp/claude-501/-Users-fuhanfeng-Dropbox-Code-Github-ArkDeck--claude-worktrees-blissful-goldstine-c7d922/26822f74-e8f8-4647-9226-2234ed41e115/scratchpad/logs/au-swift-r1.log`, SHA-256 `ae34ceafb613903e8e38e4c61f39b153404c73271009f3af0bb017f6357e52a9` |
| App build-for-testing | `sh scripts/ci/run-xcodebuild.sh` | exit 0, `** TEST BUILD SUCCEEDED **` for the App and its UI runner. The App's composition root compiles against the updater types in ClientKit and `make()` in Workflows. No warning names a changed file. Log `/private/tmp/claude-501/-Users-fuhanfeng-Dropbox-Code-Github-ArkDeck--claude-worktrees-blissful-goldstine-c7d922/26822f74-e8f8-4647-9226-2234ed41e115/scratchpad/logs/au-app-build-r1.log`, SHA-256 `d4b9d69ff3acbbdb01809c1c3e5f4ac9cbe7b6e3e0900afda7d8989d01df66ae` |
| SDD | `sh scripts/check-sdd.sh` | exit 0: 0 errors, 0 warnings |

## CI

Recorded by the next slice, because a green head is merged without an amend. The Overview
projections slice's CI (#2048) is recorded in its own run record by this commit.

## Not run

- The Settings update UI walks through `run-ui-tests.sh`. The App build-for-testing compiles the
  App and its UI runner.
- A live update feed, download or Finder hand-off, and signed standalone App acceptance.
