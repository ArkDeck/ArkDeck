# Tasks — CHG-2026-055

十三个垂直产品任务(`PRODUCT-LOOP.md` §4:一个问题、一个垂直任务、一个产品 PR)。
全部映射 **GJ-5 Bounded AI Debug Loop**。

共同规矩:

- 每个任务 = 一个实现 PR,同车交付根因说明、产品代码、测试、必要真机结论与最小文档,
  并在同一 PR 内把本任务翻 `done`、把对应 AC 结论写入 `verification.md`;
- **不建** readiness-only / status-only / verified-only / archive-only PR;
- `- Gate:` 是开工门的如实登记,由实现 PR 记录门已满足(或记录维护者的显式解冻依据);
  门不通过 status-only PR 维护,任务保持 `ready`;
- 真机结论只能来自真实运行;fake/simulation 不得顶替,缺设备窗口时如实记
  `pending-hardware` 且不得据此宣布 `REAL_DEVICE_PASS`;
- 顺序见 `proposal.md`「交付顺序与门」:**002 必须先于 003**(无人值守 E1 mutation 的前置闸),
  Wave C(012/013)必须等 Wave A 全部 done 且 GJ-5 `REAL_DEVICE_PASS`。

---

# Wave A — 关闭 GJ-5 真机环

## TASK-HFA-001 — 崩溃判定源改为崩溃台账:criteria 与 observation 消费 faultlog 产物

- Status:done
- Done:2026-07-31;随本实现 PR 合入生效(维护者 review + merge 即批准)。
  HFA-AC-1、HFA-AC-2 均 PASS,evidence = `evidence/runs/TASK-HFA-001/run-r1.md`
  (库层 959 tests/1 skip/0 fail,新增 9 例;check_sdd 0/0/114;catalog_gen 39/39 +
  零 drift,本任务未改 Catalog)。**Gate 已满足**:下方 Gate 行写的「#890 未合」
  在本日失效——#890 已合入 `main@4eb14e2d`。
  **如实登记未覆盖**:①cppcrash 与 appfreeze 两类条目正文仍无真机字节(设备当前只有
  一条 jscrash;再取需真造 native abort 或冻屏,属设备状态改变,现场为 CHG-2026-054
  窗口所留未动),故这两类 fixture 按文档形态手写并逐条标注来源;②真机端到端复验属
  TASK-HFA-005;③DC-2 活性仍只断言「设备在产出日志」,要断言「应用活着」需 capture
  带 `hilogFilters` 指名 bundle,属输入面变更不在本任务范围。
  **scope 未点名但必须实现的语义**:台账是设备级累积状态,`matchingCrashCount` 又是
  counter 指标,直接计数会让历史条目每轮重复计入、判据永不可达。故实现了水位线增量
  (首轮只立水位、不产计数不产样本;之后只计时间戳大于水位者),用设备时间戳对设备
  时间戳比较——条目名里的时间戳是设备本地时,与宿主 UTC 差一个未知时区偏移。
  副作用:DC-1 的 5 个样本现在需 6 次采集,连同 observe 共 7 轮,仍在默认
  `maxRounds: 8` 内。
- Platform:macos
- Requirements/AC:proposal What 1(判定源);change-local HFA-AC-1、HFA-AC-2,
  登记于 `verification.md`
- Gate:**TASK-DHA-005(CHG-2026-049)的采集腿合入 `main`**——当前在 PR #890,未合;
  `main@fa8a8704` 的 `capture.diagnostics@1` 里 `crashLog|faultlog` 命中数为 0,
  合入前本任务保持 `ready`,不得自建第二条采集腿
- Depends on:TASK-DHA-005(外部 change,采集腿);CHG-2026-054 TASK-HTP-002(evaluator,done)
- Hardware required:no(用 DHA-005 真机窗口产出的 faultlog 字节样本 + fake 供给;
  真机复验在 TASK-HFA-005)
- Scope:`DebugCrashTaskHandler` 的三条默认 criteria 把崩溃判定的
  `evidenceRequirements` 从 `hilog.txt` 改为崩溃台账产物(索引 + 条目正文),
  `hilog.txt` 保留为 liveness 与辅助证据;handler 的 capture 步骤请求崩溃腿的
  typed inputs;`HarnessObservationBuilder` 从 fault log 条目提取 crash signature、
  reason、进程/包名与时间戳,并与 goal 的 `crashSignature` 做匹配计数。
  **三条 fail-closed 负例必须有独立用例**:①声明的崩溃证据缺席/`missing`/`truncated`
  → `INCONCLUSIVE`,永不 PASS;②台账为空且工具正常返回 → 才可作为"无匹配崩溃"的正证据
  (空列表与"没采到"必须可区分);③条目存在但不可解析 → `ERROR` + `evidenceIntegrity`
  人工阻塞。r6/r7 那条"真实 crash 判成 PASS"的路径必须由回归用例钉死
- Allowed paths:
  - `Packages/ArkDeckKit/**`
  - `openspec/changes/chg-2026-055-harness-final-architecture/**`
  - `docs/adr/**`
- Forbidden paths:
  - `openspec/constitution.md`、`openspec/specs/**`、`openspec/verification/**`、
    `openspec/baselines/**`、`openspec/contracts/**`
  - `Catalog/**`、`scripts/**`、`.github/**`、`AGENTS.md`、`PRODUCT-LOOP.md`、
    `ArkDeck.xcodeproj/**`、`ArkDeckApp/**`
  - 其他 change 目录
- Risk:high(判定权的证据源变更。判错方向只有一个是危险的:把"没看见崩溃"当成"没有崩溃"。
  故三条 fail-closed 路径各有独立负例,且保留 r6 的真实字节做回归)

## TASK-HFA-002 — Stale Decision Guard:state version、context digest、revision 前置与 ModelRun

- Status:done
- Done:2026-07-31;随本实现 PR 合入生效(维护者 review + merge 即批准)。
  HFA-AC-3、HFA-AC-4、HFA-AC-5 全部 PASS,evidence =
  `evidence/runs/TASK-HFA-002/run-r1.md`(库层 950 tests/1 skip/0 fail,新增 10 例;
  变异对照实测:去掉 guard 后同一竞态里 job **照样被派发**)。
  两处如实登记的偏离:①decision 上的字段名为 `basisDigest`(§11.4 的 contextHash 位),
  模型实收字节的 digest 单独记在 `HarnessModelRun.contextDigest`(§12.9);②ModelRun 记
  **实测字节数**而非 token —— 决策端口返回 `Data`,token 是端口看不见的厂商概念,
  待 TASK-HFA-011 接真实 adapter 时再补 usage。
  workspace/build/deploy 前置的**消费者**在 TASK-HFA-003/009,本任务不写空校验占位。
- Platform:macos
- Requirements/AC:proposal What 2(防陈旧闸);change-local HFA-AC-3、HFA-AC-4、HFA-AC-5,
  登记于 `verification.md`
- Gate:无外部门。**本任务是 TASK-HFA-003 的硬前置**(终版 §25.1:防陈旧闸齐备前
  不开放无人值守 E1 mutation),不得与 003 并行开工
- Depends on:CHG-2026-054 TASK-HTP-001/003/004(done)
- Hardware required:no
- Scope:task 暴露 `currentStateVersion`(复用既有 projection 乐观锁版本,不新建第二个计数器);
  decision 携带 `observedStateVersion` 与 `contextDigest`;接受 decision 在**同一事务内**
  原子校验 §11.4 清单中当前可判定的项(htaskId、stateVersion、contextDigest、
  无 active effectful job、expectedBindingRevision);workspace/build/deploy 相关前置留出
  字段并在 003/009 落地后生效(本任务写好校验点与负例骨架,不留 TODO 式空校验)。
  **stale 的代价语义与失败区分**:stale 不执行、不计策略失败、不增 no-progress、
  不写 failure fingerprint,但已发生的 model call 仍计入预算,并重新组装 context 产生新
  digest。`ContextAssembler` 输出 `contextDigest` + selection manifest(选了什么、
  为什么选、裁掉了什么),digest 在**脱敏之后**计算;`ModelRun` 记录 provider、modelName、
  modelRevision、adapterVersion、htaskId、round、observedStateVersion、contextDigest、
  起止时间、input/output tokens、schema 校验结果、decisionId。人工 resolution 必须递增
  state version,使一切旧 decision 立即 stale
- Allowed paths:
  - `Packages/ArkDeckKit/**`
  - `openspec/changes/chg-2026-055-harness-final-architecture/**`
  - `docs/adr/**`
- Forbidden paths:
  - `openspec/constitution.md`、`openspec/specs/**`、`openspec/verification/**`、
    `openspec/baselines/**`、`openspec/contracts/**`
  - `Catalog/**`、`scripts/**`、`.github/**`、`AGENTS.md`、`PRODUCT-LOOP.md`、
    `ArkDeck.xcodeproj/**`、`ArkDeckApp/**`
  - 其他 change 目录
- Risk:high(这是无人值守写源码/部署的安全闸。校验漏一项 = 旧决策作用于新事实。
  故每条前置各有一个"变化后旧 decision 被拒"的竞态用例,并有写入前/写入后两窗口崩溃矩阵)

## TASK-HFA-003 — 修复腿接线:PROPOSE_PATCH、patch → build → deploy → verify 与失败回滚

- Status:ready
- Platform:macos
- Requirements/AC:proposal What 3(修复腿);change-local HFA-AC-6、HFA-AC-7、HFA-AC-8,
  登记于 `verification.md`
- Gate:**TASK-HFA-002 已 done**(硬前置,不接受提前解冻:终版 §25.1)。
  E1 段在真机上的执行仍需维护者经 merged PR 签发的 standing capability
- Depends on:TASK-HFA-002;CHG-2026-054 TASK-HTP-005(五个 workspace operation,done)
- Hardware required:no(host 面可全程构造:workspace fixture + fake 设备腿;
  真机收敛在 TASK-HFA-005)
- Scope:新增 `PROPOSE_PATCH` decision kind 与严格 schema(baseWorkspaceRevision、
  patchSha256、有界 unified diff、touchedFiles、expectedChangedSymbols),越界即整条拒绝
  (`maxPatchBytes`、文件数、ProjectProfile 可写 glob、二进制、符号链接、路径逃逸);
  `DebugCrashTaskHandler` 扩 `permittedOperations` 到 `workspace.applyPatch@1` /
  `buildOpenHarmony@1` / `runTests@1` / `revertPatch@1` 与既有部署腿,并把
  `HarnessTaskHandler.swift:151-167`(verdict fail → 交人)、`:207-221`
  (patching/building/deploying → noSafeAction)替换为真实推进;三条 stage gate 按
  design §4 做**结构性相等判定**(applied-patch readback revision == patchRevision;
  build source revision == 当前 patch revision;部署 readback digest == build output digest);
  失败分类补 `BUILD_SEMANTIC_FAILURE`/`TEST_FAILURE`/`WORKSPACE_REVISION_CONFLICT` 三类
  (`ALTERNATIVE_REQUIRED`,不原样重试);部署或复验失败 → `workspace.revertPatch@1`,
  回滚也消耗 `maxE1Mutations`;apply 结果未知只允许 readback 四态判定,**禁止重复 apply**
- Allowed paths:
  - `Packages/ArkDeckKit/**`
  - `openspec/changes/chg-2026-055-harness-final-architecture/**`
  - `docs/adr/**`
- Forbidden paths:
  - `openspec/constitution.md`、`openspec/specs/**`、`openspec/verification/**`、
    `openspec/baselines/**`、`openspec/contracts/**`
  - `Catalog/**`、`scripts/**`、`.github/**`、`AGENTS.md`、`PRODUCT-LOOP.md`、
    `ArkDeck.xcodeproj/**`、`ArkDeckApp/**`
  - 其他 change 目录
- Risk:high(首次让无人值守回路写源码并部署。三条 gate 的相等判定、未知结果不重放、
  失败必回滚各有独立负例;E1 预算与既有 capability 边界不放宽)

## TASK-HFA-004 — Attempt 模型、strategy fingerprint 与重复策略拒绝

- Status:ready
- Platform:macos
- Requirements/AC:proposal What 4(Attempt);change-local HFA-AC-9、HFA-AC-10,
  登记于 `verification.md`
- Gate:TASK-HFA-003 已 done(有了 patch/build 维度,strategy fingerprint 的七要素才不是空壳)
- Depends on:TASK-HFA-003
- Hardware required:no
- Scope:Attempt 实体(attemptId、ordinal、hypothesis、strategyFingerprint、baseRevision、
  patchRevision、outcome、failureFingerprint、actionRunIds、evaluationIds、confirmedFacts、
  disprovedFacts)与其持久化/事件;`strategyFingerprint` = 终版 §10.1 七要素的 canonical
  JSON SHA-256,**hypothesis 自由文本不参与**;Action Retry 与 Strategy Attempt 按 design §5
  的三条路径判定(含"崩溃重放用原 idempotencyKey、确认重试用新 ActionRun/新 key");
  `DUPLICATE_STRATEGY` 拒绝(同 patch digest + 同 base revision + 同 build preset +
  同 failure fingerprint 不得成为新 Attempt);progress 向量按终版 §15.4 收紧
  ——只重新分析/总结/规划、相同 decision fingerprint、workspace 最终回到同一 revision
  一律不算进展;补 `maxNoProgressRounds`、`maxActionRetriesPerRun` 预算字段与耗尽后的
  安全停止;新增 `task.attempts` daemon 方法与 CLI
- Allowed paths:
  - `Packages/ArkDeckKit/**`
  - `openspec/changes/chg-2026-055-harness-final-architecture/**`
  - `docs/adr/**`
- Forbidden paths:
  - `openspec/constitution.md`、`openspec/specs/**`、`openspec/verification/**`、
    `openspec/baselines/**`、`openspec/contracts/**`
  - `Catalog/**`、`scripts/**`、`.github/**`、`AGENTS.md`、`PRODUCT-LOOP.md`、
    `ArkDeck.xcodeproj/**`、`ArkDeckApp/**`
  - 其他 change 目录
- Risk:medium(新增持久化实体 + 停机判据收紧。风险是误判"无进展"提前停机,
  故进展/无进展两侧各有正负例,并有写入前/写入后崩溃矩阵)

## TASK-HFA-005 — GJ-5 真机端到端 r2:含修复腿的一次 submit 自动收敛

- Status:ready
- Platform:macos
- Requirements/AC:proposal Wave A 全部交付面的真机复验;change-local HFA-AC-11、HFA-AC-12,
  登记于 `verification.md`
- Gate:TASK-HFA-001..004 全部 done;已接管设备 + 当前 catalog digest;
  **E1 段需维护者经 merged PR 已签发的 standing capability(Agent 不得自签)**
- Depends on:TASK-HFA-001、TASK-HFA-002、TASK-HFA-003、TASK-HFA-004
- Hardware required:yes
- Scope:在已接管 DAYU200 上一次 `task submit` 驱动 `DEBUG_CRASH` 完成
  运行 → 采集 → 崩溃台账判定 → patch → build → 部署 → 复验,直到 evaluator `PASS`
  或安全停止;**必须同时取得两条证据**:①注入真实崩溃后 verdict 不是 `pass`
  (关闭 r6 的假阳性);②修复后复验 `PASS`(关闭"部署修复腿未覆盖")。
  记录人工步骤计数(E0 与已授权 E1 目标为 0)、每轮 decision/attempt/job/artifact 链、
  预算消耗与停止原因;窗口内暴露的产品缺陷在同一 PR 内修复(不新开治理载体);
  据结果如实翻转 GJ-5 状态(仅当前 digest 上的真实运行可写 `REAL_DEVICE_PASS`);
  窗口结束前清理设备侧残留(应用与 staging),清理凭据不足时如实登记
- Allowed paths:
  - `Packages/ArkDeckKit/**`
  - `Catalog/**`
  - `openspec/changes/chg-2026-055-harness-final-architecture/**`
  - `docs/adr/**`
- Forbidden paths:
  - `openspec/constitution.md`、`openspec/specs/**`、`openspec/verification/**`、
    `openspec/baselines/**`、`openspec/contracts/**`
  - `scripts/**`、`.github/**`、`AGENTS.md`、`PRODUCT-LOOP.md`、
    `ArkDeck.xcodeproj/**`、`ArkDeckApp/**`
  - 其他 change 目录
- Risk:high(首次无人值守含源码写入与部署的多轮真机执行。停止条件、outcomeUnknown、
  预算面必须在此之前全部有测试覆盖,窗口内保留人工中断能力)

---

# Wave B — 终版架构面补齐

## TASK-HFA-006 — 三维状态:Lifecycle / Stage / Conditions 与既有任务前向迁移

- Status:ready
- Platform:macos
- Requirements/AC:proposal What 6(三维状态);change-local HFA-AC-13、HFA-AC-14,
  登记于 `verification.md`
- Gate:GJ-5 `REAL_DEVICE_PASS`(TASK-HFA-005 done)或维护者显式提前解冻并在实现 PR 写明依据
- Depends on:TASK-HFA-005(状态轴重构不应打断正在收敛的真机线)
- Hardware required:no(迁移用例以 CHG-2026-054 窗口留下的持久化任务目录为输入)
- Scope:lifecycle 引入 `waiting` + `waitReason`(`USER_SUSPENDED`/`ACTIVE_JOB`/
  `RETRY_BACKOFF`/`DEVICE_UNAVAILABLE`/`OBSERVATION_WINDOW`),`paused` 语义并入
  `waiting + USER_SUSPENDED`;`deviceReady` 从 phase 降为 Condition;Condition 集合
  (TargetResolved、DeviceBound、DeviceReady、WorkspaceReady、ReproductionConfirmed、
  ArtifactsReady、AnalysisReady、PatchProposalReady、PatchApplied、BuildPassed、
  BuildOutputsReady、DeploymentObserved、VerificationEvidenceReady、CriteriaSatisfied)
  带 `TriState`/reasonCode/message/evidenceArtifactIds/observedAt/observedRevision;
  stage gate 表驱动(终版 §8.6)且逐格负例;binding revision 变化规则(§8.5)——
  **瞬时 Condition 变 FALSE/UNKNOWN 不修改 stage**;既有持久化任务按 design §6 前向迁移,
  断言迁移后 `task.events` 时间线逐字保持
- Allowed paths:
  - `Packages/ArkDeckKit/**`
  - `openspec/changes/chg-2026-055-harness-final-architecture/**`
  - `docs/adr/**`
- Forbidden paths:
  - `openspec/constitution.md`、`openspec/specs/**`、`openspec/verification/**`、
    `openspec/baselines/**`、`openspec/contracts/**`
  - `Catalog/**`、`scripts/**`、`.github/**`、`AGENTS.md`、`PRODUCT-LOOP.md`、
    `ArkDeck.xcodeproj/**`、`ArkDeckApp/**`
  - 其他 change 目录
- Risk:high(状态模型迁移会碰全部既有 task 记录。缓解:迁移函数有真实历史数据用例,
  时间线逐字断言,gate 表逐格负例;不改 job 状态机与 journal 语义)

## TASK-HFA-007 — 确定性 Analyzer:新 provider `arkdeck-analyzer` 与 derived artifact 流水线

- Status:done
- Done:2026-07-31;随本实现 PR 合入生效(维护者 review + merge 即批准)。
  HFA-AC-15、HFA-AC-16 PASS,evidence = `evidence/runs/TASK-HFA-007/run-r1.md`
  (库层 1010+ tests/1 skip/0 fail,新增 9 例;catalog_gen 39/39 零 drift;
  check-sdd 0/0/114;catalog digest 更新)。
  **Gate**:§20 冻结门由维护者 2026-07-31 显式提前解冻(指令:完成全部 HFA);
  本任务 host-only、零设备命令、零源码写入。
  **交付**:新 provider `analyzer`(CatalogProvider 枚举 + 生成器/schema 词表 +
  dispatcher 独立路由 + daemon 组合注册)、封闭 step kind `runDeterministicAnalyzer`
  (`analyzerRef` 是枚举,不能指向任意程序)、三个 operation
  (`analyzer.extract-crash-signature@1` / `summarize-hilog@1` / `summarize-trace@1`)、
  derived artifact provenance(sourceArtifactId + sourceSha256 + analyzerRef +
  analyzerVersion + derivedSha256 + byteCount)。
  **三条 fail-closed**:输入字节与 lease 不符即拒绝(lease 是声称,字节是事实);
  空输出判 failed(「分析器什么都没产出」不等于「没发现问题」);
  声明 `.json` 却不是 JSON 判 `analyzer.malformedResult`(名字是被检查的承诺,不是标签)。
  **两处如实登记的未交付**:
  ① `workspace.collect-build-outputs@1` **未交付**。它不是分析,是构建产物收集;
  而 `workspace.build-openharmony@1` 今天只发布 `build.log`,没有 output manifest ——
  正确的归属是**补构建腿自己的产物声明**,不是 analyzer 面。本 change 不为它新建任务;
  TASK-HFA-005 的真机端到端若因缺 output manifest 无法做「部署 digest == build output
  digest」的相等判定(HFA-AC-11/12),应在那条任务里同车补齐;
  ② `workspace.parse-build-failure@1` 同理未交付 —— 它消费 build.log,一旦构建腿
  发布了结构化产物,它要么变成第四个 analyzer profile(零新机制),要么根本不需要。
  先把机制做实,不先造它的壳。
  **一条设计约束**:每台主机一个 pinned analyzer 二进制,各 analyzer 用 `fixedArguments`
  选行为。dispatcher 按 provider 解析可执行文件,两个不同二进制会被对方的 digest 拒掉
  (fail closed),因此该形态不可表达 —— 写在 `AnalyzerExecutableResolver` 的注释里。
  **harness 内解析尚未改接 derived artifact**:TASK-HFA-001 的就地解析仍在原位,
  改接需要 handler 先派发 analyzer job 再消费其产物,属规划面变更(TASK-HFA-003 的
  handler 已交付,接线留给 TASK-HFA-005 的真机链路一并验证)。
- Platform:macos
- Requirements/AC:proposal What 7(Analyzer 面);change-local HFA-AC-15、HFA-AC-16,
  登记于 `verification.md`
- Gate:GJ-5 `REAL_DEVICE_PASS`(TASK-HFA-005 done)或维护者显式提前解冻;
  本任务 host-only、零设备命令、零源码写入
- Depends on:TASK-HFA-001(判定面先稳定,再把解析搬到 provider);
  CHG-2026-054 TASK-HTP-007(host-only 准入路径,done)
- Hardware required:no
- Scope(r1 追加:承接 TASK-HFA-008 移交的 `workspace.parseBuildFailure@1` 与
  `collectBuildOutputs@1` —— 两者消费既有 artifact 并发布 derived artifact,与本任务的
  analyzer/derived-artifact 流水线同一套 plumbing):新 provider `arkdeck-analyzer`
  (`CatalogProvider` 新增 case + registry 注册 + host concurrency key)与三个 operation:`analyzer.extractCrashSignature@1`、
  `analyzer.summarizeHilog@1`、`analyzer.summarizeTrace@1`(全部 E0、`binding: none`、
  经既有 `DescriptorBoundProcessDispatcher`);derived artifact 必须带
  sourceArtifactIds/hashes、analyzerRef@version、toolchainFingerprint、
  task/attempt/actionRun/runtimeJob、revision 作用域、redaction 状态、content hash;
  harness 内的就地解析改为消费 derived artifact(判定语义不变,provenance 变真);
  §17.5 例外边界写进契约:**纯内存/无子进程**的转换可留在 engine-internal step
  且必须属于某个 job、记 intent/outcome、发布 derived artifact、带 analyzer version,
  **任何外部工具一律走 provider**(负例:声明为 analyzer 例外却 spawn 子进程 → 拒绝);
  catalog 重生成与 digest 更新 + 生成器 pin 同步;工具未配置即 `UNAVAILABLE` 带机器可读
  原因且零 capability 消耗。命名差异(终版把 symbolizeCrash 列在 analyzer 下,仓内为
  `workspace.symbolizeCrash@1`)记一行兼容说明,**不搬家**
- Allowed paths:
  - `Packages/ArkDeckKit/**`
  - `Catalog/**`
  - `openspec/contracts/catalogs/**`
  - `openspec/contracts/workflow-step.schema.json`
  - `openspec/contracts/workflow-step-registry.yaml`
  - `openspec/contracts/provider-contracts.md`
  - `scripts/catalog_gen/**`
  - `openspec/changes/chg-2026-055-harness-final-architecture/**`
  - `docs/adr/**`
- Forbidden paths:
  - `openspec/constitution.md`、`openspec/specs/**`、`openspec/verification/**`、
    `openspec/baselines/**`、`openspec/contracts/capability-registry.yaml`
  - `scripts/**`(仅上列 `scripts/catalog_gen/**` 除外)、`.github/**`、`AGENTS.md`、
    `PRODUCT-LOOP.md`、`ArkDeck.xcodeproj/**`、`ArkDeckApp/**`
  - 其他 change 目录
- Risk:high(新 provider + 新 operation 面,命中六处词表 lockstep,同 PR 更新生成器 pin
  并断言零 drift——CHG-2026-050/053/HTP-007 先例。分析错误会把错误事实送进判定,
  故 analyzer 确定性与版本化各有用例,原始 artifact 一律保留)

## TASK-HFA-008 — workspace 只读族:定位证据的 typed operation

- Status:done
- Done:2026-07-31;随本实现 PR 合入生效(维护者 review + merge 即批准)。
  HFA-AC-17 PASS,evidence = `evidence/runs/TASK-HFA-008/run-r1.md`
  (库层 973 tests/1 skip/0 fail,新增 14 例;catalog_gen 39/39 零 drift;
  check-sdd 0/0/114;catalog digest 更新)。
  **Gate**:§20 冻结门由维护者 2026-07-31 在会话中显式提前解冻(指令:完成全部 HFA);
  本任务 host-only、零设备命令、零源码写入,风险面与 TASK-HTP-007 同级。
  **交付 4 个新 operation**:`workspace.inspect-git-status@1`、`inspect-diff@1`、
  `read-source-range@1`、`create-checkpoint@1`。
  **标题从「八个」改为按实际能力交付,三条依据逐条如实登记(§5:判重以产品结果为准,
  不以任务名为准)**:
  ① `searchSource@1` **已存在** —— 就是已发布的 `workspace.inspect-source@1`
  (pinned grep + symbol + glob,argv 逐 token 已钉死)。再发一个语义相同的 operation
  属重复能力,不做;
  ② `inspectSymbol@1` = `inspect-source@1`(定位)+ 本任务的 `read-source-range@1`
  (取上下文)的**组合**,不是第三个 operation。handler 侧组合属 TASK-HFA-003 的规划面;
  ③ `parseBuildFailure@1` / `collectBuildOutputs@1` **移交 TASK-HFA-007**:两者都
  **消费既有 artifact 并发布 derived artifact**,依赖的是 analyzer/derived-artifact
  流水线与 artifact input resolver,而不是本任务的 workspace 读取面。放在这里会先
  造一套只此一处使用的 artifact 消费路径,与 007 重复。
  **一处如实登记的命名偏离**:终版 §18.3 把产物写成 `git-status.json` / `diff-summary.json`,
  而 git 的实际输出是文本(`--porcelain=v1`、`--stat`),故产物名用 `.txt`。
  把文本命名为 `.json` 会让下游按 JSON 解析并失败——这是不实描述,不是格式选择。
- Platform:macos
- Requirements/AC:proposal What 8(workspace 只读族);change-local HFA-AC-17,
  登记于 `verification.md`
- Gate:GJ-5 `REAL_DEVICE_PASS`(TASK-HFA-005 done)或维护者显式提前解冻;host-only
- Depends on:CHG-2026-054 TASK-HTP-007(host-only 准入 + provider 骨架,done)
- Hardware required:no
- Scope(r1 修订,依据见上方 Done 的三条登记):`workspace.inspect-git-status@1`、
  `inspect-diff@1`、`read-source-range@1` 三个 E0 读取 operation 与
  `create-checkpoint@1`(写 git 对象、不动 ref/index/worktree);
  全部经 ProjectProfile 声明的 scope 与 preset lowering,调用方零 argv、零路径;
  每个 operation 声明 typed inputs/outputs、byte budget、artifact 与 retry safety;
  argv 逐 token 契约测试;provider/工具不可用时 `UNAVAILABLE` 带机器可读原因且零
  capability 消耗;catalog 重生成 + digest 更新 + 生成器 pin 同步。
  **禁止面**(负例断言不可表达):`runShell`、`executeCommand`、`runArbitraryScript`、
  `runGit`、`writeFile`
- Allowed paths:
  - `Packages/ArkDeckKit/**`
  - `Catalog/**`
  - `openspec/contracts/catalogs/**`
  - `openspec/contracts/workflow-step.schema.json`
  - `openspec/contracts/workflow-step-registry.yaml`
  - `openspec/contracts/provider-contracts.md`
  - `scripts/catalog_gen/**`
  - `openspec/changes/chg-2026-055-harness-final-architecture/**`
  - `docs/adr/**`
- Forbidden paths:
  - `openspec/constitution.md`、`openspec/specs/**`、`openspec/verification/**`、
    `openspec/baselines/**`、`openspec/contracts/capability-registry.yaml`
  - `scripts/**`(仅上列 `scripts/catalog_gen/**` 除外)、`.github/**`、`AGENTS.md`、
    `PRODUCT-LOOP.md`、`ArkDeck.xcodeproj/**`、`ArkDeckApp/**`
  - 其他 change 目录
- Risk:medium(八个 operation 多为只读,主要风险是 scope 逃逸与 byte budget 失控;
  `createCheckpoint@1` 是唯一 E1,须有 readback 与 revert 配对)

## TASK-HFA-009 — Workspace 执行主体:capability subject 扩展与 exact base revision 绑定

- Status:ready
- Platform:macos
- Requirements/AC:proposal What 9(workspace 主体与 capability);change-local HFA-AC-18、
  HFA-AC-19,登记于 `verification.md`
- Gate:GJ-5 `REAL_DEVICE_PASS`(TASK-HFA-005 done)。**本任务改安全内核的授权主体面,
  不接受 Agent 自行提前解冻**;需维护者在 review 中确认主体扩展形态
- Depends on:TASK-HFA-003(修复腿在位,exact revision 绑定才有真实消费者)、TASK-HFA-008
- Hardware required:no
- Scope:`RuntimeCapability` 的授权主体从 device 扩到 workspace
  (workspaceIdentitySHA256 + expectedWorkspaceRevision + allowedFileScopesDigest),
  **复用同一 store、同一验证器、同一 reservation/consumption/outcome 账本**;
  终版 §18.2 的 WorkspaceRevision digest(HEAD OID + index tree OID + 已变更路径内容
  digest + submodule OIDs + profileVersion,能识别 dirty worktree)成为
  `applyPatch`/`buildOpenHarmony`/`revertPatch` 的准入前置;revision 失配 =
  `WORKSPACE_REVISION_CONFLICT`,fail closed 不 apply;`device` 主体的既有准入与
  E2 exact-plan 语义**逐条不变**(回归断言);capability 只能收窄不能放宽的性质有负例
- Scope note(2026-08-01):r1 要让四个 workspace 变更 operation 能**声明**自己的 base
  revision,那是 descriptor 的可选输入字段;不放开 `Catalog/**` 与生成器,绑定就只能停在
  够不着的代码里。故下方 allowed paths 增列这两项。
- Allowed paths:
  - `Packages/ArkDeckKit/**`
  - `Catalog/**`
  - `scripts/catalog_gen/**`
  - `openspec/contracts/capability-registry.yaml`
  - `openspec/contracts/provider-contracts.md`
  - `openspec/changes/chg-2026-055-harness-final-architecture/**`
  - `docs/adr/**`
- Forbidden paths:
  - `openspec/constitution.md`、`openspec/specs/**`、`openspec/verification/**`、
    `openspec/baselines/**`
  - `Catalog/**`、`scripts/**`、`.github/**`、`AGENTS.md`、`PRODUCT-LOOP.md`、
    `ArkDeck.xcodeproj/**`、`ArkDeckApp/**`
  - 其他 change 目录
- Risk:high(动的是授权主体本身。缓解:device 分支逐条不变且有回归断言;
  workspace 分支只对声明 workspace 主体的 operation 可达;E2 与 exact-plan 信任根不变;
  harness 仍不得自签、不得续期、不得扩范围)

## TASK-HFA-010 — Memory 晋升、作用域与检索

- Status:ready
- Platform:macos
- Requirements/AC:proposal What 10(Memory);change-local HFA-AC-20,登记于 `verification.md`
- Gate:GJ-5 `REAL_DEVICE_PASS`(TASK-HFA-005 done)或维护者显式提前解冻
- Depends on:TASK-HFA-004(Attempt 是 memory 投影的主要事实源之一)
- Hardware required:no
- Scope:memory 生命周期 `CANDIDATE`/`VERIFIED`/`SUPERSEDED`/`INVALIDATED`;
  晋升到 `VERIFIED` 必须满足终版 §13.2 之一(对应 Required Evaluation PASS 或人工确认)
  且带证据引用;作用域字段(component、symbols、revisionScope、deviceProfiles、
  toolchainProfiles)与失效条件;`FailureMemory` 的 `retryDisposition` 五态与
  alternativeHints;检索**先精确过滤再排序**(指纹/component/file/symbol/operation/
  revision/profile),未验证 memory 的得分必须低于当前 task evidence;
  超出作用域的 memory 不得进入 `confirmedFacts.current`(负例);
  ContextAssembler 消费并在 selection manifest 里记录纳入理由
- Allowed paths:
  - `Packages/ArkDeckKit/**`
  - `openspec/changes/chg-2026-055-harness-final-architecture/**`
  - `docs/adr/**`
- Forbidden paths:
  - `openspec/constitution.md`、`openspec/specs/**`、`openspec/verification/**`、
    `openspec/baselines/**`、`openspec/contracts/**`
  - `Catalog/**`、`scripts/**`、`.github/**`、`AGENTS.md`、`PRODUCT-LOOP.md`、
    `ArkDeck.xcodeproj/**`、`ArkDeckApp/**`
  - 其他 change 目录
- Risk:medium(错误知识跨 task 传播是主要风险,由作用域过滤与晋升条件的负例覆盖;
  不引入向量库、不引入检索基础设施)

## TASK-HFA-011 — 真实厂商 LLM adapter 与 model call 预算

- Status:done
- Done:2026-07-31;随本实现 PR 合入生效(维护者 review + merge 即批准)。
  HFA-AC-21 PASS,evidence = `evidence/runs/TASK-HFA-011/run-r1.md`
  (库层 978 tests/1 skip/0 fail,新增 10 例)。
  **Gate**:§20 冻结门由维护者 2026-07-31 显式提前解冻(指令:完成全部 HFA);
  出站默认 deny **不变**——配置 adapter 不等于开启出站,开启仍要项目级显式配置。
  **交付**:`HarnessModelTransport` 端口(生产 = `URLSessionModelTransport`,仅 https)
  + Claude / OpenAI / Gemini 三个 gateway;`maxModelCalls` 预算(含 legacy 解码默认)
  与 `HarnessBudgetKind.modelCalls` 安全停止;model call 在**每条出口路径**上计费
  (dispatch / patch / 交人 / noSafeAction / stale),计费折进同一次 transition ——
  规划中途提交会移动 state version,把自己的 decision 变成 stale(TASK-HFA-002 的闸)。
  顺带把 `HarnessModelRun.responseBytes` 从占位 0 改为实测字节数。
  **一处必须记的连带修正**:TASK-HFA-002 的
  `testAStaleWakeChargesNoFailureNoProgressAndNoBudget` 原断言「预算全零」,
  是因为当时没有 model call 预算可计。本任务落地后该断言改为
  `HarnessConsumedBudget(modelCalls: 1)` —— 这正是 HFA-AC-4 原文要求的
  「stale 不计策略失败,但已发生的 model call 仍计入预算」,是收紧不是放宽。
  **如实登记未覆盖**:①真实厂商端点未做真调用(测试全部经 fake transport,
  零网络、零密钥入仓);②token usage 仍不记——三家 envelope 的 usage 字段形态不同,
  且当前无消费者,记实测字节数而不是半可信的 token;③密钥来源(keychain/env/配置)
  由 composition root 决定,本任务只定义 `HarnessVendorCredential` 的形状。
- Platform:macos
- Requirements/AC:proposal What 11(厂商 adapter);change-local HFA-AC-21,
  登记于 `verification.md`
- Gate:GJ-5 `REAL_DEVICE_PASS`(TASK-HFA-005 done)或维护者显式提前解冻。
  **出站默认 deny 不变**;开启出站需项目级显式配置
- Depends on:TASK-HFA-002(ModelRun 与 contextDigest 在位后再接真实模型)
- Hardware required:no
- Scope:Claude / OpenAI / Gemini 三个 adapter 共用既有 `LLMDecisionPort`,
  严格结构化输出与解析负例(未知字段、未知 kind、raw argv/shell/远端路径、状态字段、
  retry 计数、成功结论一律整条拒绝);**替换 adapter 不改变状态机结论**
  (同一持久化事实 → 同一 stage/lifecycle 迁移,离线确定性路径作为对照);
  补 `maxModelCalls` 预算与耗尽后的安全停止;出站内容断言只含脱敏、有界摘要与
  artifact 引用(不含设备标识、未脱敏字节、凭据);超时/不可用/无效输出走
  `MODEL_OUTPUT_INVALID`(有界重试,不创建 ActionRun)
- Allowed paths:
  - `Packages/ArkDeckKit/**`
  - `openspec/changes/chg-2026-055-harness-final-architecture/**`
  - `docs/adr/**`
- Forbidden paths:
  - `openspec/constitution.md`、`openspec/specs/**`、`openspec/verification/**`、
    `openspec/baselines/**`、`openspec/contracts/**`
  - `Catalog/**`、`scripts/**`、`.github/**`、`AGENTS.md`、`PRODUCT-LOOP.md`、
    `ArkDeck.xcodeproj/**`、`ArkDeckApp/**`
  - 其他 change 目录
- Risk:high(唯一的外部不可信输入面与唯一出站面。拒绝面与脱敏面由负例钉死,
  不依赖模型自律;密钥不入仓、不入日志、不入 context)

---

# Wave C — 结构性迁移(队尾)

## TASK-HFA-012 — Harness 存储迁移到 SQLite(终版 §22)

- Status:ready
- Platform:macos
- Requirements/AC:proposal What 12(SQLite 迁移);change-local HFA-AC-22,
  登记于 `verification.md`
- Gate:**Wave A 全部 done 且 GJ-5 `REAL_DEVICE_PASS`**(维护者 2026-07-31 决定:
  先跑通功能再迁移;`PRODUCT-LOOP.md` §12 不允许非阻塞的大规模重构)
- Depends on:TASK-HFA-005;TASK-HFA-004(Attempt 表在迁移范围内)
- Hardware required:no
- Scope:`harness_task`/`task_event`/`task_condition`/`attempt`/`model_run`/`decision`/
  `action_run`/`dispatch_intent`/`runtime_job_link`/`artifact_link`/`evaluation`/
  `human_action`/`memory_entry`/`context_manifest` 表;WAL 模式、外键 ON、
  snapshot 更新与 event append 同一事务、`UPDATE ... WHERE state_version = ?` 乐观锁、
  task 级 reconcile lease、canonical JSON 与 digest、schema migration version;
  既有 durable file 数据**一次性迁移且可回读**(迁移后 `task.events`/`task.result`
  逐字保持);崩溃一致性矩阵(迁移中断可重入);
  **不做**分布式事务、不复制 journal/artifact 事实
- Allowed paths:
  - `Packages/ArkDeckKit/**`
  - `openspec/changes/chg-2026-055-harness-final-architecture/**`
  - `docs/adr/**`
- Forbidden paths:
  - `openspec/constitution.md`、`openspec/specs/**`、`openspec/verification/**`、
    `openspec/baselines/**`、`openspec/contracts/**`
  - `Catalog/**`、`scripts/**`、`.github/**`、`AGENTS.md`、`PRODUCT-LOOP.md`、
    `ArkDeck.xcodeproj/**`、`ArkDeckApp/**`
  - 其他 change 目录
- Risk:high(动的是全部 harness 持久化。缓解:迁移用真实历史数据做逐字回读断言,
  迁移中断可重入,失败可停在旧存储不损坏;引擎 journal 与 artifact store 不受影响)

## TASK-HFA-013 — 抽取 `ArkDeckHarness` module(终版 §30)

- Status:ready
- Platform:macos
- Requirements/AC:proposal What 13(module 抽取);change-local HFA-AC-23,
  登记于 `verification.md`
- Gate:**Wave A 全部 done 且 GJ-5 `REAL_DEVICE_PASS`**;TASK-HFA-012 已 done
  (先迁存储再搬家,避免同一 PR 同时改存储与模块边界)
- Depends on:TASK-HFA-012
- Hardware required:no
- Scope:新增 `ArkDeckHarness` library target(Domain/Application/Context/Evaluation/
  Memory/Persistence/Ports/LLM/Tasks 子目录),把 harness 代码从 `ArkDeckCore`/
  `ArkDeckStorage`/`ArkDeckWorkflows/AgentHarness`/`ArkDeckAgentDaemon` 迁入;
  **纯移动 + 依赖方向修正,不改行为**(逐文件对照,行为变更一律拆出);
  依赖方向单向:`ArkDeckHarness` → Runtime 协议 / Catalog 查询接口,
  harness **不 import** OpenHarmony 设备参数、不持远端路径、不构造 Git/HDC/build argv
  (由依赖断言测试钉死);保持单 `arkdeck-agentd` executable
- Allowed paths:
  - `Packages/ArkDeckKit/**`
  - `openspec/changes/chg-2026-055-harness-final-architecture/**`
  - `docs/adr/**`
- Forbidden paths:
  - `openspec/constitution.md`、`openspec/specs/**`、`openspec/verification/**`、
    `openspec/baselines/**`、`openspec/contracts/**`
  - `Catalog/**`、`scripts/**`、`.github/**`、`AGENTS.md`、`PRODUCT-LOOP.md`、
    `ArkDeck.xcodeproj/**`、`ArkDeckApp/**`
  - 其他 change 目录
- Risk:medium(纯移动的风险在"顺手改了行为"。缓解:PR 内断言测试数与结论不变,
  行为变更一律拆出;两段留守范式见 MU-2 T06 先例)
