---
id: CHG-2026-055-harness-final-architecture
revision: 1
status: approved # 携 approved 落地:维护者 review + merge 本 PR 即批准(enforcement 批准语义);merge 前任务不开工。范围过大时在 review 中要求削减并在同一 change 内修订,不新建 change。
class: capability
core_change_level: none
owner: lvye
core_baseline: CORE-3.0.0
platforms: [macos]
---

# Harness 终版架构补全:修复腿、判定源、防陈旧与确定性分析器

> **设计输入**:`ArkDeck Agent Harness Runtime 终版架构设计`(维护者 2026-07-31 下发,
> 文档自述评审基线 `85de890b`)。**该基线早于 CHG-2026-054 的全部 15 个 `TASK-HTP-*`
> 提交**,因此文档 §2/§3 的「Harness 不存在」盘点相对 `main@fa8a8704` 已经过期。
> 本 change 交付的是**文档要求与 main 实测现状之差**,不重造 CHG-2026-054 已交付面。

> **恰四类声明**:本 change 引入 **新 provider**(`arkdeck-analyzer`)、**新 operation 面**
> (`analyzer.*` 与 workspace 只读族八个 operation),并**扩展 RuntimeCapability 的授权主体**
> (从 device 扩到 workspace,属 E1/E2 安全策略面变化)。按 `PRODUCT-LOOP.md` §22 与
> `AGENTS.md` 控制平面条款,这恰属需要 OpenSpec change + 维护者 PR 审批的四类,且与 GJ-5
> 交付同车。本 change 不产生 readiness/verification/archive 后续载体:任务随各自实现 PR
> 直接翻 done,verification 结论写入同一实现 PR,归档冻结(§20)。

## §19 治理循环四问(新增 Proposal 的强制说明)

1. **对应的真实安全风险**:三条,全部命中 `PRODUCT-LOOP.md` §3。
   ① **崩溃发生了而 harness 判 PASS**——r6/r7 真机实证:三条 criteria 全部以
   `hilog.txt` 为唯一证据源(`HarnessTaskHandler.swift:83-111`),而崩溃明细在
   faultlogger 台账里;一次真实 crash 之后 `matchingCrashCount=0`、verdict `pass`
   (§3-7「把未实现的能力对外标记为可用」的判定面变体)。
   ② **无人值守写源码与部署时没有防陈旧闸**——终版 §11.4/§25.1 明确要求
   `observedStateVersion` + `contextHash` + revision 前置齐备**之前不得开放无人值守 E1
   mutation**;`contextHash|observedStateVersion` 在全仓命中数为 **0**(§3-3、§3-10)。
   ③ **E1 授权主体缺 workspace 维度**——`workspace.applyPatch@1` 今天是 host-only、无
   workspace 身份与 exact base revision 绑定的 capability 主体,补丁可能落在与决策所见
   不同的工作区状态上(§3-10「身份不明确时执行 mutation」)。
2. **为什么不能直接用 runtime 代码修**:①③ 需要**新 provider + 新 operation + capability
   主体扩展**,`AGENTS.md`/§22 明文要求这两类先审批;直接落代码才是违规路径。② 本身是纯
   产品代码,但与 ①③ 同属一条 GJ-5 收敛线,按「结构性改动必须与一个 Golden Journey 同车」
   (§12)合并在同一 change 内交付,不单独立项。
3. **推进哪个 Golden Journey**:GJ-5。当前状态 `IMPLEMENTING`——CHG-2026-054 的真机窗口
   已证明「采集 → 判定 → 安全停止」可以一次 `task submit` 零人工步骤收敛(r4),但如实登记
   了两处未覆盖:**部署修复腿**与**真机 fail → 交人路径**。本 change 的 Wave A 五个任务正是
   这两处。
4. **为什么不会产生后续连锁任务**:proposal 携 `approved` 落地(merge 即批准);十三个任务
   各自是一个垂直实现 PR(代码 + 测试 + 真机结论 + 文档同车);verification 结论写在同一
   PR;不建 readiness-only / status-only / verified-only / archive-only PR。范式已在
   CHG-2026-053/054 跑通。

## Why(差量:终版文档要求 vs `main@fa8a8704` 实测)

下表每一行都在 `main@fa8a8704` 上复核过,不是按文档推测。左列是终版文档章节,右列是仓内事实。

| 终版要求 | main 现状(实测) | 后果 |
| --- | --- | --- |
| §8.2/§11.3/§18.4 修复腿:PATCHING → BUILDING → DEPLOYING → VERIFYING | `HarnessTaskHandler.swift:76-78` 的 `permittedOperations` 只有 `observe.device@1` 与 `capture.diagnostics@1`;`:151-167` verdict `.fail` → `requestHuman`;`:207-221` patching/building/deploying 三个 phase 一律 `noSafeAction`。TASK-HTP-005 已交付的五个 `workspace.*` operation **零消费者** | GJ-5 只有取证半环;"修复"永远交人 |
| §14.3 崩溃判定来自崩溃台账 | 三条默认 criteria 的 `evidenceRequirements` 全部是 `hilog.txt`(`HarnessTaskHandler.swift:91/100/109`);`HarnessObservationBuilder.swift:237` 在 harness 进程内对 hilog 文本做模式扫描 | 真实 crash 判成 PASS(r6/r7 实证) |
| §11.4 Stale Decision Guard(INV-07) | `contextHash`、`observedStateVersion` 全仓命中 **0**;decision 只带 `round`(`HarnessDispatch.swift:46-72`);projection 有乐观锁 `version` 但不进 decision | 人工授权/工作区变化后旧 decision 仍可执行 |
| §11.1 四类 decision | `HarnessDecisionKind` 只有 `invokeOperation`/`requestHuman`/`noSafeAction`(`HarnessDispatch.swift:35-38`),**无 `PROPOSE_PATCH`** | 补丁没有 typed 表达面 |
| §10 Attempt 实体与 strategy fingerprint | 只有 `activeRound` 与 `HarnessFailureFingerprint`;无 Attempt、无 baseRevision/patchRevision 绑定 | 同一补丁 + 同一 build failure 可换文案重来 |
| §8.1/§8.3/§8.4 三维状态 | `HarnessTaskStatus` 七态含 `paused`、**无 `waiting`**(`HarnessTask.swift:31-38`);`HarnessTaskPhase` 九态**含 `deviceReady`**(`:51-60`);无 Condition 模型 | 设备瞬断与业务进度混在一根轴上 |
| §17.5/§20.1 raw → 确定性 analyzer → derived artifact → context | `CatalogProvider` 只有 `hdc`/`rockchip`/`workspace`;`Catalog/operations/` 12 个 operation 零 `analyzer.*`;解析在 harness 进程内就地做 | 分析结果无 provenance、无版本、不可复算 |
| §18.3 workspace 只读族 | 只有 `workspace.inspectSource@1`;缺 gitStatus/diff/searchSource/readSourceRange/inspectSymbol/createCheckpoint/parseBuildFailure/collectBuildOutputs | 分析阶段拿不到定位证据,只能靠一次性全量读 |
| §16.4/§18.2 workspace capability 主体与 exact base revision | `RuntimeCapability` 主体只有 device;`workspaceRevision` 只作为 provider summary 输出字段存在(`WorkspaceOperationsProvider.swift:783`),不是准入前置 | 补丁的 base 与决策所见可能不一致 |
| §13.2 Memory 晋升与作用域 | `HarnessMemoryModel.swift` 有 scope/kind/confidence,**无** CANDIDATE/VERIFIED/SUPERSEDED/INVALIDATED 生命周期,**无** revision/device/toolchain 作用域 | 旧知识可能污染新 revision 的决策 |
| §9.2 预算面 | `HarnessTaskBudgets` 四项(`HarnessTask.swift:181-196`),缺 `maxModelCalls`、`maxNoProgressRounds`、`maxActionRetriesPerRun` | 模型调用与重试无独立上限 |
| §30 LLM adapter | 只有端口与离线确定性路径,零厂商 adapter;出站默认 deny | 决策面还没有真实模型可换 |
| §22 SQLite / §30 独立 `ArkDeckHarness` module | 存储 = `ArkDeckStorage` durable files;代码分布在 Core/Storage/Workflows/Daemon 四处 | 与终版目标结构不一致(见「结构性偏离」;已由 TASK-HFA-012/013 关闭) |

一句话:CHG-2026-054 交付了**控制面骨架与取证半环**;本 change 交付**修复半环 + 让判定与决策站在正确证据和正确版本上**,并把终版要求的确定性分析面、workspace 主体绑定与知识作用域补齐。

## What(交付面,按 GJ-5 阻塞度排序)

### Wave A — 关闭 GJ-5 真机环(001–005)

1. **崩溃判定源改为崩溃台账**(TASK-HFA-001):criteria 与 observation builder 消费
   `capture.diagnostics@1` 的 faultlog 产物(采集腿由 CHG-2026-049 TASK-DHA-005 交付,
   本任务只做消费);证据缺失一律 `INCONCLUSIVE`,**不得**因"没看见 crash"判 PASS。
2. **Stale Decision Guard 与 ModelRun**(TASK-HFA-002):task `currentStateVersion` +
   decision `observedStateVersion` + `contextDigest` + workspace/deployed/binding revision
   前置,接受前在同一事务内原子校验;stale 不执行、不计策略失败、不增 no-progress;
   `ModelRun` 记录(provider/model/adapterVersion/tokens/schema 校验/contextDigest/decisionId)。
   **本任务是无人值守 E1 mutation 的前置闸**(终版 §25.1)。
3. **修复腿接线**(TASK-HFA-003):新增 `PROPOSE_PATCH` decision kind 与严格 schema;
   handler 打通 analyze → patch → build → (test) → deploy → verify;stage gate 按 §8.6
   钉死(build 的 source revision 必须等于当前 patch revision;部署 digest 必须等于
   build output digest);失败按 §15.3 分类,build/test 语义失败要求新策略而非原样重试;
   部署或复验失败自动 `workspace.revertPatch@1`。
4. **Attempt 模型与重复策略拒绝**(TASK-HFA-004):Attempt 实体 + strategy fingerprint
   (§10.1 七要素 canonical JSON SHA-256);Action Retry 与 Strategy Attempt 分离(§10.2);
   duplicate decision fingerprint 拒绝;progress 向量按 §15.4 收紧(只重新分析/总结/规划
   不算进展);补 `maxNoProgressRounds`/`maxActionRetriesPerRun` 预算;新增 `task.attempts`。
5. **GJ-5 真机端到端 r2**(TASK-HFA-005):在已接管设备上一次 `task.submit` 跑通**含修复腿**
   的完整闭环,人工步骤 0(E0 与已授权 E1),如实翻转 GJ-5 状态。

### Wave B — 终版架构面补齐(006–011)

6. **三维状态 Lifecycle/Stage/Conditions**(TASK-HFA-006):`waiting` + `waitReason`
   取代 `paused` 语义;`deviceReady` 由 phase 降为 Condition;11+3 个 Condition 带
   TriState/reasonCode/evidenceArtifactIDs/observedRevision;stage gate 表驱动;
   binding revision 变化规则(§8.5);既有持久化任务前向迁移。
7. **确定性 Analyzer 面**(TASK-HFA-007):新 provider `arkdeck-analyzer` + 三个 operation
   (`analyzer.extractCrashSignature@1`/`summarizeHilog@1`/`summarizeTrace@1`);
   raw → analyzer → derived artifact → context 流水线与 §20.3 元数据;harness 内的就地解析
   改为消费 derived artifact。
8. **workspace 只读族**(TASK-HFA-008):`inspectGitStatus`/`inspectDiff`/`searchSource`/
   `readSourceRange`/`inspectSymbol`/`createCheckpoint`/`parseBuildFailure`/
   `collectBuildOutputs` 八个 E0/E1 operation。
9. **Workspace 执行主体与 capability 扩展**(TASK-HFA-009):`RuntimeCapabilitySubject`
   扩到 workspace(identity + expectedWorkspaceRevision + allowedFileScopesDigest);
   §18.2 的 WorkspaceRevision digest 成为 applyPatch/build 的准入前置;复用同一 store、
   同一验证器、同一 reservation/consumption 账本。
10. **Memory 晋升、作用域与检索**(TASK-HFA-010):CANDIDATE/VERIFIED/SUPERSEDED/INVALIDATED;
    revision/component/symbol/device/toolchain 作用域;晋升条件与失效条件;检索先精确过滤
    再排序,未验证 memory 得分低于当前 task evidence。
11. **真实厂商 LLM adapter**(TASK-HFA-011):Claude/OpenAI/Gemini 三个 adapter 共用既有端口;
    出站默认 deny 不变;补 `maxModelCalls` 预算;替换 adapter 不改变状态机结论。

### Wave C — 结构性迁移(012–013,队尾)

12. **Harness 存储迁移到 SQLite**(TASK-HFA-012):终版 §22(WAL、外键、同事务 snapshot+event、
    乐观锁、schema migration)与 §13.4 的 FTS 检索;既有 durable file 数据一次性迁移且可回读。
13. **抽取 `ArkDeckHarness` module**(TASK-HFA-013):终版 §30 目录结构;依赖方向单向
    (Harness → Runtime 协议/Catalog 查询),harness 不 import 设备参数、不持远端路径、
    不构造 argv。交付后 #962 进一步在 target 层钉死:Workflows 不见 Harness,
    Harness 不见 Process;`ArkDeckAgentComposition` 是唯一双平面 library 接缝。

## 结构性偏离的处理(维护者 2026-07-31 决定)

终版 §22(SQLite)与 §30(独立 module)与 main 现状冲突。维护者决定:**保留现状先跑通功能,
迁移任务排在队尾**(TASK-HFA-012/013),而不是先重构再开发。理由是 `PRODUCT-LOOP.md` §12
只在「模块边界导致无法完成真实闭环」时才允许结构性改动;当前 durable file 存储与四处分布
并没有阻塞 GJ-5,先迁移只会推迟修复腿。两个任务的门都写明:**Wave A 全部 done 且 GJ-5 达
`REAL_DEVICE_PASS` 之后才开工**。

> 更新(2026-08-02):TASK-HFA-012/013 均已 done,GJ-5 已于 2026-08-01 r2 真机闭环取得
> `REAL_DEVICE_PASS`(evidence/runs/TASK-HFA-005/run-r2.md);本节自此转为历史记录。

## 安全边界与新增不变量

以下与 Constitution / `AGENTS.md` 禁令、CHG-2026-054 的 HTP-INV-1..12 叠加,不得被解释为放宽:

- **HFA-INV-1**:证据缺失或不可解析时 verdict 只能是 `INCONCLUSIVE`/`ERROR`。
  **"没有在证据里看到崩溃"不等于"没有崩溃"**——criteria 声明的证据产物缺席时判 PASS 一律
  视为产品缺陷。
- **HFA-INV-2**:任何写源码或部署的 decision,执行前必须通过 §11.4 全套前置校验
  (state version、context digest、workspace revision、binding revision、build/deploy digest);
  任一项失配 = stale,**不执行**。
- **HFA-INV-3**:`PROPOSE_PATCH` 的 diff 受 `maxPatchBytes`、文件数、ProjectProfile 声明的
  可写 glob、二进制/符号链接/路径逃逸检查约束;越界整条拒绝,不做截断或"尽力应用"。
- **HFA-INV-4**:补丁应用结果未知时只允许 readback 判定(§18.4 四态),**不得重复 apply**。
  部署或复验失败必须走已声明的 `revertPatch`,不得靠再打一个补丁"盖过去"。
- **HFA-INV-5**:相同 patch digest + 相同 base revision + 相同 build preset + 相同 failure
  fingerprint **不能**通过改写 hypothesis 文本成为新 Attempt;判定为 `DUPLICATE_STRATEGY`。
- **HFA-INV-6**:Analyzer 必须确定性、版本化、无网络、只读其声明的输入 artifact;
  derived artifact 必须带 sourceArtifactIDs/hashes、analyzer ref 与版本、revision 作用域。
  分析结论不得改变 task 状态。
- **HFA-INV-7**:workspace capability 只能收窄,不能授予 runtime 不具备的能力;
  workspace 主体的授权必须绑定 workspace identity + exact base revision + 可写 glob digest +
  materialized plan digest,且沿用既有 reservation/consumption 账本(不建第二套)。
- **HFA-INV-8**:Memory 的 `VERIFIED` 只能由 evaluator `PASS` 或人工确认产生,且必须带
  revision/device/toolchain 作用域与失效条件;超出作用域的 memory 不得进入
  `confirmedFacts.current`。
- **HFA-INV-9**:CHG-2026-054 的 HTP-INV-6(E2 一律人工、E1 只用维护者已签发的 standing
  capability、harness 不自签不续期不扩范围)与 HTP-INV-9(不 push/merge/绕过人工 review)
  在本 change 全程不变。

## 明确不做

- 不做多 Agent / 角色系统 / 图编排 / Workflow DSL / 通用 Plugin SDK;
- 不做向量数据库、跨机调度、第二个 daemon、Sidecar、独立 ArkNG 仓库;
- 不做 Prompt 管理平台或长期聊天 session 作为 memory;
- 不做自动 `git push`/PR/merge,不改 E2 授权语义,不自动化 flash;
- 不新建第二套 artifact/journal/capability/job 状态机;
- 不为命名整洁做 `WorkflowEffect` 重命名(终版 §17.3:先按 `effectRiskClass` +
  `executionDomain` 计算属性兼容,API 稳定后再评估);
- 不改动 GJ-1/GJ-2 已发布 operation 的 step 语义(各自垂直任务推进)。

## 交付顺序与门

```text
Wave A  001 判定源 → 002 防陈旧闸 → 003 修复腿 → 004 Attempt → 005 真机 r2
Wave B  006 三维状态 / 007 Analyzer / 008 workspace 只读族 / 009 workspace 主体 / 010 Memory / 011 厂商 adapter
Wave C  012 SQLite 迁移 → 013 module 抽取
```

硬顺序约束(不可自行放宽):

- **002 必须先于 003**:终版 §25.1 —— 防陈旧闸齐备前不开放无人值守 E1 mutation;
- **001 依赖 TASK-DHA-005 的采集腿合入 main**(当前在 PR #890,未合);合入前 001 保持 `ready`;
- **005 是硬件门**:需已接管设备 + 当前 catalog digest + 维护者经 merged PR 签发的 E1
  standing capability(Agent 不得自签);
- **Wave B 各任务彼此独立**,可按维护者优先级任意穿插,但 007 的 derived artifact 面若先于
  001 落地,001 应改为消费 derived artifact(两条路都留在 001 的 Scope 里说明);
- **Wave C 门 = Wave A 全部 done 且 GJ-5 `REAL_DEVICE_PASS`**。

## 重复搜索结论(§5)

搜索面 = `Catalog/operations/`(12 个 operation)、`DeviceProviders/` 与 `WorkspaceProvider/`、
全部活跃 change 的 `tasks.md`(含 `chg-2026-049` 的 DHA-001..005、`chg-2026-054` 的 HTP-001..007)、
打开的 PR(#890 TASK-DHA-005、#891 TASK-AIN-001)、最近合入提交(#875–#889)、
`openspec/**` 全文检索(`harness|attempt|context hash|analyzer|workspace revision`)。结论:

- **与 CHG-2026-054 无重复**:054 的七个任务全部 `done`,其 Scope 明确不含修复腿接线、
  防陈旧闸、Attempt 实体、Condition 模型、analyzer provider 与 workspace 只读族;
  054 的 TASK-HTP-006 已**如实登记**「部署修复腿未覆盖」,本 change 的 003/005 正是补它;
- **与 CHG-2026-049 TASK-DHA-005 不重复且有依赖**:DHA-005 = 设备侧崩溃台账**采集腿**
  (两个只读 stdout 步骤与两个产物);本 change 的 001 = harness 侧**消费与判定**,
  两者边界清晰,001 在 DHA-005 合入前不开工;
- `chg-2026-025` 的 AIN-011..016 按 §16 = 历史设计记录,不重启;其中"Bounded AI Debug Loop"
  的真正未完成部分由本 change 与 054 共同重做;
- 既有 `HumanActionRequired`、`CleanupDebt`、`RuntimeArtifactStore`、`RuntimeCapability`
  账本**复用不重建**。

## 平台影响

macOS runtime plane only。Windows/Linux 仍 not started。本 change 不改变 HDC server 保护、
device binding 边界、job 状态机/journal/recovery 语义、typed step 与 effect 等级、
artifact/隐私规则;`binding: confirmedDevice` 的既有准入逐条不变。因此不产生新的平台端口义务。

## Out of scope

- GJ-1/GJ-2 剩余产品缺陷(trace 真实收取与校验、HAP lease 链路剩余项)——各自垂直任务;
- E2 / flash 自动化(永久排除);
- App UI 呈现 harness task(CLI + daemon 面先行);
- `analyzer.symbolizeCrash@1`:符号化今天以 `workspace.symbolizeCrash@1` 交付且已 done,
  本 change 不搬家,只在 007 的 design 注记里登记这处与终版 §18.3 表格的命名差异。
