# ArkDeck Architecture Rules

> Status: current(2026-09-28 CHG-2026-074 删除 Swift Runtime 与 Swift CLI(TASK-XPA-017/018);
> 2026-08-19 CHG-2026-064 起进程内决策平面移除;ADR-0008 typed-only agent surface 同一世界观)。
> 执法点:Swift 侧是 `Packages/ArkDeckKit/Package.swift` 的依赖声明(编译器强制)+
> `Tests/ArkDeckContractTests/ArchitectureBoundaryContractTests.swift`(结构测试);
> Rust 侧是 `rust/Cargo.toml` 工作区与 `rust/scripts/check-readonly.py` 的 crate 依赖检查。
> 本文只描述**模块边界**;设备安全边界与 E0/E1/E2 授权见 Constitution 与 ADR。

ArkDeck 的长期形态不是 Agent Framework,而是被外部 agent 调用的权威执行层
(CHG-2026-064 移除了进程内决策平面):

```text
External agent decides   (Claude Code / codex / 任意已发布面调用方)
    ↓
Runtime executes        (Rust arkdeck-agentd: admission / job / journal / capability)
    ↓
Provider operates       (hdc / build.sh / git / analyzer lowering)
    ↓
Artifact proves
```

## 1. 模块分层(现状即规范)

Runtime 与 CLI 是 Rust(`rust/`,CHG-2026-074):`arkdeck-agentd`(daemon)与 `arkdeck`(CLI)
是唯一的执行面与命令面。Swift 不承载 Runtime 语义:Swift daemon、engine、storage、process、
provider、组合层、launchd 与 Swift CLI 的 target 已删除,结构测试断言它们不得以原名回归。
Swift 侧只剩 App 这一边:

```mermaid
graph TD
    APP[ArkDeck.app<br/>Xcode App + UI 测试] --> CLIENTKIT
    APP --> TRACE[ArkDeckTraceAdapter<br/>ArkTrace 产品配置]
    CLIENTKIT[ArkDeckClientKit<br/>App IPC transport + 展示/读模型 + facade] --> CORE
    RT[ArkDeckRuntime<br/>共享契约 + 宿主设施] --> CORE
    CLIENT[ArkDeckAgentClient] --> CORE
    BOOT[ArkDeckBootstrap<br/>bundle/tool 注册表] --> CORE
    CORE[ArkDeckCore<br/>catalog/JobState/Capability/Target<br/>v2 请求 DTO]
    CLIENTKIT -. XPC com.arkdeck.agentd .-> AGENTD[Rust arkdeck-agentd]
```

要点:

- **不存在进程内决策平面**(CHG-2026-064)。`ArkDeckHarness` target 已删除;
  任何调用方(人、App、外部 agent)进入执行的唯一门是「已发布 operation reference +
  typed inputs 经 admission」。
- App 只经 ClientKit 与 Rust daemon 说话,只认独立 Rust daemon 的身份
  (`com.arkdeck.agentd`,版本与 build 号精确匹配);过渡期的 façade 身份不再被接受。
- `ArkDeckRuntime`、`ArkDeckAgentClient`、`ArkDeckBootstrap` 只依赖 Core;App 不链接它们,
  由契约测试使用。v2 请求 DTO 在 ArkDeckCore(§6 判例 1)。
- 删除的 Swift Runtime 录下的 oracle 仍提交在 `rust/tests/fixtures/**` 与
  `Tests/ArkDeckContractTests/Fixtures/**`,由 Rust 测试回放。

## 2. Dependency Rules(允许的 import 上限)

一个 target 可以少 import,不可多 import。完整矩阵以
`ArchitectureBoundaryContractTests.allowedImports` 为准本:

```text
ClientKit    → Core
Runtime      → Core
AgentClient  → Core
Bootstrap    → Core
TraceAdapter → (nothing in ArkDeckKit; ArkTrace 外部包)
Core         → (nothing)
App(ArkDeck.xcodeproj)→ ClientKit, Core, TraceAdapter(UI 测试 target:ClientKit, Core)
```

Package.swift 声明的 target 集合被精确钉住:上述库、App UI 测试用的 `ArkDeckFakeHDCFixture`
和四个测试 target;测试 target 也只链接这些库。ArkForge 只经 Rust crate 使用
(`rust/Cargo.toml` 的单一 pin,`rust/scripts/check-arkforge-pin.py`),Package.swift 不再引用它。

## 3. Ownership Rules(事实源唯一)

下表的 owner 名来自已删除的 Swift 实现;Rust Runtime 承担同一 owner 职责与同一载体。

| 事实 | Owner | 载体 |
|---|---|---|
| Runtime Job 状态与时间线 | Runtime(RuntimeJobEngine) | `jobs/<jobID>/journal.jsonl` + `record.json` 快照 |
| Artifact 字节与元数据 | RuntimeArtifactStore | `artifacts/<jobID>/index.json`;调用方只经 lease/ID 引用 |
| Capability(E0/E1/E2) | Runtime | `RuntimeCapabilityStore`(唯一 enforcement:engine 三相 preauthorize/consume/recordOutcome) |
| Recovery(runtime job) | Runtime | engine 的 `recoverPersistedJobs`/`reconcile`(Storage 只出机制原语) |
| Evolution 隔离工作区 | EvolutionWorkspaceManager(组合层) | `evolution-workspaces/<id>`,按值拷贝、路径必须窄于源 profile |

引用链:`jobID → journal/artifacts`。外部 agent 对 job/artifact 只持引用,
补丁向主树的晋升走维护者 review PR。历史 `harness/` SQLite 目录为只读遗留,
不再有 owner(CHG-2026-064)。

## 4. Forbidden Rules(结构测试逐条钉死)

```text
Package.swift 声明 §2 之外的 target,或删除的 target 名/源码目录回归
          (ArkDeckCLI、ArkDeckAgentDaemon(Main)、ArkDeckWorkflows、ArkDeckAgentComposition、
           ArkDeckStorage、ArkDeckProcess、ArkDeckOpenHarmony、ArkDeckLaunchAgent、
           Journal/Engine/Soak/RuntimePort/FakeHapSigner fixture、ArkDeckHarness)
Package.swift 声明 arkdeck / arkdeck-agentd 可执行产品,或引用 ArkForge 包
任何剩余 target 或测试 target 链接 §2 矩阵之外的 ArkDeck 模块
任何模块公开 API -> command: String / shell script     (typed argv-only)
任何模型面(模型网关符号/ARKDECK_HARNESS_MODEL_/厂商端点/Bearer 凭据)
App 的代码要求接受 façade 身份 com.arkdeck.agentd.facade
App 链接或 import ClientKit、Core、TraceAdapter 之外的 ArkDeckKit 产品
```

文件级 import 扫描不是 manifest 检查的冗余:SwiftPM 允许同包未声明依赖的 import
通过编译,测试是那个洞的唯一护栏。

## 5. Evolution 边界

Evolution 可以:隔离工作区内 patch/build/test/deploy/verify(全部走
catalog typed operation + RuntimeJobEngine admission)。

Evolution 不能:碰 primary tree 的 ref(派生 profile `sourceControlPreset: nil`,
git 面只有 status/diff/stash-create + 只读 plumbing)、自动 merge/push、
绕过 review(晋升 = 维护者 review PR)、扩权
(`EvolutionWorkspacePolicy` 拒绝可破坏操作,scope 必须窄于源 profile)。

## 6. 判例(遇到边界问题先查这里)

1. **一个类型被 App 与其它 Swift 库同时需要** → 下沉到 ArkDeckCore(全局模型),
   不要制造反向 import。判例:v2 请求 DTO 在 Core(App 客户端库 ClientKit 只依赖
   Core,也要构造请求)。
2. **想给 ArkDeck 加"决策能力"** → 不加。决策属于外部 agent;ArkDeck 提供
   已发布 operation、admission 与证据(CHG-2026-064 判例:整个任务平面)。
3. **Provider 想读调用方上下文** → 不读。provider 只见 Operation/Input/
   Target/Effect/Policy。
4. **想给 Swift 加 Runtime 语义(engine、存储 owner、provider、daemon)** → 不加。
   它属于 Rust Runtime;App 经 ClientKit 调用已发布的控制面方法。
5. **矩阵需要放宽** → 那是架构决策:与需要它的代码同 PR,由维护者 review;
   先自问是否其实该走 1/2/3。
