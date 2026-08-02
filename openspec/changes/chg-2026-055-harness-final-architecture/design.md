# Design — CHG-2026-055 Harness 终版架构补全

> 本文件是设计与取舍记录,不是授权载体。与 `proposal.md` 冲突时以 proposal 为准;
> 与 Constitution / `PRODUCT-LOOP.md` 冲突时停手交维护者。
> 设计输入 = 维护者 2026-07-31 下发的《ArkDeck Agent Harness Runtime 终版架构设计》
> (自述基线 `85de890b`)。**该基线早于全部 `TASK-HTP-*` 提交**,文档 §2/§3 的能力盘点
> 相对 `main@fa8a8704` 已过期;实现时以本文件与仓内实测为准,以文档为目标形态。

## 1. 差量地图(哪些已在仓内、哪些是本 change)

```text
终版 §7 组件            仓内现状(main@fa8a8704)                     本 change
─────────────────────────────────────────────────────────────────────────────
TaskManager             HarnessTaskCoordinator                        —
TaskStateReducer        有(status/phase 两轴 + 乐观锁)                006 加 Condition 轴
TaskReconciler          有(一次唤醒至多一个 effectful job)            —
ConditionObserver       无                                            006
ContextAssembler        有(有界裁剪,无 hash/manifest)                 002 加 digest + manifest
DecisionGateway         有(端口 + 严格解析,零厂商 adapter)            011
PolicyGuard             有(availability/effect/预算/指纹/raw 拒绝)     002 加 stale 面
EvaluationEngine        有(criterion + verdict 四态)                  001 换证据源
RecoveryManager         有(失败分类 + no-progress 雏形)               004 收紧
MemoryProjector         有(task/project/failure 三 scope)             010 加生命周期与作用域
HarnessRuntimePort      有                                            —
WorkspaceProvider       有(6 个 operation)                           008 只读族 + 009 主体绑定
AnalyzerProvider        无                                            007
```

## 2. 判定源:为什么必须换到崩溃台账(001)

r6/r7 两轮真机实测的硬事实(见 `chg-2026-054/evidence/runs/TASK-HTP-006/run-r6-fail-path.md`):

- 应用确实产生了 fault log(108,974 字节,落在 `/data/log/faultlog/faultlogger/`);
- harness 采到的 887 KB `hilog.txt` 里**只有应用自身日志行**,没有 fault block;
- 于是 `matchingCrashCount=0`、`newFatalSignatureCount=0`、verdict `pass`。

**证据模型的修法不是"多抓一点 hilog"**,而是让 criteria 声明的证据类型与真相所在一致:

```text
criterion.evidenceRequirements = [crash-log-index.json, crash-log.txt]   ← 判定必须的
                               + [hilog.txt]                             ← 辅助/liveness 用
```

三条 fail-closed 规则(001 的负例集):

1. 声明的崩溃证据产物**缺席或 missing/truncated** → `INCONCLUSIVE`,永不 PASS;
2. 台账**为空且工具正常返回**(设备确实没有崩溃记录)→ 才可作为"无匹配崩溃"的正证据;
   空列表与"没采到"必须可区分(DHA-005 的采集腿已把这两者分开);
3. 台账里有条目但内容不可解析 → `ERROR` + `evidenceIntegrity` 人工阻塞,不是 PASS。

**与 007 的关系**:001 先在 observation builder 内做确定性解析(沿用 §17.5 的"纯内存、
无子进程"例外);007 落地后,同一解析改为 `analyzer.extractCrashSignature@1` 产出的
derived artifact,001 的 criteria 不变。两条路都不改判定语义,只改证据来源的 provenance。

## 3. 防陈旧闸(002):字段与事务序

终版 §11.4 的校验集,按仓内可实现的形态落地:

```text
decision.htaskId            == task.htaskId
decision.observedStateVersion == task.currentStateVersion      ← 新增
decision.contextDigest      == task.latestContextDigest        ← 新增
decision.attemptId          == task.activeAttemptId            ← 004 之后生效
task.activeEffectfulJobId   == nil
decision.baseWorkspaceRevision == task.currentWorkspaceRevision ← 003/009 之后生效
decision.expectedBindingRevision == task.currentBindingRevision
引用的 build/deploy artifact digest 仍存在且一致
```

事务序沿用既有乐观锁写路径(`commit()` → reducer),**不引入第二把锁**:

```text
begin(immediate)
  load task for update
  校验上表 → 不通过:记 DECISION_STALE 事件,返回,不执行
  校验通过:记 DECISION_ACCEPTED + 持久化 ActionRun
commit
```

Stale 的**代价语义**必须与失败区分(否则模型会被自己的陈旧决策拖进 no-progress 停机):

| 计入 | stale | 策略失败 |
| --- | --- | --- |
| model call 预算 | 是 | 是 |
| no-progress 轮次 | **否** | 是 |
| failure fingerprint | **否** | 是 |
| 重新组装 context | 是 | 视情况 |

`contextDigest` 的定义(§12.9):对**过滤后**的 canonical JSON 取 SHA-256,键排序、
时间戳与引用归一化、包含 `contextSchemaVersion` 与实际选入的片段。
**脱敏在 digest 之前完成**,因此 digest 精确代表模型实际收到的内容。

## 4. 修复腿(003):状态机与 gate

```text
ANALYZING --PatchProposalReady--> PATCHING --PatchApplied--> BUILDING
   ^                                                            |
   |                                          BuildPassed + outputs
   |                                                            v
   +--(build/test 语义失败:要求新策略)--- ANALYZING <--- DEPLOYING
                                                              |
                                             DeploymentObserved(digest 相等)
                                                              v
                                                          VERIFYING
                                              criteria FAIL + 预算仍允许 → ANALYZING
```

三条 gate 必须是**结构性相等判定**,不是"看起来成功":

| 迁移 | 必须成立 |
| --- | --- |
| PATCHING → BUILDING | applied-patch 的 readback revision == Attempt.patchRevision |
| BUILDING → DEPLOYING | build 的 source revision == 当前 patch revision,且 build output manifest 有 digest |
| DEPLOYING → VERIFYING | 设备 readback 的产物 digest == build output digest |

失败分类沿用终版 §15.3;本 change 只需在既有 `HarnessFailureFingerprint` 上补
`BUILD_SEMANTIC_FAILURE` / `TEST_FAILURE` / `WORKSPACE_REVISION_CONFLICT` 三类的
`retryDisposition = ALTERNATIVE_REQUIRED`,**不新建失败框架**。

回滚:部署或复验失败 → `workspace.revertPatch@1`(已存在)。回滚本身也是 E1,消耗
`maxE1Mutations`;回滚结果未知时进人工阻塞,不重复回滚。

## 5. Attempt vs Action Retry(004)

终版 §10.2 的分界必须落成代码可判定的两条路径,而不是文档措辞:

```text
同一 operation + 规范化后同一 inputs + 同一 patch + failure 为 TRANSIENT 且 retry-safe
    → Action Retry:Attempt 不变,新 ActionRun,新 idempotencyKey(除崩溃重放用原 key)
至少一项策略要素变化(§10.1 七要素之一)
    → 新 Attempt:新 ordinal、新 strategyFingerprint
七要素完全相同且已产生同一 failureFingerprint
    → DUPLICATE_STRATEGY:拒绝,不派发,不伪装新 Attempt
```

`strategyFingerprint` = canonical JSON SHA-256,输入恰为:hypothesis class、
selected operation family、patch digest(或 patch-region fingerprint)、base workspace
revision、artifact source set、prerequisite set、target/toolchain profile、
expected next observation。**hypothesis 自由文本不参与**——这正是防止"换个说法重来"的地方。

## 6. 三维状态(006):迁移而不是重写

现状两轴(status × phase)→ 目标三轴(lifecycle × stage × conditions)。落地顺序:

1. 先加 Condition 轴(纯新增,既有任务的 conditions 初始为 `UNKNOWN` + reasonCode
   `migratedWithoutObservation`);
2. `deviceReady` 从 phase 移到 Condition:phase 枚举去掉该 case,迁移函数把历史
   `deviceReady` 映射为 `stage=REPRODUCING` + `DeviceReady=UNKNOWN`;
3. `paused` → `waiting` + `waitReason=USER_SUSPENDED`;`waiting` 新增;
4. stage gate 表驱动(§8.6),表本身是数据,负例逐格覆盖。

**迁移必须有实测**:用 CHG-2026-054 真机窗口留下的持久化任务目录做前向迁移用例,
断言迁移后 `task.events` 时间线逐字保持、结论不变。

## 7. Analyzer 面(007)与 §17.5 例外边界

```text
Runtime Job Raw Artifact
  ↓ hash / status / privacy / subject 快照
analyzer.* Runtime Operation(确定性、版本化、无网络、无自由路径)
  ↓
Derived Structured Artifact(带 sourceArtifactIDs/hashes、analyzerRef@version、revision 作用域)
  ↓ TaskArtifactLink
Observation Builder / ContextAssembler
```

**例外边界必须写死**:纯内存、确定性、无外部副作用、无子进程的转换,可以继续留在
engine-internal step(必须属于某个 RuntimeJob、记 intent/outcome、发布 derived artifact、
带 analyzer version)。**任何调用外部 symbolizer/parser 的分析一律走 AnalyzerProvider**。
这不是第二套执行引擎——它复用 `DescriptorBoundProcessDispatcher` 的身份校验与真 spawn。

命名差异登记:终版 §18.3 把 `symbolizeCrash` 列在 `analyzer.*` 下,仓内已以
`workspace.symbolizeCrash@1` 交付且 done。本 change **不搬家**(搬家 = 破坏性修改已发布
operation,要额外审批且零产品收益),只在 007 的实现 PR 里记一行兼容说明。

## 8. Workspace 主体与 capability(009)

终版 §16.4 的主体扩展,落到既有 `RuntimeCapability` 上:

```text
subject = .device(stableIdentitySHA256, bindingRevision)          ← 既有,逐条不变
        | .workspace(workspaceIdentitySHA256,
                     expectedWorkspaceRevision,
                     allowedFileScopesDigest)                      ← 新增
```

WorkspaceRevision 的定义(§18.2)必须包含 dirty worktree,否则 exact base 绑定形同虚设:

```text
SHA256(HEAD OID + index tree OID + 已变更路径内容 digest(排序) + submodule OIDs + profileVersion)
```

同一个 store、同一验证器、同一 reservation/consumption/outcome 账本;
**不新建 workspace capability 系统**。E1 workspace 授权仍只能由维护者经 merged PR 签发。

## 9. 与终版文档的偏离登记(实现时不得静默改回)

| 终版要求 | 本 change 的处理 | 依据 |
| --- | --- | --- |
| §22 SQLite 存储 | 已交付:TASK-HFA-012 done(SQLite 迁移合入,含历史 durable file 一次性迁移) | `PRODUCT-LOOP.md` §12:结构性改动须与 GJ 同车且非阻塞不做 |
| §30 独立 `ArkDeckHarness` module | 已交付:TASK-HFA-013 done(独立 SwiftPM target);Harness✂️Process、Workflows✂️Harness 两条边由 #962 在 Package.swift 层删除并由 `ArchitectureBoundaryContractTests` 钉死 | 同上 |
| §17.2 Runtime Request V3 `subject` | 只做 workspace 主体的窄化扩展(009),不做通用 Resource DSL;host-only 已由 `binding: none` 准入路径(TASK-HTP-007)承担 | 终版 §27 风险表自身的缓解方案 |
| §17.3 `WorkflowEffect` 重命名 | 不重命名;按 `effectRiskClass` + `executionDomain` 计算属性兼容 | 终版 §17.3 明文建议 |
| §18.3 `analyzer.symbolizeCrash@1` | 保持 `workspace.symbolizeCrash@1` | 见 §7 |
| §12.6 Context 预算默认值 | 沿用仓内既有 `HarnessDecisionContextLimits`,按终版数值校准而非替换 | 已有实现且有测试覆盖 |

## 10. 测试面(全 change 通用)

- **判定面负例优先**:每个"能判成功"的路径都必须有一条"证据缺席/不可解析时不判成功"的负例;
- **argv 逐 token 断言**:新 operation 一律沿用 `DeviceProviderArgvContractTests` 范式
  (`PRODUCT-LOOP.md` §11 的两次实证教训:typed 层全绿时生产 argv 仍可能是错的);
- **崩溃矩阵**:凡引入新的持久化状态字段(002 的 stateVersion/contextDigest、004 的 Attempt),
  必须有"写入前/写入后终止"两窗口用例;
- **词表 lockstep**:新增 step kind 命中六处 lockstep(diagnostics-stdout.yaml、
  workflow-step.schema.json、operation.schema.json 两处、WorkflowStep.swift validator、
  `scripts/catalog_gen/test_generate.py` 三条 pin),同 PR 更新并断言零 drift;
- **真机结论只能来自真机**:缺窗口时如实记 `pending-hardware`,不得以 fake 顶替。
