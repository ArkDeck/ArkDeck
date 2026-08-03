# 存储 race 夹具的 5 秒会合预算 — 负载敏感 flake 定性(2026-08-03)

## 结论

- **PR #1005 被排除,不是原因 `[R]`** —— 目标 flake 在**干净 main**(485107e7)上原样复现
- **这是一族"对真实工作设 5 秒墙钟预算"的脚手架问题**,至少跨 2 个文件 3 个用例
- **真正的环境根因:gate 配置会把本机内存跑爆** —— 16 GB 主机上
  `--parallel --num-workers 8` + `ARKDECK_DAYU200_70035_IMAGE` 打开重档归档套件,
  实测把机器跑到重启
- 本次**只**放宽了 `SessionArtifactStorageContractTests` 的会合预算;
  **全量 gate 下的复跑验证未做**,原因见末节 —— 不声称 flake 已消除

## 起因

`SessionArtifactStorageContractTests` 两例在全量并行 gate 下失败、孤立跑却是百分之几秒:

- `testConcurrentSessionCreationReleasesLosingClaimHeadroom` @3272(`waitB`),29.752s
- `testArtifactPublicationIsSerializedAcrossStoreInstancesAndBindsPartialInode` @5243
  (`winnerWait`),43.103s

两次连续失败发生在带 PR #1005(ArkDeckProcess 截断修复)的树上,而 fc15de23 的一次干净
全量是 1239/1239 全绿 —— 需要判断 #1005 是否有因果关系。

## A/B 实测

A = 干净 main `485107e7`,B = 同树合入 PR #1005 的 head `843a4bc3`。
**注:#1005 此后已合入 main(`6de99a3f`)**,所以事后看 B 臂 ≈ 当时的未来 main,
A 臂 = #1005 合入前的 main;下表按当时状态记录。

两个 worktree 都放在 `.claude/worktrees/` 下(**首次尝试把 B 放在 `/private/tmp` 下,
产生了 3 个 `/tmp` vs `/private/tmp` 的路径解析伪失败,那批数据作废重来**),
交替跑 A/B/A/B 让背景负载漂移平摊到两臂。

| 轮次 | 进场 load | 秒 | 用例数 | 结果 |
|---|---|---|---|---|
| A-main 1 | 23.72 | 132 | 1246 | **失败** `testConcurrentSessionCreationReleasesLosingClaimHeadroom` @3271(`waitA`) |
| B-1005 1 | 9.33 | 143 | 1247 | 干净 |
| A-main 2 | 9.73 | 100 | 1246 | 干净 |
| B-1005 2 | 6.91 | 134 | 1247 | 干净 |
| A-main 3 | 8.25 | 129 | 1246 | **失败** `RuntimePortContractTests.testTEST_AC_JOB_008_01_PlatformInstanceContract` @821 `fixtureTimeout`(34.007s) |
| B-1005 3 | 16.75 | 91 | 1247 | 干净 |

**裁决依据不是两臂比例**(n=3 太小,而且方向恰好相反,那只是噪声),而是:
目标 flake 在干净 main 上出现了,同一个测试、同一个
`("timedOut") is not equal to ("success")`,只是落在 `waitA` 而不是 `waitB`。
`#1005 不是必要条件` —— 原先那两次连续失败是采样巧合。

顺带:A-3 暴露的 `RuntimePortContractTests` 是**同族第三例**,而且实时计数器漏计了它
(失败行是 `: failed: caught error:` 而非 `XCT` 开头)。

## 机制

被否掉的假说(**实测**,记下来免得再走一遍):

- **不是 libdispatch 线程池饥饿**。探针在 load 34.8、8 个阻塞块占着
  `DispatchQueue.global()` 时,再投递一个块的**启动**延迟 p50 0.01 ms / max 0.17 ms。
- 而且 `.now() + 5` 是在块**内部**求值的,调度延迟根本吃不到这 5 秒预算。

成立的解释:

- 赢家路径是 **fsync 密集**的。`SessionStore.createSession` 结尾有九次连续
  `syncDirectory`(`SessionLayout.swift:182-190`);`SessionArtifactStore.publish` 是
  write + fsync + rename + 父目录 fsync + manifest 原子写。
- 临时目录在 `FileManager.default.temporaryDirectory`(APFS 启动卷),
  正是 gate 解压 + 哈希 731 MB 归档时在捶的同一个卷。
- 16 GB 主机 + 8 worker + 重档归档 → 内存耗尽 → 压缩器/换页
  (实测 `Pageouts: 3417`,机器重启)→ fsync 与线程唤醒变成秒级不可预测。

和失败签名吻合:**超时的那一个 wait 总是等"干重活的赢家"**。输家(`EEXIST` /
拿不到发布锁)快速失败,所以 3271/3272 哪个中招取决于哪个 store 赢了 mkdir。
`RuntimePortContractTests` 那条更露骨:5 秒预算,实际耗掉 34 秒仍未等到。

## 改了什么

`SessionArtifactStorageContractTests.swift` 引入 `storageRendezvousTimeout = 60`,
替换 8 处**正向**会合等待(4 处 fault injector 内部 + 3 处主线程断言 + `waitForSemaphore`)。

**没有削弱任何被测不变量**:create-race 恰好一个赢家、输家报 `already exists`、
输家 headroom 释放(`activeAfterRace == 1` / `reservedAfterRace == 201`)、
赢家随后整份释放归零、发布锁跨 store 实例串行化 —— 这些断言一条没动,
它们本来也不依赖那个 5 秒。wait 是纯防挂脚手架,过期只说明主机没跑到。

两处**负向**等待(`.now() + 0.1` 断言 `.timedOut`,验证"仍被挡住")**保持不变**并加了注释:
负载只会让它们更确定,调大只是让测试变慢。

60 这个数是**按观测取的,不是推导出来的**:同族的 RuntimePort 那条在同样负载下
实际耗时 ≥34 秒。正常主机上这些等待是百分之几秒,永远碰不到 60。

## 验证到什么程度(重要)

- **做了**:编译通过;`--filter SessionArtifactStorageContractTests` 单进程跑
  61 例 0 失败 / 5.744s(不设归档环境变量、不并行)
- **没做**:改动后的**全量并行 gate 复跑**。原因是该配置在本机会把内存跑爆并导致重启,
  维护者已明确要求停止全量跑。
- 因此**不声称 flake 已消除**,只声称:预算从"落在噪声内"抬到了"远高于实测停顿"。

## 未处理 / 建议

1. **最高优先级是 gate 并发度,不是测试**。16 GB 上 8 worker + 归档套件超出主机容量,
   任何超时调参都救不了"机器崩掉"。建议下调 `--num-workers`,或把重档归档套件
   与主套件分开跑。
2. `RuntimePortContractTests.swift` 692/704/708 三处 `timeout: 5`(等真实子进程写
   ready-file 与退出)是**同族且已实测失败**,本 PR **未动** —— 它属于另一处 scope,
   留给维护者决定是否一并放宽。该文件另有 9 处 `DispatchQueue.global()` + 5 秒信号量站点。
3. `SessionSettingsContractTests` 早就写成 10 秒 —— 说明这族预算此前已被撞过一次。
