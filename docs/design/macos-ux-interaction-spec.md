# ArkDeck macOS UX 与交互定义

> Status：draft v1.3（design input，非 normative；2026-08-25 v1.2 新增独立 Toolkit tab、把 Diagnostics 调整为低干扰默认，并按当前 SwiftUI 实现回写 Viewer / Trace 页面结构（后续稿件变更必须与实现同车）；同日 v1.3 按设计评审修订：Diagnostics 的 Marker 改为「标记 + 环形缓冲回溯取证」、截图按实际拍摄时刻标注、新增自动 Marker、对齐承诺分两阶段、event identity 不被非事件点击清空；Toolkit 输入闭集扩为 tap/longClick/swipe、两态触点反馈、画面年龄与过期输入暂停、第一版录屏为宿主逐帧合成。详细2026-08-26 按当前 SwiftUI 实现回写 Debug 页面结构:五个 tab 的分组改为 section 标题加细线，Artifacts 改为单个已签名 app-owned `.so` 的本地 / 只读 SSH 来源流程，交互原型的 Debug 页同车重写。详细设计见 [`diagnostic-mode-design.md`](./diagnostic-mode-design.md) 与 [`toolkit-device-control-design.md`](./toolkit-device-control-design.md)；对应 OpenSpec 提案 `openspec/changes/chg-2026-071-interactive-device-control/`）
> 交互原型：`docs/design/prototype.html`（可点击，与本文档同版本演进）
> 行为事实源：`openspec/specs/desktop-ux-observability/spec.md`、各 capability spec、Catalog 与 Runtime contracts；本文档只定义 HOW（布局、组件、层级与流转），行为冲突时以事实源为准
> Promotion：本目录是草稿区。被采纳的版本在起草 M2+ 功能 change 前移入 `openspec/platforms/macos/design/`，并由 change 的 `design.md` hash-pin。设计中发现的行为级缺口必须走 behavior delta，不能只画进稿子。

## 0. v1.2 目标与当前实现边界

v1.2 保留 v0.8 Viewer、v0.9 Debug、当前精简 Trace 工作区和既有 Diagnostic Session Viewer，在 Diagnostics 之后新增独立 **Toolkit** tab。Diagnostics 默认只持续采集 Trace 与 HiLog，Marker 触发按需截图；连续录屏是明确 opt-in。Toolkit 的第一个工具是「真机操作」：默认显示最后一次确认截图，用户可独立获取截图、开启 5 fps 低帧率预览、开始有界录屏，以及发送一次点击或滑动。Diagnostics、Trace 与 Toolkit 各自保存 view state、配置和运行状态，互不替换，也不会静默开启彼此的高开销 channel。

当前代码与目标设计的边界必须如实呈现：

| Surface | 当前实现 | v1.2 设计方向 |
| --- | --- | --- |
| App shell | SwiftUI `WindowGroup` + `NavigationSplitView`；Overview / Flash / Debug / Viewer / Trace / History / Automation 均有实际工作区 | 保留原生 split view；在 Trace 后新增 Diagnostics 与 Toolkit；统一 toolbar、全局 Job inspector 与窗口自适应 |
| Device detail | 未授权设备有接管引导；已接管设备能显示真实 binding / observation facts，并有原生右键重命名和重新检测 | 删除重复内容标题；宽屏拆分状态操作与事实；名称只是 App 展示别名，重新检测只刷新候选事实 |
| Overview | `HDCStatusView` 展示 HDC、授权、通道、Rockchip 访问诊断与 target-bound 能力矩阵 | 分组为「服务器」「设备与通道」「能力」「需处理事项」，unknown 与 unavailable 不合并 |
| Viewer | `UIDumpWorkspaceView` 已实现首次空态、显式 target、typed「抓取视图」、同 Job Artifact 校验，以及截图 + UI 树/节点属性联动检查器 | UI 稿直接镜像当前实现；不再把已经落地的 Viewer 写成未来方向 |
| Debug | `DebugWorkspaceView` 已有 Artifacts / Logs / Apps / Network / Commands 五个 tab，Artifacts 为默认项;已发布单个 app-owned `.so` 的本地文件与只读 SSH 来源选择、ELF / ABI / Build ID / hash 校验、备份、原子发布、Ability restart、加载 readback 与失败回滚，SSH 来源在「设置 › 服务器」中管理;每组以 section 标题加细线分组，Runtime 可用性只在标题旁一行呈现 | 默认进入 Artifacts；管理 SSH、本机目录、SMB、WSL 来源及其根目录，搜索、勾选、预览替换计划，完成替换后显式提供重启与日志验证。未发布的来源浏览、批量、`.abc` 与独立设备重启能力必须显示 unavailable，不用原型状态伪造生产可用性 |
| Trace | 主窗口是精简的「抓取 Trace / 查看 Trace」两段式入口；原生 Timeline 在独立 ArkDeck Trace Viewer 窗口中打开 | UI 稿镜像当前入口，不复活自定义 tag、参数 diff、派生产物 dashboard 或页内 Timeline 模式；Diagnostics 不复用或改写 Trace 状态 |
| Diagnostics | 尚无独立 production surface；现有 `capture.diagnostics@1` 能产出 bounded HiLog、单张截图、UI dump/tree 和 raw Trace，但没有屏幕视频、并发/环形采集、会话内准入或跨来源 clock calibration；截图腿会把作业升级为 deviceMutation | 以独立 Diagnostic Session 统一采集 / Viewer；Trace/HiLog 以环形缓冲回溯保存，Marker 只记时间点、截图事后拍摄并标注 `+N ms`，自动 Marker 补齐人工反应延迟；连续录屏需明确开启。选择 Trace event 时联动可用截图/视频与日志；第一版对齐只承诺 `同一时钟` / `无法对齐` 两态，`已校准 ±N ms` 待 ground-truth 实验。原型中的环形采集、自动 Marker、视频与校准仍是目标设计，不代表 production availability |
| Toolkit | 尚无独立 production surface；截图、录屏、点击和滑动也未必存在对应的已发布 operation / Provider lowering；OHOS 无已知设备侧录屏命令面；交互输入的端到端延迟未测 | 以独立 Toolkit 集合承载小工具，第一个工具为「真机操作」。默认按需截图；低帧率预览常显实测帧率与画面年龄、过期时输入暂停；第一版录屏为宿主逐帧合成（Assembling→Validating，无设备残留），设备侧编码 Spike-gated；点击/长按/滑动两态反馈（pending→confirmed）、绑定精确 target、binding、显示尺寸、方向与画面 epoch，排队超时输入作废。缺少已发布 typed operation 或延迟门槛未达标时显示 unavailable，绝不以 raw HDC 兜底 |
| Settings | 已有独立 macOS `Settings` scene，但当前 AppShell detail 同时内嵌 `AutoUpdateSettingsView`；自动更新检查、下载、校验和 Finder handoff 已接通 | App 主窗口不再内嵌完整更新设置；toolbar 只显示需要注意的更新状态，详细设置回系统 Settings scene |
| Runtime capability | Catalog 已发布 observe / diagnostics / HAP / Flash / port-forward 等 typed operations；Harness 有持久化 task lifecycle | UI 只提交 operation reference + typed inputs；展示 availability、effect 与受控 lowering disclosure，绝不提供 raw command 输入 |
| Runtime data | Trace tag / 参数快照、Debug probe、Flash prerequisite / postflight、Artifact metadata 均有生产 facade | 缺失字段显示 unknown / unavailable，不使用 fixture、占位行或默认值补齐 |

## 1. 现代 macOS 设计原则

1. **原生层优先**：优先使用 `NavigationSplitView`、`ToolbarItem`、`Table`、`Form`、`Inspector`、`Settings` 和系统 alert/sheet；自绘只用于原生组件无法表达的 Job 阶段、Artifact 来源和 effect 状态。
2. **导航与内容分层**：sidebar 与 toolbar 是导航/控制层，内容区是工作层。材料和模糊只用于前两者；内容本身保持平静、清晰、可长时间阅读。
3. **少卡片，多分组**：同一工作流内以 section 标题、间距和 table row 分组；只有可独立移动、选择或产生状态的对象才使用有边界的 container。
4. **跟随系统个性化**：sidebar icon、主选择态和 focus ring 跟随 macOS accent color。品牌色不覆盖用户选择；状态色只承担成功、警告和危险语义。
5. **高信息密度但不拥挤**：优先同时显示设备、阶段、证据和操作，减少弹窗与层层 drill-down；长表允许排序、筛选和列宽调整。
6. **所有控制都有键盘路径**：toolbar 命令同时出现在 menu bar；支持 `⌘R` refresh、`⌘F` search/filter、`⌘⇧J` 展开 Job inspector、`Esc` 取消或关闭 sheet，并恢复焦点。

以上方向与 Apple 当前 macOS HIG 一致：Mac 工具应利用大屏减少嵌套、支持窗口缩放和键盘工作流；sidebar 使用熟悉 symbol 并尊重系统 accent；toolbar 位于窗口 frame 内且命令在 menu bar 有等价入口。

## 2. 视觉 token 与平台映射

实现使用 SwiftUI/AppKit semantic color，不把原型 fallback 色值写进产品代码。

| 角色 | SwiftUI / AppKit 意图 | 原型 fallback | 用途 |
| --- | --- | --- | --- |
| window | `windowBackgroundColor` | light `#F5F5F7` / dark `#1C1C1E` | 内容底 |
| sidebar material | `.sidebar` / system material | 半透明 system gray | sidebar 与 toolbar |
| surface | `controlBackgroundColor` | light `#FFFFFF` / dark `#2C2C2E` | grouped section、table、popover |
| text primary | `labelColor` | `#1D1D1F` / `#F5F5F7` | 主文本 |
| text secondary | `secondaryLabelColor` | `#6E6E73` / `#AEAEB2` | 辅助文本 |
| separator | `separatorColor` | 半透明 system gray | split divider、table row |
| accent | `Color.accentColor` | system blue | 选择、链接、主操作、focus |
| success / warning / danger | system green / orange / red | 语义变体 | 状态；必须同时有 symbol + 文字 |
| planned / simulated | purple / orange outline | 同 | execution mode；不使用实心大面积背景 |

字体只用系统字族：UI = SF Pro；代码、路径、hash、Job/Session ID、日志 = SF Mono。推荐角色：window title 13/semibold、page title 20/semibold、section title 13/semibold、body/control 13/regular、secondary 12/regular、monospace 11–12。变化中的时长、bytes、round、PID 使用 tabular numbers。

基础尺寸：toolbar 52；sidebar 232–300（用户可拖动）；导航 row 32；常规 control 28–32；section 内 gap 8–10，section 间 gap 20–24；内容边距 20–24；同心圆角自外向内 container 11 → 内嵌 box 9 → control 7（原型 `.card` 一直是 11，本文档此前写 10，两者以 11 为准）。桌面最小 target 24×24，空间允许时使用 32–40；任何扩展 hit area 不得重叠。

## 3. 窗口骨架与自适应（REQ-UX-001）

```text
Primary Window
├── Unified Toolbar
│   ├── leading：Sidebar toggle + 当前页面标题
│   ├── center：当前设备 scope（必要时）/ 页面级 segmented control
│   └── trailing：搜索/刷新/唯一主操作 + Job inspector toggle
├── NavigationSplitView
│   ├── Sidebar：Devices、Workflows、History
│   └── Detail：Recovery / HumanActionRequired banner + 当前工作区
└── Bottom Job Inspector（跨页面、可拖动高度、可折叠）
```

- 参考窗口 1180×760；最小 900×600。宽度不足 980 时先把双栏内容改为单栏；不足 760 时 sidebar 可自动收起，但必须保留 toolbar toggle 和 View menu 命令。双栏在可用宽度足够时应使用 detail pane 的主体宽度，不能把内容永久锁在窄卡片中并留下大面积无意义空白。
- Sidebar 只保留两级以内层级，不在底部放关键动作。设备与工作流分组；Settings 使用系统 `Settings` scene，不作为 sidebar 最后一项伪装成普通页面。每个固定导航 row 的可见名称、稳定 identifier、selected state 与整行非零 AX hit frame 必须属于同一 accessibility element；不得只把 identifier 挂在无法激活的虚拟文本子节点上。
- 页面标题在 toolbar，内容区不重复同一主标题。需要解释的页面用紧凑 section title + subtitle；滚动后 toolbar 仍提供上下文。
- 表格和日志可以 full-bleed 到 detail pane 的分组边缘；文字、筛选器和操作保持 content inset。
- 需要同时检查清单与详情时使用三栏 split view（History、Automation Attempt）；其他页保持两栏，避免永久空 inspector。

## 4. 横切交互模式

### 4.1 全局 Job Inspector（AC-UX-001-01）

- 折叠态 36pt：运行中数量、最高风险 Job 的 symbol/阶段/elapsed、indeterminate 或真实进度、展开按钮。
- 展开态 220–320pt，可拖动：左侧 Job 列表，右侧阶段、当前 typed operation、目标 binding、预算、日志尾部 200 行和 Artifact 增量。
- 取消按钮直接使用 `CancellationPolicy` 文案，如「在安全边界停止」；critical step 期间显示后续动作会停止，但当前写入不会被强杀。
- plan-only / simulated 在标题、列表、History、详情与导出中永久保留 outline badge（REQ-UX-006）。
- 状态变更写入稳定的 accessibility live region；日志流本身不逐行播报。

### 4.2 Recovery 与 HumanActionRequired（REQ-UX-003）

- Recovery banner 位于 detail 顶部、页面内容之前，但不覆盖 toolbar；分为 resume-safe、waiting、outcomeUnknown、archivable。
- `outcomeUnknown` 使用 system warning symbol + 明确文字，只有 RecoveryGuide 与显式归档；不渲染看似可继续的主按钮。
- 「结束恢复并归档为已中断」sheet 明确三个“不会”：不证明设备恢复、不停止远端任务、不回滚参数。critical child 未到安全边界时禁用并说明原因。
- Harness 的 `humanRequired` 复用同一 banner family，显示 block 类型、reasonCode、证据、最小人工动作和将恢复到的 stage；不使用笼统「继续」。

### 4.3 危险确认 sheet（REQ-UX-005）

- 需要独立决策的 host-wide 或非计划内危险动作使用 macOS sheet，而非居中网页 modal。标题 = 动词 + 对象；正文固定展示 identity / binding、effect、不可逆内容、recovery path。默认焦点在取消；`Esc` 关闭；Tab 不离开 sheet；关闭后焦点回触发按钮。
- Flash 是已发布 typed operation 的专用例外：Exact Plan、目标、镜像、分区、userdata 影响、供电要求和 bootloader / 厂商恢复路径已在同一页面按阅读顺序完整展示后，直接提供一个完整命名的主按钮「擦除用户数据并刷机」。不再打开第二个 sheet，不要求勾选框或输入确认短语。
- 点击 Flash 主按钮只是对已展示影响的 UX acknowledgement，不是 Runtime authority。Runtime 仍须在首个外部 effect 前重新 materialize plan，并以 fresh target / binding / tool / Artifact facts 与 Runtime-owned capability fail closed 准入。

### 4.4 Availability、effect 与状态

- 页面先展示 Runtime 返回的 `AVAILABLE` / `UNAVAILABLE(reasonCode)`，再允许配置；Provider、Target facts、plan lowering 不完整时不展示可执行主按钮。
- effect 统一为 symbol + 文案：`hostOnly`、`readOnly`、`deviceMutation`、`destructive`。状态色只辅助，不作为唯一判断。
- execute 无 badge；plan-only = 紫色 outline「PLANNED」；simulated = 橙色 dashed outline「SIMULATED · fixture id」。

## 5. 页面定义

### 5.1 Overview（REQ-UX-002）

- Toolbar：设备 scope、`⌘R` 刷新、必要时「选择 HDC…」。刷新中保留原快照并显示小型 progress，不让内容跳空。
- 顶部 status strip：HDC server health、target ready、channel protection、需要处理数量。
- 内容按四个 section 排列：Server & Toolchain；Selected Device & Binding；Capabilities；Needs Attention。path/hash 允许复制，长值用中间省略且可查看完整值。
- 能力矩阵只显示生产探测的 `hidumper`、`hitrace`、`bytrace` 与 Catalog 发布状态 `RockUSB Flash`；不得硬编码设备、虚构 `flashd` 探测或把 probe failure 写成“不存在”。
- Rockchip 访问诊断必须把 `permissionDenied`、`driverUnavailable` 与 offline / unauthorized 分开显示，并给出责任方、ArkDeck 外的最小修复步骤和可否重新探测；不得建议 App 自行 sudo、安装驱动或放宽全局权限。
- recovery preview / exact-generation confirmation / dispatch 保持三步，不合并成一个“修复”按钮；host-wide 影响用 sheet 列出 affected devices / Jobs / other clients。

### 5.2 设备接管与授权（REQ-HDC-007）

- 设备行是**设备详情导航**，不是全局 scope：选择 ready / offline 行进入该设备详情，选择 unauthorized 行进入同一详情中的接管引导。Flash、Debug、Viewer、Trace 等工作区必须继续展示并提交自己的显式 target / binding，不得暗中继承最近选中的设备行。
- Sidebar 未授权设备行显示 warning symbol +「需要信任」，选中后 detail 显示三步 onboarding：解锁 → 设备端信任 → 有界等待。
- 已接管设备详情只在 toolbar 保留一个主标题。内容按「当前状态与操作」和「Runtime 事实」组织：参考宽屏左右双栏，窄窗按阅读顺序垂直堆叠；connect key、target、binding revision、model、firmware、transport 和确认时间都来自 Runtime projection，缺失即不显示，不以演示值补齐。
- 设备行右键使用原生 context menu：`重命名…` 只修改 App 本地展示别名，不改变 connect key、target identity 或 binding；`重新检测` 重新读取整个候选列表，既不向设备发送 mutation，也不承诺候选仍存在。菜单项同时提供键盘可达的详情内操作。
- E000002（等待）与 E000003（拒绝/超时）分状态；retry 是普通按钮。重启 shared HDC server 属独立危险 sheet，绝不成为默认修复。
- production authorization verdict 由 `device.candidates` 的 domain-owned durable binding 刷新入口生成；App 只解码并展示 `authorized` / `pending` / `timedOut` 等闭集事实，不构造 `DurableCurrentDeviceBinding`。`denied` 在生产 probe 尚无判据时不得由 fixture 推断。

### 5.3 Viewer

- 用户可见名只使用 `Viewer`；`ArkUI dump` 只用于描述数据源、树和 raw Artifact，不作为页面名或导航名。
- 初次进入先显示实现中的空态：「没有已验证的 capture」以及 typed Runtime Job / 同 Job Artifact 说明。此时 toolbar 只显示显式设备、搜索和主操作「抓取视图」；不得用演示截图伪装成已有 capture。
- 有已验证 capture 后，toolbar 才增加当前屏幕/root、精确抓取时间，并把主操作改为「重新抓取」。搜索有内容时原位显示匹配序号与上一个/下一个结果按钮；刷新 Viewer 仍位于窗口 toolbar。
- 截图和 dump 树必须来自同一次 capture epoch；任一侧缺失或时代不一致时不得建立可点击映射。
- 宽屏使用左右双区：左侧「设备截图」；右侧参考 Chrome DevTools Elements 检查器纵向分为「UI 树」和「节点属性」。同一选中组件在截图中用 accent 边界框标记、在树中使用唯一选中行，并立即刷新下方属性。截图或树发起选择都必须更新另外两处。
- 「显示组件边界」默认关闭；当前组件始终使用 2px accent 边界和 `#<componentId> <type>` 标签。打开开关后才显示其余节点的低对比度边界。重叠 bounds 命中最深的可见节点；父节点可从 breadcrumb 或树中选择，不用多个重叠透明热区争抢指针事件。
- UI 树是完整节点序列，默认展开到当前节点并自动滚动使其可见；深层缩进不截断节点名，树区域同时支持横向与纵向滚动。搜索只改变树的呈现，不改变 capture 与选中 identity。树遵循 macOS outline keyboard pattern：上下移动，左键折叠或返回父节点，右键展开或进入首个子节点，Enter / Space 选择。
- 下方节点属性区使用「属性 / 布局 / 无障碍 / Raw dump」分类。结构化字段只作为快速阅读；`Raw dump` 必须保留该节点的全部原始字段，不因 UI 未识别字段而丢失信息。
- 选中后不强制移动键盘焦点；变化通过稳定的 polite status 播报。截图可点区域与树行都使用原生 button 语义和可见 `focusVisible`，不只依赖颜色表达选中。
- UI 树默认获得右侧较多高度；树与属性之间使用可拖动的水平分隔条，键盘可用上下方向键微调、Home / End 跳到允许范围两端。调整只改变可视比例，不改变节点选择和滚动身份。
- 窗口变窄时仍保持右侧「UI 树在上、节点属性在下」的关联结构；无法容纳左右双区时按「设备截图 → 右侧检查器」单列排列。任一宽度下当前节点、搜索、树的双向滚动和 raw 信息都不可被裁掉。
- footer 使用生产 capture metrics 的阶段名：nodes、submit、run、list、read(bytes/time/throughput)、parse 与总时长；未采集 metrics 时明确显示「未测量」，不显示演示健康结论。
- Viewer 数据默认本地保存且按敏感 Artifact 处理；导出前仍须预览和确认。Fault/Crash Artifact 与整机诊断快照不得伪装成 Viewer 中的另一类节点。

### 5.4 Trace

- Trace 主窗口固定为一条 secondary summary 和两个顺序 section：「抓取 Trace」在上，「查看 Trace」在下；不使用双栏 card dashboard，也不在内容区重复页面标题。
- 「抓取 Trace」header 右侧显示 `正在检查… / 可以抓取 / 暂时无法抓取`。表单只保留显式设备、抓取场景和时长；抓取场景是单一 picker，不再提供 Preset / Custom 模式或直接 tag 编辑。
- 时长由十进制输入、秒/分钟 segmented unit 和快捷值组成：秒为 15 / 30 / 45 / 60，分钟为 1 / 2 / 3。Runtime request 始终规范化为秒；无效输入在原位显示范围错误。
- section footer 左侧只呈现一个可行动状态：本地保存说明、正在抓取、terminal 结果、outcome unknown 或首个 blocker；右侧是「开始抓取」，有 active Job 时替换为 Job ID +「取消抓取」。完整进度、参数、计划和 Artifact 事实留在全局 Job Inspector / History，不重新塞回页面。
- 「查看 Trace」只显示本地/最近 Trace 说明和「打开 Trace 查看器」。最近一次抓取通过唯一 published raw `trace.htrace` 校验后可显示就绪文件名；校验失败提供同一入口的重试，不画 Artifact 列表 dashboard。
- Trace Viewer 是 ArkDeck 的独立窗口，不替换主窗口 detail。Viewer toolbar 提供 Capture、Open、reload、search、zoom 和 Inspector；返回 Capture 聚焦/打开主窗口的 Trace 页面，不复制第二套设备控制面。
- 自动进入 Viewer 之前必须从本次 terminal Job 精确选中唯一的 published raw `trace.htrace`，经 sensitive opt-in 的 Artifact API 分块读取，并同时匹配 byte count 与 lowercase SHA-256。任一校验失败不替换当前文档、不写 Recent、不启动 parser。
- Timeline 使用原生 AppKit/CoreGraphics 画布，包含 CPU slice、thread state、named slice、counter 和 frame lane。滚动 / 捏合、键盘、range/event selection、flag、mark 和 search 都操作真实 event identity，不从像素位置伪造事件。
- Process filter 与 trace search 分开；隐藏 lane 时保留 view state，搜索命中可显示必要 lane 并滚动到真实事件。Inspector 可停靠在右侧或底部，窄窗只改布局不丢失选择。
- 加载中只有 hashing、cache lookup 与 indexing 拥有真实 denominator 时才显示百分比；TraceStreamer stdout 无可靠进度时使用 indeterminate。空 timed events、缓存隔离重建、schema 不兼容、取消与 parser identity drift 必须显示不同状态。
- 所有 toolbar 动作在 Trace menu 有键盘等价入口，完整快捷键目录位于 Help 菜单。Timeline 焦点、选区、搜索结果与状态变化有稳定无障碍语义；不以颜色作为唯一信号，并尊重 Reduce Motion。

### 5.5 Diagnostics

- Diagnostics 是 Trace 之后的独立 sidebar tab，包含「新建诊断」和「Diagnostic Session Viewer」两种状态。它不替换 Trace、不打开 ArkTrace 独立 App shell，也不读写 Trace 的 preset、时长、筛选、选择、Recent 与运行状态。详细行为见 [`diagnostic-mode-design.md`](./diagnostic-mode-design.md)。
- 新建诊断默认提供「低干扰诊断」与「图形诊断」preset。Trace 与 bounded HiLog 以环形缓冲/缓冲区回溯方式采集（在 Marker 或停止时回溯保存问题前窗口）；Marker 只记录时间点并触发一次事后截图；自动 Marker（frame deadline missed / crash 触发，默认开）补齐人工反应延迟；屏幕录制是默认关闭的 optional channel，只有用户明确勾选后才加入 Session。preset 只组合 reviewed typed inputs；高级 disclosure 才展示 duration、Trace categories、HiLog filters、Artifact byte budget 与 optional channels。设备未确认支持 required channel（含环形能力）时在主操作旁显示 unavailable 原因，不把 unsupported tag 或 channel 伪装成可选。
- 点击「开始诊断」后先进入 Arming；只有 required channel 全部 recording，界面才显示「采集已开始，现在开始复现」。录制中突出 elapsed / bounded limit、精确 target / binding、各 channel 状态和 Marker 数量，提供「标记并截图」（`⌘M`）与「停止并生成结果」。手动 Marker 立即记录时间点，截图先显示「正在截图…（事后拍摄）」，完成后显示「拍摄于标记后 +N ms」；截图失败时 Marker 保留并显示原因。无可靠总量时只显示阶段和 elapsed；屏幕录制关闭时明确显示「无持续取帧」。采集期间对同一设备的其他 mutation（含 Toolkit 输入）在 in-session 准入语义发布前 fail closed 并解释原因。
- Diagnostic Session 以 Session monotonic time 为主轴。Trace event、视频 frame PTS 和 HiLog timestamp 都通过带适用区间与 `maxError` 的映射进入该时间轴；UI 词表为 `同一时钟`、`已校准 ±N ms`、`无法对齐` 三档，但**第一版只承诺前后两档**——`已校准 ±N ms` 在 ground-truth 实验量化误差后才启用，任何 ±N ms 数字在此之前不进产品 UI。重启、重连、recorder restart 或 timestamp 回退切断 alignment segment，并在 Timeline 画 gap。
- Viewer 顶部同时显示「当前画面」与「当前时间上下文」，底部为全宽 Timeline。当前画面在 Marker 截图的实际拍摄时刻（±150 ms）显示截图并固定标注「拍摄于 Marker 后 +N ms」；Session 明确包含录屏时，才按 `frame.pts ≤ t < nextFrame.pts` 解码视频帧并显示 `Δt`。没有覆盖光标的画面证据时显示缺口，不沿用旧截图。右侧展示选中 event 与默认 `±100 ms` 日志；点击截图、视频或日志只移动光标，不凭时间接近伪造 Trace event identity，**也不清空已选 event 的 identity**——光标离开事件区间时详情面板保留并显示偏离标注。
- Timeline Track 顺序固定为 Marker → Screen → Frame/Display → CPU/Process/Thread → HiLog → 有事实的平台扩展 Track。所有 Track 共用一个 ruler、time cursor 和 selection range；Track header 固定，时间内容水平滚动。录屏 gap、secure surface、日志无法映射或 alignment 超限都保留可见缺口，不能沿用旧帧。
- 第一版默认保存 Marker 截图，不进行持续取帧；用户明确开启录屏时才保存原始视频和 frame index，且不长期保存逐帧 PNG。视频按需解码；thumbnail、frame index、HiLog index 与 linkage index 都是可重建 derived Artifact，必须记录 raw source hash、tool identity、参数、size 和 hash。
- 当前 `capture.diagnostics@1` 只有单张 `screenshot.png`，没有屏幕视频、并发 channel boundary 和 clock calibration。原型必须持续展示 production-boundary callout；未来接入需要 reviewed operation/Provider contract，不能从 App 执行 raw HDC 或把同 Job identity 当成时间同步证明。
- 自动进入 Viewer 前，必须从 terminal Job 精确选择并校验每个 published Artifact 的 status、privacy、byte count、lowercase SHA-256 和内容类型。任一 Artifact 校验失败只隔离该 Artifact；Session 可 truthful 地进入 Partial，但失败内容不写入 viewer index、不替换已打开内容。
- Trace 解析仍复用 ArkTrace 原生 AppKit/CoreGraphics timeline、真实 event identity、cache 和 query。滚动 / 捏合、键盘、range/event selection、flag、mark 与 search 不从像素位置伪造事件；Process filter 与 trace search 分开，隐藏 lane 时保留 view state。
- 所有 toolbar 动作在 Diagnostics menu 有键盘等价入口。Timeline 提供可聚焦 slider 语义，方向键移动光标、`Shift + 方向键` 扩展 range、`⌘M` 添加 Marker；离散 marker/event 仍可单独 Tab 到达。状态使用 symbol + 文案，动态变化通过稳定 polite status 播报，并尊重 Reduce Motion。

### 5.6 Toolkit · 真机操作

- Toolkit 是 Diagnostics 之后的独立 sidebar tab，内部使用紧凑工具列表；第一个工具为「真机操作」。后续工具只有在对应 typed operation 已发布后才出现，不预留一排不可用卡片，也不提供 raw shell。完整设计见 [`toolkit-device-control-design.md`](./toolkit-device-control-design.md)。
- 真机操作默认显示最后一次确认截图、获取时间和 stale 状态，不持续从设备取帧。用户可手动「获取截图」（先显示 pending，成功后原位替换）；低帧率预览与有界录屏彼此独立，开始录屏不会自动开启预览。预览常显**实测帧率与画面年龄**（5 fps 是目标值），画面年龄超阈值或断流时输入面进入暂停；第一版录屏为宿主逐帧合成（停止后 Assembling → Validating，无设备端拉取与残留），设备侧编码录屏与 remote artifact reference 是 Spike-gated 目标形态。两者旁边持续显示会改变设备负载的提示。
- 页面固定为：顶部精确 target / binding / display facts 与画面动作；左侧设备画面；右侧操作方式、操作记录和性能提示。设备画面是唯一主要输入面，不显示坐标表单。窄窗按工具列表 → target → 画面 → 操作说明 → 边界说明排列，不隐藏主操作。
- 画面不提供「点击 / 滑动」模式切换：一次 primary pointer sequence 位移 `<6 pt` 且按住 `<500 ms` 转换为 tap、位移 `<6 pt` 且按住 `≥500 ms` 转换为 longClick（两者坐标锚定 pointer down 位置，长按不得静默降级为点击）；位移达到阈值转换为 swipe，起点、终点与 duration 直接来自 pointer down / move / up。拖动期间只显示本地轨迹，pointer up 时恰好提交一个 typed intent。键盘使用方向键移动虚拟指针、Enter / Space 点击、`Shift + 方向键` 滑动；非闭集手势就地提示「该手势不会发送到设备」。每次发送前重新验证 target、binding revision、display size、orientation 与画面 epoch；任一事实变化都拒绝旧映射并要求刷新画面。
- 每个输入 intent 提交后 ≤100 ms 显示 pending 触点（空心），结果事实到达才转 confirmed（实心）；failed / unknown 在触点原位显示符号。排队滞留超过阈值的输入作废并显示「画面已过期，输入未发送」，绝不延迟补发。操作记录展示提交时间、坐标与 pending / confirmed / failed / unknown 结果，是审计和反馈，不是可自动重放的宏；外部效果未知时绝不重发同一 input。
- 截图和录屏作为 sensitive Artifact 处理。第一版录屏为宿主逐帧合成：停止后进入 Assembling → Validating（byte count、SHA-256、容器可读性），原子发布到 ArkDeck managed Artifact storage，再显示本地位置、实测帧率、「在 Finder 中显示」「另存为…」与「再录一段」；接近 60 秒上限前 10 秒显示倒计时。设备侧编码形态（720p · 15 fps 等封闭 preset + Receiving 链 + remote artifact reference）在对应 operation 与 Runtime 面发布前不出现在产品中；届时本地校验前不得删除设备端唯一副本。原型数值只表达信息层级，不构成生产默认值。
- 当前可点击原型只使用演示画面，不连接设备。截图、预览、录屏、点击和滑动必须分别由 Catalog / Provider / Runtime 发布并 materialize；缺少 operation、availability 或 fresh facts 时显示 unavailable，App 不拼接 HDC 命令。

### 5.7 Debug 工作台

- 五个 tab：Artifacts / Logs / Apps / Network / Commands，Artifacts 为默认项。Tab 使用 roving focus 与左右方向键、Home / End；切换只替换工作区内容，不把焦点强制移到内容区。
- Artifacts 的固定阅读顺序为：显式 target / binding → 编译来源 → 编译根目录 → 搜索与结果 → 已选摘要 → 替换计划 → 替换结果 → 重启 → Logs。页面不把最近选中的 sidebar 设备暗中当成 target，也不让服务器配置同时承担设备 scope。
- 编译来源固定为四种封闭 connector：SSH 远端服务器、本机目录、SMB 共享、WSL 发行版。用户可切换、添加、编辑、删除来源配置；每个来源可独立添加、编辑、删除多个编译根目录。根目录始终在所选 connector 的命名空间内解释，绝不是设备目标路径。
- SSH 配置展示 host、1…65535 端口、用户名与「密码 / SSH 密钥」登录方式。密码、私钥安全书签和可选密钥口令进入 Keychain / 系统安全存储，列表、Job、日志和 Artifact evidence 只显示认证方式与凭据是否就绪，绝不回显 secret 或完整私钥路径。首次连接必须展示并固定 SSH host-key fingerprint；已固定指纹变化时 fail closed，不能静默接受新指纹。SSH connector 只允许 bounded browse/read/import，不提供 raw command、任意远端执行或终端。
- 本机目录通过系统目录选择器建立安全书签；SMB 使用 `smb://server/share`、账户和 Keychain 密码；WSL 选择发行版，并使用发行版内 Linux 路径作为根目录。SMB / WSL 同样只经封闭文件 connector 读取，不把 mount、`wsl.exe` 或 shell fragment 暴露为 UI 输入。删除来源会移除 ArkDeck 配置、目录书签和 ArkDeck 保存的 Keychain credential item，但不会删除外部 SSH 私钥、服务器/共享/WSL 内文件或任何设备数据；只删除某个根目录则仅移除该书签。
- 搜索只在当前服务器的当前根目录内运行，支持文件名 / 相对路径与 `.so` / `.abc` 类型筛选。结果表以 checkbox 多选，至少展示名称、类型、来源相对路径、size、mtime 与兼容性事实；不可识别、ABI 不一致、签名/Build ID 缺失、ABC 编译器/API 指纹不匹配的行显示原因并禁用选择，不能只用红色表达。
- 「检查并预览替换」先展示 target / binding、来源、每项 host-side validation、effect、备份与发布策略。确认按钮使用完整动作名「备份并替换 N 个产物」，不用 `确定`。source path 只用于导入 Artifact lease；device path 必须由 published operation/profile materialize，App 不提交任意目标路径。
- ABI / ELF class / machine / Build ID / code-sign / hash 或 ABC compatibility 的**预检**负责在首个设备写入前阻止不兼容产物；每个现有目标的 immutable **备份**负责原子发布、启动或 readback 失败后的 rollback。界面必须分别表达这两层，不能把「有备份」写成「ABI 一定兼容」，也不能在 backup 未确认时进入 publish。
- 替换进入全局 Job Inspector，阶段至少区分 Preflight、Artifact lease、compatibility verification、staging、backup、atomic publish 与 readback。取消遵循实际 safe boundary；publish outcome unknown 时不重放，转入 Runtime recovery。只有全部选中项的 backup 与 publish readback confirmed，页面才显示「替换完成」。
- 替换成功后在原位显示独立「重启目标…」操作，并同时提供「获取日志」。重启页必须明确重启的是 Ability、进程还是整台设备及其影响；整机重启走危险 sheet，展示精确 target / binding、将中断的会话和重连后验证。点击只是 UX acknowledgement，不是 Runtime authority；没有已发布 closed restart operation 或 fresh facts 时显示 unavailable，不能用 raw HDC reboot 兜底。
- 重启完成后主操作变为「获取日志并验证」，切到保留的 Logs 工作区。Logs 继续提供 bounded live viewport、等级/tag/filter、host shard 状态；「暂停界面」不停止 host capture。「清空设备 buffer」位于 destructive actions menu，走危险 sheet。日志是 Debug 反馈 Artifact，与替换输入分开保存，不因切 tab 丢失采集状态。
- Apps：HAP import、install/start/stop/uninstall；mutation 与 read-only action 分组，package/PID 使用 tabular numbers。Network：`port-forward.create@1` / `port-forward.remove@1` 产生真实 Runtime Job，端口只接受 1024…65535 的十进制字段；失败后以 exact inverse + readback 补偿，不接受 shell fragment。Commands：只能选择 daemon 实现的 closed read-only template，显示 Provider lowering 的只读 disclosure，没有任意文本命令输入或 PTY。
- Production availability 必须如实：当前 Catalog 只覆盖单个 app-owned `.so` 的 `deploy.native-library.app-owned@1`，且 restartAbility 位于同一 typed plan 内；批量来源浏览、`.abc` deployment 与独立 device restart 仍是 v0.9 设计输入。它们只有在对应 behavior delta、Catalog operation、Provider lowering 与 recovery/readback 全部发布后才能从 unavailable 变为可操作。原型可演示目标交互，但必须持续标明其不代表生产可用性。

### 5.8 Flash

- 面向开发者的 Flash 页面只提供真实执行，不再显示 Execute / Plan only / Simulated 模式切换。plan-only 与 simulated 仍可作为 Runtime、测试或内部诊断能力存在，但不占用正常刷机主流程。
- 默认信息层级固定为「当前设备 → 选择镜像 → 擦除数据并开始刷机」。主界面只突出设备就绪状态、镜像名称/大小、userdata 影响和一个主操作；Availability、Profile、Prerequisites、Target & Binding、镜像 SHA 与 Exact Plan 收进可展开的「刷机详情」。required prerequisite 为 unknown/unsatisfied 时，以紧邻主操作的 blocker 取代按钮，不把危险准入细节隐藏成一个不可解释的 disabled 状态。
- 开始后，镜像选择区原位切换为进度区；完成后原位切换为成功或失败结果，不另开 dashboard。页面的第一视觉焦点依次是当前阶段、进度或结果、镜像名称；Job Inspector 仍可查看完整 timeline，但默认不自动展开、不抢焦点。
- 百分比只能由 Runtime 已确认写入字节数除以本次 materialized plan 的镜像/分区总字节数得到，并始终标为「镜像写入估算」。准备镜像、进入 Loader、重启和验证等没有可靠 byte denominator 的阶段显示 indeterminate + 阶段文案，不用经过时间伪造百分比。写入达到 100% 只表示镜像写入完成，必须继续显示「正在重启并验证」；只有 postflight 成功才能显示「刷机成功」。
- 进度视图同时显示已确认写入大小 / 总大小和三个粗粒度阶段「准备 / 写入镜像 / 重启与验证」。不得按文件选择时的压缩包大小直接推导 device write progress；若 Runtime 只提供 partition bytes，分母必须使用 materialized partition plan 的总写入大小。
- Execute 的 `recoveryPath` 必须来自 owner-only DAYU200 binding 对当前 target stable identity、所选 binding revision 与适用 HDC connect-key alias 的精确覆盖。新跨模式 identity transition 只接受相邻 revision；历史同身份、同 revision binding 只接受已经完成的当前 Runtime attestation，不得就地升级。唯一例外是切换到另一台已采用设备：所选 target 必须仍为 revision 1，fresh USB identity 必须唯一，并同时精确匹配该 target 的 stable identity 与 connect key；Runtime 以独立 CAS 切换 singleton active binding，不把它伪装成 revision 前进。任一条件不满足时仍显示 unsatisfied，并在 capability 签发和首个外部 effect 前拒绝。
- 页面通过只读 `flash.bootloader-status` 区分未发现、多个候选、已精确绑定和「唯一 DAYU200 精确匹配所选 target、但尚未成为 active binding」。后者可处于 HDC-normal 或 Loader；Rockchip device access 卡只显示说明，不增加第二个绑定按钮。用户选择 target 后点击一次红色刷机按钮，同一次提交先把所选既有 target + expected binding revision 交给 Runtime。Runtime 重新读取唯一 DAYU200；对 revision-1 新设备执行精确 active-binding CAS，对同一设备的 HDC→Loader 身份变化仍只持久化相邻 revision。随后重新生成精确计划，并仅在全部 required prerequisite 满足后提交 Flash。不得把 raw serial / topology 送进 App。
- DAYU200 页面中的 bootloader 特指 `0x2207:0x350a` RockUSB Loader，不是 HDC `-bootloader` 所选的 fastboot personality。HDC-normal 进态必须由 Provider 固定 lower 到 `loader` 模式，并以 IOKit identity + identity-bound `arkforged discoverDevices` 的双源 exact Loader 回读为成功边界；回读成功后同一 Job 自动继续分区刷写，不增加第二次点击。fastboot、未注册 USB mode、任一观察源缺失或 Loader identity 不一致都不得把 prerequisite 猜成 satisfied。
- 当前目标绑定是设备身份选择，不是刷机危险确认：不要求输入短语、checkbox 或第二个 sheet，绑定本身也不派发设备命令。若 Loader 绑定闭合的是唯一、尚无 outcome 行的 `enter-loader-mode` intent，旧 Job 以 confirmed failure 结束且原 action 不重放；机械结算只接受被选择的同 revision fresh re-attestation 或一个相邻 revision。显式 `outcomeUnknown`、多个候选、stale revision、损坏日志、任何 destructive intent 或重新 materialize 后仍有 blocker 都保持 fail closed。绑定落盘后的崩溃恢复只完成同一机械结算，不触发 dispatch。
- 「刷机详情」里的 Exact Plan 默认显示四个紧凑阶段摘要：准备与校验、进入 Loader 与身份绑定、写入分区、回读/重启/验证，并同时给出 step 数和最高 effect。需要逐步排障时再进入 Job Inspector 查看完整 step timeline；不为每个 step 绘制独立圆角卡片。
- 提交后直到 `job.run` 返回前，页面自动轮询 Runtime 的 `job.list`，使用真实 timeline 和已确认 byte facts 更新阶段与进度；不依赖用户手动刷新。critical write 期间页面持续显示「当前分区写入不会被强制中断」与电源提示，Job Inspector 补充「停止只作用于后续步骤」。
- Runtime 返回 Job ID 后立即显示「取消剩余步骤」；请求通过 `job.cancel` 到达 Runtime。临界写入不会被强杀，取消在下一个安全边界生效，不回放 unknown destructive intent。
- rebind 按 transport 分流：USB 只有在稳定身份、相邻 binding revision 与 updater/plan 阶段证据完整匹配时可自动 rebind 并继续；TCP / UART 断连必须停在人工确认，任何证据不完整或漂移都 fail closed。不得把 USB 的已证明自动恢复写成“静默续刷”。
- 固件可改变 DAYU200 的 HDC serial，而已绑定 Loader identity 保持稳定。Runtime 在首笔写入前必须持有 owner-bound 的旧 HDC identity + USB topology；重启后只接受该 topology 上唯一的 HDC personality、唯一匹配的 `Connected` row，并通过新 connect key 精确校验镜像声明的 model/build。完整只读证明落盘后，后续 facts 与 `flash.bootloader-status` 把新 HDC alias 关联回原 target/binding；拓扑歧义、USB identity 自相矛盾或 model/build 不匹配均零落盘、fail closed。App 只显示脱敏后的 target、revision、mode 与结果，不接收 raw serial/topology，也不提供 alias 管理控件。
- 当前发布的 `flash.dayu200` 只有 USB / RockUSB 路径，因此执行中的 Job 不暴露 rebind confirm / abort 控件；上面的 Loader target 绑定是执行前身份关联，不是断连后续刷确认。未来若发布 TCP / UART Flash operation，必须先补齐对应 domain 状态与 confirm / abort RPC，不能只在 UI 伪造停点。
- 成功结果只展示 Runtime 已投影的事实：明确的「刷机成功」、设备回报 build 与镜像期望一致、总用时；完整 binding revision、plan、artifact 与 timeline 保留在「刷机详情」和 History。执行前 Loader 激活若产生相邻 revision，App 必须先以该新 revision 重新生成精确计划；重启后的 HDC alias 只在 topology、model 与 build 精确证明后关联回这一 target/revision。manifest 全 executed + SHA 在 wire 没有字段前不画占位第三行。failed、cancelled 或 outcomeUnknown 均不得投影为成功，其中 outcomeUnknown 必须显示 needsAttention 与不可通过确认绕过的恢复说明。

### 5.9 History（REQ-UX-004）

- 三栏：filter/sidebar → Session table → detail inspector。筛选支持 status、executionMode、device、time 和全文搜索；filter 可保存为 toolbar menu。
- interrupted、failed、cancelled 使用不同 symbol + 文案；unknown outcome 额外显示 needsAttention。
- Detail 分组为 Summary / Timeline / Parameters / Artifacts / Recovery linkage。Artifact 行展示 name / role / origin / size / SHA-256 / privacy / status。
- 导出以单个 Artifact 为边界：先显示文件名、size、privacy 与 SHA-256；敏感 Artifact 要求显式确认。App 以有界 chunk 读取、复算 byteCount / SHA-256 后写入用户选择的位置，目标路径不跨 daemon 边界。成功后可在 Finder 定位。

### 5.10 Settings

- 使用系统 Settings scene，分为 General / Toolchains / Storage / Updates / Diagnostics。
- Toolchain 切换明确「只影响新 Job」；Storage 展示 root、quota、retention、pinned 与当前使用量；Updates 复用已实现的 signed update flow。
- 诊断包默认不含 device raw，可预览勾选且无自动上传（AC-DIAG-002-01）。

### 5.11 Automation / Bounded AI Debug Loop

Automation 是现有 Harness task plane 的生产监控与有限生命周期控制面，不是 Git `TASK-*` 看板，也不带 Preview badge。

- 两栏 split view：左栏列出既有 `HTASK-*`；右栏展示 goal、type、lifecycle、stage、target、round、version、updated、active Job、wait reason 与 Runtime 返回的 allowed operations。
- App 只开放 `task.list`、`task.reconcile`、`task.pause`、`task.cancel`；不能 submit 新 task、提供 human resolution、resume、propose patch、导出 promotion、GC workspace 或管理 capability。
- reconcile / pause / cancel 的响应必须返回同一个 HTASK 的完整新快照；task ID 漂移或字段不完整即失败，不局部拼接事实。
- allowed operations 只读展示。页面不得出现 raw command、argv、远端路径、预算编辑器、源码 patch 输入或权限安装入口。
- Attempt、budgets、conditions 与 HumanActionRequired 只有在 Runtime wire 完整投影后才能新增；v0.4 不用模拟数据补这些区域。

## 6. 可访问性、本地化与动效

- 一个 window detail 只有一个可感知的主标题；heading 层级连续。icon-only button 有 label，装饰 symbol 隐藏于 accessibility tree。
- 所有 interactive target 有 `focusVisible`；高对比度/Increase Contrast 下保留结构边界；状态同时有 symbol + 文案。
- 200% text/zoom 与 900×600 最小窗口下不裁掉关键操作；长中文、英文和 pseudo-localization 可换行，ID/hash 允许中间省略但完整值可达。
- 中英文从 localization catalog 读取；设备 raw、命令、Artifact 原文保留；时间、duration、bytes 按 locale 格式化。
- 高频操作不做自定义动画。drawer/sheet transition 可被打断，≤180ms；`Reduce Motion` 下只做 opacity crossfade。按钮按下可轻微 scale 0.96，但产品 SwiftUI 优先沿用系统 button style。

## 7. 原型评审模式

- Toolbar「AC 标注」只用于设计走查，叠加对应 REQ/AC chip，不进入产品。
- 原型必须声明演示数据，不连接设备；任何 simulated、planned、fake 结果不得展示为真实硬件结果。
- 每次原型变更至少检查：UTF-8/中文；light/dark；900×600 与宽屏；键盘遍历与 modal focus return；Reduce Motion；所有导航页；typed-only 命令面；Job 跨页可见。
- 所有用户可见交互修改必须与产品代码同车更新对应原型页面/状态、表达该事实的本规格或 design brief，以及 `docs/design/references/` 当前设计版本下受影响页面的简体中文与英文 1180×760 UI 参考图；缺少页面、状态或参考图时由本次改动补建，不得延期。
- UI 参考图必须从 `prototype.html?reference=1&page=<page>&lang=<locale>` 加必要的显式状态参数生成，持续显示演示数据；它只校验布局、文案和状态，不是 App 实机截图、Runtime 输出或硬件验收证据。生成入口与状态参数记录在对应 reference 目录的 README 中。

### 7.1 v0.5 基线、v0.6 Flash、v0.8 Viewer、v0.9 Debug 与 v1.3 Diagnostics / Toolkit 评审

- `docs/design/references/v0.5/` 固定保存 1180×760 的简体中文与英文设备详情参考截图；原型通过显式 locale / reference state 生成，不依赖浏览器记忆状态。v0.6 Flash 先在交互原型中评审，确认后再固定同尺寸中英文参考截图并进入 SwiftUI 对齐。
- Viewer 以 `prototype.html?page=dump` 的首次空态为默认可点击事实；点击「抓取视图」后进入与 `prototype.html?page=dump&viewerState=captured` 相同的检查器态。检查器默认选中 `Toggle #42`，可从截图与完整树双向切换节点，且下方属性、布局、无障碍和 raw 内容同步更新；水平分隔条可用指针和键盘调整。
- Trace 以 `prototype.html?page=trace` 为实现同步稿：只保留显式设备、抓取场景、秒/分钟时长、快捷时长、「开始抓取」以及独立「打开 Trace 查看器」入口。秒快捷值为 `5s / 10s / 15s / 30s`，默认选中 `10s`；分钟快捷值为 `1 min / 2 min / 3 min`。旧自定义 tag、参数 snapshot、Artifact 状态卡不得作为后续实现输入恢复。
- Debug 以 `prototype.html?page=debug` 为实现同步稿:五个 tab（Artifacts / Logs / Apps / Network / Commands，Artifacts 默认）使用 roving focus 与左右方向键、Home / End;每组以 section 标题加细线分组，不再逐组画有边界卡片;Runtime 可用性只在标题旁一行呈现，被阻止时才在配置之上展开 reason code。Artifacts 走查「本地文件 / 远端服务器 → 选择或浏览一个已签名 `.so` → 填写所属 Bundle 与 `lib<name>.so` → 校验并检查替换计划（plan digest 与七个 materialized step）→ 备份、替换、重启并验证 → 获取日志并验证」;远端浏览只在已验证编译根目录内列出 `lib*.so`，空态跳转「设置 › 服务器」，服务器编辑必须走查密码 / OpenSSH 私钥分支、端口与绝对路径的字段级错误聚焦，以及主机密钥固定提示。旧的本机目录 / SMB / WSL 来源浏览、按名称与类型搜索、勾选批量替换和独立设备重启不得作为后续实现输入恢复，只能以 unavailable 呈现。原型底部的 production-boundary callout 不得删除。
- v1.3 Diagnostics 以 `prototype.html?page=diagnostics` 为可点击事实：sidebar 同时保留 Trace、Diagnostics 与 Toolkit，切换时各自的 preset、时长、筛选、选择和运行状态不得串扰。默认打开的演示 Session 即第一版默认形态（无录屏、Marker 截图事后拍摄），另有「含录屏」与「Partial + 无法对齐」两个可切换 Session。点击 Marker 截图、可选视频帧、Trace event、HiLog marker 或 Timeline slider 都必须更新同一个时间光标并同步可用画面、`Δt` 与邻近日志；已选 event identity 不被非事件点击清空，光标离开时显示偏离标注。可返回采集页走查「开始诊断 → required channels ready（环形缓冲）→ 自动 Marker 触发 → 标记并截图（pending → +N ms）→ 停止并生成结果 → 生成新 marker-only Session」；`⌘M` 必须可用，默认屏幕录制必须关闭，Partial 横幅、无法对齐降级、截图失败原位说明、对齐 disclosure 和 production-boundary callout 不得删除。
- v1.3 Toolkit 以 `prototype.html?page=tools` 为可点击事实：默认状态必须显示「按需截图 · 无持续取帧」。走查获取截图（pending → 完成）、画面单击（pending 空心触点 → confirmed 实心、落点为按下位置）、按住 ≥0.5 秒长按（不降级为点击）、按住拖动 swipe、方向键虚拟指针、非闭集手势就地提示、独立开启/停止预览（实测帧率 + 画面年龄常显；断流窗口出现「画面已过期 · 输入已暂停」且 pointer down 被拒绝）、独立开始/停止录屏（接近上限倒计时）。停止录屏后必须先显示「正在合成视频」（Assembling → Validating），再显示 Mac 本地位置、实测帧率、「在 Finder 中显示」「另存为…」与「再录一段」。每次完成的 pointer sequence 只更新一条操作记录，录屏不能隐式开启预览。切换 Trace / Diagnostics 后返回 Toolkit，截图时间、预览、录屏合成与结果状态必须保留；performance notice 与 production-boundary callout 不得删除。
- 参考截图只校验导航层级、宽屏分栏、信息密度、context menu 和文案长度，不是生产 Runtime 截图，更不是硬件验收证据；截图中必须持续标明演示数据。
- App UI 测试在同一 1180×760 默认窗口和中英文 fixture 下检查：设备详情只有一个主标题、双栏/单栏的几何关系；Flash 默认只显示设备、镜像和主操作，运行态显示阶段与真实 byte-derived 估算，结果态只在 postflight 成功后出现成功文案。测试附加当次窗口截图供人工 diff；系统字体、accent、材质和抗锯齿继续由 macOS 控制，不用逐像素阈值锁死原生渲染。

## 8. v1.2 已决视觉项

- 图标：产品使用 SF Symbols；HTML 原型使用单色 inline SVG 近似，禁止 Emoji 作为最终导航图标。
- 密度：默认紧凑舒适（macOS medium sidebar size）；不额外提供 App 内密度开关，尊重系统设置。
- Job Inspector：默认折叠；有 running / waiting / humanRequired 时显示摘要但不自动抢焦点。
- 外观：跟随系统；不默认强制 dark。
- Accent：跟随用户系统 accent；ArkDeck 不固定 teal 覆盖系统选择。
- Viewer：首次进入先显示真实空态；抓取成功后使用左侧截图 + 右侧上下检查器。树与属性之间保留紧凑的可拖动结构分隔线，不使用圆角卡片。普通截图边界默认隐藏，当前选中边界、树行与 inspector 使用同一 accent selection，并保留 ID / type 文字线索。
- Diagnostic：参考宽屏使用“上方当前画面 + 当前时间上下文、下方全宽 Timeline”，不做三个等宽文件查看器。Trace event 是主选择身份，Marker 截图、可选视频与日志可反向移动共享光标但不伪造也不清空 event identity。默认不持续录屏；Marker 截图按拍摄时刻显示并固定标注 `+N ms`；画面 metadata 与对齐状态固定可见（第一版两态）；自动与手动 Marker 在 track 上样式区分；Timeline 用结构分隔，不把每条 Track 包成卡片。
- Toolkit：内部工具列表与真机操作工作区保持两层信息架构；参考宽屏使用左侧设备画面、右侧控制与历史，不把截图、录屏、点击和滑动拆成四张同权卡片。按需截图是安静默认，预览显示实测帧率与画面年龄、断流时以遮罩暂停输入；触点反馈两态（pending 空心 → confirmed 实心）；宿主合成录屏完成后用一个紧凑结果条展示本地位置、实测帧率与后续操作（含「再录一段」）；性能提示与 typed-only 边界固定可见。
- Debug：Artifacts 是首个且默认 tab；编译来源配置和搜索结果各自成组，避免把来源管理、文件勾选与设备执行混成一张表。来源编辑器先选 SSH / 本机目录 / SMB / WSL，再渐进披露对应连接字段；SSH 再选密码或密钥，隐藏分支不进入 tab order。替换后的重启与日志反馈原位出现，不另开 dashboard；兼容性阻止、备份确认、替换 readback、重启后验证使用不同文案和状态，不用一个绿色「成功」吞并全部阶段。
- 页面标题只在 toolbar：任何工作区的内容区都不再画与 toolbar 同名的主标题。原型此前每页一个 `<h1>` 且标题栏显示「ArkDeck — 页面名」，两者不重复；SwiftUI 的 `navigationTitle` 只显示裸页面名，内容区再画一遍就成了字面重复，违反 §3 与 §6 的「一个 detail 只有一个可感知主标题」。需要解释的页面改用一行 secondary 说明 + 页面级控件（Debug 的 scope 行即此形态）。原型已同步移除全部 `<h1>`，改由 `data-page-title` 提供标题栏文本。
- 统一页面测量 920：Flash、设备详情与 Trace 此前各自取 760 / 920 / 1000。在 1180 参考窗口下 detail pane 约 926，920 正好填满而不留死白，在更宽的显示器上仍有界。正文段落另按约 620 收窄，Flash 的「一条平静阅读路径」不靠整页变窄来实现。
- 容器圆角 11：与 §2 同心圆角一致，外层 container 11、内嵌 box 9、control 7。

## 9. 平台设计参考

- [Designing for macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos/)
- [Sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars)
- [Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars)
- [Split views](https://developer.apple.com/design/human-interface-guidelines/split-views)
- [Materials](https://developer.apple.com/design/human-interface-guidelines/materials)
