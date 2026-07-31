# TASK-HTP-003 run r1 — policy guard、预算、失败指纹与 HumanActionRequired 生产者

- Date:2026-07-31
- Executor:agent(交互式会话),host-only
- Gate:同 TASK-HTP-001 的维护者提前解冻;前置 TASK-HTP-001/002 已 done(#845/#848 合入)
- Effect:hostOnly / readOnly。零 HDC dispatch、零 capability 消耗、零 job 创建
- Authority:default read-only policy(E0)

## 1. 套件

```text
swift test --package-path Packages/ArkDeckKit
Executed 815 tests, with 1 test skipped and 0 failures (0 unexpected) in 63.665s
```

新增 `HarnessBoundsContractTests` 19 例(HTP-AC-8..11 + 三层 memory);001/002 的 35 例
在 guard 接入后全绿。

## 2. Guard 的检查序(第一条拒绝即结论)

```text
1 预算 → 2 task type 闭集 → 3 runtime availability → 4 raw command 面
→ 5 effect ceiling → 6 authorization → 7 失败指纹 → 8 无进展 → 9 active job
```

3 在 6 之前是**故意的**:PRODUCT-LOOP §8 要求 provider/plan 不可用时不得消耗
capability,最省的保证方式就是在问授权之前先拒。测试
`testAnUnavailableOperationIsRefusedBeforeAuthorizationIsConsulted` 断言 capability
port **一次都没被问**。

### 实现期抓到的真实设计错误(测试驱动)

第一版按 `permittedEffects.max()`(**上限**)授权,结果把 GJ-1 的 E0 采集拒了 ——
`capture.diagnostics@1` 的上限含 `deviceMutation`(remote trace 那条路径)。

正确划分:**有效 effect 由请求选中的步骤决定,而这条选择规则属于引擎**
(CHG-2026-049 的修正就是「授权与执行共用同一条纯选择规则」)。harness 在这里重算它
= 第二份会漂移的实现;猜上限 = 误拒真实闭环。所以 guard 只守它不复制任何东西也能知道的:

- **地板**(`minimumEffect` 已经是 deviceMutation)→ 必然需要授权;
- **destructive 上限** → E2 永不自动化(有预算、有 capability 也不行);
- 两者之间 → 交引擎 admission,它无 capability 即拒且原子消耗。

`testReadOnlyCeilingOperationsAreLeftToTheEngine` 把这条取舍钉住,防止后人"修回"上限。

## 3. HTP-AC-8 预算即停止

四类预算各有断言(`testEveryBudgetKindStopsTheTask`):rounds / wallClock /
artifactBytes / e1Mutations,每类都有机器可读 reason code。

- `testWallClockExhaustionStopsBeforeDispatchingAnything`:时钟在 submit 与首次唤醒之间
  跨过预算 → `maxWallClockExhausted`、**零 dispatch**(仅查轮数的实现会漏掉这条);
- `testArtifactBytesAreChargedOncePerVerifiedArtifact`:只有**验证通过并读满**的字节被
  计费、每个 artifact 只计一次;预算耗尽后同一次唤醒即停,已取得的样本仍留在记录里。

## 4. HTP-AC-9 失败指纹与无进展

指纹 = operationRef + phase + provider(取自 catalog descriptor)+ targetProfile +
归一化 inputs hash + errorClassification + semanticErrorCode;摘要即文件名
(`FAIL-<16 hex>`,无分隔符 → traversal 不可表达)。

| 同指纹次数 | 行为 | 测试 |
|---|---|---|
| 1 | 允许原策略 | `testSecondIdenticalStrategyIsRefusedAndThirdIsProhibited` |
| 2 | 拒绝**完全相同**的 decision;改 typed inputs 即算新策略 | 同上(含正例) |
| ≥3 | 停止 → `strategyExhausted` 人工阻塞 | `testFailureMemoryIsCrossTaskAndDrivesTheThirdStrikeStop` |

失败记忆**跨任务**:三个不同 task 命中同一指纹,记录只有一条、`observedByTasks` 三个,
第三个 task 直接被停(第二个 task 不必重新发现第一个的坑)。

无进展:`noProgressRounds` 进 projection(durable —— 重启不重置耐心),只有
`jobObserved`/`evaluation`/`recovery` 因果可写;连续 2 轮无「新验证证据 / 新样本 /
verdict 变化」即停。`testNoProgressRoundsAccumulateAndStopTheLoop` 端到端跑到停止并用
新 store 读回同一计数;`testProgressVectorIgnoresProseAndCountsEvidence` 断言"只多了
分析文字"不算进展。

## 5. HTP-AC-10 outcomeUnknown → 结构化 HumanActionRequired

`HumanActionRequired`(CHG-2026-025 起就在仓内、437 行、runtime 面零生产者)现在有了
生产者。类别取自封闭词表,reasonCode / minimumActionKey / prohibitedAutomation /
resumeProbe 由**模型自己**填,harness 不写自己版本的"人该做什么"。

`testOutcomeUnknownProducesATypedHumanActionAndResumesOnlyOnAResolution` 断言:
category `outcomeUnknownDecision`、reasonCode `recovery.outcomeUnknown`、
minimumActionKey `human.reconcileOrAbandon`、prohibitedAutomation `[outcomeGuess]`、
resumeProbe `reconcileOutcome`、jobId = 真实 job;零自动重发;空 resolution 被拒;
typed resolution 后**文档自身的状态机**把它翻成 `resolvedByFreshProbe`,phase 不回退。

**如实边界**:四类阻塞里只有 `authorizationApproval` 与 `outcomeUnknown` 能被封闭词表
准确描述;`strategyExhausted` / `evidenceIntegrity` / `environmentUnavailable`
**不产出文档**(`document: nil`),只带 status + reasonCode + 证据引用。给它们硬凑一个
category 等于往证据级文档里写不实的"最小人工动作"—— 这正是 CHG-2026-050 的教训
(不要拿最像的身份顶替)。扩词表是契约变更,该走自己的载体。

## 6. HTP-AC-11 E2 永不自动化、E1 只用既有 capability

- `flash.dayu200@1`(destructive):即便预算 8 次 mutation + capability 在手,仍
  `destructiveEffectNeverAutomated`;并断言 `defaultPolicy(for: .debugCrash)` 不含它;
- `debug.hap@1`(地板 deviceMutation):无预算 → `authorizationRequired`;有预算但无
  维护者签发的 capability → `authorizationRequired`;两者齐备 → guard 让路,由引擎
  admission 定夺(harness 从不 draft/install/consume);
- 不可用 operation → 先拒且**不问 capability**(见 §2)。

## 7. 进程级实跑抓到并已修的缺陷

真实 UDS + 真实引擎跑:submit → reconcile(target 未接管 → 引擎拒)→ 查 humanActions
与 memory。

**缺陷**:失败指纹写入了,但 `task memory` **空**。根因 = admission 被拒时既无 jobID
也无 artifact,而证据模型只认 job/artifact/evaluation → `evidenceRequired` 抛错,又被
`try?` 静默吞掉。修法两条:

1. 证据模型新增 `requestIDs`(durable dispatch intent 本身就是证据 —— 仓内
   "intent before effect" 的那条记录);
2. 这些 memory 写入不再 `try?`:写不进去是存储问题,值得失败,不该静默。

新增回归 `testARefusedAdmissionIsRecordedInTaskMemoryWithTheIntentIdentity`。修复后同一
条路径实跑:

```text
reconcile: stoppedForHuman | submissionRejected
task memory: attempt | observed | evidence.requestIds: ['htask-a6905c1009e37f6afe3ac422']
             observe.device@1 failed (submissionRejected); fingerprint FAIL-0F6CE890B95D33F2 now at 1
humanActions: block=environmentUnavailable | document=none | requestId=htask-a6905c…
resume --resolution "operator: adopt the device first" → status=running phase=initializing v4
humanActions: block=environmentUnavailable | open=False | resolution="operator: adopt the device first"
failure memory: FAIL-0F6CE890B95D33F2.json occurrences=1 class=admissionRejected code=operationUnavailable
```

全程零 job、零 dispatch、零 capability 消耗。

## 8. 本轮**未**验证的部分(如实登记)

- **真机**:未接管设备,真机 E1 与收敛属 TASK-HTP-006(pending-hardware);
- **E1 真实消耗路径**:capability port 只被查询,真实 E1 执行需维护者签发 capability +
  设备窗口(DHA-HW-002 同类前置),本轮只验证"无授权即拒"的一侧;
- **决策多样性**:`requireNewStrategy` 目前必然停止,因为确定性 handler 只有一种策略;
  能提出替代策略的决策端口是 TASK-HTP-004,届时同一条拒绝会变成"重新规划"而非停止
  (代码注释已标明);
- **模型出站**:未接入(TASK-HTP-004)。
