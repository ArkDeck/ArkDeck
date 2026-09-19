# Overview run record and action projections ClientKit extraction

Base: protected main `f56481d8`, which includes the remote build source slice (#2044, merged as
`fc91f120`). TASK-XPA-019 / SPK-8 remain incomplete. This slice moves ownership only.

The coordination session agreed to take this slice ahead of AutoUpdate. That order follows a
map of the 17 App files still importing `ArkDeckWorkflows`, listing the Workflows source files
each one depends on:
- AutoUpdate and RuntimeSupportBundle are used only by the composition root, so moving them lowers
  the count by nothing. Both also need the CLI → ClientKit edge ruled on the same day, which is
  its own slice.
- `OverviewRecordView.swift` depended on exactly two Workflows files, and both move here.

## Acceptance: App files that stop importing `ArkDeckWorkflows`

| | On `f56481d8` | At this head |
| --- | --- | --- |
| ArkDeckApp files importing `ArkDeckWorkflows` | 17 | 16 |

- `ArkDeckApp/Features/Overview/OverviewRecordView.swift` drops the import. It already imported
  ClientKit.
- `OverviewResumeSheet.swift` still imports Workflows for `RuntimeWorkspaceContinuation`. That
  type needs ArkDeckRuntime and is used by the CLI, so it waits for the CLI → ClientKit edge.

## What moved

- `Sources/ArkDeckClientKit/OverviewRunRecord.swift` and
  `Sources/ArkDeckClientKit/OverviewActionProjection.swift` are the former Workflows files, renamed.
  The only change is dropping their now-self `import ArkDeckClientKit`. They hold
  `OverviewRunRecordProjection`, `OverviewRunThread` and `OverviewRunResumeDisposition` (which runs
  are one line of work and which may be continued), and `OverviewAction` /
  `OverviewActionProjection` (the "start a new one" row). They are read-only projections over
  ClientKit's History and capability models and use no other Workflows type.
- The other consumers already import ClientKit: the App's `ArkDeckApp.swift` and
  `OverviewResumeSheet.swift`, Workflows' `RuntimeWorkspaceContinuation.swift` (it calls
  `OverviewRunRecordProjection.resumeDisposition`), and `OverviewRunRecordContractTests`. The CLI
  names neither type: `RuntimeWorkspaceContinuation`'s public API takes ClientKit's History types.
- No dependency edge, `Package.swift` or Xcode project change. `docs/ArchitectureRules.md` records
  the split.

## Behaviour

None changes. Both files are byte-identical apart from the removed import.

## Tests

`OverviewRunRecordContractTests` stays in ArkDeckContractTests, because it also exercises
`RuntimeWorkspaceContinuation` from Workflows. It already imports both modules.

## Local targeted checks

These ran on this change over `06baec89`, #2044's head, before the check sections were written.
The rebase onto `f56481d8` replayed without conflict. No file this slice touches differs between
the two bases, and nothing merged between them uses the moved types. The full local unified gate
is not run (AGENTS.md "验证与完成"); the PR's CI is the gate and runs on the rebased head.

| Check | Command | Result |
| --- | --- | --- |
| Swift, the affected classes | `sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --filter 'OverviewRunRecordContractTests\|ArchitectureBoundaryContractTests\|ArkDeckContractTests\.ArkDeckContractTests/'` | exit 0. 35 passed, 0 failed, all in ContractTests: `OverviewRunRecordContractTests` 16, `ArchitectureBoundaryContractTests` 15 (the manifest and per-file import matrices), `ArkDeckContractTests` 4 (the App's allowed imports among them). The run builds every test target of the package. No warning names a changed file. Log `/private/tmp/claude-501/-Users-fuhanfeng-Dropbox-Code-Github-ArkDeck--claude-worktrees-blissful-goldstine-c7d922/26822f74-e8f8-4647-9226-2234ed41e115/scratchpad/logs/ovp-swift-r1.log`, SHA-256 `da4672918b04f4af3ab2deaa9bc777c72c3d718de2ee2c71bddaba44afcd8327` |
| App build-for-testing | `sh scripts/ci/run-xcodebuild.sh` | exit 0, `** TEST BUILD SUCCEEDED **` for the App and its UI runner. No warning names a changed file. Log `/private/tmp/claude-501/-Users-fuhanfeng-Dropbox-Code-Github-ArkDeck--claude-worktrees-blissful-goldstine-c7d922/26822f74-e8f8-4647-9226-2234ed41e115/scratchpad/logs/ovp-app-build-r1.log`, SHA-256 `d0a45505f452e7004b365947709483b36d43a5e7b350fe0e193dffef5ba3dc53` |
| SDD | `sh scripts/check-sdd.sh` | exit 0: 0 errors, 0 warnings |

## CI

Recorded by the next slice, because a green head is merged without an amend. The remote build
source slice's CI (#2044) is recorded in its own run record by this commit.

## Not run

- The Overview UI suite through `run-ui-tests.sh`. The App build-for-testing compiles the App and
  its UI runner.
