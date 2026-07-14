# CHG-2026-003 Verification Plan

> Status：planned
> Change：CHG-2026-003-dayu200-image-characterization@r1
> Core baseline：CORE-1.0.0

本文件是 immutable verification plan;实际结果由 Task run/evidence 记录。

## Acceptance matrix

| Evidence ID | Method | Expected result | Status |
| --- | --- | --- | --- |
| CHAR-M0-DAYU200-IMAGE-001 | streaming scan + nine hazard codes | pinned identity matches; complete physical-order inventory with per-member SHA-256; bounded reads; every hazard fixture fails before classification | pending |
| CHAR-M0-DAYU200-CLASSIFICATION-001 | six-condition closed rule + branch-complete unit tests | `rockchipRawImageSet` only when all fixed-archive path/kind/size conditions hold; otherwise `unknown`; result remains non-authoritative/candidateNonExecutable and Provider/compatibility stay unknown | pending |
| CHAR-M0-DAYU200-NODISPATCH-001 | process/file audit | read-only archive access; writes confined to the five evidence outputs and lifecycle sidecars; zero subprocess/network/HDC/vendor/device dispatch | pending |

## Gate

本 change 不产生硬件、Provider 或支持声明。`unknown` 是合法结论;缺口清单
(分区语义、烧写地址、协议、恢复路径)是必交产物,直接输入 DEC-002 与
Route-B CLI capability change。
