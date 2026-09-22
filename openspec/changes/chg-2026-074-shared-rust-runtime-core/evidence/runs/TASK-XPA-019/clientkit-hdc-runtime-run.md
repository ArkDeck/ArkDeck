# HDC production presentation through ClientKit

Base: protected main `73eeacc99`. TASK-XPA-019 remains incomplete.

## Delivered behavior

App root, Overview HDC diagnostics and Settings toolchains use the new ClientKit
HDC facade and display-only models. Every production refresh calls
`runtime.hdc.status` through the existing signature-pinned, health-validated
Runtime XPC transport. Rust App ingress gained this method in merged PR #2110.
Legacy local-production/selection flags cannot select a local supervisor or
executable; only the explicit UI fixture flag selects fixture presentation.
Workflows remains available to its other consumers and is not deleted.

A failed refresh clears previous HDC facts. Transport timeout/disconnection,
Runtime refusal, unavailable and unknown observations retain an explicit reason.
Malformed identity/health facts never promote authorization. A stale Connected
candidate cannot become ready. Missing counters, events, channel protection and
ownership evidence remain unknown rather than invented zeros or receipts.

Recovery approval currently requires a Runtime console receipt. The App shows
that this connection cannot approve recovery and exposes no ineffective action.
Tool registration also remains Runtime-owned; no local picker/execution fallback
is composed. Their future controlled interfaces belong to the Runtime task.
Fixture preview/confirmation contains display values only, not authority.

The three legacy App local-supervisor/picker UI tests are replaced with a
production composition assertion that the same legacy flags cannot select a
local tool or recovery. This is the intended CHG-2026-074 ownership transition,
not proof of Runtime tool-registration or recovery acceptance. Existing
Workflows supervisor/bookmark contract coverage and fixture presentation tests
remain. No accepted Core safety assertion is relaxed.

## Local targeted checks

- `ARKDECK_SWIFTPM_CACHE_ROOT=/private/tmp/arkdeck-e190-swift sh
  Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --jobs 2 --filter
  HDCClientDiagnosticsTests`: exit 0, 8 tests;
  `/private/tmp/arkdeck-e190-hdc-client-tests.log`.
- `ARKDECK_XCODE_CACHE_ROOT=/private/tmp/arkdeck-e190-xcode ARKDECK_XCODE_JOBS=2
  sh scripts/ci/run-xcodebuild.sh`: exit 0, TEST BUILD SUCCEEDED;
  `/private/tmp/arkdeck-e190-hdc-app-build.log`.

- `ARKDECK_UI_TEST_DERIVED_DATA=/private/tmp/arkdeck-e190-ui sh
  scripts/ci/run-ui-tests.sh --no-build` selecting HDCStatusUITests methods
  `testEnglishFixtureSweep`, `testProductionLaunchCannotSelectLocalHDCOrRecovery`,
  `testOBSAPP4_AppSourceKeepsPresentationOnlyPackageBoundary`: exit 0, 3 passed;
  `/private/tmp/arkdeck-e190-hdc-ui-retry.log`; result bundle
  `/private/tmp/arkdeck-e190-ui/Logs/Test/Test-ArkDeck-2026.09.22_17-34-03-+0800.xcresult`.
  The first invocation built successfully but exited 65 before tests because
  macOS timed out enabling automation mode. The documented no-build retry
  succeeded; no assertion or timeout was relaxed. First log:
  `/private/tmp/arkdeck-e190-hdc-ui.log`.
- `sh scripts/check-sdd.sh`: exit 0;
  `/private/tmp/arkdeck-e190-hdc-sdd.log`.

The UI run uses ad-hoc test signing and is App presentation evidence only.
No full local gate or
performance measurement is used. Signed pure-Rust Mach integration and real
hardware acceptance are not claimed: the local Developer ID identity is
available, but the fixed Mach service is occupied by the installed Runtime.
That service has not been modified, restarted or replaced. An independent
macOS login/VM with the fixed service free is the outstanding environment need.

## CI

PR #2112 initial Swift run 35711260830 failed the legacy source-construction
scan: the new display-only fixture's inferred `.external` labels were counted
as Runtime ownership constructions. The fixture now spells its distinct
`HDCClientDiagnosticsPresentation.Ownership.external` type explicitly. All
original Runtime construction limits remain unchanged; the scan separately
allows exactly two display constructions in that one explicit fixture.

Local CI reproduction: `run-swiftpm.sh test --jobs 2 --filter
HDCSupervisorObservabilityContractTests`, exit 0, 31 tests;
`/private/tmp/arkdeck-e190-hdc-ci-repro.log`. No full local gate or repeated App/UI
run is needed for the type qualification and scan. Fresh required guard/swift
checks and maintainer review remain necessary on the follow-up head.
