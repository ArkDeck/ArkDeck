# Diagnostic session readers ClientKit extraction

Base: protected main `62123ea8`, the merge of the device control slice (#2077). TASK-XPA-019 / SPK-8 remain incomplete. This slice moves ownership only.

After the device control slice, twelve App files still imported `ArkDeckWorkflows`. A map of what
each one actually names put the remaining work in two groups:
- subsystems that depend on nothing heavier than Core and ClientKit, which move as they are: the
  diagnostic readers here, and later UIDump, Debug, Flash and the Trace contracts;
- subsystems held by ArkDeckOpenHarmony, which need a decision before anything moves: the HDC
  diagnostics presentation that two App files name, and one probe type inside
  `TraceApplicationFacade`.

A first pass at that map also listed `HDCControlLifecycleAuditStore` as blocking five App files.
It does not: those five name `Binding`, and that file happens to declare a `package struct
Binding` of its own. The scan now excludes framework names and prints a use site for each hit.

This slice takes the first group's cleanest member. It needs no seam.

## Acceptance: App files that stop importing `ArkDeckWorkflows`

| | On `62123ea8` | At this head |
| --- | --- | --- |
| ArkDeckApp files importing `ArkDeckWorkflows` | 12 | 11 |

- `ArkDeckApp/Features/Diagnostics/DiagnosticsWorkspaceView.swift` drops the import. It already
  imported ClientKit.
- `DiagnosticsWorkspaceViewModel.swift` keeps it for `TraceApplicationFacade`, which waits on the
  OpenHarmony probe type, and for the hilog reader that stays in Workflows.

The coordination session ruled on 2026-09-20 how this count ends before M5: the App's composition
root, `ArkDeckApp.swift`, may keep importing Workflows until M5 handles the production `make()`
assemblies with the Swift Runtime. Until then TASK-XPA-019 counts as done at zero App files other
than that root.

## What moved

Three files move from `Sources/ArkDeckWorkflows/` to `Sources/ArkDeckClientKit/`, and a fourth is
split:

| File | What it holds |
| --- | --- |
| `DiagnosticSessionReading.swift` | the session's read model: what a capture recorded, and what it never looked for |
| `DiagnosticSessionApplicationReader.swift` | the App-facing reader over that model |
| `DiagnosticSessionOfflineInspector.swift` | the offline inspection of a session directory |
| `DiagnosticHilogSummaryPresentation.swift` (new, ClientKit) | the verified summary's presentation and load result, moved out of `DiagnosticHilogSummaryReader.swift` |
| `DiagnosticHilogSummaryReader.swift` (stays in Workflows) | the reader itself |

- The three moved files depend on nothing but Foundation, ArkDeckCore and ClientKit. Two drop a
  now-self `import ArkDeckClientKit`; the third is byte-identical.
- The hilog reader could not follow them, and the first run said so: it verifies the summary
  Artifact with `HilogSummaryDerivedAnalyzer.validateReport` and decodes
  `HilogSummaryDerivedArtifact`, both of which live in Workflows' analyzer provider, next to
  `AnalyzerProvider` and its process dispatch. So the file is split where the module boundary
  falls: the presentation and the load result are what the App renders and move to ClientKit;
  the reader stays in Workflows and keeps returning them. Its own imports now name ClientKit, and
  a header comment says why it stayed.
- `DiagnosticHilogSummaryPresentation` gains a `package init`. Its memberwise initializer is
  internal, so the reader could not build it from another module. `package` is the narrowest level
  that works, and it leaves the App-facing surface unchanged: the App only reads these fields.
- Only `DiagnosticsWorkspaceViewModel.swift` calls the reader, and it keeps its Workflows import
  for `TraceApplicationFacade` anyway. `DiagnosticsWorkspaceView.swift` renders the presentation,
  which is why the split frees it.
- The CLI reads sessions too: `CLIDiagnosticsResources.swift` gains `import ArkDeckClientKit` over
  the transitional edge from #2054, and `ArkDeckCLIMain.swift` already had it.
- No dependency edge, `Package.swift` or Xcode project changes. The only access-level addition is
  the `package init` above. `docs/ArchitectureRules.md` records the split.

## Behaviour

Nothing changes. The three moved files keep their bytes apart from two import lines, and the
hilog split moves declarations between files without touching a statement: the reader's logic,
its refusal strings and the presentation's fields are as they were.

## Tests

- `DiagnosticSessionOfflineInspectorContractTests` moves to `ArkDeckClientKitTests` with
  `@testable import ArkDeckClientKit`. It names no Workflows type any more. One of its tests reads
  the App reader's source to prove the App and the CLI call the same owner; that path now points at
  ClientKit.
- `DiagnosticSessionReadingContractTests` stays in ContractTests: it also drives
  `HilogSummaryDerivedAnalyzer`. It already imported ClientKit.
- `CLIDiagnosticsProcessContractTests` stays and adds the ClientKit import. A whole-repo scan for
  the moved type names found only this file and one false positive, a Python `threading.Event()`
  inside a test's embedded script.

## Local targeted checks

These ran on this change over the device control slice's head, `02994729`, which #2077 merged as
`62123ea8`; the rebase onto that merge replayed without conflict. The full local unified gate is
not run (AGENTS.md "验证与完成"); the PR's CI is the gate.

| Check | Command | Result |
| --- | --- | --- |
| Swift, the affected classes | `sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --filter 'DiagnosticSessionOfflineInspectorContractTests\|DiagnosticSessionReadingContractTests\|CLIDiagnosticsProcessContractTests\|ArchitectureBoundaryContractTests\|ArkDeckContractTests\.ArkDeckContractTests/'` | r5 exit 0. 56 passed, 0 failed: ClientKitTests `DiagnosticSessionOfflineInspectorContractTests` 6; ContractTests `ArchitectureBoundaryContractTests` 16, `ArkDeckContractTests` 4, `CLIDiagnosticsProcessContractTests` 1 and `DiagnosticSessionReadingContractTests` 29. The run builds every test target of the package. No warning names a changed file. Log `/private/tmp/claude-501/-Users-fuhanfeng-Dropbox-Code-Github-ArkDeck--claude-worktrees-blissful-goldstine-c7d922/26822f74-e8f8-4647-9226-2234ed41e115/scratchpad/logs/diag-swift-r5.log`, SHA-256 `fcb6733c5f5ce61838999fc5e3fb0da75814db1f35cba3403dd12df6236cdc5d` |
| | the same, r1, r2 and r4 | Three failures, each of which changed this slice. r1: the hilog reader could not compile in ClientKit, because it verifies with the analyzer provider's validator — hence the split. r2: the presentation's memberwise initializer is internal, so the reader could not build it from Workflows — hence the `package init`. r4: `testAppAndCLICallTheSharedOwner` reads the App reader's source by path, which had moved. r3 ran against the tree from before the `package init` landed, because the runner syncs the worktree when it takes the shared build lock, so it repeated r2's failure. Logs `/private/tmp/claude-501/-Users-fuhanfeng-Dropbox-Code-Github-ArkDeck--claude-worktrees-blissful-goldstine-c7d922/26822f74-e8f8-4647-9226-2234ed41e115/scratchpad/logs/diag-swift-r{1,2,3,4}.log` |
| App build-for-testing | `sh scripts/ci/run-xcodebuild.sh` | exit 0, `** TEST BUILD SUCCEEDED **` for the App and its UI runner. `DiagnosticsWorkspaceView.swift` compiles without Workflows. Log `/private/tmp/claude-501/-Users-fuhanfeng-Dropbox-Code-Github-ArkDeck--claude-worktrees-blissful-goldstine-c7d922/26822f74-e8f8-4647-9226-2234ed41e115/scratchpad/logs/diag-app-build-r1.log`, SHA-256 `e9447b5daee2666e7de5b2b893f39c1f24ad589d4a3a2e2d1254ce1572e5c661` |
| SDD | `sh scripts/check-sdd.sh` | exit 0: 0 errors, 0 warnings |

## CI

Recorded by the next slice, because a green head is merged without an amend. The device control
slice's CI (#2077) is recorded in its own run record by this commit.

## Not run

- The Diagnostics workspace UI walk through `run-ui-tests.sh`. The App build-for-testing compiles
  the App and its UI runner.
