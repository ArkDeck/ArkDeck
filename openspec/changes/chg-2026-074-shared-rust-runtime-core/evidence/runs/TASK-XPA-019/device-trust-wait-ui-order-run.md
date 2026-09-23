# Device trust wait: retry order in the App UI sweep

TASK-XPA-019 / CHG-2026-074. A UI-test ordering defect; no App or fixture
behavior changes.

## Failure

The scheduled Swift slow lanes run 35782157568 (main `9acccf849`, job
`ui-tests` 106930043129) failed once, in
`AppShellUITests.testEnglishSweepOfEveryWorkspace` at `AppShellUITests.swift:2016`.
The sweep had just written `--ui-test-device-authorized` to the fixture state
file and was clicking the timed-out wait's retry (`device.action.beginWait`).
XCTest found the button at 12.18 s. When it synthesized the click at 12.41 s,
the button was gone.

## Cause

`DeviceListFixtureApplicationProvider` answers every candidate read from the
fixture state file, not only the wait's probes. The App also makes candidate
reads of its own: `DeviceListViewModel.startLiveObservation` refreshes every
10 s once the startup read has published (#1463, `f413ab1c1`, 2026-08-23). Only four paths
write the device presentation: the startup read, that 10 s refresh, a manual
Re-check, and the wait's own result. In the failing window, no wait was
running and nothing clicked Re-check. That leaves the 10 s refresh: it read the
flipped file between the write and the click and published Connected.
`DeviceDetailView` shows the retry only for an Unauthorized device, so the click
found no button.

The logged times fit a tick. In the failing run the App went idle at 2.17 s, so
its first tick fell at about 12.2 s, inside the 12.2–12.41 s gap between the
write and the click. In the last passing run (dispatch 35695961440 on
`d96421400`) the App went idle at 1.39 s, so its first tick fell at about 11.4 s.
There the sweep wrote at about 10.0 s, and the retried wait's first probe
reported ready by 10.5 s, before that tick.

This is test ordering, not a product regression. The retry-after-flip order
dates from #1187 (2026-08-07) and has been exposed to the tick since #1463.
Nothing in `d96421400..9acccf849` adds a device read. The failing run was slower
(App idle 2.17 s vs 1.39 s; about 0.1 s vs 0.065 s per AppShell query), and that
moved the write onto the first tick. Refreshing while the App is active is
intended: a device whose owner accepts the prompt after a timed-out window
should appear authorized without a retry. The Chinese sweep never walks the
wait (`localizedSweep`), so only the English sweep was exposed.

## Change

- The retry starts while the fixture still reads Unauthorized. The test writes
  `--ui-test-device-authorized` only after the retried wait shows its countdown
  and the timed-out banner is gone. A tick before the click can now read only
  Unauthorized.
- After `device.trust.ready`, a Connected device shows no wait state, and a tick
  may publish Connected before the wait's own probe does. So the test reads the
  verdict back on an Unauthorized device. It waits until Re-check is enabled,
  which cannot happen while the wait polls. Then it resets the fixture, clicks
  Re-check, and requires `device.fact.state` = Unauthorized with no countdown,
  no timed-out banner, no unavailable notice, and an enabled start action. The
  read-back allows 15 s, one live tick period: a tick that read the file just
  before the reset can publish Connected once more.
- `DeviceListApplicationContractTests` also asserts that, after the flip,
  `refreshCandidates()` (the path the live observation uses) reports Connected.
- No assertion was removed or loosened. No sleep was added. The App and the
  presentation-only fixture are unchanged.

Remaining limit: the retried wait keeps the fixture's 2 s fast-poll window, as
the first wait does. A runner stall of more than about 1.5 s between the retry
click and the flip would end that wait timed out. The read-back reports that as
a failure instead of passing on a later tick.

## Local targeted checks

The console was locked (`CGSSessionScreenIsLocked=1`), so no UI test ran locally.

- `ARKDECK_SWIFTPM_CACHE_ROOT=/private/tmp/arkdeck-e190-swift sh
  Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --filter
  ArkDeckClientKitTests.DeviceListApplicationContractTests`: exit 0, 5 tests;
  `/private/tmp/arkdeck-e190-s7-devicelist-tests.log`.
- `ARKDECK_XCODE_CACHE_ROOT=/private/tmp/arkdeck-e190-xcode ARKDECK_XCODE_JOBS=2
  sh scripts/ci/run-xcodebuild.sh`: exit 0, `** TEST BUILD SUCCEEDED **`;
  `/private/tmp/arkdeck-e190-s7-app-build.log`.
- `ARKDECK_PYTHON=/private/tmp/arkdeck-validation-venv/bin/python sh
  scripts/check-sdd.sh`: exit 0, 0 errors, 0 warnings;
  `/private/tmp/arkdeck-e190-s7-sdd.log`.

## CI

Pending. Pull-request CI only builds the UI tests. Running them needs a
dispatch: `gh workflow run swift-slow-lanes.yml --ref
agent/xpa-019-device-wait-ui-regression -f job=ui-tests`.
