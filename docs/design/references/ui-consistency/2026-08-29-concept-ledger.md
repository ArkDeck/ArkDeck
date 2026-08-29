# UI 一致性台账 · 2026-08-29 批次四（Diagnostics 概念页双语 + 信任页 Runtime 事实栏）

> 任务：[UI 稿与实现一致性核对任务](../../ui-consistency-audit-task.md)（TASK-AIN-021）
> 基线：`e914beed`（批次三 PR #1588 合入后的 `origin/main`）
> **批次范围**：F52 第 2 条的剩余部分（Diagnostics 概念页）与第 3 条（信任页），
> 共 2 个 surfaceID，另含一处顺带修复的既有缺陷。其余 60 个 surfaceID 与组件复用腿
> **本批不重核**，继承[批次一](2026-08-29-ledger.md)、[批次二](2026-08-29-states-ledger.md)、
> [批次三](2026-08-29-inspector-ledger.md)的结论——`17a30972…e914beed` 之间只有本审计
> 自身的 PR #1586/#1587/#1588，未触及 App 代码。
> 差异登记见[审计记录 F55](../../implementation-audit-2026-08-27.md)。
>
> **验证边界**：只核对稿与代码。无浏览器逐页走查、无原生 XCUITest、无设备操作；
> 不构成 App 呈现或真机验收，不翻转任何 Golden Journey 状态。

## 1. 本批重核的界面单元（2）

| 对象 | 本批处置 | verdict | 证据 |
| --- | --- | --- | --- |
| diagnostics.concept | 正文、三个演示 Session 的数据（label / alignChip / alignRows / alignNote / partialReasons / marker 标签）、演示采集生成的新 Session、时间轴上按事实生成的 AX 名称、Marker 状态行、时间对齐与原始顺序日志两个弹层全部改为语言对，由通用 `bi()` 解析。设备画面占位与 HiLog 正文、Trace event 名保持设备原文 | `fixed` | F55；`the Diagnostics concept pages read in both languages` |
| device.trust | 改为与设备详情同构的两栏（当前状态与操作 + Runtime 事实），文案逐字取自 `Localizable.xcstrings`；事实栏只列未授权候选真正报告的三项，**不为 target / binding / 机型 / 系统版本补演示值**；补 `device.wait.unavailable` 第四态；信任成功后显示「已授权但未接管」＋CLI 接管说明 | `fixed` | F55；`the trust page shows the same Runtime facts column and every wait answer` |

## 2. 顺带修复的既有缺陷

| 缺陷 | 处置 | verdict |
| --- | --- | --- |
| `fmtLeft()` 被信任页倒计时与轮询 tick 引用两处却从未定义：进入 polling 态时 `pAuth()` 抛 `ReferenceError`，整页停止渲染——「开始等待授权」在浏览器里是坏的。已在合入的 `main` 上复现，属既有缺陷 | 补上 mm:ss 格式化实现，回归断言倒计时确实渲染 | `fixed` |

## 3. 对上一批结论的更正

批次三的记述写了「F52 第 1 条至此全部闭合」，但该条列举的 `device.wait.unavailable` 当时
并未实现。正确说法：F52 第 1 条在批次二、三闭合了 Overview / Flash / Trace / Settings /
Job 检查器 / Viewer 六处，`device.wait.unavailable` 直到本批才补上。原记述保留不改写。

## 4. 本批未覆盖（继续登记）

| 登记项 | 现状 |
| --- | --- |
| F52-4 | App 侧 `deviceNotice`、Settings 四个副本、19 处手写 `Grid(`、两个 workspace 绕过 `WorkspaceFont`/`WorkspaceMetrics`、`RuntimeExecutionModeBadge` 放置 |
| F52-5 | `ViewerInspectorCopy` 硬编码英文，而目录里的中文键无人引用 |
| F52-6~9 | 资源里的已移除路径键、退役 Automation 样式、preview 无构建守护、`Select` 无 class 映射 |
| F52 待裁决三条 | 内容区重复工具栏标题、Viewer 检查器英文保留范围、App 侧 C-DUP 收敛取舍 |

**F52 的纯设计侧登记项（第 1、2、3 条）至此全部闭合**；剩余四条与三条待裁决都需要 App
改动或维护者结论。

## 5. 本批验证

| 检查 | 结果 |
| --- | --- |
| `npm --prefix docs/design/arkdeck-ds test` | **74 项通过，0 失败**（新增 2 项） |
| 全页英文扫描 | 20 组页面/状态组合，除设备画面占位与设备日志正文外**无中文回落** |
| `npm --prefix docs/design/arkdeck-ds run build` | 通过；`check:tokens` 每个原型 class 均已分类 |
| `npm --prefix docs/design/arkdeck-ds run build:review` | 通过 |
| 统一本地闸 `scripts/ci/plan.py --run-local` | 退出 0；纯设计/文档车道，不分配 Swift / App 编译车道 |
| 浏览器逐页走查 / 原生 XCUITest / 真实设备 | **均未执行** |
