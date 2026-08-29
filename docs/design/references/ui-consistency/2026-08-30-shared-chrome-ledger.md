# UI 一致性台账 · 2026-08-30 批次五（App 侧共享件收敛，C-DUP 第一批）

> 任务：[UI 稿与实现一致性核对任务](../../ui-consistency-audit-task.md)（TASK-AIN-021）
> 基线：`9e80901f`（批次四 PR #1589 合入后的 `origin/main`）
> **批次范围**：**组件复用腿**——F52 第 4 条登记的 App 侧重复实现里，「成套重写已存在共享件」
> 的那一半：`DeviceWorkspace` 自写的通知、`SettingsRootView` 自写的五个类型、跨 Feature 共用
> 却放在 History 里的执行模式徽章。功能实现腿的 62 个 surfaceID **本批只重核受影响的 15 行**，
> 其余 47 行继承[批次一](2026-08-29-ledger.md)～[批次四](2026-08-29-concept-ledger.md)的结论——
> `9e80901f` 与批次四基线之间只有本审计自身的 PR #1589，未触及 App 代码。
> 差异登记见[审计记录 F56](../../implementation-audit-2026-08-27.md)。
>
> **验证边界**：本批触碰 App 代码，因此跑了原生 XCUITest 全套（改前基线一次、改后一次）。
> 原生全绿只证明这些断言覆盖到的行为未回归，**不构成 App 呈现验收、不构成真机验收**，
> 不翻转任何 Golden Journey 状态。无浏览器逐页走查，无设备操作。

## 1. 组件复用腿：本批处置的重复实现

| 对象 | 核对结论 | verdict | 证据 |
| --- | --- | --- | --- |
| `DeviceWorkspace.deviceNotice(_:systemImage:color:identifier:)` | 与 `WorkspaceNotice` 语义等价的第二份实现，且同文件已在用共享件；7 处调用（登记时记为 8 次，含定义行）全部改用共享件，语义色按既有取值映射，符号与标识符不变 | `fixed` | F56；`the shared workspace chrome has no App-side copies` |
| `SettingsRootView.SettingsPaneContainer` | 重写 `WorkspacePage`；6 处调用改走共享件，上下内边距由 24/24 变为共享的 20/28 | `fixed` | 同上 |
| `SettingsRootView.SettingsPaneHeader` | 重写 `WorkspaceHeaderBar`；5 处调用改走共享件，说明行不再被 620pt 行宽夹住 | `fixed` | 同上 |
| `SettingsRootView.SettingsValueGrid` + `SettingsValueRow` | 重写 `WorkspaceFactGrid` + `WorkspaceFactRow`，并多出单行中段省略、悬停全值、可选中与数字列对齐；按 F52 的判断**扩展共享行**承载这四种行为，副本删除；5 张事实列表改走共享件 | `fixed` | 同上 |
| `SettingsRootView.SettingsErrorBanner` / `SettingsSuccessBanner` | 重写 `WorkspaceNotice`；7 处调用改走共享件的 warn / ok 两态，颜色不再是唯一载体 | `fixed` | 同上 |
| `RuntimeExecutionModeBadge` 的归属 | 两个 Feature 渲染，却定义在 `Features/History/RuntimeHistoryView.swift`；实现逐字不变移入 `DesignSystem/`，`appViewFiles` 21 个 | `fixed` | 同上 |
| `WorkspaceFactRow`（受控共享件） | 新增四个默认关闭的可选行为：`usesTabularDigits` / `usesMonospacedName` / `isSelectable` / `elidedValue`；既有 8 处调用行为不变 | `fixed` | 同上 |
| `WorkspaceNotice` / `WorkspacePage` / `WorkspaceHeaderBar` / `WorkspaceFactGrid` / `WorkspaceChip`（受控共享件） | 定义未改；本批只增加消费方 | `pass` | 同上 |

## 2. 组件复用腿：本批**未**收敛的重复（逐条给理由）

| 对象 | 结论 | verdict |
| --- | --- | --- |
| 9 个 Feature 文件里 19 处手写 `Grid(` | 实测分类：15 处是键值事实列表（应收敛为 `WorkspaceFactGrid`），4 处不是——`SettingsRootView` 存储策略是三列可编辑表单，`FlashWorkspaceView.planStageSummary`、`HDCStatusView` 能力矩阵与设备事件是带表头/分隔线的三列表格。收敛会改变行距（多处用 `tightGap` 6 而共享件是 `rowGap` 4），单独成批更好复核 | `registered`（F56 本批未覆盖） |
| 73 处 `.font(.system(size:…))` | 实测 39 处在 `DiagnosticsWorkspaceView`、30 处在 `DeviceWorkspaceView`、另 4 处在 `UIDumpWorkspaceView` / `FlashWorkspaceView`（F52 记「占全 App 此类写法的全部」不准确）。其中 10pt、12pt-medium、11pt-medium 在 `WorkspaceFont` 里**没有等值角色**，收敛必然改变实际字号，属产品判断，单独成批 | `registered`（F56 本批未覆盖） |
| `SettingsAssuranceRow` / `SettingsLoadingRow` | 不与任何现有共享件重复（一个是图标+标题+说明的三段行，一个是小 spinner + 文案）；App 内只此一处使用 | `exception`：无第二份实现，不构成 C-DUP |
| 退役 Automation 的四个组件（OperationList / BudgetMeters / StageTrack / StatusStrip） | spec §5.11 要求保留为历史资料 | `exception`：继承 F52-7 |

## 3. 功能实现腿：本批重核的界面单元（15）

按 §4 六项协议逐项核对；本批的改动只触及第 1（信息结构）与第 6（可达性）两项的载体，
文案、状态集合与动作集未改，因此第 2–5 项以「与基线一致」记。

| surfaceID | 本批处置 | verdict | 证据 |
| --- | --- | --- | --- |
| device.details | 事实栏未改；同文件的通知改走共享件 | `pass` | 原生 `testDeviceContextMenuRenamesAndRefreshesDeviceState` |
| device.trust | 五种信任态 + 三种等待态共 8 处通知统一为 `WorkspaceNotice`，标识符不变 | `fixed` | F56；原生 `testHistoryAndRecoveryContinuousSessionInBothLanguages` 中的信任/等待断言 |
| settings.general | 面板骨架、说明行、构建事实列表改走共享件 | `fixed` | F56；原生 `testApplicationIconSwitchesFromSettings` |
| settings.toolchains | 面板骨架、说明行、八行事实列表（path/sha256 保持单行中段省略）改走共享件；失败提示改共享通知 | `fixed` | F56；原生 `testRemoteBuildSourceSettingsSurfaceIsReachableAndFailClosed` 的工具链断言 |
| settings.servers | 面板骨架、说明行改走共享件；失败横幅改共享通知 | `fixed` | F56；同上 |
| settings.serverEditor | 编辑器内两处失败提示改共享通知 | `fixed` | F56；同上 |
| settings.serverDelete | 未改动 | `pass` | 继承批次一 |
| settings.storage | 面板骨架、说明行、位置与用量两张事实列表改走共享件；存储策略表单保留自写 `Grid`（三列可编辑输入） | `fixed` | F56 |
| settings.traceCache | 未改动（`TraceSettingsPane` 在 `TraceViewerWorkspaceView.swift`，不含副本） | `pass` | 原生 `testTraceSettingsCacheAndLicensesAreReachableInBothLanguages` |
| settings.traceLicenses | 未改动 | `pass` | 同上 |
| settings.updates | 面板骨架改走 `WorkspacePage` | `fixed` | F56 |
| settings.diagnostics | 面板骨架、说明行、预览事实列表改走共享件；成功/失败提示改共享通知的 ok/warn 两态 | `fixed` | F56 |
| shell.inspector | 执行模式徽章改由 `DesignSystem/` 提供，渲染逐字不变 | `fixed` | F56；原生 `testGlobalCancellationFixtureRefusesWithoutChangingTheJobOutcome` |
| history.detail | 同上，History 与 Job 检查器同源 | `fixed` | F56；原生 `testRealDeviceHistoryReopensExactViewerCapture` |
| design.components | 共享词表新增一个受控 App 组件文件；App 侧六份重复实现清零 | `fixed` | F56；`the shared workspace chrome has no App-side copies`、`every App View file and preview is covered and linked` |

**未重核的 47 个 surfaceID**：依据基线为批次一～四的结论。`9e80901f` 相对批次四基线
`e914beed` 只有 PR #1589 一次合入，改动全在 `docs/design/**`，未触及 App 代码或本批改动的
共享件消费方，故不重核。

## 4. 本批未覆盖（继续登记）

| 登记项 | 现状 |
| --- | --- |
| F52-4 剩余 | 15 处事实列表 `Grid(` 与 73 处 `.font(.system(size:…))`，见上表第 2 节 |
| F52-5 | `ViewerInspectorCopy` 硬编码英文，而目录里的中文键无人引用——等待第 2 条裁决 |
| F52-6 | 资源里的已移除路径键（Debug 11 / Diagnostics 13 / Flash 29 / History 6 / Settings 4） |
| F52-7 | 退役 Automation 样式，按 spec §5.11 保留 |
| F52-8 | preview 无构建守护 |
| F52-9 | `Select` 无 class 映射（已记 exception） |
| F52 待裁决三条 | 内容区重复工具栏标题、Viewer 检查器英文保留范围、App 侧 C-DUP 收敛取舍 |

**关于第 3 条待裁决。** 本批只收敛「共享件已存在、语义等价、收敛不改变语义」的六份重复，
并把可见差异逐条写进 F56 与本台账，未替维护者决定第 1、2 条。剩余的字号与行距收敛会改变
实际呈现尺寸，留待你给结论后再动。

## 5. 原生回归覆盖到哪里、没覆盖到哪里

本批改动的表面里，原生断言真正覆盖的是设备信任/等待通知（`device.trust.*`、`device.wait.*`
按标识符断言存在）与各 Settings 面板的可达性、控件与字段。**没有**被原生断言覆盖的是：

- Settings 的失败/成功通知本身。App 没有能确定性触发 Settings 错误的 fixture 启动参数
  （现有的只有 `--ui-test-viewer` / `--ui-test-flash` / `--ui-test-devices` /
  `--ui-test-device-recording` / `--ui-test-flash-plan` 等五类），本批不为凑断言而新增
  测试专用产品路径。这七处横幅的收敛由源码级回归
  `the shared workspace chrome has no App-side copies` 守护，不冒充已由原生验证。
- 面板内边距、说明行行宽、通知底色与描边这些纯呈现变化，任何断言都没有测量；它们逐条
  写在 F56 与第 1 节里，等你目测确认。

## 6. 本批验证

| 检查 | 结果 |
| --- | --- |
| 原生 XCUITest 全套 · 改前基线（`9e80901f`，未改动） | **45 通过 / 3 失败 / 11 跳过** |
| 原生 XCUITest 全套 · 改后 | **46 通过 / 2 失败 / 11 跳过** |
| 原生 XCUITest 定向归因（clean `main`，仅两条失败用例） | 1 通过 / 1 失败，见下表 |
| `npm --prefix docs/design/arkdeck-ds test` | **75 项通过，0 失败**（新增 1 项） |
| `npm --prefix docs/design/arkdeck-ds run build` | 通过 |
| `npm --prefix docs/design/arkdeck-ds run build:review` | 通过 |
| `npm --prefix docs/design/arkdeck-ds run check:tokens` | 通过，每个原型 class 均已分类 |
| 统一本地闸 `scripts/ci/plan.py --run-local` | 退出 0；本轮首次分配 App 编译车道（分类为 `app: true` / `swift: false`，`build-for-testing` 通过），SDD、catalog 与设计车道同跑通过 |
| 浏览器逐页走查 / 真实设备 | **均未执行** |

**原生全套两次都是红的，本批没有把它变绿，也不假装它绿。** 三条失败逐条归因如下，
证据是同一台机器上三次运行的 xcresult：

| 用例 | 改前基线 | 改后 | clean `main` 单独跑 | 归因 |
| --- | --- | --- | --- | --- |
| `HDCStatusUITests.testProductionSandboxRejectsRepositoryFakeBeforeAnyHDCProbe` | 失败：`Expected exact displayed value …/Packages/ArkDeckKit/.build/debug/ArkDeckFakeHDCFixture, got: unknown (no configured candidate)` | **通过** | — | **环境前置缺失**：该 SwiftPM 产物在本工作副本里没有构建过。已 `swift build --product ArkDeckFakeHDCFixture` 补齐，改后即通过。与本批改动无关 |
| `AppShellUITests.testDebugHAPSelectionAddsHSPRejectsDuplicatesAndClearsInBothLanguages` | 失败 `AppShellUITests.swift:1154` | 失败 `AppShellUITests.swift:1154` | **通过** | **既有的顺序/负载相关不稳定**：全套跑必失败、单独跑必通过，两次全套失败在同一行——`app.popUpButtons["debug.apps.postRun"]` 15 秒内未出现。该 Picker 在 `DebugWorkspaceView.lifecycleSection` 里无条件渲染，本批未触碰该文件。**根因未定**，不臆断 |
| `AppShellUITests.testHistoryAndRecoveryContinuousSessionInBothLanguages` | 失败：`Test crashed with signal kill`（该次运行期间本机并行跑着 npm 构建与 `swiftc -parse`） | 失败：`requested History row job-fixture-recovery-human: row (535.5, 626.0, 193.5, 16.0), viewport (483.0, 448.5, 342.0, 189.5)` | **失败：同一断言、同一 viewport `(483.0, 448.5, 342.0, 189.5)`**，只是先卡在 `job-fixture-recovery-archive`（`row (535.5, 696.0, 140.0, 16.0)`） | **既有失败，在未改动的 `main` 上可复现**。审计记录本就写着 F40/F41 的「原生精确行定位仍在复测，不能视为通过」。测量事实：表格 viewport 只有 189.5pt 高（底边 638），而被要求完整可见的行在 y=626 与 y=696，20 次滚动后仍未进入。**根因未定**，本批不改 History |

**这两条已在 F56 单列登记为待处理，不计入本批的「已修」。** 本批对原生结果的唯一正向
影响是补齐了 HDC fixture 前置（失败数 3→2、通过数 45→46）。
