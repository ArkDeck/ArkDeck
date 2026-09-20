# Debug facade ClientKit extraction

Base: protected main `64ff5380`, which includes the Trace slice (#2089, merged as `660c282c`). TASK-XPA-019 / SPK-8 remain incomplete. This slice moves ownership only.

## Acceptance: App files that stop importing `ArkDeckWorkflows`

| | On `64ff5380` | At this head |
| --- | --- | --- |
| ArkDeckApp files importing `ArkDeckWorkflows` | 9 | 8 |

`ArkDeckApp/Features/Debug/DebugWorkspaceView.swift` imports ClientKit instead. It names nineteen
types, all of them from the two files this slice moves whole and the read models it splits out.

Before M5 the task counts as done at zero App files other than the composition root and the two
HDC views, per the coordination session's rulings recorded in the workspace continuation and Trace
slices.

## What moved

| File | Where it goes |
| --- | --- |
| `DebugApplicationFacade.swift` (1661 lines) | ClientKit, whole |
| `AppProductCapabilityRegistry.swift` (229 lines) | ClientKit, whole. It imports no ArkDeck module at all |
| the validator half of `AgentDeviceOperations/NativeDeployment/AppOwnedNativeLibrary.swift` | ClientKit's `NativeLibraryArtifactValidator.swift`: the ABI, the artifact and code-sign facts, the validation error and `NativeLibraryArtifactValidator` |
| four read models of `DeviceProviders/DebugRuntimeProbe.swift` | ClientKit's `DebugRuntimeProbeSnapshot.swift`: `DebugRuntimeCommandTemplate`, `DebugRuntimePortDirection`, `DebugRuntimePortRule` and `DebugRuntimeProbeSnapshot` |

- The facade's only tie to Workflows was the native-library validator, which it calls when the
  operator picks a library file: it reads the file's ELF and code-signature facts before anything
  is submitted. That validator needs only ArkDeckCore, CryptoKit and Foundation, so it moves with
  the facade. What stays in `AppOwnedNativeLibrary.swift` is the deployment half — the restart,
  verification and rollback profiles and the descriptors Workflows' providers lower — which names
  `DeviceProviderError` and `HDCBundleReference`.
- The probe file splits the same way the Trace probe did in #2089, and no further: the
  coordination session asked that `FoundationDebugRuntimeProbe` and the probe types the daemon
  composition uses stay put, because another session is recording `debug.probe` and
  `template.run` frames through them. So `FoundationDebugRuntimeProbe`, `DebugRuntimeProbing` and
  `DebugRuntimeCommandResult` all stay in Workflows. `DebugRuntimeCommandResult` moved in the
  first draft and came back: the facade and the App name it zero times.
  `DebugRuntimeCommandTemplate` could not stay, because the facade names it five times.
- `ArkForgeAuthoritySupport.swift` stays. An earlier file-level map listed it as a Debug
  dependency of the App; the App names nothing from it.
- Imports added, all over edges that already exist: the daemon's
  `RuntimeImportControlHandler.swift`; the CLI's `CLIDebugTemplates.swift` and
  `CLIMachineContracts.swift`; Workflows' `DeviceProviderContract.swift`,
  `DeviceProviderAdapters.swift`, `OpenHarmonyNativeCodeSignHelper.swift` and the probe file.
- No dependency edge, `Package.swift`, access level or Xcode project changes.
  `docs/ArchitectureRules.md` records the split.

## Behaviour

Nothing changes. The two whole-file moves are byte-identical apart from a now-self import, and the
two splits move declarations between files without touching a statement.

## Tests

No test moves. Each of the classes that names a moved type still needs Workflows, the daemon or
the CLI, so they stay where they are and gain `@testable import ArkDeckClientKit`:
`DebugApplicationFacadeContractTests` (which drives `FoundationDebugRuntimeProbe`,
`DebugRuntimeCommandResult` and the read-only probe receipt validation),
`CLIDebugProbeContractTests`, `CLIDebugTemplateContractTests`, `CLIMachineContractTests`,
`DebugTemplateOperationContractTests`, `NativeLibraryDeploymentContractTests` and
`NativeLibraryOracleContractTests`.

`DebugApplicationFacadeContractTests` also reads the facade's source by path; that path now points
at ClientKit. `DebugWindowInventoryJobRunnerContractTests` reads the runner, which stays in
Workflows, so it is unchanged.

The design-system lane reads the facade's source too, and CI found it after the first push:
`docs/design/arkdeck-ds/scripts/workspace-interactions.test.mjs` pulls the five operation
references out of `DebugApplicationFacade.swift` to prove each history revisit opens the right
Debug tab. It now resolves the facade in ClientKit or Workflows, the same way the Swift side has
since #2089. That is the fourth source-path assertion this series has tripped, and the second
outside the Swift test targets.

## Local targeted checks

No Swift run and no App build. The machine was overloaded and the maintainer put every session
into wind-down: the shared build lock had four recordings queued ahead of anything here, so
this slice leaves those to CI. The PR's `swift` lane is the check, and it runs the full suite.

| Check | Command | Result |
| --- | --- | --- |
| Design-system interactions | `node --test scripts/workspace-interactions.test.mjs` in `docs/design/arkdeck-ds` | 70 passed, 0 failed, in 1.6s. It needs no build slot, because `node_modules` was already installed. It covers the `ds-interactions` failure this push fixes |
| SDD | `sh scripts/check-sdd.sh` | exit 0: 0 errors, 0 warnings |

What that leaves unverified locally, and what would catch it: the moved facade and the two splits
compile only in CI's `swift-tests`; `DebugWorkspaceView.swift`'s new import compiles only in CI's
`app-build`. Both are in the required `swift` aggregate.

The static checks that did run here are the ones that need no build: a whole-repo scan for the
moved type names found every file that had to gain an import (the twelve listed above), and a scan
for source-path assertions found `DebugApplicationFacadeContractTests`. Both scans exclude common
framework names, after an earlier version of the scan mistook SwiftUI's `Binding` for a Workflows
type.

## CI

Recorded by the next slice, because a green head is merged without an amend. The Trace slice's
CI (#2089) is recorded in its own run record when that slice's own follow-up lands.

## Not run

- The Debug workspace UI walks through `run-ui-tests.sh`. The App build-for-testing compiles the
  App and its UI runner.
- A device, and a real native library: the validator's opt-in tests need one.
