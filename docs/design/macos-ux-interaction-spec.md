# ArkDeck macOS UX 与交互定义

> Status：draft v0.3（design input，非 normative；2026-08-05 按当前 `main` 代码与 Catalog 对齐）
> 交互原型：`docs/design/prototype.html`（可点击，与本文档同版本演进）
> 行为事实源：`openspec/specs/desktop-ux-observability/spec.md`、各 capability spec、Catalog 与 Runtime contracts；本文档只定义 HOW（布局、组件、层级与流转），行为冲突时以事实源为准
> Promotion：本目录是草稿区。被采纳的版本在起草 M2+ 功能 change 前移入 `openspec/platforms/macos/design/`，并由 change 的 `design.md` hash-pin。设计中发现的行为级缺口必须走 behavior delta，不能只画进稿子。

## 0. v0.3 目标与当前实现边界

v0.3 不新增 Runtime 能力，目标是把已有的 typed operation、设备状态、Job、Artifact、Recovery 和 bounded AI loop 组织成现代 macOS 工具界面：原生窗口层级、可调整的 split view、系统工具栏、适合长时间工作的紧凑密度，以及不依赖颜色的安全状态。

当前代码与目标设计的边界必须如实呈现：

| Surface | 当前 `main` | v0.3 设计目标 |
| --- | --- | --- |
| App shell | SwiftUI `WindowGroup` + `NavigationSplitView`；已有 Overview / Flash / Debug / UI Dump / Trace / History 导航词汇 | 保留原生 split view；补齐统一 toolbar、设备 scope、全局 Job inspector 与窗口自适应 |
| Overview | `HDCStatusView` 已展示 path/source/hash/trust/client/server/daemon/endpoint/health/ownership/authorization/channel protection，并有显式 refresh、HDC 选择和 recovery preview/confirm/dispatch | 重新分组为「服务器」「设备与通道」「能力」「需处理事项」，不把诊断字段堆成单张表 |
| Settings | 已有独立 macOS `Settings` scene，但当前 AppShell detail 同时内嵌 `AutoUpdateSettingsView`；自动更新检查、下载、校验和 Finder handoff 已接通 | App 主窗口不再内嵌完整更新设置；toolbar 只显示需要注意的更新状态，详细设置回系统 Settings scene |
| Runtime capability | Catalog 已发布 observe / diagnostics / HAP / native library / Flash / analyzer / workspace typed operations；Harness 已有 lifecycle、stage、conditions、Attempt、budgets 与 HumanActionRequired | UI 只提交 operation reference + typed inputs；展示 availability、effect、预算和实际 lowering 的只读回显，绝不提供 raw command 输入 |
| 其余功能页 | 导航存在，但主窗口尚未有对应 production view；原型是目标稿，不得标为当前已实现 | 按本文档逐页落地；未接 production provider 时显示 `UNAVAILABLE + reasonCode`，不能使用演示结果冒充真实能力 |

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

基础尺寸：toolbar 52；sidebar 232–300（用户可拖动）；导航 row 32；常规 control 28–32；section 内 gap 8–10，section 间 gap 20–24；内容边距 20–24；container radius 10，内部 control radius 6–8，遵守同心圆角。桌面最小 target 24×24，空间允许时使用 32–40；任何扩展 hit area 不得重叠。

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

- 参考窗口 1180×760；最小 900×600。宽度不足 980 时先把双栏内容改为单栏；不足 760 时 sidebar 可自动收起，但必须保留 toolbar toggle 和 View menu 命令。
- Sidebar 只保留两级以内层级，不在底部放关键动作。设备与工作流分组；Settings 使用系统 `Settings` scene，不作为 sidebar 最后一项伪装成普通页面。
- 页面标题在 toolbar，内容区不重复超大标题。需要解释的页面用紧凑 title + subtitle；滚动后 toolbar 仍提供上下文。
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

- 使用 macOS sheet，而非居中网页 modal。标题 = 动词 + 对象；正文固定展示设备 identity / binding、effect、不可逆内容、recovery path。
- erase / format / destructive 至少两项逐项确认；主按钮是完整动作，例如「刷写 rk3568-dev 的 2 个分区」，不用「确定」。
- 默认焦点在取消；`Esc` 关闭；Tab 不离开 sheet；关闭后焦点回触发按钮。

### 4.4 Availability、effect 与状态

- 页面先展示 Runtime 返回的 `AVAILABLE` / `UNAVAILABLE(reasonCode)`，再允许配置；Provider、Target facts、plan lowering 不完整时不展示可执行主按钮。
- effect 统一为 symbol + 文案：`hostOnly`、`readOnly`、`deviceMutation`、`destructive`。状态色只辅助，不作为唯一判断。
- execute 无 badge；plan-only = 紫色 outline「PLANNED」；simulated = 橙色 dashed outline「SIMULATED · fixture id」。

## 5. 页面定义

### 5.1 Overview（REQ-UX-002）

- Toolbar：设备 scope、`⌘R` 刷新、必要时「选择 HDC…」。刷新中保留原快照并显示小型 progress，不让内容跳空。
- 顶部 status strip：HDC server health、target ready、channel protection、需要处理数量。
- 内容按四个 section 排列：Server & Toolchain；Selected Device & Binding；Capabilities；Needs Attention。path/hash 允许复制，长值用中间省略且可查看完整值。
- recovery preview / exact-generation confirmation / dispatch 保持三步，不合并成一个“修复”按钮；host-wide 影响用 sheet 列出 affected devices / Jobs / other clients。

### 5.2 设备接管与授权（REQ-HDC-007）

- Sidebar 未授权设备行显示 warning symbol +「需要信任」，选中后 detail 显示三步 onboarding：解锁 → 设备端信任 → 有界等待。
- E000002（等待）与 E000003（拒绝/超时）分状态；retry 是普通按钮。重启 shared HDC server 属独立危险 sheet，绝不成为默认修复。

### 5.3 UI Dump

- 使用单一工作流表单：Window inventory → Recipe → Debug parameter policy → Review。当前步骤在 leading edge 对齐，避免四张孤立卡片。
- Recipe 只提供四个 canonical option；componentDetail 才显示 component ID。解析失败时提供 raw read-only view 和校验后的安全手输 ID。
- 结果用 Artifact table：name、role、origin、size、hash、sensitivity；stdout、sidecar、merged 分行，raw 永不被 merged 覆盖。
- 页尾固定 scope note：Fault/Crash 与 system diagnostic snapshot 首版不支持。

### 5.4 Trace

- Toolbar 或 section header 使用 Preset / Custom segmented control；只显示设备已确认 tag，unsupported tag 禁用并解释。
- 参数 snapshot diff 是 table，不用彩色卡片；missing / unreadable 明确「不可自动恢复」。需重启时在执行前显示影响。
- 无可靠总量时显示 indeterminate + elapsed，不伪造百分比。完成后 raw / filtered / capture.log 分列，筛选是派生产物操作。

### 5.5 Debug 工作台

- 四个 tab：Logs / Apps / Network / Commands。Tab 遵循 macOS keyboard pattern；tab 内容改变时焦点不被强制移动。
- Logs：bounded live viewport、等级/tag/filter、host shard 状态；「暂停界面」不停止 host capture。「清空设备 buffer」位于 destructive actions menu，走危险 sheet。
- Apps：HAP import、install/start/stop/uninstall；mutation 与 read-only action 分组，package/PID 使用 tabular numbers。
- Network：typed forward rows，端口字段校验；不接受 shell fragment。
- Commands：只能选择 approved typed template / operation reference 并填写其 schema-defined inputs。Provider 生成的 executable + argv 作为只读 disclosure 展示；没有任意文本命令输入，也不模拟 PTY。

### 5.6 Flash

- Toolbar 中放 Execute / Plan only / Simulated segmented control，模式 badge 紧随标题并永久保留。
- 详情顺序：Availability → Profile & Image Set → Prerequisites → Exact Plan → Review & Run。required prerequisite 为 unknown/unsatisfied 时，Run 区显示 blocker，不只留下灰色按钮。
- Exact Plan table 展示 step、typed parameters 摘要、effect、execution disposition。plan-only 的 mutation/destructive 行显示 `notExecuted(planned)`。
- critical write 期间在 Job Inspector 和页面内同时显示「当前写入不会被强杀；停止只作用于后续步骤」与电源提示。断连进入 rebind confirmation，不静默续刷。

### 5.7 History（REQ-UX-004）

- 三栏：filter/sidebar → Session table → detail inspector。筛选支持 status、executionMode、device、time 和全文搜索；filter 可保存为 toolbar menu。
- interrupted、failed、cancelled 使用不同 symbol + 文案；unknown outcome 额外显示 needsAttention。
- Detail 分组为 Summary / Timeline / Parameters / Artifacts / Recovery linkage。支持 Finder 定位；显式导出前展示敏感数据预览。

### 5.8 Settings

- 使用系统 Settings scene，分为 General / Toolchains / Storage / Updates / Diagnostics。
- Toolchain 切换明确「只影响新 Job」；Storage 展示 root、quota、retention、pinned 与当前使用量；Updates 复用已实现的 signed update flow。
- 诊断包默认不含 device raw，可预览勾选且无自动上传（AC-DIAG-002-01）。

### 5.9 Automation / Bounded AI Debug Loop（code-backed design candidate）

该页面对应当前 Harness 代码的 `HarnessTaskLifecycle`、`HarnessTaskStage`、conditions、Attempt、budgets、allowed operations 与 HumanActionRequired。它是已有 Runtime 能力的呈现候选；进入 production 前仍需 accepted UX delta。

- Sidebar 增加 Automation（Preview），不与 Git `TASK-*` 混淆；运行单元始终显示为 `HTASK-*`。
- Summary strip：goal、target + expected binding revision、lifecycle、current stage、round、elapsed。
- Stage timeline 固定为 initializing → reproducing → collecting → analyzing → patching → building → deploying → verifying；fallback 回 analyzing 用回向箭头，不伪装成新成功阶段。
- Budget panel 展示 consumed / max：rounds、wall clock、Artifact bytes、E1 mutations、model calls，以及 max no-progress rounds / retries。接近上限只警告；耗尽时停止并显示 machine reason。
- Allowed operations 以只读 chips 显示；任何 raw command surface 在提交前拒绝。Attempt detail 展示 strategy fingerprint、base/patch revision、confirmed/disproved facts、ActionRun、evaluation、runtime/build Artifact 与 outcome。
- `humanRequired` 使用 4.2 的 banner；授权缺失、outcomeUnknown、strategy exhausted、evidence integrity、environment unavailable 使用各自准确文案，不自动重试。

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

## 8. v0.3 已决视觉项

- 图标：产品使用 SF Symbols；HTML 原型使用单色 inline SVG 近似，禁止 Emoji 作为最终导航图标。
- 密度：默认紧凑舒适（macOS medium sidebar size）；不额外提供 App 内密度开关，尊重系统设置。
- Job Inspector：默认折叠；有 running / waiting / humanRequired 时显示摘要但不自动抢焦点。
- 外观：跟随系统；不默认强制 dark。
- Accent：跟随用户系统 accent；ArkDeck 不固定 teal 覆盖系统选择。

## 9. 平台设计参考

- [Designing for macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos/)
- [Sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars)
- [Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars)
- [Split views](https://developer.apple.com/design/human-interface-guidelines/split-views)
- [Materials](https://developer.apple.com/design/human-interface-guidelines/materials)
