# CHG-2026-008 Verification Plan

> Status:planned
> Change:CHG-2026-008-ui-dump-hidumper-wrapper@r1
> Core baseline:CORE-2.0.0

本文件是 immutable verification plan;实际结果由 Task run/evidence 记录。执行
blocked 于 change approved 且 TASK-M1-006 done(`Packages/**` 独占解除)。

## Acceptance matrix

| Evidence ID | Method | Expected result | Status |
| --- | --- | --- | --- |
| INT-UD-WRAPPER-001 | adversarial contract tests | 每 recipe 固定 argv 形态;成败判定只依输出标记不依退出码;错误样输出(exit-0 陷阱)显式失败;标记缺失判 unknownOutput;fake 对抗全分支;零真实 hdc | pending |
| INT-UD-GOLDEN-001 | golden registration review | golden 来自人类白名单采集、脱敏、`.gitattributes` 先行、字节钉死、profile/lock/测试资源三方一致、零字节改写;零兼容性声明 | pending |

## Gate

- M0B 事实是设计输入非兼容性证据:本 change 不产生支持声明、不推进 matrix 行。
- golden 采集沿用受控位置/脱敏先例;序列号与用户路径不入仓库。
- `Packages/**` 在 M1-006 done 前不得触碰;违反即整体 fail。
