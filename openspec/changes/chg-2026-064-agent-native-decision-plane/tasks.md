# Tasks — CHG-2026-064

分阶段垂直交付，每个 Task 独立可验。`ready` 只有在本 proposal PR 经维护者
review/merge 进入 protected `main` 后生效；合入前不得开始实现 PR。实现 PR 必须
以 `scripts/check_pr_paths.py --preflight` 用本文件 base-tree 的 Allowed paths
覆盖完整 diff，不得在同一实现 PR 内扩张本声明。

顺序门：AND-001 与 AND-002 可并行；**AND-003 在 AND-001 done 且 AND-002 取得
新判据 `REAL_DEVICE_PASS` 之前不得开工**（先证明外部路线，再拆除内嵌路线）。

## TASK-AND-001 — 搬家与去耦：产品能力迁出 Harness 平面

- Status:ready（仅在本 proposal 经维护者 merge 后方可开始实现 PR）
- Golden Journey:GJ-5（结构前置）；同时保护 GJ-1 的 crash-signature 采集链
- Platform:macos
- Requirements:`AND-REQ-003`（analyzer 搬迁契约不变）、`AND-REQ-004`
  （chat 与 campaign 去 Harness 化）
- Acceptance:`AND-AC-1..3`（见 verification.md）
- Depends on:本 proposal merge
- Applicable failure patterns:
  - `AF-002`（production reachability）——`--analyze-crash-ledger` 子命令与
    `analyzer.extract-crash-signature@1` 的生产路径迁移后必须实测可达，
    不得只在类型层面搬家；
  - `AF-011`（exit 0 ≠ 成功）——「同输入产物逐字节一致」以 hash 对照取证，
    不以测试套件绿作为唯一证据。
- Production reachability:
  `capture.diagnostics@1 → faultlog raw artifact → analyzer.extract-crash-signature@1
   → （迁移后）ArkDeckWorkflows 内解析实现 → crash-signature derived artifact`；
  `arkdeck agent chat → AgentChatApplication → （迁移后）AgentComposition 内
   agent loop/OpenAI gateway → AgentRuntimeExecutor → admission`
- Trusted fact sources:derived artifact 的 sourceArtifactIDs/hash 来自既有
  artifact store；campaign lane 判定事实来自 Workflows 侧
  `EvolutionCampaignAuthority`/`EvolutionCampaignLedger`（不动）；本任务不引入
  新 trusted fact
- Allowed paths:
  - `Packages/ArkDeckKit/Package.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckHarness/**`（仅删除被迁出文件与修
    残留引用；不得新增功能）
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/**`
  - `Packages/ArkDeckKit/Sources/ArkDeckRuntime/**`
  - `Packages/ArkDeckKit/Sources/ArkDeckAgentDaemonMain/**`
  - `Packages/ArkDeckKit/Sources/ArkDeckCLI/**`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/**`
  - `Packages/ArkDeckKit/APIBaseline/**`
  - `openspec/changes/chg-2026-064-agent-native-decision-plane/**`
- Forbidden paths:
  - `Catalog/**`（本任务零 operation 变化；catalog digest 不得漂移）
  - `openspec/constitution.md`、`openspec/specs/**`、`openspec/contracts/**`、
    其他 change 目录、`AGENTS.md`、`PRODUCT-LOOP.md`、`.github/**`
- Risk:medium（纯迁移与剥离，行为零变化由逐字节对照与既有合约测试钉住）
- Hardware required:no
- 交付内容:
  1. `HarnessFaultLogLedger.swift` 解析实现迁入 `ArkDeckWorkflows`
     AnalyzerProvider 邻位；daemon `--analyze-crash-ledger` 子命令随迁；
     同一 faultlog 输入的 crash-signature 产物 hash 对照进 evidence。
  2. `HarnessAgentLoop.swift` + `HarnessAgentOpenAIGateway.swift` 迁入
     `ArkDeckAgentComposition`；`NativeAgentChatContractTests` 全绿；
     env 键名不变。
  3. `EvolutionCampaignHost.swift` 剥离 `HarnessVendorConfiguration` /
     `HarnessLocalAgentCLIProfile`（自持等价类型，或该修复 lane 配置随
     AND-003 退场——实现 PR 内二选一并记录裁决）；campaign lane 合约测试全绿。
  4. 迁移后 `ArkDeckHarness` 内不再有任何被 runtime 平面或 CLI 生产路径
     消费的实现体（rg 取证进 PR 描述）。

## TASK-AND-002 — 外部 agent 真机实证：反转后的 GJ-5 不需要任务平面

- Status:ready（仅在本 proposal 经维护者 merge 后方可开始；与 AND-001 可并行）
- Golden Journey:GJ-5（按重述判据翻转状态的唯一载体）
- Platform:macos
- Requirements:`AND-REQ-002`（安全内核零降级的真机侧证明）、`AND-REQ-005`
  （新判据取证）
- Acceptance:`AND-AC-4..6`
- Depends on:本 proposal merge；已接管真实设备；已注册 ProjectProfile；
  维护者经 merged PR 签发的 standing E1 capability（Agent 不得自签，
  HTP-INV-6 不变）
- Applicable failure patterns:
  - `AF-004`（全链可达）——闭环必须从真实缺陷到真机复验走通，不得以
    fixture/simulation 或部分链路冒充；
  - `AF-008`（信任边界对抗）——负向用例必须真的被 runtime 准入拒绝，
    取具名拒绝码为证；
  - `AF-011`（exit 0 ≠ 成功）——复验结论以设备侧 readback/产物为证，
    不以 agent 自述或命令退出码为证。
- Production reachability:
  `headless 外部 agent（claude -p / codex exec）→ arkdeck CLI → owner-only UDS
   → daemon admission → job engine → typed provider（observe/capture/workspace.
   applyPatch/build/deploy/verify）→ artifact store → agent 读产物 → 下一轮
   typed submit → 有界终态`
- Trusted fact sources:设备身份/binding/firmware 来自 typed production probes；
  workspace revision 来自 provider 度量；capability 消耗来自 runtime 台账；
  agent transcript 只作为过程证据，不作为任何 runtime 事实来源
- Allowed paths:
  - `Packages/ArkDeckKit/Sources/**`（仅限实证中暴露缺陷的垂直修复）
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/**`
  - `docs/**`（最小必要注记）
  - `openspec/changes/chg-2026-064-agent-native-decision-plane/**`
- Forbidden paths:
  - `Catalog/**`（证明前提 = 现有已发布面已足够；发现 operation 缺口时如实
    登记 blocker，不得顺手新增/修改 operation）
  - `Packages/ArkDeckKit/Sources/ArkDeckHarness/**`（本任务不动宿主面——
    实证期间 task 平面保持原样，删除是 AND-003 的事）
  - `openspec/constitution.md`、`openspec/specs/**`、`openspec/contracts/**`、
    其他 change 目录、`AGENTS.md`、`PRODUCT-LOOP.md`、`.github/**`
- Risk:high（真机 E1 mutation 与源码写入；全部经既有 admission，闸门零放宽）
- Hardware required:yes（已接管设备 + 当前 catalog digest；设备 offline 时
  如实保持 `IMPLEMENTING`/`BLOCKED_BY_PRODUCT_DEFECT`，不得记
  `REAL_DEVICE_PASS`）
- Decision-Grade:D1（GJ-5 状态翻转随实现 PR 由维护者 review/merge 批准）
- 交付内容:
  1. 一次 headless 外部 agent 会话完成含修复腿闭环；证据束（transcript、
     journal 摘录、job 时间线、产物 hash、`task.*` 调用数 0 取证、三层预算
     逐项说明）进 `evidence/runs/TASK-AND-002/`。
  2. 负向用例：陈旧 base revision 的 `applyPatch` 被 runtime 准入具名拒绝。
  3. 实证暴露的产品缺陷在同一任务内垂直修复（根因 + 代码 + 测试 + 复跑）。
  4. GJ-5 按新判据如实翻转；旧判据 PASS 记录不改写。

## TASK-AND-003 — 移除 Harness 决策平面

- Status:blocked（门 = TASK-AND-001 done 且 TASK-AND-002 新判据
  `REAL_DEVICE_PASS`；另见隔离工作区前置）
- Golden Journey:GJ-5（终态结构）；GJ-1—GJ-4 共享的迭代减负
- Platform:macos
- Requirements:`AND-REQ-001`（宿主唯一性）、`AND-REQ-002`（安全内核零降级）、
  `AND-REQ-006`（移除完整性）
- Acceptance:`AND-AC-7..11`
- Depends on:TASK-AND-001；TASK-AND-002 `REAL_DEVICE_PASS`；
  CHG-2026-061 `workspace.prepare-isolated-copy@1` 生产可用（否则
  `EvolutionWorkspaceManager` 的删除构成隔离工作区制备能力回退——除非维护者
  在 review 中明示接受该回退并记录裁决）
- Applicable failure patterns:
  - `AF-001`（allowed-paths / 消费者枚举完整性）——删除面横跨模块、daemon、
    CLI、App、测试、工程文件与文档；每个待删符号删除前必 rg，孤儿引用
    （字符串路径、xcstrings、xcodeproj 成员）逐项清点；
  - `AF-002`（生产可达）——「删除后一切仍可达」以全量测试 + `arkdeck` 冒烟
    （job/flash/artifact/agent chat）取证，不以编译通过为证。
- Production reachability:
  `Agent/App/CLI → 已发布 caller 面（operation/job/artifact/target/capability
   五族 + workspace.*/analyzer.*）→ admission → typed provider`；`task.*` 面
  自此不存在，未知方法走既有 unknown-method 错误
- Trusted fact sources:不变（本任务只做减法；不新增任何 trusted fact 或
  判定面）
- Allowed paths:
  - `Packages/ArkDeckKit/Package.swift`
  - `Packages/ArkDeckKit/Sources/**`
  - `Packages/ArkDeckKit/Tests/**`
  - `Packages/ArkDeckKit/APIBaseline/**`
  - `Packages/ArkDeckKit/LaunchAgents/**`（README 操作者注记）
  - `ArkDeckApp/**`、`ArkDeckAppUITests/**`、`ArkDeck.xcodeproj/**`
  - `README.md`、`README.zh-CN.md`、`docs/**`
  - `openspec/changes/chg-2026-064-agent-native-decision-plane/**`
- Forbidden paths:
  - `Catalog/**`（零 operation 变化；digest 不得漂移）
  - `openspec/constitution.md`、`openspec/specs/**`、`openspec/contracts/**`、
    其他 change 目录、`AGENTS.md`、`PRODUCT-LOOP.md`、`.github/**`
  - 既有 daemon state（`harness/` 数据目录不读不删不迁移）
- Risk:medium（大而机械的减法；安全内核零触碰由 AND-AC-9 的既有合约测试
  逐条全绿钉住）
- Hardware required:no（host gates 全量回归；可选真机冒烟不作为门）
- 交付内容:按 `design.md` §2 清单执行：模块与两个 target 删除、daemon 面
  （方法路由 + 组合块 + XPC 允许表）删除、CLI `task` 族删除、App Automation
  投影删除（Automation 工作区去留与设计稿同车裁决，不留假面）、AgentComposition
  逐文件裁决、16 个专属测试删除 + 架构测试收紧改写、APIBaseline 再生、
  README/docs 改写、已移除配置键 fail-loud、操作者升级注记。
