# 任务指令：macOS 端 Rust 迁移链收口到 G5

版本：2026-09-13（起点 protected `main` ≥ `6bb0d0eb`）。本文是交给执行 Agent 的任务提示词，
对应 [CHG-2026-074](../../../openspec/changes/chg-2026-074-shared-rust-runtime-core/proposal.md) 的
macOS 迁移链；它取代 2026-09-10 交给执行方的仓外交接稿。那份稿子里关于 Allowed paths 探测、
`Scope-Extension`、7 个 nightly 日、同 release Swift 回滚演练、`--baseline-revision` re-pin 的规矩
**全部作废**，原因见 §2。本文不是规范：Task 定义以 `tasks.md` 为准，安全规则以 Constitution 与
`PRODUCT-LOOP.md` 为准；本文与它们冲突时以它们为准并回改本文。

起点包含：CHG-2026-077 路径护栏退役（#1882）、XPA-013 durable Import（#1881）、XPA-012 cleanup apply
（#1880）、XPA-014 Job snapshot（#1879）、XPA-002 contract 视图去重（#1878）、AIN-022 main run 不取消
（#1883）。

你是 Repo Agent，以循环方式推进 CHG-2026-074 的 macOS 迁移链，直到 G5 达成：

> **G5 = TASK-XPA-017 done**：GJ-1..5 在纯 Rust daemon 上、当前 Catalog digest 上 headless
> `REAL_DEVICE_PASS`；`ArkDeckAgentDaemon`、`ArkDeckAgentDaemonMain`、`ArkDeckWorkflows` 引擎部分、
> `ArkDeckStorage`、`ArkDeckProcess`、`ArkDeckOpenHarmony` target 与 Swift fixtures 删除；Swift CLI 删除
> （018）；App 不再 `import ArkDeckWorkflows`（019）；性能车道跑在 Rust daemon 上（025）；LaunchAgent
> 永久指向 Rust 二进制；`openspec/verification/traceability.md` macOS 列与 `PLATFORM-PROFILES.lock.yaml`
> 在 017 翻转。仓内只剩一份 Runtime 语义实现、一份 ArkForge codec。

你不能合并、不能自批、不能标 approved/verified；合入才是批准。G5 之前不碰任何 Windows 任务（r8）。
每完成一个可运行切片就交一个 PR；CI 绿了不等合入，立刻开下一个不依赖合入的切片（见 §5.4）。

---

## 0. 当前状态（2026-09-13 实测，动手前用 `tasks.md` 与 `evidence/runs/` 复核）

| Task | Status（tasks.md） | 已在 `main` 上的能力 | 必须补齐的能力 |
|---|---|---|---|
| XPA-001 / 003 / 023 | done | 96 逐方法 schema；Rust façade 拥有公共 UDS + Mach service，转发同 release Swift daemon，GJ-1..5 经 façade PASS（09-09/10）；perf harness 与基线 | — |
| XPA-002 | in-progress | macOS read-only foundation、rust CI 车道、contract 视图 | 只剩 Windows 验收（SPK-3），在 017 之后，**本指令不含** |
| XPA-012 | in-progress | 隔离 Rust owner 服务 `history.filter.*`、`runtime.storage.*`、`session.list/show/pin/unpin`、`session.cleanup.preview/apply`、`session.export.preview/apply`、`trace cache status`、Bootstrap tool/bundle inspect、DevEco/HDC `runtime tool register`、`runtime tool list/remove`、`runtime bundle list/register/retire`、`target list/show`、`target display-name set/clear` | `trace cache purge` 与 trace 数据库准备、tool selection 等剩余 host-store 写路径、**安装态组合**（façade 本地服务这些 store、Swift daemon 不再打开它们）、GJ-1 re-pass |
| XPA-013 | in-progress | Job Artifact 读库、`artifact.inspect/read`（经 Job owner 路由）、`artifact.export` 到外部目录、`artifact.import.begin/append/abort/inspect`（Target owner 解析 binding） | `artifact.import.commit`/私有 `artifact.publish`、`release`、`artifact.import.inspection`、lease、quota/retention、active-use、GC/cleanup-debt、canonical alias HDC route、owner 切换、写路径 crash-window、GJ-1/2/3 re-pass |
| XPA-014 | in-progress | Rust 读 v1 SQLite Job 索引：`job.list/status/show/timeline/evidence`、`job events` cursor、publication facts、Artifact 路由；未知字段拒绝 | admission 顺序与 `job.plan` digest 对齐、journal 写者（fsync/tail cursor/torn-tail 修复）、SQLite 写（`user_version` 不动）、capability mint/reserve/consume、recovery（先过维护者门）、agent execution 协调、executor 交接、§G.4 cutover preflight、GJ-1..5 |
| XPA-018 | in-progress | Rust CLI：`doctor`、`operation list/describe/example`、`device candidates`、`job status/list/show/evidence/timeline/events`、history/session/runtime storage/tool/bundle/trace cache/artifact/target 各 leaf | 其余全部 leaf（agent、capability、human-action、workspace、debug、flash、recovery、runtime service/hdc、trace probe/capture/inspect、ui-dump、signing、`maintainer contracts export` 零漂移…）、`cli-feature-coverage.json` macOS `fullFunction`、Swift CLI 删除（先过 L.1 第 7 条）、GJ-1..5 用 Rust CLI headless |
| XPA-015 | blocked（依赖 014） | HDC 观测/解析与进程基础 | analyzer/workspace provider（Keychain `SecItem*`、HAR 存在性门、registered toolchain 替代 `/usr/bin/git`）、GJ-5 |
| XPA-016 | blocked（依赖 015） | `arkdeck-provider-hdc` 只读观测 | HDC provider 全量、supervisor observation（libproc）、process executor（`/.vol/<dev>/<ino>` 启动、PTY 秘密交换、持久 shell 通道）、target adopt 的 USB 附着证明与 identity readback、GJ-1/2/3 |
| XPA-019 | blocked（依赖 014，逐 facade） | 无 `ArkDeckClientKit` target；App 23 个文件 `import ArkDeckWorkflows`；Workflows 里 13 个 App-facing facade | ClientKit target（生成 typed 模型 + `xpc_connection` 传输 + presentation adapter）、13 个 facade 逐个切换、UI 测试 |
| XPA-025 | blocked（依赖 014、023） | `rust-perf.yml` 仍用 SwiftPM 构建 `arkdeck-agentd` 与 `ArkDeckRuntimeSoakFixture`；microbenchmarks 只在 main 跑（#1877） | Rust `arkdeck-soak`、`scripts/bench` 对 cargo 构建的 daemon 采集、参考主机重取基线、三车道绿 |
| XPA-017 | blocked（依赖 016、018、019、025） | — | ArkForge lane 直接消费 `arkforge-client`；删 Swift target；LaunchAgent 永久 Rust；DMG；车道退役；lock/traceability 翻转；G5 |

安装态事实：`launchctl print gui/$UID/com.arkdeck.agentd` 显示当前 program 是
`~/Library/Application Support/ArkDeck/Helpers/ArkDeckAgent.app/Contents/MacOS/arkdeck-facade`
（XPA-003 的 façade 对）。Rust `arkdeck-agentd` 二进制三种模式（`rust/crates/arkdeck-agentd/src/main.rs`）：
`ARKDECK_DEVELOPMENT_STATE_ROOT` 存在 → 隔离 Rust owner（拒绝 Swift 配对与 HDC 配置，`ARKDECK_ENDPOINT`
必须在该根目录内且不在 `~/Library/Application Support/ArkDeck` 下）；否则旁边有 Swift 可执行文件 →
façade 转发；否则独立 daemon。**终局是第三种模式接管 LaunchAgent，façade 与 Swift 消失。**

遗留工作区（维护者参考主机上的临时目录，可能已清理；实施前先看，别重做）：
- `/private/tmp/arkdeck-xpa012-trace-maintenance-20260912`（commit `7ac34ec7`）与
  `/private/tmp/xpa012-maintenance-before-combine-20260912.bundle`：Trace maintenance/purge 的候选实现，
  被拆出 #1880 后未再交付。`git -C <path> diff origin/main --stat` 评估可复用部分，再决定重用还是重写。
- `/private/tmp/arkdeck-xpa-native-validation-20260912`：11 个未提交 Swift 改动（Bootstrap display name
  与多份 contract test），可能是 #1870/#1880 的原始 producer 改动。逐文件 `git diff origin/main` 核对，
  已在 main 的丢弃，未在 main 的判断归属。
- 其他会话的 worktree（`git worktree list` 里非本会话的目录）只读，不动；有重叠先看
  `gh pr list --state open`。

设备事实：DAYU200 `TGT-958780b2ffb7`，固件 `OpenHarmony-7.0.0.37`，hdc `3.2.0f`，Catalog digest
`508783ac…`（`arkdeck operation list --output json` 复核）；binding revision 每次用 `target show` 重读；
GJ-1..5 已在该 digest 上 PASS（09-02/03 Swift、09-09/10 façade）。设备在不在：
`arkdeck runtime hdc status --output json`、`arkdeck device candidates --output json`、
`ioreg -r -c IOUSBHostDevice`。不在时做 host 侧工作并如实写「未接设备」，不把它写成阻塞。

---

## 1. 必读（读完再动手；每个 Task 开工前重读它的小节）

1. `AGENTS.md`（已拆分：提交规则在 `scripts/agent-guides/contributing.md`，真机/App 验收在
   `scripts/agent-guides/acceptance.md`，按表按需读）；`PRODUCT-LOOP.md` §2、§4、§6、§16、§19。
2. `openspec/changes/chg-2026-074-shared-rust-runtime-core/`：`proposal.md` 的 Revision 6–10 与
   Governance loop；`tasks.md` 头部约定（含 r8/r9/**r10** 段）与每个 Task 完整小节；`verification.md`
   的 XPA-AC-1..10（r10 已改 AC-1/AC-9 解释）；`evidence/README.md`；`evidence/macos-remaining.md`；
   `evidence/runs/TASK-XPA-0{03,12,13,14,18}/` 的全部 run 记录（你继承的状态与已知残留）。
3. 设计文档 [`rust-core-cross-platform-architecture.md`](rust-core-cross-platform-architecture.md)：§D、
   §E.2/E.3、§F、**§G.1–G.5（r10 路线 A/B/C、数据边界、shadow 白名单、cutover 处理、执行链验证）**、
   §H（019）、§I（025）、§J.4 各 Task 行、§J.5 gate 表、§K、§L.1。
4. `docs/adr/0005-agentd-uds-control-plane.md`；`docs/adr/0007-artifact-lifecycle.md`（013）；
   `docs/adr/0009-campaign-unknown-outcome-authority.md`（014 前必读，头部注记 = 未裁决项）。
5. `docs/design/cli-golden-journey-headless-runbook.md`（§0、§1、§2–§6、§7）与记录先例
   `docs/design/references/single-v1/gj-headless-rerun-2026-09-{09,10}-xpa003.json`、
   `docs/design/references/v1.6-goal/real-device-validation.md` 的 2026-09-02 段。
6. CLI 规格 `docs/design/arkdeck-cli-product-spec.md` §12（版本/弃用/tombstone）、§14/§15/§18（018）；
   `openspec/contracts/cli-command-registry.yaml`、`cli-feature-coverage.json`（256 条 entry，
   `implementationStatusByPlatform` 是 parity 台账）。
7. `rust/README.md`（构建、检查、每个已迁移 owner 的用法与 `rust/scripts/check-*.py` 进程 harness）、
   `rust/supply-chain/README.md`；Swift 侧要移植的模块：`Packages/ArkDeckKit/Sources/{ArkDeckStorage,
   ArkDeckWorkflows,ArkDeckAgentDaemon,ArkDeckAgentDaemonMain,ArkDeckProcess,ArkDeckOpenHarmony,
   ArkDeckBootstrap,ArkDeckRuntime,ArkDeckCore}`。关键落点：`RuntimeJobEngine.swift`（10.9k 行）、
   `RuntimeRecoveryService.swift`、`AgentExecutionCoordinator.swift`、Workflows 下 `ArkForge*.swift`、
   `AnalyzerProvider/`、`WorkspaceProvider/`、`DeviceProviders/`；Storage 下 `RuntimeJobRepository`、
   `JournalEvent*`、`DurableFiles`、`RecoveryManifestContract`、`RuntimeCapabilityStore`、
   `ArtifactStorage`、`RetentionAndExport`；OpenHarmony 下 `HDC*`；Process 下 `IdentityBound*`、
   `PersistentDeviceShellChannel`。

---

## 2. 2026-09-10 之后改掉的规矩（照旧文档做会错）

1. **路径护栏已退役（CHG-2026-077，#1876/#1882）**：仓内没有 `check_pr_paths.py`、没有 allowed-paths
   job、没有 preflight、没有 `Scope-Extension:` trailer、不开 scope PR、不扩写 Allowed paths。Task 的
   Allowed/Forbidden paths 只是作者预计触及范围的**规划声明**：实现需要碰表外文件就直接改，在最终 commit
   正文说明为什么。改动范围由维护者在真实 diff 上 review。`Forbidden paths` 里的安全内核面（specs、
   constitution、Catalog、entitlements、`user_version`）仍然不碰，那是安全规则不是路径规则。
2. **r10（tasks.md/design §G.1/verification.md，#1841 合入）**：产品未发布，普通现有状态是可重建测试数据。
   取消：7 个 nightly 日 shadow 等待、每个 cutover 的同 release Swift 回滚演练、全量旧数据互读目标。
   保留：现有 differential/shadow 语料作快速回归、真实 Rust 写入 + 重启读回 + CAS/锁 + 原子发布 +
   关键崩溃窗口作为开发判据、真机安全（切换前停止旧执行、机械检查未决副作用、唯一 authority、
   unknown 不重放、新目录不能让同一设备的 intent/reservation/outcome 消失）。路线：**A** 隔离根内跑通
   host/artifact/Job 核心 + HDC Observe/Diagnostics + CLI；**B** 按实际接口依赖补齐 Debug、native library、
   workspace/analyzer、ArkForge，同步接 ClientKit、性能、soak，**能直接实现 Rust 路径时不额外建设完整
   Swift sidecar**；**C** 消费方全部脱离后删 Swift runtime/CLI 与 façade，再做最终 GJ-1..5、App UI、
   安装签名、IPC 身份、恢复验证。中间态不要求可发布，但每个合入的 PR 都必须让 `main` 可构建、
   全绿、façade 对仍能服务现有 App/CLI。
3. **contract manifest 语义（#1866/#1878）**：`spec/baselines/swift-single-v1.json` 描述「它所在的
   checkout」（schema `arkdeck.swift-development-baseline/2`，无 commit 字段）。改了任何被消费的输入
   （`Packages/ArkDeckKit/Contracts/control-protocol.json`、`spec/control/methods/**`、ControlFrames
   语料、CLI argv 语料…）就在**同一个 change 里**跑 `python rust/scripts/generate-contract.py --write`，
   `--check` 必须零 diff；`--baseline-revision` 已删除；published 视图 = `git merge-base origin/main HEAD`，
   别人合入不再让你的分支变 stale，**不再需要 re-pin PR**。
4. **工具链与 CI**：`rust/rust-toolchain.toml` 跟随 `stable`；required checks = SDD Guard 的 `guard` +
   Swift CI 的 `swift` 聚合 job（rust 车道是 `rust-ci.yml` 的 `workflow_call`，在 `swift` 聚合内，
   `gh run list --workflow rust-ci.yml` 永远为空，用 `gh pr checks <N> --json name,bucket,workflow`）；
   main 上的 run 不再被后续合入取消；perf microbenchmarks 只在 main 跑。
5. **PR 由 push 自动开**：推到 `agent/**` 分支，`.github/workflows/agent-pr.yml` 以 `github-actions[bot]`
   开 PR，标题 = HEAD commit subject，正文 = 固定模板 + 从 subject 抽出的 `Task:` 行。**完整说明只能写在
   最终 commit message 正文里**。禁止任何 `gh` 写操作（用 gh 开/改 PR、review、merge、rerun、api POST）；
   本仓 `.claude/settings.json` 的 PreToolUse hook 会直接拒绝含 gh 开 PR 字面量的 Bash 命令（含 heredoc
   内容），写含该字面量的文档用编辑器工具。

---

## 3. 每个切片都适用的硬规则

- **A4**：runtime 实现更换后，同一 digest 上受影响的 GJ 必须重新 `REAL_DEVICE_PASS`；fixture/shadow/
  plan-only/隔离根都不算。每个 Task 的 Acceptance 行写了要 re-pass 哪些 GJ；切片级 PR 不要求真机，
  Task 收口 PR 要求。
- **§G.2 冻结**：到 017 之前禁止 durable schema、`user_version`、键集合漂移；Rust 写出与 Swift
  `CodingKeys` 完全相同的键集合；每个 owner 保留「多一键 → 拒绝」负例。确需改字段：同一 change 内同步
  双方 + 全部向量 + 重生成 manifest，并在 commit 正文点名，不悄悄加。
- **§G.3 shadow 白名单**：只比较 `job.plan`（plan-only 零派发）、`operation.list/describe`、
  `device.observations`、`job.list/status/evidence/timeline`、`artifact.list/inspect`、各 decoder、
  canonical/digest、CLI envelope。禁止 `deviceMutation/destructive` 双跑、durable 双写、capability
  reserve/consume 双跑。
- **§G.4 cutover preflight**（014 起、每次真实设备激活前）：阻断集 `queued/preflight/running/
  waitingForDevice/awaitingRebindConfirmation/planning/cancelRequested/cancellingAtSafeBoundary/
  reconciling/recoveringByCompleteOverwrite/resumeAtConfirmedSafeBoundary/userAbandonRequested/
  finalizing` + 未决 intent + running agent execution + reserved 未 settle 的 capability use → 拒绝
  切换并列出 Job；parked 集 `waitingForRecovery`/`outcomeUnknown` 与全部终态原样承接、永不 replay；
  recovery epoch 从已有最高计数继续；切换前保留或明确归档旧目录并记录快照摘要。谓词放进共享状态表，
  两个实现同一份。
- **零派发与 fail closed**：任何 step 没有 durable intent 不得派发；两个 owner 写同一 SQLite、两个进程
  持有同一 store lock、Swift 引擎直接写 `index.json`（013 之后）都是停止条件。unknown 不等于零执行。
- **安全内核不动**：不改 `openspec/specs/**`、constitution、`Catalog/**`、`ArkDeckApp.entitlements`；
  不创建/修改 capability、trusted facts、hardware evidence；不手改
  `~/Library/Application Support/ArkDeck/` 下任何 Runtime/凭据状态；不 `flash install-binding --rebind`；
  不清空或更换安装态 state 目录；secret 不进 argv/env/receipt/日志/evidence。
- **真机**：只用 `arkdeck agent run`/`agent resume` 与已发布 typed 命令；GJ-4 是破坏性刷机，每次开窗前
  维护者明确说 go，用 DEC-014 入口 `runtime service update … --arkforge-campaign gj4-xpa0NN-<date>`
  开窗（`operation list` 30/30），跑完不带 campaign 再 update 关窗（28/30）；DEC-016 允许具名 campaign
  在四小时预算后授权 complete-overwrite recovery epoch，准入被拒时按 `capability list`/`job show`/
  `recovery flash-invocation` 读出原因并报告。记录只放脱敏 target 身份。
- **一个切片一个 PR，一个 PR 一个 Task token**；每个合入后的 `main` 必须可构建全绿、façade 对可服务
  App 与 CLI、没有「客户端链接已删模块」的中间态。跨 Task 的硬前置（例如 013 的 publication 需要 014
  的 Job owner 写路径）拆成独立 PR、各挂各的 token，不在一个 PR 里混两个 Task。

---

## 4. 逐 Task 卡片（以 `tasks.md` 为准；这里是当前剩余项与特别注意）

### TASK-XPA-012 — host-only durable stores → Rust owner（收口）

- 剩余：`trace cache purge` + trace 数据库准备 + 安装态 cache ownership（先评估 `7ac34ec7`）；tool selection
  等剩余写路径（`RuntimeToolSelectionControlActionStore` 语义）；**安装态组合**：façade 进程本地服务这些
  store、Swift daemon 停止打开它们（`ArkDeckAgentDaemonMain` 组装根 + Workflows 的 store 消费方脱钩），
  `runtime service status`/receipt 反映 owner；隔离根 → 安装态的切换按 §3 preflight 与快照规则；GJ-1
  headless re-pass（runbook §2 + §2.1）。
- 完成判据：XPA-AC-1/7/9 行；Swift 侧结构测试断言这些 store 不再被 Swift daemon 打开；两个进程持同一
  lock 的负例；run.md 收口 + `Status:done（…）`。
- 主要落点：`rust/crates/{arkdeck-hoststore,arkdeck-platform,arkdeck-agentd,arkdeck-cli}`、
  `Sources/ArkDeckAgentDaemonMain`、`Sources/ArkDeckWorkflows`（store 消费方）、`Sources/ArkDeckBootstrap`、
  `Sources/ArkDeckTraceAdapter`、`Tests/**`、`LaunchAgents/**`、`Distribution/macOS/**`。

### TASK-XPA-013 — artifact store → Rust owner

- 剩余：`artifact.import.commit`（publication）、私有 `artifact.publish`（Swift 引擎经 pairing secret
  发布，直到引擎本身被 Rust 取代）、`artifact.import.release`、`artifact.import.inspection`（Job 引用
  检查）、lease、quota（拒新不毁旧）、retention、active-use/release、GC/cleanup-debt（只回收过期、
  未引用、未 pin）、canonical alias HDC route、owner 切换、写路径 crash-window（publish 中 kill 任一进程
  → 索引一致或缺失记录，不得半写）、GJ-1/2/3 re-pass。
- 完成判据：`index.json` 与 payload verification 字节相等；Artifact record/provenance 键集合与 Swift
  `ArtifactStorage` 完全一致 + 多一键拒绝；`artifact.read` 分页与 digest 校验一致；结构测试断言 Swift
  引擎不再直接写 `index.json`；XPA-AC-10 各条不变。
- 注意：Raw Artifact 不原地修改；sensitive opt-in 语义不变；export 拒绝覆盖/symlink 已在 #1874 实现，
  保持。

### TASK-XPA-014 — admission / job store / capability / recovery → Rust（D2）

- 剩余：admission 按已发布顺序（descriptor → provider registered → fresh target facts → full
  materialisation → lowering coverage → plan digest → capability）；`job.plan` digest 与 Swift 逐
  operation 相等（plan-only 零派发）；journal 写者（fsync/`F_FULLFSYNC`、tail cursor、torn-tail 修复）；
  SQLite `runtime_job` 写路径（pinned 布局、`user_version` 不动）；capability mint/reserve/consume 与
  authorization ledger；agent execution（`agent.run/status/resume/abandon/list`、HAR、`human-action`）；
  执行交接：r10 优先直接 Rust 路径，只有确需时才做 `executor.step.execute{jobId, stepId, typedAction,
  planDigest, targetFacts, useOrdinal}` 的 sidecar 协议（sidecar 只收 typed action，不能改 operation/
  target/plan/step set）；§G.4 preflight；GJ-1..5 在 Rust authority 上 PASS。
- 完成判据：Rust 写的 journal envelope/payload、checkpoint、recovery manifest、authorization ledger
  全部过 Swift 严格校验器（`JournalEventValidation`、`DurableFiles`、`RecoveryManifestContract`、
  `AuthorizationUsageLedger`）+ 多一键负例；crash-window 四象限（Rust/Swift × intent 前后、consume
  前后）全部 fail closed；`outcomeUnknown` lane 承接且不 replay；cutover 演练带 journal/SQLite 字节
  比对。
- **维护者门（开工时一次性问，拿到前做不依赖它的部分）**：L.1 第 13 条——ADR-0009 决策 2/4 今日承载点
  未裁决（ADR 头部注记），**裁决前不得把 recovery 语义固化进 Rust**；admission/journal/SQLite/capability
  可以先做。GJ-4 每次开窗要 go。
- 停止条件：任何 step 无 durable intent 派发；双 owner 写 SQLite。

### TASK-XPA-015 — analyzer / workspace providers → Rust

- 要点：`analyzer.extract-crash-signature@1` 等分析器输出与 Swift 字节相等；workspace isolate/patch/
  build/sign 流程（DevEco/ohpm/hvigor 调用经 registered toolchain 引用，不用 `/usr/bin/git`）；Keychain
  经 `SecItem*` C API；签名口令零泄漏；存在性门走 HAR console challenge；sidecar 覆盖面收缩。
- 完成判据：XPA-AC-1/10；GJ-5 re-pass（runbook §6：crash-probe、analyzer、isolate、patch、build、sign、
  deploy、healthy 判据；输入物料与 credential/preset 见 runbook §1 与 09-09 记录）。

### TASK-XPA-016 — HDC provider、supervisor observation、process executor → Rust

- 要点：`/.vol/<dev>/<ino>` 启动路径、事件驱动取代 25 ms poll、libproc 观测 server identity/generation、
  PTY 秘密交换、持久 shell 通道；Golden/Probe fixtures 全回放；fake 进程面断言真实 argv（含
  `-t <connectKey>`）；target adopt 的独立 USB 附着证明与 typed identity readback。
- 完成判据：AC-HDC-006-01、AC-HDC-009-01、XPA-AC-1/2；supervisor identity/generation 与 Swift 相同；
  GJ-1/2/3 re-pass。

### TASK-XPA-018 — Rust CLI 全 parity，Swift CLI 退役

- 持续项：每个新 Rust owner 落地时同 PR 补它的 CLI leaf（这已是 09-11 起的做法）。
- 收口项：以 `cli-feature-coverage.json` 256 条 entry 为台账逐条对账 Rust CLI（`arkdeck commands
  --output json` 两边比对）；argv fixture（当前 `Packages/ArkDeckKit/Tests` 下 210 个）与 envelope/page/
  nextAction 样本字节相等；`maintainer contracts export` 由 Rust 生成且与已发布 bundle 零漂移；所有
  leaf 由 Rust daemon 服务或按 CLI 规格 §12 tombstone（含 macOS 进程内兼容 leaf 如 `--socket`）；
  `implementationStatusByPlatform.macos` 全部 `implemented`，Windows 列如实 `notImplemented`/`deferred`
  不声称；Swift CLI 删除；GJ-1..5 用 Rust CLI headless。
- **维护者门**：L.1 第 7 条（双 CLI 期长度、兼容 leaf tombstone 时点）——删 Swift CLI 前先问。
- 车道退役：`scripts/ci/plan.py`、`scripts/ci/test_plan.py`、`.github/workflows/swift-ci.yml`、
  `scripts/test_agent_pr_workflow.py`（`swift` 聚合的 `needs` 被逐字钉住，改车道要同 PR 更新契约测试）。

### TASK-XPA-019 — App 改用 ArkDeckClientKit，脱离 ArkDeckWorkflows

- 交付：新 `ArkDeckClientKit` target（从 `spec/control/methods/**` 生成 typed 模型、`xpc_connection`
  长连接 + 反向钉 daemon 身份、presentation adapter）；13 个 App-facing facade 逐个切换并各自可发布
  （`DebugApplicationFacade`、`DeviceControlFacade`、`DeviceListApplicationFacade`、`FlashApplicationFacade`、
  `HDCApplicationDiagnosticsFacade`、`OverviewCapabilityApplicationFacade`、
  `RockchipDeviceAccessApplicationFacade`、`RuntimeHistoryApplicationFacade`、
  `RuntimeHistoryFilterApplicationFacade`、`RuntimeJobControlApplicationFacade`、
  `RuntimeTraceCacheApplicationFacade`、`TraceApplicationFacade`、`UIDumpApplicationFacade`；
  `XPCConnectionBox` 随之退役）；23 个 `import ArkDeckWorkflows` 清零；presentation 语义只来自 daemon
  投影或 `spec/ui-semantics`，App 不派生状态。
- 完成判据：AC-UX-001-01..007-01、AC-DIAG-001-01/02、AC-DIAG-002-01、AC-I18N-001-01、XPA-AC-8；UI 测试
  全绿（`sh scripts/ci/run-ui-tests.sh -only-testing:ArkDeckHDCUITests/<Suite>`，全机唯一跑道、安静
  机器 loadavg < 核数×1.5、不 pkill 全局进程；新 UITests 文件要登记 pbxproj；Settings/Storage 这类依赖
  活 daemon 的页面在 CI 无 daemon，要同车给 `--ui-test-*` fixture 且 fixture 值与产品默认值可区分）。
- 可与 015/016 并行（014 合入后），共享文件 `Package.swift`、`project.pbxproj`、`Distribution/macOS/**`
  先 rebase 再推。

### TASK-XPA-025 — 性能车道切到 Rust daemon + Rust soak fixture

- 交付：Rust `arkdeck-soak`（复刻 `ArkDeckRuntimeSoakFixture` 语义与 `arkdeck-runtime-soak/v1`
  schema）；`scripts/bench` 对 cargo 构建的 `arkdeck-agentd` 采集；`rust-perf.yml` 不再构建任何 SwiftPM
  产品；参考主机 release 构建重取 13 项基线（含 idle RSS 两电平拆分：启动 plateau 与稳态分开记）
  入仓，Swift 末版基线并列保留；PR/nightly/soak 三车道在 Rust daemon 上绿。跨机器比较绝对值和比值都
  不成立，只在参考主机比；advisory run 不因不稳非零退出；失败时先拷证据再 propagate；`tee` 要配
  `pipefail`。
- **维护者门**：L.1 第 15/16 条——只记录测量，不批准预算、不提高上限。
- 可与 015/016 并行（014 合入后）。

### TASK-XPA-017 — ArkForge lane → Rust；删除 Swift daemon/引擎/存储 target（G5，D2）

- 前置：016、018、019、025 全部 done。
- 交付：Rust ArkForge lane 直接消费 `arkforge-client`（pin 以 `Package.swift`/ArkForge 仓为准，含
  hardware campaign 与 DEC-016 语义）；删除 `ArkDeckAgentDaemon`、`ArkDeckAgentDaemonMain`、
  `ArkDeckWorkflows` 引擎部分、`ArkDeckStorage`、`ArkDeckProcess`、`ArkDeckOpenHarmony` 与 Swift
  fixtures（`ArkDeckJournalCrashFixture`/`ArkDeckEngineCrashFixture`/`ArkDeckRuntimeSoakFixture`；Rust
  等价物由 014/025 先行）；ArkForge Swift SDK 从 `Package.swift` 移除；LaunchAgent 永久指向 Rust
  二进制，façade 模式与 `package-macos-facade.sh` 的 rollback bundle 退役；`ArchitectureBoundaryContractTests`
  改为守卫「Swift 无 Runtime 语义」；发布 helper/DMG 含 Rust daemon（nested code、空 entitlements、
  Developer ID + Hardened Runtime，沿 `build-helpers.sh` 公证形态）；CI 车道退役；
  `openspec/platforms/macos/**`、`PLATFORM-PROFILES.lock.yaml`、`traceability.md` macOS 列在此翻转、
  此前不得翻。
- 完成判据：仓内无第二份 Runtime 语义实现；GJ-1..5 在纯 Rust daemon 上 `REAL_DEVICE_PASS`（GJ-4 要 go
  与 campaign 窗口）；安装/签名/IPC 身份/恢复验证按 §G.5 表全过。
- 完成即 G5：报告后停下。Windows 阶段（XPA-002 Windows 验收 → XPA-004…）是另一份指令。

---

## 5. 机械流程（每个切片都一样）

### 5.1 开工

1. `git fetch origin && git worktree list && gh pr list --state open --json number,headRefName,title`：
   看清 main tip、别的会话在飞的分支、遗留工作区（§0）。
2. 读该 Task 的 `tasks.md` 小节 + `evidence/runs/<task>/` 最新记录，列出「已在 main / 本切片交付 / 仍剩余」
   三栏，写进本切片 run 记录开头。
3. 有维护者门的 Task（014：L.1 第 13 条 + GJ-4 go；018：第 7 条；025：第 15/16 条；017：GJ-4 go 与
   发布形态）在开工时一次性列成问题报给维护者，拿到裁决前做不依赖它的部分。
4. 第一个切片 PR 把 `blocked` 翻成 `in-progress（日期 + 一句话）`，`pin-example` 换成真实 `yaml pins`
   （键只能是 `path/artifact/blob/commit/sha256`，40/64 hex）；收口 PR 翻 `done（…）` 并附真机记录。
   状态行用全角括号（`TASK_STATUS_RE`）。

### 5.2 切片形状（沿 #1841～#1881 先例）

一个切片 = 一个可运行的垂直能力：Rust owner/handler（`rust/crates/*`）+ typed RPC（若新增方法则同步
`control-protocol.json`、`spec/control/methods/*.json`、`openspec/contracts/runtime-control-plane.schema.json`、
`CLIControlMethodRegistry`/`cli-feature-coverage.json`）+ Rust CLI leaf（必要时 Swift CLI 也切到同一
typed 方法）+ Swift 侧 producer fixture 与严格 readback 测试 + `rust/scripts/check-<slice>.py` 真实
进程 harness（启动、请求、重启、CAS/锁、second-owner 拒绝、崩溃窗口）+ `evidence/runs/<task>/<slice>-run.md`
+ `rust/README.md` 一段用法。规模对齐先例（一两千行），不做半成品 PR。

新方法/新错误码的 schema 来自真实录帧：`ARKDECK_CONTROL_FRAME_LOG=<dir>` 跑相关 Swift 契约测试 →
`Packages/ArkDeckKit/Scripts/generate-control-contract.py --derive-method-schemas <dir>` → 用生成器的
`signature()` 剪掉只有 ID 不同的语料重写 → `python rust/scripts/generate-contract.py --write`。schema 只能
发布语料里出现过的形状：新 owner 的每种拒绝都要有一条录到的帧，否则门不会红也不会保护你。

### 5.3 本地门（最终 commit 后、push 前，全部要过）

```bash
ARKDECK_PYTHON=<repo>/.venv-sdd/bin/python sh scripts/check-sdd.sh
```

```bash
python3 scripts/ci/plan.py --repo-root . --base-revision origin/main --head-revision HEAD --merge-base --include-worktree --run-local
```

- 统一闸按 diff 选 Swift / App build-for-testing / design-system / Rust 车道；rust 车道的 Python 需要
  `PyYAML==6.0.3` + `jsonschema==4.26.0`（自建 venv 后用它的解释器启动 `plan.py`，`ARKDECK_PYTHON` 仍指
  `.venv-sdd`）；cargo 的 cwd 是 `rust/`；`check-contracts.py` 约 10 分钟；`plan.py` 遇首个失败即停，
  后续步骤可按 `local_commands` 顺序手工补跑。
- Rust 三平台 clippy 本地先过：`cargo clippy --workspace --all-targets --target x86_64-pc-windows-msvc`
  与 `--target x86_64-unknown-linux-gnu`（`rustup target add`；check-only 不需链接器），避免 macOS-only
  代码在 Linux/Windows job 报 unused。
- 已知 flake 族：负载敏感墙钟断言（`arkdeck-client/tests/bounded.rs`、`DispatchedInvocationDurationContractTests`
  等）——与 diff 无关时按族判读，修法是等真实完成条件，不是放宽 margin；`swift test --parallel` 每个
  method 一个进程，固定 fixture 目录会互删；Foundation `Process.waitUntilExit()` 在非主线程会挂，用
  `isRunning` 轮询 + deadline。
- App 呈现相关断言用 `sh scripts/ci/run-ui-tests.sh -only-testing:ArkDeckHDCUITests/<Suite>`（不是
  merge gate）。

### 5.4 提交、rebase、冲突、推送、循环

- 分支 `agent/xpa-0NN-<slug>-<YYYYMMDD>`，从最新 `origin/main` 建；**每次 commit 前** `git fetch origin
  && git rebase origin/main`（本地跑过全量门后若 rebase 带进了新 main 提交，至少重跑受影响车道）。
- **推送前查冲突**：`gh pr list --state open --json number,headRefName,files` 取每个开着的 PR 的文件集，
  与 `git diff --name-only origin/main..HEAD` 求交集；有交集就读对方 diff：语义无关 → 在 commit 正文
  写明重叠文件与合并顺序；语义相关 → 把分支 rebase 到对方分支上并在正文写「合并本 PR 连带前序内容，
  届时前序应 Close 而非 merge」，或与对方会话协调（`gh pr view --json headRefName` 用分支名对会话，
  不动别人的工作区）。
- 最终 commit：subject 英文、以 `(TASK-XPA-0NN)` 结尾且只含一个 TASK token；正文写 diff 概要、原因、
  跑了什么、没跑什么及原因、重叠/前置 PR、待裁决项——这是 PR 的唯一说明载体。
- 推送：`git push origin HEAD:refs/heads/agent/<branch>`（维护者主机上的 `origin` 已配成部署密钥 remote，
  见 `scripts/agent-guides/contributing.md`）；22 端口被网络层拦时改走 `ssh.github.com` 的 443 端口
  （`GIT_SSH_COMMAND` 指定同一把部署密钥并加 `-o IdentitiesOnly=yes -p 443`，远端
  `ssh://git@ssh.github.com:443/ArkDeck/ArkDeck.git`）。推完查
  `gh run list --workflow "Agent PR" --branch <branch>` 确认 PR 开出，再 `gh pr view <N>
  --json title,state,files` 读回；重触发 CI 只能 `git commit --amend --no-edit` 换 SHA 后
  `--force-with-lease=refs/heads/<branch>:<old-sha>`。
- **循环**：CI 绿 → 不等合入，立刻开下一个切片。默认从 `origin/main` 新建分支；只有下一切片硬依赖
  未合入内容时才叠在其上，并在正文声明；前序 squash 合入后 `git rebase --onto origin/main <前序分支>`
  剥离已合入 commit，再 force-with-lease。CI 红先分辨本 PR 问题还是 flake，修或重触发。「等合入」永远
  不是阻塞；真正的阻塞（没接设备、维护者门未裁、安全停止条件）要实测出来并写清。
- 治理类改动（proposal revision、tasks.md 之外的 openspec 文档、DEC）走独立 `docs:`/`proposal(...)`
  PR，subject 不带 TASK token，可以先行不停工。

### 5.5 真机与记录

- 每次安装态操作前 `arkdeck runtime service status --output json` 读清当前安装的是哪一对 helper，记进
  run.md，不假设。helper 构建：`bash Packages/ArkDeckKit/Distribution/macOS/build-local-helpers.sh`
  （`ARKDECK_CLI_PROVISIONING_PROFILE`、`ARKDECK_DAEMON_PROVISIONING_PROFILE` 在
  `~/Library/Application Support/ArkDeck/Signing/macOS/`，`ARKDECK_LOCAL_HELPER_OUTPUT` 自定；脚本内部
  调 `rust/scripts/package-macos-facade.sh debug` 构建 Rust daemon 并作为 `arkdeck-facade` 装进
  `ArkDeckAgent.app`，同时留一份独立 Swift bundle）；安装 `arkdeck runtime service update --daemon
  <…/ArkDeckAgent.app> --output json`；daemon 重启偶发撞孤儿 managed HDC server，launchd 约 30 s 自愈。
  Runtime 不是预定 main 构建时先按 `openspec/changes/chg-2026-025-ai-native-unattended-device-ops/
  evidence/host-prerequisites/installation-runbook.md` 更新，再开始 Journey。
- 严格按 runbook：§1 前置，§2 GJ-1（含 §2.1 HAR crash-resume），§3 GJ-2，§4 GJ-3，§5 GJ-4（go 后），
  §6 GJ-5，§7 记录模板。输入物料位置在 runbook §1（GJ-4 归档 SHA-256 `4fd35765…`）。
- 记录：`docs/design/references/single-v1/gj-headless-rerun-<date>-xpa0NN.json`（schema
  `arkdeck.gj-headless-rerun/1`，沿 xpa003 两份记录的字段：journey、state、runtimeBuild、
  protectedMainBase、binarySHA256、targetID、binding revision 前后、executionID、jobId、terminalState、
  actualStepKinds、时间、firmware、confirmationMethod、authority）+ 叙述记录；`evidence/runs/<task>/run.md`
  引用。G5 终记录另按 `verification.md` Golden Journeys 行落到
  `docs/design/references/v1.6-goal/gj-headless-rerun-<date>-macos.json` 并给
  `real-device-validation.md` 加一节（沿 2026-09-02 段格式）。
- headless 路径失败先修产品路径，修不了报 `BLOCKED_BY_PRODUCT_DEFECT` 并指明归属 Task；不让维护者代跑、
  不拿 UI 点击替代。fake/fixture/plan-only 不能充当真机结果。

---

## 6. run 记录必须包含

Base commit；readiness pins 实际值；「已在 main / 本切片交付 / 仍剩余」三栏；每条 Acceptance 的命令、
退出码、结果、判据；differential/shadow 的比对范围与结果；crash-window 矩阵；cutover preflight 的阻断/
parked 实测；旧目录保留/归档与快照摘要；真机 GJ 的 Job ID 与记录文件；统一闸摘要（log 路径 + SHA-256）；
未执行项及原因；残留与归属；待维护者裁决项。真实运行结果本身是一等证据，schema 表达力不足只写一行兼容
说明，不阻塞状态推进（PRODUCT-LOOP §2）。

---

## 7. 通用规矩与停止条件

- 验证每一道门再断言阻断；读到一个值 ≠ 读懂它被谁怎么用，先看消费方与契约测试；另一 AI 或旧记录说
  「已通过」必须自己跑一遍再信。
- 不为过测试放宽 Core requirement、Safety invariant、AC；不自标 approved/verified/REAL_DEVICE_PASS。
- 不确定即 fail closed；unknown intent 永不 replay；「没测到」不写成「测到的值」（optional 同时承载值与
  失败时用三态）。
- 不用 `git checkout <branch> -- .` 覆盖工作树；清理只用 `git reset --hard HEAD`；不用裸 `git stash`；
  并行 Bash 里 `cd` 会让 cwd 漂移，每条命令用绝对路径。
- 硬停止（触发即停、报告、不绕）：安全内核冲突；任何 step 无 durable intent 派发；双 owner 写 SQLite 或
  双进程持同一 lock；façade/Rust 对已转发帧声称零派发；需要放宽 entitlements；`main` 会进入客户端链接
  已删模块的状态；真实设备上出现不确定副作用（只读回或按 POL-RECOVERY-001 完整证明推进）。
- 不是停止条件：路径不在 Allowed paths、旧 Task 显示 blocked、缺 Acceptance ID、CI flake、等合入、
  文档表达不了结果。

---

## 8. 汇报（PRODUCT-LOOP §19）

每个切片 PR 推出后一段：PR 编号与分支、交付了哪条能力、本地门与 CI 结论、没跑什么及原因、重叠 PR、
下一切片。每个 Task 收口后一段：PR 列表、交付物逐条对照卡片、真机记录路径与 GJ 四态、残留（带归属）、
待裁决项、下一个 Task 的前置。不重复输出全表或无变化状态。017 done 后报告 G5 达成、最终 GJ 记录路径、
Windows 阶段入口（XPA-002 Windows 验收），然后停。
