---
id: CHG-2026-064-agent-native-decision-plane
revision: 1
status: proposed
class: capability
core_change_level: none
owner: fuhanfeng
core_baseline: CORE-3.0.0
platforms: [macos]
---

# CHG-2026-064 — Agent Native 反转：外部 agent 出大脑，移除 Harness 决策平面

> **本文件不构成批准。** 本 proposal 经维护者 review/merge 进 protected `main`
> 后，各 Task 方可开始实现 PR。merge 同时构成 GJ-5 验收判据重述（见「GJ-5
> 判据重述」节）的批准。

> **恰四类声明**：本 change 不新增 published operation、不新增 provider、不新增
> integration/device profile、不改变 E2 安全策略。它做两件属于控制平面的事：
> ① **移除一组已发布 caller 面**——daemon `task.*` 十七个方法、CLI `task`
> 子命令族、App Automation 工作区的 task 投影（`forwardableAutomationMethods`
> 恰为四个 `task.*`，随之清空）；② **迁移一个已发布 operation 的实现体**——
> `analyzer.extract-crash-signature@1` 的解析实现从 Harness 平面迁入 runtime
> 平面，可观察契约（输入、产物、schema、digest）不变。属「对已发布面的破坏性
> 修改」，按 `AGENTS.md` 控制平面条款走 OpenSpec + 维护者 PR review/merge。
> class 定为 `capability`（对齐引入该平面的 CHG-2026-054/055）；若维护者认为
> 跨平面收缩应按 `integration` 或 `core` 处理，请在 review 时重分类。

## §19 治理循环四问

1. **对应的真实安全风险**：三条，均命中 `PRODUCT-LOOP.md` §3。
   ① **同一「无人值守写源码并消耗 E1」能力存在两份实现**（§3-3/§3-4 的判定面
   变体）：活的一份是 runtime admission（workspace capability 主体 + exact base
   revision，`RuntimeCapability.swift` / `RuntimeJobEngine.swift:6612`）；冻结的
   一份是 Harness 内嵌循环——完整的决策网关、自主 E1 消耗与源码写入路径俱在，
   「冻结」仅由 `LocalAgentCLIGateway.swift:17-21` 的注释维持，没有类型或
   admission 级的强制。ArkForge `architecture.md` 21.3「同一 destructive 路径
   不得双实现」的原则在 CHG-2026-059 已被本仓接受为裁决依据，此处同构。
   ② **厂商 LLM 出站面在 daemon 内存续**（§3-9）：`HarnessVendorGateways` 与
   egress 策略是一个仍需维护的隐私出站面；决策产出方已反转为外部 agent
   （PR #1257）后，这个面只剩维护成本与泄漏面，没有生产收益。
   ③ **内嵌循环的「为人停下」链路可靠性不达标且反复返修**（§3-10 变体）：
   r2（workspace 身份活不过 daemon 重启、「量不到」报成「变了」）与 r3
   （`humanRequired` 队列为空）两轮修复都在补同一类结构性缺陷——跨进程决策
   生命周期的固有复杂度。继续维护它挤占真实设备闭环的优先级（§0）。
2. **为什么不能直接通过 Runtime 代码修复**：这不是缺陷，是边界收缩。移除已
   发布 caller 面、迁移已发布 operation 的实现归属、重述 GJ-5 验收判据，三者
   都是 Repo-plane 变化，`AGENTS.md`/`PRODUCT-LOOP.md` §22 要求先批准再动。
   行为实现（搬迁、删除、真机取证）仍全部是产品代码，不新增治理框架。
3. **推进哪个 Golden Journey**：GJ-5。判据重述后在真机上取得外部 agent 驱动的
   `REAL_DEVICE_PASS`（TASK-AND-002）；同时为 GJ-1—GJ-4 的迭代减负：仓库第二大
   模块（18,117 行源码 + 13,507 行专属合约测试）退出全量构建与测试路径。
4. **为什么不会产生后续连锁任务**：`proposed` 落地，维护者 review/merge 即批准；
   三个垂直任务各自一个实现 PR，代码 + 测试 + 真机结论 + 最小文档同车；
   verification 结论写入同一 PR；不建 readiness-only / status-only /
   verified-only / archive-only PR；归档冻结（§20）。

## Why（根因：「有界闭环」是对的，「循环宿主在 daemon 里」被实践证伪）

CHG-2026-054 引入 Harness 时的根因判断至今成立：GJ-1/GJ-2 修好了「一次执行
是否真实」，而「多次执行之间的收敛」当时连数据模型都不存在，daemon 没有任务
概念，每一轮 debug 的下一步只能由人决定。CHG-2026-055 按终版架构把它补全。
**变化发生在 2026-08 的实践**：宿主选择被三组仓内事实证伪。

### 事实一：决策产出方已经反转，内嵌宿主成为遗留

- PR #1257（TASK-AIN-021，2026-08-11）把「读 `task.context`、在
  `task.proposePatch` 应答的**外部 agent**」定为 GJ-5 一等决策产出方；
- `LocalAgentCLIGateway.swift:17-21` 自述：该通道仅限无人值守且处于**维护
  冻结**，主决策产出方是外部 agent；
- CHG-2026-059 已把 Rockchip lowering 交给 ArkForge——「ArkDeck 批准、别人
  执行」的分离先例已被维护者批准并实施。本 change 是同一运动在认知层的对应：
  **大脑交给外部 agent，手交给 ArkForge，ArkDeck 收敛为权威与证据层。**

### 事实二：内嵌宿主的卡点是结构性的，不是缺陷偶发

GJ-5 运行史上的三类真机卡点，全部源自「把 agent 圈进 daemon」的固有复杂度
——循环状态必须活过进程、上下文必须显式导出、每个决策要有跨进程生命周期：

| 真机卡点 | 根因归属 |
| --- | --- |
| `HTASK-7C12960C4B6E`：停在 `patchProposalRequired` 而人工队列为 0 条 | 内部循环的停机必须显式翻译成人类可见记录（r3 修） |
| `HTASK-C458F21E8B9C`：daemon 重启后派生 profile 注册丢失，三连 `STALE_DECISION`，真因被 `insufficientEvidenceForPatch` 掩盖 | 循环身份必须跨进程持久（r2 修） |
| 「量不到 workspace revision」被断言成「revision 变了」 | 决策与执行分离在两个进程间，观测必须三态化（r2 修） |

外部 agent 模式下这三类问题**结构性消失**：agent 的会话就是上下文，决策
产出即刻提交执行，不存在需要防陈旧的「跨进程决策对象」。执行侧真正需要的
防陈旧闸（补丁必须落在决策所见的 base revision 上）**已经在 runtime 准入面**
（见事实三），与决策宿主无关。

### 事实三：删除在架构上是干净的，安全内核不随葬（2026-08-18 实测盘点）

| 项 | 实测值 |
| --- | --- |
| Harness 是否在设备操作路径上 | **否**。`AgentDaemon.harnessCoordinator` 为 Optional 默认 `nil`，缺席时 `task.*` fail-closed（`AgentDaemon.swift:79-81`）；`job.*`/flash/capture 是平行 switch case |
| 依赖方向 | 单向且被测试锁死：runtime plane 不得依赖 harness plane（`ArchitectureBoundaryContractTests.swift:125-129`）；唯一双面接缝是 `ArkDeckAgentComposition` target |
| 存储耦合 | **零共享 schema**。Harness 用 daemon state 下独立 `harness/` 目录内的私有 SQLite（18 张表）；`ArkDeckStorage` 内 harness 命中为 0 |
| E1 防陈旧闸位置 | runtime 侧：workspace capability 主体（identity + `expectedWorkspaceRevision` + `allowedFileScopesDigest`）在 `ArkDeckCore/RuntimeCapability.swift`，准入在 `RuntimeJobEngine.swift:6612/8221`——**删 Harness 不触碰** |
| spec 正本耦合 | `openspec/specs/**`、`openspec/contracts/**`、`AGENTS.md` 中 harness 命中为 **0**——任务平面从未进入 spec 正本 |
| 规模 | 模块 37 文件 18,117 行；专属测试 16 文件 13,507 行；强相关测试约 4,000 行；`task.*` 端点 17 个；CLI `task` 子命令 17 个；AgentComposition 内 harness 系文件 2,510 行 |

## What changes（三个垂直任务）

### TASK-AND-001 — 搬家与去耦（先解缝，零行为变化）

把「删除会误伤」的三处从 Harness 平面解出来，全部行为不变：

1. `HarnessFaultLogLedger.swift`（222 行）——`analyzer.extract-crash-signature@1`
   的解析实现体——迁入 runtime 平面（`ArkDeckWorkflows` AnalyzerProvider 邻位；
   契约类型本就在 `ArkDeckRuntime/CrashLedgerAnalysisContracts.swift`）。
   同一输入的 derived artifact 逐字节不变。
2. `HarnessAgentLoop.swift` + `HarnessAgentOpenAIGateway.swift`（728 行）——
   `arkdeck agent chat` 的内核，与 task 平面无共享领域模型——整块迁入
   `ArkDeckAgentComposition`。env 键名（`ARKDECK_HARNESS_MODEL_*`）本任务不改，
   命名债另记。
3. `EvolutionCampaignHost.swift`（798 行，刷机验收 campaign 的产品组合体）——
   剥离其对 Harness 的仅有依赖（`HarnessVendorConfiguration` ×3、
   `HarnessLocalAgentCLIProfile` ×1，均为策略修复 lane 的网关配置类型），
   campaign 语义与 lane 行为不变。

### TASK-AND-002 — 外部 agent 真机实证（先证明，后拆除）

在已接管真实设备上，一个 **headless 外部 agent** 会话（`claude -p` 或
`codex exec` 任一）从一条真实缺陷出发，**仅通过已发布 caller 面**完成含修复腿
的完整闭环，循环内人工步骤 0，全程 `task.*` 调用数 0。它证明的命题是：
**反转后的 GJ-5 不需要任务平面**。实证中暴露的产品缺陷在同一任务内垂直修复
（§11：优先修真实运行路径）。按下节判据如实翻转 GJ-5 状态。

### TASK-AND-003 — 移除（证明成立后，删除而非禁用）

删除 Harness 模块、daemon `task.*` 面、CLI `task` 子命令族、App Automation 的
task 投影、AgentComposition 内的 harness 系文件（HarnessAdapters、
LocalAgentCLIGateway、HarnessVendorComposition、EvolutionWorkspaceManager 等）、
16 个专属合约测试文件；架构测试收紧为「harness plane 不存在」；APIBaseline
再生。完整清单与处置规则见 `design.md`。

> 留一份「以防万一」的内嵌循环，等于对同一条无人值守 E1 路径保留两份实现——
> 这正是 CHG-2026-059 拒绝过的形态（AFA-REQ-001「删除而非绕过」），本 change
> 沿用同一纪律。

### 交付顺序与门（不可自行放宽）

```text
AND-001（搬家去耦）──┬──> AND-003（移除）
AND-002（真机实证）──┘
```

- **AND-001 与 AND-002 可并行**；
- **AND-003 的门 = AND-001 done 且 AND-002 取得新判据 `REAL_DEVICE_PASS`**。
  先证明外部路线，再拆除内嵌路线；顺序不可倒置。
- **AND-003 的隔离工作区前置**：CHG-2026-061 的
  `workspace.prepare-isolated-copy@1` 生产可用后，`EvolutionWorkspaceManager`
  的删除才不构成能力回退（061 成为隔离工作区制备的唯一路线）。若维护者裁决
  接受「移除期间无隔离工作区制备路线」，可解除此前置，裁决记录进实现 PR。

## GJ-5 判据重述（本节随 merge 获得批准）

`PRODUCT-LOOP.md` §6 对 GJ-5 的定义是「运行 → 采集 → 分析 → 生成 typed
request → admission → 部署 → 复验 → 有界停止」加一组预算面；它约束**闭环与
有界性**，不约束循环宿主。本 change 重述其验收判据如下：

**GJ-5 `REAL_DEVICE_PASS` 判据（反转后）**：在已接管真实设备与已注册
ProjectProfile 上，一个 headless 外部 agent 会话从一条真实缺陷出发，仅通过
已发布 caller 面完成 观察/采集 → 产物分析 → `workspace.applyPatch`（绑定
exact base revision）→ build → 部署 → 复验 → 终态结论；循环内人工步骤 0
（E0 与已授权 E1）；`task.*` 调用数 0；下表三层预算/停止面全部在位。

| PRODUCT-LOOP §6 预算面 | 反转后的宿主 |
| --- | --- |
| `maxRounds` / `maxWallClock` | 外部 agent 运行时（headless 会话自带轮次/时钟预算） |
| `maxArtifactBytes` | 既有有界采集语义（operation 级，未变） |
| `maxE1Mutations` | `RuntimeCapability`（既有，未变） |
| `allowedOperations` | capability 绑定 operation + workspace allowed-paths digest（既有，未变） |
| `stopOnRepeatedFailure` | agent 运行时的循环纪律 + admission 幂等/重复拒绝（既有） |
| `stopOnOutcomeUnknown` | runtime 既有语义：outcomeUnknown fail-closed、不自动重放（未变） |
| `stopOnHumanActionRequired` / `stopOnAuthorizationRequired` | runtime 拒绝 + `HumanActionRequired` 台账（既有）；agent 停下并如实报告 |

诚实登记：GJ-5 现状 `REAL_DEVICE_PASS` 是**旧判据**（内嵌宿主，2026-08-01/05/06
evidence）下取得的，作为历史记录保留、不改写。本 change 合入后，GJ-5 按新判据
记 `IMPLEMENTING`，直至 TASK-AND-002 在当前 catalog digest 上取得新判据 PASS。
`PRODUCT-LOOP.md` 文本不动（维护者签发文件），冲突按其 §2 兼容说明规则处理。

## Requirements

### AND-REQ-001 — 决策宿主唯一性

ArkDeck SHALL NOT 在自身进程内持有 LLM 决策循环、决策网关、厂商模型出站通道
或 agent 记忆模型（`arkdeck agent chat` 的会话式前端除外，其每个副作用仍逐一
经 admission）。内嵌决策平面 SHALL 被删除而非禁用或绕过；保留任一形式的
fallback 循环等于对同一条无人值守 E1 路径保留两份实现。

### AND-REQ-002 — 安全内核零降级

workspace capability 主体（identity + `expectedWorkspaceRevision` +
`allowedFileScopesDigest`）、E1/E2 capability 预算与过期、workspace
allowed-paths 准入、`HumanActionRequired` 台账、intent-before-effect journal、
outcomeUnknown fail-closed SHALL 全部保持不变。本 change 的任何删除 SHALL NOT
触碰 `RuntimeCapability` 与 `RuntimeJobEngine` 的准入语义；实现 PR 须以既有
合约测试逐条全绿证明。

### AND-REQ-003 — analyzer 实现搬迁、契约不变

`analyzer.extract-crash-signature@1` 的可观察契约（输入、产物形状、schema、
catalog digest）SHALL 不变；实现体 SHALL 迁至 runtime 平面；对同一输入，迁移
前后的 derived artifact SHALL 逐字节一致。

### AND-REQ-004 — chat 与 campaign 去 Harness 化、行为不变

`arkdeck agent chat` 与刷机 Evolution campaign lane 的可观察行为 SHALL 不变；
两者 SHALL NOT 依赖 `ArkDeckHarness`。chat 的 env 配置键名本 change 不改。

### AND-REQ-005 — GJ-5 新判据取证

新判据 `REAL_DEVICE_PASS` SHALL 以 headless 外部 agent 的完整 transcript、
daemon journal 与产物为证：循环内人工步骤 0、`task.*` 调用数 0、每次 E1 消耗
对应有效 capability、每次 `applyPatch` 绑定 exact base revision。任一预算/
停止层缺席 SHALL NOT 记 PASS。Fixture/simulation SHALL NOT 冒充真机结论。

### AND-REQ-006 — 移除完整性

daemon `task.*` 方法、CLI `task` 子命令族、App Automation task 投影、
`ArkDeckHarness` 模块与其私有 SQLite 写入路径 SHALL 删除而非禁用；架构测试
SHALL 收紧为「harness plane 不存在」；APIBaseline SHALL 同步再生。磁盘上既有
`harness/` 数据目录 SHALL 保留（不读、不删、不迁移），daemon 在其存在时正常
启动；已移除的配置键被显式设置时 SHALL 具名 fail-loud（沿 PR #1077 先例）。

## Acceptance

`AND-AC-1..11`，全文见 `verification.md`。对应关系：AND-001 → AC-1..3；
AND-002 → AC-4..6；AND-003 → AC-7..11。

## 强制重复搜索结论（§5）

搜索面 = 活跃 change（CHG-2026-025/054/055/059/061/062/063）、近期合入
（#1257、#1346–#1380）、`Catalog/operations/`、`DeviceProviders/` /
`WorkspaceProvider/` / `AnalyzerProvider/`、全部 `Harness*` 生产与测试文件、
`openspec/**` 全文检索（`harness|HTASK|task plane|automation`）。结论：

- **与 CHG-2026-054/055 不重复**：两 change 已 done 且不重启（§16）。其交付中
  属**执行面**的（`workspace.*` 全族、workspace capability 主体、
  `analyzer.*`、`HumanActionRequired` 生产接线）全部保留；属**宿主面**的
  （循环、网关、记忆、Attempt、Evolution workspace 管理）是本 change 的移除
  对象。归档与 evidence 记录只读留存，不改写。
- **与 TASK-AIN-021 衔接**：PR #1257 的 `task.context`/`task.proposePatch`
  外部产出方入口是过渡态，本 change 完成其终态并移除过渡载体；AIN-021 其余
  交付不受影响，唯 App Automation 工作区的 task 投影随 AND-003 移除。
- **与 CHG-2026-061 互补且构成 AND-003 前置**：061 把隔离工作区制备发布为
  runtime-owned operation；本 change 移除 harness 侧的
  `EvolutionWorkspaceManager` 后，061 是该能力的唯一路线。
- **与 CHG-2026-059/063 同向**：批准/执行分离的第三步；本 change 零新增
  operation/provider，与两者无路径冲突。

## 平台影响

macOS runtime plane only。不改变 HDC server 保护、device binding 边界、job
状态机/journal/recovery 语义、typed step 与 effect 等级、artifact/隐私规则、
E2 授权语义。不产生新的平台端口义务。

## Out of scope

- **MCP server 入口**（`arkdeck mcp`，从 `Catalog/operations/*.json` 生成 tool
  schema）——外部 agent 接口的增量面，另开 change；本 change 的取证走既有 CLI。
- `arkdeck agent chat` 的长期产品形态（内嵌 OpenAI client vs 外接 agent 前端）
  ——本 change 只搬不裁；`ARKDECK_HARNESS_MODEL_*` 键名重命名同属后续。
- `PRODUCT-LOOP.md` / `AGENTS.md` 文本修订（维护者签发文件；判据重述以本
  proposal 为准，§2 兼容注记）。
- ArkForge 仓库侧任何变化。
- GJ-1—GJ-4 已发布 operation 的 step 语义。
- E2 / flash 自动化（永久排除，沿用）。

## Safety, privacy, compatibility and rollback

- **安全**：删除后 AI 进入系统的唯一路径 = 已发布 operation + typed inputs 经
  admission——从「架构测试维持的约定」收紧为「结构事实」。厂商 LLM 出站面自
  daemon 消失。安全内核零改动（AND-REQ-002）。
- **隐私**：`harness/` 私有 SQLite 留在盘上，不读不删不迁移不上传；文档注记
  操作者可自行删除。外部 agent 读到的仍只有既有 caller 面允许的投影。
- **兼容**：`task.*` 的调用方清点 = CLI 自身与 App Automation 投影，均同车
  移除，无第三方调用方。活跃 HTASK 处置：AND-003 实现 PR 附操作者注记——
  升级前以 `task.list` 确认无 active 任务；升级后旧数据只读留存。已移除配置
  键显式设置时具名 fail-loud。`arkdeck agent run/resume`（`AgentRuntimeExecutor`
  路径）与全部 `job.*`/`flash.*`/`artifact.*`/`target.*` 面不受影响。
- **回滚**：AND-001/003 均为纯代码 PR，revert 即回滚；数据目录未动。AND-002
  是证据与缺陷修复，缺陷修复按常规单独可回滚。
- **不回滚的部分**：内嵌循环时期的运行史与两轮返修教训（r2/r3）以 evidence
  留档；判据重述后旧 `REAL_DEVICE_PASS` 作为历史记录可追溯、不改写。
