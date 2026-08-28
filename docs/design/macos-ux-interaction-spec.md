# ArkDeck macOS UX 与交互定义

> Status：draft v1.6（design input，非 normative；2026-08-25 v1.2 新增独立 Device tab、把 Diagnostics 调整为低干扰默认，并按当前 SwiftUI 实现回写 Viewer / Trace 页面结构；同日 v1.3 按设计评审修订 Diagnostics Marker、时间对齐与 Device 输入反馈。2026-08-26 回写 Debug 当前 SwiftUI 分组及单个已签名 app-owned `.so` 的本地 / 只读 SSH 来源流程；v1.4 将 History 从 Job 审计表重组为按工作类型回访的活动中心，同时保留完整 Runtime 证据、Artifact、恢复关联与导出能力。2026-08-27 v1.5 同步 Device 命名、图标及当前 App 交互：空态、按需截图、按帧录屏与旧画面输入拒绝。Diagnostics / Device 详细设计见 [`diagnostic-mode-design.md`](./diagnostic-mode-design.md) 与 [`device-control-design.md`](./device-control-design.md)；对应 OpenSpec 提案 `openspec/changes/chg-2026-071-interactive-device-control/`）
> 本轮基线：2026-08-27 `origin/main` = `e1d52e68`。v1.6 全页核对、当前/未来分层及验证证据见 [`implementation-audit-2026-08-27.md`](implementation-audit-2026-08-27.md)；不是全部目标行为已交付的声明。
> 交互原型：`docs/design/prototype.html`（可点击，与本文档同版本演进）
> 行为事实源：`openspec/specs/desktop-ux-observability/spec.md`、各 capability spec、Catalog 与 Runtime contracts；本文档只定义 HOW（布局、组件、层级与流转），行为冲突时以事实源为准
> Promotion：本目录是草稿区。被采纳的版本在起草 M2+ 功能 change 前移入 `openspec/platforms/macos/design/`，并由 change 的 `design.md` hash-pin。设计中发现的行为级缺口必须走 behavior delta，不能只画进稿子。

## 0. v1.6 当前实现与目标设计

本版先按最新代码确认实际入口，再比较 accepted specs、Catalog、交互稿和接线。
**当前镜像**与**未来目标**必须分开；disabled 入口不等于目标功能完成，CLI/Runtime 能力不等于 App 已接通。
完整逐页、子标签、窗口、弹层及组件镜像清单见全页扫描报告。

| Surface | 已实现并接通 | 仍未实现或未接通 |
| --- | --- | --- |
| App shell | 八个主页面：Overview / Flash / Debug / Viewer / Trace / Device / Diagnostics / History；动态设备详情；独立 Settings、Trace Viewer 和快捷键帮助窗口 | Automation 与 task.* 已在 CHG-2026-064 退役；不是待补 UI |
| Overview | 当前目标、SSH source、调试线、环境与来源检查；校验过的 readOnly `observe.device@1` / `capture.diagnostics@1` 可复制原始 typed inputs 和 thread 至新草稿 | 仅导航不会提交；变更操作、旧 Marker 时间、目标/binding 漂移和 unknown 禁止复用。新 Job 在目标工作区显式启动，不复制 authority/lease/Runtime Session |
| Device detail / trust | 真实候选状态、binding/observation、重命名和重新检测、有界授权等待 | App 不执行 target.adopt；TCP/UART 添加不能画为已发布 App 功能 |
| Flash | 导入镜像、fresh exact plan、前置条件、同页影响说明、Runtime 执行/进度/结果、细节 disclosure、Loader 激活绑定 | 不提供人工确认覆盖未知 outcome、不从成功字符串推定 postflight |
| Debug | Artifacts / Logs / Apps / Network / Commands 五个 tab；单个已签名 app-owned `.so` 的本地/只读 SSH 来源、校验、计划、部署及 readback/rollback；HAP、bounded logs、typed 网络规则和闭集命令 | `.abc`、批量替换、SMB/WSL/目录 connector、独立设备重启、设备日志 buffer 清理及未发布 package lifecycle 保持 unavailable |
| Viewer | 空态优先；精确 target、同 Job screenshot/tree 校验；截图/树/搜索联动；属性、布局、可访问性、原始和高级 Dump 五种 inspector | Fault/Crash 与 System Diagnostic Snapshot 不是 Viewer 首版能力；设计中旧“UI Dump”导航不再适用 |
| Trace | 两段式采集/查看入口；已验证 raw `trace.htrace` 打开独立原生 Viewer；时长单位转换与校验 | 原型不应在 unavailable 时启用开始，也不能把非法输入静默改成 10 |
| Trace Viewer | 最近文件、筛选、搜索、Timeline、事件/范围/标注、两种停靠、加载/取消/错误与帮助；App 普通文案中英双语；通用稿已有 loaded 样本和锁定目录的 19 条快捷键 | 原始字段、进程名和许可证正文不翻译；合成 loaded 图不构成真实 trace/设备验收 |
| Device | 按需截图、一次 typed 点击/长按/滑动、旧图拒绝输入、2–300 帧有界采集与本机 .mov 合成/校验、实测帧率/缺帧/配额状态 | 无持续预览、键盘输入、设备端编码与按秒启停录屏 |
| Diagnostics | History 精确来源 → Session reader → index/summary/markers 校验 → timeline/缺口/Artifact；显式读取文本/JSON；已发布 Trace 可转入独立 Viewer | 交互式 arm/append-marker/stop、会话内视频与时钟校准未接通。published bounded ringBuffered 与部分自动 Marker 已存在，不能误报为全缺失；无校准/事件时间时明确无法对齐/未记录时刻 |
| History | 八类筛选、保存/分页、证据、参数、导出与精确来源上下文；Diagnostics 历史 Session 已加载并保留来源 | 不重放；未知 operation 不猜类型；Flash 来源目标已消失时显示缺失，不静默换设备 |
| Settings | 独立七标签：General / Toolchains / Servers / Storage / Trace / Updates / Diagnostics；Trace 内 Cache / Licenses | 不再内嵌完整更新设置；当前 App 诊断包不提供 device raw 勾选，敏感 Artifact 从 History 单独导出 |
| Job Inspector / recovery | job.list/status/evidence/artifact.list 精确详情；标准 published 日志显式读取（最多 2 MiB，末 200 行）；已知活动 Job 取消请求先核对 fresh identity | 取消请求不代表终态；敏感产物走 History。unknown 不取消/重放；恢复 rebind/archive 未有 App RPC 接线，仍保留为缺口，不删 accepted spec |

`prototype.html` 默认展示当前边界。`?page=diagnostics&concept=diagnostics` 仅用于未来会话探索；
`?page=automation` 解释退役旧链接，不显示任务控制。保存会话状态用 `diagnosticsState=loaded|partial|trace|failed`，
Trace Viewer 用 `traceViewerState=loaded|loading|failed`。所有页面保持演示披露，不连接 Runtime/设备。
视觉 token 与 §1/§2 未改变。

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

**实现边界**：当前 `GlobalJobInspectorView` 只展示 `job.list` 事实，不含以下目标中的
全局日志尾部、取消与拖动布局能力；普通原型只镜像当前只读入口。下列是尚需闭合的设计要求。

- 折叠态 36pt：运行中数量、最高风险 Job 的 symbol/阶段/elapsed、indeterminate 或真实进度、展开按钮。
- 展开态 220–320pt，可拖动：左侧 Job 列表，右侧阶段、当前 typed operation、目标 binding、预算、日志尾部 200 行和 Artifact 增量。
- 取消按钮直接使用 `CancellationPolicy` 文案，如「在安全边界停止」；critical step 期间显示后续动作会停止，但当前写入不会被强杀。
- plan-only / simulated 在标题、列表、History、详情与导出中永久保留 outline badge（REQ-UX-006）。
- 状态变更写入稳定的 accessibility live region；日志流本身不逐行播报。

### 4.2 Recovery 与 HumanActionRequired（REQ-UX-003）

**实现边界**：当前全局 banner 只打开该项精确 Job 的 History，并清除遮挡该记录的旧
筛选；不能只切换到 History 而沿用另一条选择。所有主窗口工作区、动态设备详情与信任
页共享同一 banner family，独立 Settings / Trace Viewer / 帮助不显示。逐项投影尚未解决
的 unknown、waitingForHuman、waitingForRecovery、awaitingRebindConfirmation、
resumeAtConfirmedSafeBoundary、userAbandonRequested；已有 Runtime current-epoch
关系的历史 unknown 仍保留原事实，但不再作为当前提醒。下列 resume/archive/human
resolution 不是 App 现有动作。Runtime 已发布且准入的恢复能力与 App 缺失入口分开记录。

主窗口恢复区最多占当前 detail 可用高度的 45%，超出后独立纵向滚动；按内容实测高度
收缩单条短提示，不为它预留空白。该上限同时为工作区预留 400 pt；空间更小时保留至少
96 pt 的恢复滚动视口，但仍不超过 45%。多条记录显示总数，所有记录仍可逐项检查；不能用只显示
最高优先级一条来掩盖其他未决项。内容宽度不超过 600 时，History 动作移到说明下方，
保留完整标签、Job/target 与说明，不能把关键动作挤出窗口。

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

- 阅读顺序：当前设备与已绑定 SSH source → 下一步 → 每条调试线最新运行（可展开此前三次）→ 默认折叠的环境与连接。结构依据 `OverviewRecordView` / `HDCStatusView`，不恢复旧四卡 dashboard。
- target picker 只包含当前已授权、已接管且有 binding revision 的在线观察；设备行只是详情导航，不能暗中改变各工作区 scope。服务器来自 `RemoteBuildSourceBindingApplicationFacade` 的显式绑定，不取服务器列表第一项。
- “查看这次运行”必须携带精确 Job ID 到 History 并选中它；不是打开任意最新记录。
- “继续”sheet 展示来源 target/binding、effect、Catalog digest 与已上报参数。当前出口仅打开工作区，不预填/提交；缺失参数或 unknown destructive outcome 不提供貌似可执行的继续。
- 环境 disclosure 保留 Server/Toolchain、Selected Device/Binding、Capabilities、Needs Attention，支持 ⌘⇧D 展开/折叠。path/hash 可查看完整值；unknown 与 unavailable、授权与通道加密分别呈现。
- Rockchip 的 permissionDenied / driverUnavailable 区别于 offline/unauthorized；不自动 sudo、安装驱动或放宽权限。
- HDC recovery 仍是 impact preview → exact-generation confirmation → dispatch；sheet 展示受影响设备/Jobs/其他客户端。原型无 proof 时禁用，不以确认文案代替 Runtime 证明。

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
- 下方节点属性区使用 `Properties / Layout / Accessibility / Raw dump / Advanced Dump` 五个分类；这些 Provider/调试技术词在两种 App 语言中均保留英文。结构化字段只作为快速阅读；`Raw dump` 必须保留该节点的全部原始字段，不因 UI 未识别字段而丢失信息。
- `Advanced Dump` 已接入生产：选中标签时才读取当前 capture、target/binding 和组件数字 `hostWindowId/componentId` 所关联的 `componentDetail`，提供字段/值搜索、loading、缺失数字 ID、失败和重试。不得沿用上一组件字段，也不得把缺少 ID 当作成功的空结果。原型 `viewerTab=advanced` 的字段和各状态均为显式演示数据。
- 选中后不强制移动键盘焦点；变化通过稳定的 polite status 播报。截图可点区域与树行都使用原生 button 语义和可见 `focusVisible`，不只依赖颜色表达选中。
- UI 树默认获得右侧较多高度；树与属性之间使用可拖动的水平分隔条，键盘可用上下方向键微调、Home / End 跳到允许范围两端。调整只改变可视比例，不改变节点选择和滚动身份。
- 窗口变窄时仍保持右侧「UI 树在上、节点属性在下」的关联结构；无法容纳左右双区时按「设备截图 → 右侧检查器」单列排列。任一宽度下当前节点、搜索、树的双向滚动和 raw 信息都不可被裁掉。
- footer 使用生产 capture metrics 的阶段名：nodes、submit、run、list、read(bytes/time/throughput)、parse 与总时长；未采集 metrics 时明确显示「未测量」，不显示演示健康结论。
- Viewer 数据默认本地保存且按敏感 Artifact 处理；导出前仍须预览和确认。Fault/Crash Artifact 与整机诊断快照不得伪装成 Viewer 中的另一类节点。

### 5.4 Trace

- Trace 主窗口固定为一条 secondary summary 和两个顺序 section：「抓取 Trace」在上，「查看 Trace」在下；不使用双栏 card dashboard，也不在内容区重复页面标题。
- 「抓取 Trace」header 右侧显示 `正在检查… / 可以抓取 / 暂时无法抓取`。表单只保留显式设备、抓取场景和时长；抓取场景是单一 picker，不再提供 Preset / Custom 模式或直接 tag 编辑。
- 时长由十进制输入、秒/分钟 segmented unit 和快捷值组成：秒为 5 / 10 / 15 / 30，分钟为 1 / 2 / 3。Runtime request 始终规范化为秒；切换到分钟向上取整，避免缩短已有时长。无效输入保留原值并在原位显示范围错误；Catalog 当前界限为 1–600 秒（1–10 分钟）。
- section footer 左侧只呈现一个可行动状态：本地保存说明、正在抓取、terminal 结果、outcome unknown 或首个 blocker；右侧是「开始抓取」，有 active Job 时替换为 Job ID +「取消抓取」。完整参数、计划和 Artifact 事实留在 History（全局 Inspector 的读取/取消及恢复边界见 §4.1），不重新塞回页面。
- 当前 App 在 blocked/invalid 时仍保留可点击的开始按钮，用于显示首个明确错误；`submit()` 的 `canStartCapture` 校验不通过时零提交。原型同样只反馈错误，不能切到假采集中；只有提交进行中禁用重复动作。不要把“可点击”误判为 Runtime 可执行。
- 「查看 Trace」只显示本地/最近 Trace 说明和「打开 Trace 查看器」。最近一次抓取通过唯一 published raw `trace.htrace` 校验后可显示就绪文件名；校验失败提供同一入口的重试，不画 Artifact 列表 dashboard。
- Trace Viewer 是 ArkDeck 的独立窗口，不替换主窗口 detail。Viewer toolbar 提供 Capture、Open、reload、search、zoom 和 Inspector；返回 Capture 聚焦/打开主窗口的 Trace 页面，不复制第二套设备控制面。
- 自动进入 Viewer 之前必须从本次 terminal Job 精确选中唯一的 published raw `trace.htrace`，经 sensitive opt-in 的 Artifact API 分块读取，并同时匹配 byte count 与 lowercase SHA-256。任一校验失败不替换当前文档、不写 Recent、不启动 parser。
- Timeline 使用原生 AppKit/CoreGraphics 画布，包含 CPU slice、thread state、named slice、counter 和 frame lane。滚动 / 捏合、键盘、range/event selection、flag、mark 和 search 都操作真实 event identity，不从像素位置伪造事件。
- Process filter 与 trace search 分开；隐藏 lane 时保留 view state，搜索命中可显示必要 lane 并滚动到真实事件。Inspector 可停靠在右侧或底部，窄窗只改布局不丢失选择。
- 加载中只有 hashing、cache lookup 与 indexing 拥有真实 denominator 时才显示百分比；TraceStreamer stdout 无可靠进度时使用 indeterminate。空 timed events、缓存隔离重建、schema 不兼容、取消与 parser identity drift 必须显示不同状态。
- 所有 toolbar 动作在 Trace menu 有键盘等价入口，完整快捷键目录位于 Help 菜单。Timeline 焦点、选区、搜索结果与状态变化有稳定无障碍语义；不以颜色作为唯一信号，并尊重 Reduce Motion。

### 5.5 Diagnostics

**当前 UI**：已经存在 `DiagnosticsWorkspaceView`，默认显示未打开 Session；布防和打标记禁用，
显示 `diagnostic_session_capture_not_connected` 与缺失交互式采集接口的说明。
保存会话的 reader 已接通：History 传递精确来源，重新查询并校验 index / summary / markers
的身份、byteCount、SHA-256 与 completeness 后才 `publish(reading:)`。可查看 partial、无时间的
Marker、notDerived 和产物元数据；文本显式读取，已发布 Trace 可转交 Viewer。不会推算截图时刻，
也不会只因存在 adopted target 就报告采集已开始。JPEG 与 PNG 可满足截图通道，但不豁免另行声明的 required 文件。
**以下为未来目标**，仅 `concept=diagnostics` 可查看；不代表当前可用性或真实设备验收。

- Diagnostics 位于 Device 之后，是独立 sidebar tab，包含「新建诊断」和「Diagnostic Session Viewer」两种状态。它不替换 Trace、不打开 ArkTrace 独立 App shell，也不读写 Trace 的 preset、时长、筛选、选择、Recent 与运行状态。详细行为见 [`diagnostic-mode-design.md`](./diagnostic-mode-design.md)。
- 工作区名称固定为 **Diagnostics**：侧栏、窗口标题与页面标题在中英文中均保留英文，切换页面或语言时不得变成「诊断」。按钮、preset、状态和说明文案继续按各自的本地化规则显示；Settings 中用于应用诊断包的「诊断」仍是独立文案，不随工作区名称更改。
- 新建诊断默认提供「低干扰诊断」与「图形诊断」preset。Trace 与 bounded HiLog 以环形缓冲/缓冲区回溯方式采集（在 Marker 或停止时回溯保存问题前窗口）；Marker 只记录时间点并触发一次事后截图；自动 Marker（frame deadline missed / crash 触发，默认开）补齐人工反应延迟；屏幕录制是默认关闭的 optional channel，只有用户明确勾选后才加入 Session。preset 只组合 reviewed typed inputs；高级 disclosure 才展示 duration、Trace categories、HiLog filters、Artifact byte budget 与 optional channels。设备未确认支持 required channel（含环形能力）时在主操作旁显示 unavailable 原因，不把 unsupported tag 或 channel 伪装成可选。
- 点击「开始诊断」后先进入 Arming；只有 required channel 全部 recording，界面才显示「采集已开始，现在开始复现」。录制中突出 elapsed / bounded limit、精确 target / binding、各 channel 状态和 Marker 数量，提供「标记并截图」（`⌘M`）与「停止并生成结果」。手动 Marker 立即记录时间点，截图先显示「正在截图…（事后拍摄）」，完成后显示「拍摄于标记后 +N ms」；截图失败时 Marker 保留并显示原因。无可靠总量时只显示阶段和 elapsed；屏幕录制关闭时明确显示「无持续取帧」。采集期间对同一设备的其他 mutation（含 Device 输入）在 in-session 准入语义发布前 fail closed 并解释原因。
- Diagnostic Session 以 Session monotonic time 为主轴。Trace event、视频 frame PTS 和 HiLog timestamp 都通过带适用区间与 `maxError` 的映射进入该时间轴；UI 词表为 `同一时钟`、`已校准 ±N ms`、`无法对齐` 三档，但**第一版只承诺前后两档**——`已校准 ±N ms` 在 ground-truth 实验量化误差后才启用，任何 ±N ms 数字在此之前不进产品 UI。重启、重连、recorder restart 或 timestamp 回退切断 alignment segment，并在 Timeline 画 gap。
- Viewer 顶部同时显示「当前画面」与「当前时间上下文」，底部为全宽 Timeline。当前画面在 Marker 截图的实际拍摄时刻（±150 ms）显示截图并固定标注「拍摄于 Marker 后 +N ms」；Session 明确包含录屏时，才按 `frame.pts ≤ t < nextFrame.pts` 解码视频帧并显示 `Δt`。没有覆盖光标的画面证据时显示缺口，不沿用旧截图。右侧展示选中 event 与默认 `±100 ms` 日志；点击截图、视频或日志只移动光标，不凭时间接近伪造 Trace event identity，**也不清空已选 event 的 identity**——光标离开事件区间时详情面板保留并显示偏离标注。
- Timeline Track 顺序固定为 Marker → Screen → Frame/Display → CPU/Process/Thread → HiLog → 有事实的平台扩展 Track。所有 Track 共用一个 ruler、time cursor 和 selection range；Track header 固定，时间内容水平滚动。录屏 gap、secure surface、日志无法映射或 alignment 超限都保留可见缺口，不能沿用旧帧。
- 第一版默认保存 Marker 截图，不进行持续取帧；用户明确开启录屏时才保存原始视频和 frame index，且不长期保存逐帧 PNG。视频按需解码；thumbnail、frame index、HiLog index 与 linkage index 都是可重建 derived Artifact，必须记录 raw source hash、tool identity、参数、size 和 hash。
- 当前 `capture.diagnostics@1` 只有单张 `screenshot.png`，没有屏幕视频、并发 channel boundary 和 clock calibration。原型必须持续展示 production-boundary callout；未来接入需要 reviewed operation/Provider contract，不能从 App 执行 raw HDC 或把同 Job identity 当成时间同步证明。
- 自动进入 Viewer 前，必须从 terminal Job 精确选择并校验每个 published Artifact 的 status、privacy、byte count、lowercase SHA-256 和内容类型。任一 Artifact 校验失败只隔离该 Artifact；Session 可 truthful 地进入 Partial，但失败内容不写入 viewer index、不替换已打开内容。
- Trace 解析仍复用 ArkTrace 原生 AppKit/CoreGraphics timeline、真实 event identity、cache 和 query。滚动 / 捏合、键盘、range/event selection、flag、mark 与 search 不从像素位置伪造事件；Process filter 与 trace search 分开，隐藏 lane 时保留 view state。
- 所有 toolbar 动作在 Diagnostics menu 有键盘等价入口。Timeline 提供可聚焦 slider 语义，方向键移动光标、`Shift + 方向键` 扩展 range、`⌘M` 添加 Marker；离散 marker/event 仍可单独 Tab 到达。状态使用 symbol + 文案，动态变化通过稳定 polite status 播报，并尊重 Reduce Motion。

### 5.6 Device · 真机操作

2026-08-27 真机走查补充：CLI 截图、三类输入和 40 帧采集已真实执行，App 截图／旧图拒绝／刷新通过；已安装 Runtime 漏接 App 录屏的 XPC 入口，因此 App 录屏仍待修复审核合入与 Runtime 更新后再验。交互稿新增 `deviceState=runtimeUnavailable` 表达提交前失败，不展示虚假视频结果。详见 [真机走查记录](references/v1.5/real-device-validation.md)。

- Device 位于 Trace 与 Diagnostics 之间，中英文同名，使用线框设备图标（SwiftUI `iphone`）。工作区没有内部工具列表；详情见 [`device-control-design.md`](./device-control-design.md)。
- 顶部设备名及 target / binding，右侧仅「获取截图」。首次显示「尚未获取截图」和空操作记录，不自动抓图。截图请求期间按钮禁用；失败保留旧图，并显示失败原因。
- 内容区 ≥880 pt 时画面在左、320 pt Inspector 在右；更窄时为 420 pt 高画面接 Inspector，整体滚动。Inspector 顺序为操作方式、录屏、操作记录、负载提示；页脚常显画面年龄／尺寸及静止画面边界。
- 一次 pointer sequence 仅生成一个 typed input：<6 pt、<500 ms 为 tap；<6 pt、≥500 ms 为 long press；≥6 pt 为 swipe。坐标锚定按下点，长按限制 500–2000 ms，滑动限制 80–2000 ms。没有坐标表单、键盘虚拟指针或轨迹箭头。
- pending 时显示空心触点并禁止另一条输入；settled 后触点有填充，具体结果从记录读取。confirmed 和 unknown 都使旧图过期，再点只产生本地拒绝记录；明确失败不改变原可用性。只有重新截图恢复可用，历史图默认只读；不使用 800 ms 年龄倒计时，不自动重发 unknown。
- 录屏默认 40 帧，范围 2–300，Stepper 步长 10。点击后立即显示「检查空间中」，固定请求帧数并禁用帧数和录制按钮；配额查询返回后才决定拒绝或提交 `capture.screen-sequence@1`。随后显示采集／合成／校验，各阶段都禁止重复录制；拒绝或失败后恢复控件。没有停止按钮、秒数／fps 选择器、60 秒倒计时或持续预览。采集总帧数不冒充进度。
- 空间不足在开始前拒绝，显示需要／剩余，允许用户缩至可容纳帧数但不自动开录；剩余空间不可读时说明未检查，仍由 Runtime 存储预检准入。完成后展示实际帧数、实测 fps、缺帧、本地临时 .mov 路径，以及「在访达中显示」「另存为…」「再录一段」。最后一项只回到 idle；前两项在 HTML 中仅演示说明，不写占位文件。
- 原型窗口外提供异常状态选择，窗口内保留演示数据声明；示意截图不含真实设备内容。当前不支持的预览、设备编码、键盘控制和 Session 关联不绘成可用功能。所有实际设备副作用仍由已发布 Catalog / Provider / Runtime 准入；不得 raw HDC 兜底。

### 5.7 Debug 工作台

本节描述 2026-08-27 的当前实现。生产可用性必须读取 exact target/binding 的 Runtime facts；原型中的 demo 状态不能替代它们。更完整的来源管理、批量替换和独立重启仍是设计输入，见本节末尾，不能画成已发布能力。

- 五个 tab：Artifacts / Logs / Apps / Network / Commands，Artifacts 为默认项。使用 roving focus、左右方向键及 Home / End，切换不强制焦点进入内容区。设备 scope 显式显示 target / binding；来源连接成功不代表设备已接管。
- **Artifacts** 当前只接单个 signed app-owned `.so` 的 `deploy.native-library.app-owned@1`。来源为本地文件选择器，或已在 Settings → Servers 验证的 SSH 来源；SSH browser 只在登记 root 下 browse/read/import，允许返回上级但不能越 root。没有四 connector 管理器、checkbox 批量选择或 `.abc` 筛选。
- 阅读顺序为 target/binding → 来源及单文件 → bundle/library 标识 → host validation → 预览计划 → Runtime 结果。改变 target/binding/来源/标识须使旧 preparation 失效；不能拿上一目标的成功反馈继续提交。
- 本地文件和 SSH relative path 只用于导入 Artifact lease。设备目标路径由 published operation/profile materialize，App 不允许任意 device path、raw command、SSH 命令或 PTY。SSH 密码/私钥/口令仅进入 Keychain；首次 host-key 固定与指纹漂移拒绝由来源配置负责。
- 计划 sheet 展示精确 target/binding、bundle、逻辑库名、hash、ABI/ELF/Build ID/code-sign、effect、备份/原子发布/readback/rollback。兼容性预检与不可变备份是两层不同保护；不能用“有备份”代替兼容性证明。无 preparation 或校验失败时不得启用提交。
- `restartAbility` 已位于同一 typed plan 内，不再画“替换完成后点击独立整机重启”的当前流程。只有 Runtime 的完整 terminal/postflight 支持时才显示成功；unknown 不重放。页面和全局 Inspector 显示真实 Job facts，全局 Inspector 本身仍只读。
- **Logs** 是 `capture.diagnostics@1` 的 bounded capture：1–600 秒，Info/Warn/Error、domain/tag/PID/keyword/marker 的 typed filters，raw shard 必保留。开始前验证 target/availability/输入；采集中显示 Job 和 typed cancel。暂停只暂停 viewport，切 tab 不取消 Job；host shard/预算/导出与设备 buffer 分开表达。清空本地视口不等于清空设备日志；设备 buffer operation 尚未发布，入口禁用并说明原因，不能画可提交的危险确认。
- **Apps** 已接 `debug.hap@1`：单 HAP 导入、bundle/Ability 校验；安装策略固定 installOrReplace，清理仅 uninstall/retain，结束状态 stopped/running，可选 diagnostics（1–300 秒）。全新安装与恢复之前版本未发布，不提供选项。typed request 默认折叠，完整计划按 Catalog 的 14 个步骤显示；可用性、文件和身份输入共同决定运行按钮。真实 submit/cancel、terminal 和 Artifact 已接线，原型仅预览参数，不创建演示 Job 冒充执行。
- 包库存的独立启动/停止/卸载与整套 HAP workflow 是不同入口；前者未有对应独立闭集 operation，仍禁用并说明原因，不能把 HAP workflow 的发布当作包行操作授权。
- **Network** 使用 `port-forward.create@1` / `port-forward.remove@1`，支持 forward/reverse，端口只接受 1024…65535 的十进制字段。真实 Runtime Job 与 exact inverse/readback 补偿可见，不接受 shell fragment。
- **Commands** 只允许 daemon 已实现的 closed read-only template；lowered argv 是只读 disclosure，结果保留 Artifact 来源与失败原因。Root、任意终端等不提供执行入口。

**尚未实现的设计输入**：SMB/WSL connector、多 root/批量来源搜索与多选、`.abc` deployment、独立 device restart、设备日志 buffer 清除。保留相应需求与安全边界；只有对应 behavior/Catalog/Provider/recovery/readback 发布后才进入当前可操作稿。当前原型不画这些功能的虚假成功态，也不以删规格来消除实现缺口。

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

- History 是只读 Runtime 活动中心，不是第二套 Job 执行面。摘要只来自 `job.list`；选中记录后才按需加载详情与 Artifact metadata，不用 fixture 或本地推断补齐缺失事实。
- 工作区宽度达到 890 时，三栏为活动类型导航 → 最近记录 → detail inspector；更窄时用顶部活动选择器保留记录/详情两栏，原型低于 620 时上下排列。以实际工作区宽度而非 viewport 判断；双栏/三栏内列表与详情独立滚动。活动类型按 published operation 归入 Flash、Debug、Viewer、Trace、Diagnostics 与 Device；未识别 operation 保留在「其他」和「全部记录」，不得错误映射到相似工具。
- 支持全文搜索、status、executionMode、session、device/target 与 time 筛选；筛选可保存到 toolbar menu。「需要关注」与「最近失败」是筛选预设，不改变 Runtime state。
- 原生与原型窄窗将次要筛选收入「筛选历史」popover，活动选择与搜索保持直接可用；列表/详情只能使用筛选栏下方的剩余高度，不得溢出窗口。原型用独立「已存筛选」入口保留保存/恢复/删除和预设，宽窗继续使用「完整筛选」展开入口。普通筛选保留原生列表载体；显式 Job 导航清除旧筛选后，以恢复的记录重建原生列表并定位整行，空匹配状态不能吞掉定位请求。
- 双栏与三栏的记录区独立滚动，标题、搜索与活动选择不随记录滚走；原型的精确跳转同时检查目标整行位于记录视口内、搜索仍可见。popover 使用平台的非模态交互，不增加 Runtime 执行动作。键盘打开/Escape 与点击外部关闭的原型验收状态见本轮验证记录，不以按钮关闭代替。
- 搜索和筛选使用精确 Job / Session / operation / target / state / executionMode，不把 Job ID 当 Session，也不把显示设备名当 target。active 只匹配已知非终态；needsAttention 使用未解决的 unknown / waitingForHuman 或实际残留计数，有恢复关系的历史 unknown 不因旧 unknown 本身继续报警。时间区间为过去一小时、一天、一周，按 reported finished / started / created 判断；缺失时刻不从“今天”标签推算。支持恢复、删除已存筛选和清除筛选。
- 原型搜索即时更新并保留焦点/光标范围；完整筛选的展开状态不因改条件、清除或恢复而丢失。工具栏短标签不拆行，Inspector 长状态在列表内换行显示；切换语言或页面时，外观控件继续显示实际 system / light / dark 状态。
- interrupted、failed、cancelled 使用不同 symbol + 文案；unknown outcome 额外显示 needsAttention。plan-only / simulated badge 在记录、详情与导出中永久保留。
- 对已知活动类型提供「在 Flash / Debug / Viewer / Trace / Diagnostics 中打开」，只导航并恢复可由已验证记录支持的上下文；它不重放 operation、不把历史 Artifact 当成 fresh device fact，也不绕过目标工作区的 Runtime 准入。
- `capture.diagnostics@1` 即使归类为 Viewer / Trace，也另提供「打开诊断工具」来读取同一 Job 的多通道制品。原分类不变；Diagnostics → Trace 的只读转交继续显示 exact Job 来源，不创建或重放 Job。
- Detail 分组为 Summary / Timeline / Correlation / Evidence / Parameters / Artifacts / Recovery linkage。Artifact 行展示 name / role / origin / size / SHA-256 / privacy / status；关联视图只表达同一 Runtime 投影中已证明的 Job、Session、operation、target 与 Artifact identity。
- Summary 保留 Session 与创建/开始/结束时间；Evidence 保留 Provider / Catalog / binding / authority / observed device / terminal / mode / effect / first evidence / actual step kinds / blockers，Artifact 保留 source operation / media type / status detail。Correlation 只接受当前记录的精确身份并提供同 Session 筛选。完整恢复标志缺失不显示“无需恢复”。
- 六类工作区的只读回访显示可关闭的 exact Job / target / operation / state / Artifact 来源信息；转交 Diagnostics 不改写来源分类。全局 Inspector 打开 History 复用原记录投影，保留 unknown、类型和身份；不创建默认 Diagnostics 行。原型只演示来源元数据，不读取历史 Artifact，也不把工作区样本当成历史文件。
- 所有 History 类型共用事实规则：未报告的 binding、manifest、hash、Journal 或 Artifact 保持缺失，不按 kind/状态填默认值。typed inputs 区分未报告与明确空参数；before / after 仅显示显式 traceParameters，保留 missing / unreadable / unknown 及 unchanged / changed / unverified。cancelled 不证明补偿或参数恢复，unchanged 也不等于执行过恢复。稿件中的样本值明确标为演示。
- 导出以单个 Artifact 为边界：先显示文件名、size、privacy 与 SHA-256；敏感 Artifact 要求显式确认。App 以有界 chunk 读取、复算 byteCount / SHA-256 后写入用户选择的位置，目标路径不跨 daemon 边界。成功后可在 Finder 定位。

### 5.10 Settings

- 使用独立系统 Settings scene，七个标签为 General / Toolchains / Servers / Storage / Trace / Updates / Diagnostics。Trace 内分 Cache / Licenses；按需读取避免首窗被 I/O 阻塞。
- Toolchain 切换明确「只影响新 Job」；Storage 展示 root、quota、retention、pinned 与当前使用量；Updates 复用已实现的 signed update flow。
- Servers 支持 SSH password / key，test connection 产生 fingerprint 和 canonical root，保存验证事实；漂移 fail closed。移除来源不删除服务器文件。
- Storage 可设置新 Job root、quota、safety margin、retention；使用量来自 inventory，不用示例数字补 unknown。
- Trace Cache 只清理未使用的 derived database，不删除原始 Trace；Licenses 展示随包许可证与第三方 notice。
- Updates 只检查已签名 feed、下载并校验，再显式 Finder handoff，不静默安装。
- App 诊断包目前始终排除 device raw；先选择目的地、预览 entry/hash/估算大小，再显式本地导出（AC-DIAG-002-01）。单个敏感 device Artifact 的导出入口在 History，不在 App 诊断包增加无效勾选。

### 5.11 Automation（退役历史，不作为实现待办）

CHG-2026-064 已移除内置 Harness、daemon `task.*`、CLI `task` 命令族和 App Automation
投影；`ArchitectureBoundaryContractTests` 禁止重新引入这个决策平面。
旧 Automation 设计和相关 StatusStrip/StageTrack/BudgetMeters 示例仅保留为历史组件资料。
当前 App 不显示导航或 task 控制；原型旧 URL 显示退役说明，不模拟 running HTASK。
GJ-5 由外部 Agent 调用已发布的 `agent` / `job` / `artifact` 等面推进，不因此新增 App task 宿主。

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

### 7.1 v0.5 基线、v0.6 Flash、v0.8 Viewer、v0.9 Debug 与 v1.3 Diagnostics / Device 评审

- `docs/design/references/v0.5/` 固定保存 1180×760 的简体中文与英文设备详情参考截图；原型通过显式 locale / reference state 生成，不依赖浏览器记忆状态。v0.6 Flash 先在交互原型中评审，确认后再固定同尺寸中英文参考截图并进入 SwiftUI 对齐。
- Viewer 以 `prototype.html?page=dump` 的首次空态为默认可点击事实；点击「抓取视图」后进入与 `prototype.html?page=dump&viewerState=captured` 相同的检查器态。检查器默认选中 `Toggle #42`，可从截图与完整树双向切换节点，且下方属性、布局、无障碍和 raw 内容同步更新；水平分隔条可用指针和键盘调整。
- Trace 以 `prototype.html?page=trace` 为实现同步稿：只保留显式设备、抓取场景、秒/分钟时长、快捷时长、「开始抓取」以及独立「打开 Trace 查看器」入口。秒快捷值为 `5s / 10s / 15s / 30s`，默认选中 `10s`；分钟快捷值为 `1 min / 2 min / 3 min`。旧自定义 tag、参数 snapshot、Artifact 状态卡不得作为后续实现输入恢复。
- Debug 以 `prototype.html?page=debug` 为实现同步稿:五个 tab（Artifacts / Logs / Apps / Network / Commands，Artifacts 默认）使用 roving focus 与左右方向键、Home / End;每组以 section 标题加细线分组，不再逐组画有边界卡片;Runtime 可用性只在标题旁一行呈现，被阻止时才在配置之上展开 reason code。Artifacts 走查「本地文件 / 远端服务器 → 选择或浏览一个已签名 `.so` → 填写所属 Bundle 与 `lib<name>.so` → 校验并检查替换计划（plan digest 与七个 materialized step）→ 备份、替换、重启并验证 → 获取日志并验证」;远端浏览只在已验证编译根目录内列出 `lib*.so`，空态跳转「设置 › 服务器」，服务器编辑必须走查密码 / OpenSSH 私钥分支、端口与绝对路径的字段级错误聚焦，以及主机密钥固定提示。旧的本机目录 / SMB / WSL 来源浏览、按名称与类型搜索、勾选批量替换和独立设备重启不得作为后续实现输入恢复，只能以 unavailable 呈现。原型底部的 production-boundary callout 不得删除。
- v1.3 Diagnostics 以 `prototype.html?page=diagnostics` 为可点击事实：sidebar 同时保留 Trace、Diagnostics 与 Device，切换时各自的 preset、时长、筛选、选择和运行状态不得串扰。默认打开的演示 Session 即第一版默认形态（无录屏、Marker 截图事后拍摄），另有「含录屏」与「Partial + 无法对齐」两个可切换 Session。点击 Marker 截图、可选视频帧、Trace event、HiLog marker 或 Timeline slider 都必须更新同一个时间光标并同步可用画面、`Δt` 与邻近日志；已选 event identity 不被非事件点击清空，光标离开时显示偏离标注。可返回采集页走查「开始诊断 → required channels ready（环形缓冲）→ 自动 Marker 触发 → 标记并截图（pending → +N ms）→ 停止并生成结果 → 生成新 marker-only Session」；`⌘M` 必须可用，默认屏幕录制必须关闭，Partial 横幅、无法对齐降级、截图失败原位说明、对齐 disclosure 和 production-boundary callout 不得删除。
- v1.5 Device 以 `prototype.html?page=device-control` 走查当前实现：默认无画面、40 帧和空日志；截图后一次输入 pending → settled → stale，再点拒绝；unknown 不重发，明确失败保留图可用性。验证按帧录屏采集／合成／校验、缺帧、空间拒绝、缩短及空间不可读；「再录一段」仅重置。Trace 切换不清空 Device 状态；评审场景切换不接受旧回调。移除原 v1.3 的持续预览、键盘虚拟指针、60 秒倒计时与 MP4 路径设想。
- 参考截图只校验导航层级、宽屏分栏、信息密度、context menu 和文案长度，不是生产 Runtime 截图，更不是硬件验收证据；截图中必须持续标明演示数据。
- App UI 测试在同一 1180×760 默认窗口和中英文 fixture 下检查：设备详情只有一个主标题、双栏/单栏的几何关系；Flash 默认只显示设备、镜像和主操作，运行态显示阶段与真实 byte-derived 估算，结果态只在 postflight 成功后出现成功文案。测试附加当次窗口截图供人工 diff；系统字体、accent、材质和抗锯齿继续由 macOS 控制，不用逐像素阈值锁死原生渲染。

## 8. v1.2 已决视觉项

- 图标：产品使用 SF Symbols；HTML 原型使用单色 inline SVG 近似，禁止 Emoji 作为最终导航图标。
- 2026-08-27 图标评审：Debug 改用 `terminal`，同步 Sidebar、Overview 返回入口与 History；Device 保留 `iphone`。Sidebar 统一 22×22 pt 图标占位，其余 symbol 使用系统 medium scale，手机使用 large scale 做光学补偿；保留各自长宽比与原生字重，不用拉伸统一轮廓。原型使用 22×22 px 占位、18 px 常规图标／20 px 手机，手机笔画随尺寸补偿，保持视觉线重一致。Viewer、Trace、诊断的图标造型不变。
- 密度：默认紧凑舒适（macOS medium sidebar size）；不额外提供 App 内密度开关，尊重系统设置。
- Job Inspector：默认折叠；有 running / waiting / humanRequired 时显示摘要但不自动抢焦点。
- 外观：跟随系统；不默认强制 dark。
- Accent：跟随用户系统 accent；ArkDeck 不固定 teal 覆盖系统选择。
- Viewer：首次进入先显示真实空态；抓取成功后使用左侧截图 + 右侧上下检查器。树与属性之间保留紧凑的可拖动结构分隔线，不使用圆角卡片。普通截图边界默认隐藏，当前选中边界、树行与 inspector 使用同一 accent selection，并保留 ID / type 文字线索。
- Diagnostic：参考宽屏使用“上方当前画面 + 当前时间上下文、下方全宽 Timeline”，不做三个等宽文件查看器。Trace event 是主选择身份，Marker 截图、可选视频与日志可反向移动共享光标但不伪造也不清空 event identity。默认不持续录屏；Marker 截图按拍摄时刻显示并固定标注 `+N ms`；画面 metadata 与对齐状态固定可见（第一版两态）；自动与手动 Marker 在 track 上样式区分；Timeline 用结构分隔，不把每条 Track 包成卡片。
- Device：与当前 App 相同的无二级导航布局。顶部 target / binding 与截图动作，左图右 Inspector（窄窗纵向）；空态居中，无手机壳或虚构默认截图。录屏按帧数，结果在原分组内显示，性能提示和静止画面边界常显。详见 v1.5 中英文参考图。
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
