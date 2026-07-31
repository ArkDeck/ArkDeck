# Verification — CHG-2026-054

> Change:CHG-2026-054-agent-harness-task-plane@r1
> Status:in_progress # 2026-07-30:HTP-AC-1..6 通过,AC-7 的判定/fail-closed 面通过
> 且真机字节面如实 pending-hardware;AC-8..17 pending(各自任务未开工),
> AC-18/19 pending-hardware。每条结论由其所属任务的实现 PR 写入本文件;维护者
> review/merge 该实现 PR 即确认。不为本 change 追加独立 verification/archive 载体
> (PRODUCT-LOOP §4/§20)。

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
  requestHuman 不被 collectMoreEvidence 稀释。 observation 来自真实字节且缺证据 fail closed(TASK-HTP-002)

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
- 结论:pending

## HTP-AC-9 失败指纹与 no-progress 收敛(TASK-HTP-003)

- 方法:同指纹第 2 次拒绝完全相同的 decision(必须至少改变 operation/inputs/前置/
  patch region/hypothesis/artifact 来源/profile/recovery path 之一);≥3 次 →
  `HUMAN_REQUIRED`/`FAILED`;无进展轮不产生新的 effectful job。
- Evidence:实现 PR 内测试。
- 结论:pending

## HTP-AC-10 outcomeUnknown 停止并产出结构化人工阻塞(TASK-HTP-003)

- 方法:构造 `outcomeUnknown` job 结果,断言零自动重发原副作用、产出
  `HumanActionRequired`(category `outcomeUnknownDecision`,含 reasonCode、
  evidenceRefs、resume 状态),typed resolution 后可恢复到原 phase。
- Evidence:实现 PR 内测试。
- 结论:pending

## HTP-AC-11 E2 永不自动化、E1 只用既有 capability(TASK-HTP-003)

- 方法:E2 operation 一律拒绝并产出 `HumanActionRequired`(断言 harness 无
  draft/install/consume E2 的路径);E1 capability 缺失/过期/范围不符时 fail closed,
  零 dispatch、零 capability 消耗;capability 在 provider 或 plan 不可用时不被消耗。
- Evidence:实现 PR 内负例测试。
- 结论:pending

## HTP-AC-12 decision 严格 schema 与拒绝面(TASK-HTP-004)

- 方法:负例集断言以下一律整条拒绝——raw argv/shell/HDC/远端路径、task 或 job 状态
  字段、retry 计数、成功结论、授权结果、catalog 外 operationRef、typed inputs 越界;
  正例只接受四类 decision。
- Evidence:实现 PR 内测试(负例逐项)。
- 结论:pending

## HTP-AC-13 出站默认 deny 与脱敏有界(TASK-HTP-004)

- 方法:默认配置下断言零出站(无 adapter 调用);显式开启后断言 `DecisionContext`
  仅含脱敏、有界摘要与 artifact 引用——不含未脱敏字节、设备标识、凭据,且总尺寸
  在声明上限内;超限时裁剪并记录,而非静默发送。
- Evidence:实现 PR 内测试。
- 结论:pending

## HTP-AC-14 决策端口可替换且状态不依赖模型会话(TASK-HTP-004)

- 方法:同一 `DecisionContext` 分别经离线确定性 adapter 与真实 adapter,断言状态机
  结论路径等价(接受/拒绝/停止的判定不依赖 adapter 身份);断言 task 状态不保存任何
  模型会话句柄。
- Evidence:实现 PR 内测试。
- 结论:pending

## HTP-AC-15 workspace provider availability 与零 raw 命令(TASK-HTP-005)

- 方法:六个 `workspace.*` operation 的 lowering **逐 token** 断言由 preset 生成的完整
  argv(与 `DeviceProviderArgvContractTests` 同范式);LLM/CLI 提交 argv 一律被拒;
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
