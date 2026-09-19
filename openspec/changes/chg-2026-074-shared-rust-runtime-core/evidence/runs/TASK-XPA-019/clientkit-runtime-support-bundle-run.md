# Runtime support bundle contract ClientKit extraction

Base: protected main `6592bcce`, which includes the AutoUpdate slice (#2054, merged as
`090a5026`). TASK-XPA-019 / SPK-8 remain incomplete. This slice moves ownership only.

This is the second of the three subsystems the App and the Swift CLI share. The coordination
session ordered them by how little they depend on Workflows internals. The first, AutoUpdate
(#2054), brought the transitional CLI → ClientKit edge, and this slice uses it.

## Acceptance: App files that stop importing `ArkDeckWorkflows`

| | On `6592bcce` | At this head |
| --- | --- | --- |
| ArkDeckApp files importing `ArkDeckWorkflows` | 16 | 16 |

No App file is freed. No App file names these types. Since #2036 the App's Settings screen has
exported through ClientKit's `SettingsDiagnosticBundleExporting`. The composition root composes
Workflows' `RuntimeSupportBundleSettingsExporter` into that protocol.

## What moved and what stayed

- `Sources/ArkDeckClientKit/RuntimeSupportBundleContract.swift` holds the contract, moved verbatim
  out of `Sources/ArkDeckWorkflows/Settings/RuntimeSupportBundleApplicationFacade.swift` with its
  doc comment:
  - `RuntimeSupportBundlePreview`;
  - `RuntimeSupportBundleExportReceipt`;
  - `RuntimeSupportBundleServiceError`;
  - `RuntimeSupportBundleProviding`.

  They need only Foundation.
- The Workflows file keeps its name. It holds `RuntimeSupportBundleApplicationFacade.make()` and
  the private `ProductionRuntimeSupportBundleProvider`. That provider reads this Mac's files
  through ArkDeckStorage's `LocalDiagnosticBundleExporter`, which ClientKit may not import. The
  file now imports ClientKit, and a header comment says where the contract went.
- `ArkDeckRuntimeCommands.swift` (the CLI's `runRuntimeSupportBundle`) imports ClientKit over the
  edge #2054 added. `RuntimeSupportBundleSettingsExporter.swift` in Workflows already imported it.
- `docs/ArchitectureRules.md` records the split. The AutoUpdate paragraph now names
  `RuntimeWorkspaceContinuation` as the edge's only remaining future user.
- No dependency edge, `Package.swift`, access level or Xcode project changes.

## Behaviour

Nothing changes. The two schema version strings, `arkdeck.runtime-support-bundle-preview/1` and
`arkdeck.runtime-support-bundle-export/1`, are literals and moved verbatim. No encoded form
names a module.

## Tests

- `RuntimeSupportBundleApplicationContractTests` stays in ContractTests and imports ClientKit. It
  drives `RuntimeSupportBundleApplicationFacade.make()` and the built `arkdeck` executable.
- `SettingsApplicationFacadeContractTests` in ContractTests reads the Workflows file's source. It
  checks for `trigger: .userInitiated`, `recentSessions: []`, `path: .redacted` and
  `serverEndpoint: .redacted`, all of which are in the provider that stays. It is unchanged.

## Local targeted checks

These ran on this change over `ac73ffaa`, #2054's head, before the check sections were written.
The rebase onto `6592bcce` replayed without conflict. No path this slice touches differs between
the two bases, and no Swift file changed between them. The full local unified gate is not run
(AGENTS.md "验证与完成"); the PR's CI is the gate and runs on the rebased head.

| Check | Command | Result |
| --- | --- | --- |
| Swift, the affected classes | `sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --filter 'RuntimeSupportBundleApplicationContractTests\|SettingsApplicationFacadeContractTests\|SettingsStorageUIFixtureContractTests\|ArchitectureBoundaryContractTests\|ArkDeckContractTests\.ArkDeckContractTests/\|CLICommandRegistryCoverageContractTests'` | r1 exit 0. 49 passed and 0 failed. Counts by class: ClientKitTests `SettingsApplicationFacadeContractTests` 4; ContractTests `ArchitectureBoundaryContractTests` 15, `ArkDeckContractTests` 4, `CLICommandRegistryCoverageContractTests` 16, `RuntimeSupportBundleApplicationContractTests` 3 (the provider and the built `arkdeck` executable), `SettingsApplicationFacadeContractTests` 3 and `SettingsStorageUIFixtureContractTests` 4. The run builds every test target of the package, the CLI among them. The only warnings on a changed file are `ArkDeckRuntimeCommands.swift`'s existing "variable was never mutated" warnings. They appear in the AutoUpdate slice's run too, one line earlier, because this slice adds one import line. Log `/private/tmp/claude-501/-Users-fuhanfeng-Dropbox-Code-Github-ArkDeck--claude-worktrees-blissful-goldstine-c7d922/26822f74-e8f8-4647-9226-2234ed41e115/scratchpad/logs/rsb-swift-r1.log`, SHA-256 `d783ccef57612ed4a620255ae517d9fb808c1060c08541dd36ebf7be3b31bc5d` |
| SDD | `sh scripts/check-sdd.sh` | exit 0: 0 errors, 0 warnings |

## CI

Recorded by the next slice, because a green head is merged without an amend. The AutoUpdate
slice's CI (#2054) is recorded in its own run record by this commit.

## Not run

- The Settings diagnostics UI walk through `run-ui-tests.sh`, and the App build-for-testing. No
  App or UI-runner source names a moved type, and the PR's `app-build` job builds both.
