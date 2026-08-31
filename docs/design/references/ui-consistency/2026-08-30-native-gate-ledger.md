# UI 一致性台账 · 2026-08-30 批次七（稳定原生门禁）

> 任务：[UI 稿与实现一致性核对任务](../../ui-consistency-audit-task.md)（TASK-AIN-021）
> 基线：`373edb9b`（PR #1597 合入后的 `origin/main`）
> **批次范围**：不是新的一轮核对，而是清 F56 / F57 两条欠账——F56 登记的两条既有原生失败，
> 与 F57 登记的「套件结果不稳定」。**只动测试侧**（`ArkDeckAppUITests/**`）；同族的产品侧
> 修复由并行会话持有，见第 3 节。差异登记见[审计记录 F58](../../implementation-audit-2026-08-27.md)。
>
> **验证边界**：本批的原生复核**尚未完成**——写作时整机 UI 自动化被锁屏阻塞
> （`IOConsoleLocked = Yes`），需要维护者解锁。第 5 节如实标注哪些已验证、哪些没有。
> 不以设计侧全绿冒充原生已验证。

## 1. 四处修复与各自的实证

| # | 位置 | 实证（不是推断） | 处置 | verdict |
| --- | --- | --- | --- | --- |
| 1 | `AppShellUITests` Debug tab 切换 | 失败运行导出的 **AX hierarchy 显示 App 停在 Artifacts**（`debug.artifacts.bundle` / `logicalName` 可见），而其后 15 秒在等只存在于 Apps 页的 `debug.apps.postRun` | 裸 `.click()` → `clickCorrectingNavigationSplitAXOffset`（本套件其余 Debug 分页切换一律用它），最多重试 3 次，切换生效后才继续 | `fixed`（待原生复核） |
| 2 | `AppShellUITests.chooseDebugPackage` | 三次运行分别失败在 `:1154` / `:1227` / `:1180`，最后两次是 `package was not selected` / `expected entry.hap, got: No local HAP selected` | ⌘⇧G 后不再取 `panel.textFields.firstMatch`（open panel 自带文本框，可能抓到既有字段），改为定位 Go to Folder 那张 sheet 自己的输入框；键盘布局 pin 移到第一次合成按键**之前**；失败时附 panel hierarchy | `fixed`（待原生复核） |
| 3 | `HDCStatusUITests.expandAdvancedDiagnostics` | 同一条断言 `expanding Environment must reveal the raw toolchain facts` 在两次运行里落在**两个不同测试**上（`testProductionSandboxRejects…` 与 `testUserPickerPersistsBookmark…`）——helper 被 `walkEveryDiagnosticState` 共用，点丢了记在调用方头上 | 固定次数滚动 + 单次 click → ⌘⇧D（披露自己的快捷键，无需命中测试）+ 按钮发布的 `accessibilityValue` 判断按键是否生效（因而不依赖界面语言）；删除失去消费方的 `overviewScrollView` | `fixed`（待原生复核） |
| 4 | `HDCStatusUITests.applyFixtureState` | 期待 `timed out — retry is non-destructive`，读到 `denied — The device declined trust…`，即**下一条**断言读到上一个状态的值 | 等 Refresh 重新 enabled 的超时 5 → 20 秒，App 空闲后再驱动 | `fixed`（待原生复核） |

**四处形状相同**：驱动一个异步动作，然后立刻读一次结果。`waitUntil(timeout:_:)` 收进
`KeyboardInputSourcePin.swift`（已是共享测试工具所在地），不在两个测试类各写一份。

## 2. 本会话撤回的一份产品修复

F56 的 History 精确行定位，本会话的处理链条如下，第三步是关键：

1. 先按「竞态」假设在测试侧加 10 秒轮询；
2. **轮询无效**——行仍然永远不进 viewport（实测落在下方 12–58pt，有一次 `(0, 956, 0, 0)` 即
   尚未布局）。这条否证了自己的假设：纯等待修不好，必须动产品侧；
3. 据此写了一版产品修复（几个 runloop turn 内重复 anchor），**随后撤回**。

撤回理由不是先来后到：并行会话持有维护者指派的该 chip，且其机制更好——重锚挂在
`onScrollGeometryChange(contentSize)`，即行安装/量行的**真实完成条件**，无定时器、无次数上限；
本会话那版 `10×50ms` 属于「靠负载统计」，与仓规冲突。三条实证移交对方 commit 归档。
`RuntimeHistoryView.swift` 在本分支上与 `main` 逐字相同。

## 3. 与并行会话的跑道协调（本批的一部分成本）

| 事件 | 结果 |
| --- | --- |
| 两会话同时跑 UI 测试 | 后启动方 `Timed out while enabling automation mode`；跑道全机唯一 |
| 对方 `run-ui-tests.sh` 开头的全局 `pkill` | 打死本会话在飞的 runner，本会话看到 `Test crashed with signal term while preparing to run tests`（两次） |
| 本会话后台任务被回收 | SIGTERM 连带打死 runner，日志停在 `Running tests...`、退出码 144；改用 `nohup` 脱离进程组 |
| 默认 DerivedData 全机共享 | `build.db is locked`；改用 `ARKDECK_UI_TEST_DERIVED_DATA` 独立路径 |
| 换新 DerivedData 路径首跑 | 必吃一次 automation-mode 超时（脚本头注释已载明） |
| 当前 | 整机 UI 自动化被**锁屏**阻塞（`IOConsoleLocked = Yes`），需维护者解锁 |

脚本本身在 `scripts/ci/**`，**不在本 Task 的 Allowed paths 内，本批不改**，只登记。

## 4. 对 F57 结论的更正

F57 用一张 A–E 五次运行的方差表论证「套件在逐字相同的代码上会跑出不同的失败集合」。
**该表作废**：当时整机上还有另一会话在跑同一套件、以及一个 Codex 会话在跑 Relay 测试，
本会话无从得知，数据被并发污染，不能支撑那个结论。带有
`Failed to activate application` / `database is locked` / `enabling automation mode` / `signal term`
四类信号之一的运行一律判为**无效 run**，不计红、不作回归证据。F57 的其余部分
（`expandAdvancedDiagnostics` 是共用 helper、失败会记在调用方头上）由第 1 节第 3 行的直接
实证独立支撑，不依赖那张表。

## 5. 本批验证（逐条如实标注）

基线 `c8d8179a`（含 #1597 窗口帧钩子、#1598 pkill 收窄）。下表所列运行的**有效性信号计数为 0**，
即都是有效 run。判据在本批过程中扩到六条——后两条是第二次 HDC 取样才暴露出来的：

`Failed to activate application` / `database is locked` / `Timed out while enabling automation mode` /
`signal term`（或 `BUILD INTERRUPTED`）/ **`Not authorized for performing UI testing actions`** /
**`Lost connection to the application`** / **`The test runner hung before establishing connection`**（含同族的 `crashed ... before establishing connection`，脚本头注释已载明属 runner 启动面）。

后两条尤其容易被误读成产品缺陷：它们报在具体测试头上、措辞像断言失败，但实为 UI 自动化授权
在运行中丢失。实测一次：未锁屏、`testmanagerd` 存活、无其他会话占用跑道，仅有一个 Relay 性能
soak 在压 CPU，`HDCStatusUITests` 就出现 1 通过 / 5 失败，其中 4 条是「Not authorized」、1 条是
「Lost connection」。**该次判为无效 run，不计入下表。**

| 检查 | 结果 |
| --- | --- |
| 测试目标编译 `build-for-testing` | **通过** |
| `npm --prefix docs/design/arkdeck-ds test` | **76 项通过，0 失败** |
| 原生 `HDCStatusUITests` 定向全类 · 取样一 | **`** TEST SUCCEEDED **`，6 通过 / 0 失败** |
| 原生 `HDCStatusUITests` 定向全类 · 取样二 | **`** TEST SUCCEEDED **`，6 通过 / 0 失败** |
| 原生 `testDebugHAPSelection…` 定向（本分支） | **失败：`file picker did not open`** |
| 原生 `testDebugHAPSelection…` 定向（**clean `main` 同一 commit**） | **失败：同一条 `file picker did not open`** |
| 统一本地闸 `scripts/ci/plan.py --run-local` | 退出 0；App 编译车道（`app: true` / `swift: false`）`build-for-testing` 通过 |
| 浏览器逐页走查 / 真实设备 | **均未执行** |

**四处修复的复核状态，不含糊：**

| 修复 | 状态 | 依据 |
| --- | --- | --- |
| `expandAdvancedDiagnostics` → ⌘⇧D | **已验证（两次有效取样）** | HDC 全类 6/6 × 2，且 `walkEveryDiagnosticState` 是这些测试的公共入口 |
| `applyFixtureState` 沉降（5→20s） | **已验证（两次有效取样）** | 同上，含 `testEnglishFixtureSweep` 的 fixture 状态序列 |
| Debug tab 切换 → 修正点击 | **已验证有改善，未验证到底** | 该测试此前失败在等 `debug.apps.postRun`（tab 没切过去）；现在能走到文件选择器，说明 tab 切换生效。但整条测试仍红于后续步骤 |
| `chooseDebugPackage` 定位 Go to Folder 输入框 | **未被执行到** | 测试在 `chooseDebugPackage` 的**第一道** guard 就失败，从未到达被改的那几行。**本批不声称它有效** |

### 本批未修、已登记的一条既有失败

`testDebugHAPSelection…` 在 `c8d8179a` 上失败于 `file picker did not open`，
**在未改动的 `main` 上以完全相同的消息复现**（两次运行有效性信号均为 0），因此**与本批改动无关**。
触发点是 `app.buttons["debug.apps.entry.choose"].click()` —— 又一处裸 `.click()`，而紧随其后的两处
`addPackage` 点击都先做 `scrollIntoView`。

**曾尝试按同样方式修，失败并已回退**：加 `scrollIntoView(chooseEntry, …)` 后，失败变成
`Unable to find hit point for ScrollView, {{1647.0, 200.0}, {245.0, 318.0}}` —— 该 ScrollView 的 x
落在本机单显示器（2560×1664 Retina）逻辑宽度之外，即 helper 选中了一个**屏外**的滚动宿主。
换言之控件/宿主为何解析到屏外尚未查清，**在查清之前不拿一个换汤不换药的失败去替原来的失败**，
已回退，只登记。根因未定。

**本批 PR 只主张已验证的两处 + 一处「有改善」，不主张把 `testDebugHAPSelection…` 修绿。**

## 2026-08-31 补记：`scrollIntoView` 一族失败的机制定案（见审计 F68）

本台账上文那条「加 `scrollIntoView(chooseEntry, …)` 后失败变成 `Unable to find hit point for
ScrollView, {{1647.0, 200.0}, {245.0, 318.0}}`，根因未定」，与 F58/F59/F66 的同族观测，
2026-08-31 查到了共同的机制：

**`XCUIElement.scroll(byDeltaX:deltaY:)` 在这些滚动宿主上静默空转。** 插桩测得 12 次调用前后
宿主与目标 frame 逐字节相同——不报错、不移动、不返回失败。`press(forDuration:thenDragTo:)`
兜底同样零位移。

由此，「选错滚动宿主」这条一直以来的工作假设**不成立或至少不充分**：即便选中正确宿主，
滚动也推不动目标。此前三次沿该假设做的修复（本台账的 `chooseEntry`、F66 的高度判据、
F69 的 Debug 分页条）全部无效，均已回退。

**规矩**：在滚动为何空转查清之前，不再提交任何依赖 `scroll` 生效的修复；
也不再把「加了 scrollIntoView 之后报错换了一种」当作进展。
