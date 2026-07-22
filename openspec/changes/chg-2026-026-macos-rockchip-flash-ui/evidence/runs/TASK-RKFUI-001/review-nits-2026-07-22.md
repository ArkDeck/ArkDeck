# TASK-RKFUI-001 review-nit rerun

- Run time: 2026-07-22
- Executor: autonomous agent
- Evidence classification: contract/fake and host-side static verification
- Hardware/device dispatch: 0
- Task/change status change: none

## Scope and result

- Added the typed `unexpectedCarriageReturn` discovery diagnostic in Swift and the matching Python
  diagnostic string; both remain classified as `malformedOutput`.
- Downgraded the unverified `maskrom-stdout` fixture from `controlledHistoricalCapture` to
  `syntheticFault`.
- Split existing evidence files from future task run locations in `evidence/README.md`.
- Changed the signed E0 spike to drain stdout and stderr concurrently on background readers while
  waiting. Capture is bounded to one byte above the combined 64 KiB parser limit, and a child that
  remains alive after the timeout and one-second SIGTERM grace is stopped with SIGKILL before the
  final wait.

## Verification

| Command / check | Result |
| --- | --- |
| `swift test --filter RockchipDeviceDiscoveryContractTests` from `Packages/ArkDeckKit` | PASS: 6 tests, 0 failures |
| `python3 -m unittest` from `scripts/rockchip_e0_probe` | PASS: 5 tests, 0 failures |
| `xcrun swift-format lint --strict` on the three changed Swift files | PASS |
| `ARKDECK_PYTHON=<main-checkout .venv-sdd Python 3.14.6 / PyYAML 6.0.3> scripts/check-sdd.sh` | PASS: 0 errors, 0 warnings, 111 acceptance IDs |
| standalone `RockchipE0ProbeApp.swift` Swift typecheck with AppKit and Security | PASS |
| `git diff --check` | PASS |

The first directed Swift run exposed that checking the bridged Swift `String` did not reliably
produce the intended carriage-return diagnostic for the CRLF vector. The implementation was
corrected to inspect raw stdout byte `0x0d`; the final directed run above passed. No signed Sandbox
E0/device attempt was rerun, so the existing execute-readiness conclusion remains blocked.
