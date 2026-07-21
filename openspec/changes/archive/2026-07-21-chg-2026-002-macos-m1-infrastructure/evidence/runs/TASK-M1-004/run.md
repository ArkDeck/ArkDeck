# TASK-M1-004 run — macOS runtime ports

## Run identity and classification

- Base revision:`000dd89d32b70c6736513d298a543a52ebf22074`
  (`governance: define TASK-M1-004 readiness (#31)`)
- Working branch:`agent/task-m1-004`
- Date/timezone:2026-07-16,Asia/Shanghai
- Environment:macOS 26.5.2(25F84),arm64;Xcode 26.6(17F113);Apple Swift 6.3.3
- Execution authority/classification:`standardAgent`;local contract + macOS platform evidence
- Hardware/network/HDC/device access:none
- Destructive/device dispatch:none。双进程 fixture 只使用临时目录、kernel lock 与本地
  `CFMessagePort`;fake clocks/notifications 不修改系统 wall clock。Agent 未执行 host sleep。
- Final run status:`blocked`。全部自动化向量通过；production clock pair + NSWorkspace attempt 3
  已得到 `@lvye` 执行的 passing observation，前两次失败亦完整保留。Implementation/evidence
  completion gate 已满足；由独立状态 PR 执行 `blocked→done`，本实现 run 不自行翻转状态。

## Locked inputs

以下 SHA-256 在实现前固定；本任务没有修改 Core、contract、baseline、integration 或 platform
profile。

| Input | SHA-256 |
| --- | --- |
| `openspec/baselines/CORE-2.0.0.yaml` | `07227da529608f26dcbbc8843f1623278b51cb3036cd93e1e9ed4af6f8880aa6` |
| `openspec/verification/core-conformance.yaml` | `293cc22936c1079d434c52e23572b6f575c71715d98d32018cde4ecf0deba839` |
| `openspec/specs/workflow-journal-recovery/spec.md` | `0d94128bd06292b1d9ae24a29353a1cbf5591b6c96cd560a139c37d42c357d25` |
| `openspec/contracts/journal-event.schema.json` | `21df4c44b704d249c2228384b075a331346a4731d3f0b90f66ec8092dded8b19` |
| `openspec/architecture/platform-ports.md` | `47752d0cc767867762ef1bc2f65d4aafbd20e81a5622e43320509ffac27a9962` |
| `openspec/integrations/INTEGRATION-PROFILES.lock.yaml` | `ea4e89905abc02717049a651356ecfe6148ea85e820a7d442aa06686c1a52f04` |
| `openspec/integrations/openharmony/profile.md` | `820eca652a7e237693960aadc6d01a9f45c4a964cff3d8307a8fa0e4e5218734` |
| `openspec/platforms/PLATFORM-PROFILES.lock.yaml` | `6ed7ae92343f93693555fef4e5831cd363f6d0c5dcb7fbdd4d651d6d506a1212` |
| `openspec/platforms/macos/profile.md` | `54bd9b295799cb8d93bf397eeb585f24828463f4f1fce1e59a0693f65369d0bf` |
| `openspec/platforms/macos/verification.md` | `0e3de8749ec5e974ed96ceed1760ee7e049a92eecb052c2cfb47658390ca7072` |
| `openspec/platforms/macos/conformance-cases.yaml` | `0502fb2d7a2807f3d99c61b4db90f5e8f7963a80cc6a225f541cfe7f8613178b` |
| change `proposal.md` | `59e0107f12957988d5af24071c927f26021267ec8e6bbd205eef718a106f162a` |
| change `design.md` | `659ac7fd165f89be163a49aff108b4fe8b5cbc3815a0d6ee4547d63779df9f14` |
| pre-run change `tasks.md` | `8350cab3659844705e7d84ef6f97af4d16135a5455a5ffdb3966b996ccfd953f` |
| change `verification.md` | `d272f88404464ee25f57788cf8c2bbf3576346a4a1476ab0b56fa06e013a02e4` |
| change `scope.yaml` | `2b6157ff202cda41f601445cee986c7fadb8d60a6b2ef2a924f13051a12b6265` |
| change `acceptance-cases.yaml` | `6e9afe53672b7d0ba33e663945658ad6752e013f3b4ca90c1de939600e31ad3e` |

## Work completed

- 将 M0A prototype 收敛为固定 per-user/product Application Support lock path 与
  kernel-backed non-blocking BSD advisory lock；lock directory/file 必须是本地文件系统上
  user-owned、非 symlink、regular、single-link 且不可由 group/other 写入。正常竞争只调用一次
  activation sender；其他 lock/path/permission/reliability 不确定性进入 read-only diagnostics。
- 将 writer resource initializer 收进 `RuntimeInstanceCoordinator` 的 kernel admission gate；只有
  `.writer` 才执行 initializer，`.secondary` 与 `.readOnlyDiagnostics` 均不执行。双进程 fixture
  对该 initializer 的 writer/Job/HDC/Session hook 做线程安全调用计数，所有 JSON 数值均读取探针
  snapshot，不再按 admission 分支写入常量。
- 实现 bounded request/reply 的 macOS `CFMessagePort` activation client/listener：payload 严格匹配
  product/user、最大 4096 bytes、send/receive timeout 最多 5 秒；固定内存 fail-closed filter
  保证同一 request ID 至多激活一次。oversized outbound request 明确返回 `requestTooLarge`；listener
  context 使用 Core Foundation retain/release callback 持有 weak-listener box，stop/deinit 与在途
  callback 不会解引用已释放 listener。activation success/failure 都不能产生 writer authority。
- 实现单一 `ProcessInfo.beginActivity(.idleSystemSleepDisabled)` backend、引用计数 controller 与幂等
  lease；begin failure 不制造 lease，explicit end、success、throw、cancel、lease deinit 与 controller
  teardown 均精确释放；最后一个 end 与下一次并发 begin 在同一 controller lock 下串行，底层
  activity 最大并存数为 1。不声明阻止合盖或用户主动 sleep。
- 实现可注入 audit/elapsed/active clocks；production pair 分别使用 `ContinuousClock` 与
  `SuspendingClock`。elapsed deadline 只读取 elapsed duration，throughput/ETA segment 只读取 active
  duration；`Date` 仅用于 audit 与跨进程 fail-safe 判断。
- 实现 restart-safe timing projection：只从既有 locked journal/config evidence 投影 accumulated
  elapsed/active、configured timeout/deadline 与 snapshot UTC；类型不可编码 monotonic instant/tick
  origin，也没有新增持久 codec/schema。wall-clock 回退、缺失/非法 evidence 与无法证明未过期统一
  fail safe 为 expired。
- 实现 `NSWorkspace` sleep/wake source、typed lifecycle event、start/stop、重复/乱序去抖与注入式
  sink。为保持 Package UI-framework boundary，Runtime 只通过 Foundation/Objective-C runtime 获取
  `NSWorkspace.shared.notificationCenter`，不暴露或静态 import AppKit 类型。每个有效 wake 记录
  locked wake payload 所需字段，并各触发一次 segment reset、reconnect evaluation 与 reconcile
  request。单一 serial executor 线性化 source 注册/移除、observer state、notification queue 与 sink
  draining：source callback 只向该 executor 入队，start/stop 同步穿过同一 executor，并发 callback
  或 lifecycle 操作均不能越过前序操作。typed event 不声明独立 `Codable`，避免合成
  `sleepEventID` 偏离 locked
  `sleepEventId`；Runtime 不导入 Storage/OpenHarmony，也不直接访问 HDC/Session。
- 注册 dedicated `ArkDeckRuntimePortFixture`；真实两个 macOS 子进程以 absolute executable +
  argument array 竞争同一 lock，并通过真实本地 activation request/reply 证明 writer/side-effect
  边界。fixture 不调用 host shell。

## Verification commands and results

| Command | Result |
| --- | --- |
| `swift format lint <TASK-M1-004 changed Swift files>` | passed;0 diagnostics |
| `swift test --package-path Packages/ArkDeckKit --filter RuntimePortContractTests` | passed;13 tests,0 failures;1 human-only production sleep/wake harness skipped by design |
| `swift test --package-path Packages/ArkDeckKit` | passed;111 tests,0 failures;同一 human-only harness 1 skip |
| manual `testTEST_MAC_M1_PORTS_001_ManualProductionSleepWakeObservationHarness` | attempt 1 fail；attempt 2 fail；attempt 3 passed:1 test,0 failures,44.608 s |
| `scripts/check-sdd.sh` | passed;0 errors,0 warnings,111 acceptance IDs |
| `git diff --check` | passed |
| Runtime import/access static scan | passed;无 `ArkDeckStorage`/`ArkDeckOpenHarmony` import；HDC/Session 仅出现在边界注释 |
| fixture shell-surface static scan | passed;无 shell executable、`system` 或 `popen` |
| timing wall-clock static scan | passed;deadline/duration 无 `Date()` 计算路径 |

## Automated vector evidence

### Instance and activation

| Vector | Writer init holder/contender | Activation | Job init probe holder/contender | HDC init probe holder/contender | Session-writer init probe holder/contender | Conclusion |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| holder + matching contender | 1/0 | request=1,handler=1,delivery=`activated` | 1/0 | 1/0 | 1/0 | pass |
| holder + unavailable activation endpoint | 1/0 | request=1,handler=0,delivery=`unavailable` | 1/0 | 1/0 | 1/0 | pass;no lock takeover |
| symlink lock path | n/a/0 | 0 | n/a/0 | n/a/0 | n/a/0 | pass;read-only diagnostics |
| permission-denied lock path | n/a/0 | 0 | n/a/0 | n/a/0 | n/a/0 | pass;read-only diagnostics |
| unreliable-filesystem fault | n/a/0 | 0 | n/a/0 | n/a/0 | n/a/0 | pass;read-only diagnostics |
| matching request delivered twice | unchanged | handler=1;second=`duplicate` | unchanged | unchanged | unchanged | pass |
| product/user mismatch or inbound payload >4096 bytes | unchanged | handler=0;`rejected` | unchanged | unchanged | unchanged | pass |
| outbound payload >4096 bytes | unchanged | `requestTooLarge`;request not sent | unchanged | unchanged | unchanged | pass |
| activation handler failure delivered twice | unchanged | handler=1;`activationFailed`,`duplicate` | unchanged | unchanged | unchanged | pass |

上述 writer/Job/HDC/Session 数值是**仪表化的 fixture-local writer initializer hook 实际调用
次数**：holder 经真实 kernel admission gate 调用一次，secondary/read-only 的同一闭包调用次数为 0；
若 gate 错误执行 secondary initializer，计数将变为 1 并使测试失败。fixture 只链接
`ArkDeckRuntime`，这些探针不是生产 Job store、真实 HDC endpoint、Session writer 或设备 I/O
测量。直接 macOS 运行期观测是两个独立进程的 admission、BSD lock 竞争、activation delivery 与
listener `activationCount`；本 run 不把探针表述为真实 HDC/Session side effect evidence。

### Power activity

| Vector | Successful begin | End | Active lease after vector | Conclusion |
| --- | ---: | ---: | ---: | --- |
| 16 concurrent/nested leases | 1 | 1 | 0 | pass |
| success scope | +1 | +1 | 0 | pass |
| throwing scope | +1 | +1 | 0 | pass;original error preserved |
| cancelled async scope | +1 | +1 | 0 | pass;`CancellationError` preserved |
| lease deinit + repeated release | +1 | +1 | 0 | pass;no double-end |
| backend begin failure | attempt +1;successful begin +0 | +0 | 0 | pass;no phantom lease |
| controller teardown with live lease | 1 | 1 | 0 | pass;later lease end does not double-end |
| last release blocked in backend + concurrent acquire | 2 sequential | 2 | 0 | pass;maximum simultaneous underlying activity=1 |

### Clock, sleep/wake, segment and restart

| Vector | Wall/audit | Elapsed | Active | Deadline/segment/counters | Conclusion |
| --- | --- | ---: | ---: | --- | --- |
| no wall jump control | baseline | 20,000,000,000 ns | 12,000,000,000 ns | 30 s deadline not expired | pass |
| wall forward to Unix 4,000,000,000 | jumped | 20,000,000,000 ns | 12,000,000,000 ns | identical to control | pass |
| wall backward to Unix 100 | jumped | 20,000,000,000 ns | 12,000,000,000 ns | identical to control | pass |
| virtual sleep 60 s,deadline remaining 30 s | +60 s | +60,000,000,000 ns | +0 ns | expired | pass |
| valid sleep/wake | typed `sleep,wake` | wake=60,000,000,000 ns | wake=0 ns | journal=2,reset=1,reconnect=1,reconcile=1 | pass |
| initial/duplicate/out-of-order wake | unchanged | unchanged | unchanged | journal/reset/reconnect/reconcile increments=0 | pass |
| concurrent sleep/wake callbacks while sleep sink blocked | unchanged | ordered queue | ordered queue | journal=`sleep,wake`;reset/reconnect/reconcile=1 each | pass;wake cannot overtake sleep |
| source start blocked + concurrent stop | n/a | serialized | serialized | source start=1,stop=1,final registered=false | pass;stop cannot overtake registration |
| source stop blocked + concurrent start | n/a | serialized | serialized | source start=2,stop=1,final registered=true;post-restart journal=`sleep,wake` | pass;start waits and re-registers |
| throughput wake reset | n/a | not read | active-only | segment 0 rate=10;segment 1 first sample=nil,next rate=10 | pass;old segment/sleep time not read |
| valid restart projection after 10 s | +10 s | accumulated=20,000,000,000 ns | accumulated=10,000,000,000 ns | remaining=90,000,000,000 ns | pass |
| wall rollback | -1 s | persisted duration only | persisted duration only | `expired(wallClockRollback)` | pass |
| deadline +121 s | +121 s | persisted duration only | persisted duration only | `expired(deadlineReached)` | pass |
| missing/negative timing evidence | missing/invalid | unavailable | unavailable | `expired(invalidOrMissingEvidence)` / construction rejected | pass |
| old process tick probe | n/a | old-tick read=0 | old-tick compare=0 | snapshot fields contain no tick/origin | pass |

Restart projection fields are exactly:
`accumulatedElapsedDurationNanoseconds`,`accumulatedActiveDurationNanoseconds`,
`configuredOverallTimeoutNanoseconds`,`configuredDeadlineUTC`,`snapshotUTC`。

## Test and Port conclusions

| Test ID | Evidence class | Automated conclusion | Final task conclusion |
| --- | --- | --- | --- |
| `TEST-AC-JOB-008-01` | platform + instrumented contract | passed:双进程恰一 writer；同一个 gated fixture initializer 在 holder 的 Job/HDC/Session hooks=1、所有 secondary/read-only hooks=0；探针不冒充生产模块 I/O | passed for runtime admission boundary |
| `TEST-AC-NFR-001-01` | platform | passed:wall forward/backward 对 elapsed deadline 与 active duration 均无影响 | passed |
| `TEST-AC-NFR-001-02` | platform + human-operated platform observation | passed:virtual sleep 60 s 得到 elapsed +60 s、active +0、30 s deadline expired；attempt 3 production suspended delta=32,958,563,041 ns | passed；task status pending independent state PR |
| `TEST-AC-NFR-001-03` | platform | passed:wake 后新 segment，首 sample=nil；duplicate/out-of-order wake 的四类 counter 不增加 | passed |
| `TEST-AC-NFR-001-04` | platform | passed:只读取五个 restart-safe 字段；rollback/missing/invalid/expired 全部 fail safe，old tick read/compare=0 | passed |
| `TEST-MAC-M1-PORTS-001` | platform + human-operated platform observation | automated matrix passed；attempt 3 sequence=`sleep,wake`,counters=`1/1/1` | passed；task status pending independent state PR |

| Port | Automated binary conclusion | Final gate |
| --- | --- | --- |
| `PORT-INSTANCE-001` | pass | pass |
| `PORT-ACTIVATION-001` | pass | pass |
| `PORT-POWER-001` | pass | pass |
| `PORT-CLOCK-ELAPSED-001` | pass for injected/control vectors | pass;attempt 3 elapsed delta=39,913,733,041 ns |
| `PORT-CLOCK-ACTIVE-001` | pass for injected/control vectors | pass;attempt 3 active delta=6,955,170,000 ns,suspended delta=32,958,563,041 ns |
| `PORT-SLEEP-WAKE-001` | pass for fake notifications + locked journal shape | pass;attempt 3 real sequence=`sleep,wake`,counters=`1/1/1` |

## Required human observation runbook

此命令只启动 bounded observation harness，**不会**自动 sleep；维护者须在 180 秒 active-process
窗口内亲自从 macOS UI 触发一次 sleep，保持休眠至少 15 秒后再唤醒。该 timeout 使用 production
`SuspendingClock`，机器处于睡眠的时间不消耗操作窗口：

```sh
ARKDECK_RUNTIME_SLEEP_WAKE_OBSERVATION=1 \
ARKDECK_RUNTIME_SLEEP_WAKE_TIMEOUT_SECONDS=180 \
swift test --package-path Packages/ArkDeckKit \
  --filter RuntimePortContractTests/testTEST_MAC_M1_PORTS_001_ManualProductionSleepWakeObservationHarness
```

### Manual observation attempt 1 — failed

以下结果来自维护者在对话中提供的原始 XCTest 输出；缺失字段不猜测补齐：

| Field | Observed value |
| --- | --- |
| Observation time/timezone | 2026-07-16 20:10:01.760–20:14:17.610,Asia/Shanghai |
| Human operator | not supplied in output |
| macOS build / architecture | not supplied；`arm64e-apple-macos14.0` 只是 test target，不作为 host tuple |
| Harness duration | 255.851 s |
| NSWorkspace sequence | `sleep` only |
| production elapsed / active delta | unavailable；旧 harness 将同一个 sleep event 同时当作 first/last 后打印的 `0/0` 不属于 clock evidence |
| segment/reconnect/reconcile | `0/0/0`；缺少有效 wake 的级联结果 |
| Binary result | fail；5 XCTest assertions failed |

该尝试的 wall duration 已超过配置的 180 秒，而旧 harness 以 `Date` 控制整个窗口；结果与 wall
deadline 在系统睡眠中到期、进程恢复后未再次驱动 main RunLoop 投递 wake 一致。仅凭 attempt 1
仍不能排除 wake source 本身未投递，因此修复为 active-process timeout 并输出实际 sequence/counters
后必须复验。失败尝试永久保留，不覆盖、不改写为通过。

### Manual observation attempt 2 — failed under superseded harness gate

| Field | Observed value |
| --- | --- |
| Observation time/timezone | 2026-07-16 20:18:36.415–20:19:01.495,Asia/Shanghai |
| Human operator | not supplied in output |
| macOS build / architecture | macOS 26.5.2（25F84）,arm64 |
| Harness duration | 25.080 s |
| NSWorkspace sequence | `sleep,wake` |
| production elapsed delta | 20,590,532,917 ns |
| production active delta | 7,007,008,416 ns |
| derived suspended delta (`elapsed-active`) | 13,583,524,501 ns |
| segment/reconnect/reconcile | `1/1/1` |
| Binary result | fail；旧 harness 的 arbitrary `active <= 2,000,000,000 ns` assertion failed |

Attempt 2 证明 production active clock 至少排除了 13.583 s 的已知休眠区间，且会拒绝
`elapsed=60.1 s,active=60 s`（derived suspended delta 仅 0.1 s）的错误实现。`WillSleep` 到系统真正
挂起、恢复执行到 `DidWake` 之间仍可包含正常 active transition；锁定 verification 只要求真实窗口
保持 elapsed 推进/active 暂停语义，并未规定 notification transition 必须小于 2 秒。因此删除该任意
上限，保留 `elapsed-active >= 10 s` 的已知休眠区间 gate。旧 harness 又因 XCTest assertion 非 fatal
而错误打印 `result=pass`；输出已改为由全部 predicate 计算。Attempt 2 仍按执行时 gate 如实保留为
fail，不追溯改写；修复后需要 attempt 3 passing rerun。

### Manual observation attempt 3 — passed

| Field | Observed value |
| --- | --- |
| Observation time/timezone | 2026-07-16 20:22:42.461–20:23:27.069,Asia/Shanghai |
| Human operator | `@lvye` |
| macOS build / architecture | macOS 26.5.2（25F84）,arm64；同一操作会话在 attempt 2 后提供 |
| Harness duration | 44.608 s |
| production elapsed delta | 39,913,733,041 ns |
| production active delta | 6,955,170,000 ns |
| derived suspended delta (`elapsed-active`) | 32,958,563,041 ns |
| NSWorkspace sequence | `sleep,wake` |
| segment/reconnect/reconcile | `1/1/1` |
| Binary result | pass；XCTest 1 test,0 failures；harness `result=pass` |

Attempt 3 满足全部 binary gate；这是 human-operated macOS platform observation，不是 device
`realHardware` evidence、完整 platform conformance 或 release claim。human operator GitHub
identity 由维护者随后在同一对话中确认为 `@lvye`，全部 observation 字段已闭合。

Passing observation closure：

| Field | Required value | Current |
| --- | --- | --- |
| Human operator | GitHub/maintainer identity | `@lvye` |
| Observation time/timezone | exact timestamp | 2026-07-16 20:22:42.461–20:23:27.069,Asia/Shanghai |
| macOS build / architecture | observed tuple | macOS 26.5.2（25F84）,arm64 |
| production elapsed delta | nanoseconds | 39,913,733,041 |
| production active delta | nanoseconds | 6,955,170,000；derived suspended=32,958,563,041 |
| NSWorkspace sequence | exact ordered sequence | `sleep,wake` |
| segment/reconnect/reconcile | exact counters | `1/1/1` |
| Binary result | pass/fail | pass；XCTest 1 test,0 failures；harness `result=pass` |

Pass 条件：sequence=`sleep,wake`;active delta >= 0；
`elapsed delta - active delta >= 10_000_000_000` ns（已知休眠区间）；segment reset、reconnect
evaluation、reconcile request 均恰为 1。若通知缺失、乱序、clock delta 不满足明确区间或 harness
timeout，结论为 fail，不得把 TASK-M1-004 标为 done。该 gate 会拒绝
`elapsed=60.1 s,active=60 s` 一类错误实现。

## Deviations and residual risk

- Required manual production observation 已由 `@lvye` 执行的 attempt 3 通过，全部 evidence 字段
  已闭合。按独立状态 PR 规则，`TASK-M1-004` 暂保持 blocked，不在实现 run 中翻转。
- `NSWorkspace` 由 Foundation/Objective-C runtime 取得，以满足 package target 不静态 import UI
  framework 的既有 contract；selector/name 或 OS 行为变化由上述真实 observation fail closed 检出。
- activation dedupe 使用固定内存 filter；可能在高饱和度时产生 false positive 并少激活一次，但不会
  false negative 导致同一 request 重复激活，也不影响 writer lock。该更严格失败模式仅影响 UX。
- BSD `flock`/`O_EXLOCK` 保护已打开的 inode；同用户进程若在持锁期间 unlink lock path，再以同路径
  创建新 inode，新实例理论上可在新 inode 上取得锁并形成双 writer。0700 user-owned directory 将
  风险限定在同用户威胁模型，但未消除；未来应加入 path 与 held descriptor 的 dev/ino 重验证或更强
  lock namespace。本任务如实保留该风险，不把当前 path lock 描述为可抵抗同用户主动篡改。
- 本 run 是 local contract/macOS platform evidence，不是 realHardware、完整 platform conformance 或
  release claim；未改变 `conformance_status:notStarted`，也没有真实设备、网络或 destructive 操作。
