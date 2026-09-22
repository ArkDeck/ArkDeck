# Flash plan accessibility crash

TASK-XPA-019 / CHG-2026-074. An App integration defect found while validating the
ClientKit Flash migration; this fix is independent of Runtime implementation.

## Reproduction and change

The unchanged App sources on protected main `e5d8b69183f77820ce889fe51b459e931d78a16a`
reproduced the same crash as the migration branch: expanding a fixture Flash plan
and querying the refresh action caused an EXC_BAD_ACCESS stack overflow through
SwiftUI AccessibilityNode.accessibilityLabel and AppKit AX attribute lookup.
The baseline ran in `/private/tmp/arkdeck-e190-flash-ui-baseline` with separate
DerivedData `/private/tmp/arkdeck-e190-ui-baseline`. The baseline failure log is
`/private/tmp/arkdeck-e190-flash-ui-baseline.log` (exit 65).

The isolated production change removes the redundant accessibilityLabel override
from WorkspaceFactRow's selectable, visually elided Text. The key/value GridRow,
full underlying Text, selection, truncation and hover tooltip remain unchanged.
Native selectable Text exposes its complete content as AX value, not AX label.
The existing bilingual Flash test retains every availability/refresh assertion
and additionally checks the localized hash field name plus the exact 64-character
native AX value. No control is hidden and no timeout or failure threshold changes.

The source diff from that baseline to current main
`fcfa9893e3350a3215386818686d9bc950436c04` contains no App, UI-test or Swift package
changes (only an independent Rust CLI slice). The fix branch is based on that
current main. The UI wrapper resolved its allowed swift-asn1 dependency to 1.7.3
in the baseline build; that incidental lock-file rewrite is not part of this PR.
Both failing and corrected baseline runs used the same resolved dependency set.

## Local targeted checks

`ARKDECK_UI_TEST_DERIVED_DATA=/private/tmp/arkdeck-e190-ui-baseline sh
scripts/ci/run-ui-tests.sh -clonedSourcePackagesDirPath
/private/tmp/arkdeck-e190-ui/SourcePackages
-only-testing:ArkDeckHDCUITests/AppShellUITests/testFlashAvailabilityRefreshBlocksACachedPlanInBothLanguages`

Final name/value and existing bilingual interaction validation passed: exit 0,
1 test (both languages), `/private/tmp/arkdeck-e190-flash-ui-ax-final.log`.
`sh scripts/check-sdd.sh` passed, exit 0, `/private/tmp/arkdeck-e190-flash-ax-sdd.log`.
The preceding exact native-value run passed (exit 0),
`/private/tmp/arkdeck-e190-flash-ui-baseline-fixed-final.log`.
The wrapper built the App and UI runner and drove the real App with presentation
fixtures. This is not signed Rust Mach, hardware or recovery acceptance.
VoiceOver speech and keyboard-only traversal were not separately exercised.

## CI

Pending the independent fix PR, required guard/swift checks and maintainer review.
