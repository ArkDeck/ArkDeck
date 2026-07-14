# Verification Plan

> Change:CHG-YYYY-NNN
> Status:planned # planned | passed | failed;结论经维护者在 PR 中确认

## Environment

- Core baseline / platform profile
- OS/toolchain/device/HDC/provider versions
- Required fixtures and clean-host state

## Acceptance matrix

| AC ID | Verification method | Expected result | Evidence |
| --- | --- | --- | --- |
| — | — | passed | — |

## Negative and recovery tests

- Failure injection
- Cancellation/safe boundary
- Crash/restart/reconcile
- Disk/server/device disconnect
- Privacy and secret scan

## Deviations

任何 deviation 必须写明并在 PR review 中确认;不允许隐式豁免。

## Result gate

- [ ] 所有适用 AC passed 且 evidence 可复查
- [ ] Simulation/fake 未计入硬件支持
- [ ] Traceability updated
