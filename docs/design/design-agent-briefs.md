# ArkDeck 设计稿 briefs（v1.6 全入口索引）

每份对应规格 `docs/design/macos-ux-interaction-spec.md` §5.x 的一个功能页。
用法:在 claude.ai/design 的 ArkDeck 项目里**开新对话,一次贴一份**。不要一次让它画完整个 app。

2026-08-27 按 `e1d52e68` 全页复核。当前优先读取 [v1.6 §0 / §5](macos-ux-interaction-spec.md) 与
[完整覆盖矩阵](implementation-audit-2026-08-27.md)；旧九页列表遗漏 Device、Diagnostics、Trace Viewer/帮助及 Settings 子标签。

| 当前入口 | 必须附带的子页面/状态 | 实现边界 |
| --- | --- | --- |
| Overview | scope/SSH 绑定、下一步、调试线、环境、继续检查 sheet、HDC impact sheet | 已落地结构；仅校验通过的只读观测可准备原始 typed inputs / thread 新草稿；导航与提交分开 |
| 设备详情 | unauthorized/polling/timeout/authorized-unadopted/adopted/offline、rename、re-check | App 不执行接管；HDC 修复去 Overview |
| Flash | 镜像选择、计划/前置条件、Loader、写入/重启/postflight、失败/unknown | 当前同页主动作，不恢复旧第二确认框 |
| Debug | Artifacts/Logs/Apps/Network/Commands、SSH browser、单库计划 sheet、buffer/export 提示 | 本地单文件/只读 SSH 已接通；批量/abc/独立重启未实现 |
| Viewer | 空态/capture、截图/树、搜索；属性/布局/可访问性/原始/高级 Dump | 不新增 UI Dump 独立导航 |
| Trace | 可用/不可用、数字校验、单位/快捷值、active/terminal/Artifact 失败 | 秒 5/10/15/30；分钟 1/2/3 |
| Trace Viewer / 帮助 | 空态/recent、loading/cancel/error、loaded timeline、event/range/annotation、dock、快捷键 | 独立窗口与普通文案双语；通用稿补齐 loaded、选择/范围/标注/停靠；帮助镜像上游 19 条 |
| Device | 空态/截图/过期/输入 unknown、配额预检/逐帧/合成/校验/失败 | 默认 40 帧；无持续预览或键盘输入 |
| Diagnostics | empty/loading/failed/loaded/partial；缺失事件时刻/无校准；显式文本读取与 Trace 转交 | 保存 Session reader 已接通；交互式 arm/append/stop 未接通 |
| History | 八类活动；完整 filters/saved/page；detail/evidence/artifact export/context | History 本身只读；Diagnostics 历史 reader 已接通 |
| Settings | General/Toolchains/Servers/Storage/Trace/Updates/Diagnostics；Cache/Licenses；server editor/delete；导出预览 | 独立窗口；App diagnostics 排除 raw |
| 横切 | Job 详情/标准日志/取消请求、恢复 banner、系统文件选择器/保存框 | 日志/取消已接线；rebind/archive 仍不可用，不能用确认覆盖 unknown |
| Automation | 旧链接只说明退役 | CHG-2026-064 已删除 App/CLI/daemon task 平面；不作为待实现功能 |

**旧 brief 使用限制**：以下保留历史细节以便追溯；凡与上表或 v1.6 冲突的导航数量、
Overview 四卡布局、Debug 多 connector、Settings 五标签、Automation production 声明、
旧无边界 cancel/rebind/archive、HDC 直接重启及任意操作参数复用都已失效，不可单独复制为当前实现任务。

三点使用须知:

1. **设计 agent 看不到这个仓库。** 它自动拿到的只有组件 bundle、每个组件的 `.prompt.md` / `.d.ts`,以及 README 里的约定头(token 词表、危险语义规则)。它不知道 §5 的页面定义,也没读过 `prototype.html`——所以 brief 必须自带事实。这也是每份 brief 里「内容」段要逐字照抄的原因。
2. **「必须画出的语义」段是重点。** ArkDeck 的设计价值几乎全在非顺利路径上;不点名,agent 只会画顺利路径,那样的稿子没有评审价值。
3. **画出来的是候选稿,不是规格的替代。** 本目录 §5 是非 normative 的 HOW 设计输入，accepted specs/Catalog 才是行为事实源;两者不一致时以规格为准,发现行为级缺口要走 behavior delta,不能只改稿子。

下面九份历史 brief 写成时发现的规格↔原型不一致,以及规格要求但原型无内容的地方,都已就地标注在对应 brief 里。

---

## 5.1 Overview

> 历史细节：当前实现以本文顶部 v1.6 索引与对应交互定义为准；不得把下文旧入口视作已发布能力。

> 贴进 claude.ai/design 项目的新对话。

用 ArkDeck 组件画 **Overview** 页。

**布局** — `WindowFrame`,标题 `ArkDeck — OpenHarmony 设备工作台`。
左栏的设备行由 `device.candidates` 动态产生；`NavItem` × 7（Overview · Flash · Debug · Viewer · Trace · History · Automation，Overview 为当前页），不画 Settings 导航项。
内容区自上而下:`StatusStrip` 四格 → 两列 `Card` 网格,四张卡片依次是 HDC 工具链 / 连接与通道保护 / 能力矩阵 / 设备访问诊断。
底部 `JobInspector` 折叠态常驻。

**内容** — 只绑定生产 presentation，不硬编码设备、build、serial、hash 或探测结论:

StatusStrip 四格:
- `HDC server` → 当前 health / generation
- `目标设备` → 当前 adopted target / connection state；无 target 时显示明确空态
- `通道保护` → 当前 protection verdict
- `需处理` → 当前诊断计数

卡片一「HDC 工具链」,用 `KeyValueList`:
| 来源 / 路径 | 当前 HDC selection snapshot |
| 平台信任 | 当前 trust verdict + reason |
| client / server / daemon | 当前版本事实；缺失写 unknown |
| server | health · generation · ownership |
| endpoint | 当前 host / port / source |
| SHA-256 | 完整值可选择，视觉中间省略 |
| 自动 lifecycle / subserver | Runtime 返回的计数 |

版本不一致时尾注:`版本字符串不一致:只读能力按独立探测结论呈现;Flash 仍需命中已验证组合。ArkDeck 不会自动重启 external server。`

卡片二「连接与通道保护」,`KeyValueList`:
- 当前设备 → transport + 独立 authorization Chip + 独立 channel-protection Chip
- `策略` → `无可靠加密证据 → 按未受保护通道处理;设备授权 ≠ 链路机密性`

卡片三「能力矩阵（当前 target）」,`DataTable`,列 = 能力 / 状态 / 探测证据（第三列 mono），固定四行:
- `hidumper`：`debug.template.run(windowInventory)` 的 target / binding-bound 结果
- `hitrace`：`trace.probe` 的 disposition、family、tag 数与 help SHA
- `bytrace`：同一 `trace.probe` 的独立 disposition；probe failed / unrecognized 都显示 `无法确认`
- `RockUSB Flash`：Catalog 中 `flash.dayu200` 的 availability / reason

状态闭集为 `可用` / `受限` / `不可用` / `无法确认`。不存在 `flashd` 行，也没有 raw shell 输出入口。

卡片四「设备访问诊断」,当前无异常时的文案:
`当前未发现 permissionDenied / driverUnavailable。若出现,将区别于 offline/unauthorized 展示,并给出由谁执行的最小权限修复步骤;ArkDeck 不会自动提权或写系统规则。`

**必须画出的语义** — 这几条是本页的存在理由,画错就等于画反:

1. **unknown 与 unavailable 必须视觉可分。** probe failed / unrecognized 是「无法确认」，Catalog 明确 unavailable 才是「不可用」；ArkDeck 不从“没探测到”推断“没有”。
2. **「已授权」与「加密未验证」是两枚独立 chip,不能合并成一个状态。** 设备授权 ≠ 链路机密性。
3. **版本不一致(`mismatchUnverified`)不阻断只读能力,但阻断 Flash。** 尾注要说清这个分级,不要写成"工具链故障"。
4. `ownership: external` 意味着这个 server 是 DevEco 起的——页面上不能出现任何"重启 server"的主按钮,那是 §5.2 里的独立危险 sheet。

**不要做的事**:不要发明设备名、build 串或 hash；不要复活 `flashd`、raw shell 或 `查看 raw`；不要把四张卡合并成一张长表；不要给任何 chip 配 emoji。

---

## 5.2 设备接管与授权

> 历史细节：当前实现以本文顶部 v1.6 索引与对应交互定义为准；不得把下文旧入口视作已发布能力。

> 贴进 claude.ai/design 项目的新对话。

用 ArkDeck 组件画 **设备授权** 页。

**布局** — `WindowFrame`,标题 `ArkDeck — OpenHarmony 设备工作台`。
左栏设备行来自 `device.candidates`，当前选中 unauthorized candidate；`NavItem` × 7（Overview · Flash · Debug · Viewer · Trace · History · Automation）。本页是点击未授权设备行进入的,不是导航目的地 —— 七个 `NavItem` 全部非活动。
内容区只有一张 `Card`,宽度上限 640,不铺满 detail:标题 → 三步 onboarding 有序列表 → 状态块(随阶段替换) → 一行按钮。三步就是 spec 说的 解锁 → 设备端信任 → 有界等待。
底部 `JobInspector` 折叠态常驻。

一共画 **四个生产状态**:`idle` / `polling`(E000002 等待中) / `timedOut`(E000003) / `ready`,外加一张独立的 `DangerConfirmDialog`。四个状态共用同一张卡的骨架,只换状态块和按钮行。`denied` 暂无生产 probe 判据，不画成生产状态。

**内容** — 逐字使用,不要改写、不要翻译、不要补充:

页标题:`设备授权 — unknown-tablet`
卡片标题:`此设备尚未信任本机(E000002)`

三步有序列表(四个状态里都在,不随阶段消失):
1. `解锁设备屏幕;`
2. `在设备弹出的「是否信任此计算机?」中选择 信任 或 始终信任;`(`信任` 与 `始终信任` 加粗)
3. `ArkDeck 将自动检测授权结果(有界轮询,不反复弹通知)。`

状态块,每个阶段只出现一个:
- `idle` — 无状态块。
- `polling` — warn `Chip`(带缓慢脉冲):`等待设备端确认… 03:00`。`03:00` 是 mm:ss 倒计时,从 180 秒起数。
- `timedOut` — warn `Callout`:`等待设备授权超时(E000003 · timedOut)。这不等同于已知 denied。请解锁设备、检查 USB 调试与信任弹窗后重试。`
- `ready` — ok `Callout`:`已授权,设备 Ready——列表与 Overview 已更新。`

按钮行:
| 阶段 | 主按钮 | 次按钮 |
| --- | --- | --- |
| idle | primary `开始等待授权` | — |
| polling | primary `开始等待授权`,disabled | — |
| timedOut | primary `重试:开始等待授权` | danger `重启共享 HDC server…` |
| ready | primary `开始等待授权` | — |

左栏未授权设备行:warning symbol + `需要信任`,transport `USB`。
(原型该行现在写的是 `未授权 — 点击处理`;spec §5.2 要求 `需要信任`,按 spec 画。)
左栏 ready 设备行:`rk3568-dev` · `OpenHarmony 5.0.0.71` · `USB`。
`ready` 那张图里,原来的未授权行变成 `ohos-tablet` · `OpenHarmony 5.0.0.46` · `USB` · ready。

独立危险 sheet,`DangerConfirmDialog`:
- `title` = `重启共享 HDC server?`
- `impactTitle` = `影响范围`
- `impact` 三条:
  - `该 server 由 DevEco Studio 启动(ownership: external),重启将断开其与所有已连接设备的会话`
  - `其他工具正在进行的传输/调试会失败`
  - `ArkDeck 从不静默执行此操作`
- `acknowledgements` 一条:`我了解会影响 DevEco 与其他设备会话`
- `confirmLabel` = `重启共享 HDC server`,`cancelLabel` = `取消`

**必须画出的语义** — 这几条是本页的存在理由,画错就等于画反:

1. **E000002 与 E000003 是两个状态,不是同一条错误的两种措辞。** E000002 = 还在等(warn chip + 倒计时,主按钮 disabled,没有次按钮);E000003 = 等待窗口已经关掉(warn callout + 可点的重试)。同一张卡上永远不会同时出现这两块。
2. **retry 是普通按钮。** `Button variant="primary"`,没有确认 sheet、没有勾选门、没有 danger 描边。「再等一次」在 ArkDeck 眼里是零代价动作,不该被仪式化。
3. **重启共享 HDC server 绝不是默认修复。** 它只在 `timedOut` 态出现,只在次要位置,永远不占主按钮位、不预选、不出现在 idle/polling/ready。它走独立 sheet 且必须勾选才解锁 —— 因为这个 server 是 DevEco 起的,重启掉的是别人的会话。
4. **左栏那一行读作「需要信任」,不是「离线」也不是「错误」。** 未授权是一个人能当场解决的状态;offline 不是。三态点必须可分:ready = ok、unauthorized = warn、offline = 灰。
5. **有界等待要把边界画出来。** `03:00` 是真的会走到 0,走到 0 就翻成 E000003。不要画无限旋转的 spinner,也不要给这段等待配百分比进度 —— ArkDeck 不知道用户什么时候会去点那个弹窗。
6. **`ready` 那张图里设备名和 build 变了(unknown-tablet → ohos-tablet · OpenHarmony 5.0.0.46)。** 授权之前 ArkDeck 拿不到设备身份,这不是刷新延迟,是「没测到」和「测到的值」的区别。

**不要做的事**:不要把原型里的 `模拟:用户拒绝(E000003)` 按钮画进产品页,那是原型自己的演示开关;不要画 `REQ-HDC-007` / `AC-HDC-007-01/02` 这类 AC 标注 chip(spec §7:评审叠加层,不进产品);不要把 E000003 画成红色 danger,原型是 warn;不要发明 serial、key 或别的错误码;不要让这张卡铺满 detail 宽度。

---

## 5.3 Viewer

> 贴进 claude.ai/design 项目的新对话。
>
> 生产实现交接：[`viewer-ui-implementation-task.md`](viewer-ui-implementation-task.md)。
> 该 brief 复用 `TASK-AIN-021`，不新建 OpenSpec Task，也不改变本设计稿版本号。

用 ArkDeck 组件画 **Viewer** 页。页面名、导航名和任务名只使用 `Viewer`；`ArkUI dump` 只用于描述数据源。

**事实源顺序** — 当前 SwiftUI `UIDumpWorkspaceView` 是产品表面的事实源；本 brief、
`prototype.html?page=dump` 和设计系统组件只镜像它。设计更新不得先行发明新的 Viewer
步骤、控件或默认状态。窗口工具栏只显示一个 `Viewer` 主标题，内容区不要再重复 `<h1>`。

**布局** — `WindowFrame`，标题 `ArkDeck — Viewer`。左栏：`DeviceRow` × 2
（DAYU200 · ready；unknown-tablet · unauthorized）+ `NavItem` × 8，`Viewer` 为当前页。
detail 默认不是 inspector，而是生产实现的空态；完成一次抓取后才切换为占满可用空间的
DevTools 式双区 inspector：左侧 `ViewerScreenshot`；右侧 `ViewerInspectorStack`，上方
`ComponentTree`、下方 `DumpInspector`。底部 `JobInspector` 折叠态常驻。

**默认空态**（`prototype.html?page=dump`）:

- toolbar：设备选择器、`搜索组件 / ID / 文本`、primary `抓取视图`；没有 current root、
  capture 时间和搜索匹配导航；
- 中央标题：`没有已验证的 capture`；
- 说明：`「抓取视图」会创建一个 typed Runtime Job，并且只展示同一个 Job 里通过校验的 Artifact。`。

**已抓取态**（`prototype.html?page=dump&viewerState=captured`）:

- toolbar：设备选择器、当前 screen/root、ISO capture 时间、搜索框；输入搜索词后显示
  `匹配数 / 总节点数` 与上一项/下一项；primary 按钮改为 `重新抓取`；
- 内容变为截图 + 树/属性双区 inspector；
- 底部为一次抓取的生产指标摘要：`nodes · submit · run · list · read · parse · Σ`。

**左栏「设备截图」**
- 显示一张 OpenHarmony 设置页截图，包含「设置 / WLAN / 蓝牙 / 移动网络 / 显示和亮度 / 声音和振动」。
- `显示组件边界` 默认关闭；关闭时当前节点仍使用 2px accent 边界和 `#42 Toggle` 标签，开启后才为其他节点增加低对比度 1px accent 边界。
- 截图上每个有 bounds 的节点都可选择。重叠时命中最深的可见节点，父节点通过 breadcrumb 或树选择，不让多层透明热区争抢事件。

**右侧上方「UI 树」**
- 显示完整、可展开、可横向与纵向滚动的树，header 只显示 `ArkUI dump · 28 / 28`。层级很深时保留完整节点名，不用省略号吞掉末端信息；示例至少包含一个 9 层长名称节点，以明确展示横向滚动能力。
- 树至少展示：`Root #1 → Stage #3 → Column #8 → Navigation #12 / List #21 → ListItem #22 → Row #31 → Text WLAN #38 / Row #40 → Toggle #42`。
- `Toggle #42` 使用与截图命中框相同的 accent 选中态。选择截图节点时树自动滚动使对应行可见，但不抢键盘焦点。

**右侧下方「节点属性」**
- 与 UI 树之间使用紧凑的水平拖动分隔条，默认 UI 树约占右侧高度 60%；分隔条支持指针拖动和上下方向键调整。
- header：`Toggle` + chips `#42 / Interactive / Visible`；技术词与实际 Inspector 一致，不随 App 语言切换。
- breadcrumb：`Root / Stage / Column / List / Row / Toggle`。
- tabs：`Properties / Layout / Accessibility / Raw dump / Advanced Dump`，默认选中 `Properties`。
- 属性表展示：`id / type / inspectorId / text / bounds / enabled / visible / clickable / focusable / checked / opacity / zIndex / hitTestBehavior`。
- 下方 disclosure：`布局与渲染 / 无障碍 / 原始 dump`。`Raw dump` 必须可查看该节点的全部原始字段，不因结构化 inspector 未识别字段而丢失信息。
- `Advanced Dump` 已实现按选中组件惰性读取 `componentDetail`、字段/值搜索、loading、缺失数字 ID 和失败重试；必须画出第五标签，不得沿用上一组件的结果。原型使用 `viewerTab=advanced`，拒绝/失败/加载演示分别使用 `advancedState=missingIDs/failed/loading`。

**必须画出的语义**：

1. **左右双区是同一个 selection model。** 截图框、树行和下方属性 header 都必须指向 `Toggle #42`；截图或树选择新节点时，另外两处同步更新。
2. **截图与树必须来自同一 capture epoch。** 不用旧截图去映射新 dump；数据不完整时显示无法建立映射，不猜测 bounds。
3. **树不是只显示命中附近的摘要。** 它是完整 dump 树，搜索只改变当前显示结果。
4. **详情不是只列常用字段。** 结构化分组用于快速阅读，完整 raw 始终可达。
5. **键盘与指针路径等价。** 截图区和树行有原生 button / outline 语义与 `focusVisible`；树支持上下选项、左右折叠展开与父子节点。分隔条使用 `role=separator`，方向键和指针都能调整高度。
6. **窄屏不拆散树与属性。** 中等宽度继续保留左侧截图 + 右侧上下检查器；更窄时按截图 → 检查器单列排列，检查器内部始终是树在上、属性在下。
7. **空态是首屏，不是异常态。** 没有经过验证的 capture 时不画演示截图或 fixture 树；用户先选择设备并抓取，验证完成后才原子切换到 inspector。

**不要做的事**：不要给 `Viewer` 增加任何产品前缀或恢复旧名；不要在内容区重复窗口标题；不要让默认页面直接落入演示 capture；不要保留旧 Window inventory / Recipe / Debug parameter policy / Review 表单；不要把属性恢复成独立第三栏；不要让下方属性挤掉树的最小可用高度；不要只靠颜色表达选中；不要展示 raw command 输入。

## 5.4 Trace

> 贴进 claude.ai/design 项目的新对话。

用 ArkDeck 组件画 **Trace** 页。

**事实源顺序** — 当前 SwiftUI `TraceWorkspaceView`、`TraceConfigurationView` 与
`TraceProgressArtifactsView` 是产品表面的事实源；本 brief 和
`prototype.html?page=trace` 只镜像它。Trace 页只承担两件事：抓取 Trace、打开 Trace
查看器。窗口工具栏只显示一个 `Trace` 主标题，内容区不要重复标题。

**布局** — `WindowFrame`，标题 `ArkDeck — Trace`。左栏：已接管设备 + `NavItem` × 8，
`Trace` 为当前页。detail 是一个纵向、单阅读顺序页面，不使用两列 dashboard，也不放
`RecoveryBanner`、参数快照卡或 Artifact 状态卡。底部全局 `JobInspector` 仍由 App shell
负责，不复制进 Trace 内容。

detail 从上到下固定为：

1. 摘要：`从已接管的 OpenHarmony 设备抓取 Trace，然后在内置查看器中分析。`
2. `抓取 Trace` section，标题右侧显示 `检查中`、`可以抓取` 或 `暂时无法抓取`；
3. `查看 Trace` section，提供独立 Trace Viewer 窗口入口。

**抓取 Trace**:

- `设备`：单选 Picker；下方显示截短的设备 connection summary，完整值通过 help /
  accessibility 暴露；
- `抓取场景`：单选 Picker，生产列表为 `应用响应`、`渲染与动画`、`CPU 调度`、
  `I/O`、`系统概览`；下方显示当前场景对应的生产说明；
- `时长`：72pt 数字输入 + `秒 / 分钟` segmented control；秒快捷值固定为
  `5s / 10s / 15s / 30s`，默认选中 `10s`；分钟快捷值固定为
  `1 min / 2 min / 3 min`；
- section footer 左侧只显示当前事实：正在提交、失败、terminal outcome、首个 blocker，
  或 `Trace 只保存在这台 Mac，并会在完成后自动打开。`；
- footer 右侧未运行时为 primary `开始抓取`；存在 active Job 时显示 job ID 和 `取消抓取`。
  blocked/invalid 时仍可点击，以明确显示首个错误，但不会提交 Runtime 请求；提交中禁用重复动作。

**查看 Trace**:

- 默认说明：`在查看器中打开本地 Trace，或继续查看最近的 Trace。`；
- trailing 按钮：`打开 Trace 查看器`；
- 正在准备、读取失败、最近 Artifact 三种状态原位替换说明；失败态可 `再试一次`；
- 查看器通过单独的 ArkDeck window 打开，不把时间轴内嵌回 Trace 抓取页。

**必须画出的语义**:

1. **页内只有抓取与查看。** 能力探测、typed Job、Artifact 验证和 viewer preparation
   仍在 facade / Runtime 后面完成，不把内部实现细节扩写成配置 dashboard。
2. **不可用也保留动作位置。** 页头状态与 footer blocker 清楚说明原因；`开始抓取` 按
   生产逻辑反馈校验错误，不切入演示采集中。可点击不代表 Runtime 可执行。
3. **时长控件和生产边界一致。** 设计稿只使用秒/分钟及当前快捷值；输入非法时在控件下方
   显示 validation，不发明新档位。
4. **Viewer 是单独窗口。** 打开本地或最近 Trace 后进入共享查看器，抓取页本身不承担
   Artifact 表、timeline 或 hash 检查器。
5. **状态来自生产 facade。** 未知或缺失事实显示 unavailable / blocker，不用 fixture
   补成成功态。

**不要做的事**：不要恢复 `Preset / 自定义 tag` 切换、TagPicker、Debug 参数快照、
before → desired diff、`应用参数并开始抓取(…)`、raw / filtered Artifact 卡、两列 dashboard、
假百分比或页面内嵌 timeline；不要在内容区重复 `Trace` 主标题；不要发明 tag、参数、
时长档位、文件名或 hash。

---

## 5.5 Debug 工作台

> 当前实现稿，2026-08-27。依据 `DebugWorkspaceView.swift`、已发布 Catalog 与交互定义 §5.7；本节替换原来的四 connector / 批量 / 独立重启概念 brief。

用 ArkDeck 组件画 **Debug 工作台**。必须分别画五个标签和各自不可用、输入未完成、已准备、运行、失败状态；演示数据持续标明，不得将原型当作设备证据。

**外壳**：设备区 + 八项导航 Overview / Flash / Debug / Viewer / Trace / Device / Diagnostics / History，Debug 选中。Settings 属独立窗口，Automation 已退役。内容区为显式 target/binding → 五标签 → 当前面板；RecoveryBanner 仅有真实待处理投影时显示，全局 JobInspector 当前只读。页面不使用 Harness StatusStrip。

五个 tab 固定为 Artifacts / Logs / Apps / Network / Commands；中文标签依 `DebugLocalizable.xcstrings`。默认 Artifacts，左右方向键与 Home/End 切换，焦点留在 tab。示意 target 必须标为 demo，不能把 sidebar 最近点过的设备隐式作为 scope。

### Artifacts：单个 app-owned `.so`

按顺序画：

1. **来源**：本地文件或已验证 SSH 来源，两种选择。选择单个 `.so`，显示来源、文件名及大小；未选时按钮不假装有输入。不画 SMB/WSL、`.abc` 或 checkbox 多选。
2. **SSH browser sheet**：已登记来源、当前 root/relative path、返回上级/刷新、目录与文件、选择/取消；loading/empty/refused 均有状态。不能越 verified root。来源新增/编辑在 Settings → Servers，不在此处拼一个四 connector 管理器。
3. **身份**：bundle、逻辑库名和必要的 typed 字段，字段旁给格式错误。来源 path 与设备 path 分开；用户不能输入任意设备路径。
4. **预览**：`检查并预览替换`，只有文件/身份/target/availability 可用才启用。展示 host validation、hash、ABI/ELF/Build ID/code-sign 和缺失原因；不把预检画成设备执行成功。
5. **计划 sheet**：精确 target/binding、单库、effect、backup → atomic publish → readback → restartAbility/postflight 与 rollback 语义。确认动作清楚说明单库替换；取消返回原输入。
6. **结果**：submitting/active/terminal/refused/unknown 分开，阶段和进度来自 Runtime；只有完整结果支持时才显示成功。保留到 Logs 的入口。改变 scope 或输入使旧 preparation 失效。

兼容性验证阻止错误产物进入设备，备份用于失败恢复，二者不能互相替代。`restartAbility` 在同一 typed plan 内，当前稿**不画独立“重启设备…”及其成功页**。unknown intent 永不重放，也不能用 toast 文本当恢复证明。

### Logs：bounded 采集与本地视口

控制区包含 target、availability、1–600 秒、Info/Warn/Error、domain/tag/PID/keyword/marker。raw shard 必保存，不画可关闭的假选项。typed request 默认折叠，仍可检查精确字段。

- 开始需 available + target + valid inputs；采集中显示 Job 和 typed cancel，不称无限持续流。
- 暂停仅暂停 viewport；未采集时禁用。筛选、host shard/预算、导出与 Runtime 状态分开，切标签不取消 Job。
- 清空本地显示与设备 buffer 分开；设备 buffer operation 未发布，危险入口禁用并带原因，不画可确认的执行 sheet。
- 显式导出使用系统保存面板并呈现 privacy/hash。示意日志不得写成真实设备观测。

### Apps：已发布 HAP workflow

此页已接 `debug.hap@1`，不能固定写 `providerLoweringMissing`。布局为左侧 HAP/身份，右侧生命周期/计划，下方包库存与 Artifact/近期 Job。

- 单 HAP 文件选择；bundle 与 Ability 有可见标签和 typed 校验。
- 安装策略当前固定 `installOrReplace`；清理策略仅 `uninstall / retain`；结束状态 `stopped / running`；diagnostics 可选，1–300 秒。全新安装与恢复之前版本未发布，不提供可选项。
- 输入摘要放在折叠 request 内；计划必须使用 `Catalog/operations/debug.hap.v1.json` 的完整 14 个 step ID/kind/effect，不另造六阶段流程。
- missing file/identity、unavailable、submitting/active/cancel/terminal/failed 各有呈现；运行按钮由实际条件决定。HTML demo 的提交只展示参数，明确不会导入文件、创建 Job 或操作设备。
- 包库存的独立启动/停止/卸载仍禁用：它们不是已发布 HAP workflow 的别名。不要把这些行按钮画成已实现。

### Network 与 Commands

**Network**：forward/reverse、两端 1024–65535 十进制端口、创建/移除；展示 typed Job、失败与 exact inverse/readback 补偿结果。无任意 shell 输入。

**Commands**：只读模板选择、各自 typed 输入、lowered argv 只读 disclosure、Runtime 结果和 raw Artifact；空态、输入错误、不可用和失败都可读。不能提供 Root、自由命令或 PTY。

### 共同行为与仍未实现的边界

- 操作可用性由 exact target/binding 的 Runtime facts 决定，SSH 成功只证明来源可读。
- 密码、私钥和口令仅存 Keychain，不进入列表、Job、日志、导出或演示截图。
- modal 支持焦点限制、Escape 与焦点返回；状态使用稳定 polite live region，日志不逐行播报。
- **未来设计输入**：SMB/WSL、多 root/批量搜索和替换、`.abc`、独立设备重启、设备 buffer 清除。另页标明“未实现”，不混入当前导航或演示成功态；安全需求仍保留。

---

## 5.6 Flash

> 贴进 claude.ai/design 项目的新对话。

用 ArkDeck 组件画 **Flash** 页。三个模式各画一张(Execute / Plan only / Simulated),外加一张「正在写入分区」的执行中状态。以当前 DAYU200 / `flash.dayu200` 产品事实为准。

**当前权威 brief（旧原型 literals 全部失效）**:

- 顺序固定为 Availability → Rockchip device access → Profile & Image Set → Prerequisites → Exact Plan → Review & Run。所有 target、build、partition、size、hash、toolchain 与 plan digest 都直接绑定 App facade 的生产 presentation；不得硬编码 rk3568、flashd 或示例 serial。
- Execute 的 Exact Plan 与 data impact 完整展示后，只有一个 danger 主按钮 `擦除用户数据并刷机`。不打开确认 sheet，不画 checkbox，不要求输入短语。按钮说明须明确它只是 UX acknowledgement；Runtime capability 与 fresh facts 仍是唯一准入。
- 提交期间每 750ms 读取 `job.list`，用 indeterminate progress + 真实 timeline 展示状态；不画百分比或 ETA。timeline 尾部进入 `criticalNonInterruptible` step 时，页面与 Job Inspector 同时显示完全一致的临界写入 callout。
- Rockchip 访问卡必须区分 permission denied、driver unavailable、offline/unauthorized、tool blocked 与 protocol blocked，并显示责任方、ArkDeck 外最小修复动作和普通 `重新检查设备访问` 按钮。不得画 sudo、驱动安装或全局权限放宽入口。
- 若只读状态确认唯一 DAYU200 精确匹配所选 target、但尚未成为 active binding，在 Rockchip 访问卡内追加 warn callout；HDC-normal 显示 `所选 DAYU200 需要切换为当前绑定`，Loader 显示 `DAYU200 已进入 Loader 模式`。不增加第二个绑定按钮。用户仍只点击一次 `擦除用户数据并刷机`，同一次提交先闭合当前目标身份、按返回 revision 重新生成精确计划，并仅在全部 required prerequisite 满足后继续。绑定成功后 Loader 状态变为 ok `Loader 已绑定到所选设备`。不画 serial/topology，不打开 sheet，不要求 checkbox 或输入短语。
- 此处 bootloader 只表示 `0x2207:0x350a` RockUSB Loader；HDC fastboot `-bootloader`、其他 USB mode 或只有命令 exit 0 都不能点亮 Loader/prerequisite。Provider 从 HDC-normal 固定进入 `loader`，必须取得 IOKit identity 与 identity-bound `arkforged discoverDevices` 一致的双源 exact Loader 回读，随后在同一 Job 内继续刷写，不再要求用户点击第二次。
- 这次执行前身份关联不是 Runtime authority，也不是执行中 rebind confirm。Runtime 必须 fresh-read 唯一注册 DAYU200。切换另一台已采用设备时只接受 revision-1 target，且 fresh identity 必须同时精确匹配 target stable identity 与 connect key；以独立 CAS 切换 active binding，不伪造 revision 前进。同一设备的新跨模式身份仍只通过 CAS 持久化为相邻 binding；不完整或历史同身份 binding 不得就地升级或提供刷机准入。对唯一未落 outcome 的 enter-Loader intent 只做同 revision 或一个相邻 revision 的零重放结算；ambiguous / stale / 显式 outcomeUnknown / destructive intent 或重新 materialize 后仍有 blocker 时一律不提交 Flash。
- 成功后只画两个已有生产字段的 Postflight 对照：`observation.firmware` 对 profile `runtimeBuildVersion`；提交时已经 materialize 的 binding revision 对 `observation.bindingRevision`，成功关系为 `n→n`。执行前 Loader 激活若产生相邻 revision，App 会先用新 revision 重新生成精确计划；Flash Job 内经 topology + build 证明的新 HDC alias 仍关联到该计划固定的 target/revision。manifest 全 executed + SHA 尚无字段，不画占位行。
- USB rebind 在稳定身份、相邻 binding revision 与 updater/plan 阶段证据完整时自动继续，任何缺失或漂移都 fail closed；TCP / UART 断连才进入人工 rebind confirmation。不要把有 durable proof 的 USB 恢复写成“静默续刷”。
- 当前 Catalog 只发布 USB / RockUSB 的 `flash.dayu200`，所以执行中的 Job 不画 rebind confirm / abort 控件；Loader target 绑定只出现在执行前的 Rockchip 访问卡。未来 TCP / UART Flash 必须先有 domain 状态与 RPC，设计不能先行伪造。
- Plan only / Simulated badge 永久保留；Execute 没有 badge。所有状态以 symbol + 文案表达，不只靠颜色；长 hash 中间省略但完整值可选择/查看；900×600 和 VoiceOver 阅读顺序必须保留主按钮前的风险信息。

**当前生产事实与刻意边界**:

- Prerequisites 来自 target / binding / profile-bound `flash.prerequisites`，闭集为 `loader` / `recoveryPath` / `unlocked` / `stablePower`；没有 `flashd`。
- `recoveryPath` 只有在 owner-only DAYU200 binding 精确覆盖当前 target identity、revision 与适用 HDC alias 时才是 satisfied。HDC adoption 本身不构成证明；但所选 revision-1 target 与 fresh 唯一 HDC USB identity/stable identity/connect key 全量精确匹配时，同一次主按钮动作可先完成 active-binding CAS，再重新读取 prerequisites。required 项仍为 unknown / unsatisfied 时保留 Exact Plan 审阅并禁用提交，Runtime 使用同一事实在 capability 签发与首个外部 effect 前双重拒绝。
- Trace tag、参数 before / after、Debug 日志 / 包清单 / 端口规则和 Overview 能力矩阵均接生产 facade。缺失或不匹配时显示 unavailable / unknown，不用 fixture 补洞。
- Flash `job.cancel` 已开放，临界写入只停止后续步骤；Artifact 在 History 中逐项导出；Automation 只开放既有 task 的 list / reconcile / pause / cancel。
- HDC production authorization 由 domain-owned durable binding 刷新；App 可展示真实 `.timedOut`，但生产 probe 尚不能推导的 `denied` 不得从 fixture 搬过来。
- Flash Postflight 仍只有 build 对照与 binding revision 两行；manifest 全 executed + SHA 无 wire 字段，继续不画。

<details>
<summary>已废止的 rk3568 / flashd 原型参考（仅供追溯，不得用于新设计或实现）</summary>

**布局** — `WindowFrame`,标题 `ArkDeck — OpenHarmony 设备工作台`。
左栏:`DeviceRow` × 2(rk3568-dev / unknown-tablet)+ `NavItem` × 8(Flash 为当前页)。
内容区自上而下:`RecoveryBanner` → 页标题 `Flash` + 紧随其后的模式 badge → `SegmentedControl`(Execute / Plan only / Simulated,label「执行模式」)→ 两列区域。
左列自上而下三张 `Card`:`Profile / Image Set — rk3568-5.0-full` → `Prerequisites` → (执行成功后才出现)`上次执行 · Postflight`。
右列一张 `Card`:`Exact Plan`,表下面就是 Review & Run 区。
底部 `JobInspector` 折叠态常驻;执行中展开态要一起画。

规格把模式段控放在 toolbar、并要求详情第一节是 **Availability(`AVAILABLE` / `UNAVAILABLE(reasonCode)`)**。原型两点都没有:段控在内容区顶部一张卡里,且 Flash 页没有任何 Availability 文案或 reasonCode 串。按规格的顺序排版,但 Availability 那一节留空槽并标注「原型未提供文案」,不要编 reasonCode。

**内容** — 逐字使用,不要改写、不要翻译、不要补充:

模式 badge(紧跟页标题):
- Execute → **没有 badge**
- Plan only → `Chip` tone `planned` icon `◇`:`PLANNED — 不派发 deviceMutation/destructive`
- Simulated → `Chip` tone `simulated` icon `▤`:`SIMULATED · fixture-a3 — 不接触真实设备`

卡片「Profile / Image Set — rk3568-5.0-full」,`DataTable`,列 = 分区 / 镜像 / 大小 / SHA-256(全 mono):
- `boot` · `boot.img` · `64MB` · `c9d2…41aa ✓`
- `system` · `system.img` · `2.1GB` · `8b07…9e35 ✓`
卡尾 hint:`镜像原地引用,不复制进 Session;GB 级流式 hash。`

卡片「Prerequisites」,无表头的三列表(名称 / 状态 / 补充):
- `root-capable build` · ok `Chip` `satisfied`
- `进入 updater` · ok `Chip` `satisfied`
- `flashd 能力` · 默认 warn `Chip` `unknown`,第三列一个勾选框,标签 `演示:已在升级模式实测确认`;勾上后状态变 ok `satisfied`,勾选框消失
- `稳定供电` · ok `Chip` `satisfied`

卡片「Exact Plan」,`DataTable`,列 = `#` / `step` / `参数摘要` / `effect` / (最后一列无表头):
| 1 | enterUpdater | — | `EffectBadge` deviceMutation |
| 2 | flashPartition | boot · boot.img · 64MB | `EffectBadge` destructive |
| 3 | flashPartition | system · system.img · 2.1GB | `EffectBadge` destructive |
| 4 | reboot + waitReconnect | binding revision + 强证据 | `EffectBadge` deviceMutation |
| 5 | postflight verify | 版本/设备校验 | `EffectBadge` readOnly |
Plan only 模式下,**每一行**最后一列都是 `Chip` tone `planned`:`notExecuted(planned)`;其余模式该列为空。

Review & Run 区,按模式三态:
- Execute:`Button` variant `danger`:`刷写 rk3568-dev(2 个分区)…`。flashd 仍为 unknown 时按钮 disabled,`title` = `required prerequisite flashd 为 unknown,临界步骤前阻断`,并且**旁边一句可见的阻断说明**:`⚠ flashd unknown → 执行分支被阻断(不能刷到一半才发现)`
- Plan only:`Button` primary `生成完整计划(零设备写入)`;生成后追加 `Button` `查看 plan artifact` + `Chip` planned `◇ planned · 已持久化`
- Simulated:`Button` primary `运行模拟场景(断连注入)`。只有模拟 **TCP / UART** transport 时才进入 `WaitReconnect → Rebind 确认`；模拟 USB 时，在稳定身份、相邻 binding revision 与 updater/plan 阶段证据完整匹配后自动 rebind，证据不足则 fail closed。(原型里的 AC 编号是评审叠层，不进产品——本页任何地方都不要画 REQ/AC chip。)

执行中(Execute 且任务在跑),Exact Plan 卡片内 `Callout` tone `danger`:
`正在写入分区 —— 临界区不可中断:取消只会停止后续步骤。请勿合盖、手动睡眠、断电或拔线(idle sleep 已由系统保持,但合盖无法被阻止)。`
(⚠ 由 `Callout` 自己画,文案里别再打一个。)

Execute 不打开 `DangerConfirmDialog`，也不要求 checkbox 或文字短语。Exact Plan、目标、镜像、分区、userdata 影响、供电提示和 bootloader / 厂商恢复路径在 Review & Run 中完整可见；随后只有一个 danger 主按钮 `擦除用户数据并刷机`。点击即提交 typed request，但该点击只是 UX acknowledgement，Runtime capability 与 fresh facts 仍是唯一准入。

`JobInspector` 里的 Execute 任务:标题 `Flash · rk3568-5.0-full · rk3568-dev`,`PhaseTrack` 九阶段 `Preflight` `EnterUpdater` `Re-identify` `flash boot` `flash system` `Verify` `Reboot` `Postflight` `Complete`,当前停在 `flash system`。日志尾部:
```
→ Preflight
已获取 CriticalActivityLease(idle sleep 保持)
→ EnterUpdater
→ Re-identify
→ flash boot
→ flash system
用户请求取消(策略:atSafeBoundary)
— 已请求取消:等待安全边界 —
```
取消按钮文案 `取消(在安全边界)`;已请求取消后变 `等待安全边界…` 并 disabled。任务上的 criticalNote 与页面内那句一字不差。完成文案 `完成:postflight 校验通过,设备回报 build 与镜像期望一致。`

Plan only 任务:标题 `Flash(plan-only)· rk3568-5.0-full`,阶段 `Preflight` `Validate` `makePlan` `Persist plan`(全部走完),日志只有一行:`完整计划含 2 个 destructive 步骤,全部 notExecuted(planned);mutation dispatch = 0。`
`查看 plan artifact` 开普通 sheet,标题 `plan artifact — rk3568-5.0-full` + `Chip` planned `◇ PLANNED`,正文是只读 JSON:
```
{
  "schema": "flash-plan/1.0",
  "profile": "rk3568-5.0-full",
  "device": {"serial": "150100469…", "bindingRevision": 3},
  "steps": [
    {"n":1,"step":"enterUpdater","effect":"deviceMutation","status":"notExecuted(planned)"},
    {"n":2,"step":"flashPartition","target":"boot","sha256":"c9d2…41aa",
     "effect":"destructive","status":"notExecuted(planned)"},
    {"n":3,"step":"flashPartition","target":"system","sha256":"8b07…9e35",
     "effect":"destructive","status":"notExecuted(planned)"},
    {"n":4,"step":"reboot+waitReconnect","effect":"deviceMutation","status":"notExecuted(planned)"},
    {"n":5,"step":"postflightVerify","effect":"readOnly","status":"notExecuted(planned)"}
  ],
  "mutationDispatch": 0
}
```
sheet 尾注:`plan artifact 已持久化到 Session;PLANNED 标识在历史与导出中永久保留。`

Simulated 任务:标题 `Flash(simulated)· fixture-a3 TCP 断连注入`,设备 `SIM-fixture-a3`,阶段 `Preflight` `EnterUpdater` `flash boot` `注入断连` `WaitReconnect` `Rebind 确认` `reconcile` `Complete`,停在 `Rebind 确认`。日志首行 `→ Preflight(合成设备,无真实 connectKey)`,停下时追加 `检测到 TCP 断连后回连:等待用户 rebind 确认。`USB fixture 不复用这条人工确认路径：完整证据允许自动 rebind，缺失或漂移直接阻断。
rebind 区块(在 Job inspector 里,不是弹窗):粗体 `设备回连,需确认后继续`,mono 证据行 `同一 serial · binding revision 3→4 · updater 阶段与 plan 一致`,两个按钮 primary `确认同一设备,继续` / `中止`。确认后日志 `用户确认 rebind:同一 serial · binding revision 3→4;继续执行。`;中止后任务终态为已取消,日志 `用户中止 rebind:剩余步骤不执行;该结论写入审计。`。完成文案 `完成:reconcile 与注入脚本一致;SIMULATED 标识永久保留。`

卡片「上次执行 · Postflight」(仅执行成功后),`KeyValueList`，只画 Runtime 当前已投影的两行:
| 设备回报 build | OpenHarmony 5.0.0.96 + ok `Chip` `= 镜像期望 ✓` |
| 设备身份 | 同一 serial · binding revision 3→4 |

**必须画出的语义** — 这几条是本页的存在理由,画错就等于画反:

1. **模式 badge 永不脱落。** 段控是模式的来源,badge 紧跟标题;PLANNED / SIMULATED 还要出现在 `JobInspector` 的任务行、History 行与导出包里。Execute **没有** badge——「没有徽章」本身就是「这是真的」的表达,不要为了对称给它补一个 `EXECUTE` chip。
2. **详情顺序是 Availability → Profile & Image Set → Prerequisites → Exact Plan → Review & Run。** 先说这台设备能不能做,再说做什么、再说凭什么能做、再说具体做几步、最后才是那颗按钮。Availability 这一节原型没有文案,留空槽并注明,不要拿 Prerequisites 顶替。
3. **unknown 的前置条件要画成「带理由的阻断」,不是一个灰按钮。** `flashd 能力` 是 unknown 时,`⚠ flashd unknown → 执行分支被阻断(不能刷到一半才发现)` 这句必须**可见**——它不能只藏在 disabled 按钮的 hover title 里。unknown 用 warn,不用 danger:ArkDeck 不知道,和 ArkDeck 知道它不行,是两件事。
4. **Exact Plan 的 effect 列和 disposition 列是这张表存在的理由。** 五步各自的 effect 分级(deviceMutation / destructive / readOnly)用 `EffectBadge` 画满;Plan only 下每行都要有 `notExecuted(planned)`,配合 `mutationDispatch: 0`——plan-only 不是「按钮变灰的 Execute」,它是一次真的、有产物的、零写入的运行。
5. **临界写入期间,页面和 Job inspector 说同一句话。** 措辞是「取消只会停止后续步骤」,不是「无法取消」:当前写入不会被强杀,后续步骤会停。电源提示要保留那句诚实的括号——`idle sleep 已由系统保持,但合盖无法被阻止`。这一刻取消按钮变 `等待安全边界…` 并禁用。
6. **断连按 transport 分流,摆证据不摆结论。** TCP / UART rebind 区块给可核对的原始比对，并保留继续 / 中止两个明确选择。USB 在稳定身份、相邻 revision、updater/plan 阶段证据完整时按 Core 自动 rebind；缺证据或漂移时零新 dispatch。不要把有 durable proof 的 USB 自动恢复描述成“静默续刷”。
7. **Postflight 是「设备回报 build = 镜像期望」的对照,不是「成功」两个字。** 当前只画 build 对照与提交后保持固定的 binding `n→n`；执行前 Loader 激活产生的相邻 revision 已包含在最终提交的精确计划中。manifest 全 executed + SHA 尚无生产字段，不画占位行。

**不要做的事**:不要画百分比进度条或 ETA(设备不报可信字节总量,用 `PhaseTrack` + `IndeterminateBar`);不要发明分区名、镜像名、大小、hash、serial、build 串或 fixture id;不要把 SIMULATED 缩成角落里的小灰字;不要给 Flash 添加确认 sheet、勾选框或文字短语;不要给 chip 配 emoji。

</details>

---

## 5.7 History

当前交付参考（2026-08-28，F38）。以 `RuntimeHistoryView.swift` 和
`RuntimeHistoryApplicationFacade.swift` 为准；下列要求替换旧 Session 表、固定 manifest、
按类型生成文件和“取消即恢复”的历史稿。

**外壳与选择**：八页导航；History 内为活动类型、记录、详情三栏，窄窗折叠筛选但保留选择关系。
All / Flash / Debug / Viewer / Trace / Diagnostics / Device / Other 都要覆盖。
类别来自明确的 workspace/operation 投影，不从标题猜；未知记录保留 Other。
记录按已报告 finished / started / created 时间倒序，缺失日期不从展示文案推断。
选择只能属于当前过滤结果；跨工作区的 exact Job 入口清除旧筛选并定位对应记录。

**筛选**：搜索匹配 Job、Session、operation、target、state、executionMode。
状态含 all / active / needsAttention / succeeded / failed / interrupted / cancelled；
模式含 execute / planned / simulated / unknown；Session 与 target 用精确 ID，不把 Job ID
或设备显示名称当成身份。时间含过去一小时、一天、一周，未报告时间不匹配时间区间。
保存、恢复、删除筛选，以及需要关注、最近失败和清除筛选都可达；原型保存只在页面内存中演示。

**详情**：Summary / Timeline / Correlation / Evidence / Parameters / Artifacts / Recovery linkage
按 Runtime 提供的字段展示。operation、state、outcome certainty、actual effect、target、
binding、Journal 条目、manifest、hash 和副作用证据均不能由类型或状态补造。
未报告的旧记录明确显示缺失；没有 Journal 或 Artifact 清单不补默认步骤和文件。

**参数**：所有类型都支持精确 typed inputs，不局限于 Trace / Viewer。
未报告与明确空参数分开；只有显式 traceParameters 才画 before / after，逐项保留
value / missing / unreadable / unknown 和 unchanged / changed / unverified。
相等的读回值只能说明 unchanged，不能推导补偿已经执行。cancelled 不代表参数已恢复；
failed / interrupted 与 outcomeUnknown 是不同维度。

**Artifact**：逐项显示 name / role / origin / size / SHA-256 / privacy / status，来源是对应 Job
的实际清单。设计样本仅采用已发布 descriptor，未提供的大小/哈希保持未报告：
Viewer 可有 ui-dump.json / ui-tree.json / screenshot.png；Trace 可有 trace.htrace / capture.log；
Diagnostics 可有 hilog.txt / markers.json / artifact-index.json / capture-summary.json；
Native 可有 publish-report.json / verification-report.json；canonical Flash 可有
post-flash-facts.json / post-flash-hilog.txt / flash-report.json。
这些是有条件的清单示例，不是按类型自动生成的文件集合。

每个 published Artifact 单独提供导出，missing / invalid 禁用；预览必须是点击的那一项，
展示文件名、size、privacy、SHA-256。sensitive 明示敏感导出，standard 不冒充敏感文件。
取消不读取；确认后选择位置，App 分块读取并复算 byteCount / SHA-256，再写入本地。
只有成功后才提供 Finder 定位。原型演示不创建文件，不是导出或设备证据。
全局 Inspector 的标准日志入口只能来自实际 published log 行，不能推断 capture.log / flash.log。

**结果与恢复**：unknown 保留独立标识。未解决的 unknown / waitingForHuman 或残留项进入
“需要关注”；有 Runtime 恢复关系的旧 unknown 保持原结果，但不因旧 unknown 本身继续报警。
没有证明的补偿不画完成；恢复关系只表达当前 target epoch 已建立，不重写原 Job 为成功。
工作区/Diagnostics 入口只读回访，不重放、取消、重绑或重试 operation。
planned / simulated 标识保留，不因导出生成新的 Session mode 声明。

至少画：中英文当前记录及 typed inputs、缺失事实的旧取消记录、标准与敏感逐项导出、
未解决与已关联恢复的 unknown、空筛选、精确 Session/target 筛选、窄栏长参数/文件名。

---

## 5.8 Settings

> 历史细节：当前实现以本文顶部 v1.6 索引与对应交互定义为准；不得把下文旧入口视作已发布能力。

> 贴进 claude.ai/design 项目的新对话。

用 ArkDeck 组件画 **Settings** 页。

**布局** — Settings 是系统 `Settings` scene,不是主窗口的一页:画成一个比主窗口窄的独立 `WindowFrame`,标题 `ArkDeck — Settings`,没有 sidebar、没有设备列表、没有底部 Job inspector。内容区不再重复超大标题(页面标题已在 window chrome 上)。主窗口通往它的入口是 toolbar 上一枚 icon-only `ToolbarButton`(`Symbol name="settings"`,aria-label `打开设置`),那枚按钮属于主窗口,不画进这一稿。
内容区是两列 `Card` 网格,四张卡依次是 HDC 工具 / 输出与保留 / 诊断 / 更新,分别对应 spec 的 Toolchains / Storage / Diagnostics / Updates 四个 pane。spec 还列了一个 General pane,原型没有任何 General 内容——不要替它编设置项,也不要画一排空的 pane 切换器凑数。
「导出诊断包…」打开一个 sheet:`Card` 承载,底部两枚 `Button`。

**内容** — 逐字使用,不要改写、不要翻译、不要补充:

卡片一「HDC 工具」,用 `RadioGroup`(name `hdc`,label `HDC 工具`,当前值 `deveco`):
- `DevEco SDK — …/toolchains/hdc · 3.1.0e`(路径与版本 mono)
- `手动选择 — /usr/local/bin/hdc · 3.0.0b`(mono),description = `(SHA-256 已计算 · 能力需重新探测)`

卡内 `Callout tone="warn"` + `Symbol name="warning" small`:
`有任务正在运行:切换不影响运行中的 Job——工具在 Job 创建时固化,仅新任务使用新选择。`
(没有运行中任务时,同一位置退成一行灰字:`切换不影响运行中的 Job:工具在 Job 创建时固化。` 本稿画有任务在跑的那一态。)

卡片二「输出与保留」,`KeyValueList`:
| 输出根目录 | ~/Library/Application Support/ArkDeck |
| 历史配额 | 20GB · 保留 90 天 · pinned 除外 |
| 当前占用 | 6.4GB · 42 个 Session · 3 pinned |

卡片三「诊断」:
正文 `诊断包由你主动导出,默认不含设备 raw 产物,导出前可预览勾选;无自动上传。`(「不含」加粗)
按钮 `导出诊断包…`

卡片四「更新」:
- 勾选框(已勾)`自动检查已签名更新`
- 灰字 `只获取签名 feed；下载后先校验身份与完整性，明确同意后才在 Finder 中显示安装包。`
- `Chip tone="ok"` `✓ 当前已是最新版本` + `Button` `立即检查`(按下后原地变成禁用的 `已检查 · 当前版本`)

诊断包 sheet:
标题 `导出诊断包`
灰字 `逐项勾选导出内容;默认不含设备 raw 产物。该包只保存到本机,无自动上传。`
四个勾选项:
- ☑ `ArkDeck 应用日志(近 7 天)`
- ☑ `工具链探测记录(hdc 版本/hash/endpoint)`
- ☑ `设备清单(connectKey 已脱敏)`
- ☐ `设备 raw 产物(默认不含,可能包含敏感内容)`
底部:`取消` + primary `导出诊断包`

**必须画出的语义** — 这几条是本页的存在理由,画错就等于画反:

1. **工具链切换只影响新 Job。** RadioGroup 旁那句不是提示语,是这一页的主要事实:正在跑的 Job 用的是它创建时固化的那个二进制,切换不追溯、不重启、不影响它。所以这张卡里不能出现「应用并重启」「立即生效」这类按钮——选中即选择,生效点在下一个 Job。有任务在跑时这句话升级成 warn `Callout`,因为此刻它才真的会被误读。
2. **手动选择那一项的代价写在选项里。** `SHA-256 已计算 · 能力需重新探测` 属于 description,不进 tooltip、不移到卡片尾注:读者正在做选择,代价就该在这一行。「已计算」与「需重新探测」是两件事,不要合并成一句「已验证」。
3. **Storage 的五项事实(root / quota / retention / pinned / 当前使用量)必须都在,但只有三行。** 配额行同时带 retention 与 pinned 例外,占用行同时带 Session 数与 pinned 数。照三行画,不要为了对齐 spec 的五个词拆成五行、再给空出来的行编数值。
4. **诊断包三件事同框:默认不含设备 raw、逐项可预览勾选、无自动上传。** 三条缺一不可,而且各说各的:「默认不含」不是「不能含」,所以设备 raw 那一项存在且可勾,只是默认不勾并带自己的风险说明;「可预览勾选」意味着清单在导出前完整摊开,不是导完再看;「无自动上传」是这一页唯一提到网络的地方,它说的是「没有」。
5. **更新走的是已实现的签名流程,顺序不能省。** 只取签名 feed → 先校验身份与完整性 → 明确同意后才在 Finder 中显示安装包。自动的只有「检查」这一步;不要画一键安装、静默安装或自动安装开关。

**不要做的事**:不要把 Settings 画成 sidebar 的第八个 `NavItem`(原型把它内嵌进主窗口只是原型便利,入口按钮的 title 自己写着「设置(原型中内嵌展示)」);不要用 `DangerConfirmDialog` 做诊断导出 sheet——导出是 hostOnly 动作,套危险确认等于把它误分类成不可逆的设备操作(组件表里没有 checkbox,勾选项用原生 `<input type="checkbox">` + label 画);不要画 AC 标注 chip(`AC-DIAG-002-01` 只在原型评审模式里叠加,不进产品);不要发明路径、配额数字或版本号。

---

## 5.9 Automation（已退役）

CHG-2026-064 已删除 App Automation、daemon task.* 与 CLI task 命令族。
旧设计不再作为候选方案或待办；不要根据此 brief 重建 Harness 决策平面。
历史内容可从 Git 追溯；当前原型 `page=automation` 只提供退役说明。

## 补充：独立 Device 与 Diagnostics

Device 使用 `device-control-design.md` 和 v1.6 当前原型；覆盖 empty/captured/stale/unknown/
inputFailed、frameCount preflight、quota/refused、capturing/assembling/validating/ready/failed。
Diagnostics 使用 `diagnostic-mode-design.md`：当前页面禁用 arm/mark，未来 recorder/reader 目标
必须单独标注。两个工作区不共享状态或静默启动对方的 channel。

## 补充：独立窗口、Settings 与全局层

Trace Viewer、Trace Keyboard Shortcuts 与 Settings 都是独立 scene；七个 Settings 标签和
Cache/Licenses 都要评审。详见本文顶部全入口表和全页覆盖清单。
Job Inspector 当前只读；恢复 banner 只去 History；这些 UI 缺口不能推断为 Runtime 缺失。
