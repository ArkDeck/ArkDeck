# CHG-2026-008 Verification Plan

> Status:planned
> Change:CHG-2026-008-ui-dump-hidumper-wrapper@r2
> Core baseline:CORE-2.0.0

本文件是 r2 verification plan；实际结果由 TASK-UD-001 implementation revision 的
run/evidence 记录。r2 只替换 implementation scheduling dependency，不更改两个
change-local acceptance 的 method/expected result。

## Readiness environment

- CHG-008 r2 经维护者合入，且 `TASK-RLC-001 done`、CHG-2026-014 verified；该依赖只证明
  固定 package bytes/interfaces 已合入和 `Packages/**` 排他占用解除，不提供 M1-006
  HDC/XCUITest/AC evidence。
- M0B 受控 HiDumper 四流输入存在，byte size 与 SHA-256 同 repo capture hash 清单及
  redacted manifest 一致；manifest evidence class 为 `controlledHumanCapture`，privacy
  self-check 通过。实现 PR 只读输入、生成新的仓库 fixture，不原地修改 controlled raw。
- 锁屏 macOS headless shell；Swift/SwiftPM、`xcrun swift-format`、仓库 fixture 与本地临时
  目录。禁止已安装真实 `hdc`、真实设备、capture/collector、GUI/系统授权、非 loopback
  网络与 device mutation/destructive dispatch。

## Acceptance matrix

| Evidence ID | Method | Expected result | Status |
| --- | --- | --- | --- |
| INT-UD-WRAPPER-001 | adversarial contract tests | 每 recipe 固定 argv 形态;成败判定只依输出标记不依退出码;错误样输出(exit-0 陷阱)显式失败;标记缺失判 unknownOutput;fake 对抗全分支;零真实 hdc | pending |
| INT-UD-GOLDEN-001 | golden registration review | golden 来自人类白名单采集、脱敏、`.gitattributes` 先行、字节钉死、profile/lock/测试资源三方一致、零字节改写;零兼容性声明 | pending |

## Gate

- M0B 事实是设计输入非兼容性证据:本 change 不产生支持声明、不推进 matrix 行。
- golden 采集沿用受控位置/脱敏先例;序列号与用户路径不入仓库。
- 两项 Test ID 必须来自同一 TASK-UD-001 implementation revision；fixture/registry/profile/
  lock/Bundle.module path/hash 任一不一致、controlled raw 被改写或 privacy self-check 不通过即
  fail closed。
- 真实 HDC/device/capture/collector/非 loopback/device mutation dispatch count 必须为 `0`；
  任一发生即整体 fail，simulation/fake 不得记为真机 evidence。
- `TASK-M1-006` 保持 blocked/非 done；若实现开始消费其未关闭 probe/XCUITest/AC evidence，
  或据本 change 推进 conformance/hardware/support/release claim，即整体 fail。
