# Device bounded preview and keyboard pointer — 2026-10-04

This follow-up adds an explicitly started screenshot preview and a keyboard path for the three existing gestures. It does not add an operation, change Runtime admission, or claim hardware acceptance.

Preview submits `capture.diagnostics@1` serially, pauses two seconds between frames, and stops starting new requests at 60 seconds or 30 frames. Stop, cancellation, target/binding changes and navigation discard late frames and prevent further dispatch. The current Runtime Job may still finish after Stop. Capture failure is terminal and never automatically retried. Capture, input, preview and recording also share model-level exclusion, including rapid clicks before a view redraw.

Keyboard arrows move a local, bounded pointer; Return/Space taps, Option-Return holds for 800 ms, and Shift-Return establishes a local swipe start or sends a 300 ms swipe. Escape removes the start. Inspector buttons provide the same actions. No key/text injection operation is implied. Exact target/frame guards, history-only and stale-frame refusal, and unknown-outcome non-replay remain in place. A late gesture receipt stays visible with its original target, without changing a newer frame.

## Local targeted checks

- `sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --filter 'DevicePreviewSessionTests|DeviceFrameLivenessContractTests|DeviceGestureClassificationContractTests|DeviceDesignSynchronizationContractTests'`: exit 0; 24 Swift Testing cases plus 3 XCTest design cases passed on the final code. Logs: `/private/tmp/arkdeck-macos-closeout-20261004/device-preview-targeted-final.log`.
- `ARKDECK_XCODE_JOBS=2 sh scripts/ci/run-xcodebuild.sh`: exit 0, App build-for-testing. The subsequent UI wrapper rebuilt the final App sources. Log: `/private/tmp/arkdeck-macos-closeout-20261004/device-preview-app-build-final.log`.
- `sh scripts/ci/run-ui-tests.sh -jobs 2 -only-testing:ArkDeckHDCUITests/AppShellUITests/testDevicePreviewStopsBeforeKeyboardInputAndUnknownStaysStale -only-testing:ArkDeckHDCUITests/AppShellUITests/testDeviceRecordingLocksControlsWhileCheckingStorage`: exit 0 after adding explicit test scrolling for the newly extended compact inspector. Log: `/private/tmp/arkdeck-macos-closeout-20261004/device-preview-ui-fixed.log`.
- Screenshot review exposed a further focus/reveal defect: clicking Move pointer while the picture already held keyboard focus did not scroll it back into view. Added an explicit reveal request and retained focus while input settles. Re-ran the first UI case with a picture-hittability assertion: exit 0, 18.906 seconds, including a further assertion that the whole compact picture fits above the footer. Log: `/private/tmp/arkdeck-macos-closeout-20261004/device-preview-ui-fit.log`. The failed attempt is retained in `device-preview-ui-focus.log`; the assertion was not relaxed.
- `node --check` on the prototype's extracted inline scripts: exit 0. Extraction: `/private/tmp/arkdeck-macos-closeout-20261004/device-prototype.js`.
- `cargo fmt --all --check --manifest-path rust/Cargo.toml`: exit 0. Log: `/private/tmp/arkdeck-macos-closeout-20261004/device-preview-fmt.log`.
- `sh scripts/check-sdd.sh`: exit 0, zero errors/warnings. Log: `/private/tmp/arkdeck-macos-closeout-20261004/device-preview-sdd.log`.
- `git diff --check`: exit 0.

All UI captures are explicit fixtures; no device operation was executed. The five real-device Golden Journeys remain excluded by the user's request. No full local unified gate was run.

## CI

Pending the feature PR push. GitHub CI is the unified gate; local targeted results do not constitute maintainer approval or a published Runtime change.
