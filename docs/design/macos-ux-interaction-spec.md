# ArkDeck macOS UX 与交互定义

> Status：draft v0.8（design input，非 normative；2026-08-22 完成 Viewer DevTools 式上下检查器对齐；2026-08-23 与 SwiftUI 实现对齐一轮视觉词汇，见 §8）
> 交互原型：`docs/design/prototype.html`（可点击，与本文档同版本演进）
> 行为事实源：`openspec/specs/desktop-ux-observability/spec.md`、各 capability spec、Catalog 与 Runtime contracts；本文档只定义 HOW（布局、组件、层级与流转），行为冲突时以事实源为准
> Promotion：本目录是草稿区。被采纳的版本在起草 M2+ 功能 change 前移入 `openspec/platforms/macos/design/`，并由 change 的 `design.md` hash-pin。设计中发现的行为级缺口必须走 behavior delta，不能只画进稿子。

## 0. v0.8 目标与当前实现边界

v0.8 延续 v0.7 的 `Viewer` 命名与选中联动，将检查器重排为 Chrome DevTools 式结构：左侧设备截图；右侧上方为可展开、可双向滚动的完整 UI 树，下方为当前节点属性。树与属性共享垂直空间并可拖动分隔条调整比例，以容纳很深的组件层级。数据源仍是 ArkUI dump，但用户可见的功能名始终为 `Viewer`。

当前代码与目标设计的边界必须如实呈现：

| Surface | 当前实现 | v0.8 设计方向 |
| --- | --- | --- |
| App shell | SwiftUI `WindowGroup` + `NavigationSplitView`；Overview / Flash / Debug / Viewer / Trace / History / Automation 均有实际工作区 | 保留原生 split view；导航及页面用户可见名统一为 `Viewer`；统一 toolbar、全局 Job inspector 与窗口自适应 |
| Device detail | 未授权设备有接管引导；已接管设备能显示真实 binding / observation facts，并有原生右键重命名和重新检测 | 删除重复内容标题；宽屏拆分状态操作与事实；名称只是 App 展示别名，重新检测只刷新候选事实 |
| Overview | `HDCStatusView` 展示 HDC、授权、通道、Rockchip 访问诊断与 target-bound 能力矩阵 | 分组为「服务器」「设备与通道」「能力」「需处理事项」，unknown 与 unavailable 不合并 |
| Viewer | `UIDumpWorkspaceView` 仍是窗口、Recipe、参数策略与产物审核表单 | 改为左侧截图 + 右侧上下检查器；UI 树在上、当前节点属性在下，截图区域、树节点与属性选中态双向同步 |
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
- toolbar 显示精确 target + window、最近抓取时间、「重新抓取」和「搜索组件 / ID / 文本」。截图和 dump 树必须来自同一次 capture epoch；任一侧缺失或时代不一致时不得建立可点击映射。
- 宽屏使用左右双区：左侧「设备截图」；右侧参考 Chrome DevTools Elements 检查器纵向分为「UI 树」和「节点属性」。同一选中组件在截图中用 accent 边界框标记、在树中使用唯一选中行，并立即刷新下方属性。截图或树发起选择都必须更新另外两处。
- 截图默认显示低对比度组件边界，当前组件使用 2px accent 边界和 `#<componentId> <type>` 标签。重叠 bounds 命中最深的可见节点；父节点可从 breadcrumb 或树中选择，不用多个重叠透明热区争抢指针事件。
- UI 树是完整节点序列，默认展开到当前节点并自动滚动使其可见；深层缩进不截断节点名，树区域同时支持横向与纵向滚动。搜索只改变树的呈现，不改变 capture 与选中 identity。树遵循 macOS outline keyboard pattern：上下移动，左键折叠或返回父节点，右键展开或进入首个子节点，Enter / Space 选择。
- 下方节点属性区使用「属性 / 布局 / 无障碍 / Raw dump」分类。结构化字段只作为快速阅读；`Raw dump` 必须保留该节点的全部原始字段，不因 UI 未识别字段而丢失信息。
- 选中后不强制移动键盘焦点；变化通过稳定的 polite status 播报。截图可点区域与树行都使用原生 button 语义和可见 `focusVisible`，不只依赖颜色表达选中。
- UI 树默认获得右侧较多高度；树与属性之间使用可拖动的水平分隔条，键盘可用上下方向键微调、Home / End 跳到允许范围两端。调整只改变可视比例，不改变节点选择和滚动身份。
- 窗口变窄时仍保持右侧「UI 树在上、节点属性在下」的关联结构；无法容纳左右双区时按「设备截图 → 右侧检查器」单列排列。任一宽度下当前节点、搜索、树的双向滚动和 raw 信息都不可被裁掉。
- Viewer 数据默认本地保存且按敏感 Artifact 处理；导出前仍须预览和确认。Fault/Crash Artifact 与整机诊断快照不得伪装成 Viewer 中的另一类节点。

### 5.4 Trace

- Toolbar 或 section header 使用 Preset / Custom segmented control；只显示设备已确认 tag，unsupported tag 禁用并解释。
- `trace.probe` 返回 target / binding 绑定的 tag 集与全部参数 before 值；Job evidence 返回 after 值。snapshot diff 是 table，不用彩色卡片；missing / unreadable 明确「不可自动恢复」。需重启时在执行前显示影响。
- 无可靠总量时显示 indeterminate + elapsed，不伪造百分比。完成后 raw / filtered / capture.log 分列，筛选是派生产物操作。

### 5.5 Debug 工作台

- 四个 tab：Logs / Apps / Network / Commands。Tab 遵循 macOS keyboard pattern；tab 内容改变时焦点不被强制移动。
- Logs：bounded live viewport、等级/tag/filter、host shard 状态；「暂停界面」不停止 host capture。「清空设备 buffer」位于 destructive actions menu，走危险 sheet。
- Apps：HAP import、install/start/stop/uninstall；mutation 与 read-only action 分组，package/PID 使用 tabular numbers。
- Network：`port-forward.create@1` / `port-forward.remove@1` 产生真实 Runtime Job，端口只接受 1024…65535 的十进制字段；失败后以 exact inverse + readback 补偿，不接受 shell fragment。
- Commands：只能选择 daemon 实现的 closed read-only template。执行结果可显示已脱敏 connect key 的 executable / argument disclosure 与 lowering SHA；这些值从不作为请求字段，没有任意文本命令输入，也不模拟 PTY。

### 5.6 Flash

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

### 5.7 History（REQ-UX-004）

- 三栏：filter/sidebar → Session table → detail inspector。筛选支持 status、executionMode、device、time 和全文搜索；filter 可保存为 toolbar menu。
- interrupted、failed、cancelled 使用不同 symbol + 文案；unknown outcome 额外显示 needsAttention。
- Detail 分组为 Summary / Timeline / Parameters / Artifacts / Recovery linkage。Artifact 行展示 name / role / origin / size / SHA-256 / privacy / status。
- 导出以单个 Artifact 为边界：先显示文件名、size、privacy 与 SHA-256；敏感 Artifact 要求显式确认。App 以有界 chunk 读取、复算 byteCount / SHA-256 后写入用户选择的位置，目标路径不跨 daemon 边界。成功后可在 Finder 定位。

### 5.8 Settings

- 使用系统 Settings scene，分为 General / Toolchains / Storage / Updates / Diagnostics。
- Toolchain 切换明确「只影响新 Job」；Storage 展示 root、quota、retention、pinned 与当前使用量；Updates 复用已实现的 signed update flow。
- 诊断包默认不含 device raw，可预览勾选且无自动上传（AC-DIAG-002-01）。

### 5.9 Automation / Bounded AI Debug Loop

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

### 7.1 v0.5 基线、v0.6 Flash 与 v0.8 Viewer 评审

- `docs/design/references/v0.5/` 固定保存 1180×760 的简体中文与英文设备详情参考截图；原型通过显式 locale / reference state 生成，不依赖浏览器记忆状态。v0.6 Flash 先在交互原型中评审，确认后再固定同尺寸中英文参考截图并进入 SwiftUI 对齐。
- v0.8 Viewer 以 `prototype.html?page=dump` 为可点击事实：默认选中 `Toggle #42`，必须可从截图与完整树双向切换节点，且下方属性、布局、无障碍和 raw 内容同步更新；水平分隔条可用指针和键盘调整。固定参考截图只在本轮方向确认后补入，避免把未确认的提案当成回归基线。
- 参考截图只校验导航层级、宽屏分栏、信息密度、context menu 和文案长度，不是生产 Runtime 截图，更不是硬件验收证据；截图中必须持续标明演示数据。
- App UI 测试在同一 1180×760 默认窗口和中英文 fixture 下检查：设备详情只有一个主标题、双栏/单栏的几何关系；Flash 默认只显示设备、镜像和主操作，运行态显示阶段与真实 byte-derived 估算，结果态只在 postflight 成功后出现成功文案。测试附加当次窗口截图供人工 diff；系统字体、accent、材质和抗锯齿继续由 macOS 控制，不用逐像素阈值锁死原生渲染。

## 8. v0.8 已决视觉项

- 图标：产品使用 SF Symbols；HTML 原型使用单色 inline SVG 近似，禁止 Emoji 作为最终导航图标。
- 密度：默认紧凑舒适（macOS medium sidebar size）；不额外提供 App 内密度开关，尊重系统设置。
- Job Inspector：默认折叠；有 running / waiting / humanRequired 时显示摘要但不自动抢焦点。
- 外观：跟随系统；不默认强制 dark。
- Accent：跟随用户系统 accent；ArkDeck 不固定 teal 覆盖系统选择。
- Viewer：使用左侧截图 + 右侧上下检查器；树与属性之间保留紧凑的可拖动结构分隔线，不使用圆角卡片。截图边界、树行与 inspector 用同一 accent selection，但选中同时保留 ID / type 文字线索。
- 页面标题只在 toolbar：任何工作区的内容区都不再画与 toolbar 同名的主标题。原型此前每页一个 `<h1>` 且标题栏显示「ArkDeck — 页面名」，两者不重复；SwiftUI 的 `navigationTitle` 只显示裸页面名，内容区再画一遍就成了字面重复，违反 §3 与 §6 的「一个 detail 只有一个可感知主标题」。需要解释的页面改用一行 secondary 说明 + 页面级控件（Debug 的 scope 行即此形态）。原型已同步移除全部 `<h1>`，改由 `data-page-title` 提供标题栏文本。
- 统一页面测量 920：Flash、设备详情与 Trace 此前各自取 760 / 920 / 1000。在 1180 参考窗口下 detail pane 约 926，920 正好填满而不留死白，在更宽的显示器上仍有界。正文段落另按约 620 收窄，Flash 的「一条平静阅读路径」不靠整页变窄来实现。
- 容器圆角 11：与 §2 同心圆角一致，外层 container 11、内嵌 box 9、control 7。

## 9. 平台设计参考

- [Designing for macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos/)
- [Sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars)
- [Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars)
- [Split views](https://developer.apple.com/design/human-interface-guidelines/split-views)
- [Materials](https://developer.apple.com/design/human-interface-guidelines/materials)
