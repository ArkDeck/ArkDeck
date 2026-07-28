# TASK-OBS-001 run log

## implementation + contract run（2026-07-28,host-only）

### 授权链与环境

- 授权 = Readiness r2(#678,merge `a8666bd`,本任务段 `Status: ready`)一次性
  实现授权;本 run 逐字落实该 readiness 契约与其 25 条验证计划附录,零处引用
  r1 readiness 或 prototype #265。
- 取证环境:独立非 /private/tmp worktree `~/wt-obs-impl`(CHG-2026-024 r2 教训:
  /private/tmp 检出内 Swift 契约测试红绿不可作结论;本 run 全部测试结论均在该
  非 /private/tmp 检出得出)。Apple Swift 6.3.3(arm64-apple-macosx26.0),
  Darwin 25.5.0 arm64。
- base = `origin/main` `d9aa14a6d8e73f16fabb7434db351c5e734923fe`(#679 merge),
  分支 `agent/chg-2026-022-obs-001-impl`。
- 本 run 不翻转任务 status(`ready→done` 为后续独立状态 PR),不声称 OBS-002/
  M0B-002/macOS conformance 任何进展。

### rebase 注记(沿 readiness r2 自身的 rebase 注记先例)

- 实现期间 main 前进:`d9aa14a` → `5c935568082eb150289ce71089f1b8b60c2bb6fc`
  (#680 feat(TASK-ASP-001)、#681、#682、#682 后 #685,均维护者 review/merge)。
  载体已 rebase 到该 OID;区间文件集与本 PR 文件集实测零交集
  (`git diff --name-only` 双向对比)。
- 九项 Packages pin(六 Sources + 三 Tests)在新 base 逐项 `ls-tree` 复核,
  与 readiness 表逐字节同值——Packages 构建输入零漂移(区间内 Packages 仅
  chg-2026-041 的 DeviceObservation fixtures/测试文件,不在 pin 集合内)。
- 四项 invariant(路径外)openspec pin 因上述维护者 merge 漂移(#680 的
  archive-stable provenance 重构 + #685 的 lock 行),新 OID:
  `device-observation-probes.yaml` `1130ca66`→`399c5a10`、
  `openharmony/profile.md` `32ce163d`→`8889864c`、
  `INTEGRATION-PROFILES.lock.yaml` `129abc62`→`9297820f`、
  `macos/profile.md` `2d7b2829`→`e4bcf6da`。实测 diff 仅 provenance 引用形态
  (`sourcePath` → `sourceChange`+`sourceEvidence`)与 lock 哈希行;本实现
  Sources 侧采纳的 registered family 语义字段(exactArgv/exact endpoint/
  toolContext sha 与版本/presenceRule/observedEmpty/timeout)逐项零漂移。
  「invariant」对本实现的义务——本 PR diff 对四文件逐字节零触碰——在
  rebase 后依然成立(四文件不在本 PR diff 中)。
- 新 base 基线重测(独立非 /private/tmp worktree `~/wt-obs-base` @
  `5c93556`):`Executed 415 tests, with 1 test skipped and 0 failures
  (0 unexpected) in 78.724 (78.804) seconds`,exit 0(#680 使 main 自身
  413→415)。rebase 后本树全量:`Executed 440 tests, with 1 test skipped and
  0 failures (0 unexpected) in 82.193 (82.266) seconds`,exit 0;440 = 415 +
  25,零回归结论在新 base 上重新成立。
- 第二次前进:`5c93556` → `495c7356081a83d18538ae6fcdb3e3580134dfbf`
  (#686/#688/#683,chg-2026-008 与 chg-2026-041 与 scripts/ui_dump_diagnosis
  面,维护者 merge)。载体再 rebase 到该 OID;区间与本 PR 文件集零交集,且
  区间 `git diff --name-only -- Packages/` 为空——Swift 构建输入零漂移,
  415 基线原样迁移。再 rebase 后本树全量:`Executed 440 tests, with 1 test
  skipped and 0 failures (0 unexpected) in 37.862 (37.900) seconds`,exit 0
  (440 = 415 + 25)。九项 Packages pin 于该 OID 逐项 `ls-tree` 复核仍与
  readiness 表同值;四 invariant openspec pin 较 `5c93556` 再无变化。

### Readiness pin 复核(实现开工前,`git ls-tree` 逐项)

- readiness prerequisite 2 的 14 项 pin 于 base `d9aa14a` 逐项复核:13 项内容
  pin(六 Sources、三 Tests、四 invariant openspec 文件)全部与 readiness 表
  同值,零漂移。
- 第 14 项(本 change `tasks.md`,pin 语义 =「本 PR 改前」):
  `315d1abbd9e09ab8a1103acb9c7736de6809d21a` == `a8666bd^` 实测值;当前
  `ac498a4eefd4bce7c94a47158b847af72e045cc7` == #678 merge 产物,#678 之后
  零 commit 触及本 change 目录。判定:零漂移。
- 四 invariant(路径外)文件本实现零触碰(见下文件集)。
- open PR 交集重测(readiness prerequisite 5 要求开工时以在飞集合重测):开工
  时 open PR 仅 #680(chg-2026-041,agent/task-asp-001),其文件集(新增
  DeviceObservation 测试 fixtures/新测试文件 + 四 openspec invariant 文件 +
  chg-2026-041 evidence)与本实现文件集零交集。

### 实现落点(四机制,均在 readiness 实现边界文件集内)

| 机制 | 落点 |
| --- | --- |
| (a) identity-bound successful-spawn 唯一 hook | `ArkDeckProcess.swift`:`FoundationProcessExecutor` 新增 package 级 `identityBoundSpawnObserver` 存储属性((receipt, ProcessRequest, pid_t) 三元)+ package init 缺省形参 + `startPreparedIdentityBound` spawn 成功返回点唯一一处调用;public init 保持零形参 no-op,plain `execute()` 零变更 |
| (b) opaque confirmed/managed permit | `HDCServerDispatchPermit`(class-identity,init fileprivate 于 HDCProduction.swift,值伪造不可);confirmed permit 在 `dispatchValidated` 与 lease 同回合铸造并随 lease 入 executor;managed permit 在 `authorizeManagedStart` 铸造并随 authorization 入 caller;runner 以 TaskLocal(`HDCServerDispatchPermitBinding`)把 per-execution permit 绑定到同 task 内的 hook 核验,并发无 pid→argv 合成 |
| 计数器 | `HDCSupervisorDispatchMonitor`(supervisor `nonisolated let` 持有):automaticLifecycle/automaticSubserver/confirmedLifecycle/managedStart 四计数 + 有界 spawn audit;唯一写入口 `recordIdentityBoundSpawn` 为 fileprivate,仅 runner 在同文件内构造的 hook 闭包持有;seam = `HDCDispatchInstrumentationFault.removePermitBeforeSpawn`(permit 铸造与 hook 核验之间,默认无效果) |
| subserver 族(裁定⑤) | `HDCRegisteredCommandFamily.subserver`,sealed argv = `-s <ep> spawn-sub` / `-s <ep> killall-sub`(count==3);binding 配 nil-stdout(与 lifecycle 族同构),evaluator 恒 `unknownOutput`(fail-closed);registry `subserverCapability` unsupported 注册面不动;fixture 增对应 mode(零输出 exit 0) |
| ownership `.external` 判定 | `ArkDeckOpenHarmony.swift` `observeRegisteredServerIdentity`:四证据(①bracket pre-existing receipt;②monitor automatic lifecycle == 0;③generation ∉ arkDeckLaunchedGenerations(lifecycle succeeded 与 recordManagedStart 双源记账);④managed provenance 无 active/unreconciled)齐 → 唯一生产 `.external` 铸造;任一缺 → `.unknown`;basis(`HDCServerOwnershipBasis` 四独立 Bool)逐 endpoint 留存并随 presentation 暴露 |
| managed 覆盖(裁定②) | `recordManagedStart` 留存 provenance(active)+ `recordManagedProvenanceReconciled/Retired` 显式记录;两条观察路径(`observeUnidentifiedServer`/`observeRegisteredServerIdentity`)改为 evidence 实时重验(inspector)有效 → 保持 `.arkDeckManaged`,失效 → 降 `.unknown` 并留 unreconciled 标记;internal 注入 seam(`HDCExistingServerObservation`)如实保留(裁定⑥) |
| endpoint source 穿透(裁定④) | `HDCJobToolchainSnapshot` 新增 `endpointSource`(facade 以原始 selection.source 填充);presentation 读 snapshot 原值,compose 内部重导出的 `.explicit` selection 不再进展示面;child-env 注入清单(仅键名,排序)由 makeHost 计算入 use case |
| 只读设备 fan-out | `HDCDeviceObservationFanOut`(actor,有界环形缓冲,独立 consumer 注册面)+ `HDCDeviceObservationComposition.makeProduction`(仅 `integrationRegistered` 源可入,test-only 源 fail-closed 拒绝)+ `HDCRegisteredDeviceObservationSource`(生产源腿:Sources 侧 `HDCDeviceObservationProbeCatalog` 闭合采纳 `OPENHARMONY-HDC-DEVICE-OBSERVATION-PROBES@1.0.0` 唯一 entry 的 exactArgv/exact endpoint/identity bracket/presenceRule/observedEmpty 语义,连接键经 per-session HMAC-SHA-256 脱敏 `redacted-device-<24hex>`) |
| caller 无 origin | 新监控面零 public/package 写入口:permit init fileprivate、monitor 记录口 fileprivate、monitor 装配 init 为 module-internal;`FoundationProcessExecutor` public init 零 hook 形参(C6 源面扫描背书) |

### 文件集(git status 实测;== readiness 实现边界)

- Sources(5/6;`HDCReadOnlyProbeRegistry.swift` 属「仅如需」项,未需要,零触碰):
  `ArkDeckProcess/ArkDeckProcess.swift`、`ArkDeckOpenHarmony/HDCProduction.swift`、
  `ArkDeckOpenHarmony/ArkDeckOpenHarmony.swift`、
  `ArkDeckWorkflows/HDCApplicationDiagnosticsFacade.swift`、
  `ArkDeckWorkflows/HDCServerLifecycleJournalAdapter.swift`
- Tests:新契约文件 `ArkDeckContractTests/HDCSupervisorObservabilityContractTests.swift`
  (25 用例)+ `ArkDeckFakeHDCFixture/main.swift`(仅新增 subserver mode)
- evidence:本文件
- `Package.swift`、App、Core contract/schema、chg-2026-022 之外 openspec、
  `HDCSupervisorContractTests.swift`、`ArkDeckContractTests.swift`:零改动
  (既有用例零修改腿由 diff 文件集直接背书:两个既有契约测试文件不在 diff 中)

### 命令与结果(全部于 `~/wt-obs-impl` 实测;汇总行取自完整输出文件)

| 命令 | 结果 |
| --- | --- |
| 基线 `swift test`(改动前,base 树) | `Executed 413 tests, with 1 test skipped and 0 failures (0 unexpected) in 38.085 (38.117) seconds`,exit 0(== readiness r2 基线 413/1/0) |
| `swift build`(改动后) | exit 0,0 error |
| `swift test --filter HDCSupervisorObservabilityContractTests` | `Executed 25 tests, with 0 failures (0 unexpected) in 2.214 (2.216) seconds`,exit 0 |
| 全量 `swift test`(改动后) | `Executed 438 tests, with 1 test skipped and 0 failures (0 unexpected) in 39.483 (39.517) seconds`,exit 0;438 = 413 + 25,零回归、既有 skip 不变 |
| `./scripts/check-sdd.sh` | `check_sdd: 0 error(s), 0 warning(s), 111 acceptance IDs`,exit 0 |
| `git diff --check` | 干净 |
| `scripts/check_pr_paths.py` 模拟判定 | PASS(见下节,against 实现 commit;title 声明 TASK-OBS-001,文件集 = 上表) |

### 25 条验收逐条映射(readiness 验证计划附录 → 测试名 → 结果)

| # | 测试 | 结果 |
| --- | --- | --- |
| C1 | `testOBS_C1_ConfirmedChainWithIntactPermitCountsConfirmedNotAutomatic` | PASS(日志恰 1 行 `-s <ep> kill -r`;automatic 两计数 == 0;confirmed 计数/审计 == 1) |
| C2 | `testOBS_C2_PermitRemovedBeforeSpawnCountsAutomaticLifecycleThroughSameHook` | PASS(同链同 argv,seam 移除 permit;日志 +1;automatic lifecycle 0→1;subserver 恒 0;confirmed 0) |
| C3 | `testOBS_C3_SealedSubserverFamilySpawnCountsAutomaticSubserver` | PASS(`-s <ep> spawn-sub` 经同一 runner+hook 真实 spawn;subserver 0→1;lifecycle 计数不动;日志 +1;semantic 恒 unknownOutput) |
| C4 | `testOBS_C4_CountersAreMeasuredValuesNotBranchConstants` | PASS(两次变异后恰 == 2;三次无 spawn 刷新计数不变;计数差 == 日志行数差逐值相等) |
| C5 | `testOBS_C5_PreSpawnFailuresDoNotCount` | PASS((i) prepare 期 hash 不匹配、(ii) gate invalidation 赢在 posix_spawn 前:两情形日志 +0、全计数不变;(ii) 保持既有 outcomeUnknown 文案逐字) |
| C6 | `testOBS_C6_DeclarationAndSourceSurfaceScan` | PASS(ArkDeckProcess/HDCProduction 全词 origin == 0;public init 零 hook 形参;记录口 fileprivate 非 public/package;Sources `.external` 构造点精确集合 == 判定落点 1 处 + Facade fixture 2 处) |
| C7 | `testOBS_C7_ManagedPermitPositiveControlSpawnsThroughSameHook` | PASS(absent-endpoint 授权铸 permit;fixture managed-server 经同一 hook spawn 日志 +1;automatic 两计数 0;recordManagedStart 以真实 PID/argv/监听证据 → arkDeckManaged) |
| C8 | `testOBS_C8_PresentationMirrorsMonitorSnapshotWithoutRenamingOrSubtraction` | PASS(presentation autoLifecycle/autoSubserver 逐值 == monitor 快照;confirmed/managed 字段名+值双断言,未相减未改名) |
| O1 | `testOBS_O1_AllFourEvidenceItemsClassifyExternalWithBasis` | PASS(四证据齐 → external;basis 四项逐一 present) |
| O2 | `testOBS_O2_UnavailableBeforeReceiptSpawnsNothingAndStaysUnknown` | PASS(before 收据 unavailable → 零 checkserver spawn(日志 +0)、ownership 保持 unknown) |
| O3 | `testOBS_O3_NonzeroAutomaticLifecycleCountBlocksExternal` | PASS(C2 变异使计数 == 1 后合格观察 → unknown;basis ② absent、其余 present) |
| O4 | `testOBS_O4_LifecycleMintedGenerationBlocksExternal` | PASS(lifecycle succeeded 铸的 generation → unknown;basis ③ absent、其余 present) |
| O5 | `testOBS_O5_LiveManagedClaimIsRetainedWithBasis` | PASS(活体 managed claim 经合格 bracket → arkDeckManaged;basis ④ absent;managed evidence live == true) |
| O6 | `testOBS_O6_ManagedToExternalProhibitionMatrix` | PASS(M1 live→managed;M2 evidence 失效无 reconcile→unknown+unreconciled;M3 reconcile 后同周期 bracket→unknown;M4 retire 后独立新观察→external 唯一放行;M5 失忆≠出清→unknown;M6 observeUnidentifiedServer 遇 live claim→managed) |
| O7 | `testOBS_O7_ExternalUnknownGateEquivalenceDiff` | PASS(双臂 preview/confirm/dispatch/startManaged/critical-job/consumeDispatchLease 逐步 gate 结果相等;显式断言仅 ownership 字面与 scopeHash 两处差异;第二条腿 = 既有门测试零修改,由 diff 文件集背书) |
| O8 | `testOBS_O8_BasisExposureIsPerEvidenceBinary` | PASS(basis 恰四独立 Bool、标签精确集合、无聚合布尔;两向量逐格断言;presentation 透传逐格相等) |
| E1 | `testOBS_E1_EndpointSourceThreeStatesPresentedTruthfully` | PASS(explicit/inheritedEnvironment/default 三态逐一如实) |
| E2 | `testOBS_E2_ChildEnvironmentInjectionListIsExactKeySet` | PASS(清单 ==(排序)`ARKDECK_FAKE_HDC_INVOCATION_LOG`+`OHOS_HDC_SERVER_PORT` 两键精确集合、只含键;键冲突 selection 值胜出断言一次) |
| E3 | `testOBS_E3_ParentProcessEnvironmentSnapshotUnchanged` | PASS(含真实 child spawn 的全流程前后 ProcessInfo 环境逐键相等;既有 child-only overlay 断言零修改沿用) |
| E4 | `testOBS_E4_DefaultAndInheritedSourcesSurviveComposition` | PASS(default/inherited 经 compose 后 presentation source 仍为原值,未被翻成 explicit) |
| F1 | `testOBS_F1_TypedSnapshotSequenceDiffsAppearedUnchangedDisappeared` | PASS(A,B→B,C→成功空→failure/unknown 事件逐条相等;observedEmpty 两形态(`[Empty]` marker/全 Offline)等价;failure/unknown 零 disappearance + unknown 标记;presence 按 registered presenceRule state 列判定) |
| F2 | `testOBS_F2_BoundedBufferKeepsLatestEventsInStableOrder` | PASS(容量 4 推 9 条:len == 4、内容 == 最新 4 条逐条相等、序稳定) |
| F3 | `testOBS_F3_FullFanOutCompositionIssuesOnlyRegisteredArgv` | PASS(完整组合对 fixture 运行;调用日志恰 `list targets -v` ∈ 注册 exact argv 集;族存在性与 registered family 绑定,族缺席时 XCTFail 硬失败而非 skip;raw 连接键零出现) |
| F4 | `testOBS_F4_DeviceRecipientsAreSeparatedFromLifecycleImpact` | PASS(impact snapshot affected 集合精确 == 仅 lifecycle 参与者;设备消费者收设备事件、lifecycle 广播零到达;双向) |
| F5 | `testOBS_F5_TestOnlySnapshotSourceIsRejectedFromProductionComposition` | PASS(test-only 源接生产组合入口 → `testOnlySnapshotSourceRejected` fail-closed;integration 源标记唯一放行) |

四 change-local AC 对应:OBS-COUNTER-001 = C1-C8;OBS-OWNERSHIP-001 = O1-O8;
OBS-ENDPOINT-001 = E1-E4;OBS-FANOUT-001 = F1-F5(生产源腿语义以 CHG-2026-024
registered family 为唯一输入;F 组绿不构成 M0B-002 真机观察进展)。

### 不变量与反作弊自查

- 零 lifecycle/dispatch/安全门语义变更:permit/monitor 纯观察,不参与任何门;
  scopeHash 编成与 lease 比较零改动(裁定③);`in-flight` scope 因判定升级而
  stale 属既有 fail-closed 行为。全量 438/1/0 背书。
- 反作弊红线逐条:零处直接调用 monitor record(fileprivate,测试不可达);零
  origin 枚举/字符串/flag(C6 扫描);无「类型存在即过」断言(全部值断言);
  confirmed/managed 未被相减冒充 automatic(C8);F3 族缺席 XCTFail 非 skip;
  生产路径零 fixture 注入(F5 + facade `--ui-test-hdc-diagnostics` 既有边界)。
- `ArkDeckProcess.swift` 单列风险(HDC/Rockchip/discovery 共用 spawn 路径):
  仅新增回调存储属性、package init 缺省形参与成功点一处调用;public API 零
  变更;全量零回归 + C5/C6 背书。
- #265 任何测试/evidence/PASS 数字零引用。
