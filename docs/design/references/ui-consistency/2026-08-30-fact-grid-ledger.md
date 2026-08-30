# UI 一致性台账 · 2026-08-30 批次六（键值列表走共享事实网格，C-DUP 第二批）

> 任务：[UI 稿与实现一致性核对任务](../../ui-consistency-audit-task.md)（TASK-AIN-021）
> 基线：`fb6e5993`（批次五 PR #1590 合入后的 `origin/main`）
> **批次范围**：**组件复用腿**——F52 第 4 条剩下的键值列表部分，即 19 处手写 `Grid(` 里
> 属于事实列表的 14 处（第 15 处 `SettingsValueGrid` 已在批次五收敛）。功能实现腿的
> 62 个 surfaceID **本批只重核受影响的 12 行**，其余 50 行继承批次一～五的结论——
> `fb6e5993` 与批次五基线之间只有本审计自身的 PR #1590。
> 差异登记见[审计记录 F57](../../implementation-audit-2026-08-27.md)。
>
> **验证边界**：本批触碰 App 代码，跑了原生 XCUITest 全套。原生套件在 `main` 上本就是红的
> （F56 已登记两条既有失败），本批只比对失败集合是否扩大，**不声称原生全绿**。
> 无浏览器逐页走查，无设备操作，不构成真机验收。

## 1. 组件复用腿：19 处手写 `Grid(` 的逐条处置

| # | 位置 | 类型 | 处置 | verdict |
| --- | --- | --- | --- | --- |
| 1 | `SettingsRootView` 存储策略 | 三列可编辑表单 | 保留自写 `Grid`，注释写明理由，回归强制 | `exception` |
| 2 | `SettingsRootView.SettingsValueGrid` | 事实列表 | 批次五已收敛 | `fixed`（F56） |
| 3 | `FlashWorkspaceView.planStageSummary` | 三列表格（表头 + 分隔线） | 保留自写 `Grid`，注释写明理由 | `exception` |
| 4 | `FlashWorkspaceView` 设备访问建议 | 事实列表 | → `WorkspaceFactGrid` + 三行共享行 | `fixed` |
| 5 | `FlashWorkspaceView.planSummary` | 事实列表（字面 12/6） | → 共享网格；`summaryRow` 返回共享行，保留中段省略 | `fixed` |
| 6 | `RuntimeHistoryView` Correlation | 事实列表（`tightGap`） | → 共享网格 | `fixed` |
| 7 | `RuntimeHistoryView` Summary | 事实列表 | → 共享网格 | `fixed` |
| 8 | `RuntimeHistoryView` Evidence | 事实列表 | → 共享网格 | `fixed` |
| 9 | `RuntimeHistoryView.typedParameterGrid` | 事实列表（键本身是 mono 值） | → 共享网格 + `usesMonospacedName` | `fixed` |
| 10 | `FlashRuntimeActivityView` | 事实列表 | → 共享网格；`factRow` 返回共享行 | `fixed` |
| 11 | `DiagnosticsWorkspaceView` HiLog 计数 | 事实列表（字面 24/8） | → 共享网格；`hilogCount` 返回共享行 | `fixed` |
| 12 | `HDCStatusView` 能力矩阵 | 三列矩阵（表头 + 分隔线） | 保留自写 `Grid`，注释写明理由 | `exception` |
| 13 | `HDCStatusView.diagnosticsGrid` | 与 `WorkspaceFactGrid` 逐字相同 | 辅助函数删除，4 处调用直接用共享网格 | `fixed` |
| 14 | `HDCStatusView` 设备事件表 | 三列日志表 | 保留自写 `Grid`，注释写明理由 | `exception` |
| 15 | `HDCStatusView` 生命周期影响预览 | 事实列表 | → 共享网格（`row(...)` 本就返回共享行） | `fixed` |
| 16 | `GlobalJobInspectorView` Job 事实 | 事实列表 | → 共享网格；`factRow` / `recordedStateFactRow` 返回共享行 | `fixed` |
| 17 | `GlobalJobInspectorView` 恢复关系 | 事实列表（字面 16） | → 共享网格 | `fixed` |
| 18 | `DeviceWorkspace.factsGrid` | 事实列表（九个逐行 `GridRow`） | → 共享网格 + 新 `deviceFact` 收口 | `fixed` |
| 19 | `DebugWorkspaceView` Artifact 计划事实 | 事实列表（`blockGap` 横向） | → 共享网格；`planFact` 返回共享行 | `fixed` |

**8 个行辅助函数全部改为返回 `WorkspaceFactRow`**：History `row`、Jobs `factRow` /
`recordedStateFactRow`、Flash `summaryRow`、FlashRuntimeActivity `factRow`、HDC `field`、
Debug `planFact`、Diagnostics `hilogCount`，另新增 `DeviceWorkspace.deviceFact`。
`HDCStatusView.FieldTextStyle` 删除（三态即共享行的两个选项）。

## 2. 可见变化（无断言测量，需目测）

| 变化 | 影响面 | 为什么这是修复而不是顺带 |
| --- | --- | --- |
| 等宽值 13pt → 12pt | History 四张表、Job 检查器两张表、Flash 计划摘要、Flash 运行态 | 这些用 `.body.monospaced()` 绕过了 `WorkspaceFont.monospacedValue`；spec §2 对「路径/hash/版本/序列号/ID」只规定一个 12pt mono |
| 行距 6pt → 4pt | History 三张表、设备详情事实栏 | 用 `tightGap`(6) 而非 `.kv{gap:4px}` 对应的 `rowGap`(4) |
| 横向/纵向间距归一到 14/4 | Flash 计划摘要（12/6）、Diagnostics 计数（24/8）、Debug（`blockGap`/默认） | 三处各写各的字面值 |
| Diagnostics 计数表的键变为次要色 | HiLog 计数 8 行 | 原本键是主色，与 App 其余键值列表不一致 |
| 设备详情 `bindingRevision` 由 `tabularSecondary` 改为 mono | 1 行 | 共享行没有 12pt 比例字+表格数字的角色；该值是可比对的修订号，走 mono 更贴 spec §2。**这一条是取舍，不是等价替换** |

## 3. 刻意保留的行为

| 行为 | 位置 | 理由 |
| --- | --- | --- |
| 值不可选中、不截断、整段换行 | `HDCStatusView.field(...)` | 原注释：macOS 上文本选中会改变可访问性表示，使只读值对 UI 自动化不可见。收敛后 `isSelectable` / `elidedValue` 保持默认关闭，注释改写为解释这一点，并由回归断言 |
| 单行中段省略 + 悬停全值 + VoiceOver 读全值 | `FlashWorkspaceView.summaryRow` | 用共享行的 `elidedValue` 承载，行为不变 |
| 键为 mono 主色 | `RuntimeHistoryView.typedParameterGrid` | 用共享行的 `usesMonospacedName` 承载，行为不变 |

## 4. 功能实现腿：本批重核的界面单元（12）

改动只触及第 1（信息结构）与第 4（文案与本地化中的 mono 字段用法）两项载体；
文案、状态集合与动作集未改，其余四项以「与基线一致」记。

| surfaceID | 本批处置 | verdict |
| --- | --- | --- |
| device.details | 事实栏九行 → 共享行；行距 6→4 | `fixed` |
| overview.main | HDC 诊断字段 → 共享行（不可选中约束保留） | `fixed` |
| overview.environment | 同上，四处 `diagnosticsGrid` → 共享网格 | `fixed` |
| overview.hdcImpact | 生命周期影响预览 → 共享网格 | `fixed` |
| flash.workspace | 设备访问建议三行 → 共享行 | `fixed` |
| flash.plan | 计划摘要 → 共享网格，中段省略保留 | `fixed` |
| flash.runtime | 运行态事实 → 共享网格 | `fixed` |
| history.detail | Summary / Correlation / Evidence / Parameters 四张表 → 共享网格 | `fixed` |
| shell.inspector | Job 事实与恢复关系两张表 → 共享网格 | `fixed` |
| diagnostics.hilog | 计数表 → 共享网格，键改次要色 | `fixed` |
| debug.artifacts | Artifact 计划事实 → 共享网格 | `fixed` |
| design.components | App 侧键值列表重复清零，4 处 exception 由回归强制写明理由 | `fixed` |

**未重核的 50 个 surfaceID**：依据基线为批次一～五的结论；`fb6e5993` 相对批次五基线只有
PR #1590 一次合入，即本审计自身的改动。

## 5. 本批未覆盖（继续登记）

| 登记项 | 现状 |
| --- | --- |
| F52-4 剩余 | 73 处 `.font(.system(size:…))`（Diagnostics 39 / Device 30 / UIDump 2 / Flash 2）。10pt、12pt-medium、11pt-medium 在 `WorkspaceFont` 里无等值角色，必然改字号，下一批单独做 |
| F52-5 | `ViewerInspectorCopy` 硬编码英文——等待第 2 条裁决 |
| F52-6 / F52-8 | 资源里的已移除路径键；preview 无构建守护 |
| F52-7 / F52-9 | 按 spec §5.11 保留；`Select` 无 class 映射，均记 exception |
| F56 登记的两条既有原生失败 | `testDebugHAPSelection…`（套件内才复现）、`testHistoryAndRecovery…`（`main` 上可复现），根因均未定 |
| F52 待裁决三条 | 内容区重复工具栏标题、Viewer 检查器英文保留范围、App 侧 C-DUP 收敛取舍 |

## 6. 本批验证

| 检查 | 结果 |
| --- | --- |
| App 编译（`xcodebuild build`） | `** BUILD SUCCEEDED **`，0 error |
| 原生 XCUITest 全套（第一次） | 44 通过 / 4 失败 / 11 跳过 |
| 原生 XCUITest 全套（第二次，同一提交、同样空载） | **47 通过 / 1 失败 / 11 跳过** |
| 两条新失败单独重跑（本分支） | **2/2 通过** |
| `npm --prefix docs/design/arkdeck-ds test` | 76 项通过，0 失败（新增 1 项） |
| `npm --prefix docs/design/arkdeck-ds run build` / `build:review` / `check:tokens` | 全部通过 |
| 统一本地闸 `scripts/ci/plan.py --run-local` | 退出 0；App 编译车道（`app: true` / `swift: false`）`build-for-testing` 通过，SDD、catalog 与设计车道同跑通过 |
| 浏览器逐页走查 / 真实设备 | **均未执行** |

### 原生套件的运行间方差（本批实测，五次全套）

第一次跑出 44/4，比批次五的 46/2 差，两条新失败又正好落在本批改过的 HDC 与 Debug 上，
所以没有直接放行，而是逐条量了：

| 运行 | 代码 | 结果 | 失败集合 |
| --- | --- | --- | --- |
| A | `main`（当时本机并行跑着构建） | 45/3 | DebugHAP、History（signal kill）、Sandbox（fixture 未构建） |
| B | 批次五 | 46/2 | DebugHAP、History |
| C | 批次六 | 44/4 | DebugHAP、History、EnglishFixtureSweep、zhLocalizationSweep |
| D | `main`（空载，fixture 已补） | 45/3 | DebugHAP、History、Sandbox（**「expanding Environment must reveal the raw toolchain facts」**） |
| E | 批次六（空载，与 D 同条件，代码与 C 逐字相同） | **47/1** | UserPickerPersistsBookmark（**同一条 Environment 断言**） |

**结论：这套 XCUITest 在逐字相同的代码上会跑出不同的失败集合。** C 与 E 是同一个提交、
同样空载，一个 4 失败一个 1 失败；D 与 E 里同一条断言分别打在两个不同的测试上。批次六
最好的一次（47/1）优于 `main` 最好的一次（45/3）。C 的两条新失败在本分支上单独重跑通过。
因此 C 的 44/4 **不是本批回归**，而是套件方差。

**顺带定位到方差的一个来源**（登记，不在本批修）：
`ArkDeckAppUITests/HDC/HDCStatusUITests.swift:494` 的 `expandAdvancedDiagnostics` 是
「固定次数滚动 + 单次 click + 5 秒等待」，没有重试；它被 `walkEveryDiagnosticState` 共用，
于是哪个测试恰好抽到不利的布局/时序，失败就记在哪个测试头上——这正是 D 与 E 里同一条
断言打在两个不同测试上的原因。

**这对后续批次是个真问题**：套件目前无法在 1–4 条失败的粒度上区分回归与噪声，
而批次七要大改 Diagnostics 与 Device 两个工作区的字号。建议在批次七之前单起一批稳定
原生门禁；本批不顺手改，避免把收敛批次和测试稳定性混在一个 PR 里。
