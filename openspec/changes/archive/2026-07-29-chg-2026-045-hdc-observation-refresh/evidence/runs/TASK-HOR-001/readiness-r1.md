# TASK-HOR-001 fresh D1 readiness r1

Date: 2026-07-29

Classification: contract + signed macOS fixture readiness. This is not
implementation evidence, installed-HDC evidence or `realHardware` evidence.

## Verdict

`TASK-HOR-001` has a closed implementation route, exact protected-main input
pins, a reproducible signed App test environment and a negative/mutation
matrix. It may become `ready` only when the maintainer reviews and merges this
independent readiness PR. No implementation may start before that merge.

This review claims none of `HOR-UI-001`, `HOR-SESSION-001`,
`HOR-BOUNDED-001` or `HOR-SAFETY-001`. Those AC require same-revision
implementation evidence.

## Trust, approval and concurrency

- Proposal PR #766 exact head
  `4e898ce54b37fafbef776da7c0722a8b728046d5` was approved by maintainer
  `lvye` at `2026-07-29T00:50:04Z` and merged at
  `2026-07-29T00:50:10Z` as
  `7938cf67a2749a8d7ddb3c86b44fd244705d3974`.
- Approval-only PR #768 exact head
  `7441fd4075830f3169e35715da459f01a2d2dede` was approved by maintainer
  `lvye` at `2026-07-29T00:55:52Z` and merged at
  `2026-07-29T00:58:15Z` as
  `f1214137bd80c2544209dcd95ac32a869982ec06`.
- The current proposal blob is `status: approved`; proposal revision 1,
  verification `@r1` and acceptance `change_revision: 1` agree.
- Duplicate approval PR #767, head
  `7a5b996878242829a08444ffa68e0d08fe211388`, was closed unmerged at
  `2026-07-29T00:59:57Z`.
- At the final concurrency audit (`2026-07-29T01:24:57Z`), the complete
  open-PR query returned `[]`. The authenticated GitHub protected-main API
  and local `origin/main` both returned
  `f1214137bd80c2544209dcd95ac32a869982ec06`.
- A final SSH fetch retry was unavailable because the remote closed the SSH
  connection. This did not create an uncertain base: the branch had already
  been created from the fetched `origin/main`, and the authenticated GitHub
  API independently reported the same exact OID after the retry.

The complete structured path/blob pins are in `tasks.md`. The implementation
run must additionally record this readiness PR's merge OID and stop if
protected main or any forbidden input differs from those pins.

## Closed production route

Current protected-main reachability is:

```text
ArkDeckApp.task startup
  → HDCStatusViewModel.refresh()
  → HDCApplicationDiagnosticsProviding.refresh()
  → HDCProductionApplicationDiagnostics.refresh()
  → retained HDCDeviceObservationApplicationSession.refresh()
  → HDCDeviceObservationComposition.pollOnce()
  → one HDCRegisteredDeviceObservationSource.observe()
  → exact registered `list targets -v`
  → retained capacity-64 presentation buffer
```

The implementation is limited to the following route:

1. `ArkDeckApp` passes `HDCStatusViewModel.refresh` and its read-only
   `isRefreshInFlight` state to `HDCStatusView`.
2. `HDCStatusView` renders exactly one localized refresh button with stable
   accessibility identifier `hdc.devices.refresh`. The refresh button and
   executable chooser are disabled while the refresh is in flight.
3. `HDCStatusViewModel.refresh()` performs a synchronous main-actor
   `guard !isRefreshInFlight`, sets the state before creating asynchronous
   work, invokes the provider exactly once, and clears the state on normal,
   failed or cancelled completion while the model still exists.
4. App startup calls that same method; no second startup/manual route exists.
5. `HDCProductionApplicationDiagnostics.refresh()` keeps its existing one
   `attachSessionIfConfigured()`, one provider refresh and one retained device
   session refresh. It performs no second discovery after the bootstrap flag
   is set.
6. The equal
   `(candidateCanonicalIdentity, endpoint, executionSessionIdentity)` key
   retains the existing observation actor and buffer. Executable reselection
   remains the explicit boundary that clears the session.
7. The existing actor-level `refreshIsInFlight` guard remains the inner
   bound. Its production composition internally creates exactly one
   registered source and polls it once.

The public provider protocol already exposes the required async `refresh()`.
It must not change. The App has no candidate, endpoint, execution identity,
runner, argv, receipt, process/socket identity, pseudonym key or generation
construction surface.

## Exact source and safety identity

The byte-pinned production authority remains:

- device observation integration registry
  `OPENHARMONY-HDC-DEVICE-OBSERVATION-PROBES@1.0.0`;
- entry
  `openharmony-hdc-device-observation-snapshot-3.2.0f-macos`;
- integration profile `OPENHARMONY-TOOLS@0.5.0`;
- candidate version `3.2.0f`;
- candidate executable SHA-256
  `05b2bf7ad30201c082da336db28f8856952a2b2f49ac3404b96fdb4bf1a68f83`;
- endpoint `127.0.0.1:8710`;
- argv `["list", "targets", "-v"]`;
- timeout 15,000 ms;
- capacity 64;
- stable identity observation before and after the read-only child;
- per-session HMAC-SHA-256 pseudonyms truncated to the public
  `redacted-device-<24 hex>` shape.

Wrong hash, endpoint, listener identity, process result, timeout,
cancellation or identity drift remains unavailable/unknown and provides no
fallback command or mutation. The App refresh route does not add server
start/stop/restart, adoption, subserver, authorization, binding/device
mutation, destructive dispatch, product-network discovery or raw connect-key
exposure.

## UI fixture and signed environment

Environment:

- macOS 26.6 build `25G72`, arm64;
- Xcode 26.6 build `17F113`;
- Apple Swift 6.3.3 (`swiftlang-6.3.3.1.3`,
  `clang-2100.1.1.101`);
- project `ArkDeck.xcodeproj`, scheme `ArkDeck`, Debug destination
  `platform=macOS,arch=arm64`;
- Xcode default signing settings, with no signing override.

The built App identity was:

```text
Identifier=com.arkdeck.desktop
Signature=adhoc
CDHash=5b34b5bbd7796f86ac777e5b5ecfc2d768e219ff
executable sha256=aea7ebc76c56962d5e4c4a70acc15c16eb2f5ca3395bcc58b91e7949979a9740
executable size=14240592
```

The built UI runner identity was:

```text
Identifier=com.arkdeck.desktop.hdcuitests.xctrunner
Signature=adhoc
CDHash=06dfe84b72de5187e9a330b56091d87ccc07eebf
executable sha256=a4f2ffb235a2f9b02dc6632d44b8c55cdbfff6176f50a8200abbb67e638d0972
executable size=93232
```

`codesign --verify --deep --strict --verbose=2` passed for both bundles.

The checked-in UI harness deliberately requires a visible,
byte-identical fake executable for the bookmark-picker test. The SwiftPM fake
used by this run had:

```text
source blob=bd4b0beb792b8a7989930679a28db9b6ec4db42a
binary sha256=fccd9d37cb7301bfbfd33a290f92075db7fb8a7c2ef288443e6e3e1b413f7f88
binary size=131888
```

The hidden SwiftPM build path cannot be selected by the signed App file
importer. A first full run therefore passed 12 tests and setup-blocked only
`testUserPickerPersistsBookmarkAcrossRelaunch`; this is not a product
failure. The existing harness contract supports a repository-root
`ArkDeckFakeHDCFixture-M1-006` hardlink. The retry created that exact
byte-identical hardlink, passed the isolated picker test 1/1, then passed the
complete suite 13/13. The hardlink was removed immediately and `git status`
was clean. It was never committed and never represented installed HDC.

The clean result bundle summary was:

```text
title=Test - ArkDeck
result=Passed
platform=macOS 26.6 (25G72), arm64
passed=13
failed=0
skipped=0
expectedFailures=0
```

The result bundle contains host UI-runner metadata and remains under
`/private/tmp`; it is not committed. No host hardware identifier is copied
into evidence.

Future signed UI runs must reproduce the precondition with a byte-identical
hardlink, fail closed on a digest mismatch, and remove it after the test. The
UI launch fixture remains exactly `--ui-test-hdc-diagnostics`; new sequential
presentation, delay and counters may exist only inside
`HDCFixtureApplicationDiagnostics`, below the explicit fixture boundary.

## Exact implementation and mutation matrix

### `HOR-UI-001`

Positive:

- English and `zh-Hans` show one visible enabled refresh button when idle;
- accessibility lookup by `hdc.devices.refresh` succeeds;
- activation reaches the fixture provider and changes the rendered device
  event presentation from its first deterministic state to its second;
- keyboard/assistive activation uses the same action.

Red controls:

- remove the App callback, omit the view action, disconnect the button, change
  the accessibility identifier or omit either locale → signed UI or source
  contract fails;
- render a refresh-shaped label without provider invocation → fixture call
  counter remains 0 and fails.

### `HOR-SESSION-001`

Positive:

- two accepted contract snapshots (`Connected`, then all `Offline`) produce
  ordered `appeared`, then `disappeared` in one capacity-64 buffer;
- candidate canonical identity, endpoint, execution session identity and
  session pseudonym remain equal;
- production-root source audit finds one internal production session/source.

Red controls:

- clear or replace the session during refresh, change any key input, perform
  discovery again, construct a second actor/source, use two fixtures or stitch
  events across App restart → contract/source audit fails.

### `HOR-BOUNDED-001`

Positive:

- the first accepted App action synchronously marks in flight before async
  provider work;
- one accepted action records one provider call and at most one registered
  source invocation;
- a second activation during fixture-only delay records zero additional
  provider calls and no third transition;
- refresh and executable selection are disabled until completion.

Red controls:

- remove or asynchronously delay the App guard, add a second provider/session
  refresh, queue duplicate work, remove either disabled state, or allow a
  third fixture transition → contract/signed UI counters fail;
- add a production `Timer`, `Task.sleep`, background loop, navigation poll,
  automatic retry or unbounded task queue → source occurrence/separation
  audit fails.

### `HOR-SAFETY-001`

Positive:

- all pinned OpenHarmony, registry/profile, Core/contract/baseline, project,
  workflow and signing inputs are byte-identical;
- installed-HDC child execution, real-device access, server lifecycle,
  subserver, authorization, binding/device mutation, destructive effect and
  non-loopback product-network counters are 0;
- production has no fixture flag/value/delay/counter and presentation exposes
  no raw connect key.

Red controls:

- any forbidden-path/blob change; App construction of candidate/endpoint/
  runner/argv/receipt/generation; fixture value above its boundary; changed
  argv/hash/endpoint/timeout/capacity; lifecycle/subserver/device mutation
  token; or raw identifier exposure → blob, static separation, registry or
  effect-counter gate fails.

Cancellation is deliberately bounded: cancellation may suppress the returned
presentation and clears only the App in-flight flag if the model remains
alive. It does not add an App-owned HDC process handle or attempt to terminate
the shared server. Existing Sources-side timeout/cancellation fail-closed
behavior remains byte-pinned.

## Baseline commands and results

```text
CI=true swift test --package-path Packages/ArkDeckKit
  PASS — 506 tests, 1 skipped, 0 failures

xcodebuild -project ArkDeck.xcodeproj -scheme ArkDeck -configuration Debug \
  -destination platform=macOS,arch=arm64 \
  -derivedDataPath <thread-temp>/DerivedData \
  -resultBundlePath <thread-temp>/ArkDeckVisibleFixtureFull.xcresult \
  test -only-testing:ArkDeckHDCUITests/HDCStatusUITests
  PASS — 13 tests, 0 failures

codesign --verify --deep --strict --verbose=2 <ArkDeck.app>
codesign --verify --deep --strict --verbose=2 <ArkDeckHDCUITests-Runner.app>
  PASS

scripts/check-sdd.sh
  PASS — 0 errors, 0 warnings, 111 acceptance IDs

<shared-sdd-python> scripts/test_check_sdd.py
  PASS — 56/56

python3 scripts/test_check_pr_paths.py
  PASS — 50/50

python3 JSON parse of ArkDeckApp/Resources/Localizable.xcstrings
  PASS — sourceLanguage=en, 28 current keys

xcrun xcstringstool compile ArkDeckApp/Resources/Localizable.xcstrings \
  --output-directory <thread-temp>/LocalizationDryRun --dry-run
  PASS — en.lproj and zh-Hans.lproj outputs

git diff --check
  PASS
```

The direct PATH `python3 scripts/test_check_sdd.py` probe lacked PyYAML and is
not the repository contract. `scripts/check-sdd.sh` correctly selected the
repository's shared pinned SDD interpreter; the exact same shared interpreter
then passed the 56-test checker suite. This host setup issue does not widen
scope or alter the result.

These green results prove only that the pinned inputs and verification harness
are usable.

## Required implementation verification

The implementation/evidence PR must run and record, on one revision:

```text
swift test --package-path Packages/ArkDeckKit \
  --filter HDCDeviceObservationPresentationContractTests
swift test --package-path Packages/ArkDeckKit \
  --filter HDCDeviceObservationRegistryContractTests
swift test --package-path Packages/ArkDeckKit \
  --filter HDCSupervisorObservationRegistryContractTests
swift test --package-path Packages/ArkDeckKit \
  --filter HDCSupervisorObservabilityContractTests
swift test --package-path Packages/ArkDeckKit \
  --filter HDCSupervisorContractTests
CI=true swift test --package-path Packages/ArkDeckKit
xcodebuild ... test -only-testing:ArkDeckHDCUITests/HDCStatusUITests
codesign --verify --deep --strict --verbose=2 <App and UI runner>
scripts/check-sdd.sh
<shared-sdd-python> scripts/test_check_sdd.py
python3 scripts/test_check_pr_paths.py
xcrun xcstringstool compile ... --dry-run
git diff --check
```

It must also record:

- implementation/base/readiness merge OIDs and changed-file blobs;
- all four `HOR-*` AC results with evidence class;
- sequential same-session identity and buffer observations;
- App provider call count, registered source invocation count and duplicate
  suppression result;
- forbidden input blob identity;
- exact signed App/runner identity and UI summary with no raw host identifier;
- `installed_hdc_child=0`, `real_device=0`,
  `server_lifecycle_dispatch=0`, `subserver_dispatch=0`,
  `binding_or_device_mutation=0`, `destructive=0`,
  `non_loopback_product_network=0`;
- fixture hardlink creation/digest check/removal and a clean final worktree;
- no claim of hardware validation.

Any need for a new provider API, OpenHarmony/registry/profile/project/workflow
change, new argv, background poll/retry, second candidate/session/source,
extra entitlement, installed HDC or device execution is a deviation. The task
must remain blocked and the proposal must be revised rather than silently
widening the implementation PR.
