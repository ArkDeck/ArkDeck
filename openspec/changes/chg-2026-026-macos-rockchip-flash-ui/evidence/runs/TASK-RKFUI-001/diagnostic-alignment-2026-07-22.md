# TASK-RKFUI-001 diagnostic alignment rerun

- Run time: 2026-07-22
- Executor: autonomous agent
- Evidence classification: contract/fake and host-side static verification
- Hardware/device dispatch: 0
- Registry version: unchanged at `1.0.0`

## Scope and result

Aligned the Python probe with the Swift discovery contract: bookmark stale/path-mismatch/
creation-or-resolution failures now return `toolBlocked`, and `maximumOutputBytes` is enforced
against combined stdout plus stderr bytes. Swift and Python each cover the previously missed
63 KiB stdout plus 2 KiB stderr case as `outputTooLarge`. The integration profile now states the
combined-stream limit explicitly.

## Verification

| Command / check | Result |
| --- | --- |
| `swift test --filter RockchipDeviceDiscoveryContractTests` from `Packages/ArkDeckKit` | PASS: 6 tests, 0 failures |
| `python3 -m unittest` from `scripts/rockchip_e0_probe` | PASS: 5 tests, 0 failures |
| `xcrun swift-format lint --strict` on the changed discovery source and contract test | PASS |
| `ARKDECK_PYTHON=<main-checkout .venv-sdd Python 3.14.6 / PyYAML 6.0.3> scripts/check-sdd.sh` | PASS: 0 errors, 0 warnings, 111 acceptance IDs |
| `git diff --check` | PASS |

The first sandboxed Swift invocation could not write the compiler module cache; the same requested
test was rerun outside the filesystem sandbox and passed. The default `python3` lacked PyYAML, so
the SDD guard used the repository's existing readiness-pinned `.venv-sdd` interpreter through its
documented `ARKDECK_PYTHON` override. No dependency was downloaded or changed.

## Acceptance conclusion

- AC-FLASH-001-01 contract parser/fault coverage remains PASS, including the combined output cap.
- AC-UX-007-01 diagnostic parity is restored for security-scoped bookmark failures; all remain
  tool-selection/remediation failures rather than device permission failures.
- No signed Sandbox E0/device attempt was rerun. The existing execute-readiness conclusion remains
  blocked, and no task/change status is changed by this host-only rerun.
