# CHG-2026-008 Verification Plan

> Status:planned
> Change:CHG-2026-008-ui-dump-hidumper-wrapper@r3
> Core baseline:CORE-2.0.0

本文件是 r3 review-remediation verification plan。当前任务为 `blocked`，没有 implementation
revision 可以产生有效 PASS evidence。未来 run 必须同时绑定 canonical Core Test ID 与两个
change-local Test ID；任何基于未批准 argv/marker 或自造 fake/golden 的既有 PASS 都无效。

## Readiness environment

- CHG-008 r3 经维护者合入；`TASK-RLC-001 done`、CHG-2026-014 verified 只提供 package
  bytes/interfaces provenance，不提供 M1-006 source AC。`tasks.md` 的 consumer dependency
  表必须经后续 readiness revision 复核且没有 `yes` 行。
- 当前 M0B redacted manifest 只含 `hidumper --help` 和 `hidumper -ls`，不是四 Recipe
  capture。人类维护者必须补充 target-build 四 Recipe capture，且后续 approved decision
  revision 必须逐 Recipe 登记 exact argv boundary 与 success/failure/unknown family；在此之前
  argv equality、marker classifier 和 golden registration 均不可二值验收。
- 每个拟支持 Recipe 必须有真实成功输出 provenance；公开示例、simulation、fake 与 PR #126
  草案不得作为 target-build success family 或 compatibility evidence。
- 锁屏 macOS headless shell；Swift/SwiftPM、`xcrun swift-format`、仓库 fixture 与本地临时
  目录；一个由 readiness revision 记录精确 executable path、无需联网安装且通过 PyYAML
  `6.0.3` preflight 的 Python。实现/验证阶段禁止已安装真实 `hdc`、真实设备、capture/
  collector、GUI/系统授权、非 loopback 网络与 device mutation/destructive dispatch。

## Requirement → AC → Test ownership

| Requirement/source | Acceptance | Test ID / canonical method | Required binary evidence |
| --- | --- | --- | --- |
| `REQ-DUMP-003` | `AC-DUMP-003-01` | `TEST-AC-DUMP-003-01` / `recipeSchemaContract` | invalid component ID preflight + zero argv/request/dispatch |
| CHG-008 wrapper integration | `INT-UD-WRAPPER-001` | `TEST-INT-UD-WRAPPER-001` / adversarial contract | approved exact argv + registered output-family classifier |
| CHG-008 golden registration | `INT-UD-GOLDEN-001` | `TEST-INT-UD-GOLDEN-001` / golden review | capture provenance + byte/hash/privacy/registry consistency |

## Acceptance matrix

| Evidence ID | Method | Expected result | Status |
| --- | --- | --- | --- |
| AC-DUMP-003-01 | canonical `recipeSchemaContract` | componentDetail 的 missing、empty、非法格式/字符、leading option、whitespace/newline、shell metacharacter 与 argument injection 全部在 argv/ProcessRequest 前失败；argv/request/recording-dispatch count 均为 0；合法 token positive control 不启动真实 HDC | pending |
| INT-UD-WRAPPER-001 | adversarial contract tests | 每 Recipe 与 approved decision exact argv equality；success 只来自登记 output family，不依退出码；错误样 exit-0 显式失败；未登记/marker 缺失为 unknownOutput；chunk/stream precedence 与无 shell composition 全覆盖；零真实 HDC | pending |
| INT-UD-GOLDEN-001 | golden registration review | golden 来自实际四 Recipe human target-build capture，脱敏且 `.gitattributes` 先行，字节/hash 钉死，profile/lock/测试资源一致，raw 零改写；零兼容性声明 | pending |

## Gate

- 当前 capture blocker、consumer dependency review、Core trace 或 SDD interpreter gate 任一未关闭，
  TASK-UD-001 均保持 `blocked`，不得运行实现或起草 PASS/done。
- exact argv 与 output family 只能逐 byte/结构地来自 approved human capture + decision revision；
  fake 仅验证已批准规则，不能定义规则或证明目标 build。
- PyYAML preflight 必须先以 readiness revision 记录的解释器执行
  `<recorded-python> -c 'import yaml; assert yaml.__version__ == "6.0.3"'`，随后 mandatory guard
  必须使用 `env ARKDECK_PYTHON=<recorded-python> scripts/check-sdd.sh`；不得在执行阶段联网安装。
- M0B 事实是设计输入非兼容性证据：本 change 不产生支持声明、不推进 matrix 行。
- golden 采集沿用受控位置/脱敏先例;序列号与用户路径不入仓库。
- `TEST-AC-DUMP-003-01` 与两个 change-local Test ID 必须来自同一 TASK-UD-001
  implementation revision；任一 component invalid case 产生 argv/request/dispatch，或 fixture/
  registry/profile/lock/Bundle.module path/hash 不一致、controlled raw 被改写、privacy self-check
  不通过，即 fail closed。
- 真实 HDC/device/capture/collector/非 loopback/device mutation dispatch count 必须为 `0`；
  任一发生即整体 fail，simulation/fake 不得记为真机 evidence。
- `TASK-M1-006` 保持 blocked/非 done；若实现开始消费其未关闭 probe/XCUITest/AC evidence，
  或据本 change 推进 conformance/hardware/support/release claim，即整体 fail。
