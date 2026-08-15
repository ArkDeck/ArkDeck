# Verification — CHG-2026-055

> Change:CHG-2026-055-harness-final-architecture@r3

Status:in_progress # r1(2026-07-31):TASK-HFA-001/002/008 已 done,
HFA-AC-1/2/3/4/5/17 有结论;其余 HFA-AC 仍 `pending`(未开工)。
r2(2026-08-01):TASK-HFA-005 真机闭环完成,HFA-AC-11/12=`PASS`,GJ-5=
`REAL_DEVICE_PASS`;其余结论见各 AC 段。
每条结论由其所属任务的实现 PR 写入本文件;维护者 review/merge 该实现 PR 即确认。
不为本 change 追加独立 verification/archive 载体(`PRODUCT-LOOP.md` §4/§20)。

约定:

- 结论只能取 `PASS` / `FAIL` / `pending`(未开工)/ `pending-hardware`(缺设备窗口,
  如实分类,不得以 fake/simulation 顶替);
- 每条结论必须给出可复查的落点(测试名、命令、退出码、artifact hash、脱敏设备标识);
- **HFA-AC-11/HFA-AC-12 是 GJ-5 唯一可写 `REAL_DEVICE_PASS` 的依据**,且必须在当前
  catalog digest 上取得;
- 判定面的每条 AC 都必须包含至少一条"证据缺席/不可解析时不判成功"的负例落点。

## HFA-AC-1 崩溃判定以崩溃台账为源(TASK-HFA-001)

- 方法:用真实 fault log 字节样本(CHG-2026-049 TASK-DHA-005 窗口产出)驱动
  observation builder,断言 crash signature、reason、进程/包名被正确提取,
  并与 goal 的 `crashSignature` 匹配计数;同一样本下 `matchingCrashCount > 0` 时
  mandatory criterion 不得 PASS。
- Evidence:实现 PR 内测试 + 全量套件结果 + `evidence/runs/TASK-HFA-001/run-r1.md`。
- **结论(2026-07-31):PASS** —— `testRealJsCrashEntryYieldsItsReasonAndSourceLocation`
  用**真机字节**(DAYU200 / OH 3.2 / Build 7.0.0.36,`hidumper -s 1201 -a
  "-p Faultlogger -f <条目名>"`)解出 `jscrash:TypeError+entry/src/main/ets/
  crashprobe/CrashProbe.ets:36:16`,kind / bundle / uid / 时间戳逐字段断言
  (`testEntryNameDecomposition`);`testAMatchingLedgerEntryKeepsTheMandatoryCriterion
  FromPassing` 断言同一样本下 mandatory criterion 判 `fail` 而非 PASS。
  另有 r6 回归 `testHilogNeverContributesCrashCountsAnyMore`:hilog 即便带 fault
  block 也不再产出崩溃计数,故同一次崩溃不会被两个源各计一次。
  **样本来源如实标注**:索引与 jscrash 正文为真机字节(fingerprint/unique id 已
  mask、尾部 `HiLog:` 段截断);cppcrash 与 appfreeze 正文按文档形态手写,**非真机**
  —— 设备当前只有一条 jscrash 条目,再取需真造崩溃(属设备状态改变,未做)。

## HFA-AC-2 证据缺席不得判成功(TASK-HFA-001)

- 方法:三条独立负例——①声明的崩溃证据产物缺席/`missing`/`truncated` → `INCONCLUSIVE`;
  ②台账为空且工具正常返回 → 可作为"无匹配崩溃"正证据(与"没采到"可区分);
  ③条目不可解析 → `ERROR` + `evidenceIntegrity` 人工阻塞。并保留 r6 真实场景回归
  (真实 crash 之后不得出现 verdict `pass`)。
- Evidence:实现 PR 内测试。
- **结论(2026-07-31):PASS** —— 三条负例各有独立用例:
  ①`testAbsentLedgerIsInconclusiveAndNeverPasses`(`artifactNotCollected:
  crash-index.txt` → `INCONCLUSIVE`,且该轮不产出任何崩溃计数,故"没看"不会被写成
  "没有");②`testEmptyLedgerAndMissingLedgerAreDifferentAnswers`(空台账 —— 设备
  答了 `No fault log exist.` —— 计 0 且零 blocker;缺席则只有 blocker、无计数);
  ③`testUnreadableLedgerIsAnIntegrityBlockerNotAnEmptyLedger`(非台账字节 →
  `crashLedgerUnreadable:crash-index.txt:ledgerHeaderAbsent`;不可解析条目名 →
  `…:entryNameUnparseable`;二者均进 `integrityBlockers` → `ERROR` + 人工阻塞,
  **绝不退化成空台账**)。
  另有水位线用例 `testHistoricEntriesAreNotCountedAndFreshOnesAreCountedOnce`:
  设备上的历史条目连跑 5 轮累计仍为 0(否则 `== 0` 的判据永不可达、修好也判不出),
  水位之后的新条目恰好计一次、再看一轮不重复计入。

## HFA-AC-3 Stale decision 不执行(TASK-HFA-002)

- 方法:逐前置各一条竞态用例——state version 递增后、contextDigest 变化后、
  人工 resolution 之后、binding revision 变化后,旧 decision 一律被拒且零副作用;
  同一事务内校验(并发 accept 只有一条成功)。
- Evidence:实现 PR 内测试。
- **结论(2026-07-31):PASS** —— 闸门落在 `dispatch()` 的第一句(重新 load → 重建 basis →
  `HarnessDecisionFreshness.staleness()`),因此拒绝发生在 `putIntent`/`submit` **之前**。
  `testAHumanResolutionDuringPlanningStopsTheDispatch` 用真实竞态:fake gateway 在
  `propose()` 里回调 `coordinator.pause` + `resume`(这正是 actor 在网络往返处被挂起的窗口),
  断言 action=`staleDecision`、reasonCode 前缀 `decisionStale:stateVersion`、
  **提交给引擎的请求为 0**、`decisionStale` 事件恰一条且无 `jobDispatched`。
  `testACancelDuringPlanningStopsTheDispatch` 覆盖窗口内取消(任务已终态,不再写状态,
  仍零提交)。`testAChangedBasisIsStaleEvenWhenTheVersionHeld` 覆盖 version 未动而
  offered operation 收窄的情形——version 计数器单独抓不到这一类。
  `testAnActiveJobAppearingUnderAProposalIsStale` 与
  `testADecisionWithoutABasisIsUnverifiableRatherThanFresh`(旧记录 fail closed)补齐负例。
  **变异对照**:把 freshness 检查改为 `if false, ...` 后,同一用例得到
  `("dispatched") is not equal to ("staleDecision")` 且请求真的提交 —— 这条 guard 挡的是
  实存缺陷,不是理论风险。

## HFA-AC-4 Stale 的代价语义与失败区分(TASK-HFA-002)

- 方法:断言 stale 不计策略失败、不增 no-progress 轮次、不写 failure fingerprint,
  但已发生的 model call 计入预算;stale 之后重新组装 context 产生**不同** digest。
- Evidence:实现 PR 内测试。
- **结论(2026-07-31):PASS** —— `testAStaleWakeChargesNoFailureNoProgressAndNoBudget`
  断言陈旧轮之后 `noProgressRounds == 0`、`consumedBudget == HarnessConsumedBudget()`(全 0)、
  `store.failureRecords()` 为空;随后**下一轮正常派发**(闭环没有被自己的陈旧决策毒化)。
  代价语义写在 `HarnessDecisionStaleness` 的类型注释里:陈旧不是策略失败,把它记成失败
  会让操作员自己的 resolution 把任务推向 `strategyExhausted`。

## HFA-AC-5 Context digest 可复算且 ModelRun 完整(TASK-HFA-002)

- 方法:同一 task state version + 同一持久化事实 → 同一 `contextDigest`(重复组装断言);
  digest 在脱敏之后计算(含未脱敏字节的输入不会产生相同 digest);ModelRun 记录字段齐全
  (provider/model/adapterVersion/observedStateVersion/contextDigest/tokens/schema 校验/decisionId)。
- Evidence:实现 PR 内测试。
- **结论(2026-07-31):PASS,含两处如实登记的偏离** ——
  `testTheBasisDigestIsReproducibleAndMovesOnlyWithPersistedFacts`:同一 snapshot 两次取
  basis digest 相同、长度 64;offered 集合的**顺序**不是事实(digest 不变);`observedState`
  变化则 digest 变化。时钟类字段一律不进 basis —— 否则每个决策一秒后都会"陈旧",那是
  停摆不是护栏。`testAnAcceptedProposalRecordsTheModelCallItCameFrom` 断言 ModelRun 与它
  产出的 decision 的 `observedStateVersion` 相等、`contextDigest` 等于 gateway 实收 context 的
  `transmittedDigest`(该 digest 在裁剪与出站筛查**之后**计算,代表真正离开本机的字节);
  `testARefusedProposalStillRecordsTheModelCall` 断言被解析器整条拒绝的调用同样留有记录
  (调用发生过、context 出过站,这是事实);`testAModelRunIdCannotEscapeItsTaskDirectory`
  钉死文件名文法。
  **偏离一(命名)**:decision 上的字段叫 `basisDigest`(§11.4 的 contextHash 位置),
  模型实收字节的 digest 是 `HarnessModelRun.contextDigest`(§12.9)。二者回答不同问题,
  共用一个名字会让后者消失。
  **偏离二(token)**:决策端口返回 `Data`,token 是端口看不见的厂商概念,故记**实测字节数**
  (`contextBytes`/`responseBytes`)而不是猜的 token;`HarnessModelDescriptor` 默认只写端口
  真正知道的 producerID,其余标 `unspecified`。真实 usage 待 TASK-HFA-011。

## HFA-AC-6 `PROPOSE_PATCH` 越界整条拒绝(TASK-HFA-003)

- 方法:负例集——超 `maxPatchBytes`、超文件数、写入 ProjectProfile 未声明的 glob、
  二进制 patch、符号链接、`..` 路径逃逸、`.git` 内部修改、base revision 失配,
  各自断言整条 decision 被拒且零 ActionRun、零 apply。
- Evidence:实现 PR 内测试。
- **结论(2026-08-01,第三方补记 —— 由非实现方核验已合入的代码与测试,方法见 `evidence/runs/LEDGER-BACKFILL/2026-08-01.md`):PASS** ——
  `HarnessRepairContractTests.testProposePatchSchemaRejectsEverySyntacticEscapeBeforeDispatch`
  覆盖 schema 面的整条拒绝;`testWorkspaceProfileGlobSymlinkAndBaseMismatchPublishNoPatchArtifact`
  覆盖 glob 越界、symlink 与 base 失配三类,并断言**不发布 patch artifact**
  —— 即拒绝发生在产出之前,而不是产出后再回收。(TASK-HFA-003,合入 `4cec8b87`)

## HFA-AC-7 三条 stage gate 是结构性相等判定(TASK-HFA-003)

- 方法:分别构造 ①applied-patch readback revision ≠ Attempt.patchRevision、
  ②build source revision ≠ 当前 patch revision、③部署 readback digest ≠ build output digest,
  断言各自不得进入下一 stage;相等时才推进。
- Evidence:实现 PR 内测试。
- **结论(2026-08-01,第三方补记 —— 由非实现方核验已合入的代码与测试,方法见 `evidence/runs/LEDGER-BACKFILL/2026-08-01.md`):PASS** ——
  `HarnessRepairContractTests.testAllThreeStageGatesRequireStructuralEquality` 逐条覆盖三条 gate;
  `testBuildSourceRevisionMustEqualPatchRevisionBeforeTestsDispatch` 单独钉住
  「build 的 source revision 必须等于当前 patch revision」这条最容易被"看起来成功"绕过的相等判定。
  (TASK-HFA-003)

## HFA-AC-8 未知结果不重复 apply、失败必回滚(TASK-HFA-003)

- 方法:apply 结果未知时只走 readback 四态判定(`PATCH_APPLIED`/`PATCH_NOT_APPLIED`/
  `STILL_UNKNOWN`/`PARTIALLY_APPLIED`),断言零第二次 apply;部署或复验失败触发
  `workspace.revertPatch@1` 且回滚消耗 E1 预算;回滚结果未知 → 人工阻塞,不重复回滚。
- Evidence:实现 PR 内测试。
- **结论(2026-08-01,第三方补记 —— 由非实现方核验已合入的代码与测试,方法见 `evidence/runs/LEDGER-BACKFILL/2026-08-01.md`):PASS** ——
  `testUnknownApplyUsesFourStateReadbackAndNeverSubmitsASecondApply` 断言未知结果只走四态
  readback 且**零第二次 apply**;`testDeploymentDigestMismatchDispatchesTypedRollbackAndChargesBudget`
  与 `testVerificationFailureDispatchesTypedRollbackAndChargesBudget` 断言部署 digest 不符与
  复验失败各自触发 typed 回滚**并计入预算**(回滚本身也是 E1,不白送)。
  `testSemanticRepairFailuresRequireAnAlternativeStrategy` 补上「语义失败要求新策略而非原样重试」。
  (TASK-HFA-003)

## HFA-AC-9 重复策略不得伪装成新 Attempt(TASK-HFA-004)

- 方法:同 patch digest + 同 base revision + 同 build preset + 同 failure fingerprint,
  仅改写 hypothesis 文本,断言 `DUPLICATE_STRATEGY` 拒绝、不新建 Attempt、不派发 job;
  七要素任一变化则允许新 Attempt(正例)。
- Evidence:实现 PR 内测试。
- **结论(2026-08-01,第三方补记 —— 由非实现方核验已合入的代码与测试,方法见 `evidence/runs/LEDGER-BACKFILL/2026-08-01.md`):PASS** ——
  `HarnessAttemptContractTests.testStrategyFingerprintUsesTheSevenCanonicalElementsButNotHypothesisProse`
  正面钉住七要素参与、hypothesis 散文不参与;
  `testRewordedFailedPatchIsRejectedBeforeAnotherAttemptOrDispatch` 与
  `testCoordinatorRejectsRewordedPatchAfterBuildFailureWithoutSecondApply` 从两个层面
  (决策面与 coordinator 面)断言「改写措辞的同一补丁」被拒且**不产生第二次 apply**。
  (TASK-HFA-004,合入 `ba5b21ec`)

## HFA-AC-10 Action Retry 与 Strategy Attempt 分离、无进展可停止(TASK-HFA-004)

- 方法:瞬态失败 → 同 Attempt 新 ActionRun(崩溃重放用原 idempotencyKey、确认重试用新 key);
  只重新分析/总结/规划、相同 decision fingerprint、workspace 回到同一 revision 一律不计进展;
  连续 `maxNoProgressRounds` 后关闭当前 Attempt 并要求新 strategy fingerprint,
  无安全替代 → 人工阻塞或 FAILED。
- Evidence:实现 PR 内测试。
- **结论(2026-08-01,第三方补记 —— 由非实现方核验已合入的代码与测试,方法见 `evidence/runs/LEDGER-BACKFILL/2026-08-01.md`):PASS** ——
  `testActionRetryCrashReplayAndSemanticAlternativeAreDifferentRoutes` 把三条路径分开钉死;
  `testPendingIntentCrashWindowRestoresOriginalActionRunBeforeDispatch` 覆盖崩溃重放走**原**
  ActionRun;`testRepeatedVerificationCapturesAreSamplesNotDuplicateStrategies` 覆盖「复验采样
  不是重复策略」这条最容易误杀的边界;`testAttemptEventsAreDurableAndRejectRegression` 与
  `testHumanResolutionReactivatesTheSameAttemptWithoutLosingItsHistory` 覆盖持久化与人工恢复。
  (TASK-HFA-004)

## HFA-AC-11 真机:一次 submit 完成含修复腿的收敛,人工步骤 0(TASK-HFA-005)

- 方法:已接管 DAYU200 + 当前 catalog digest,一次 `task submit` 跑通
  运行 → 采集 → 判定 → patch → build → 部署 → 复验;记录人工步骤计数、每轮
  decision/attempt/job/artifact 链、预算消耗与停止原因。
- Evidence:设备窗口 run 记录(命令、退出码、artifact hash、脱敏设备标识、capability ID)。
- **结论(2026-08-01,`evidence/runs/TASK-HFA-005/run-r2.md`):PASS** ——
  `HTASK-89586A62D3CD` 在当前 catalog digest `44b6728d…af5ec6` 上由一次 submit
  自动收敛到 `succeeded/criteriaPassed`:20 rounds / 416s / 20 model calls /
  2 E1 mutations,human actions `[]`。精确 patch 后 build/test succeeded,构建产物与
  部署读回 SHA-256 同为 `6263bb8a…87e8`;两次设备 mutation 均有 exact-input、
  binding-revision-1 的 RuntimeCapability consumption,终态后 typed cleanup 也 succeeded、
  residue `0`。故人工步骤计数为 0,GJ-5 可如实写 `REAL_DEVICE_PASS`。
  **⚠ digest 变动(TASK-HFA-009 r2,同一 change 内):** 本结论取得于 catalog digest
  `44b6728d…af5ec6`。r2 把五个 workspace 变更 operation 升为 E1(effect / authorization /
  defaultPolicyIssuance 三处描述符改动),digest 因此移动到 `577a8ca1…19b8`。按
  `PRODUCT-LOOP.md` §6「`REAL_DEVICE_PASS` 必须在**当前** catalog digest 上取得,旧 digest
  的真机记录只证明历史」,**r2 合入后 GJ-5 需在新 digest 上重取**;本条结论作为历史记录保留,
  不撤销、不追认。维护者 2026-08-01 决定:先合 r2,窗口另行安排。

## HFA-AC-12 真机:注入真实崩溃后不得判 PASS(TASK-HFA-005)

- 方法:在真机上注入可复现的目标崩溃,断言 verdict 不是 `pass`(关闭 r6 假阳性);
  修复后复验 `PASS`。两条证据缺一不可,缺则 GJ-5 不得写 `REAL_DEVICE_PASS`。
- Evidence:同上窗口记录 + 两轮 verdict 的 evaluation ID。
- **结论(2026-08-01,`evidence/runs/TASK-HFA-005/run-r2.md`):PASS** ——
  baseline crash fixture 部署后,round 6 `EVAL-202905F2F681=fail`:
  `applicationLiveness=unhealthy`,`matchingCrashCount=1`,且目标签名为
  `jscrash:com.example.waterflowdemo`,没有假阳性 PASS。修复、构建、测试并部署同一
  digest 后,round 20 `EVAL-64B95811F714=pass`;连续 5 个样本均为
  `healthy / matchingCrashCount=0 / newFatalSignatureCount=0`。两条证据完整。
  **⚠ digest 变动(TASK-HFA-009 r2,同一 change 内):** 本结论取得于 catalog digest
  `44b6728d…af5ec6`。r2 把五个 workspace 变更 operation 升为 E1(effect / authorization /
  defaultPolicyIssuance 三处描述符改动),digest 因此移动到 `577a8ca1…19b8`。按
  `PRODUCT-LOOP.md` §6「`REAL_DEVICE_PASS` 必须在**当前** catalog digest 上取得,旧 digest
  的真机记录只证明历史」,**r2 合入后 GJ-5 需在新 digest 上重取**;本条结论作为历史记录保留,
  不撤销、不追认。维护者 2026-08-01 决定:先合 r2,窗口另行安排。

## HFA-AC-13 设备瞬断不回退业务进度(TASK-HFA-006)

- 方法:stage = VERIFYING 时令 `DeviceReady` 变 FALSE,断言 lifecycle → `waiting`、
  **stage 不变**;设备恢复且 binding 仍合法 → 回到 running、stage 仍不变;
  binding revision 变化未确认 → `DeviceBound=UNKNOWN` 且旧 decision 全部 stale;
  stage gate 表逐格负例。
- Evidence:实现 PR 内测试。
- **结论(2026-08-01,第三方补记 —— 方法见 `evidence/runs/LEDGER-BACKFILL/2026-08-01.md`):PASS** ——
  `HarnessThreeDimensionalStateContractTests.testTransientDisconnectRecoveryAndBindingDriftNeverRewindStage`
  正是本条的核心断言:瞬断恢复与 binding 漂移都**不回退 stage**;
  `testEveryRequiredStageGateCellRejectsFalseAndUnknown` 覆盖 gate 表**逐格**对 FALSE 与
  UNKNOWN 的拒绝(UNKNOWN 与 FALSE 分开处理是三态模型的要害);
  `testConditionChangesParticipateInTheDecisionBasis` 把 condition 变化接进 TASK-HFA-002 的
  防陈旧基线 —— condition 动了,旧决策即陈旧;
  `testCanonicalWaitingRecordsFailClosedWithoutAnExactReason` 断言 waiting 必须带确切 reason,
  不接受笼统等待。(TASK-HFA-006,合入 `0c537d82`)

## HFA-AC-14 既有任务前向迁移逐字保持(TASK-HFA-006)

- 方法:以 CHG-2026-054 真机窗口留下的持久化任务目录为输入跑迁移,断言迁移后
  `task.status`/`task.events`/`task.result` 逐字保持,`paused` → `waiting +
  USER_SUSPENDED`、历史 `deviceReady` phase → `stage=REPRODUCING + DeviceReady=UNKNOWN`。
- Evidence:实现 PR 内测试 + 使用的历史任务目录标识。
- **结论(2026-08-01,第三方补记 —— 方法见 `evidence/runs/LEDGER-BACKFILL/2026-08-01.md`):PASS** ——
  `testHistoricalSchemaOneDirectoryMigratesWithoutChangingTimelineBytes` 断言历史目录迁移后
  **时间线字节不变**;`testHistoricalResultSurvivesForwardMigration` 断言 result 存活。
  这两条正是本 AC 要的「逐字保持」。(TASK-HFA-006)

## HFA-AC-15 Analyzer 确定性、版本化且 provenance 完整(TASK-HFA-007)

- 方法:同一输入 artifact 重复运行产出**逐字节相同**的 derived artifact;derived artifact
  带 sourceArtifactIds/hashes、analyzerRef@version、revision 作用域、redaction 状态、
  content hash;分析结论不改变 task 状态(负例)。
- Evidence:实现 PR 内测试 + catalog digest 更新 + 生成器零 drift。
- **结论(2026-07-31):PASS** —— `AnalyzerProviderContractTests` 9 例:
  `testTheSameArtifactProducesTheSameActionAndTheSamePlan` 断言同一输入两次得到**相同**
  action 与相同 argv(pinned 可执行 + 固定参数 + 引擎已解析的 artifact 路径);
  `testTheDerivedResultCarriesItsWholeProvenance` 断言 verify summary 携带
  analyzerRef、analyzerVersion、sourceArtifactId、sourceSha256、derivedSha256(64 位)
  与字节数 —— 一条结论必须能追到它来自哪份字节、由哪个版本的代码产出;
  `testAnArtifactThatDoesNotMatchItsLeaseIsRefused` 断言 lease 与字节不符即拒绝;
  `testAnEmptyOrUnstructuredResultIsAFailureAndNotAConclusion` 三条负例(空输出、
  非 JSON、非零退出)各自判 failed;
  `testRecoveryOfAnAnalysisConfirmsNothingHappened` 断言分析不留外部副作用;
  `testTheCatalogPublishesAnalyzersAsHostOnlyReads` 断言三个 operation 都是
  `provider: analyzer` / `binding: none` / `hostOnly`,且产物名与引擎物化用的是**同一张表**。

## HFA-AC-16 外部工具不得走 engine-internal 例外(TASK-HFA-007)

- 方法:负例——声明为 analyzer engine-internal 例外的 step 若 spawn 子进程或访问声明外
  路径/网络,一律拒绝;外部 symbolizer/parser 必须经 `arkdeck-analyzer` provider 与
  `DescriptorBoundProcessDispatcher`;provider/工具未配置 → `UNAVAILABLE` 带机器可读原因
  且零 capability 消耗。
- Evidence:实现 PR 内测试。
- **结论(2026-07-31):PASS** ——
  `testAnUnconfiguredAnalyzerIsUnavailableRatherThanImprovised` 断言未注册 profile 时
  三个 operation 一律 `UNAVAILABLE` + 机器可读原因 `analyzer.profileUnavailable`,
  零 capability 消耗(§8);`testAToolThatDriftedFromItsPinIsUnavailable` 断言二进制
  与 pin 漂移即不可用;`testAnAnalysisPlanIsRefusedWhenNoAnalyzerRouteIsRegistered`
  断言 analyzer 计划**不会**被送进 workspace 路由(那条路由拥有另一组可执行文件),
  无独立路由即拒绝。step kind 的 `analyzerRef` 是封闭枚举,任意程序不可被命名。
  **未覆盖(如实)**:engine-internal 例外(纯内存转换)本身没有新增负例 —— 本任务没有
  引入该例外的实现,TASK-HFA-001 的就地解析仍在原位、尚未改接 derived artifact,
  改接属规划面变更,留待 TASK-HFA-005 的真机链路一并验证。

## HFA-AC-17 workspace 只读族 typed-only 且 argv 逐 token 正确(TASK-HFA-008)

- 方法:八个 operation 各有 argv 逐 token 断言(沿用 `DeviceProviderArgvContractTests` 范式)
  与 typed inputs 边界用例;`runShell`/`executeCommand`/`runArbitraryScript`/`runGit`/
  `writeFile` 在契约面不可表达(负例);scope 逃逸与 byte budget 超限 fail closed;
  `createCheckpoint@1` 有 readback 与 revert 配对。
- Evidence:实现 PR 内测试 + catalog digest 更新 + 生成器零 drift。
- **结论(2026-07-31):PASS,范围按实际能力交付** ——
  `WorkspaceReadOnlyOperationsContractTests` 14 例:
  `testGitStatusLowersRootBoundArgvTokenForToken` 与
  `testDiffLowersRevisionAndScopeAfterTheOptionTerminator` 逐 token 断言生产 argv
  (含 `-C <resolved root>` 前置与 `--` 终止符的**位置**);
  `testARevisionOrScopeThatCouldBecomeAnOptionOrAPathIsRefused` 用 11 个负例钉死
  「输入不得变成选项或路径」(`-f…`、`../etc`、`/etc/passwd`、`Sources/$(id)`、空串);
  `testAnUnboundedOrEscapingReadRangeIsRefused` 断言超界跨度、倒置区间、traversal、
  绝对路径、profile glob 外路径一律拒绝;
  `testACheckpointLowersStashCreateAndMovesNothing` 断言 checkpoint 是
  `stash create`(写对象、不动 ref/index/worktree),且 argv 里没有 `push`/`commit`;
  `testACheckpointWithoutAnObjectIsAFailureNotASuccess` 断言空 checkpoint 判 failed
  (否则修复腿会以为自己可以回滚);
  `testWithoutAPinnedSourceControlToolBothOperationsReportUnavailable` 断言未配置
  pinned 工具时 `UNAVAILABLE` + 机器可读原因且零 capability 消耗(§8);
  `testTheForbiddenWorkspaceSurfacesAreNotExpressible` 断言
  `run-shell`/`execute-command`/`run-git`/`write-file`/`run-arbitrary-script`
  在已发布 catalog 中不存在。
  **范围登记**:实交 4 个 operation。`searchSource` 已由 `workspace.inspect-source@1`
  提供(重复能力不再造);`inspectSymbol` = inspect-source + read-source-range 的组合;
  `parseBuildFailure`/`collectBuildOutputs` 移交 TASK-HFA-007(消费 artifact、发布
  derived artifact,属 analyzer 流水线)。三条依据写在 `tasks.md` 的 Done 行。
  **命名偏离**:产物用 `.txt` 而非终版 §18.3 的 `.json` —— git 的实际输出是文本,
  命名为 json 会让下游按 JSON 解析并失败。

## HFA-AC-18 workspace 主体绑定 exact base revision(TASK-HFA-009)

- 方法:workspace revision 失配时 `applyPatch`/`build`/`revertPatch` 一律
  `WORKSPACE_REVISION_CONFLICT` fail closed;dirty worktree 能被 revision digest 识别
  (同一 HEAD、不同工作区内容 → 不同 revision);capability 绑定 workspace identity +
  expectedWorkspaceRevision + allowedFileScopesDigest。
- Evidence:实现 PR 内测试。
- **结论(2026-08-01):PARTIAL —— revision 半边 PASS,capability 半边 pending**。
  `WorkspaceRevisionBindingContractTests` 9 例:`testTheRevisionIsStableForAnUnchangedTree`
  (同一棵树两次同值、64 位);`testAWorkingTreeEditMovesTheRevision`(dirty worktree 被识别
  —— 这正是只看 HEAD 会漏掉、而又最要命的一类:决策是对着这些字节做的);
  `testHeadAndIndexBothParticipate`(文件未变但 HEAD 移动 → revision 变;index 变 → revision 变);
  `testAPackedRefResolvesRatherThanReadingAsAbsent`(packed ref 的仓库不是"没有 HEAD"的仓库);
  `testTheIdentityIsTheTreeAndNotItsContents`(identity 与 revision 是两件事);
  `testAMutationDeclaringAMovedRevisionIsRefused` 断言声明了陈旧 revision 的变更被
  `workspace.revisionConflict` 拒绝(命名的,不是泛化错误);
  `testAMutationDeclaringTheCurrentRevisionProceeds` 与 `testAnUndeclaredRevisionIsNotSilentlyInvented`
  钉住正例与「不声明即维持既有行为」;`testTheMutatingOperationsAllDeclareTheField` 断言四个
  变更 operation 都能声明该字段且为可选(非破坏性)。
  **§18.2 的两处替换已如实登记在代码注释里**:index 贡献的是 index **文件**摘要而非 tree OID
  (读 tree OID 要解析 git 二进制索引;文件摘要随索引变动,正是所用性质);submodule OID 未纳入
  (本 provider 尚无 submodule 面,不可变动的成分不是证据)。全部为文件读取,不 spawn git ——
  准入需要在任何进程启动之前拿到答案。
  **capability 半边(r2,2026-08-01):PASS** —— `WorkspaceCapabilityGateContractTests` 8 例:
  `testAWorkspaceGrantDoesNotAuthorizeADeviceMutation` 与
  `testADeviceGrantDoesNotAuthorizeAWorkspaceMutation` 双向断言一个主体的 grant 不能授权另一个
  (失败原因是 `targetIdentityRequired` —— 两者是不同**种类**的主体,不是同种类的不同取值);
  `testAGrantForAnotherTreeIsRefused` 与 `testAWiderWriteScopeThanTheGrantIsRefused` 断言
  换棵树、放宽可写范围一律拒绝;`testAPinnedGrantIsRefusedOnceTheTreeMoves` 与
  `testAStandingGrantSurvivesTheRevisionsItsOwnMutationsProduce` 钉住 pinned 与 standing 两种形态。
  引擎侧由 `WorkspaceProviderContractTests` 端到端覆盖(准入 + 派发时二次确立主体)。
  **签发可达性(r3,2026-08-01):PASS** —— r2 的准入闸合入后实测发现生产 CLI 与 draft
  engine 都仍假定 capability 主体必为设备,维护者无法得到 workspace grant 草稿。
  `testCapabilityDraftDoesNotAskTheDeviceStoreForAWorkspaceSubject` 钉住 CLI target 解析不查询
  device store;`testRuntimeDraftsAReviewableWorkspaceCapabilityWithoutInstallingOrDispatching`
  断言草稿精确携带 workspace identity、观测 revision、scope digest 与 typed input constraints,
  同时 capability store 为空、Job 为零、workspace 字节不变。草稿中的 standing target 不固定
  revision,request 自己声明的 `expectedWorkspaceRevision` 仍被 exact input constraint 固定。
  **source-preserving checkpoint policy(r4,2026-08-15):PASS(host contract)** ——
  `testCatalogToRuntimeArchiveCheckpointPublishesReceiptAndConfirmsCapabilityLineage` 从无 caller
  authorization 的真实 Runtime submit/run 路径出发,断言 Runtime 只签发一张
  `workspace.create-checkpoint@1` 单次能力,并逐项等于 admitted plan digest、typed inputs、
  request revision 与 ProjectProfile source-scope digest;窄文件集 digest 冒充 workspace
  revision 仍在签发前被 `workspace.revisionConflict` 拒绝。此结论不代替合入后 Phase 6
  DAYU200 重放,真机 dispatch 当前仍未发生。

## HFA-AC-19 device 主体准入逐条不变、capability 只收窄(TASK-HFA-009)

- 方法:`binding: confirmedDevice` 的既有准入回归断言逐条不变;E2 exact-plan 语义不变;
  负例——workspace 主体的 capability 不能授予 runtime 不具备的能力、不能自签、不能续期、
  不能扩范围;复用同一 reservation/consumption/outcome 账本(不出现第二套账本)。
- Evidence:实现 PR 内测试。
- **结论(2026-08-01,r2):PASS** ——
  **device 半边逐条不变**:`testMutatingOperationsCarryTheGuardsOfTheirOwnSubject` 的 else 分支
  保留原断言(deviceExclusive + confirmedDevice),`testOnlyWorkspaceMutationsMayBeUnbound`
  额外钉住"只有 workspace 变更可以无绑定"—— 该测试是**重述**不是放宽,原本禁止的
  「无绑定的设备变更」仍然被禁;E2 exact-plan 语义未触及。
  **capability 只能收窄**:`testEveryWorkspaceMutationRequiresAGrantAndForbidsSelfIssuance`
  断言五个变更 operation 都要求 standingCapability 且**两层**禁止运行时自签
  (描述符 `defaultPolicyIssuance: disabled` + 引擎 issuance 分支);
  `testTheReadOnlyWorkspaceFamilyStillNeedsNoGrant` 断言只读族**没有**被顺手升级 ——
  把读也升上去会让闸看起来更安全,却让闭环什么都看不了。
  **复用同一账本**:consumption 走既有 `RuntimeCapabilityStore`,未新建第二套;
  其主体校验从"必须有设备"改为"必须有设备**或** workspace 主体",两者都没有即拒绝。
  **device draft 回归(r3,2026-08-01):PASS** ——
  `testCapabilityDraftStillPinsADeviceSubjectToItsCurrentBinding` 保留 device store lookup 与 exact
  binding;既有 daemon draft 测试仍验证 `bindingRevision`/`stableIdentitySHA256`,新增 workspace
  字段在 device wire payload 中用 `encodeIfPresent` 省略,未把旧消费者改成接收 `null`。
  **r4 收窄证明(2026-08-15):PASS(host contract)** ——
  `testSourceChangingWorkspaceMutationsRequireAGrantAndForbidSelfIssuance` 逐条锁住 apply/build/test/
  revert 的 standing policy 与 `defaultPolicyIssuance: disabled`;
  `testCheckpointUsesRuntimeOwnedPolicyWithoutWideningSourceMutationGrants` 只允许单步
  `createWorkspaceCheckpoint` 走 Runtime policy。引擎 additionally pins exact materialized plan
  digest for this E1 policy capability,caller-supplied capability 仍被既有 Runtime-owned policy
  boundary 拒绝。device descriptors 与 E2 destructive exact-plan 分支未修改。

## HFA-AC-20 Memory 晋升条件与作用域过滤(TASK-HFA-010)

- 方法:`VERIFIED` 只能由 evaluator PASS 或人工确认产生且带证据引用(负例:自述结论无法晋升);
  超出 revision/device/toolchain 作用域的 memory 不得进入 `confirmedFacts.current`;
  未验证 memory 的检索得分低于当前 task evidence;`SUPERSEDED`/`INVALIDATED` 不再被选入。
- Evidence:实现 PR 内测试。
- **结论(2026-08-01,第三方补记 —— 方法见 `evidence/runs/LEDGER-BACKFILL/2026-08-01.md`):PASS** ——
  `HarnessMemoryContractTests.testVerifiedMemoryRequiresAPassOrHumanReceiptAndExactScope`
  钉住晋升条件(PASS 或人工回执)与精确作用域;
  `testDecodedVerifiedMemoryCannotBypassPromotionAuthority` 堵住「直接反序列化一条 VERIFIED
  绕过晋升」这条最实际的旁路;`testExactScopeFiltersBeforeRankingAndCandidatesStayBelowCurrentEvidence`
  断言先精确过滤再排序、未验证 memory 得分低于当前证据;
  `testContextConfirmedFactsContainOnlyInScopeVerifiedMemory` 断言超作用域者进不了
  `confirmedFacts`;`testLegacyProjectMemoryLoadsFailClosedInsteadOfGainingScope` 断言旧数据
  fail closed 而不是凭空获得作用域;`testFailureMemoryCarriesFiveClosedDispositionsAndTypedAlternatives`
  覆盖五态 retryDisposition。(TASK-HFA-010,合入 `bbaa50e7`)

## HFA-AC-21 厂商 adapter 可替换且出站受限(TASK-HFA-011)

- 方法:三个 adapter 与离线确定性路径在同一持久化事实下产生**相同的状态机结论**;
  解析负例集(未知字段/未知 kind/raw argv/shell/远端路径/状态字段/retry 计数/成功结论)
  整条拒绝;出站内容断言不含设备标识、未脱敏字节与凭据;`maxModelCalls` 耗尽后安全停止;
  模型不可用时闭环退化为确定性路径而非停摆。
- Evidence:实现 PR 内测试(不含真实网络调用的密钥)。
- **结论(2026-07-31):PASS,三处如实登记的未覆盖** ——
  `HarnessVendorGatewayContractTests` 10 例,全部经 fake transport,零网络:
  `testEveryAdapterSendsExactlyTheCanonicalContextBytes` 断言三家 adapter 的请求体都
  携带 `context.transmittedBytes` 的**同一份**规范字节(这正是 ModelRun digest 的取值
  对象,否则 digest 记录的是没发生过的事);
  `testTheCredentialNeverLeavesTheHeaderSet` 用一个哨兵密钥断言它**不在** body、
  不在 URL、不在 modelDescriptor,只在 header;
  `testTheOutboundContextCarriesNoDeviceIdentity` 断言出站字节里没有 targetID、
  connectKey、远端路径;
  `testEachVendorEnvelopeIsDecodedToTheSameProposalBytes` 断言三家 envelope 解出**同一份**
  proposal 字节(adapter 只搬运,不解释);
  `testAVendorErrorOrGarbageIsATransportFailureAndNotAProposal` 覆盖 500/401/非 JSON/
  空 envelope 四种,一律 `transportFailure`,绝不变成 proposal;
  `testSwappingAdaptersDoesNotChangeWhatTheStateMachineConcludes` 用同一份回复跑三家,
  断言 action 与派发的 operation 完全相同 —— 这是「可替换端口」的可检验形式;
  `testAnExhaustedModelBudgetStopsTheModelPathAndNotTheTask` 断言 `maxModelCalls: 0` 时
  **零请求到达 vendor**、reasonCode `maxModelCallsExhausted`;
  `testAModelCallIsChargedEvenWhenItsProposalIsRefused` 断言被解析器拒绝的调用照样
  计入 `consumedBudget.modelCalls` 且 ModelRun 的 responseBytes > 0;
  `testBudgetsPersistedBeforeThisCeilingStillLoad` 断言旧 daemon 写下的预算文档仍能解码
  (缺字段取默认,不是解码失败)。
  **未覆盖(如实)**:①无真实厂商端点调用;②不记 token usage(三家 envelope 形态不同、
  当前无消费者,故记实测字节数而非半可信 token);③密钥来源由 composition root 决定。

## HFA-AC-22 SQLite 迁移可逐字回读且崩溃可重入(TASK-HFA-012)

- 方法:以真实历史 task 目录迁移,断言 `task.events`/`task.result` 逐字保持;
  迁移中断后重入不产生重复或丢失;WAL + 外键 ON + 同事务 snapshot/event + 乐观锁
  各有用例;失败时停在旧存储且不损坏。
- Evidence:实现 PR 内测试 + 迁移前后逐字对照。
- **结论(2026-08-01,第三方补记 —— 方法见 `evidence/runs/LEDGER-BACKFILL/2026-08-01.md`):PASS** ——
  `HarnessSQLiteMigrationContractTests.testSQLiteEnablesWALForeignKeysVersionedSchemaAndEveryRequiredTable`
  覆盖 WAL、外键、schema 版本与全部必需表;
  `testRealHFA005DirectoryMigratesWithByteEquivalentEventsAndResult` 用**真实历史任务目录**
  断言事件与 result 字节等价、且**原文件未被改写**;
  `testBothMigrationCrashWindowsRollBackAndReenterWithoutLegacyDamage` 覆盖两个迁移崩溃窗口
  可回滚可重入且不损坏旧数据;`testEventAndSnapshotRollbackTogetherAndCASReportsThePersistedVersion`
  覆盖同事务与乐观锁;`testCanonicalJSONDigestMismatchFailsClosed` 与
  `testReconcileLeaseIsExclusiveOwnerBoundAndExpiresAfterCrash` 补齐 digest 与 lease。
  (TASK-HFA-012,合入 `960e2bb2`)

## HFA-AC-23 module 抽取是纯移动且依赖方向单向(TASK-HFA-013)

- 方法:抽取前后测试数与结论不变(逐项对照);依赖断言测试证明 `ArkDeckHarness`
  不 import OpenHarmony 设备参数、不持远端路径、不构造 Git/HDC/build argv;
  仍是单 `arkdeck-agentd` executable。
- Evidence:实现 PR 内测试 + 前后套件计数对照。
- **结论(2026-08-01,第三方补记 —— 方法见 `%s`):PASS** ——
  **依赖方向**:`Package.swift` 声明 `ArkDeckHarness` 的依赖恰为
  `["ArkDeckCore", "ArkDeckProcess", "ArkDeckRuntime"]`(不含 Workflows / OpenHarmony,
  即单向);`ArkDeckContractTests.testPackageTargetsImportOnlyDeclaredArkDeckModules` 断言每个
  target 的 import 不超出 `Package.swift` 声明,其中 `assertHarnessModuleBoundary()` 进一步断言
  九个分层(Domain/Application/Context/Evaluation/Memory/Persistence/Ports/LLM/Tasks)各自
  拥有源文件、旧 target 不再保留 `Harness*` 文件、`ArkDeckWorkflows/AgentHarness` 目录已消失,
  且平台实现面(`HDCProviderAction.`、`RuntimeJobEngine(`、`RuntimeArtifactStore(`、
  `RuntimeCapabilityStore(` 等)不出现在 harness 内 —— 这正是「不 import 设备参数、不构造 argv」
  的可检验形式。
  **纯移动**:#911(`cdabd9ac`)的 diff 中新增测试函数 **0** 条、删除 **0** 条
  (`git show cdabd9ac | grep -cE '^[+-]  func test'` 各为 0),迁移后全量套件
  **1064 tests / 1 skipped / 0 failures**,与迁移前同数 —— 即行为面既没丢也没被顺手改。
  **未覆盖(如实)**:仓内没有一条断言把「测试数不变」本身钉住(它由本次逐项对照得出,
  不是自动回归);单 `arkdeck-agentd` executable 的拓扑由 `Package.swift` 保证,无独立断言。
  (TASK-HFA-013,合入 `cdabd9ac`)

## HFA-AC-24 隔离 workspace 的身份活过 daemon 重启(TASK-HFA-014)

- 构造:任务建立 evolution workspace 后,**换一个进程**接手同一任务(新 registry 只含源 profile);
- 该任务的 `executionProjectRef` 必须仍能解析到与磁盘 manifest 一致的派生 profile:
  projectRoot、profileID、allowedFileGlobs 逐项相同;
- manifest 与源 profile 冲突时 **fail-loud**(类型化错误),不得静默重建或回落到源 workspace ——
  回落等于把隔离悄悄取消;
- 已被销毁(带 teardown 记录)的 workspace 不因此复活。

## HFA-AC-25 量不到与量到了且变了,是两个结论(TASK-HFA-014)

- workspace revision 的求值三态:已测得 / 确证不可测(带类型化原因)/ 与期望不符;
- 只有第三态产生 `workspaceRevisionChanged`;把"解析不到 projectRef"喂进去,
  结论必须是可读的不可测原因,**不得**出现 `->none` 这类"变成了空"的表述;
- 真的变更仍判陈旧:改动一个 allowed 路径下的文件后,陈旧判定照常成立(判定只收紧不放宽);
- 反馈给决策产出方的陈旧理由必须点名"这次测量没做成"及其成因,而不是断言"变了";
  daemon 启动时逐条说出它收养不了的 workspace,不留到六轮之后才以别的名义浮现。

> **本条原文的更正(实现时发现)**:原文写的是"不得报 `insufficientEvidenceForPatch`"。
> 实测该字符串**不在 Swift 源码中的任何位置** —— 它是决策产出方(模型)自己选的理由,
> 经 `causation: noSafeAction` 上报(`HTASK-C458F21E8B9C` 末条事件)。产品无法禁止
> 产出方选哪个词。产品能管的是**喂回去的是不是实话**,所以本条改为对陈旧理由与启动
> 播报的约束。这是把断言改准,不是放宽:原文要求的那件事,代码里没有对应的闸可修。

## HFA-AC-26 为人停下必留一条交接记录(TASK-HFA-015)

- 构造:分别经 guard 类阻塞与 handler 的 `.requestHuman` 决策进入 `humanRequired`;
- **两条路径都必须**产生恰好一条人机交接记录,且记录里的理由与该次停机的 reasonCode 一致;
- 记录至少可读出:停下的理由、恢复所需相位/状态、可据以行动的证据引用;
- 反证:把 `.requestHuman` 分支的记录写入去掉,断言必须变红——
  「停下了但队列是空的」不得再次成为可通过的状态。

## HFA-AC-27 封闭词表要么正确扩展,要么不被依赖(TASK-HFA-015)

- 若 `HarnessHumanBlock` 新增取值:其封闭形状校验与文档级世代测试同 PR 更新,
  且旧台账逐字回读不变(先例:动 terminal CodingKeys 未同步校验曾使 agentd 被自己的台账 brick);
- 若不新增:人机交接记录的生成不得依赖该词表,并断言两种不同停机在台账里**不会长得一样**;
- 无论走哪条,`patchProposalRequired` 与 `environmentUnavailable` 的记录必须可区分。
