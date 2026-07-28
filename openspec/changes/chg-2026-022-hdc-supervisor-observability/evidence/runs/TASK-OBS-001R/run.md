# TASK-OBS-001R run log

## implementation + contract run（2026-07-28，host-only）

### 授权、基线与范围

- Change = `CHG-2026-022-hdc-supervisor-observability@r3`，Core baseline =
  `CORE-2.1.0`；本任务只认领 change-local
  `OBS-DEVICE-PRESENTATION-001`，canonical Core AC 零认领。
- Fresh D1 readiness = PR #709 exact head
  `a629432b2f023c87afbdfb7318bc7e95329d621f`，由维护者 `lvye`
  APPROVED 后 merge 为
  `c295d4a45a30ea08d7ab66440c5593d1208f222a`。本实现只消费该一次性授权。
- 开工 base = 上述 #709 merge。实现期间 `main` 先前进到
  `f065ac90e69ff89c9ebb8817bfb4f9ebb1b0ed7d`（#710/#711/#712），再由
  #714 只修改 CHG-2026-042 `tasks.md` 前进到
  `eaa57f9281c6194e1bada0c740bde1d6e4f48fc6`，最后由 #715 只修改
  CHG-2026-008 readiness/capture 治理文件前进到最终 base
  `fe13de4d319bd4fdd07f2439daf9cce8bff34897`；全部区间均与本任务
  Allowed paths 及所有 source/invariant pins 零交集。三次重基后逐项
  `git ls-tree` 复核 pins 全部
  原值，最终 implementation commit =
  `60924f9d0c533908425a5b60b868f8301d13f261`（parent =
  `fe13de4d319bd4fdd07f2439daf9cce8bff34897`）。
- 开工与重基后 open PR 路径复核：开工时 0；推送前列表曾短暂显示唯一
  #715，其文件均在 CHG-2026-008，后确认维护者已于
  `2026-07-28T08:20:23Z` merge。首次 Agent PR run 因远端 base 已前进而按
  fail-closed 规则拒绝 stale head；fetch/rebase 后最终 open PR = 0，未以修改
  guard 或扩大 scope 绕过。
- 环境：macOS 26.5.2 arm64、Xcode 26.6、Apple Swift 6.3.3。本 run
  contract/fake only；零 installed HDC、零真实设备、零 HDC server
  lifecycle/subserver/device mutation/destructive；测试进程零设备/外部服务网络，
  仅治理核验使用 GitHub fetch/PR metadata；零硬件 evidence。

### 实现落点

| Contract | 实现 |
| --- | --- |
| Public immutable projection | 新增 public closed `HDCDeviceObservationPresentationKind` 与 public immutable `HDCDeviceObservationPresentationEvent`；构造器 package-only 且只接收 `Date`，`HDCDiagnosticsPresentation.deviceEvents` 默认 `[]` |
| Timestamp/privacy bridge | internal actor 在 ingest 点调用 injected clock，统一 UTC RFC 3339 fractional seconds；`.unchanged` 零 clock/零 history；identifier 仅接受 `redacted-device-[0-9a-f]{24}`，非法值、unknown/unavailable 均 fail closed，internal reason/raw key 不出 public value |
| Bounded composition | internal fan-out 与独立 presentation buffer 同为 capacity 64；public history 始终保留最新 64 条且顺序稳定 |
| Exact production factory | package-only application session factory只接受 candidate + endpoint；先钉 3.2.0f SHA `05b2...f83` 与 `127.0.0.1:8710`，再内部构造 registered runner/source/composition/HMAC key；无 source/runner/argv/clock/test seam 参数 |
| Stable identity/cancellation | 3.2.0f 专用 commandless process/listener observer执行 stable pre/post bracket；source 只发 exact `list targets -v`；Process 既有 cancellation handler 只终止 ArkDeck-owned child，结果投影 unavailable |
| Refresh/overlap/reset | Workflows 以 candidate canonical identity + endpoint + execution session identity 持有唯一 session；显式 `refresh()` 最多 poll 一次；in-flight gate 令并发 refresh coalesce/返回当前 buffer；selection/bootstrap/session 变化清空旧 session/buffer/HMAC key；无 timer/background poll/retry |
| Fixture boundary | exact `--ui-test-hdc-diagnostics` 经同一 public type给出两条固定 Date 事件；无 flag/近似 flag走 production，production section 零 fixture literal/test source |

实现文件集恰为 readiness Allowed paths：

- `Packages/ArkDeckKit/Sources/ArkDeckOpenHarmony/ArkDeckOpenHarmony.swift`
- `Packages/ArkDeckKit/Sources/ArkDeckOpenHarmony/HDCProduction.swift`
- `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/HDCApplicationDiagnosticsFacade.swift`
- 新增
  `Packages/ArkDeckKit/Tests/ArkDeckContractTests/HDCDeviceObservationPresentationContractTests.swift`
- 本 run.md 与本 change `tasks.md` 的状态/pins/evidence 注记

明确零修改：

- `HDCSupervisorObservabilityContractTests.swift`
- `ArkDeckProcess.swift`
- `HDCServerLifecycleJournalAdapter.swift`
- `Package.swift`
- device-observation registry、proposal/design/verification/acceptance YAML
- `ArkDeckApp/**`、`ArkDeckAppUITests/**`

### 命令与结果

| 命令 | 结果 |
| --- | --- |
| 开工 pins：`git ls-tree` + `shasum -a 256` | readiness 表全部 source/invariant blob 与 SHA-256 精确匹配；新测试文件 absent |
| 开工 open PR 路径审计 | 0 open PR；PASS |
| 开工 `swift test --filter HDCSupervisorObservabilityContractTests` | 25 tests，0 failures，exit 0 |
| 开工 `swift test --skip-build` | exit 0；readiness 基线仍为 442 tests / 1 skipped / 0 failures |
| 重基后 `swift test --filter HDCDeviceObservationPresentationContractTests` | 18 tests，0 failures，exit 0 |
| 重基后 `swift test --filter HDCSupervisorObservabilityContractTests` | 25 tests，0 failures，exit 0 |
| 重基后全量 `swift test` | 460 tests，1 skipped，0 failures，exit 0；460 = 442 + 18 |
| `./scripts/check-sdd.sh` | 0 errors，0 warnings，111 acceptance IDs，exit 0 |
| `python3 -m unittest test_check_pr_paths -q`（`scripts/`） | 49 tests，OK |
| `git diff --check` | PASS |
| invariant `git diff --exit-code` + SHA-256 | PASS；五个关键 invariant SHA 与 readiness 完全相同 |

偏差说明：第一次实现后全量命令在 filesystem sandbox 内于 SwiftPM manifest
阶段因用户 clang module cache 不可写而 exit 1，测试未启动、不是产品/测试失败；
按仓库工具约定在 sandbox 外重跑同一命令后 460/1/0 PASS。该失败不计入
acceptance PASS，但如实保留。

### DP1-DP18 二值映射

| DP | 测试方法 | 结果 |
| --- | --- | --- |
| DP1 | `testDP1_PublicProjectionHasExactClosedReadableShapeAndRawTypesStayInternal` | PASS：exact cases/fields 可读；raw snapshot/source/composition/HMAC 零 public 暴露 |
| DP2 | `testDP2_PresentationDefaultsToEmptyEventsWithoutChangingLegacySentinels` | PASS：默认 `[]`，unprobed/loading 与旧 caller 值不变 |
| DP3 | `testDP3_AppearedAndDisappearedUseInjectedUTCFractionalRFC3339Clock` | PASS：固定 Date 得 exact 两个 UTC fractional timestamp 与 identifier regex |
| DP4 | `testDP4_UnchangedUpdatesObservationWithoutClockOrPublicHistoryGrowth` | PASS：第二次 observation 运行但 event/clock count 均不增长 |
| DP5 | `testDP5_UnknownAndUnavailableExposeNoIdentifierOrInternalReason` | PASS：两 kind、nil identifier、reason 零泄漏 |
| DP6 | `testDP6_MalformedIdentifierFailsClosedToUnknownWithoutLeakage` | PASS：非法/raw-like identifier → unknown + nil |
| DP7 | `testDP7_PublicBufferKeepsExactlyLatest64InStableOrder` | PASS：70 输入保留最新 64，首尾 timestamp/顺序精确 |
| DP8 | `testDP8_WrongCandidateSHAAppendsUnavailableWithZeroRunnerInvocation` | PASS：unavailable，runner invocation 0 |
| DP9 | `testDP9_WrongEndpointAppendsUnavailableWithZeroRunnerInvocation` | PASS：unavailable，runner invocation 0 |
| DP10 | `testDP10_IdentityUnavailableStopsBeforeRunnerInvocation` | PASS：exact declared identity但文件/receipt unavailable，runner invocation 0 |
| DP11 | `testDP11_StableBracketUsesExactRegisteredArgvOnceAndRedactsRawKey` | PASS：fake 调用日志恰一行 `list targets -v`，raw key 零 public |
| DP12 | `testDP12_PostIdentityDriftDropsPayloadAndPublishesOnlyUnavailable` | PASS：child/argv 恰一次，payload 丢弃，仅 unavailable |
| DP13 | `testDP13_ProductionFactoryHasNoSourceRunnerArgvOrTestSeam` | PASS：factory declaration/source scan 闭合；Workflows 只引用 production factory |
| DP14 | `testDP14_SequentialExplicitRefreshPollsOnceAndOverlaysSamePresentation` | PASS：两次 refresh = 两次 poll，history 逐次追加且 base presentation 其余字段不变 |
| DP15 | `testDP15_ConcurrentRefreshesCoalesceWithoutSecondPollOrQueuedRetry` | PASS：observe count 1，max in-flight 1，零排队 retry |
| DP16 | `testDP16_CancellationPublishesUnavailableAndTerminatesOnlyOwnedObservation` | PASS：owned observation termination 1；server/lifecycle/subserver/device mutation spies 全 0 |
| DP17 | `testDP17_NewSessionClearsBufferAndChangesPseudonymForSameRawKey` | PASS：replacement session buffer 从空开始；两个固定 HMAC key 得不同 pseudonym |
| DP18 | `testDP18_ExactUITestFlagProvidesPinnedEventsAndProductionHasNoFixturePoller` | PASS：exact flag 两条固定 fixture；无 flag/近似 flag production；显式 refresh 外零 poll/timer/retry |

结论：`OBS-DEVICE-PRESENTATION-001` 的 host-only contract evidence = PASS。
这不构成真实设备/M0B-002 evidence，不自行把 TASK-OBS-001R 标为 `done`，不恢复
TASK-OBS-002 readiness，也不把 change 标为 `verified`。
