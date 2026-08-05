# daemon graceful-drain 夹具的 5 秒预算 — 两个成因,一个是产品缺陷(2026-08-05)

## 结论

- **两个独立成因,都能让同一条断言(@1384「the waiting client must receive the
  completed Runtime status」)红** —— 定性时不要在找到第一个后就停
  1. **`drainAndStop(deadline: 5)` 是对真实工作下的墙钟赌注**(同族脚手架问题)
  2. **`AgentDaemon.serve` 在写回响应*之前*就 `finishRequest()`** —— 这是
     **产品缺陷**,不是测试问题:drain 会在这个窗口里看到「daemon 空闲」并
     `shutdown(SHUT_RDWR)` 掉连接,把一个已经跨完全部持久边界的请求的响应截断
- **本族此前的定性「本机假红,交 CI 判」对这条不成立 `[R]`**:2026-08-05 它在
  **CI** 上真红(GitHub Actions,`swift test --parallel --num-workers 4` 全量,
  run 30973828857,PR #1078),同日本机全量并行也红,孤立跑却绿
- 与近期改动**无因果关系 `[R]`**:#1078 是单 markdown 文件的 docs-only,树与
  #1077 合入后的 main 除该文件外无差异;#1075/#1076/#1077 三条 swift 皆绿。
  本夹具的 `makeStack(... harnessCoordinator: nil ...)` 根本不构造 #1077 动过的
  vendor/CLI decision gateway
- 修法**不是抬常数**:改成等真实完成条件,墙钟只留作防挂上界

## 复现

孤立跑 0.980s,预算 5s —— 看着有 5 倍余量。

负载发生器:28 个 CPU 自旋 + 6 个 `dd conv=fsync` 写进程,和夹具同卷
(`FileManager.default.temporaryDirectory`),load avg ~30。

| 树 | 负载 | 结果 |
|---|---|---|
| 未修 | 有 | 12 跑 **1 红**,红的那次 14.239s,@1384 原样签名;绿的 2.4–7.1s |
| 未修 | 有 | A/B 臂 25 跑 **1 红** |
| 已修 | 有 | 30 跑 0 红;A/B 臂 25 跑 0 红 |

**负载统计本身不足以定案**(未修合计 37 跑 2 红、已修 55 跑 0 红,
Fisher one-tailed p≈0.16)。定案靠的是下面两组**确定性**探针,不是这张表。

## 成因一:墙钟预算(确定性探针 C/D)

在**空闲主机**上把注入的真实工作抬到超过 5 秒(dispatcher 每次 sleep 1.2s ×
`observe.device` 的 5 次 dispatch ≈ 6s),两棵树各跑一次:

| 探针 | 树 | 结果 |
|---|---|---|
| C | 未修 | **失败** @1384,5.381s —— drain 预算到期,连接被 shutdown,client 拿不到 status |
| D | 已修 | **通过**,6.433s —— drain 等到了真实完成 |

同样的真实工作量,一棵红一棵绿:这就是「墙钟依赖」本身,与主机快慢无关。

顺带量化:老 `DelayedDispatcher` 每次 dispatch 固定 sleep 150ms,
`observe.device` 的 6 个 step 里有 5 个会 dispatch,等于**凭空给那 5 秒预算塞进
约 750ms 的自造延迟**(孤立跑 0.980s 里真实工作只占约 0.23s)。

## 成因二:`finishRequest()` 早于响应写回(确定性探针 A/B)

`AgentDaemon.serve` 原顺序:

```
beginRequest(); let response = await handler.handleLine(line); finishRequest(); write(...)
```

`drainAndStop` 的第一段等 `activeRequestCount == 0`,之后立刻对所有连接
`shutdown(SHUT_RDWR)`。于是 `finishRequest()` 与 `write()` 之间的那几条指令
构成一个窗口:落进去就 EPIPE,调用方读到 `connection closed before response`,
**而它的 job 已经 succeeded、journal 已 replayable、artifact 已 addressable**。

**空闲主机**上探针:

| 探针 | 代码 | 结果 |
|---|---|---|
| A | 原顺序 + 两者之间 `usleep(200_000)` | **确定性失败** @1384,1.793s |
| B | 同一个 sleep,`finishRequest()` 移到 write 之后 | **3/3 通过** |

窗口只有几条指令宽,所以只需要一次不走运的抢占 —— 4 worker 打满的 CI runner
上正是这种环境。这一条**测试怎么改都不会消失**,必须改产品。

## 改了什么

### `Sources/ArkDeckAgentDaemon/AgentDaemon.swift`(产品)

`finishRequest()` 移到响应写回之后:把响应交给 socket 属于「服务这个请求」的
一部分,计数只有在字节出去之后才该掉。

**代价与边界(已核对)**:活着但不读的 client 现在能把 drain 拖到 deadline —
deadline 就是干这个的;`stop()` 走 `deadline: 0`,两段循环本来就立即退出,行为不变;
注释里那个「请求已完成、client 在等下一帧」的场景不受影响 —— 那种连接是
**请求之间**空闲,不是响应写到一半。

### `Tests/.../AgentDaemonContractTests.swift`(夹具)

- `DelayedDispatcher`(固定 150ms sleep)→ `GatedDispatcher`:signal 到达,然后
  **停在闸门上直到夹具放行**。请求在飞行中这件事从「赌 sleep 还没跑完」变成
  **构造性事实**
- `drainAndStop` 挪到后台线程,夹具先做一次 **0.1 秒负向等待**断言它**还没返回**
  —— 这是不变量本身;job 停在闸门上就不可能终态,负载只会让 drain 更慢,
  **只能加强这条断言**
- 放行后再等 drain 返回。它返回是因为请求排空了,不是因为某个钟到点了
- `daemonRendezvousTimeout = 60` 纯防挂上界(同 #1008 的 `storageRendezvousTimeout`),
  不参与判定
- `DispatchGate` 用 continuation 挂起,不阻塞协作线程池;
  `waitForSemaphore` 把阻塞挪到 Dispatch worker 上

孤立跑从 0.980s 降到 **0.243–0.340s**(自造的 750ms 没了)。

## 变异测试(夹具还有没有牙)

把 `drainAndStop` 第一段等待短路(`while false, activeRequestCount > 0, ...`):
**被抓住**,0.621s。抓它的是 client-status 那条而不是新的负向断言 —— 因为该变异
之后 drain 改为卡在 `activeConnections` 那段,锁**并没有**提前释放。
两条断言各司其职:一条管「锁提前释放」,一条管「响应被截断」。

## 验证到什么程度

- **做了**:探针 A/B/C/D 全部确定性复现;`AgentDaemonContractTests` 30/30 绿;
  `AgentRuntimeExecutor` 11/11、`ObserveDeviceSkeleton` 4/4、
  `EngineLaneCampaignDaemon` 1 skipped 绿;负载下已修树 55/55
- **没做**:`--parallel --num-workers 4` 全量复跑。该配置在本机 16 GB 上会把内存
  跑爆(#1008 已记录并导致过重启),维护者已要求停止全量并行跑。CI 会跑这一档
- **不声称**:负载统计单独证明了什么;它只是与修复一致

## 未处理

1. **产品修复缺一条确定性回归测试**。`finishRequest`/`write` 的顺序只有在人为
   撑开窗口(探针 A)时才必现;不加 daemon 内部测试钩子就钉不住指令级顺序。
   现状是契约测试端到端覆盖后果,顺序本身靠探针 + 本记录。加钩子是另一个 scope
2. `RuntimePortContractTests.swift` 的 `timeout: 5` 站点(146/214/230/231/418/429/
   430/453 等)是**同族**,#1008 已点名未动,本 PR 同样未动
