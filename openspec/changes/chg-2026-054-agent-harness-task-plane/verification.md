# Verification — CHG-2026-054

> Change:CHG-2026-054-agent-harness-task-plane@r2
> Status:in_progress # 2026-07-31(r2):HTP-AC-1..14 与 AC-20..22 通过(AC-7 的真机
> 字节面如实 pending-hardware);AC-15..17 pending(TASK-HTP-005 可开工,007 已 done),
> AC-18/19 pending-hardware。每条结论由其所属任务的
> 实现 PR 写入本文件;维护者 review/merge 该实现 PR 即确认。不为本 change 追加独立
> verification/archive 载体(PRODUCT-LOOP §4/§20)。

约定:

- 结论只能取 `PASS` / `FAIL` / `pending`(未开工)/ `pending-hardware`(缺设备窗口,
  如实分类,不得以 fake/simulation 顶替);
- 每条结论必须给出可复查的落点(测试名、命令、退出码、artifact hash、脱敏设备标识);
- HTP-AC-18/19 是 GJ-5 唯一可写 `REAL_DEVICE_PASS` 的依据,且必须在当前 catalog
  digest 上取得。

## HTP-AC-1 一次 reconcile 至多一个 effectful job(TASK-HTP-001)

- 方法:并发与重入下反复触发 reconcile,断言单次唤醒的 effectful dispatch 计数 ≤ 1;
  active job 未进终态时 reconcile 不派发新 job 且不消耗预算;单 task 同时最多一个
  effectful active job。
- Evidence:实现 PR 内测试 + 全量套件结果。
- **结论(2026-07-30):PASS** — `testOneWakeDispatchesAtMostOneEffectfulJob` 断言首个
  唤醒 dispatch 一次(按 idempotencyKey 计侧效应 = 1),随后三次唤醒均
  `waitedForActiveJob` 且 submit 计数不变;`testConcurrentWakesStillDispatchOnce`
  用 6 个并发 caller 断言 `dispatched` 恰一次、jobDispatched 事件恰一条。
  reducer 侧另有 `jobAlreadyActive` 负例(状态模型层同一不变量)。
  全量 748 tests / 1 skipped / 0 failures。

## HTP-AC-2 dispatch intent 崩溃恢复零重复副作用(TASK-HTP-001)

- 方法:两窗口矩阵——(a) persist dispatch intent 之后、submit 之前终止进程;
  (b) submit 之后、收到 jobId 之前终止进程。恢复后断言用**原 idempotencyKey** 重投、
  引擎返回 deduplicated 同 jobId、TaskJobLink 补齐、副作用只发生一次
  (沿用 MU-2 T08 的崩溃两窗口范式)。
- Evidence:实现 PR 内测试 + 全量套件结果。
- **结论(2026-07-30):PASS** — 两个窗口各有独立用例:
  (a) 引擎已收到、答复丢失(`testRecoveryReusesTheKeyWhenTheEngineAlreadyReceivedTheSubmit`):
  intent 停在 `submitted`、无 jobId、无 jobDispatched 事件;恢复后**同一
  idempotencyKey** 重投,port 回 `deduplicated`,侧效应总数仍为 1;
  (b) 未达引擎(`testRecoveryResubmitsTheSameKeyWhenTheEngineNeverReceivedIt`):
  恢复后同 key 重投、`fresh`、侧效应 1。
  `testANewCoordinatorRecoversTheLostDispatchIntent` 用**新建 store + 新 coordinator**
  (等价进程重启)跑 `recoverTasks()`,断言 link 补齐、reasonCode
  `recoveredDispatchIntent:deduplicated`、侧效应仍为 1。
  `testRejectedAdmissionIsNotRetriedByRecovery` 断言引擎拒绝 → intent 落 `rejected`、
  不进恢复集合、零副作用、任务停在 humanRequired 且不自解。
  `testOutcomeUnknownStopsAndNeverResendsTheSideEffect` 断言 outcomeUnknown 立即停止
  且后续唤醒零重发(HTP-INV-5)。

## HTP-AC-3 状态迁移只经 reducer 且逐项留痕(TASK-HTP-001)

- 方法:非法 status/phase 迁移被拒(负例集);每次合法迁移持久化 from/to/reasonCode/
  causation/jobId/evaluationId/artifactRefs/consumedBudget/version;版本冲突写入被拒;
  reducer 之外的路径无法改变状态(断言无其它写入点)。
- Evidence:实现 PR 内测试。
- **结论(2026-07-30):PASS** — `testReducerRejectsIllegalTransitions` 逐项断言:
  `successRequiresEvaluation`(非 evaluation causation 无法进 succeeded——「只有
  evaluator 能宣布成功」的结构形式)、`illegalPhase`(initializing → verifying)、
  `jobAlreadyActive`、`budgetRegressed`、`artifactRefsShrank`、`cancelPending`、
  `cancelRequestWithdrawn`、`terminal`。`testStaleVersionCommitIsRejected` 断言乐观锁
  (过期 expectedVersion 写入被拒);`testEveryTransitionCarriesCausationAndJoinsItsVersion`
  断言每条事件 sequence 连续、`resulting.version == sequence + 1`、reasonCode 非空、
  dispatch 事件带 jobId。唯一写路径:coordinator 的所有状态变更都经私有 `commit()`
  → reducer。

## HTP-AC-4 daemon 重启后 task 时间线逐字保持(TASK-HTP-001)

- 方法:提交 task、跑若干轮、重启 daemon,断言 `task.status`/`task.events`/`task.result`
  逐字一致,active job 与未完成 dispatch intent 被正确恢复(与 T11 真机"重启后历史逐字
  保持"同一断言口径)。
- Evidence:实现 PR 内测试 + 进程级自测输出(`evidence/runs/TASK-HTP-001/run-r1.md`)。
- **结论(2026-07-30):PASS** — `testTaskTimelineSurvivesARestartVerbatim` 断言新 store +
  新 coordinator 读到的事件序列与快照逐字相等、result 可读回、读取不改写日志字节;
  并把 `task.json` 回滚到首版后断言 `load()` 由事件重放得到同一状态(快照是日志的缓存)。
  进程级:daemon SIGTERM 重启后 `arkdeck task list` 仍为 `humanRequired v3`,typed
  `resume` 记入事件 3,事件日志 4 行、sha256 前 32 位 `278c44ec4ee816691f6475b28836252e`。

## HTP-AC-5 只有 evaluator 能宣布成功(TASK-HTP-002)

- 方法:构造 decision 自述"crash 已修复"/"build succeeded",断言 task 不进入
  `SUCCEEDED`;仅当全部 mandatory criteria 由真实证据判定 `PASS` 时才成功。
- Evidence:实现 PR 内负例测试。
- **结论(2026-07-30):PASS** — `testSuccessIsReachableOnlyThroughAPassingEvaluation`
  断言只有 verdict `pass` 的 evaluation 能把 task 带进 `succeeded`,且终态事件的
  causation 恒为 `evaluation`、带 evaluationId,result.evaluationId 与之一致;
  `events.filter { toStatus == .succeeded }.map(causation) == [.evaluation]` 断言没有
  第二条路径。reducer 侧 `successRequiresEvaluation`(TASK-HTP-001)是同一不变量的
  结构形式;`testAFailingCriterionHandsTheVerdictToAHumanAndNeverSucceeds` 断言
  verified 证据判 fail 时任务转 humanRequired(`criteriaFailedNoRepairCapability`)
  而非成功;`testObservedStateCannotBeWrittenWithoutEvidence` 断言非证据 causation
  (如 humanResolved「操作员说修好了」)不能写 observedState。

## HTP-AC-6 INCONCLUSIVE 不等于成功(TASK-HTP-002)

- 方法:样本不足/观测窗口不满/声明证据缺失 → verdict `INCONCLUSIVE`;断言其只能触发
  补采集或消耗下一轮,预算不足时转 `HUMAN_REQUIRED`/`FAILED`,永不 `SUCCEEDED`。
- Evidence:实现 PR 内测试。
- **结论(2026-07-30):PASS** — `testSampleGateAndIntegrityDominateTheVerdict` 断言
  样本不足 → `inconclusive` + `insufficientSamples:2/5`,补足后才 `pass`;
  `testNoMandatoryCriterionIsInconclusiveNotPass` 断言「无 mandatory criterion」
  = `inconclusive`,不是 pass;`testInconclusiveNeverSucceedsAndTheBudgetStopsTheLoop`
  端到端断言 5 样本要求 + 3 轮预算 → 任务以 `maxRoundsExhausted` 转 `failed`、
  全程未进 `succeeded`、最终 verdict 仍 `inconclusive`;
  `testComparatorsAndEscalationSelection`(escalation 取最严策略)断言
  requestHuman 不被 collectMoreEvidence 稀释。

## HTP-AC-7 observation 来自真实字节且缺证据 fail closed(TASK-HTP-002)

- 方法:用真机已产出的 hilog/ui-dump/build 产物字节样本驱动 observation builder,
  断言 crash signature、liveness、artifact digest 一致性的提取结果;artifact 为空、
  缺失或 hash 不符时 fail closed(不得产出"看起来完整"的观测)。
- Evidence:实现 PR 内测试 + `evidence/runs/TASK-HTP-002/run-r1.md`。
- **结论(2026-07-30):PASS(判定与 fail-closed 面)+ pending-hardware(真机字节面)** —
  `HarnessObservationBuilder` 先验后测:读满字节、重算 SHA-256 与 store 记录比对,
  只有 verified 字节参与测量。逐情形断言(`testAbsentEmptyOversizeAndSensitive…`、
  `testHashMismatchIsAnIntegrityBlockerAndYieldsNoMeasurement`、
  `testRequiredEvidenceThatWasNeverCollectedIsABlocker`、
  `testUnavailableInventoryIsABlockerNotAnEmptyObservation`):未发布 / 零字节 /
  超读取上限 / sensitive 未 opt-in / 未采集 / inventory 不可用 → blocker 且零 measurement;
  hash 不符 → integrity blocker → verdict `error`。crash signature 与 liveness 提取由
  `testMeasurementsComeFromVerifiedBytes`、`testCleanLogMeasuresHealthyAndZeroCounts`
  断言(matching / newFatal 不混淆)。
  **如实分类**:这些 hilog 是按 OpenHarmony cppcrash 文档形态 host 手写的 fixture,
  仓内无真机 hilog/crash 字节样本;「真机已产出字节驱动 builder」这一半保持
  pending-hardware,由 TASK-HTP-006 设备窗口关闭,不以 fixture 顶替。

## HTP-AC-8 预算耗尽即安全停止(TASK-HTP-003)

- 方法:`maxRounds`/`maxWallClock`/`maxArtifactBytes`/`maxE1Mutations` 各自耗尽的四组
  用例,断言不再派发任何 job、task 进入 `FAILED` 并带机器可读 reason code、
  consumedBudget 如实记录。
- Evidence:实现 PR 内测试。
- **结论(2026-07-31):PASS** — `testEveryBudgetKindStopsTheTask` 对 rounds /
  wallClock / artifactBytes / e1Mutations 四类各断言 `budgetRefusal` 与机器可读
  reason code;`testWallClockExhaustionStopsBeforeDispatchingAnything` 端到端断言时钟
  跨过预算时**零 dispatch**、task `failed`、reason `maxWallClockExhausted`(只查轮数的
  实现会漏这条);`testArtifactBytesAreChargedOncePerVerifiedArtifact` 断言只有验证通过
  并读满的字节计费、每 artifact 只计一次、耗尽即停且已得样本保留。consumedBudget 如实
  记录并随 projection 持久化。

## HTP-AC-9 失败指纹与 no-progress 收敛(TASK-HTP-003)

- 方法:同指纹第 2 次拒绝完全相同的 decision(必须至少改变 operation/inputs/前置/
  patch region/hypothesis/artifact 来源/profile/recovery path 之一);≥3 次 →
  `HUMAN_REQUIRED`/`FAILED`;无进展轮不产生新的 effectful job。
- Evidence:实现 PR 内测试。
- **结论(2026-07-31):PASS** — 指纹 = operationRef + phase + provider(取自 catalog
  descriptor)+ targetProfile + 归一化 inputs hash + errorClassification +
  semanticErrorCode,摘要即文件名(`FAIL-<16 hex>`,分隔符不可表达)。
  `testSecondIdenticalStrategyIsRefusedAndThirdIsProhibited`:第 1 次允许原策略、
  第 2 次拒绝完全相同的 decision、**改 typed inputs 即算新策略**(正例)、第 3 次
  一律拒;`testStanceTableMatchesTheThreeStrikeRule` 钉住 stance 表;
  `testFailureMemoryIsCrossTaskAndDrivesTheThirdStrikeStop` 用三个不同 task 命中同一
  指纹,断言记录只有一条、`observedByTasks` 三个、第三个 task 停在
  `strategyExhausted`。无进展:`noProgressRounds` 进 projection 且只有证据类 causation
  可写;`testNoProgressRoundsAccumulateAndStopTheLoop` 端到端停止并用新 store 读回同一
  计数;`testProgressVectorIgnoresProseAndCountsEvidence` 断言只多分析文字不算进展。

## HTP-AC-10 outcomeUnknown 停止并产出结构化人工阻塞(TASK-HTP-003)

- 方法:构造 `outcomeUnknown` job 结果,断言零自动重发原副作用、产出
  `HumanActionRequired`(category `outcomeUnknownDecision`,含 reasonCode、
  evidenceRefs、resume 状态),typed resolution 后可恢复到原 phase。
- Evidence:实现 PR 内测试 + `evidence/runs/TASK-HTP-003/run-r1.md`。
- **结论(2026-07-31):PASS** —
  `testOutcomeUnknownProducesATypedHumanActionAndResumesOnlyOnAResolution` 断言产出的
  文档 category `outcomeUnknownDecision`、reasonCode `recovery.outcomeUnknown`、
  minimumActionKey `human.reconcileOrAbandon`、prohibitedAutomation `[outcomeGuess]`、
  resumeProbe `reconcileOutcome`、jobId = 真实 job、status `waiting`;零自动重发
  (后续唤醒 `awaitingHuman`、submit 计数不变);空 resolution 被拒;typed resolution 后
  **文档自身状态机**翻为 `resolvedByFreshProbe` 且 phase 不回退;
  `testResolvingAnAlreadyResolvedBlockIsRefused` 断言重复解锁被拒。
  **如实边界**:封闭词表只准确覆盖 `authorizationApproval` 与 `outcomeUnknown`;
  `strategyExhausted`/`evidenceIntegrity`/`environmentUnavailable` 不产出文档
  (`document: nil`),只带 status + reasonCode + 证据引用 —— 硬凑 category 等于往证据级
  文档写不实的最小人工动作(CHG-2026-050 教训)。扩词表需自己的契约载体。

## HTP-AC-11 E2 永不自动化、E1 只用既有 capability(TASK-HTP-003)

- 方法:E2 operation 一律拒绝并产出 `HumanActionRequired`(断言 harness 无
  draft/install/consume E2 的路径);E1 capability 缺失/过期/范围不符时 fail closed,
  零 dispatch、零 capability 消耗;capability 在 provider 或 plan 不可用时不被消耗。
- Evidence:实现 PR 内负例测试。
- **结论(2026-07-31):PASS** — `testDestructiveOperationsAreNeverAutomated`:
  `flash.dayu200@1` 在「预算 8 次 mutation + capability 在手」下仍被
  `destructiveEffectNeverAutomated` 拒,且断言 debugCrash 默认策略不含它;
  `testDeviceMutationNeedsBudgetAndAnExistingCapability`:`debug.hap@1`(effect 地板
  = deviceMutation)无预算拒、有预算无 capability 拒、两者齐备才让路(harness 从不
  draft/install/consume,授权判定权仍在引擎 admission);
  `testAnUnavailableOperationIsRefusedBeforeAuthorizationIsConsulted` 断言不可用 plan
  下 capability port **一次都没被问**(PRODUCT-LOOP §8:plan 不可用不得消耗 capability);
  `testRawCommandSurfaceIsRefusedInTypedInputs` 断言 argv/远端路径被逐字段拒。
  **实现期修正**:第一版按 effect **上限**授权,把 GJ-1 的 E0 采集误拒
  (`capture.diagnostics@1` 上限含 deviceMutation);正确划分是 guard 只守「地板已 mutate」
  与「destructive 上限」,有效 effect 由引擎的选择规则决定 —— 否则就是第二份会漂移的
  实现(`testReadOnlyCeilingOperationsAreLeftToTheEngine` 钉住此取舍)。

## HTP-AC-12 decision 严格 schema 与拒绝面(TASK-HTP-004)

- 方法:负例集断言以下一律整条拒绝——raw argv/shell/HDC/远端路径、task 或 job 状态
  字段、retry 计数、成功结论、授权结果、catalog 外 operationRef、typed inputs 越界;
  正例只接受四类 decision。
- Evidence:实现 PR 内测试(负例逐项)。
- **结论(2026-07-31):PASS** — `HarnessDecisionProposal.parse` 用封闭键集解码 +
  显式禁止键集。`testStateRetryAndSuccessFieldsAreRejectedNotIgnored` 逐字段断言
  status/phase/result/retryCount/verdict/succeeded/authorization/capabilityId/effect/
  budget/activeJobId/version 共 12 键一律 `forbiddenField` **拒绝而非忽略**;
  `testUnknownFieldsAndKindsAreRefused`(未知键/未知 kind/非 JSON)、
  `testRawCommandSurfacesAreRefusedInInputsAndInProse`(inputs 与 hypothesis 双面)、
  `testAnOperationOutsideTheOfferIsRefused`(`operationNotOffered` / `operationRequired`)、
  `testEmptyAndOversizedFieldsAreRefused` 各自覆盖;正例只接受四类 decision。
  端到端:`testARejectedProposalFallsBackVisiblyAndChangesNothingElse` 断言模型宣称
  `status: succeeded` 时整条被拒、任务不成功、回退可见(reasonCode + task memory)。

## HTP-AC-13 出站默认 deny 与脱敏有界(TASK-HTP-004)

- 方法:默认配置下断言零出站(无 adapter 调用);显式开启后断言 `DecisionContext`
  仅含脱敏、有界摘要与 artifact 引用——不含未脱敏字节、设备标识、凭据,且总尺寸
  在声明上限内;超限时拒发并记录,而非静默发送。
- Evidence:实现 PR 内测试 + `evidence/runs/TASK-HTP-004/run-r1.md`。
- **结论(2026-07-31):PASS** — `testEgressIsDeniedByDefaultAndNoContextLeavesTheHost`
  断言默认配置下 gateway **零调用**、loop 仍照常推进(内建 handler)、回退写入 task
  memory;`testEgressWithoutAProjectRefIsDenied` 断言无 projectRef / 未登记项目均拒;
  `testAnEnabledContextIsBoundedPseudonymousAndFreeOfDeviceIdentity` 断言 target 以单向
  摘要出现(≠ 原 id)、`HarnessEgressScreen` 扫不到 targetID/connectKey/serial/
  stablePhysicalIdentity/远端路径、artifact 只带 id+size+digest 前缀+verified(无内容)、
  编码尺寸在上限内;`testContextTrimmingIsRecordedRatherThanSilent` 断言裁剪逐项记录;
  `testAnOversizedContextIsRefusedInsteadOfSent` 断言超限**拒发**(context 从未交给
  adapter)并退回确定性策略。生产开关 = `ARKDECK_HARNESS_EGRESS_PROJECTS`,未设即 deny。

## HTP-AC-14 决策端口可替换且状态不依赖模型会话(TASK-HTP-004)

- 方法:同一批步骤分别由内建 handler 与经端口的模型提出,断言状态机结论路径等价
  (接受/拒绝/停止的判定不依赖提出者身份);断言 task 状态不保存任何模型会话句柄。
- Evidence:实现 PR 内测试。
- **结论(2026-07-31):PASS** — `testConclusionsFollowTheStepNotTheProducer`:同样两步
  (observe → capture)一次由内建 handler 提出、一次经端口由脚本化模型提出(第三拍模型
  不可达),两条 trace 逐项相等且都以 `stoppedForHuman` 收尾;
  `testTaskStateHoldsNoModelSessionHandle` 断言 decision 记录有 producer id 而 task 快照
  扫不到 session/conversation/messages/apiKey/token。
  **方法修正**:原计划的"离线确定性 adapter"被删除 —— 它是 handler 策略的第二份实现
  (第一版实际会在设备未观测前先跑 capture,被本 AC 的等价性测试照出),内建生产者就是
  handler 本身,端口只留给仓外生产者;文件内注明理由防止回退。

## HTP-AC-20 host-only 准入不碰设备面(TASK-HTP-007)

- 方法:对声明 `binding: none` 的 operation 断言准入路径**不解析设备 facts、不查
  target store、不要求 connectKey/设备身份**;携带 `expectedBindingRevision` 的请求被
  拒(host-only 没有绑定可言);job 记录与 artifact 的 binding 快照不带 bindingRevision
  与 stableIdentity;journal 的 binding-none 步骤规则不被破坏。
- Evidence:实现 PR 内测试 + `evidence/runs/TASK-HTP-007/run-r1.md`。
- **结论(2026-07-31):PASS** — `testHostOnlyAdmissionNeverTouchesTheDeviceSurface` 用
  一个「什么都没接管」的 facts witness 断言 submit 与 run 全程 **零次** facts 查询、job
  成功、evidence 的 bindingRevision 为空、provider=workspace、effect=hostOnly;
  `testAHostOnlyRequestMayNotPinABindingRevision` 断言携带 `expectedBindingRevision`
  的请求被拒;`testReconcilingAHostOnlyJobNeverReachesADeviceReadback` 断言 reconcile
  不解析设备 facts(要么无事可做,要么按引用拒绝);
  `testDraftingACapabilityForAHostOnlyOperationIsRefused` 断言 capability draft 被拒;
  `testTheInspectionArtifactHoldsTheRealBytesAndNoDeviceBinding` 断言 artifact 的
  bindingSnapshot 无 revision、无设备身份。`MaterializedPlanDocument` 用
  `encodeIfPresent`,设备计划字节与 plan digest 逐字节不变。

## HTP-AC-21 设备绑定准入逐条不变(TASK-HTP-007)

- 方法:回归断言 `binding: confirmedDevice` 的既有准入行为不变——facts 缺失/targetID
  不匹配/缺 `expectedBindingRevision`/缺 connectKey/身份摘要非法时仍以同样的
  `evidenceIncomplete` 语义拒绝,且拒绝发生在授权之前(capability 不被消耗)。
  新路径只对 `binding: none` 可达:断言设备 operation 走不进 host-only 分支。
- Evidence:实现 PR 内测试(正反例)+ 全量套件结果。
- **结论(2026-07-31):PASS** — 最强信号是全量 877 例(含全部既有设备绑定准入测试)在改动后
  仍绿;另有三条显式回归:`testDeviceBoundAdmissionStillRequiresCompleteFacts`(无 facts
  时仍以 `target facts cannot materialize` 拒,且确实查过 facts)、
  `testDeviceBoundAdmissionStillRequiresAPinnedBindingRevision`(有 facts 但请求未 pin
  binding revision 仍拒 —— 新分支放宽的只有 host-only)、
  `testEveryDeviceBoundOperationStillDeclaresConfirmedBinding`(仓内除 workspace 外
  每个 operation 仍 `confirmedDevice`,且 `binding: none` 的 operation 恰好只有一个,
  新分支对设备面不可达)。

## HTP-AC-22 host-only operation 的双向 fail closed 与首个消费者(TASK-HTP-007)

- 方法:①契约层断言 host-only operation 内出现 `binding: confirmedDevice` 步骤或高于
  `hostOnly` 的 effect 时被拒(生成器与运行期双面);②`workspace.inspectSource@1` 的
  lowering **逐 token** 断言完整 argv(零 shell、零拼接),工具未配置时
  `operation.list` 返回 `UNAVAILABLE` + 机器可读原因且零 capability 消耗;
  ③三方词表(registry / workflow-step schema / Swift validator)与生成器 pin 同步、
  `generate.py --check` 零 drift、catalog digest 更新。
- Evidence:实现 PR 内测试 + 生成器 `--check` 输出 + `operation.list` 输出 +
  `evidence/runs/TASK-HTP-007/run-r1.md`。
- **结论(2026-07-31):PASS** — ①`testAHostOnlyDescriptorWithADeviceStepIsRefused`
  逐项断言 host-only operation 内的 `confirmedDevice` 步骤、`deviceMutation` step effect、
  permitted 超过 hostOnly 三种情形均被 `validateHostOnlyDescriptor` 拒(生成器侧另有
  schema/registry 静态校验);②`testInspectSourceLowersToAnExactArgv` 逐 token 断言
  `["-r","-n","--include","*.cpp","--","WaterFlowPattern","/tmp/demo-app"]`(`--` 终止
  选项、根在末位);`testTheProviderRefusesPathsUnknownProjectsAndDeviceFacts` 断言
  路径形 glob、未注册项目、resolveFacts 三面拒绝;
  `testUnconfiguredInspectorReportsUnavailableAndAdmitsNothing` 断言
  `no_workspace_inspector_configured` / `no_workspace_project_registered` 且 submit 被拒
  (零 capability 消耗);③三方词表 + 生成器 pin 同步,`generate.py --check` 零 drift,
  catalog digest `ad5d5a34…`;进程级 `operation.list` 显示 workspace 面 available 而
  设备面如实 unavailable。
  **实跑抓到并修的缺陷**:声明的必需 artifact 无人发布 → `artifactMapping` 与
  `artifactContents` 补齐(发布 stdout 原始字节,非摘要),并加字节级断言。

## HTP-AC-15 其余 workspace operation 的 availability 与零 raw 命令(TASK-HTP-005)

- 方法:五个 `workspace.*` operation(applyPatch/build/runTests/symbolize/revert)的
  lowering **逐 token** 断言由 preset 生成的完整 argv(与
  `DeviceProviderArgvContractTests` 同范式);LLM/CLI 提交 argv 一律被拒;
  preset 或工具链缺失时 `operation.list` 返回 `UNAVAILABLE` + 机器可读 reasonCode,
  且 capability 不被消耗。
- Evidence:实现 PR 内测试 + `operation.list` 输出。
- 结论:pending

## HTP-AC-16 patch 范围受限、可回滚、零 push(TASK-HTP-005)

- 方法:`applyPatch` 越出声明 glob 时 fail closed(零写入);apply 产出
  applied-patch artifact 且 `revertPatch` 回到原 workspace revision;断言 provider
  不存在 `git push`/`merge`/force 或 PR 创建路径。
- Evidence:实现 PR 内测试。
- 结论:pending

## HTP-AC-17 build/test 真实执行与如实分类(TASK-HTP-005)

- 方法:`buildOpenHarmony`/`runTests` 经 descriptor-bound dispatcher 真 spawn,产出
  build log / test output artifact 与真实 exit code;失败如实分类(不得把失败构建的
  下游步骤记为成功——CHG-2026-049 trace 教训的同类防线)。
- Evidence:实现 PR 内测试 + 真实构建输出 hash。
- 结论:pending

## HTP-AC-18 GJ-5 真机自动收敛、人工步骤 0(TASK-HTP-006)

- 方法:已接管设备 + 当前 catalog digest 上,一次 `task.submit` 自动完成 运行 →
  采集 → 分析 → (可选 patch → build → 部署) → 复验,直到 evaluator `PASS` 或安全
  停止;记录接管后人工步骤计数(E0 与已授权 E1 目标 = 0)、每轮 decision/job/artifact
  链、预算消耗与停止原因。
- Evidence:runtime job/artifact 真实记录 + run 记录(`evidence/runs/TASK-HTP-006/`)。
- 结论:pending-hardware(需设备窗口;E1 段另需维护者经 merged PR 签发的 standing
  capability)

## HTP-AC-19 真机证据如实性(TASK-HTP-006)

- 方法:真机结论包含命令、退出码、artifact ID 与 hash、脱敏设备标识、executor 身份
  (agent)与按实际 effect 匹配的 authority reference;断言 fake/simulation 结果未被
  记为真机结果;若任一环节为 simulation,结论必须相应降级。
- Evidence:run 记录 + artifact 索引。
- 结论:pending-hardware
