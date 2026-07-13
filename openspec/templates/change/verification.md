# Immutable Verification Plan

> Change：CHG-YYYY-NNN  
> Status：planned

本文件属于 approved change input，批准后不再改写。运行结果只写 immutable Task run；所有 active Task 完成后，由受保护 verification workflow 生成 `verification-result.json`，精确绑定本文件、change lock、done run、AC 结果和 result commit，再取得 `changeVerification` 外部批准。不得通过编辑本文件的状态绕过该流程。

## Environment

- Core baseline / platform profile
- OS/toolchain/device/HDC/provider versions
- Required fixtures and clean-host state

## Acceptance matrix

| AC ID | Verification method | Test/Evidence ID | Expected result | Evidence contract |
| --- | --- | --- | --- | --- |
| — | — | — | passed | — |

## Negative and recovery tests

- Failure injection
- Cancellation/safe boundary
- Crash/restart/reconcile
- Disk/server/device disconnect
- Privacy and secret scan

## Deviations

任何 deviation 必须指向批准的 change revision；不允许隐式豁免。

## Result gate（由 `verification-result.json` 证明）

- [ ] active Task/run 共享 exact change-approval base，最终 result tree 是各获批 run Git tree diff 的无冲突并集
- [ ] 并集外仅有按引用闭包逐文件验证的 lifecycle provenance；无 ancestor-only、目录通配或未归属实现提交

- [ ] 所有适用 AC passed
- [ ] Core/platform conformance passed
- [ ] Evidence 可复查且无敏感 raw
- [ ] Simulation/fake 未计入硬件支持
- [ ] Traceability updated
