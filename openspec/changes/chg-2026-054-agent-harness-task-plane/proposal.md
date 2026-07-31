---
id: CHG-2026-054-agent-harness-task-plane
revision: 2
status: approved # 携 approved 落地:维护者 review + merge 本 PR 即批准(enforcement 批准语义);merge 前任务不开工。范围过大时在 review 中要求削减并在同一 change 内修订,不新建 change。
# r2(2026-07-31,维护者决定):TASK-HTP-005 开工前发现 host-only(无 target)operation
# 在引擎准入面并不存在 —— catalog schema 允许 operation 级 `binding: none`,准入却对每个
# job 无条件校验设备事实。故拆出 TASK-HTP-007 先行(准入语义 + 唯一消费者
# workspace.inspectSource@1),005 收缩为其余五个 workspace operation。见 What 6/7。
class: capability
core_change_level: none
owner: lvye
core_baseline: CORE-3.0.0
platforms: [macos]
---

# Agent Harness Task Plane:GJ-5 有界自动 Debug 闭环的控制面

> **恰四类声明**:本 change 引入 **新 provider**(`arkdeck-workspace`)与
> **新 operation 面**(`workspace.*`),并为无人值守多轮执行新增三条安全面
> (E1 自主消耗、源码写入范围、artifact 出站隐私)。按 `PRODUCT-LOOP.md` §22 与
> `AGENTS.md` 控制平面条款,这恰属需要 OpenSpec change + 维护者 PR 审批的四类,
> 且与 GJ-5 交付同车。本 change 不产生 readiness/verification/archive 后续载体:
> 任务随各自实现 PR 直接翻 done,verification 结论写入同一实现 PR,归档冻结
> (§20)。

## §19 治理循环四问(新增 Proposal 的强制说明)

1. **对应的真实安全风险**:harness 会在无人值守下**自主消耗已授权 E1**、
   **自主写入源码**、并**把 artifact 摘要送出本机给 LLM**。这三条都不是既有
   runtime 缺陷,而是新的副作用面与新的隐私出站面(命中 §3-3「绕过 E1/E2 授权」、
   §3-4「重复执行未知结果副作用」、§3-8「AI 执行未声明命令」、§3-9「泄漏敏感
   Artifact」)。边界必须先被批准,再写代码。
2. **为什么不能直接用 runtime 代码修**:这不是修一个缺陷,而是新增一个 provider
   与一族 operation。`AGENTS.md`/§22 明文要求这两类走 OpenSpec change + PR;
   直接落代码才是违规路径。控制面的**行为实现**仍然全部是产品代码,不是治理框架。
3. **推进哪个 Golden Journey**:GJ-5(至今零实现——分析器、typed next request、
   预算与成功判定在仓内都不存在),并让 GJ-1/GJ-2 已经能产出的真实 artifact
   第一次拥有自动消费者。
4. **为什么不会产生后续连锁任务**:proposal 携 `approved` 落地(merge 即批准);
   六个任务各自是一个垂直实现 PR(代码 + 测试 + 真机结论 + 文档同车);
   verification 结论写在同一 PR;不建 readiness-only / status-only / verified-only /
   archive-only PR。范式已在 CHG-2026-053 跑通一遍。

## Why(根因:GJ-5 在结构上不存在,不是某个 provider 缺陷)

仓内硬事实(2026-07-30 实测):

- **daemon 方法面没有"任务"概念**。
  `Packages/ArkDeckKit/Sources/ArkDeckAgentDaemon/AgentDaemon.swift:134`
  只有 `operation.*`、`capability.*`、`job.*`、`cleanupDebt.*`、`artifact.*`、
  `target.*` 六族。每一轮 debug 的「下一步」只能由**人**读完 artifact、自己决定、
  再手动 `job.submit`。
- **引擎边界就是单个 job**。
  `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RuntimeJobEngine.swift:341`
  的公开面(`submit`/`run`/`status`/`evidenceSnapshot`/`reconcile`/
  `recoverPersistedJobs`)不含轮次、预算、desired state、成功判定或失败指纹——
  跨 job 的收敛过程**没有任何持久化载体**。
- **当前 runtime 面需要人工时没有一等产物**。
  `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/HumanActionRequired.swift`
  已有 437 行 typed 模型(category / reasonCode / prohibitedAutomation /
  resumeProbe / 状态迁移),但其生产者只有旧的 `TrustedDeviceOperationHost`
  (CHG-2026-025 期);**`RuntimeJobEngine` 与 `job.*` 从不产出它**,daemon 侧只有
  `target.adopt` 的临时 `waitingForHuman` 字符串(`AgentDaemon.swift:738`)。
  运行面遇到真实阻塞时只能失败或停在 outcomeUnknown,没有可恢复、可解析、
  可 resume 的阻塞对象。
- **真实字节没有自动消费者**。#798 起 `artifactContents` 写入真实收取内容,
  GJ-1 的 hilog/ui-dump 已是真数据;但仓内不存在 crash signature 提取、liveness
  判定、指标计算或 typed next request——分析这一步至今 100% 由人完成。
- **因此 §14 的人工预算目标在结构上达不到**:「接管后普通 E0 debug 人工步骤 = 0」
  要求「观测 → 判定 → 下一步 typed request」自动闭合。当前每一轮都要人介入,
  且 daemon 重启后没有任何东西记得「这次调试想达到什么」。

一句话:GJ-1/GJ-2 修的是**一次执行是否真实**;GJ-5 缺的是**多次执行之间的收敛控制**。
后者今天连数据模型都不存在。

## What(交付面)

按「Desired State + Observed State + Reconcile + Typed Operation + Durable Memory +
Deterministic Evaluation + Bounded Recovery」落成一层薄控制面,**不新建 Agent
Framework、不新建第二套 Runtime、不新建守护进程**。

1. **Typed Harness Task 模型与 Task Store**:`HarnessTask`(type/goal/successCriteria/
   desiredState/observedState/budgets/policy/phase/status/version)值对象入
   `ArkDeckCore`;持久化复用 `ArkDeckStorage` 既有 durable file 面
   (`ArkDeckStorage/DurableFiles.swift` 的 fsync/WAL 范式),**不引入 SQLite、不引入向量库**。自然语言只能进
   `intakeDescription`,不能参与执行。
2. **Task Reconciler + TaskStateReducer**:事件/定时/daemon 重启唤醒 → 恢复未完成
   dispatch intent → 构建 observed state → evaluate → 至多**派发一个** effectful
   job → 返回。状态只能由 reducer 迁移,每次迁移持久化 from/to/reasonCode/causation/
   jobId/evaluationId/artifactRefs/consumedBudget/version(乐观锁)。
3. **Evaluation Engine**:唯一有权宣布成功的组件。criterion(metric/operator/
   expected/minimumSamples/observationWindow/evidenceRequirements/mandatory/
   inconclusivePolicy)+ verdict `PASS|FAIL|INCONCLUSIVE|ERROR`;observation 由
   **真实 artifact 字节**构建(crash signature、liveness、build/deploy digest 一致性)。
4. **Policy & Budget Guard + Failure Memory + HumanActionRequired 首个生产者**:
   allowedOperations / availability / typed inputs / target binding / effect ceiling /
   `maxRounds`·`maxWallClock`·`maxArtifactBytes`·`maxE1Mutations` / 失败指纹与
   no-progress 检测 / raw-command 面拒绝;所有真实阻塞产出结构化
   `HumanActionRequired`(既有 437 行模型第一次在 runtime 面被生产与消费,
   零新模型)。
5. **LLM Decision Gateway**:无状态决策端口。输入 = 有界 `DecisionContext`,
   输出 = 四类之一 `INVOKE_OPERATION | PROPOSE_PATCH | REQUEST_HUMAN | NO_SAFE_ACTION`,
   经严格 schema 校验后才可能进入 Policy Guard。**出站默认 deny**;未开启出站时
   harness 退化为确定性内建策略仍可跑 E0 收敛闭环(即模型不可用不等于闭环停摆)。
6. **host-only(无 target)准入语义**(r2 新增,TASK-HTP-007):引擎当前对**每个** job
   无条件解析并校验真实设备事实(`materializeTypedPlanBeforeAuthorization` →
   `validateEvidenceFacts`:要求匹配 targetID、**非空 expectedBindingRevision**、非空
   connectKey、合法 deviceIdentity sha256、工具版本与 hash)。而 catalog schema 里
   operation 级 `binding: none` 是合法值 —— 也就是说 schema 承诺了一个准入面从未实现的
   形态。workspace 面全是 host 操作,没有 connectKey、没有设备身份,因此**不是加法**:
   先要有这条路径 —— `binding: none` 的准入语义、无 target 的 facts/journal/concurrency
   规则,以及「host-only operation 里出现任何设备 step 即 fail closed」。与**唯一消费者**
   `workspace.inspectSource@1` 同车交付(引擎只从生成的静态 catalog 取 descriptor,
   没有真实 operation 就测不到这条路径)。
   **设备绑定不放宽**:`binding: confirmedDevice` 的准入逐条不变,新路径只对声明
   `binding: none` 的 operation 可达。
7. **新 provider `arkdeck-workspace` 的其余 `workspace.*` operations**(TASK-HTP-005):
   `applyPatch` / `buildOpenHarmony` / `runTests` / `symbolizeCrash` / `revertPatch`。
   全部经 **ProjectProfile 内的 preset** lowering,参数由 provider 生成;LLM/CLI/App
   提交零 argv。这是"AI 自动化推进项目"的执行面:AI 能在本机完成 patch → build → test
   并产出可 review 的分支与证据包,**push/PR/merge 仍然是人**。
8. **`task.*` daemon 方法与 CLI**:`submit`/`list`/`status`/`result`/`cancel`/
   `pause`/`resume`/`reconcile`/`events`/`humanAction.resolve`。`job.*` 原样保留为
   底层安全执行原语。
9. **三层 Memory**:task / project / failure。写入需证据引用(jobId、artifactId、
   evaluationId、workspace revision);project memory 只接收 evaluator PASS 或人工
   确认过的结论。检索用精确指纹 + 既有文件索引,不引入检索基础设施。

### 命名冲突必须先钉死

仓内 `TASK-*` 是 **Git 治理任务**;本 change 的 Harness Task 是 **runtime 调试任务**
(ID 前缀 `HTASK-`)。二者是两个命名空间。runtime 请求中只允许出现
`clientContext.provenance.harnessTaskId` 作为 correlation,**不参与 admission、
授权或执行决策**——§13「Runtime 与 Repo 治理彻底分离」不变。

## 安全边界与新增不变量

以下为本 change 引入的不变量,与 Constitution / `AGENTS.md` 禁令叠加,不得被解释为放宽:

- **HTP-INV-1**:LLM 输出只是**提议**。不得携带 task/job 状态、retry 计数、
  raw command、成功结论或授权结果;携带即整条 decision 拒绝。
- **HTP-INV-2**:只有 Evaluation Engine 能使 task 进入 `SUCCEEDED`;
  `INCONCLUSIVE` 永不等于成功。
- **HTP-INV-3**:一个 task 同一时刻最多一个 effectful active job;一次 reconcile
  最多派发一个新 effectful job。
- **HTP-INV-4**:副作用前必须先持久化 dispatch intent 与稳定 `idempotencyKey`;
  崩溃恢复只允许用**原 key** 重投,由引擎去重。
- **HTP-INV-5**:`outcomeUnknown` 立即停止并产出 `HumanActionRequired`,
  **永不自动重发原副作用**。
- **HTP-INV-6**:harness **永不** draft / install / consume E2;E2 一律
  `HumanActionRequired`。E1 只能使用维护者经 merged PR 已签发的 standing
  capability,受 `maxE1Mutations` 约束;harness 不得自签、不得续期、不得扩范围。
- **HTP-INV-7**:capability 不得在 provider 或 plan 不可用时被消耗(§8
  Availability First);harness 只把 `AVAILABLE` 的 operation 提供给决策。
- **HTP-INV-8**:`workspace.applyPatch` 只能写入 ProjectProfile 声明的 glob 内
  文件,越界 fail closed;每次 apply 产出 applied-patch artifact 且可 `revertPatch`。
- **HTP-INV-9**:harness 不执行 `git push`/`merge`/force,不创建或合并 PR,
  不绕过最终人工代码 review。
- **HTP-INV-10**:出站(LLM)默认 deny。开启后 `DecisionContext` 只允许携带
  **脱敏、有界**的摘要与 artifact 引用;不得携带原始未脱敏字节、设备标识、
  凭据或超出声明上限的内容。artifact 内容真相仍只在 `RuntimeArtifactStore`。
- **HTP-INV-11**:harness 不新增 raw command 面。`workspace.*` 与设备 operation
  一样只经受版本控制的 provider lowering。
- **HTP-INV-12**:`harnessTaskId` 不参与 runtime 授权(见上「命名冲突」)。

## 明确不做(§12 / §19 / §20 边界)

- 不做图编排 / 多 Agent 对话 / 角色系统 / Workflow DSL / 动态插件;
- 不做新 Evidence Schema、新 Acceptance 体系、新 Verification 框架;
- 不做第二个 artifact 系统、第二个 journal、第二个 daemon;
- 不引入 SQLite、向量库、分布式 worker、跨机调度;
- 不把 MCP 作为内部执行总线(MCP 只可作为外部适配层调用 `task.*`);
- 不做自动 git push / PR / merge;
- 不做 system `.so`、Rockchip 扩展、新平台端口、大规模 App UI;
- 不改动任何已发布 operation 的 step 语义(GJ-1/GJ-2 面按各自任务推进)。

## 与现有模块的映射(不新建 Package)

| 交付面 | 放置位置 | 复用 |
| --- | --- | --- |
| Task/Goal/Criteria/Decision 值对象 | `ArkDeckCore` | 既有 JSON/Target/Effect 基础类型 |
| Reconciler / Handler / Evaluation / Memory | `ArkDeckWorkflows/AgentHarness` | `RuntimeJobEngine`、Catalog、Provider 契约 |
| Task Store / Memory Store | `ArkDeckStorage` | `DurableFiles`、`StrictJSON`、session layout |
| `task.*` 接口与恢复启动 | `ArkDeckAgentDaemon` | 既有 UDS 单实例控制平面与 composition root |
| Workspace 执行 | `ArkDeckWorkflows/DeviceProviders` 同层新 provider | `DescriptorBoundProcessDispatcher` 真 spawn 与身份校验 |
| Artifact | 既有 `RuntimeArtifactStore` | hash / retention / privacy / redaction / quota |
| 人工阻塞 | 既有 `HumanActionRequired` | 直接作为一等产物,零新模型 |

## 交付顺序与 §20 冻结门(不自行放宽)

`PRODUCT-LOOP.md` §20 的允许清单在 GJ-1/GJ-2 达到 `REAL_DEVICE_PASS` 前是**穷举**的,
不含 harness。因此:

- **本 PR 只交付审批与边界**(openspec-only,零产品代码),审批不占用产品时间,
  且新 provider/新 operation 必须先审批后实现;
- **实现开工门 = GJ-1 与 GJ-2 均 `REAL_DEVICE_PASS`**(§20 解冻)。各任务
  `- Gate:` 行如实登记该门,由实现 PR 记录门已满足;
- 若维护者选择**提前解冻**(例如 GJ-1 已 `REAL_DEVICE_PASS`、GJ-2 仍在推进时先开
  TASK-HTP-001/002——二者 E0-only、零设备 mutation、零源码写入),该判断权在维护者;
  proposal 不自行放宽,实现 PR 必须写明依据。

门的判定**不通过 status-only PR 维护**:任务保持 `ready`,由实现 PR 一次翻 `done`。

r2 交付顺序(001–004 已合入):

```text
007 host-only 准入 + workspace.inspectSource@1(唯一消费者同车)
  → 005 其余 workspace.*(applyPatch / build / runTests / symbolize / revert)+ preset
  → 006 真机端到端 GJ-5 收敛(硬门:GJ-1/GJ-2 REAL_DEVICE_PASS)
```

## 重复搜索结论(§5)

搜索面 = `Catalog/operations/`(6 个 operation,无 workspace 面)、
`DeviceProviders/`(仅 HDC + Rockchip)、活跃 change 的 tasks.md、
最近合入提交(#798/#824/#825/#826/#843)、`openspec/**` 全文
(`Bounded AI Debug Loop|harness|debug loop`)。结论:

- **无语义重复**:仓内不存在任务级控制面、evaluation、memory、decision gateway
  或 workspace provider 的实现或在办任务;
- `chg-2026-025` 的 AIN-004/012/013 等按 §16 = **历史设计记录**,不重启、不刷新
  readiness;其中真正未完成的「Bounded AI Debug Loop」正是本 change 重做的对象;
- `chg-2026-049` 的 DHA 任务面 = GJ-1/GJ-2 诊断与 HAP,与本 change 不重叠;
- 既有 `HumanActionRequired` 与 `CleanupDebt` 台账**复用不重建**。

## 平台影响

macOS runtime plane only。Windows/Linux 仍 not started:本 change 不改变 HDC server
保护、device binding 边界、job 状态机/journal/recovery 语义、typed step 与 effect
等级、artifact/隐私规则,因此不产生新的平台端口义务。

## Out of scope

- GJ-1/GJ-2 剩余产品缺陷(`hdc install` 语义核实、trace 真实收取、lease 链路)——
  各自垂直任务;
- 已发布 operation 的 step 语义修订;
- E2 / flash 的自动化(永久排除:E2 一律人工,见 HTP-INV-6);
- App UI 呈现 harness task(CLI + daemon 面先行);
- Project Memory 的规模化检索(等到有真实规模再谈,见「明确不做」)。
