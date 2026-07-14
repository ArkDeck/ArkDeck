# TASK-M0A-001 run record — 2026-07-14

- Evidence class: `platform` (local macOS build and smoke only; no hardware)
- Core baseline: `CORE-1.0.0`
- Scope: `MAC-M0A-SHELL-001`

## Environment

- macOS 26.5.1 (25F80), arm64
- Xcode 26.6 (17F113)
- Swift 6.3.3 (`swiftlang-6.3.3.1.3`, target `arm64-apple-macosx26.0`)

## Work completed

- Added an `ArkDeck` SwiftUI application target that imports only `ArkDeckCore`.
- Added `ArkDeckKit` local Swift package products and targets: `ArkDeckCore`,
  `ArkDeckProcess`, `ArkDeckRuntime`, `ArkDeckOpenHarmony`,
  `ArkDeckWorkflows`, and `ArkDeckStorage`.
- Added separate unit (`ArkDeckCoreTests`) and package-boundary contract
  (`ArkDeckContractTests`) test targets.
- Added an `en` / `zh-Hans` String Catalog skeleton. The UI labels the MVP
  capability as the full term “ArkUI UI Dump”.
- The shell exposes only static navigation and no device workflow or external
  tool dispatch. Source inspection for `Foundation.Process`, `Process(`,
  `/bin/sh`, `hdc`, `erase`, `unlock`, and `destructive` produced no matches.

## Commands and results

| Command | Result |
| --- | --- |
| `swift package describe && swift test --scratch-path /private/tmp/arkdeck-m0a-spm-build` in `Packages/ArkDeckKit` | Passed: all six products and both test targets were resolved; 4 XCTest cases passed with 0 failures. |
| `xcodebuild -project ArkDeck.xcodeproj -scheme ArkDeck -configuration Debug -derivedDataPath /private/tmp/arkdeck-m0a-derived clean build` | Passed: `** BUILD SUCCEEDED **`; local package `ArkDeckKit` resolved as a local dependency. |
| `codesign --verify --deep --strict --verbose=2 /private/tmp/arkdeck-m0a-derived/Build/Products/Debug/ArkDeck.app` | Passed: bundle was valid on disk and satisfied its designated requirement. |
| `codesign --display --verbose=4 --entitlements :- /private/tmp/arkdeck-m0a-derived/Build/Products/Debug/ArkDeck.app` | Confirmed `Identifier=com.arkdeck.desktop`, arm64 app bundle, and `Signature=adhoc` (`Sign to Run Locally`; no TeamIdentifier). Debug entitlement is only `com.apple.security.get-task-allow=true`. |
| `jq --exit-status . ArkDeckApp/Resources/Localizable.xcstrings` | Passed: String Catalog JSON parses. |
| `open -gj /private/tmp/arkdeck-m0a-derived/Build/Products/Debug/ArkDeck.app`; `pgrep -x ArkDeck` | Current-user smoke passed: LaunchServices accepted the bundle and `pgrep` observed PID `75571`. The test instance was terminated with `kill -TERM 75571`; a subsequent process check returned no ArkDeck PID. |

## AC conclusion

`MAC-M0A-SHELL-001` is **pending / not passed**. Clean build, local ad-hoc
signature inspection, package-boundary tests, and a current-user launch smoke
all passed. The required **clean-user** launch smoke has not been performed:
this execution environment did not provide an authorized fresh macOS user, and
creating or altering a host user is outside this task's allowed scope.

This is not Developer ID or distribution evidence. The local Debug signature
and `get-task-allow` entitlement must not be used to make a release, Gatekeeper,
Sandbox, or hardware-support claim; those are handled by later M0A tasks.

## Deviations and residual risk

- No real device, HDC, USB, UART, TCP, Flash, erase, unlock, update, or other
  destructive operation was invoked. Destructive dispatch count is `0` for this
  run.
- The task's `allowed paths` do not include `tasks.md`, so this record does not
  change its task status. A maintainer must arrange the clean-user smoke and
  then update task state through the reviewed change workflow.

## Addendum — 2026-07-14 post-review fixes

Review of this run produced three fixes, re-verified in the same environment:

- `ArkDeckContractTests` now enforces the boundary contract by scanning
  `import` statements in the source tree: package targets may import only the
  ArkDeck modules declared in `Package.swift`, package targets must not import
  UI frameworks, and the app target may import only `ArkDeckCore`. The previous
  hand-written constant comparisons (and the constants themselves) were
  removed. A mutation check (temporary `import SwiftUI` in `ArkDeckStorage`)
  failed the suite as expected and was reverted. `swift test` now executes
  6 XCTest cases with 0 failures.
- A shared scheme was committed at
  `ArkDeck.xcodeproj/xcshareddata/xcschemes/ArkDeck.xcscheme`, so
  `xcodebuild -scheme ArkDeck` no longer depends on Xcode scheme autocreation.
  Committing it exposed a real project defect: the Debug configuration lacked
  `ONLY_ACTIVE_ARCH = YES`, so scheme-driven builds compiled the app for
  arm64 + x86_64 while package dependencies built active-arch only, and the
  x86_64 slice failed with `unable to resolve module dependency: 'ArkDeckCore'`.
  Fixed in the project-level Debug settings. Clean build, `codesign --verify`,
  and the current-user launch smoke were re-run and passed after the fix.
- Note: package test targets cannot be attached to the app scheme's test
  action under `-project` with an `XCLocalSwiftPackageReference` (Xcode
  resolves scheme testable containers against a workspace; a top-level
  `.xcworkspace` would be required). Package tests remain `swift test`, as
  recorded above.

Evidence run records now follow the template added at
`openspec/templates/change/evidence-run.md`. The AC conclusion is unchanged:
`MAC-M0A-SHELL-001` remains pending on the clean-user launch smoke.
