# TASK-BER-001 设备窗口 attempt#1(2026-07-29)— blocked-attempt

- Operator:维护者(lvye)亲手执行,Agent 零设备命令
- Device:DAYU200,connect key `1501…4900`(脱敏),USB,Connected
- Tool:`Ver: 3.2.0f`,SHA-256
  `05b2bf7ad30201c082da336db28f8856952a2b2f49ac3404b96fdb4bf1a68f83`
  (与仓内 pin 零漂移)
- Binaries:`arkdeck-agentd` / `arkdeck`,构建自 main `803ef17`
- Evidence class:realHardware(部分通过 + 两处缺陷)

## 结果总览

| 步骤 | 结果 |
| --- | --- |
| 预检(工具/设备可见) | ✅ |
| S1 daemon 启动 | ✅ `listening on …/agentd.sock` |
| S2 doctor | ✅ providers=[hdc]、bootstrap/targetStore=ready |
| S3 **首次真机 adopt** | ✅ `TGT-958780b2ffb7`,bindingRevision 1,一次成功(设备已信任,未触发 waitingForHuman) |
| S4 `observe.device@1` | ❌ **失败**:`waitingForRecovery` / outcomeUnknown |
| S5 daemon 重启恢复 | ✅ job 历史可查、状态保持、`recovered: … no redispatch` |
| S6 拔插重绑 | ✅ **同一 targetId**,零重复 target |
| 收尾停止 daemon | ⚠ `trace trap`(崩溃退出,非干净退出) |

**AC 判定**:`BER-HW-001` **未通过**(blocked-attempt);`BER-HW-002` 的两项
观察(重启恢复、拔插幂等重绑)均如预期,但因其依赖的 job 处于 unknown
状态,**待 attempt#2 与 HW-001 一并复核后再判定通过**。

## 缺陷 1(阻断 HW-001):`observeServer` 用错语义解析器

Journal 给出精确根因:

```
"reason":"outcomeUnknown: expected exactly one Ver: line, saw 0"
```

`hdc checkserver` 的真实输出是
`Client version:Ver: X, server version:Ver: Y`,而 MU-2 的 provider
adapter 把 `.observeServer` 与 `.observeTool` 合并、共用 `hdc -v` 的
`parseClientVersion`(该 parser 找**行首** `Ver:`,故计数为 0)→
`.unknown` → 引擎按契约进 `waitingForRecovery` 并零自动重放。

**引擎行为完全正确**:未知结果没有被当成成功,也没有自动重试;
缺陷在 provider 的判定层。

修复:新增 `HDCObservationSemanticParser.parseServerCheck`(解析双版本、
未注册版本 → unsupported、`[Fail] …` 行 → 具名 malformed),adapter 的
`.observeServer` 分支改用它,并把**客户端/服务端版本不一致**判为具名
失败 `serverVersionMismatch`(此前该情形根本不可能被发现)。

## 缺陷 2:daemon 收到 SIGTERM 时崩溃(exit 133 = SIGTRAP)

本地复现确认:信号送达时进程直接 trap,**信号处理器从未进入**
(加诊断打印验证)。根因是 async top level——Swift concurrency 运行时
占据主线程,主任务挂起期间到达的信号在任何 handler 运行前就触发了运行时
陷阱。中途尝试"把 exit 移出 handler"无效,因为问题发生在更早。

修复:改为标准 daemon 形态——同步顶层 + `dispatchMain()`,异步初始化
放进 `Task.detached`(顶层是 `@MainActor` 隔离,普通 `Task` 会与
semaphore 等待死锁,此点亦实测确认)。修复后:启动 → 服务 → SIGTERM →
打印 `stopped` → **exit 0**。

原进程级测试只断言"进程停了",放过了崩溃退出——已按"断言太弱"补强为
断言 `terminationReason == .exit` 且 `terminationStatus == 0`。

## 测试替身修正(四处)

修复暴露出四个 fake 比真接口宽松:daemon/engine/skeleton 测试与
crash fixture 都对 `checkserver` 返回 `-v` 形态或 `[Empty]`。已全部改为
真实 checkserver 输出;skeleton 测试进一步改走 `ArkDeckFakeHDCFixture`
**真实的 checkserver 分支**,与硬件同形。这正是"替身表达不出被测代码
所做的区分,缺陷就藏在那里"的实例。

## 复核基线

- `swift test`:**609 / 1 skipped / 0 failures**(新增 2 项 parser/adapter
  回归)
- 修复后 host 自测:daemon 启动/doctor/SIGTERM exit 0 均实测通过

## 下一步

attempt#2 只需重跑 S1-S6(步骤不变),重点确认 S4 得到
`state: succeeded`、S6 仍为同一 targetId、收尾退出码为 0。
