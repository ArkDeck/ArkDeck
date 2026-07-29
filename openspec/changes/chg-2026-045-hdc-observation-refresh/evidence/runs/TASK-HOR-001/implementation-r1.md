# TASK-HOR-001 implementation run r1

Date: 2026-07-29

Classification: contract + signed macOS fixture implementation evidence. This
is not installed-HDC evidence or `realHardware` evidence.

## Verdict

The implementation revision containing this record satisfies the executable
checks for `HOR-UI-001`, `HOR-SESSION-001`, `HOR-BOUNDED-001` and
`HOR-SAFETY-001`. The signed UI suite passed 16/16 and the final ArkDeckKit
suite passed 509 tests with one intentional manual sleep/wake skip and zero
unexpected failures.

This record does not change `TASK-HOR-001` from `ready`, mark the change
verified or replace maintainer review. Those state transitions remain
separate PRs.

## Trust and implementation identity

- Readiness PR #770 exact head
  `7a1c4222a241bb1d3b25f57b549d2e5820df614f` was approved by maintainer
  `lvye` and merged at `2026-07-29T01:37:57Z` as protected-main OID
  `333eec928cbbd7f273abffeebb3970f15ed33554`.
- This implementation branch was created from that exact OID. Before
  implementation, local `origin/main` and the authenticated GitHub
  protected-main API both reported the same OID and the complete open-PR
  query returned `[]`.
- Immediately before commit, protected main advanced to
  `2e1fe11e0c5860599bde03448a1f48d9ee596b80` through the unrelated
  `TASK-BRC-003` readiness PR #771. Its two changed paths are confined to
  CHG-2026-036 tasks/evidence and do not overlap this task. The branch was
  fast-forwarded to that exact OID with the implementation diff preserved;
  the current open-PR query again returned `[]`.
- The six implementation blobs in this run are:

  ```text
  57d45bf03f314f21ea1b91898eb876ea708ce0f9  ArkDeckApp/App/ArkDeckApp.swift
  4841248c51347ba5332c9f0139c53f07df8dcf45  ArkDeckApp/Features/HDC/HDCStatusView.swift
  038ce1067f17b6c857d80508b13dcd3cefef0647  ArkDeckApp/Resources/Localizable.xcstrings
  9e09c41e01ee683981a717e2b2e8deda0b5e0edd  ArkDeckAppUITests/HDC/HDCStatusUITests.swift
  d4fda35b8040ada790bfe0c1990d3346978ea169  Packages/ArkDeckKit/Sources/ArkDeckWorkflows/HDCApplicationDiagnosticsFacade.swift
  daf0d88830be9b5a73e877e019a77deef908bbd1  Packages/ArkDeckKit/Tests/ArkDeckContractTests/HDCDeviceObservationPresentationContractTests.swift
  ```

## Implemented route

- `ArkDeckApp` passes the existing view-model refresh method and read-only
  in-flight state into `HDCStatusView`.
- The HDC diagnostics group exposes exactly one localized refresh button with
  accessibility identifier `hdc.devices.refresh` and Command-R activation.
- `HDCStatusViewModel.refresh()` synchronously rejects an in-flight request,
  marks the accepted request in flight before creating async work, calls the
  provider exactly once and clears the state on completion. Refresh and
  executable reselection remain disabled for that interval.
- The production provider protocol and production OpenHarmony composition are
  unchanged. The retained application session still owns the equal
  candidate/endpoint/execution-session key, capacity-64 buffer and one
  registered `list targets -v` observation per accepted refresh.
- Sequential values, a ten-second duplicate-action window and call counters
  exist only in the private UI fixture actor below its explicit boundary.

## Acceptance evidence

### `HOR-UI-001`

The signed macOS UI suite locates `hdc.devices.refresh` and verifies:

- English displays `Refresh Devices` and mouse activation advances the
  deterministic presentation;
- Simplified Chinese displays `刷新设备` and Command-R reaches the same
  callback;
- accessibility lookup reaches the one visible control;
- startup shows the first `appeared` event and one accepted refresh adds the
  second `disappeared` event.

Result: PASS, signed UI 16/16.

### `HOR-SESSION-001`

The sequential presentation contract drives the same fixture session from a
connected snapshot to an all-offline snapshot. It observes ordered
`appeared`, then `disappeared`, while candidate canonical identity, endpoint,
execution-session identity, session pseudonym and the capacity-64 buffer are
retained. Source audits confirm the production root still performs one
discovery/bootstrap and owns one registered source/session route.

Result: PASS, contract.

### `HOR-BOUNDED-001`

The App source contract proves synchronous admission precedes the async task
and that each accepted action contains one provider call. In the signed
fixture, the accepted refresh disables both refresh and executable selection;
a second button/Command-R attempt during the ten-second delay produces no
third `observationUnknown` marker. Both controls re-enable only after the
second presentation is complete. Static audits reject a production timer,
sleep, navigation poll, retry or queue.

Two transient mutations were run and restored:

1. Replacing App composition with `onRefresh: nil` made
   `testHOR2_AppWiringHasSynchronousSingleCallAdmissionAndNoQueue` fail
   1/1 because the callback occurrence changed from one to zero.
2. Reversing the view-model admission guard made the same test fail 1/1
   because the required guard/set/task ordering was broken.

The restored final test passed 1/1.

Result: PASS, platform + contract.

### `HOR-SAFETY-001`

`git diff --quiet` reported zero for every forbidden family and for the
additional pinned package/provider/fixture/change inputs. `git ls-tree HEAD`
matched every readiness pin required to remain immutable, including
Constitution/project/enforcement, verification policy, current
proposal/design/verification/acceptance, living specs, macOS/OpenHarmony
profiles and registries, Xcode project and scheme, ArkDeckOpenHarmony
production sources, package manifest, participant registry, fake HDC source,
scripts and workflows. The six readiness-pinned implementation files changed
only within their allowed task scope and have their new blobs recorded above.

The only Workflows diff begins inside
`private actor HDCFixtureApplicationDiagnostics`; the public provider and
production section have zero diff. The tracked implementation diff contains
only the six approved implementation paths plus this evidence file.

Measured forbidden-effect counters:

```text
installed_hdc_child=0
real_device=0
server_lifecycle_dispatch=0
subserver_dispatch=0
authorization_or_adoption=0
binding_or_device_mutation=0
destructive=0
non_loopback_product_network=0
```

Result: PASS, contract/source/blob audit.

## Verification commands

| Command | Result |
| --- | --- |
| `CI=true swift test --package-path Packages/ArkDeckKit --filter HDCDeviceObservationPresentationContractTests` | PASS, 22/22 on final ten-second fixture |
| focused `HDCDeviceObservationRegistryContractTests` | PASS, 15/15 |
| focused `HDCSupervisorObservationRegistryContractTests` | PASS, 9/9 |
| focused `HDCSupervisorObservabilityContractTests` | PASS, 31/31 |
| focused `HDCSupervisorContractTests` | PASS, 55/55 |
| `CI=true swift test --package-path Packages/ArkDeckKit` | PASS, 509 executed, 1 intentional manual sleep/wake skip, 0 failures |
| `xcodebuild -project ArkDeck.xcodeproj -scheme ArkDeck -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/arkdeck-hor-impl.YmdYOr/DerivedData -resultBundlePath /private/tmp/arkdeck-hor-impl.YmdYOr/HORFullUI.xcresult test -only-testing:ArkDeckHDCUITests/HDCStatusUITests` | PASS, signed UI 16/16 |
| `codesign --verify --deep --strict --verbose=2` on the App and UI runner | PASS |
| `xcrun xcstringstool compile --dry-run ArkDeckApp/Resources/Localizable.xcstrings` | PASS, `en` and `zh-Hans` |
| `jq -e . ArkDeckApp/Resources/Localizable.xcstrings` and localization contract | PASS, exact locale values |
| `scripts/check-sdd.sh` | PASS, 0 errors, 0 warnings, 111 IDs |
| shared SDD venv `python scripts/test_check_sdd.py` | PASS, 56/56 |
| `python3 scripts/test_check_pr_paths.py` | PASS, 50/50 |
| `git diff --check` | PASS |

The final full Swift run took 66.083 seconds of test time. Its one skipped
case is the existing opt-in manual production sleep/wake harness and is
unrelated to this change.

## Signed fixture identity

Environment:

```text
macOS 26.6 (25G72), arm64
Xcode 26.6 (17F113)
Apple Swift 6.3.3 (swiftlang-6.3.3.1.3, clang-2100.1.1.101)
```

App:

```text
Identifier=com.arkdeck.desktop
Signature=adhoc
CDHash=5af27911644c8d0698e8b3dedea8aae57b92a6a1
executable sha256=c057d813050bc510ed4364652164bbe7172e46fbab4ce2f21040a7e7552236b7
executable size=14274608
```

UI runner:

```text
Identifier=com.arkdeck.desktop.hdcuitests.xctrunner
Signature=adhoc
CDHash=d8e6eadba2f5e3424e537e0e91d5dd805f36d6c4
executable sha256=178322de9bcb10b244b3ba95c340eeb507492b902eeb4d7351e763d46c35a046
executable size=93232
```

The UI harness used the approved visible hardlink precondition:

```text
source=.build/debug/ArkDeckFakeHDCFixture
temporary link=ArkDeckFakeHDCFixture-M1-006
inode=100488447 (same for source and link)
sha256=fccd9d37cb7301bfbfd33a290f92075db7fb8a7c2ef288443e6e3e1b413f7f88
size=131888
source blob=bd4b0beb792b8a7989930679a28db9b6ec4db42a
```

The digest was unchanged after the UI run. The exact temporary hardlink was
removed and confirmed absent; it was never installed HDC and is not part of
the tracked diff.

The final result bundle summary was:

```text
title=Test - ArkDeck
result=Passed
platform=macOS 26.6 (25G72), arm64
passed=16
failed=0
skipped=0
expectedFailures=0
```

The result bundle remains under `/private/tmp` and is not committed. Host
device identifiers are deliberately excluded from this evidence.

## Setup observations and deviations

- A quarantine attribute inherited by a generated SwiftPM fake caused an
  early fixture launch to terminate before the contract could run. Only the
  generated build product attribute was cleared; no source or product
  behavior changed.
- Two early focused supervisor attempts encountered transient host-load
  pressure in the pre-existing oversized fake-output test. The test passed
  alone, the final focused suite passed 55/55 and the final full suite passed
  with zero failures.
- Early UI attempts were interrupted by a stale `testmanagerd` session and a
  System Settings input-method permission prompt. The prompt was explicitly
  rejected, no permission or system setting was granted, the stale test
  daemon was restarted, and the clean final signed run passed 16/16.
- This host's `plutil` does not accept the JSON string-catalog form. JSON
  parsing, `xcstringstool` compilation and the exact localization contract
  all passed, so no catalog exception is claimed.

There is no scope, provider API, OpenHarmony source, registry/profile,
project/signing, installed-HDC, device or network deviation.
