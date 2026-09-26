# Device → Debug → History / Job Inspector UI follow-up

Presentation-only follow-up on `bb3b5531c`. No Runtime, ClientKit, Catalog,
transport, packaging, installation, or device mutation changes.

## Implemented

- Inspector observes the full selected Job summary, not only its ID. A completed
  History refresh invalidates its detail even when the summary is unchanged.
  Refresh reads the detail after the list returns, rather than racing the list.
  The native list's initial/fallback selection matches the displayed record.
- Published logs with privacy other than `standard` cannot invoke a no-op preview
  button. Existing History is the destination for sensitive artifacts. Log reads
  expose progress; an unavailable Artifact list exposes its reported reason.
- Device's wide Inspector scrolls as a whole, including recording results, logs,
  and performance guidance. The narrow layout retains one page scroll. Long
  device labels have full help text and cannot compress the screenshot button.
- Debug keeps the selected target in scene storage across workspace navigation.
  Initial/changed selection is handed to the App model; shell refreshes probe that
  target rather than the facade's first-target fallback. Initial empty and failed
  target reads preserve selection. A changed target supersedes an in-flight
  refresh; only the current request can publish its result. Prior operation
  completions cannot retarget the visible probe. Exact History context still applies.
- Updated the affected design mirror, including the obsolete statement that the
  Inspector did not yet support log reads or cancellation requests.

## Local targeted checks

- `ARKDECK_XCODE_CACHE_ROOT=/private/tmp/arkdeck-device-debug-build ARKDECK_XCODE_JOBS=2 sh scripts/ci/run-xcodebuild.sh`: exit 0.
  Log: `/private/tmp/arkdeck-device-debug-build.log`.
- Final incremental `ARKDECK_UI_TEST_DERIVED_DATA=/private/tmp/arkdeck-device-debug-build/DerivedData sh scripts/ci/run-ui-tests.sh --build-once`: exit 0.
  Log: `/private/tmp/arkdeck-device-debug-final-build.log`.
- `DebugWorkspaceRefreshStateTests`: 3 executed, 0 failures, exit 0. The exact App
  helper and test source were compiled with `xcrun swiftc`, Xcode's XCTest include,
  framework/library paths, and a temporary `defaultTestSuite.run()` entry point.
  This does not launch the App or depend on automation mode. It checks B → leave →
  return, initial/failed reads, and a late A response after selection changes to B.
  Log: `/private/tmp/arkdeck-debug-selection-tests.log`;
  runner entry point: `/private/tmp/arkdeck-debug-selection-tests/main.swift`.
- `cargo fmt --all --check --manifest-path rust/Cargo.toml`: exit 0.
  Log: `/private/tmp/arkdeck-device-debug-fmt.log`.
- `sh scripts/check-sdd.sh`: exit 0; 0 errors, 0 warnings.
  Log: `/private/tmp/arkdeck-device-debug-sdd.log`.
- UI test selection (same independent DerivedData):
  `AppShellUITests/testInspectorReloadsAfterHistoryRefreshInBothLanguages`,
  `testHistoryAndJobSelectionSurviveInspectorToggle`, and
  `testGlobalCancellationFixtureRefusesWithoutChangingTheJobOutcome`.
  Signed build completed. Initial runner initialization timed out while enabling
  automation mode, before any test case. The one permitted `--no-build` retry
  failed identically. Both invocations exited 65; zero UI assertions ran.
  Result bundles are under `/private/tmp/arkdeck-device-debug-build/DerivedData/Logs/Test/`
  (`19-45-46` initial and `19-48-40` retry on 2026-09-26).
  Logs: `/private/tmp/arkdeck-device-debug-ui.log` and
  `/private/tmp/arkdeck-device-debug-ui-retry.log`.
- New UI regression covers History refresh → explicit log reread → exact History
  record, English/light and Chinese/dark, and Device/Debug at 1180×600 and 900×600.
  This is fixture presentation coverage, not hardware or migration acceptance.
- Design reference capture attempted from
  `prototype.html?reference=1&page=device-control&lang=en`. The browser rendered
  its accessibility tree, but screenshot capture repeatedly timed out, including
  after resetting the viewport. New reference images are not available; do not
  mistake old references or unexecuted assertions for visual verification.

## CI

PR and CI results will be recorded after push. No local full unified gate was run.
SwiftPM sources were not changed; no unrelated package test classes were run.

## Remaining boundaries

Recovery rebind/archive remain without App RPC wiring, as documented in the
existing UX spec. This patch does not add recovery authority or manufacture
outcomes. A cancelled/refused request remains separate from the Runtime's
reported Job state. UI automation/visual evidence must be reported independently
of the successful compiler checks.
