# Workspace continuation ClientKit extraction

Base: protected main `28d2016c`, which includes the sink slice (#2058, merged as `293ff532`), its
follow-up fix (#2062, merged as `30a0c85f`) and the runtime support bundle slice (#2057, merged as
`da614a2b`). TASK-XPA-019 / SPK-8 remain incomplete. This slice moves ownership only.

This is the second of the two slices that option 1 of the coordination session's ruling calls for.
The first, #2058, moved the v2 request contract from ArkDeckRuntime to ArkDeckCore. That was the
only thing keeping `RuntimeWorkspaceContinuation` out of ClientKit. This is also the last of the
three subsystems the App and the Swift CLI share, after AutoUpdate (#2054) and the runtime support
bundle (#2057).

## Acceptance: App files that stop importing `ArkDeckWorkflows`

| | On `28d2016c` | At this head |
| --- | --- | --- |
| ArkDeckApp files importing `ArkDeckWorkflows` | 16 | 15 |

- `ArkDeckApp/Features/Overview/OverviewResumeSheet.swift` drops the import. It prepares the
  continuation, shows its failures and makes its own provider with
  `RuntimeContinuationApplicationFacade.make()`, all now in ClientKit, which it already imported.
- `ArkDeckApp.swift` names `RuntimeWorkspaceContinuation` too. It keeps importing Workflows for
  the facades still there.

## What moved

- `Sources/ArkDeckClientKit/RuntimeWorkspaceContinuation.swift` is the former Workflows file,
  renamed. Only two imports change: `import ArkDeckClientKit`, which would now be a self-import,
  and `import ArkDeckRuntime`, which it no longer needs, both go. The file holds:
  - `RuntimeWorkspaceContinuation`: the draft, `prepare`, `request` and `inputsMatchCatalog`;
  - `RuntimeContinuationFailure`;
  - `RuntimeContinuationApplicationProviding`;
  - `RuntimeContinuationApplicationFacade.make()` and its UI-test fixture;
  - the `RuntimeContinuationXPCProvider` actor.
- Every type it names is now in ClientKit or Core:
  - from Core, the v2 request DTOs (since #2058), the Catalog and effect resolver, `JobState`,
    `JSONValue` and the canonical encoders;
  - from ClientKit, the History presentations, `OverviewRunRecordProjection`, the workspace kind
    projection, the Job detail reader and the XPC transport.
- The CLI's `CLIWorkspaceContinuation.swift` calls the package-level `inputsMatchCatalog`. It
  imports ClientKit over the transitional edge from #2054.
- No dependency edge, `Package.swift`, access level or Xcode project changes.
  `docs/ArchitectureRules.md` records the move. In the AutoUpdate paragraph, #2057's sentence
  said the continuation would use the edge later. It now says the support bundle export and the
  continuation both use it.
- Some documents name the old path, and they stay as written, since they are history:
  - the dated implementation audit, `docs/design/implementation-audit-2026-08-27.md`;
  - the v1.6 follow-up verification summary;
  - CHG-2026-075's task list.

## Behaviour

Nothing changes. The file is byte-identical apart from its imports. The request it builds is the
same: the same identifiers, the same `continue-ui-` idempotency key, the same provenance keys and
the same client name `arkdeck-overview-continuation`.

## Tests

`OverviewRunRecordContractTests` moves to `ArkDeckClientKitTests`, with its imports tidied into
one `@testable import ArkDeckClientKit`. It stayed in ContractTests in #2048 only because it
exercises the continuation and its XPC provider, which lived in Workflows. It needs nothing
else.

## Local targeted checks

These ran on this change stacked on the sink slice's first head, `77bb4a6c`, before the check
sections were written. The slice was then rebased twice, onto `c3870c3d` and onto `28d2016c`,
both without conflict. Among this slice's paths, only `docs/ArchitectureRules.md` differs
between `77bb4a6c` and `28d2016c`: #2057's paragraph, whose continuation sentence this slice
updates. None of the Swift files changed on main between them names a continuation type, and
no fixture or recorded text names the `ArkDeckWorkflows` module, which is what #2058 was caught
by. The full local unified gate is not run (AGENTS.md "验证与完成"); the PR's CI is the gate and
runs the full Swift suite on the rebased head.

| Check | Command | Result |
| --- | --- | --- |
| Swift, the affected classes | `sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --filter 'OverviewRunRecordContractTests\|CLIWorkspaceContinuationContractTests\|ArchitectureBoundaryContractTests\|ArkDeckContractTests\.ArkDeckContractTests/'` | r1 exit 0. 42 passed and 0 failed. ClientKitTests `OverviewRunRecordContractTests` 16 includes the continuation's XPC provider tests, now against ClientKit. ContractTests: `ArchitectureBoundaryContractTests` 16 (the per-file import matrix), `ArkDeckContractTests` 4 (the App's allowed imports) and `CLIWorkspaceContinuationContractTests` 6. The run builds every test target of the package, the CLI among them. No warning names a changed file. Log `/private/tmp/claude-501/-Users-fuhanfeng-Dropbox-Code-Github-ArkDeck--claude-worktrees-blissful-goldstine-c7d922/26822f74-e8f8-4647-9226-2234ed41e115/scratchpad/logs/rwc-swift-r1.log`, SHA-256 `e960d8370597fa2cf5f0b7cf0e434d8c38f4d7dc2a42b9d3acad71f16b24b9b4` |
| App build-for-testing | `sh scripts/ci/run-xcodebuild.sh` | exit 0, `** TEST BUILD SUCCEEDED **` for the App and its UI runner. `OverviewResumeSheet.swift` compiles without Workflows. No warning names a changed file. Log `/private/tmp/claude-501/-Users-fuhanfeng-Dropbox-Code-Github-ArkDeck--claude-worktrees-blissful-goldstine-c7d922/26822f74-e8f8-4647-9226-2234ed41e115/scratchpad/logs/rwc-app-build-r1.log`, SHA-256 `e0d9efd33415791072d89cb5e3d13959da797ed71516fa7dce20a6a5cd764456` |
| SDD | `sh scripts/check-sdd.sh` | exit 0: 0 errors, 0 warnings |

## CI

PR #2067, merged as `42d1fb97`. On head `79553ba9` (base `28d2016c`) every check passed:

| Workflow run | Jobs | Conclusion |
| --- | --- | --- |
| Swift CI `35495975327` | `plan`, `swift-tests`, `app-build`, `ds-interactions` and the required `swift` aggregate; `rust-checks` skipped, as the plan selected no Rust lane | success |
| SDD Guard `35495975250` | the required `guard`, `ds-tokens` | success |
| Agent PR `35495975236` | `open-pr` | success |

This was also the first full Swift suite to run on a base that carried #2062, the fix for the
failure #2058 left on main, so it confirmed main was green again.

A green head is merged without an amend, so the Device control slice records this section. This
slice's commit recorded, in their own run records: the runtime support bundle slice's CI (#2057),
and the message fix's CI (#2062) with the local Swift result that its own push could not wait for.

## Not run

- The Overview resume sheet walk through `run-ui-tests.sh`. The App build-for-testing compiles the
  App and its UI runner.
