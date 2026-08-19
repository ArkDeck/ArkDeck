# Design — CHG-2026-064

> 本文件是移除/搬迁/保留的**文件级清单与处置规则**，供三个实现 PR 对账。
> 行数为 2026-08-18 审计基线实测值，实现时以当时 HEAD 为准；清单差异不构成
> blocker，按「删除前必 rg」规则如实登记即可。

## 0. 处置规则（判定优先于清单）

1. **执行面不动**：`RuntimeCapability` / `RuntimeJobEngine` 准入、
   `WorkspaceOperationsProvider`、`AnalyzerProvider`、`HumanActionRequired`、
   journal/recovery——零改动（AND-REQ-002，以既有合约测试全绿证明）。
2. **`import ArkDeckHarness` 不是判死刑的充分条件**：逐文件判定「它是宿主面
   还是被宿主面借住的产品能力」。已知三处产品能力借住 Harness/组合层：
   crash-ledger 解析、agent chat 内核、campaign 网关配置——**搬/剥，不删**。
3. **删除 = 删除**（AND-REQ-001）：不留 feature flag、不留空壳协议、不留
   「以防万一」的 fallback。
4. **删除前必 rg**：每个待删符号先枚举全部消费者（生产、测试、脚本、文档、
   字符串引用），孤儿字符串引用（如 evolution 候选路径）一并清理。

## 1. TASK-AND-001：搬家与去耦清单

| # | 源 | 去向 | 判据 |
| --- | --- | --- | --- |
| 1 | `Sources/ArkDeckHarness/Evaluation/HarnessFaultLogLedger.swift`（222 行，`HarnessCrashLedgerDerivedAnalyzer`） | `Sources/ArkDeckWorkflows/AnalyzerProvider/` 邻位（契约类型已在 `ArkDeckRuntime/CrashLedgerAnalysisContracts.swift:50,86`，不动） | 同输入 derived artifact 逐字节一致；`ArkDeckAgentDaemonMain/main.swift:30` 的 `--analyze-crash-ledger` 子命令改 import 后行为不变 |
| 2 | `Sources/ArkDeckHarness/LLM/HarnessAgentLoop.swift` + `HarnessAgentOpenAIGateway.swift`（728 行） | `Sources/ArkDeckWorkflows/AgentComposition/`（`AgentChatApplication.swift:8` 与 `NativeAgentChatRuntimeTools.swift:10` 是仅有消费者） | `arkdeck agent chat` 合约测试（`NativeAgentChatContractTests.swift`，903 行）全绿；env 键名 `ARKDECK_HARNESS_MODEL_*` 不改（命名债登记，不在本 change 处理） |
| 3 | `AgentComposition/EvolutionCampaignHost.swift`（798 行）内的 `HarnessVendorConfiguration` ×3、`HarnessLocalAgentCLIProfile` ×1 | campaign 自持的等价配置类型（或该修复 lane 的配置随 AND-003 一并退场——二选一在实现 PR 定，禁止两可） | 文件零 `import ArkDeckHarness`；campaign lane（CLI `--hardware-campaign`）合约测试全绿 |

搬迁后 `ArkDeckHarness` 仍存在（AND-003 才删），但已无产品能力借住其中。
过时注释一并修正：`HarnessSQLiteDatabase.swift:3`「private to ArkDeckStorage」
随 AND-003 删除自然消失，不必单修。

## 2. TASK-AND-003：删除清单

### 2.1 模块与 target（`Packages/ArkDeckKit/Package.swift`）

- 删 target/library `ArkDeckHarness`（AND-001 搬出后余 ~17,200 行）与
  executable `ArkDeckEvolutionCandidate`（`Sources/ArkDeckHarness/Candidate/`）。
- `ArkDeckAgentComposition`、`ArkDeckAgentDaemon`、`ArkDeckAgentDaemonMain`、
  `ArkDeckContractTests` 的依赖列表去 `ArkDeckHarness`。
- `APIBaseline/Sources/APIBaseline/APIBaseline.swift:14` import 移除，基线再生，
  diff 仅含 Harness 公开面消失。

### 2.2 daemon

| 位置 | 处置 |
| --- | --- |
| `ArkDeckAgentDaemon/HarnessTaskMethods.swift`（57 行） | 删 |
| `ArkDeckAgentDaemon/AgentDaemon.swift`：`:11` import、`:79-81` `harnessCoordinator` 属性、`:106/:123/:144/:161` 构造传递、`:1785-1786` `task.` 前缀路由 | 删；未知 `task.*` 走既有 unknown-method 错误 |
| `ArkDeckAgentDaemonMain/main.swift:735-864` Harness 组合块（store、egress、gateway、coordinator、恢复、auto-drive） | 删 |
| `ArkDeckCore/AgentXPCContract.swift:20` `taskContext` 常量、`:154-163` `forwardableAutomationMethods`（恰四个 `task.*`） | 删；`forwardableMethods` union 去该集合 |

### 2.3 AgentComposition（逐文件裁决，2,510 行 harness 系）

| 文件 | 处置 | 依据 |
| --- | --- | --- |
| `HarnessAdapters/`（4 文件，~700 行：Policy/JobEnginePort/ArtifactStorePort/WorkspaceRepairPort） | 删 | 纯 task 平面端口实现 |
| `LocalAgentCLIGateway.swift`（463 行） | 删 | 自述维护冻结的无人值守通道；配置键移除后显式设置 fail-loud |
| `HarnessVendorComposition.swift`（151 行） | 删 | 决策网关组合 |
| `EvolutionWorkspaceManager.swift`（895 行） | 删（前置：CHG-2026-061 生产可用，或维护者裁决） | harness 侧隔离工作区制备；061 是替代路线 |
| `LocalAgentEvolutionStrategyRepairer.swift`（155 行） | 删 | campaign 的 LLM 修复 lane 适配器，随 gateway 退场；campaign 本体不动 |
| `EvolutionCampaignAttemptIntents.swift`（48 行） | 删前确认：rg 零外部消费者即为死码 | 实测无生产引用 |
| `EvolutionCampaignHost.swift` | **留**（AND-001 已剥离） | 刷机验收 campaign 组合体，CLI lane 消费 |
| `AgentChatApplication.swift` / `NativeAgentChatRuntimeTools.swift` | **留**（AND-001 迁入内核） | chat 产品能力 |
| `RuntimeOwnedWorkspaceDispatcher.swift` | **留** | CHG-2026-061 的 runtime 侧机器 |

### 2.4 CLI

- `ArkDeckRuntimeCommands.swift:2049-2260` `runTask` 块与 help 文案删除；
  `ArkDeckCLIMain.swift:55` 的 `task` 命令注册删除。
- `arkdeck agent chat|run|resume`、`job`、`flash`、`artifact`、`target`、
  `capability`、`trace`、`debug` 等全部不动。

### 2.5 App

- `ArkDeckWorkflows/AutomationApplicationFacade.swift`（296 行）与
  `ArkDeckApp/Features/Automation/AutomationWorkspaceView.swift`（273 行）的
  task 投影删除。Automation 工作区的去留（整删或留空壳导航）在实现 PR 与
  `docs/design/**` 设计稿同车裁决——不得留「有入口无数据源」的假面。
- `Localizable.xcstrings` 相关键清理；`ArkDeck.xcodeproj` 成员同步。

### 2.6 测试

- 删 16 个 `Harness*ContractTests.swift`（13,507 行）。
- `EvolutionCampaignContractTests.swift`（2,861 行）：剔除 harness 部分，
  campaign 本体断言保留。
- `NativeAgentChatContractTests.swift`（903 行）：随 AND-001 改 import，保留。
- `ArchitectureBoundaryContractTests.swift` 改写：删除「Workflows 不见
  Harness / Harness 不见 Process」等双平面断言，**新增**「target 图中不存在
  `ArkDeckHarness`」「生产代码 `import ArkDeckHarness` 命中 0」「job/artifact
  store 无 `HTASK-` 词汇」三条收紧断言。

### 2.7 字符串与文档残留

- `EvolutionCandidatePipeline.swift:152,500`、`EvolutionCampaignAuthority.swift:64,761`
  硬编码的 `Sources/ArkDeckHarness/Candidate/` 允许路径：候选 executable 删除后
  该 lane 的处置（收窄或移除）在实现 PR 内定，禁止悬空路径。
- `README.md` / `README.zh-CN.md`（`:142` 模块清单、「AI 调试循环」能力项）、
  `Packages/ArkDeckKit/LaunchAgents/README.md`、`docs/**` 相关段落改写为
  外部 agent 表述。
- daemon state 下 `harness/` 数据目录：不读不删不迁移；操作者注记进
  LaunchAgents README。

## 3. TASK-AND-002：取证设计

- **形态**：headless 外部 agent（`claude -p` / `codex exec` 任一）+ 既有
  `arkdeck` CLI。不新增任何代码面；发现的产品缺陷垂直修复。
- **底座**：已接管设备 + 已注册 ProjectProfile + 维护者签发的 standing E1
  capability（沿 TASK-HFA-005 r2 的授权形态；Agent 不自签——HTP-INV-6 不变）。
- **证据束**（进 `evidence/runs/TASK-AND-002/`）：agent transcript 全文、
  daemon journal 摘录（每个副作用的 intent/outcome）、`job.list` 时间线、
  产物清单（hash）、`task.*` 调用数为 0 的取证（daemon 方法日志 grep）、
  三层预算在位的逐项说明。
- **负向用例**（AC-6）：一次故意在陈旧 base revision 上提交 `applyPatch`，
  取 runtime 准入的具名拒绝为证——证明防陈旧闸与决策宿主无关。

## 4. 明确不做

- 不做 MCP server（另开 change）；
- 不改 chat 产品形态与 env 键名；
- 不动 `PRODUCT-LOOP.md` / `AGENTS.md` / spec 正本；
- 不迁移、不删除、不解读既有 `harness/` SQLite 数据；
- 不为「删掉的能力可能有人要」保留任何运行时开关。

## 5. 实施勘误(TASK-AND-003 实测,2026-08-19)

按 §0 规则 2/4「删除前必 rg、清单差异如实登记」,实施与 §1/§2 清单的差异:

1. **`EvolutionWorkspaceManager` 保留并去 Harness 化,不删除**——它是
   `workspace.prepare-isolated-copy@1`(CHG-2026-061 路线)的生产实现体,
   AND-002 r2 在真机实证其可用。其依赖的 Evolution 域类型自
   `ArkDeckHarness/Domain/HarnessEvolution.swift` 迁入
   `AgentComposition/EvolutionWorkspaceModel.swift` 并更名
   (`EvolutionWorkspacePolicy`/`EvolutionWorkspaceRecord`/GC 族);manifest
   Codable 键不变,旧工作区可继续 adoption。GC 的任务生命周期证词改为
   `EvolutionWorkspaceGCLifecycle`(rawValue+isTerminal),sweep 机器保留
   (共享工作区存储的卫生能力),其调用面(原 `task.workspace-gc`)移除,
   runtime 侧 GC 面为后续任务。
2. **chat 的任务桥工具随平面移除**——`arkdeck_start_debug_task` 等四个工具
   与 overview 的 `task.list` 投影以字符串方法名指向已删除的 `task.*` 面,
   保留即为运行时假面;AND-REQ-004 的「行为不变」以 AND-001 交割时点为准,
   本任务如实收缩 chat 工具面(observe/capture/artifact/resume 保留)。
3. **`EvolutionCampaignAttemptIntents`/`LocalAgentEvolutionStrategyRepairer`
   在开工前已不存在**(先行 PR 清理),清单相应作废;campaign 本体
   (Workflows 五文件)如 §0 规则 1 承诺零改动。
4. **`agentd update` 即迁移通道**:读取旧 plist 时忽略并丢弃
   `ARKDECK_HARNESS_*` 网关键,再生成即清洁;daemon 对显式残留键具名
   fail-loud(exit 78);合约测试覆盖迁移正例与 CLI flag 具名拒绝。
