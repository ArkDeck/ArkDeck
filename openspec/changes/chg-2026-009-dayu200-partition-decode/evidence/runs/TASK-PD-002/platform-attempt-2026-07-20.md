# TASK-PD-002 fresh platform run attempt — 2026-07-20 — BLOCKED

## Run identity

- Execution base:`main` `2c3f6d8`(首次 attempt 时点;诊断复跑于同日稍后,期间
  仅治理 merge、零 `scripts/partition_decode/**` 变更)
- Attempt time:2026-07-20 15:35(首次)与同日诊断复跑,Asia/Shanghai
- Operator:维护者 lvye(fuhanfeng)本人(NSOpenPanel 选择、console 解锁);Agent 零
  broker/collector 启动,仅起草 preflight 脚本与事后诊断
- Environment:macOS 26.5.2(25F84),arm64;CPython 3.14.6(collector 解释器与
  broker 嵌入 framework 同源同版)
- Evidence class:platform blocked-attempt record;不是三项 platform AC 的 passing
  evidence,不是硬件/设备 evidence
- Final status:**BLOCKED**。collector `_validate_runtime_receipt` fail-closed 拒绝
  (`runtime receipt failed closed validation`,exit 1),create-only publication 未
  发生,零 partial/governed output。

## Preflight(全部通过,先于 attempt)

- 11 个 pinned source SHA-256(4 decoder + 7 broker,r4 readiness 钉定值)逐一复算
  相符,零漂移;
- pinned archive identity:size `732948803` bytes、SHA-256
  `fc7637f34a8394847b1b6c7e7ff2750863d18c6dc05e184abaf5aed70ec75280` 逐字相符
  (CHG-2026-003 archived identity);
- console 解锁确认(`CGSSessionScreenIsLocked` 键缺席,collector 启动前与结束后
  各一次);
- `python3 -V` = `Python 3.14.6`。

## Attempt facts

- broker 完整运行:fresh artifact 由未修改 source 新建并经严格 codesign 校验;
  NSOpenPanel 由维护者本人选择 pinned archive;broker exit `0`,stdout 协议两行
  (`BROKER_RECEIPT_B64=`/`BROKER_OUTPUT_DIR=`)齐备;receipt 1636 bytes base64
  解码与 JSON 解析成功;
- collector 在封闭校验合取处拒绝,out-dir 未创建;
- 无任何 source 修改、设备/HDC/网络访问或磁盘解包。

## Root cause(2026-07-20 诊断实锤)

- 方法:仓库外 scratchpad 零侵入诊断脚本 import **未修改**的 collector,复用其真实
  `_build_fresh_artifact`→`_inspect_artifact`→`_launch_verified_broker` 管线,把封闭
  校验合取逐项打印;维护者亲跑(含再一次 NSOpenPanel 选择)。诊断零发布、零
  evidence、零 repo 写入。
- 逐项结果:22 项中 20 项 PASS;仅
  `policyChecks[network-outbound]` 与 `policyChecks[process-exec]` FAIL,实际值均为
  JSON 数字 `1`。
- 根因:`main.m` 以 `@(expr != 0)` 装箱 `sandbox_check` 结果——C 比较结果类型为
  `int`,`@()` 产生 NSNumber(int)而非 NSNumber(BOOL),NSJSONSerialization 序列化为
  JSON `1` 而非 `true`;collector 对这两项用 `is True` 身份检查,`1 is not True`
  恒 FAIL。四个 device 路径的 dict 相等比较(`{"readDenied": True, ...}`)因
  Python `1 == True` 意外通过。sandbox 策略本身全部真实 denied(broker 对策略
  失败有提前退出门,receipt 能产出即策略全部生效)。
- 反证记录:CDHash 槽位/长度嫌疑以独立 ad-hoc 签名探针证伪(`kSecCodeInfoUnique`
  = 20 字节截断 CDHash,与 `codesign -d` 的 `CDHash=` 行逐字一致);`CORE_OUTPUTS`
  双端常量逐字一致;runtime/static identifier 与 CDHash 实测相等。
- 管线史:r1 失败、r2 锁屏、r4 headless-only——本次为该 signed-broker 管线**首次
  端到端运行**,receipt 生成端与校验端的 JSON 布尔语义从未经真实运行对齐,缺陷
  因此从未暴露。

## Boundary compliance

- 未修改任何 source(PR boundary:source 修复回 TASK-PD-001 remediation revision,
  即携带本 record 的 r5);pinned archive 仅经 NSOpenPanel 只读 descriptor 消费;
  诊断脚本位于仓库外 scratchpad,不入库;broker 输出目录留在其 sandbox 容器临时区,
  未发布、未复用。

## Acceptance conclusions

| Test ID | Conclusion |
| --- | --- |
| `TEST-DECODE-DAYU200-PARTITION-001` | **BLOCKED / NOT EXECUTED**:无 governed output;collector 校验缺陷先于判定 |
| `TEST-DECODE-DAYU200-INPUT-BOUNDARY-001` | **BLOCKED / NOT EXECUTED**:fail-closed 零 partial output 行为符合设计意图,但不构成 passing evidence |
| `TEST-DECODE-DAYU200-RECONCILE-001` | **BLOCKED / NOT EXECUTED**:无 fresh mapping/reconciliation |

解除条件:TASK-PD-001 r5 remediation `done` → TASK-PD-002 独立 readiness amendment
重钉 broker source pins 并恢复 `ready` → 重跑同一次 fresh 三项 platform run。
