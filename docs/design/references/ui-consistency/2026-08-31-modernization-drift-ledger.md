# UI 一致性台账 · 2026-08-31 批次十一（#1606 表面漂移增量核对）

> 任务：[UI 稿与实现一致性核对任务](../../ui-consistency-audit-task.md)（TASK-AIN-021）
> 基线：`e4218110`
> **批次性质**：**增量轮**，不是新一轮全量。触发条件是 brief §10「App 表面发生实质改动即重跑
> 一轮」——`bec43c53`（#1606 *modernize SwiftUI surfaces*，21 文件 / +771 −568）。
> 差异登记见[审计记录 F62](../../implementation-audit-2026-08-27.md)。
>
> **增量范围与未重核依据**：只重核 #1606 触及且**呈现确有变化**的行（见第 1 节测量）。
> 其余 60 个 surfaceID 继承批次一～十的结论——`e4218110` 与批次十基线之间除 #1606 外，
> 只有本审计自身的 PR。

## 1. 先测量漂移面，避免把 API 现代化当成漂移

#1606 改动很大，但绝大部分是 SwiftUI 写法现代化（`Tab` API、`onGeometryChange`）。逐项测量：

| 测量项 | 结果 | 结论 |
| --- | --- | --- |
| 新增可访问性标识符 | 5 个 | — |
| 删除可访问性标识符 | **同样 5 个**（`device.history.loading`、`device.screen.empty`、`device.screen.image`、`viewer.history.loading`、`viewer.tree.scroll`） | 增删**完全对称** = 代码位置移动，**可达性面未变** |
| 新增本地化键 | **3 条** | 新增文案 = 新增呈现，稿件侧零对应 |

因此本批的漂移面就是那三条键，其余不重核。

## 2. 三条 P-DRIFT 的处置

| 键 | App 用法 | 稿件此前 | 本批处置 | verdict |
| --- | --- | --- | --- | --- |
| `viewer.tree.expand` / `.collapse` | 组件树节点的**独立具名 Button**（`HStack` 里与选择按钮并列） | 一个 button 包住整行，chevron 是 `aria-hidden` 装饰、靠事件委派判断点击区 | 行降为 `role="treeitem"` 容器；chevron 成为带 `aria-label` + `aria-expanded` 的按钮；其余内容成为 `.viewer-tree-select` 按钮 | `fixed` |
| `device.record.saveFailed` | 录制成功后**写盘失败**的 alert（标题=该键，正文=写入器原因） | 无此状态 | 新增 `recordStage="saveFailed"` 与 `recordingSaveFailed` scenario，URL token 可达；与既有 `failed`（采集失败）分开 | `fixed` |

**为什么组件树非改结构不可**：App 的展开/折叠是一个**有名字的控件**；稿件把 chevron 放在一个大
button 内部，指针可达但**按名称不可达**，动作集与 App 不对应（brief §4 第 2、6 项）。
新 class `viewer-tree-select` 已加入 `CLASS_TO_COMPONENT`（→ `ComponentTree`），
`check:tokens` 通过。

**刻意保留的形态差异**：App 的 saveFailed 是模态 alert，稿件是内联提示。稿件的 `modal()` 已
映射到 `DangerConfirmDialog`（危险确认语义），拿它装信息 alert 会制造新的组件映射错误。
两侧**状态可达、文案同源**，形态差异记为已知差异，不硬凑。

## 3. 本批自己引入又修掉的一个缺陷

补 saveFailed 的样本原因时，最初在 `deviceDraftState()` 里调用了 `deviceLocale()`。该函数
**在 `S` 初始化之前**被顶层调用，于是 `?deviceState=recordingSaveFailed` 一经命中即
`ReferenceError: Cannot access 'S' before initialization`，**整页停止渲染**。

- **抓到方式**：harness 直接渲染该 URL；静态检查与肉眼都看不出来。
- **修法**：样本存 `{zh,en}` 语言对，渲染期用 `bi()` 解析（与 HIST / 诊断样本同机制）。
- **回归**：断言 `deviceDraftState` 内不得出现 `deviceLocale(`。

另复犯一次批次四的老错：手打英文文案，把 App 原文的 curly apostrophe（`Couldn’t`，U+2019）
写成直引号，导致「稿件文案 == App 目录值」断言失败。改为从 `.xcstrings` 逐字取值。
两条教训已记入共享 memory。

## 4. 本批验证

| 检查 | 结果 |
| --- | --- |
| `npm --prefix docs/design/arkdeck-ds test` | **80 项通过，0 失败**（新增 1 项） |
| `check:tokens` | 通过，每个原型 class 均已分类（含新增 `viewer-tree-select`） |
| harness 实测渲染 | 中英各一轮：组件树 17 个具名展开按钮 + 29 个选择按钮、行不再是 button；saveFailed 标题与原因中英正确、无语言回落 |
| 统一本地闸 `scripts/ci/plan.py --run-local` | 退出 0；纯设计/文档车道 |
| 原生 XCUITest | **未跑**：本批只改稿件（`docs/design/**`），不触碰 App 代码 |
| 浏览器逐页走查 / 真实设备 | **均未执行** |
