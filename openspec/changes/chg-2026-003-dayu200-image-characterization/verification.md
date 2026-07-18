# CHG-2026-003 Verification Plan

> Status：passed;maintainer confirmation 见文末,candidate `verified` 在
> verification closure PR 合入后生效
> Change：CHG-2026-003-dayu200-image-characterization@r1
> Core baseline：CORE-1.0.0

本文件是 immutable verification plan;实际结果由 Task run/evidence 记录
(acceptance matrix 的 Status 列保持起草期 `pending` 不改写,三项实际二值结论
以 `evidence/runs/TASK-DAYU200-CHAR-001/run.md` 为准:全部 passed)。

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

## Maintainer confirmation(2026-07-18)

- Implementation + evidence:PR #44,维护者 `lvye` merge,merge commit
  `6c1ba7b1d8856143fa673ec9e73010aa3e658de9`(squash 含 approval-only commit 与
  实现 commit)。
- Task `ready→done`:PR #47,维护者 `lvye` merge,merge commit
  `02f42580f003d00a36f9cef7523c74ab26eda2f7`。
- Confirmation scope:`TASK-DAYU200-CHAR-001` 实现、三个 `CHAR-M0-DAYU200-*` AC
  的 run.md 二值结论(全部 passed)、gaps 清单与
  no-hardware/no-provider/no-support-claim 边界。
- 本 confirmation 满足 verified gate;不构成 archive,archive 由后续独立 PR
  完成(先例 #21)。
