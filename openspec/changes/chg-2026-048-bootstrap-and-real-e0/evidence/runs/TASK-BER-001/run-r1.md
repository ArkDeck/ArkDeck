# TASK-BER-001 run r1 — MU-3 垂直交付(contract 面)

- Date:2026-07-29
- Executor:agent(实现与 host 自测;真机执行属维护者设备窗口)
- Base:main `eb24e66`(#778 之后)
- Evidence class:contract / fake integration
- **Hardware status:`hardware-pending`** —— `BER-HW-001`/`BER-HW-002`
  未主张,窗口计划见同目录 `device-window-plan.md`

## 交付面

- **T09**:`Bootstrap/DeviceBootstrap.swift` —— 八相位状态机、
  `BootstrapObservationAction` 四例封闭词表(**结构性 E0**,类型面无
  mutation 构造点)、多候选显式选择、unauthorized/offline →
  waitingForHuman 并自动 resume、`RuntimeTargetStore`(flock + 原子写、
  按稳定身份幂等 adopt);daemon `doctor`/`target.list`/`target.adopt`
  转正;CLI `arkdeck doctor|device|job`(经 AgentClient,零直连)。
- **T10**:`DeviceProviders/HDCE0ActionPack.swift` —— 属性 allowlist
  枚举、HiLog/UI Dump/Trace 有界 typed request(构造即校验、含默认值、
  拒 shell 片段)、`HDCOwnedRemotePath`(package-only 铸造,含
  job/step/nonce)、artifact 接收与 cleanup debt 类型;provider
  lower/verify/reconcile 覆盖全部新 action。
- **T11**:`DescriptorBoundProcessDispatcher` —— 经既有
  `ProcessIdentityBoundRequest`/`FoundationProcessExecutor` 的身份校验
  路径真实 spawn;termination 分类映射到封闭失败集(timeout/signal/
  cancel → outcomeUnknown,身份拒绝 → failed);`arkdeck-agentd`
  生产组装换用真 dispatcher(未配置 `ARKDECK_HDC_PATH` 时保持
  fail-closed 拒绝,不降级)。

## 测试结果

- `swift test` 全量:见下方"全量"行;新增 3 套件 22 项 +
  daemon 套件新增 2 项(共 24 项新测试)。
- 新增关键测试:bootstrap 8 项(含结构性 E0 断言、幂等、park/resume、
  无 serial fail-closed)、E0 action pack 10 项(边界/allowlist/
  owned path/退化输出网格/effect 分类)、walking skeleton 4 项
  (**真子进程** descriptor 绑定 dispatch 全链 + 治理字段拒绝 +
  hash 漂移拒绝 + hostManaged 拒绝)。
- `scripts/check-sdd.sh`:0 error / 0 warning / 111 AC。

## Host 自测抓到并修复的两个真缺陷(库层测试全绿也测不出)

1. **`dispatchMain()` 在 async top level 杀死 daemon**:
   `arkdeck-agentd` 打印 `listening` 后立即退出(exit 1),socket 存在
   但 ECONNREFUSED。根因:async 顶层下 `dispatch_main()` 会
   `pthread_exit` 主线程,摧毁 Swift concurrency executor。修法:改为
   async park loop。**新增进程级回归测试**
   `testDaemonBinaryStaysAliveAndServesRequests`(spawn 真二进制 →
   等 socket → 断言仍存活 → health → SIGTERM 停止);**变异实验**:
   还原 `dispatchMain()` 该测试变红,恢复后变绿(正负对照齐全)。
2. **UDS 路径超长只报 "too long"**:深状态目录触发 104 字节
   `sun_path` 上限,错误无可操作信息。修法:daemon 与 client 均报出
   实际字节数、平台上限与修法(缩短 `--state-dir`);新增回归测试
   `testOverlongSocketPathFailsWithAnActionableMessage`。

另修正一条 MU-2 遗留断言:`testTargetAdoptIsExplicitlyDeferredToMU3`
(断言 adopt 未实现)已随 T09 落地失效,**改写为**未配置 bootstrap
组合时 `target.adopt`/`target.list` 双双 fail-closed 的断言,而非删除。

## AC 结论

- `BER-BOOT-001` PASS;`BER-E0-001` PASS;`BER-SKEL-001` PASS
- `BER-HW-001`/`BER-HW-002` **未主张(hardware-pending)**:需维护者
  设备窗口;窗口计划已 host 侧自测(daemon/doctor/list/adopt-fail-closed
  全部实跑验证),窗口内只需验真设备面。

## 偏差与遗留

- `observe.device@1` 的四 artifacts 落盘在本 PR 仅到 job timeline 与
  durable journal 层;artifact 文件发布与 `artifact.*` 读取面随 T14
  (MU-4)统一 artifact 模型落地——verification 的 SKEL 判据按此收紧,
  未按"四文件已落盘"主张通过。
- bootstrap 的 `observeDeviceIdentity` 当前以 connectKey 作为 USB 稳定
  serial 来源;更丰富的身份属性(build fingerprint 等)随设备窗口的
  真实 facts 采集补齐。
