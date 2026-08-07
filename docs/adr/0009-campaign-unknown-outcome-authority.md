# ADR-0009: `outcomeUnknown` 的两个写入者,与和解读回的适用面

- Status: accepted(CHG-2026-025 r17,TASK-AIN-020,2026-08-07)
- Deciders: lvye(merge 即批准)
- Context: `settlesUnknownLoaderTransition` 是 `outcomeUnknown` 尝试唯一的和解出路。
  它有完整契约覆盖(正向 settle + 六条负向 + 分类器自身),但连续三个真机窗口、
  两种不同打断方式,一次都没有被调用过。r16 要求定案:要么让它可达,要么如实
  降级它;明确拒绝第三种——留着一道从未也无法执行的闸,却在文档里当恢复能力。

## 查实的事实

r16 把原因归给「引擎的 job 失败不给 usage reservation 落 terminal」。逐条读代码后,
真实结构比这句更细,而且分成两半:

1. **`outcomeUnknown` 有两个写入者,含义相反,记录里却是同一个词。**
   - 引擎(`RuntimeJobEngine.recordCampaignOutcome`):job 活着,自己测出结果不可
     确证,intent 集合来自它 journal 过的东西。
   - campaign 和解(`reconcileUnresolved` 的「无 terminal」分支):写入者已死,
     三个集合全空。**这是一次缺席,不是一次测量。**
2. **和解自写的那条 terminal 按构造永远到不了读回。** `reconcileUnresolved` 在同
   一次调用里写 terminal *并且* `closeAttempt`;此后 `document.activeReservation`
   为 nil,下一次 `continue` 在第一道 guard 就返回。所以
   `terminal.status == .outcomeUnknown` 那条分支只可能看见**引擎写的** terminal。
   三个窗口都杀了写入者,于是三次都走「无 terminal」分支。
3. **引擎写的 `outcomeUnknown` 是产线可达的**,不需要设备崩溃:
   `DescriptorBoundProcessDispatcher` 在子进程结果不可观测时抛
   `RuntimeDispatchFailure.outcomeUnknown`;provider verify 返回 unknown 且该步没有
   配对读回时同样如此。
4. **分类器唯一的输入是一个滞后于持久事实的投影。** `settlesUnknownLoaderTransition`
   经 `job.evidence` 读 `record.actualStepKinds`,而该字段在
   `persistRuntimeRecord`(写前置 intent 之**前**)之后才被追加进内存记录。进程在
   写前置 intent 已持久、下一次 persist 之前死亡,磁盘上的 `actualStepKinds` 就
   **不含**那条已持久的破坏性 intent——正是崩溃落点的那个窗口。
5. **一个更强的证据被真的丢掉了(与 r16 所述不同层)。** r16 说
   `confirmedNotExecuted` 分支被 `else if` 短路。实际更硬:
   `AgentAuthorityUsageTerminal` 拒绝在 `status != .failed` 时携带非空
   `confirmedNotExecutedIntentEventIDs`,所以 `outcomeUnknown` 的 terminal
   **根本装不下**这条证据——短路从来不是约束点,这条 ledger 不变量才是。
   真正在丢证据的是另一处:`finishReconcile` 的 `.confirmedNotExecuted` 分支
   journal 出的 stepOutcome **不带** `semanticCode`,而 `mutationIntentEvidence`
   只认这个 code。于是专用读回证明了破坏性步骤从未执行,usage terminal 不说,
   campaign 照旧烧成 `unsafePartial`。

## Decision

**两半都做,各自用在它成立的地方。**

1. **读回保留,并如实收窄到引擎写的 `outcomeUnknown`。** 那是唯一带 journal 支撑的
   intent 集合、且 job 还活着的写入者。它有产线入口(事实 3),所以这不是一道空闸。
2. **崩溃(无 terminal)不是读回的适用面,并停止被描述成恢复能力。** 依据是事实 2
   与事实 4:分类结果在同一次调用里就被封存、再也不会被重读;而分类器的输入恰好在
   崩溃窗口内可能漏掉一条已持久的破坏性 intent。此外 job 层 journal 还留着一条
   outstanding intent,归 job 级 recovery 管,campaign 级和解从不查阅它。
   崩溃尝试保持 `outcomeUnknown`,代码与文档都不再声称它可被读回救回。
3. **证据的次序高于状态。** 判定规则抽成
   `RockchipEvolutionCampaignHost.classify`,「每条已派发变更都被证明未执行」排在
   状态判断**之上**。今天它不改变任何行为(事实 5:ledger 不让该形状存在),
   收进来是为了状态不能再一次盖过证明,并由测试钉住次序本身。
4. **已存在的证明不得再被丢弃。** `finishReconcile` 的确认未执行结论改为带上
   `mutationIntentEvidence` 认得的 semantic code。
5. **分类依据必须可读。** `attemptTerminal` 事件新增可选 `detail`,记录读到了什么
   terminal、intent 集合的算术、命中哪条规则、读回是否被调用及其结论。

## 不做,及原因

- **不放宽任何一条 disposition。** `unsafePartial` 逐字不变;只允许把「已证明无副作用」
  从 `outcomeUnknown` 摘出去,绝不允许把「未知的部分副作用」摘出去。
- **不解除事实 5 的 ledger 不变量。** 引擎产不出「`outcomeUnknown` + 非空
  confirmedNotExecuted」:一条被证明未执行的步骤会终结它自己的 job,job 于是以
  `failed` 收口。解除不变量只会造出一个没有写入者的形状——正是本 ADR 拒绝的那种
  空闸,换了个位置。
- **不动 `isLoaderTransitionOnly` 的排除面。** 写过分区的尝试仍然、也应当到不了读回。
- **不改事实 4 的 persist 次序。** 它今天无害(无 terminal ⇒ 不查读回),而它正是
  决策 2 的承重理由之一;在派发热路径上顺手重排,会把一条论据换成一处未经论证的
  改动。若将来要让崩溃走读回,先修它,并重新论证本 ADR 的决策 2。

## Consequences

- 读回从「三个窗口零调用」变成有明确、可测的产线入口,且入口形状由真实引擎在
  归档门测试里产出而非手工种入。
- 崩溃尝试的处置没有变松:仍然 `outcomeUnknown`,仍然停给人。变的是记录不再暗示
  有一条跑过的恢复路径。
- 专用读回产出的无副作用证明第一次能抵达 campaign 判定,`unsafePartial` 的误判面
  相应缩小——缩小的是**有证明**的那部分,不是没证据的那部分。
- `attemptTerminal` 多一个可选字段;早于 r17 的 campaign 文档原样解码。
