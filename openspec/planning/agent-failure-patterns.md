# Agent 失败模式手册（非权威索引）

> **本文件不是规则源。**它是一份非权威（non-normative）导航索引，不属于
> Constitution、spec、contract、integration/platform profile、enforcement 或
> execution policy，也不创造任何批准、授权、就绪、完成或平台支持语义。
>
> **冲突处置。**本手册的任何建议与
> [`AGENTS.md`](../../AGENTS.md)、[`constitution.md`](../constitution.md)、
> [`enforcement.md`](../governance/enforcement.md)、
> [`verification/policy.md`](../verification/policy.md)、current specs 或
> contracts 冲突时，**忽略本手册**，按 [`AGENTS.md` 的权威顺序](../../AGENTS.md#权威顺序)
> 处理；无法裁决时任务 `blocked`，而不是由本手册选择更方便的解释。
>
> **只链接，不复制。**每条案例只给出仓内相对路径与完整 40-hex Git OID。本手册
> 不复制 raw evidence、hash 表、transcript、secret、真实设备标识、用户绝对路径或
> 大段日志（[`POL-PRIVACY-001`](../constitution.md#pol-privacy-001-local-first-and-explicit-export)、
> [`POL-ARTIFACT-001`](../constitution.md#pol-artifact-001-raw-evidence-is-immutable)）。
>
> **archive 只读。**`openspec/changes/archive/**` 是冻结历史，本手册只读引用，
> 不改写其任何字节或结论。被引用 change 的现实缺陷仍由其所属 approved change 处理。

本手册登记 ArkDeck 可审计历史中**重复发生**的 Agent 失败模式，供新任务开工前
检索。taxonomy 与其封闭范围登记在 **CHG-2026-029 的 `design.md` §3**（revision r4，
protected `main` `d53da289b7da80a4ee2282f5dea3122ebf97325a`；该 change 归档后目录
位置会变，故此处以 change ID 与完整 OID 定位，不使用相对路径）：
`AF-001`…`AF-009` 是**治理/交付轴**（change、PR、evidence、授权面），
`AF-010`…`AF-018` 是**执行/验证轴**（实现与验证动作本身）。两轴正交，同一次事故
可以同时命中两轴；本手册按根因归属登记，不做互斥分类，也不维护"发生次数真相
数据库"。

每项固定八个字段。`Observed cases` 中 **Fact** 是仓内可复查记录的直述，
**Inference** 是由此得出的推断，两者显式分离。`Automation status` 只取
`mechanized` / `partiallyMechanized` / `semanticReview`，并如实写明边界——
**CI 绿不解释为批准**（[enforcement 批准语义](../governance/enforcement.md#批准语义)）。
`Currency` 记录最近复核的完整 protected-main OID 与日期；`AF-NNN` ID 不复用。

## AF-001 readiness/allowed-paths 假阳性

### Signal

readiness 声明"交付形态与观察点逐项对应"但未逐点走通取证路径；allowed paths 未
枚举全部真实消费者与闭环文件；设计改动会触碰共享/横切契约表而该表不在授权面内。

### Observed cases

- **Fact.** TASK-RKFUI-001 `run.md`（CHG-2026-026 `evidence/runs/TASK-RKFUI-001/run.md`，blob `0f24bb2424e43edb34de0fffaa0eee3c4e5cbec3`）
  记录 full-suite allowed-path blocker：按已批准设计新增依赖所需的共享依赖表文件
  不在该任务初始 allowed paths 内，实现因此先被阻断。实现 PR #301 merge
  `864df6fb29213e39338e72f4e35d7369d10ab961`；精确路径 remediation PR #303 merge
  `b81361bcbe19c136e96005513261a38252755c9c`。
- **Fact.** CHG-2026-006 `tasks.md`（blob `779ff6ac060ab7ba82ddaf955b65702ec52285db`）
  保留 TASK-M0B-002 的 readiness 记录与其后的 fail-closed 回退；回退依据登记在
  CHG-2026-022 `proposal.md`（blob `63fa348e8f08276d17b1655532714d5da3a67482`）。
- **Inference.** 硬编码的横切契约表（共享依赖表、registry 表）是 readiness 起草期
  **可预见**的冲突点；起草时预判设计改动波及哪些共享契约测试并提前纳入 allowed
  paths，可省掉一轮维护者往返。该因果为推断，不是被引用记录的直述结论。

### Root cause

范围判断停在"我要改哪些文件"，没有下推到"谁消费这些文件、改完谁会红、观察点
怎么取证"。readiness 的形态对应声明与其取证路径之间缺一次源码级验证。

### Preflight

1. 列出每个交付物的**全部**真实消费者（生产调用方、契约测试、共享表、fixture）。
2. 对每个声明的观察点写出"人怎么观察 + 结果怎么落盘"，逐点走通到取证路径级；
   UI 面存在不等于可取证。
3. 预判设计改动会触碰哪些共享契约表，提前纳入 allowed paths。
4. 实现中发现的相邻缺陷**不顺手修**；越出授权面只能事后走独立 remediation
   （[`AGENTS.md` 执行规则](../../AGENTS.md#执行规则)的"不得静默扩展任务范围"）。

### Verification

- **Positive.** 在授权面内跑通全量套件，并逐条列出观察点的取证产物路径。
- **Negative.** 在 readiness 阶段构造"若某消费者未被枚举会发生什么"：对每个未纳入
  的候选路径说明它红在哪一步；无法说明即视为枚举不完整，任务保持 `blocked`。

### Canonical references

[`AGENTS.md` 执行规则](../../AGENTS.md#执行规则)、
[`AGENTS.md` Agent 禁令](../../AGENTS.md#agent-禁令)、
[verification policy — Definition of Ready](../verification/policy.md#definition-of-ready)。

### Automation status

`partiallyMechanized`。CHG-2026-028 的 PR allowed-paths diff 校验机械关闭"无意混装"
与"状态 PR 夹带实现"两类形态，其边界在
CHG-2026-028 `proposal.md`（blob `d7718251c074f3b23bb32f8703c863efc9912245`）
中被如实登记为 guard-rail 而非安全边界；"消费者是否枚举完整"仍是语义判断。

### Currency

复核基线 `31865366f7bdb8e5ca33f0c8d41c15f6daba7933`，2026-07-23（Asia/Shanghai）；
首批基线 `de6b79aafa95700297a94dc311e94b1283f8abdd` 的记录不追溯改写。

## AF-002 production root/authority/effect path 不可达

### Signal

契约测试可以构造正例，但 App/CLI 的 production composition root 没有可信数据源；
仪表、计数或分类落在生产路径从不触发的入口；"能力存在"被当作"生产可达"。

### Observed cases

- **Fact.** CHG-2026-022 `review.md`（blob `d03118ab83cbeb278910c08e55573094edbd5169`）
  记录：`OBS-FANOUT-001` 无 production data source（生产 composition 内没有任意设备
  枚举，participant inventory 诚实保持空集）；`OBS-COUNTER-001` 无可满足的
  unforgeable production origin（Supervisor 无自动 executor，调用方提供的 enum 可以
  误分类手工 dispatch，直接改 monitor 不是真实 dispatch point），被接受的替代形态是
  在唯一成功的 identity-bound spawn hook 上做 opaque-permit 分类。#269 merge
  `3147e33c0d4bf0f9f54e6160850a42f370c05cb6`。
- **Inference.** 落在生产不可达入口的计数等价于分支常量变体——它的取值由测试
  夹具决定而非由生产行为决定。该等价性是推断（与 `AF-010` 共面）。

### Root cause

设计只论证了"类型/接口存在"，没有论证从 production root 出发能取得可信 authority
并到达真实 effect dispatch point。fake 与 production 的结构差异未被写出。

### Preflight

1. 画出 production composition root → authority/permit/capability 的**唯一产生点**
   → effect dispatch point 的完整链路；任一段缺失即 `not applicable` 或 `blocked`。
2. 写明 fake/simulation 与 production 的结构差异，以及为什么正例不会跨过该差异。
3. 每个仪表/计数定位到唯一真实边界，并说明它为何不可由调用方伪造 origin。

### Verification

- **Positive.** 从 production root 触发一次真实路径，断言 effect 在预期 dispatch
  point 发生。
- **Negative.** 删除或断开 authority 产生点，断言链路 fail closed（authority 为空、
  dispatch 计数为 0），而不是回退到默认放行。

### Canonical references

[`POL-WORKFLOW-001`](../constitution.md#pol-workflow-001-typed-and-auditable-side-effects)、
[`POL-MODE-001`](../constitution.md#pol-mode-001-execution-modes-cannot-be-confused)、
[verification policy — Verification layers](../verification/policy.md#verification-layers)。

### Automation status

`semanticReview`。无通用机械门；contract 测试只证明比较函数，不证明生产链路。

### Currency

复核基线 `31865366f7bdb8e5ca33f0c8d41c15f6daba7933`，2026-07-23（Asia/Shanghai）；
首批基线 `de6b79aafa95700297a94dc311e94b1283f8abdd` 的记录不追溯改写。

## AF-003 caller-controlled trust/provenance/facts

### Signal

授权载体、设备事实、使用次数或 evidence provenance 由调用方以文本/文件自报；
shape 校验（JSON 合法、字段非空、格式匹配）被当作信任证明。

### Observed cases

- **Fact.** CHG-2026-025 `review.md`（blob `197e4adc47f75444a54eefadf00e58b4681e5202`）
  记录 `P0-AUTH-001`（parser 只校验 JSON shape 与 pin 格式，未证明 bytes 位于新鲜
  拉取的 protected main、未核对承载 commit/blob OID、未核对 merged PR/CODEOWNER
  approval，调用方可同时制造 authorization 与 carrier 文本）与 `P0-FACT-001`
  （调用方可声明 prior run count、durable binding revision、prerequisites 与 identity
  readback；validator 不拥有 journal/device/tool ports，`maxRuns=1` 在并发 Job 中可被
  多个 `priorRunCount=0` 同时通过）。#299 merge
  `a2dab4c3f4279cff0ef1a859cdb5297afe9aeb85`。
- **Fact.** 同一记录的 `P0-DISPATCH-001` 指出正例 contract 输出真实 dispatch 为 0，
  因此只证明比较函数，不证明产品执行链。
- **Inference.** "同一调用方能否同时伪造事实与其证明"是比"字段是否齐全"更早应该
  提出的问题。该优先级为推断。

### Root cause

威胁模型没有区分**事实的生产者**与**事实的搬运者**。校验器不拥有事实来源
（journal、device port、Git 远端）时，它能验证的只有形状。

### Preflight

1. 对每项被信任的事实写出：谁生产它、它绑定到哪个具体目标与 revision、freshness
   边界是什么、调用方能否同时构造它与它的证明。
2. 跨 Session/并发场景下，usage count 一类计数是否原子。
3. 无法回答即 fail closed（[`POL-SAFETY-001`](../constitution.md#pol-safety-001-fail-closed-under-uncertainty)）。

### Verification

- **Positive.** 用真实来源产生的事实走通一次授权判定。
- **Negative.** 构造调用方自制的 authorization + carrier + facts 三件套，断言门拒绝；
  并发场景下构造两个 `priorRunCount=0` 请求，断言不会同时放行。

### Canonical references

[`POL-AGENT-002`](../constitution.md#pol-agent-002-autonomous-agents-never-execute-real-destructive-hardware-workflows)、
[`POL-TARGET-001`](../constitution.md#pol-target-001-identity-before-convenience)、
[`AGENTS.md` 信任与批准](../../AGENTS.md#信任与批准)。

### Automation status

`partiallyMechanized`。schema/contract 测试覆盖形状，不覆盖 provenance。与
`AF-014` 的分工：本项是**谁生产事实**，`AF-014` 是**门自身校验了什么**；同一 gate
可两者兼有。

### Currency

复核基线 `31865366f7bdb8e5ca33f0c8d41c15f6daba7933`，2026-07-23（Asia/Shanghai）；
首批基线 `de6b79aafa95700297a94dc311e94b1283f8abdd` 的记录不追溯改写。

## AF-004 producer→consumer 端到端与跨语言类型缝隙

### Signal

producer 与 consumer 各自有测试但从未在同一真实路径上跑过；同一契约存在多份
实现（Swift/Python/数据件）；跨语言布尔、数值、序列化与身份比较未被对齐。

### Observed cases

- **Fact.** [TASK-PD-002 `platform-attempt-2026-07-20.md`](../changes/archive/2026-07-21-chg-2026-009-dayu200-partition-decode/evidence/runs/TASK-PD-002/platform-attempt-2026-07-20.md)
  记录首次真实 producer→consumer run 的诊断：Objective-C 的 `@(expr != 0)` 装箱出
  `NSNumber(int)`，JSON 序列化为 `1`，Python 侧 `is True` 身份检查永败而 `==` 意外
  通过。r5 诊断/revision PR #158 merge `b8902b199bfa834e8ea6022ea30f8e809c280eee`；
  producer 修复 PR #160 merge `33aff46b9a66370074af66b66ff2afb1ec164e48`。该 attempt
  是 blocked 记录，未升级为 passing evidence。
- **Fact.** TASK-RKFUI-001 `run.md`（CHG-2026-026 `evidence/runs/TASK-RKFUI-001/run.md`，blob `0f24bb2424e43edb34de0fffaa0eee3c4e5cbec3`）
  记录同一 E0 面存在 Swift 与 Python 两侧实现并各自跑通契约套件
  （`RockchipDeviceDiscoveryContractTests` 与 `scripts/rockchip_e0_probe/test_probe.py`），
  且明确记载该次 sanitized receipt 由人手从原始信封转录、其 schema 与本 commit 中
  `probe.py` 的直接输出对齐、下次 E0 窗口将直接由 `probe.py` 生成。
- **Inference.** 从未端到端跑过的双端契约，其"两侧都绿"不构成对齐证据。该判断
  为推断。

### Root cause

集成被推迟到平台 run 才发生。两侧各自的正例都建立在**自己**对契约的解释上，
解释分歧只有在同一条真实路径上才会暴露。

### Preflight

1. 尽早安排一次真实 producer→consumer run，不用 mock 替代其中任一端。
2. 列出契约的每一份实现，逐对比较语义（分类枚举、布尔、单位、上限的作用域）。
3. 一个数字/一套 taxonomy 有多个消费者时，显式指定权威侧并记录。

### Verification

- **Positive.** 一次真实端到端 run，产物由 consumer 逐项校验通过。
- **Negative.** 合成向量测试覆盖 int-boxed 布尔、缺字段、篡改字段，断言 consumer
  逐项报出**字段名与实际值**而不是笼统失败。

### Canonical references

[verification policy — Verification layers](../verification/policy.md#verification-layers)、
[`POL-SPEC-001`](../constitution.md#pol-spec-001-specification-is-the-source-of-truth)。

### Automation status

`partiallyMechanized`。Swift CI 与局部 contract 测试覆盖单侧；跨语言语义对齐靠
合成向量与 review。

### Currency

复核基线 `31865366f7bdb8e5ca33f0c8d41c15f6daba7933`，2026-07-23（Asia/Shanghai）；
首批基线 `de6b79aafa95700297a94dc311e94b1283f8abdd` 的记录不追溯改写。

## AF-005 evidence freshness、class 与 supersession

### Signal

旧 revision 的 PASS、candidate hash 或历史 run 没有在**事实原位**标记
`SUPERSEDED`；"工具产出"型 evidence（receipt/JSON）由人手组装；聚合类 evidence
把元数据与语义流混在一起。

### Observed cases

- **Fact.** TASK-UD-REDACTOR-001 `run.md`（CHG-2026-008 `evidence/runs/TASK-UD-REDACTOR-001/run.md`，blob `172ea48fba64819d0bf0743816323b8da68b6ec3`）
  在文件头部声明其 candidate hash 已被后续 remediation 记录取代，并在**每一行陈旧
  source-hash、三条 safe-literal 断言与测试总数处逐一标注 `SUPERSEDED`**，而不是
  只在文末写一句模糊注记。#150 merge `4cf67754bf4dd2f5c81c6e8537f8d79c8b71c3c5`。
- **Fact.** TASK-RKFUI-001 `run.md`（CHG-2026-026 `evidence/runs/TASK-RKFUI-001/run.md`，blob `0f24bb2424e43edb34de0fffaa0eee3c4e5cbec3`）
  记录该次 sanitized receipt **未由 E0 重跑产生**，而是由人手从原始信封转录；
  同时记录其 schema 与本 commit 中 `probe.py` 的直接输出对齐，并把"下次 E0 窗口
  直接用 `probe.py` 生成 receipt"作为后续动作留档。
- **Inference.** evidence 的可信度取决于它**能否被重新生成**，而不取决于它看起来
  是否规整。该判断为推断。

### Root cause

evidence 被当作一次性叙述而非可复现产物；supersession 只在新文件里声明，旧事实
原位仍呈现为有效结论，后续任务据此误读。

### Preflight

1. 每份 run 记录其绑定的完整 base OID、关键输入 pin 与 evidence class。
2. currency 三态在**事实原位**可见：`current`（精确绑定当前被评审 bytes）、
   `superseded`（保留历史事实但不用于当前结论）、`invalidated`（执行/输入/环境不
   满足方法，不构成 acceptance evidence）。
3. 工具产出型 evidence 由仓内工具生成；生成逻辑抽为可测纯函数。
4. 聚合类 evidence 只取语义流文件，避免元数据把关键标记挤出截断窗口。
5. 脱敏形态遵循既有先例，设备序列号与 connect key 字节不入仓。

### Verification

- **Positive.** 用仓内工具重新生成该 evidence，与提交件逐 key-path 比对一致。
- **Negative.** 篡改一处输入，断言重新生成的产物与提交件不一致且差异可定位；
  以及对已标 `superseded` 的行断言它不被任何当前结论引用。

### Canonical references

[`POL-VERIFY-001`](../constitution.md#pol-verify-001-evidence-not-task-completion)、
[`POL-ARTIFACT-001`](../constitution.md#pol-artifact-001-raw-evidence-is-immutable)、
[verification policy — Evidence 与 run 记录](../verification/policy.md#evidence-与-run-记录)。

### Automation status

`semanticReview`。evidence schema 约束结构，不判断某个 PASS 是否仍绑定当前 bytes。

### Currency

复核基线 `31865366f7bdb8e5ca33f0c8d41c15f6daba7933`，2026-07-23（Asia/Shanghai）；
首批基线 `de6b79aafa95700297a94dc311e94b1283f8abdd` 的记录不追溯改写。

## AF-006 PR/status/revision/pin 漂移

### Signal

proposal `revision`、acceptance `change_revision`、verification `@rN` 三方不同步；
pin 用截断前缀；状态 PR 夹带实现或实现 PR 夹带状态翻转；PR body 的 checks 数字
随修复 commit 累积而与实际不符；archive 前未做目录外引用扫描。

### Observed cases

- **Fact.** CHG-2026-028 `proposal.md`（blob `d7718251c074f3b23bb32f8703c863efc9912245`）
  的 Why 与诚实边界节列出四类已发生漂移：guard 绿不等于 Swift 绿、三方 revision
  漏同步、pins 截断、PR 载体与内容一致靠肉眼；并逐项给出先例 PR 编号。#316 merge
  `2382b47afb4a7ad2d0cb0f88e571b55b65593e61`。
- **Fact.** [CHG-2026-015 归档](../changes/archive/2026-07-22-chg-2026-015-hdc-readonly-probe-registration/proposal.md)
  曾因其 evidence/provenance 路径被活跃 registry 正本与产品测试 fixture 精确路径
  引用而长期暂缓，最终以 provenance re-pin 方式收口，PR #351 merge
  `583b1c1d4de1a77fc0554908f9b45e28fe604a56`。该暂缓是引用扫描**生效**的正例。
- **Inference.** 载体与内容不一致的危害在于它让审计账本失真——合并记录说的事与
  实际发生的事不同。该危害判断为推断。

### Root cause

状态、载体与内容分散在多个文件与 PR 元数据中，同步靠人；每处单独看都"差不多
对"，合起来就漂了。

### Preflight

1. 三方 revision 同步作为改 revision 的**同一次**动作完成。
2. pin 一律记完整 40-hex Git OID 与完整 64-hex SHA-256，不用截断前缀。
3. PR 标题与描述如实覆盖其全部内容；超出声明范围的内容拆分成独立 PR。
4. archive 前执行目录外精确路径引用扫描，断链即暂缓。
5. 合并前对账 PR body 中的数字与实际结果。

### Verification

- **Positive.** guard 与 CI 全绿，且三方 revision 值逐一取出比对相等。
- **Negative.** 构造 39-hex/63-hex 或字面占位符的 pin，断言校验具名报错；
  构造三方不一致的 revision，断言 guard 报错。

### Canonical references

[enforcement — 批准语义](../governance/enforcement.md#批准语义)、
[enforcement — CI 校验(sdd-guard)](../governance/enforcement.md#ci-校验sdd-guard)、
[`AGENTS.md` 执行规则](../../AGENTS.md#执行规则)。

### Automation status

`partiallyMechanized`。CHG-2026-028 将三方 revision 同步、结构化 pins 全 hash 与
PR allowed-paths diff 三面转为机器可判定；载体与内容是否**如实**仍靠 review。

### Currency

复核基线 `31865366f7bdb8e5ca33f0c8d41c15f6daba7933`，2026-07-23（Asia/Shanghai）；
首批基线 `de6b79aafa95700297a94dc311e94b1283f8abdd` 的记录不追溯改写。

## AF-007 非 hermetic 环境与本机隐式依赖

### Signal

测试依赖用户目录、构建期路径、锁屏状态、未钉工具链或隐藏硬链接；已知环境性
失败被"绿一次"当作不存在；外部 CI runner 镜像的工具链谱系凭印象下钉。

### Observed cases

- **Fact.** TASK-RKFUI-001 hermetic 契约测试记录（CHG-2026-026 `evidence/runs/TASK-RKFUI-001/hermetic-contract-test-2026-07-22.md`，blob `659f99f470cea5f03984de6ea28ce1395e391287`）
  记录契约测试原先经构建期路径回溯仓库根读取正本，换机器/路径即断；修复形态是
  正本复制进测试 fixture 随 bundle 分发、套件只读 bundle，正本与副本字节一致由
  授权层守卫 fail-closed，并以一字节篡改做反向验证。#305 merge
  `c2342ca363e60bea8d159d6fe8b87e8fca31d8ca`。同族其余套件的同型模式在该记录中
  被**如实注明为限制**，未声称已解决。
- **Fact.** TASK-MECH-001 `run.md`（CHG-2026-028 `evidence/runs/TASK-MECH-001/run.md`，blob `f5e51fad2f2a429748126eee27ab61df282c2f23`）
  记录 readiness 首轮钉定的 runner 镜像被实测推翻，重钉后通过；三轮 attempt 全部
  在案。重钉 PR #333 merge `e51dcd7a529d42d521efb9ec113a57716894a6b9`。
- **Inference.** 已知环境性失败"绿一次"不证明它不存在，"红一次"也必须逐名核对是否
  **恰为**已知集合、多一个即当真实失败查。该纪律为推断，不是被引用记录的直述结论。

### Root cause

测试与工具链对宿主环境的隐式假设没有被写下来，因此也没有被验证；环境噪声与真实
缺陷共用同一个"失败"信号。

### Preflight

1. 列出测试对宿主的每一项假设（路径、目录、锁屏、外部工具、隐藏链接）并逐项消除
   或显式钉定。
2. 外部 runner 镜像的工具链谱系先探针实证再入 pin。
3. 已知环境性失败建立**具名清单**，判定时逐名核对。

### Verification

- **Positive.** 在与开发机不同的路径/工作树下跑通目标套件。
- **Negative.** 篡改一字节 fixture，断言守卫 fail-closed 报红；以及在已知清单之外
  出现任一失败时不得判为环境问题。

### Canonical references

[verification policy — Stop conditions](../verification/policy.md#stop-conditions)、
[`POL-SAFETY-001`](../constitution.md#pol-safety-001-fail-closed-under-uncertainty)。

### Automation status

`partiallyMechanized`。Swift CI 覆盖编译与测试执行，不判断某次失败属环境还是产品。

### Currency

复核基线 `31865366f7bdb8e5ca33f0c8d41c15f6daba7933`，2026-07-23（Asia/Shanghai）；
首批基线 `de6b79aafa95700297a94dc311e94b1283f8abdd` 的记录不追溯改写。

## AF-008 adversarial matrix 缺口与任务跨信任边界过大

### Signal

安全反例在多轮 review 后逐项补齐而非在 design 阶段一次列全；单个任务同时跨越
多个信任边界；fault 注入用 fake 替身而非真实故障点。

### Observed cases

- **Fact.** archived TASK-M1-009 的四份 remediation 记录
  （[初轮](../changes/archive/2026-07-21-chg-2026-002-macos-m1-infrastructure/evidence/runs/TASK-M1-009/review-remediation-2026-07-18.md)、
  [round 2](../changes/archive/2026-07-21-chg-2026-002-macos-m1-infrastructure/evidence/runs/TASK-M1-009/review-remediation-round-2-2026-07-18.md)、
  [round 3](../changes/archive/2026-07-21-chg-2026-002-macos-m1-infrastructure/evidence/runs/TASK-M1-009/review-remediation-round-3-2026-07-18.md)、
  [round 4](../changes/archive/2026-07-21-chg-2026-002-macos-m1-infrastructure/evidence/runs/TASK-M1-009/review-remediation-round-4-2026-07-18.md)）
  逐轮暴露的 adversarial 面包括路径替换、inode/rename、typed write boundary、
  unknown outcome、非常规文件（FIFO）与 writer-lock/identity。这些面**跨轮反复
  出现而非每轮各一**：FIFO 与 non-regular 出现在 round 3，writer-lock/identity 与
  路径替换出现在初轮与 round 4，`unknown` 相关表述出现在初轮至 round 3。
  实现 PR #50 merge `15697e85444fdacab81779a588c0e290c2f47125`。
- **Fact.** [CHG-2026-021 `tasks.md`](../changes/archive/2026-07-23-chg-2026-021-trace-adapter-capture/tasks.md)
  的 TASK-TR-002R 节记录反例注入对**真实** artifact store 的多个故障点逐一进行，
  而非以 fake 替身模拟。
- **Inference.** "反例是逐轮补齐的"说明通用 adversarial matrix 与任务拆分信号没有在
  design 阶段被复用；以及任务跨信任边界过大会放大每轮的返工面。两条均为推断。

### Root cause

adversarial 覆盖被当作 review 的产出而不是 design 的输入；一个任务同时承担多个
信任边界时，任一边界的缺口都要求整体返工。

### Preflight

1. 在 design 阶段列出通用 adversarial matrix：资源替换、并发、崩溃窗口、rename、
   unknown outcome、writer lock 与 identity。
2. 统计该任务跨越的信任边界数量；多于一个时给出拆分理由或拆分方案。
3. 反例注入优先选择真实故障点。

### Verification

- **Positive.** matrix 每一格有对应测试且通过。
- **Negative.** 对真实实现注入故障，断言进入 fail-closed 分支（授权为空、dispatch
  计数为 0），而不是断言一个 fake 返回了预期值。

### Canonical references

[`POL-RECOVERY-001`](../constitution.md#pol-recovery-001-unknown-outcomes-are-never-replayed-blindly)、
[`POL-SAFETY-001`](../constitution.md#pol-safety-001-fail-closed-under-uncertainty)、
[verification policy — Core property invariants](../verification/policy.md#core-property-invariants)。

### Automation status

`semanticReview`。fault 测试按任务编写，无跨任务的通用矩阵门。

### Currency

复核基线 `31865366f7bdb8e5ca33f0c8d41c15f6daba7933`，2026-07-23（Asia/Shanghai）；
首批基线 `de6b79aafa95700297a94dc311e94b1283f8abdd` 的记录不追溯改写。

## AF-009 治理机制与实际信任边界错位

### Signal

机制的强度假设与部署现实不匹配（密钥与被防对象同账户/同 UID）；防"跨 run 历史
改写"的账本每次从空目录重建；规则强制的服务或 workflow 在现实中不存在。

### Observed cases

- **Fact.** [`postmortem-2026-07-governance.md`](postmortem-2026-07-governance.md)
  记录 V1 密码学治理的评审结论：三把私钥与运行 Agent 同机同 UID 可读且存在自动
  签名路径；ledger 在临时 runner 上每次从空目录重建，"跨 run 防历史改写"从未存在；
  被判为 P0 的 identity 碰撞实为维护者自身 relock/re-pin 的正常运维被机制记成历史
  改写；流程强制的受保护服务与 workflow 并不存在。V2 决策与废止清单同在该文件。
  #2 merge `47b310d6ef4e06a3048b74c71420bfe411b53621`。
- **Inference.** 每个把关点都应回答"它拦住了什么 PR review 拦不住的东西"；答不上
  的把关点是净负担。该判据为推断（postmortem 以"教训"形式记录了同向表述）。

### Root cause

机制按理想威胁模型设计，未对照真实部署边界（谁持有密钥、谁能触发 workflow、
账本存活在哪）；因而防护在纸面成立、在现实为空。

### Preflight

1. 写出机制声称阻断的威胁，以及攻击者/失误者在**真实部署**中拥有的能力。
2. 逐条检查：该能力是否足以绕过机制？账本/密钥/服务的实际生命周期是什么？
3. 回答"它拦住了什么 PR review 拦不住的东西"。

### Verification

- **Positive.** 在真实部署形态下演示机制阻断了目标威胁。
- **Negative.** 以被防对象的实际权限尝试绕过；能绕过即机制未成立，不得以"流程上
  不允许"补位。

### Canonical references

[enforcement — 信任模型](../governance/enforcement.md#信任模型)、
[`POL-AGENT-001`](../constitution.md#pol-agent-001-agents-cannot-self-approve-rule-changes)、
[`AGENTS.md` 信任与批准](../../AGENTS.md#信任与批准)。

### Automation status

`semanticReview`。无通用机械门；与 `AF-017` 的分工：本项是**强度错位**（机制在真实
边界上不成立），`AF-017` 是**规模超配**（机制大小超出所解决的问题）。

### Currency

复核基线 `31865366f7bdb8e5ca33f0c8d41c15f6daba7933`，2026-07-23（Asia/Shanghai）；
首批基线 `de6b79aafa95700297a94dc311e94b1283f8abdd` 的记录不追溯改写。

## AF-010 自证式验证：套套逻辑断言与未经变异证伪的测试

### Signal

断言的期望值与被测代码取自同一赋值源或同一常量；测试只有绿证据；计数器或仪表
定义在生产路径从不触发的入口；"通过"被当作"覆盖"。

### Observed cases

- **Fact.** [TASK-M0A-003 `run.md`](../changes/archive/2026-07-21-chg-2026-001-macos-m0a/evidence/runs/TASK-M0A-003/run.md)
  记录一处 tautological counter 的移除：某计数方法返回硬编码 `0`，而自动路径测试
  正是对它断言；处置是删除该方法，测试改为断言 server 状态未变且 lifecycle
  intent/outcome 审计轨迹为空。
- **Fact.** [archived CHG-2026-002 `tasks.md`](../changes/archive/2026-07-21-chg-2026-002-macos-m1-infrastructure/tasks.md)
  记录两处套套逻辑清理，其中一处的问题是把测试回显字面量误写为运行期度量。
- **Fact.** CHG-2026-022 `review.md`（blob `d03118ab83cbeb278910c08e55573094edbd5169`）
  记录"计数落在生产不可达入口"一面（#269 merge
  `3147e33c0d4bf0f9f54e6160850a42f370c05cb6`）。
- **Inference.** 上述记录只说明这些断言/计数曾被移除或判为无效，不支持关于当前
  测试套整体质量的任何结论。

### Root cause

实现与测试同一作者，期望值就近取自实现；缺少一个"这条断言在实现出错时会不会红"
的独立判据。

### Preflight

1. 逐条断言写出期望值的**独立来源**（spec 条款、外部固定向量、另一实现）。
2. 每个计数/仪表定位到唯一真实边界，说明生产路径何时触发它。
3. 断言值若来自被测代码本身，改写或删除该断言。

### Verification

- **Positive.** 正常路径通过。
- **Negative.** **变异实验必须红**——篡改 fixture 一字节、注入一处失败、或改动被测
  常量；红结果与红因入 evidence。只有绿证据的测试不接受该项。

### Canonical references

[verification policy — Verification layers](../verification/policy.md#verification-layers)、
[`POL-VERIFY-001`](../constitution.md#pol-verify-001-evidence-not-task-completion)。

### Automation status

`semanticReview`。CHG-2026-028 把"新 check 须有 canary 红反证"定为其四项机械化的
共同验收门，该门**只覆盖新 check**，产品测试面无通用门。

### Currency

复核基线 `31865366f7bdb8e5ca33f0c8d41c15f6daba7933`，2026-07-23（Asia/Shanghai）；
首批基线 `de6b79aafa95700297a94dc311e94b1283f8abdd` 的记录不追溯改写。

## AF-011 成功判据取错信号：exit code、marker 与管道截断

### Signal

用退出码判定外部工具的语义成功；判定链经管道后再取退出码；只读输出末尾而截断
掉汇总行；工具的真实成功形态从未被登记。

### Observed cases

- **Fact.** [CHG-2026-021 `design.md`](../changes/archive/2026-07-23-chg-2026-021-trace-adapter-capture/design.md)
  登记 artifact completeness 判据，其中空 trace 即使退出码为 0 也不判 succeeded。
- **Fact.** CHG-2026-026 `verification.md`（blob `f4aea707ded798680aacb7811a4786247a94dac8`）
  的 `AC-FLASH-012-01` 要求 exit code、marker 与 postflight 的叉乘覆盖，只有写入、
  reset 与 postflight 全部语义确认才判 succeeded。
- **Fact.** [TASK-RF-002 `run.md`](../changes/archive/2026-07-21-chg-2026-020-dayu200-real-flash/evidence/runs/TASK-RF-002/run.md)
  记录 Provider 的结果评估采用语义 postflight，并明确退出码 0 不等于 succeeded。
- **Inference.** 这些登记面共同指向一条判据：成功语义按该工具**真实观测到的形态**
  判定，而不是按通用约定。该概括为推断。

### Root cause

外部工具的成功语义未按真实观测形态登记；shell 管道的退出码语义被默认为链首命令，
而截断类命令又会吃掉汇总行。

### Preflight

1. 登记该工具真实的成功与失败形态：marker、stderr、产物、退出码各自意味着什么。
2. 判定链不经管道；必要时先落盘后判，或显式取管道各段状态。
3. 判定必须抓取完整汇总行，不能只看截断后的尾部。

### Verification

- **Positive.** 真实成功场景被判为 succeeded，且判据引用的是登记形态。
- **Negative.** 构造"退出码 0 但语义失败"与"非零但语义成功"两向各一例，断言判定
  分别为失败与成功。

### Canonical references

[`POL-RECOVERY-001`](../constitution.md#pol-recovery-001-unknown-outcomes-are-never-replayed-blindly)、
[`POL-SAFETY-001`](../constitution.md#pol-safety-001-fail-closed-under-uncertainty)、
[verification policy — Stop conditions](../verification/policy.md#stop-conditions)。

### Automation status

`partiallyMechanized`。按任务的 contract matrix 覆盖具体工具，无跨任务通用门。

### Currency

复核基线 `31865366f7bdb8e5ca33f0c8d41c15f6daba7933`，2026-07-23（Asia/Shanghai）；
首批基线 `de6b79aafa95700297a94dc311e94b1283f8abdd` 的记录不追溯改写。

## AF-012 交付给人类执行的一次性产物未在 host 侧自测（烧设备窗口）

### Signal

crib/runbook 含未在本机跑通的语法、未验证的外部工具参数签名、占位符、交互式
子进程或 heredoc；窗口计划里没有"脚本本身失败"的重试预算。

### Observed cases

- **Fact.** [CHG-2026-016 rehearsal attempt 4 记录](../changes/archive/2026-07-21-chg-2026-016-dayu200-recovery-rehearsal/evidence/runs/TASK-RH-001/rehearsal-attempt-4-2026-07-21.md)
  记录该次 blocked attempt 的根因：以 heredoc 提供 Python 脚本源时占用了
  `python3 -` 的 stdin，管道中的数据被丢弃，脚本读到空输入。事实范围限于该 attempt
  自身；同目录另有 attempt 2/3/5 的独立记录。
- **Fact.** CHG-2026-008 的 harness echo remediation 已完成，PR #229 merge
  `3ac44f2d759bd8bec8f95405b85281d70f89cad0`。
- **Inference.** 设备窗口是稀缺且不可重试的资源，脚本 bug 与设备事实的失败成本
  不应被等同看待。该权衡为推断。

### Root cause

把"脚本逻辑正确"当成"在操作者的 shell 里可执行"。交付物的失败面（shell 方言、
stdin 占用、参数签名、粘贴行为、缓冲）从未在 host 侧被实际触碰。

### Preflight

1. 交付前跑通**全部可 host 侧测项**：语法、外部工具参数签名、比对逻辑、退出码、
   脱敏与权限掩码。
2. 零占位符——需要现场取值的用命令替换自动获取或直接给脚本。
3. 数据经由参数或文件传入，不占用 stdin。
4. 交互式子进程通过伪终端录制，避免全缓冲吞掉提示。
5. 流内容不回显终端，只显示字节数与摘要，使转录可安全贴回。

### Verification

- **Positive.** host 自测全绿并记录命令与结果。
- **Negative.** 故意传入错误参数或错误摘要，断言脚本**自身**拒绝执行并给出具名
  退出码，而不是继续跑到设备操作。

### Canonical references

[`AGENTS.md` Agent 禁令](../../AGENTS.md#agent-禁令)、
[enforcement — 真实硬件与 destructive 操作](../governance/enforcement.md#真实硬件与-destructive-操作)、
[`POL-AGENT-002`](../constitution.md#pol-agent-002-autonomous-agents-never-execute-real-destructive-hardware-workflows)。

### Automation status

`semanticReview`。host 自测靠约定，无机械门；blocked attempt 不升级为 passing
evidence 这一点由 evidence class 规则承担。

### Currency

复核基线 `31865366f7bdb8e5ca33f0c8d41c15f6daba7933`，2026-07-23（Asia/Shanghai）；
首批基线 `de6b79aafa95700297a94dc311e94b1283f8abdd` 的记录不追溯改写。

## AF-013 形态照搬：复用既有 harness/设计而未回读目标 capability 的全部 REQ

### Signal

"与 X 同型，照 X 做"；design/readiness 出现"复用既有面"而没有逐条 REQ 对照表；
被复用形态的隐含假设（只读面、固定路径）未在新语境下重新检验。

### Observed cases

- **Fact.** [TASK-TR-001 `run.md`](../changes/archive/2026-07-23-chg-2026-021-trace-adapter-capture/evidence/runs/TASK-TR-001/run.md)
  记录该采集 harness 经 hardening 修正：原形态照搬既有只读探测 harness 的
  "探测 + 固定 owned 面 + 精确清理"结构，未覆盖目标 capability 自身的 Job-UUID
  隔离与"接收校验通过后才清理"两项规范条款。hardening PR #274 merge
  `628653c69afdf5f1b3c69e0b9eda03ba111fa5bc`。
- **Fact.** CHG-2026-022 `review.md`（blob `d03118ab83cbeb278910c08e55573094edbd5169`）
  记录 design 的"复用既有 discovery 面"假设实际需要一个独立登记的观察面。
- **Inference.** 本手册不推断其他 harness 是否存在同类漏项；任何此类断言需要逐个
  核查后另行标注。

### Root cause

相似性判断建立在**既有实现形态**上，而不是**目标 spec 条款**上。被复用形态对
"只读面""固定路径"的假设在新 capability 下不再成立，但假设本身从未被写出来。

### Preflight

1. 列出目标 capability 的全部 REQ 与强制条款，逐条标注被复用形态覆盖/未覆盖。
2. 写出被复用形态的隐含假设，逐条检验在新语境下是否仍成立。
3. "复用既有面"的假设验证到"该面是否被**治理登记**"级，而不是"代码里有"。

### Verification

- **Positive.** 逐条 REQ 对照表全部标注为覆盖，且每格有对应实现或测试。
- **Negative.** 对每条标为未覆盖的条款，写出它在当前设计下会**如何**被违反；
  写不出即说明对照未做实。

### Canonical references

[`POL-SPEC-001`](../constitution.md#pol-spec-001-specification-is-the-source-of-truth)、
[`AGENTS.md` 权威顺序](../../AGENTS.md#权威顺序)、
[verification policy — Definition of Ready](../verification/policy.md#definition-of-ready)。

### Automation status

`semanticReview`。无机械门。

### Currency

复核基线 `31865366f7bdb8e5ca33f0c8d41c15f6daba7933`，2026-07-23（Asia/Shanghai）；
首批基线 `de6b79aafa95700297a94dc311e94b1283f8abdd` 的记录不追溯改写。

## AF-014 门只校验凭据存在/形状，不校验语义绑定（fail-closed 弱化）

### Signal

以"类型封死构造器/typed gate 存在"论证"绕过不可能"；没有验证 reliable-total
receipt/capability 值是否只能由当前 adapter capability factory 的唯一 minting point
产生；cleanup 或 dispatch 无条件执行；门校验"有没有凭据"而不校验"凭据指向的是
不是这个目标"。

### Observed cases

- **Fact.** [CHG-2026-021 `tasks.md`](../changes/archive/2026-07-23-chg-2026-021-trace-adapter-capture/tasks.md)
  的 TASK-TR-002R 二值门与
  [同任务 `run.md`](../changes/archive/2026-07-23-chg-2026-021-trace-adapter-capture/evidence/runs/TASK-TR-002R/run.md)
  记录四条 fail-closed 弱化：重绑定须绑定 expected target 与 exact
  `revision + 1`；只有 matching `PublishedArtifact` 可产生 remote-cleanup authority；
  catalog membership alone 不构成 per-device capability；reliable-total receipt
  只能由当前 adapter `capability=true` factory 产生，reliable totals 无 public
  initializer，false/missing/invalid/drifted capability 保持 indeterminate。
  scoping PR #276 merge `6e85a784579809b0b79a95bb117d48033892fdf4`；以真实
  fault injection 堵住的修复 PR #278 merge
  `4bdad2f037cd62c76dbc483f0cfb4a35ae3af539`。
- **Fact.** 同一记录显示这四条是在实现 PR 合入**之后**由对抗审查发现的，前一轮
  review 的历史结论未被改写。
- **Inference.** review 追问停在"门是否可被绕过"是不够的，还需要追问"门放行时校验
  的凭据语义是否正确"。该分层为推断。

### Root cause

类型封死防的是"跳过接受步骤/绕过门"，不防"门放行的授权凭据语义是否正确"。
后者是更深一层的 fail-closed 类别，需要单独提问才会暴露。

### Preflight

对每个 gate 写出：

1. 凭据由谁产生；
2. 绑定到哪个具体目标与哪个 revision；
3. capability/receipt 的唯一 minting point 是否绑定当前 adapter，调用方能否绕开
   factory 自行构造；
4. cleanup/dispatch 是否需要真实回执，还是无条件执行。

### Verification

- **Positive.** 语义正确的凭据放行一次真实路径。
- **Negative.** 用**真实**（非 fake）故障注入覆盖三向：凭据绑定到错误目标、缺少
  发布回执、missing/false/drifted/invalid capability 或绕开 factory 的 reliable-total
  构造尝试；逐向断言进度保持 indeterminate、授权为空且 dispatch 计数为 0。

### Canonical references

[`POL-SAFETY-001`](../constitution.md#pol-safety-001-fail-closed-under-uncertainty)、
[`POL-TARGET-001`](../constitution.md#pol-target-001-identity-before-convenience)、
[`POL-WORKFLOW-001`](../constitution.md#pol-workflow-001-typed-and-auditable-side-effects)。

### Automation status

`semanticReview`。无机械门。与 `AF-003` 的分工：`AF-003` 是**谁生产事实**，本项是
**门自身校验强度**；同一 gate 可两者兼有。

### Currency

复核基线 `31865366f7bdb8e5ca33f0c8d41c15f6daba7933`，2026-07-23（Asia/Shanghai）；
首批基线 `de6b79aafa95700297a94dc311e94b1283f8abdd` 的记录不追溯改写。

## AF-015 缺陷类只在发现点修复，未全仓扫描同模式

### Signal

review 指出一处缺陷，修复 diff 只触及该处，没有同模式搜索记录；同类问题在后续
轮次再次出现。

### Observed cases

- **Fact.** archived TASK-M1-009 的四份 remediation 记录（链接见 `AF-008`）显示
  同类问题在多轮中依次再现；此处取"逐轮再现"一面。实现 PR #50 merge
  `15697e85444fdacab81779a588c0e290c2f47125`。
- **Fact.** TASK-RKFUI-001 hermetic 契约测试记录（CHG-2026-026 `evidence/runs/TASK-RKFUI-001/hermetic-contract-test-2026-07-22.md`，blob `659f99f470cea5f03984de6ea28ce1395e391287`）
  记录构建期路径模式的**部分**收口（PR #305 merge
  `c2342ca363e60bea8d159d6fe8b87e8fca31d8ca`），其余同族套件因其 fixture/registry
  摘要被多处钉定、收口成本高而**如实记录为限制**，未声称已解决。
- **Inference.** 把 review finding 当作单点缺陷而非模式实例，是"修 A 处 B 处复发"的
  直接原因。该因果为推断。

### Root cause

finding 的处置边界默认取"被指出的那一处"，而缺陷类的实际分布从未被测量。

### Preflight

1. 每个 finding 先在全仓搜索同模式，列出全部命中。
2. 每个命中三选一：修复 / 记录为限制并说明成本 / 另立 change；不得沉默略过。
3. "有意留下"与"漏掉"在记录中必须可区分。

### Verification

- **Positive.** 修复后同模式搜索结果为空，或剩余命中全部有具名记录。
- **Negative.** 对声称已收口的模式再做一次独立搜索；出现未记录的命中即视为收口
  不成立。

### Canonical references

[`AGENTS.md` 执行规则](../../AGENTS.md#执行规则)、
[verification policy — Definition of Done](../verification/policy.md#definition-of-done)。

### Automation status

`semanticReview`。全仓搜索靠约定，无机械门。

### Currency

复核基线 `31865366f7bdb8e5ca33f0c8d41c15f6daba7933`，2026-07-23（Asia/Shanghai）；
首批基线 `de6b79aafa95700297a94dc311e94b1283f8abdd` 的记录不追溯改写。

## AF-016 以会话记忆/摘要代替一手核查

### Signal

pin、状态、待办或结论的来源是"上次/我记得/摘要里写了"；引用他处摘要而未复核仓内
bytes；对外部环境（runner 镜像、工具链版本、外部工具能力）凭印象下钉。

### Observed cases

- **Fact.** TASK-MECH-001 `run.md`（CHG-2026-028 `evidence/runs/TASK-MECH-001/run.md`，blob `f5e51fad2f2a429748126eee27ab61df282c2f23`）
  记录 readiness 首轮钉定的 CI runner 镜像假设未经探针实证即入 pin，随后被一手 CI
  run 证伪，readiness 重钉后通过；三轮 attempt 全部在案。重钉 PR #333 merge
  `e51dcd7a529d42d521efb9ec113a57716894a6b9`。
- **Fact.** CHG-2026-022 `review.md`（blob `d03118ab83cbeb278910c08e55573094edbd5169`）
  的第四条 finding 记录 r1 readiness 把缩写的文件摘要值当作 blob pin 写入，并要求
  未来 readiness 以完整值钉定其实际 base。
- **Inference.** 长会话与跨会话摘要天然滞后于 protected `main`，因此摘要不能充当
  事实源；唯一事实源是仓内 bytes 与一手 evidence。该结论为推断，其规范依据见下方
  canonical references。

### Root cause

摘要读起来与事实同形，但它没有绑定到任何 commit；一旦被当作输入，后续所有推导
都继承了它的滞后与失真。

### Preflight

1. 任何 pin、状态或待办在写入前对 repo 复核，取值来自实测而非转抄。
2. 外部环境先探针实证再钉。
3. 引用他处结论时给出可解析的相对路径与完整 40-hex OID，而不是转述。

### Verification

- **Positive.** 对全部 pin 独立重取并逐项比对，比对方法与结果入 evidence。
- **Negative.** 出现任一不一致时判 `blocked` 并重新 readiness，而不是就地把 pin
  改成新值了事。

### Canonical references

[`AGENTS.md` 权威顺序](../../AGENTS.md#权威顺序)、
[verification policy — Definition of Ready](../verification/policy.md#definition-of-ready)、
[verification policy — Stop conditions](../verification/policy.md#stop-conditions)。

### Automation status

`partiallyMechanized`。CHG-2026-028 覆盖三方 revision 同步与 pin 的**形状**
（完整 40/64 hex），不覆盖"该值是否来自一手核查"。

### Currency

复核基线 `31865366f7bdb8e5ca33f0c8d41c15f6daba7933`，2026-07-23（Asia/Shanghai）；
首批基线 `de6b79aafa95700297a94dc311e94b1283f8abdd` 的记录不追溯改写。

## AF-017 收敛失败：修复轮次引入新架构与过度设计

### Signal

每轮 review 修复都带来新抽象或新机制；轮次不收敛；提案的机制规模明显超出它所
解决的问题；失败的机制被提议重建为更重的版本。

### Observed cases

- **Fact.** CHG-2026-008 `tasks.md`（blob `abaee6a12290108f4daeac9f84a3ff6700971433`）
  与 [`backlog.md`](backlog.md) 记录：某轮 revision 初稿提出的授权架构被裁剪为既有
  模型的门，该架构候选降级进入 backlog。裁剪版 PR #131 merge
  `d99ba58042b9cad64de39d6f4baa5994b2c351b2`。初稿 PR #128 **未合并**（closed
  draft，其 head 保留于提交历史）。
- **Fact.** [`postmortem-2026-07-governance.md`](postmortem-2026-07-governance.md)
  记录 V1 约 12,900 行 guard 脚本自身成为唯一事故源、0 行产品代码受影响，且恢复
  方向一度是把失败机制重建为更重的版本（外部串行签名服务、WORM、HSM 边界）。
  此处取"规模超配"一面。
- **Inference.** 收尾阶段继续扩大变更面会让每轮修复引入新的可失败点，从而使轮次
  不收敛。该因果为推断。

### Root cause

用新机制回答缺陷，而不是用最小修复。新机制自身成为新的变更面与事故面，于是下一
轮 review 又发现新问题。

### Preflight

1. 收尾阶段显式声明**机制冻结**：只修不加。
2. 任何新机制先回答"它拦住了什么 PR review 拦不住的东西"；答不上即不立项。
3. 先让流程能走通一个真实任务，再谈加固。

### Verification

- **Positive.** 收尾轮次的修复 diff 中新增抽象数为 0，且轮次收敛。
- **Negative.** 若某轮修复引入了新机制，检查它的 rollback 是否为单次 revert；
  不是即说明变更面已超出该轮应有范围。

### Canonical references

[enforcement — 信任模型](../governance/enforcement.md#信任模型)、
[enforcement — 决策分级(D0/D1/D2)](../governance/enforcement.md#决策分级d0d1d2)、
[`POL-SPEC-001`](../constitution.md#pol-spec-001-specification-is-the-source-of-truth)。

### Automation status

`semanticReview`。无机械门。与 `AF-009` 的分工：`AF-009` 是**强度错位**，本项是
**规模超配**。

### Currency

复核基线 `31865366f7bdb8e5ca33f0c8d41c15f6daba7933`，2026-07-23（Asia/Shanghai）；
首批基线 `de6b79aafa95700297a94dc311e94b1283f8abdd` 的记录不追溯改写。

## AF-018 多会话共享状态与轻信他方声明

### Signal

多个会话共用同一工作副本；引用另一会话的"已修复/已通过"作为结论；并行任务没有
文件级分工；提 PR 时对方仍在实时编辑；两个 lane 同时改动同一 change。

### Observed cases

- **Fact.** [CHG-2026-021 `tasks.md`](../changes/archive/2026-07-23-chg-2026-021-trace-adapter-capture/tasks.md)
  记录并行推进时以**文件级分工**作为前置条件写入两侧 readiness，以保证改动面零
  交集。
- **Fact（dated observation，2026-07-23）.** 本任务的 readiness r1（PR #356 merge
  `e73b025dab3c12162465040bd0829470b2409ae9`）与 CHG-2026-029 的 revision r2
  （PR #355 merge `de6b79aafa95700297a94dc311e94b1283f8abdd`）由两个 lane 并行推进：
  r1 的 pins carrier 钉定了本 change 四个文件的 blob，而 r2 恰好改动这四个文件，
  四枚 pin 全部漂移，readiness 因此按其自身条款重钉为 r2。**此为本 change 自身的
  过程事实，不构成产品缺陷，也不是任何一方的过失。**
- **Inference.** git 工作副本、分支 HEAD 与 PR 状态都是共享可变状态，因此他方声明
  在本地复验前不构成事实。该结论为推断（与 `AF-016` 同源，触发点不同）。

### Root cause

并行的收益被默认，代价（共享可变状态、pin 相互失效、重复劳动）没有在开工前被
标价。

### Preflight

1. commit 前确认当前分支；并行实现真正使用独立工作树。
2. 并行任务在 readiness 显式写出文件级分工，确认改动面零交集。
3. 他方"已通过"一律以本地重跑为准。
4. 一个 change 同时被多个 lane 推进时，先确认谁的 pin 会被谁的改动打掉。

### Verification

- **Positive.** 本地独立复跑编译与测试通过。
- **Negative.** 机械核对两侧 diff 文件集交集为空；交集非空即说明分工未成立，
  应先收敛再继续。

### Canonical references

[enforcement — 批准语义](../governance/enforcement.md#批准语义)、
[enforcement — 批次审批协议](../governance/enforcement.md#批次审批协议)、
[`AGENTS.md` 执行规则](../../AGENTS.md#执行规则)。

### Automation status

`partiallyMechanized`。CHG-2026-028 的 PR allowed-paths diff 是近似防线，它关闭的是
无意混装，不防并发写同一文件。

### Currency

复核基线 `31865366f7bdb8e5ca33f0c8d41c15f6daba7933`，2026-07-23（Asia/Shanghai）；
首批基线 `de6b79aafa95700297a94dc311e94b1283f8abdd` 的记录不追溯改写。
