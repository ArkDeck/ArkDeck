# RuntimePortContractTests 的同族 5 秒等待 — 收口(2026-08-05)

## 结论

- 本文件 21 处 5 秒站点全部处理完;这是 #1008 点名未动、#1080 再次点名未动的最后一处同族
- **本次没能在本机复现这个文件的 flake `[R]`** —— 负载 A/B 两臂各 20 跑**都是 0 红**。
  所以下面的改动**不建立在我自己的复现之上**,建立在:
  ①逐站点分类(这些 wait 不承载契约,后面的断言才判定);
  ②#1008 已记录的实测失败(`testTEST_AC_JOB_008_01_PlatformInstanceContract`
  在全量并行 gate 下 34.007s 仍超时,`fixtureTimeout`);
  ③两处**能确定性复现**的真缺陷(见下)
- 顺带查出并修掉两个**不是「预算太小」而是「写法本身错」**的问题:
  **fake 闸门静默降级**、**取消赛跑**

## 站点分类与处置

| 类别 | 处 | 处置 |
|---|---|---|
| 正向会合/完成等待(信号量、DispatchGroup) | 13 | → `runtimePortRendezvousTimeout = 60` |
| 条件轮询 `waitUntil(timeout: 5)` | 1 | → 同上 |
| 真实子进程 `waitForFile` / `waitForExit` | 3 | → 同上(#1008 实测这条在负载下 34s) |
| **fake 闸门 `_ = allow….wait(+5)`** | 4 | → `awaitFixtureGate`,超时**报自己** |
| **取消赛跑(50ms sleep 赌 cancel 抢在 5s sleep 前)** | 1 | → 改成会合 |
| 负向等待 `.now() + 0.2`(断言"仍被挡住") | 4 | **不动**,加注释说明故意短 |

判据同 #1008/#1080:正向 wait 是防挂脚手架,过期只说明主机没跑到;
负向 wait 才是不变量,负载只会让它更确定,调大只是让测试变慢。

## 确定性缺陷一:fake 闸门静默降级

四个 fake(`BlockingEndPowerActivityBackend.endIdleSleepPrevention`、
`CoordinatedSleepWakeNotificationSource.start`/`.stop`、
`RecordingLifecycleSink.record`)原来写的是:

```swift
_ = allowFirstEnd.wait(timeout: .now() + 5)   // 结果被丢弃
```

超时后 fake **自己就不挡了**。于是测试要钉的串行化悄悄不成立,
失败以一个离真因很远的计数不符浮现。

**探针 E**(只把闸门自己的上界缩到 0.05s,测试侧的 wait 仍是 60s):

```
RuntimePortContractTests.swift:1072: failed - fixture gate allowFirstEnd expired after 0.05s;
  the double stopped blocking on its own, so any assertion after this point is
  measuring the scaffold, not the contract
RuntimePortContractTests.swift:297: XCTAssertEqual failed: ("success") is not equal to ("timedOut")
RuntimePortContractTests.swift:298: XCTAssertEqual failed: ("2") is not equal to ("1")
```

改之前**只有后两条**——维护者会去追一个根本不存在的串行化 bug。
现在第一条直接点名真因。

## 确定性缺陷二:取消赛跑

原写法赌"50ms 睡完 + cancel 落地"抢在 5 秒 sleep 之前:

```swift
let cancellation = Task { try await controller.withActivity(reason: "cancel") {
  try await Task.sleep(nanoseconds: 5_000_000_000) } }
try await Task.sleep(nanoseconds: 50_000_000)
cancellation.cancel()
```

主机停顿超过内层 sleep,活动就正常跑完,取消路径**根本没被走到**,
测试红在 `cancelled activity must throw`。

**探针 F/G**(把 cancel 前的停顿设成 6s 模拟主机卡顿,空闲主机):

| 探针 | 树 | 结果 |
|---|---|---|
| F | 未修 | **失败** `cancelled activity must throw`,12.684s |
| G | 已修 | **通过**,6.093s |

改法:活动进入后自报(`activityEntered.signal()`),测试会合到再 cancel;
内层 sleep 改成只有 cancel 才结束(上界=防挂值,cancel 失灵时仍会红而不是永挂)。

## 负载 A/B(阴性结果,如实记)

28 CPU 自旋 + 8 个 `dd conv=fsync`,load avg ~19–30,交替跑两臂各 20 次:

| 臂 | 结果 |
|---|---|
| UNFIXED | pass=20 fail=0 |
| FIXED | pass=20 fail=0 |

**没复现**。合理解释:这个类的主要开销是子进程 spawn + 文件轮询,
而 #1008 记录的那次 34s 失败发生在**内存被跑爆**的全量 gate 里
(那次主机最终重启),我的合成负载没有复制这个状态。
**不声称本次改动"修好了"一个我没能复现的 flake**;只声称:
预算从"落在噪声内"抬到了"远高于已记录的 34s 停顿",
另外两处真缺陷是确定性证明的。

## 验证

- `RuntimePortContractTests` 13 tests / 1 skipped / 0 failures,连跑 3 次,1.28–1.31s
- 探针 E / F / G 均确定性复现
- 全量 ArkDeckKit 串行套件绿(见 PR 正文)
- **未做**:`--parallel --num-workers 4` 全量本机复跑(16 GB 会跑爆内存,#1008 已记录)

## 剩余

同族站点到此清零:`SessionArtifactStorageContractTests`(#1008)、
`AgentDaemonContractTests`(#1080)、本文件(本 PR)。
`SessionSettingsContractTests` 早就写成 10 秒,未纳入——它没被实测撞到过,
且 10 秒不在 5 秒那档噪声里。
