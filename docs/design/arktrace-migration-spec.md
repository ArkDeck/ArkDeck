# ArkTrace 全量迁移规格（TASK-AIN-021）

> 类型：产品实现规格，不是新的 OpenSpec Task、Change、Readiness 或批准载体。
> 归属：复用 protected `main` 已存在的 `TASK-AIN-021`。
> 目标：把 ArkTrace 的采集后解析、查询、分析、缓存与原生 Timeline 能力迁入 ArkDeck，
> 并以 ArkDeck 已发布的 typed Runtime/Artifact 边界完成真机闭环。
> 验收状态：`REAL_DEVICE_PASS`（2026-08-24），证据见
> [`arktrace-real-device-verification-2026-08-24.md`](./arktrace-real-device-verification-2026-08-24.md)。
> 配套文档：[`arktrace-user-guide.md`](./arktrace-user-guide.md)、
> [`arktrace-user-guide.en.md`](./arktrace-user-guide.en.md)、
> [`arktrace-trace-streamer.md`](./arktrace-trace-streamer.md)。

## 1. 产品结果

迁移完成后的唯一生产数据流是：

```text
arkdeck agent run
  → capture.diagnostics@1
  → exact target + binding + typed trace inputs
  → HDC Provider capture / receive / validate / cleanup
  → immutable trace.htrace Artifact
  → bounded artifact.read + byteCount/SHA-256 verification
  → pinned TraceStreamer parse
  → local content-addressed SQLite/cache
  → summary / context / deterministic analysis / Timeline Viewer
```

ArkDeck App 可以打开已有 trace，也可以打开本次 Runtime Job 采集并验证的
`trace.htrace`。App、CLI 和外部 Agent 都不得提交 raw HDC、shell、argv、远端路径、
executable path、capability 或 trusted facts。

## 2. 能力迁移矩阵

| ArkTrace 能力 | ArkDeck 归属 | 迁移决策 | 完成条件 |
|---|---|---|---|
| HDC 设备发现与采集 | `capture.diagnostics@1`、HDC Provider、Trace facade | 复用并替代 ArkTrace App-only HDC executor | 继续显式绑定 target/revision，真机产出非空且校验通过的 `trace.htrace` |
| App responsiveness / CPU / system presets | Trace App workspace + probe-supported tags | 映射到 ArkDeck preset/tag 模型，不引入第二套设备命令 | preset 只提交 probe 已确认且 Catalog 边界内的 tags |
| TraceStreamer identity/progress/process parser | `ArkDeckTraceParser` | 迁入 ArkDeckKit | exact binary/manifest 校验、bounded stdout/stderr、取消与错误契约全保留 |
| SQLite schema adapter/repository | `ArkDeckTraceStore` | 迁入 ArkDeckKit | 原始 trace 不可变；数据库只作为可重建的本地派生数据 |
| content-addressed cache/session | `ArkDeckTraceRuntime` | 迁入 ArkDeckKit | cache hit、损坏恢复、no-cache session、并发与清理契约全保留 |
| typed trace domain/query | `ArkDeckTraceCore` | 迁入 ArkDeckKit | 时间、identity、capability、query bounds 与错误模型全保留 |
| summary/context/deep analysis | `ArkDeckTraceAnalysis` + 既有 analyzer operations | 迁入实现并保持公开 operation 不变 | `analyzer.summarize-trace@1` / `analyzer.analyze-trace@1` machine bytes 兼容 |
| Agent CLI JSON contract | `ArkDeckTraceCLI` / ArkDeck-owned `arktrace` helper | 迁入 ArkDeckKit | JSON contract 1.0、exit status、deadline、row/event/output budgets 兼容 |
| Timeline geometry/palette/AppKit renderer | `ArkDeckTraceRendering` | 迁入 ArkDeckKit | CPU/thread state/slice/counter/frame lanes、zoom/pan/selection/search/flags/marks 可用 |
| document controller/recent/view state | `ArkDeckTraceAppSupport` | 迁入 ArkDeckKit | 打开、reload、取消、cache/view state 与错误恢复可测试 |
| ArkTrace standalone window chrome | `ArkDeckApp/Features/Trace` | 按 ArkDeck 工作区重组 | 不复制第二套 App shell、Settings 或设备控制面 |
| ArkTrace direct capture module | 不迁入生产依赖图 | 由 ArkDeck Runtime capture 替代 | CLI/analyzer/viewer 不获得直接 HDC route |

“全量迁移”按能力等价与生产可达性判断，不要求保留与 ArkDeck 已有实现重复或违反其安全
边界的源文件。被 ArkDeck typed capture 替代的 ArkTrace direct-HDC 实现必须留在迁移矩阵中，
不能悄悄丢失，也不能作为第二条生产路径进入 App。

## 3. ArkDeckKit 模块边界

新增模块均位于 `Packages/ArkDeckKit`，并进入架构矩阵与结构测试：

```text
ArkDeckTraceCore
├─ ArkDeckTraceParser → TraceCore
├─ ArkDeckTraceStore → TraceCore + SQLite3
├─ ArkDeckTraceAnalysis → TraceCore
├─ ArkDeckTraceRendering → TraceCore + AppKit/CoreGraphics/SwiftUI
└─ ArkDeckTraceRuntime → TraceCore + TraceParser + TraceStore
      └─ ArkDeckTraceAppSupport
           → TraceCore + TraceParser + TraceRuntime + TraceAnalysis + TraceRendering

ArkDeckTraceCLI
  → TraceCore + TraceParser + TraceStore + TraceRuntime + TraceAnalysis
```

- Trace 模块不 import `ArkDeckWorkflows`、`ArkDeckOpenHarmony`、`ArkDeckAgentClient` 或
  `ArkDeckAgentDaemon`；解析能力因此不会反向获得设备权限。
- `ArkDeckWorkflows` 继续拥有 Runtime Job、Artifact 和 analyzer provider；它不依赖 AppKit
  renderer。
- ArkDeck App 是组合根，可以同时依赖 `ArkDeckWorkflows` 与 Trace AppSupport/Rendering。
- 现有公开 Catalog operation、provider 名、effect、binding 与 authorization 不改变。
- 迁入代码保留 ArkTrace machine identity，以兼容已经发布的 analyzer envelope；Swift
  module 名使用 `ArkDeckTrace*`，体现其 ArkDeckKit 所有权。

## 4. Artifact 到 Viewer 的可信边界

### 4.1 选择

只有满足以下条件的 Artifact 才能进入解析器：

- 来自本次明确的 terminal Runtime `jobId`；
- 名称为 `trace.htrace`，status 为 published，privacy 为 sensitive；
- terminal state 成功且 `outcomeUnknown == false`；
- `artifact.list` 返回 media type、byteCount 和 lowercase SHA-256；
- 不存在未结 cleanup residue 会使本次结果身份不明确。

失败、取消、等待人工、unknown outcome、空文件或未发布 Artifact 不得替换当前已打开文档。

### 4.2 有界读取

App 只通过 Agent XPC 的 `artifact.list` / `artifact.read` 读取，不访问 daemon 文件路径：

- sensitive 读取必须显式 `allowSensitive: true`；
- 固定 chunk 上限并校验 offset 单调前进、EOF、总 byteCount；
- 流式写入 session-owned `.partial`，同步计算 SHA-256；
- byteCount 与 SHA-256 均相等后原子提升为本地 trace；
- 超预算、空的非 EOF chunk、base64 错误、offset 漂移、hash/size 不符全部 fail closed；
- 取消或失败删除 host partial，不调用 parser，不写 Recent。

### 4.3 解析与缓存

- parser 只从 ArkDeck App bundle 或 ArkDeck-owned reviewed CLI distribution 的固定位置解析，
  不搜索 `PATH`，不接受请求传入 executable/manifest；
- App 只原位执行 `Contents/MacOS/trace_streamer` 的已签名嵌套代码；CLI 使用私有 immutable
  helper snapshot。两者都在执行前后验证 exact identity，且输入/输出仍在私有 staging；
- parser executable 与 manifest 必须匹配，进程 stdout/stderr 与 deadline 有硬上限；
- raw Artifact 与本地验证副本保持不变，SQLite 是 content-addressed derived data；
- App Sandbox 只允许从 App 私有存储打开 Ready SQLite，并使用 descriptor preflight、
  `SQLITE_OPEN_NOFOLLOW` 与 post-open identity 校验；CLI 继续 descriptor-bound `/dev/fd`；
- cache 损坏时隔离并重建；`--no-cache` 使用 session-owned 临时数据库；
- 取消、parser 失败或 schema 不兼容不得留下可被误认成成功的 cache entry。

## 5. Trace 工作区

Trace 页面保留现有 target、preset/tag、duration/buffer、probe、参数快照、进度与 Artifact
事实，并新增同页查看器模式：

1. 未打开文档时显示采集配置与“打开已有 Trace”；
2. 采集成功并完成 Artifact 校验后自动进入 Viewer；
3. Viewer toolbar 提供返回采集、打开、reload、process filter、trace search 与 Inspector；
4. Timeline 支持 CPU、thread state、named slice、counter、frame lane；
5. 支持鼠标/触控板 pan、zoom、range selection、event selection、flags、marks 与键盘导航；
6. Inspector 显示 event 或 range analysis，Sidebar 按 process 分组并控制 lane visibility；
7. 加载、取消、失败、空 timed events、截断与 cache needs-attention 均使用明确状态，
   不以颜色作为唯一信号，不伪造进度百分比；
8. 尊重 VoiceOver、键盘焦点、focus-visible 与 Reduce Motion。
9. duration 支持直接输入与秒/分钟展示单位；秒快捷项为 `15/30/45/60`，分钟快捷项为
   `1/2/3`，提交边界始终规范化为 published `durationSeconds`；Target 区域可显示 Runtime
   已接管的 `hdc v<version>` 事实，但不得为此新增 Viewer-owned HDC probe。

ArkTrace 的独立 `WindowGroup`、App Settings 和直接 Capture window 不复制；这些能力必须融入
ArkDeck 既有 shell、全局 Job Inspector、Settings 与 Trace workspace。

## 6. CLI 与 analyzer 兼容

迁入的 ArkDeck-owned `arktrace` helper 保持以下机器契约：

- commands：`doctor`、`inspect`、`summary`、`processes`、`threads`、`query`、`context`、
  `analyze`、`licenses`；
- machine JSON version 1.0，单个 document 写 stdout；
- typed error 与稳定 exit status；
- timeout、maxRows、maxEvents、maxOutputBytes 均为显式硬边界；
- 不提供 raw SQL、shell、PATH fallback 或网络；
- 既有 ArkDeck analyzer validators 接受的 exact envelope、tool/parser/request/source lineage
  保持 byte-compatible。

生产 daemon 仍通过 descriptor-bound child process 隔离 analyzer。迁入源码不构成让 daemon
改为进程内解析的授权，也不允许降低现有签名、manifest、doctor、lease 和 exact-output 校验。

## 7. 规格与实现差异处理

- `openspec/specs/trace/spec.md` 的采集要求继续有效；本规格只补充其未覆盖的 host 解析、
  Timeline 与同页闭环，不修改 accepted Core requirement 或 Acceptance Scenario。
- 历史 `docs/PLAN.md` 中“首版不实现完整 Timeline”是早期范围记录；维护者本次明确要求
  全量迁移 ArkTrace，当前产品闭环以本规格与实际实现为准，不重启治理 change。
- CHG-2026-058/060 的 published operation 与安全边界继续有效；从 ArkTrace 仓库构建的
  外部分发在迁移期保持兼容，最终由同源码、同 machine contract 的 ArkDeck-owned 分发替代。

## 8. 测试与验收

### 8.1 模块回归

- 迁移 ArkTrace Core/Parser/Store/Runtime/Analysis/Rendering/AppSupport/CLI 的全部适用测试；
- 测试 fixture、golden machine JSON、TraceStreamer identity 与 query/analysis budgets 不降级；
- 架构测试钉死新增 target 的允许 import、strict memory safety 与零设备权限。

### 8.2 App/Artifact 回归

- canonical typed capture request 与 exact target/binding；
- `artifact.list/read` 多 chunk、EOF、offset、size、SHA、privacy 与预算负例；
- 只有验证成功的 raw trace 才原子切换 viewer；旧文档在新 capture 失败时保留；
- open/reload/cancel/search/selection/keyboard/VoiceOver/Reduce Motion；
- parser/helper 缺失或 identity drift 时显示 unavailable，零 fallback。

### 8.3 真机完成定义

最终真机验证默认走 Agent/CLI，而不是要求维护者点击 App：

1. `arkdeck doctor` 与精确 adopted target/binding 可用；
2. `arkdeck agent run` 执行当前 Catalog digest 的 `capture.diagnostics@1`；
3. Job terminal succeeded、`outcomeUnknown=false`、cleanup 无未结 residue；
4. `trace.htrace` published、非空、size/SHA-256 可复核；
5. ArkDeck-owned parser 成功生成数据库并识别有效 trace range；
6. summary 至少报告 CPU scheduling、thread state 或 named slice 中设备实际包含的能力；
7. 同一 Artifact 可由 ArkDeck App Viewer 打开；
8. 记录脱敏 target、Catalog digest、job/artifact IDs、bytes/hash、parser identity 与结果。

只有以上闭环在当前 Catalog digest 上完成，GJ-1/GJ-2 的本次 Trace 子能力才可记为
`REAL_DEVICE_PASS`。fixture、旧 ArkTrace 烟测或单独运行 parser 均不能替代它。

## 9. 非目标与安全不变量

- 不发布新 operation/provider/integration/device profile；
- 不修改 `capture.diagnostics@1` 或 analyzer operation 的公开语义；
- 不让 App/CLI 直接执行 raw HDC 或任意 host shell；
- 不把 sensitive Trace 自动上传或默认导出；
- 不把 simulation/fake/旧 digest 记录成当前真机结果；
- 不因 UI/文档缺口绕过 Runtime availability、capability、binding、intent-before-effect、
  Artifact lease、unknown-outcome 或 cleanup 规则。

## 10. 迁移规范性需求

本节使用 SHALL / SHALL NOT 表达本次产品迁移的可测试要求。它们不改写
`openspec/specs/trace/spec.md` 的 accepted Core 语义，而是补足其未覆盖的 host parser、
Viewer 和发布闭环。

### REQ-ATM-001 唯一设备采集权限

ArkDeck SHALL 只通过已发布的 `capture.diagnostics@1` 与 Runtime-owned HDC
Provider 采集 Trace。`ArkDeckTrace*`、`arktrace` 和 Viewer SHALL NOT 包含直接 HDC、
shell、remote path 或 caller-supplied executable 路由。

#### AC-ATM-001-01 Viewer 发起采集

- GIVEN Viewer 用户选择了已确认 target/binding 与 probe-supported tags
- WHEN 用户开始采集
- THEN App 只提交 operation reference + typed inputs
- AND Trace parser 依赖闭包中不存在 HDC 或 Agent transport

### REQ-ATM-002 精确 Artifact 准入

App SHALL 仅接受本次 terminal succeeded Job 中唯一的 `published` / `raw` /
`sensitive` / `application/octet-stream` / `trace.htrace`。读取 SHALL 有 chunk 上限并验证
offset、EOF、byte count 和 lowercase SHA-256；只有全部相等才能原子发布到
Viewer session。

#### AC-ATM-002-01 同名 Artifact 歧义

- GIVEN 同一 Job 返回两个都看似 `trace.htrace` 的候选者
- WHEN App 选择 Viewer 输入
- THEN 选择 fail closed
- AND 当前已打开的文档、Recent 与 parser 调用数不变

### REQ-ATM-003 Parser 身份与进程边界

Parser SHALL 仅执行 App bundle 或 reviewed ArkDeck distribution 的固定 `trace_streamer`，
并在每次解析前同时验证 regular file、architecture、version、manifest SHA-256 与
upstream revision。生产路径 SHALL NOT 搜索 `PATH`，SHALL 使用 `-nm`，并对 deadline、
stdout、stderr、sidecar 和 TERM → KILL 清理设置硬上限。

App bundle helper SHALL 是带 sandbox inheritance 的签名嵌套代码，并在 bundle 原位执行；
复制到 writable staging 后执行不属于允许的 App 路径。CLI SHALL 继续执行 immutable helper
snapshot。

#### AC-ATM-003-01 Helper 漂移

- GIVEN helper 字节或 manifest 任一侧与锁定 identity 不同
- WHEN App 或 CLI 请求解析
- THEN 在启动子进程前返回 typed unavailable/error
- AND 不搜索另一个可执行文件作为 fallback

### REQ-ATM-004 不可变 raw 与可重建派生数据

Raw Trace SHALL 不原地修改。SQLite/cache SHALL 由 raw SHA-256、parser identity、schema
adapter version 和有效参数完整定址；损坏或版本漂移的 entry SHALL 隔离后重建。
`--no-cache` SHALL 只使用 session-owned 临时数据库并在 close 后清理。

#### AC-ATM-004-01 Cache 损坏

- GIVEN cache key 匹配但 Ready DB 的 quick check、schema 或索引版本无效
- WHEN 重新打开同一 raw Trace
- THEN 旧 entry 不被当作成功结果
- AND 系统从不变 raw 重新解析并原子发布新 Ready DB

### REQ-ATM-005 原生 Viewer 功能等价

ArkDeck SHALL 提供 ArkTrace 已有的 CPU/thread state/named slice/counter/frame lanes、
process filter、trace search、pan/zoom、range/event selection、flags、marks、Inspector、
recent documents、cache settings 和键盘操作。空数据、truncation、unavailable 与失败
SHALL 是不同状态；交互 SHALL 支持 VoiceOver、可见焦点并尊重 Reduce Motion。

#### AC-ATM-005-01 采集失败不覆盖 Viewer

- GIVEN Viewer 已打开一份通过校验的 Trace
- WHEN 新采集失败、取消、outcome unknown 或 Artifact 校验失败
- THEN 旧文档及其选区 / viewport 保留
- AND UI 显示新 Job 的真实终态而不伪造新 Viewer

### REQ-ATM-006 CLI 机器契约兼容

ArkDeck-owned `arktrace` SHALL 保留 commands、Machine JSON 1.0 envelope、typed error、
stable exit status、deterministic ordering 和 timeout/row/event/output byte 硬预算。它 SHALL NOT
提供 raw SQL、任意表列、shell 或网络能力。

#### AC-ATM-006-01 输出预算不足

- GIVEN 成功 payload 超过 `maxOutputBytes`
- WHEN CLI 生成 machine output
- THEN stdout 不包含半截 JSON
- AND 只在最小 typed error envelope 也无法容纳时保持 stdout 为空

### REQ-ATM-007 发布资源闭包

ArkDeck App SHALL 同时携带 exact parser、manifest、迁入代码的 MIT License、
third-party notices 与 inventory 要求的 18 份 license text。Xcode build phase SHALL 声明
exact sandbox input list；任一文件缺失或漂移时 build/distribution validation SHALL fail closed。
仓库 manifest SHALL 锁定 unsigned canonical source helper；bundle manifest SHALL 锁定
CodeSignOnCopy 后的 helper bytes，并由 nested-code / outer-App 签名验证共同约束。

#### AC-ATM-007-01 空净 App build

- GIVEN 一份只含仓库受审字节的 clean checkout
- WHEN 构建 ArkDeck scheme
- THEN App bundle 的 helper/manifest/license 路径与 input list 精确相等
- AND bundle parser 签名字节 SHA-256 等于 bundle manifest
- AND canonical source 字节 SHA-256 仍等于仓库 manifest

### REQ-ATM-008 当前 digest 真机闭环

迁移只有在当前 Catalog digest 上通过 `arkdeck agent run` 完成精确设备采集、
Artifact 发布 / 校验 / 导出，再由迁入 ArkDeckKit 的 parser/summary 识别有效
Trace range 时 MAY 标记完成。

#### AC-ATM-008-01 Fixture 不代替真机

- GIVEN 全部 host tests 通过且 fixture 可解析
- WHEN 当前 Catalog digest 尚无真机 terminal receipt
- THEN 状态仍为 `IMPLEMENTING`
- AND 旧 ArkTrace 烟测、simulation 或旧 digest evidence 不得标记本次闭环完成

## 11. 实现与发布位置

| 产物 | 仓库 / App 位置 |
|---|---|
| Swift targets | `Packages/ArkDeckKit/Sources/ArkDeckTrace*` |
| CLI product | SwiftPM product `arktrace` / target `ArkDeckTraceCLIExecutable` |
| parser source lock | `Packages/ArkDeckKit/ThirdParty/TraceStreamer/source-lock.json` |
| parser manifest | `Packages/ArkDeckKit/ThirdParty/TraceStreamer/macx/manifest.json` |
| App parser | `ArkDeck.app/Contents/MacOS/trace_streamer` |
| App manifest | `ArkDeck.app/Contents/Resources/TraceStreamer/manifest.json` |
| App licenses | `ArkDeck.app/Contents/Resources/ArkTrace/` |
| Trace cache | `~/Library/Caches/ArkDeck/Trace/traces/` |
| App document types | `.htrace`、`.ftrace`、`.systrace`、`.trace` |

Xcode 负责 App 组合与发布资源；SwiftPM 负责 Trace libraries、CLI 和测试。
该拆分不允许 App 另造 parser 或 CLI 另造 Trace 语义。

## 12. 验收记录要求

真机记录 SHALL 位于 `TASK-AIN-021` 已授权的 `docs/design/**` 中，并至少包含：

- UTC 时间、host/CLI 版本与 current Catalog digest；
- 脱敏 target identity、binding revision、operation reference 与 effective effect；
- terminal state、`outcomeUnknown`、cleanup residue 与 Job ID 的可公开形式；
- exact Artifact ID/name/status/privacy/media type/byte count/SHA-256；
- parser name/version/binary SHA/upstream revision/build recipe；
- inspect/summary 的 range 与至少一类设备实际包含的 timed capability；
- 完整命令的脱敏形式、退出码与不可公开字段的编辑说明。
