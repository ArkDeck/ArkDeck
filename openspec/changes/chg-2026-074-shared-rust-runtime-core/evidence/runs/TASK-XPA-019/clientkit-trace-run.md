# Trace facade and contracts ClientKit extraction

Base: protected main `7f0650ac`, which includes the diagnostic readers slice (#2080, merged as
`5fec28f3`). TASK-XPA-019 / SPK-8 remain incomplete. This slice moves ownership only.

## Where this leaves TASK-XPA-019's count

The coordination session ruled twice on how the App's Workflows import count ends before M5:
- `ArkDeckApp.swift`, the composition root, may keep the import until M5 handles the production
  `make()` assemblies with the Swift Runtime.
- `HDCStatusView.swift` and `SettingsRootView.swift` are M5 dependencies too. They name
  `HDCDiagnosticsPresentation`, whose 18-type model closure (about 360 lines) is declared in
  ArkDeckOpenHarmony, a target M5 deletes. Sinking it into ArkDeckCore now would leave Core
  holding HDC facts that M5 would have to move again, and a parallel copy in ClientKit was
  refused. At M5 the Rust daemon serves these facts through ClientKit and both files follow.

So before M5 this task counts as done at zero App files other than those three.

## Acceptance: App files that stop importing `ArkDeckWorkflows`

| | On `7f0650ac` | At this head |
| --- | --- | --- |
| ArkDeckApp files importing `ArkDeckWorkflows` | 11 | 9 |

- `ArkDeckApp/Features/Trace/TraceConfigurationView.swift` and `TraceWorkspaceView.swift` import
  ClientKit instead.
- `DiagnosticsWorkspaceViewModel.swift` names `TracePublishedArtifactPolicy` from this facade, but
  keeps the import for the hilog reader that stayed in Workflows in #2080.

## What moved

| File | Where it goes |
| --- | --- |
| `TraceApplicationFacade.swift` (850 lines) | ClientKit: the presentation models, `TraceApplicationProviding`, the facade and its production provider, `TracePublishedArtifactPolicy`, the numeric input validation |
| `TraceCatalogContracts.swift` (63 lines) | ClientKit: `TracePresetID` and the catalog's exact facts |
| `TraceParameterContracts.swift` (34 lines) | ClientKit: `TraceDebugParameterCatalog` |
| the first 96 lines of `DeviceProviders/TraceRuntimeProbe.swift` | ClientKit's new `TraceRuntimeProbeSnapshot.swift`: the probe's five read models |
| `TraceProbeTool` (4 lines) | ArkDeckCore, out of ArkDeckOpenHarmony's `TraceProbeAdapter.swift` |

- The facade had no Workflows dependency at all. Its only tie outside ClientKit and Core was
  `TraceProbeTool.hitrace.rawValue`, in one line that decides whether a capture request is
  eligible. `TraceProbeTool` is a two-case enum. Under `docs/ArchitectureRules.md` §6 example 1 it
  sinks to Core, where the OpenHarmony adapter that probes for the tool and the App facade that
  names it both read the one copy. Copying the string into ClientKit would have been a second
  copy of a device fact.
- The probe file splits where data ends and behaviour begins: the five `Codable` read models move,
  and `TraceRuntimeProbing` with `FoundationTraceRuntimeProbe` stay in Workflows next to the
  device providers and the OpenHarmony adapter they drive.
- The facade drops three imports that are now unnecessary: its own ClientKit, ArkDeckOpenHarmony
  (with `TraceProbeTool` gone to Core) and ArkDeckRuntime (dead since #2058).
- Imports added, all over edges that already exist: Workflows' `RuntimeArtifactService.swift`,
  `RuntimeJobRecord.swift` and `DeviceProviders/TraceRuntimeProbe.swift`, and the tests below.
- No dependency edge, `Package.swift`, access level or Xcode project changes.
  `docs/ArchitectureRules.md` records the split.

## Behaviour

Nothing changes. The moved files keep their bytes apart from import lines, and the two splits move
declarations between files without touching a statement.

## Tests

- `TraceApplicationFacadeContractTests` moves to `ArkDeckClientKitTests`. After the move it names
  no Workflows, Runtime or OpenHarmony type, so it drops the Workflows import. One of its tests
  reads the facade's source by path; that path now points at ClientKit.
- `ViewerTraceDesignSynchronizationContractTests` stays in ContractTests, because it compares the
  App's prototype and localization against the design deck. It already imported ClientKit, and its
  source-path assertion follows the facade too.
- `DiagnosticsAndHAPContractTests` and `RingTraceCaptureContractTests` stay: both drive Workflows'
  providers. The first adds the ClientKit import for the probe read models.
- `TraceAdapterGoldenTests` is unchanged. It drives the OpenHarmony adapter, which keeps
  `TraceProbeAdapterSelection` and now reads `TraceProbeTool` from Core.

## Local targeted checks

These ran on this change over `b183a243`, the diagnostic readers slice's head, which #2080 merged
as `5fec28f3`. The rebase onto `7f0650ac` replayed without conflict. The full local unified gate is not
run (AGENTS.md "验证与完成"); the PR's CI is the gate.

| Check | Command | Result |
| --- | --- | --- |
| Swift, the affected classes | `sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --filter` over the Trace, Diagnostics-and-HAP, ring capture, adapter golden, boundary and layer classes | r2 exit 0: 165 passed, 0 failed — `DiagnosticsAndHAPContractTests` 109, `ArchitectureBoundaryContractTests` 16, `RingTraceCaptureContractTests` 12, `TraceApplicationFacadeContractTests` 12, `TraceAdapterGoldenTests` 8, `ViewerTraceDesignSynchronizationContractTests` 4, `ArkDeckContractTests` 4. r3, after the facade tests moved to ClientKitTests, ran the four affected classes again: 36 passed, 0 failed. Both runs build every test target of the package. No warning names a changed file. Logs `/private/tmp/claude-501/-Users-fuhanfeng-Dropbox-Code-Github-ArkDeck--claude-worktrees-blissful-goldstine-c7d922/26822f74-e8f8-4647-9226-2234ed41e115/scratchpad/logs/trace-swift-r2.log` (SHA-256 `25c5981241bcaa6a0cc857fd1c21c770c73ddc79ea57f4fb2e517e12c17d7c81`) and `/private/tmp/claude-501/-Users-fuhanfeng-Dropbox-Code-Github-ArkDeck--claude-worktrees-blissful-goldstine-c7d922/26822f74-e8f8-4647-9226-2234ed41e115/scratchpad/logs/trace-swift-r3.log` (SHA-256 `89208c767b2c1548c769ef55b218fa6afd6cfa27527ce2bf438ff265661b8c84`) |
| | the same, r1 | Two failures, both source-path assertions that read `Sources/ArkDeckWorkflows/TraceApplicationFacade.swift`. A third one, `RuntimeHistoryApplicationContractTests.testEveryAppWorkspaceUsesTheBoundedRecentSummaryPolicy`, was outside the filter and only the PR's CI caught it: it reads the Debug, Trace and UIDump facades from the Workflows directory by name. It now resolves each of the three in whichever module declares it, so the Debug and UIDump slices will not trip on it again. That fix went out without a local run, at the coordination session's direction: the shared build lock had four recordings queued ahead of it, and a path change is what the PR's `swift` lane checks. This is the third slice in this series caught by a source-path assertion. Log `/private/tmp/claude-501/-Users-fuhanfeng-Dropbox-Code-Github-ArkDeck--claude-worktrees-blissful-goldstine-c7d922/26822f74-e8f8-4647-9226-2234ed41e115/scratchpad/logs/trace-swift-r1.log` |
| App build-for-testing | `sh scripts/ci/run-xcodebuild.sh` | exit 0, `** TEST BUILD SUCCEEDED **` for the App and its UI runner. The two Trace views compile without Workflows. Log `/private/tmp/claude-501/-Users-fuhanfeng-Dropbox-Code-Github-ArkDeck--claude-worktrees-blissful-goldstine-c7d922/26822f74-e8f8-4647-9226-2234ed41e115/scratchpad/logs/trace-app-build-r1.log`, SHA-256 `ca520beb4fd83728c1121a1ad111e19706898ae82134f514335a9db04619a055` |
| SDD | `sh scripts/check-sdd.sh` | exit 0: 0 errors, 0 warnings |

## CI

Recorded by the next slice, because a green head is merged without an amend. The diagnostic
readers slice's CI (#2080) is recorded in its own run record by this commit.

## Not run

- The Trace workspace UI walks through `run-ui-tests.sh`. The App build-for-testing compiles the
  App and its UI runner.
- A device: the probe reads one, and CI has none.
