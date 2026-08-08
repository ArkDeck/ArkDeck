# ArkDeck macOS 首个实现提案：原生应用骨架与 Device Overview

> Status：ready for implementation
> Baseline：`origin/main@5d84e9565a00663d61c721d8e2d46720a993de3b`
> Design input：`docs/design/macos-ux-interaction-spec.md` draft v0.3、`docs/design/prototype.html`
> Product mapping：P4 App 体验；主要服务 GJ-1 Device Observe，并保持已取得的真实设备结论不变
> Runtime effect：只读呈现 + 已存在的显式 HDC lifecycle recovery 入口；不新增 operation、provider、profile 或 E2 策略
> Hardware required：no（本任务不取得或声称新的真实设备证据）

## 1. 实现结论

本任务只交付第一个可独立使用、可独立验收的现代 macOS 垂直切片：

1. 把当前主窗口整理成原生 `NavigationSplitView` + unified toolbar；
2. 把已有的真实 `HDCDiagnosticsPresentation` 重组为可扫描的 Device Overview；
3. 把自动更新设置移回系统 `Settings` scene；
4. 为尚未接入 production App surface 的 Flash、Debug、UI Dump、Trace、History 显示准确的 unavailable 状态；
5. 保留 HDC recovery 的 preview → exact-generation confirmation → dispatch 三段安全边界；
6. 补齐中英文、键盘、VoiceOver、窗口缩放、深浅色和高对比度验证。

本任务不实现全局 Job Inspector、Flash 提交或其他 Runtime 工作台。当前 App 尚无经 App Sandbox 验证的 daemon transport；daemon 的 `job.plan` 也只返回不入队、不落盘的 preview。实现者不得用本地 fixture、内存假 Job、静态进度或重复展示 HDC 页面来填补这些能力。

## 2. 为什么这是当前正确切片

### 2.1 当前生产缺陷

`ArkDeckApp/App/ArkDeckApp.swift` 目前存在四个直接可见的问题：

- Overview / Flash / Debug / UI Dump / Trace / History 六个导航项都渲染同一份 HDC diagnostics；页面标题变化，但产品能力没有变化；
- 主窗口同时嵌入完整的 `AutoUpdateSettingsView`，与已有 `Settings` scene 重复；
- detail 区重复超大标题，并把所有诊断字段堆进一张 `GroupBox + Grid`；
- toolbar、导航分组、页面级操作、needs-attention 层级和窗口自适应尚未建立。

`ArkDeckApp/Features/HDC/HDCStatusView.swift` 已经接收真实、不可变的 presentation，并且 recovery 回调保持在 Workflows use-case 层。这是适合先现代化的 production surface，不需要先改 Runtime。

### 2.2 与完整 v0.3 的边界

设计稿中的 Job Inspector、Flash、Debug、UI Dump、Trace、History 和 Automation 仍是后续 production surface。只有当 App 能通过已验证的 typed transport 读取对应 Runtime facts 时，才能继续实现。本切片只建立这些页面的真实路由与 unavailable 表达，不建立演示数据源。

### 2.3 重复任务结论

本提案不创建新的 OpenSpec Task：

- `TASK-OBS-002` 已交付 HDC App 观察面，是本次布局重构的历史设计输入；
- `TASK-RKFUI-002` 已描述 Flash plan-only UI 与全局 Job presentation，但其旧 facade / plan artifact 假设与当前 daemon `job.plan` 语义不完全一致，不能直接照抄；
- 当前没有打开的 PR；最近合入的 #1100 只更新设计稿，没有修改生产 SwiftUI；
- `flash.dayu200`、现有 DeviceProviders 和 Runtime Job engine 已存在，本任务不重复创建它们。

实现 PR 可使用 base-tree `TASK-BRC-005` 作为 `scripts/check_pr_paths.py` 的机械路径护栏，因为其 Allowed paths 覆盖 `ArkDeckApp/**`、`ArkDeckAppUITests/**` 和 `ArkDeck.xcodeproj/**`。这不恢复该历史 Task 的 readiness/hardware/evidence 链，也不得修改其 task/evidence 文件或声称完成其 signed Sandbox E0 验收。

## 3. 用户结果

完成后，用户打开 ArkDeck 应获得以下真实结果：

- 首屏在数秒内回答四个问题：HDC server 是否健康、设备信任是否就绪、通道是否受保护、是否有必须处理的问题；
- 可以在一个 Overview 内检查 server/toolchain、device/channel、capability 和 recovery，而不需要扫描二十多行未分组字段；
- `⌘R` 刷新时旧快照不消失，界面明确表示 refresh in progress，并拒绝重复刷新；
- 进入尚未实现的工作流时，看到准确原因和“没有提交任何 operation”，而不是看到另一份 HDC diagnostics；
- 更新选项只在系统 Settings 中出现；主窗口只在 update available / failed 等需要处理的状态显示紧凑入口；
- HDC server recovery 仍必须先预览影响、再确认精确 generation、最后单独 dispatch；危险状态不依赖颜色表达。

## 4. 信息架构与布局

### 4.1 主窗口

使用系统组件，不自绘窗口 chrome：

```text
WindowGroup（最小 900×600，参考 1180×760）
├── Unified Toolbar
│   ├── 系统 sidebar toggle
│   ├── 当前页面标题
│   ├── Overview：Refresh（⌘R）
│   └── 仅需要处理时：Update status → Settings
└── NavigationSplitView
    ├── Sidebar
    │   ├── Device：Overview
    │   ├── Workflows：Flash / Debug / UI Dump / Trace
    │   └── Records：History
    └── Detail
        ├── OverviewWorkspace
        └── UnavailableFeatureView（其余页面，直到 production 接线存在）
```

约束：

- selection 使用 `@SceneStorage`，按窗口恢复；无效值回退到 Overview；
- sidebar 建议宽度 232–300，可由用户拖动；宽度不足时使用系统 collapse 行为；
- 页面标题放 toolbar/navigation title，detail 不再重复 `.largeTitle`；
- 不添加全局背景渐变、固定品牌 accent、大面积半透明卡片或网页式顶部导航；
- 使用系统 separator、control background、accent、label/secondary label；状态色只做辅助；
- SF Symbols 必须与文字同时表达状态，导航和按钮不使用 Emoji。

### 4.2 Overview 顶部状态条

顶部使用紧凑、可换行的 status strip，显示：

1. Server：由 `presentation.serverHealth` 映射 symbol + 本地化状态；
2. Device trust：由 `presentation.authorization` 映射，不从 device events 猜测；
3. Channel：由 `presentation.channelProtection` 映射；
4. Needs attention：由 configuration error、TCP warning、key access error、critical gate、recovery blocked 等当前 presentation 事实计算数量。

状态项必须有文字和 VoiceOver value；不能只显示绿/橙/红圆点。刷新时保留原值，在 status strip 或 toolbar 显示小型 `ProgressView`。

### 4.3 Overview 内容分组

默认采用两个响应式列；窗口较窄时按相同阅读顺序变为单列：

```text
Server & Toolchain
  health / endpoint / client-server-daemon versions
  HDC source / choose executable

Selected Device & Channel
  authorization / channel protection / recent device events

Capabilities
  ownership / subserver capability / lifecycle availability

Needs Attention
  warnings / errors / recovery actions

Advanced Diagnostics（默认折叠）
  absolute path / hash / generation / endpoint source
  ownership basis / automatic dispatch counters
```

实现细节：

- 用 section 标题、间距、`LabeledContent`、`Grid` 或简洁 table row 组织，不把每个字段做成卡片；
- path、hash、generation、counter 使用 monospaced / tabular numbers；长值可中间省略，但必须能复制或展开查看完整值；
- device events 使用有界列表显示 timestamp、kind、redacted identifier，不拼成一条超长字符串；
- raw path、hash、identifier 和 domain reason 保持原值，不翻译、不改写；仅翻译 UI label 和解释性前后缀；
- 保留现有稳定 accessibility identifiers，允许新增 identifier，不任意重命名已有 identifier。

### 4.4 Needs Attention 与 recovery

Needs Attention 只在有事实时展示对应 row。每一项包含：symbol、短标题、具体原因、下一步。推荐按钮文案：

| 语义 | English | 简体中文 |
|---|---|---|
| 选择工具 | Choose HDC… | 选择 HDC… |
| 刷新 | Refresh Overview | 刷新概览 |
| 请求预览 | Preview Server Recovery Impact | 预览服务器恢复影响 |
| 确认 | Confirm Generation %lld | 确认第 %lld 代服务器 |
| 最终执行 | Run Confirmed HDC Recovery | 执行已确认的 HDC 恢复 |
| 重试信任 | Retry Device Trust Check | 重试设备信任检查 |

recovery 交互：

1. `Preview Server Recovery Impact` 只请求 preview，不 dispatch；
2. preview 返回后打开 macOS sheet，逐项展示 action、endpoint、generation、ownership、affected devices、affected Jobs、other clients、expected interruption、recovery path；
3. sheet 默认焦点为 Cancel；`Esc` 关闭；关闭后焦点回到触发按钮；
4. 用户确认当前 generation 后关闭 sheet，页面展示“已确认，但尚未执行”；
5. 最终 dispatch 是独立按钮；dispatch 前仍由既有 use-case 做 generation recheck；
6. blocked / stale / unknown 状态显示原因和安全下一步，不提供看似可继续的默认主按钮。

按钮标题可按 `HDCServerLifecycleAction` 进一步细化，但不得使用“OK”“确定”“继续”这类缺少对象的泛化文案。

### 4.5 未接 production 的页面

Flash、Debug、UI Dump、Trace、History 必须路由到可复用的 `UnavailableFeatureView`。该 view 接收页面标题、SF Symbol 和本地化 reason，不接 fixture 或示例 model。

建议正文：

- English：`This workspace is not connected to ArkDeck Runtime in this build. No operation was submitted.`
- 简体中文：`此版本尚未将该工作区连接到 ArkDeck Runtime，未提交任何操作。`

不得显示假的设备、Job、Artifact、日志、百分比或“即将推出”主按钮。页面可保留只读 scope note，但不能暗示能力已可用。

### 4.6 Settings 与更新状态

- 删除主窗口 detail 中的 `AutoUpdateSettingsView`；
- 保留现有系统 `Settings` scene 及完整 update flow；
- idle / current 状态不占 toolbar；available、failed、awaiting consent 等需处理状态显示紧凑 label，并通过 `SettingsLink` 进入更新设置；
- toolbar 文案必须描述状态，例如 `Update Available` / `更新可用`，不能只显示无名称的 badge。

## 5. 状态管理与并发

- `HDCStatusViewModel` 继续是 `@MainActor`，View 不创建 process runner、provider、journal 或 authority；
- `refresh()` 继续拒绝同一窗口的重复 in-flight 请求；旧 presentation 保持可见；
- navigation 切换不得取消或重建正在进行的 owned refresh；返回 Overview 时显示最新已提交 snapshot；
- importer、refresh 和 recovery 错误分别呈现，后一次成功只清理它实际恢复的错误；
- 任意 async completion 在 task cancellation 后不得覆盖较新的状态；若重构请求管理，使用 generation/token 或 owned task 明确拒绝 stale completion；
- 不为 unavailable 页面启动后台任务；
- 不把 raw domain error 拼进本地化 key。使用本地化标题 + 原始 reason 的两个 Text/accessibility value。

## 6. 可访问性、文字与视觉约束

### 6.1 键盘与焦点

- `⌘R` 只在 Overview 触发 refresh；in flight 时命令 disabled；
- 所有 toolbar command 在 menu command 或系统等价入口可达；
- sheet 支持 `Esc`，默认焦点为取消，关闭后恢复触发点；
- sidebar、toolbar、section controls 和 disclosure 按视觉阅读顺序进入 Tab 序列；
- icon-only control 必须有 accessibility label 和 tooltip；24×24 是绝对最小 target，常用动作优先 32×32。

### 6.2 VoiceOver

- 一个 detail 只有一个主 heading；section heading 连续；
- status item 朗读“类别、状态、必要原因”，不逐字朗读装饰 symbol；
- refresh 完成或 needs-attention 数量改变时使用单一、克制的 announcement；device event 列表不逐行 live announce；
- recovery sheet 标题必须包含动作和对象；风险、影响和按钮不能只靠颜色区分；
- 现有 `hdc.*` accessibility identifiers 继续作为自动化稳定契约。

### 6.3 颜色、字体、动效

- 颜色只使用 SwiftUI/AppKit semantic roles 和 `Color.accentColor`；
- success / warning / danger 同时使用 symbol + text；Increase Contrast 下 section 边界仍可感知；
- UI 使用系统字体；path/hash/ID 用 system monospaced，generation/counter 用 `.monospacedDigit()`；
- 默认不增加自定义动画；刷新只使用系统 progress；若使用状态 transition，Reduce Motion 下改为无位移 crossfade；
- light、dark、Increase Contrast 下均不得出现固定浅色背景、低对比度 secondary text 或仅 hover 可见的关键动作。

### 6.4 本地化

- 所有新增用户文案进入 `ArkDeckApp/Resources/Localizable.xcstrings`；至少提供 English 和 Simplified Chinese；
- 英文使用 sentence case；按钮以动词开头；错误文案包含发生了什么和可执行的恢复动作；
- 不用字符串拼接生成语序敏感句子；generation/count 使用格式参数和 locale-aware formatter；
- raw device/tool/path/hash/reason 原样展示，不“翻译”技术事实。

## 7. 文件级实现范围

允许修改：

- `ArkDeckApp/App/ArkDeckApp.swift`
- 可选新增 `ArkDeckApp/App/AppShellView.swift`
- `ArkDeckApp/Features/HDC/**`
- 可选新增 `ArkDeckApp/Features/Shared/UnavailableFeatureView.swift`
- `ArkDeckApp/Resources/Localizable.xcstrings`
- `ArkDeckAppUITests/HDC/**`
- 可选新增 `ArkDeckAppUITests/AppShell/**`
- 仅在新增文件需要显式注册时修改 `ArkDeck.xcodeproj/project.pbxproj`

禁止修改：

- `Catalog/**`
- `openspec/**`
- `Packages/ArkDeckKit/**`
- `ArkDeckApp/ArkDeckApp.entitlements`
- release/signing/update feed 配置
- HDC process、provider、Runtime Job engine、authority 或 E2 policy

若实现需要修改禁止路径，立即停止并说明缺失的 production contract；不要在本任务中扩 scope。

## 8. 完成条件

以下条件必须全部满足：

### DONE-01 路由真实

每个 sidebar item 只渲染自己的 workspace。只有 Overview 渲染 HDC diagnostics；其余五页显示明确 unavailable reason，且 UI/test source 中没有 fixture result 冒充 production。

### DONE-02 原生窗口层级

窗口使用原生 split view、toolbar 和 Settings scene；主窗口不再显示完整更新设置；最小 900×600 下主操作、needs-attention 和 recovery 入口不裁切。

### DONE-03 Overview 可扫描

server、device trust、channel、needs attention 在首屏可见；详细字段按 4.3 分组；Advanced Diagnostics 默认折叠但所有原字段仍可达。

### DONE-04 刷新稳定

刷新期间保留旧 snapshot、显示 progress、拒绝 duplicate refresh；完成后只提交最新结果。`⌘R` 与可访问按钮行为一致。

### DONE-05 Recovery 安全边界不回退

preview、exact-generation confirmation、dispatch 仍是三个独立用户动作；sheet 完整展示 impact；取消、stale generation、blocked、unknown 均为零 dispatch。UI 不自行构造 lifecycle step。

### DONE-06 状态不依赖颜色

health、trust、protection、warning、error、confirmed、blocked 均有 symbol + text + accessibility value；深浅色和 Increase Contrast 可辨识。

### DONE-07 中英文完整

所有新增 UI 文案在 localization catalog 中有 en / zh-Hans；不存在新增 hard-coded 用户文案；raw facts 保持不变。

### DONE-08 可访问性与焦点

VoiceOver 能按 status → sections → actions 的顺序理解页面；sheet focus trap、Esc、focus return 可验证；现有 accessibility identifiers 未破坏。

### DONE-09 零 Runtime 扩权

diff 中没有新增 process/argv/raw command、daemon client、Catalog、provider、entitlement、authority、device mutation 或 destructive dispatch。任务不声称新的真实设备结果。

## 9. 测试矩阵

### 9.1 必须保留的现有测试

- `ArkDeckAppUITests/HDC/HDCStatusUITests.swift` 全部通过；
- refresh coalescing、HDC bookmark、denied/timed-out/key-access、impact preview、critical gate 和 zh-Hans 场景语义不回退；
- 现有 presentation-only source guard 继续证明 App View 不持有 process/argv 或 lifecycle bypass。

### 9.2 新增 UI 测试

至少覆盖：

1. Overview 首次启动的四项 status 和分组结构；
2. 逐个选择 Flash / Debug / UI Dump / Trace / History，均显示对应标题、unavailable reason 和“未提交任何操作”，且不显示 HDC diagnostics / update settings；
3. `⌘R` refresh delay fixture：旧 snapshot 可见、progress 可见、重复请求不增加 dispatch；
4. Advanced Diagnostics 展开后 path/hash/counters 的既有 identifier 和完整值可达；
5. recovery preview sheet：完整 impact、默认取消、Esc、确认后仍需独立 dispatch；
6. English 与 zh-Hans 关键 label；长中文在 900×600 下不覆盖主按钮；
7. update settings 不在主窗口，Settings scene 仍能打开；
8. status 在去色/高对比判断中仍有 symbol 和文字，不只依赖前景色。

UI test fixture 只能注入 presentation 值和延时，不得创建 fake process/device/Job 结果；测试名称和断言必须明确 fixture，不得记为真实设备 evidence。

### 9.3 实现期视觉检查

实现者至少人工检查以下组合，可用截图作为 PR 讨论材料，但不把截图当功能验收：

- 1180×760 light / dark；
- 900×600 light / dark；
- Increase Contrast；
- Reduce Motion；
- English / Simplified Chinese；
- sidebar 展开 / 收起；
- recovery sheet 键盘遍历和 focus return。

### 9.4 本地门禁

```bash
xcodebuild test \
  -project ArkDeck.xcodeproj \
  -scheme ArkDeck \
  -destination 'platform=macOS'

sh scripts/check-sdd.sh
.venv-sdd/bin/python -m unittest discover -s scripts/catalog_gen -p "test_*.py"
.venv-sdd/bin/python scripts/catalog_gen/generate.py --check
swift test --package-path Packages/ArkDeckKit --parallel --num-workers 8
git diff --check
```

最终 commit subject 必须包含 base-tree Task ID，例如：

```text
feat(TASK-BRC-005): modernize the macOS device workspace
```

push 前运行：

```bash
python3 scripts/check_pr_paths.py \
  --repo-root . \
  --preflight \
  --base-revision origin/main \
  --head-revision HEAD
```

如果最终 diff 超出 `TASK-BRC-005` base-tree Allowed paths，停止并缩回范围；不得修改旧 task 来扩张 Allowed paths。

## 10. PR 交付要求

- 一个 production PR 同车交付 SwiftUI、localization、必要测试和最小实现说明；
- PR 标题如实写“macOS Device Overview / shell modernization”，不声称全设计稿、Flash UI 或 Job Inspector 已完成；
- PR 正文说明 root cause、用户可见变化、未实现页面为何显示 unavailable、安全边界、测试命令与结果；
- 不修改旧 OpenSpec task 状态，不创建 readiness/evidence/archive PR；
- 不把 host-only UI test 记为真实设备验证；GJ-1 保持 `REAL_DEVICE_PASS`，本 PR 改善的是 P4 呈现。

## 11. 实现者开工指令

将下面内容直接作为 AI 的实现请求：

```text
请实现 ArkDeckApp/Documentation/macos-ui-implementation-proposal.md。

先完整读取 AGENTS.md、PRODUCT-LOOP.md、docs/design/macos-ux-interaction-spec.md、
当前 ArkDeckApp/App/ArkDeckApp.swift、ArkDeckApp/Features/HDC/HDCStatusView.swift
以及现有 HDC XCUITests。按提案的 DONE-01...DONE-09 实现并验证。

这是一个 production SwiftUI 垂直切片：只做原生 App shell + 真实 Device Overview。
未接 Runtime 的页面必须显示准确 UNAVAILABLE；不得添加 demo Job、fake progress、raw
command、daemon transport、provider 或新的设备执行入口。保持 preview → exact-generation
confirmation → dispatch 三段 recovery 边界。

使用 TASK-BRC-005 仅作为 base-tree CI 路径护栏，不修改任何旧 task/evidence 状态。
完成代码、localization、XCUITest、本地门禁、commit、push，并提交一个 ready-for-review PR。
```

## 12. 硬停止条件

遇到以下任一情况，AI 必须停止扩写并报告具体缺口：

- 需要 App 连接 agent daemon、读取 Runtime Job/Artifact 或提交 operation；
- 需要修改 App Sandbox entitlement、socket 路径、integration/device profile；
- 需要改变 `HDCDiagnosticsPresentation`、HDC lifecycle safety contract 或 E2 policy；
- 设计要求的数据在 production presentation 中不存在，只能靠 fixture 或推断补齐；
- recovery 的 exact-generation recheck 无法继续由现有 use-case 保证；
- 最终 diff 无法被 base-tree Allowed paths 完整覆盖。

停止时只报告一个最小 product contract 缺口和受影响的 DONE 条件，不创建新的 OpenSpec change、readiness 或 verification task；是否扩大任务由维护者决定。
