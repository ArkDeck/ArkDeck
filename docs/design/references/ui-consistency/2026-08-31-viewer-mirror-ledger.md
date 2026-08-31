# UI 一致性台账 · 2026-08-31 批次十四（稿件补齐 Viewer 镜像）

> 任务：[UI 稿与实现一致性核对任务](../../ui-consistency-audit-task.md)（TASK-AIN-021）
> 基线：`5b4b4b9b`
> **批次范围**：F65 明确登记为「需独立一批」的一项——裁决落地后稿件仍缺的六条 Viewer 镜像。
> **纯设计侧**，不触碰 App 代码。差异登记见[审计记录 F67](../../implementation-audit-2026-08-27.md)。
>
> **验证边界**：无原生 UI 跑动（本批不改 App）、无浏览器逐页走查、无设备操作。

## 1. 六条镜像的逐条处置

| # | 对象 | 类别 | 稿件此前 | 本批 | verdict |
| --- | --- | --- | --- | --- | --- |
| 1 | `viewer.properties.selectPrompt` | **状态** | `viewerNode()` 总回退到首个节点，未选中态**不存在** | `?viewerSelection=none` 可达，检查器显示空态 | `fixed` |
| 2 | `viewer.properties.rawUnavailable` | **状态** | Raw 标签总输出 JSON | `?viewerRaw=unavailable` 可达 | `fixed` |
| 3 | `viewer.advancedDump.unavailable` | **状态** | 只有 loading / missingIDs / failed | 新增 `unavailable` 态，与加载、失败分开 | `fixed` |
| 4 | `viewer.advancedDump.search.shortcut` | 名称 | 无 | 搜索框 `title` | `fixed` |
| 5 | `viewer.advancedDump.search.results` | 名称 | 匹配计数无 AX 名称 | `aria-label` | `fixed` |
| 6 | `viewer.advancedDump.search.clear` | **控件 + 名称** | 依赖 `<input type="search">` 的原生清除按钮，**不承载名称** | 与 App 同构的真实按钮，带名称与标识符，仅在有查询时出现 | `fixed` |

第 6 条不只是补名称：原生清除按钮辅助技术读不到，动作集与 App 不对应。新 class
`viewer-advanced-clear` 已加入 `CLASS_TO_COMPONENT`（→ `DumpInspector`）。

## 2. 实测（harness 渲染，中英各一轮）

| 状态 | zh | en |
| --- | --- | --- |
| 未选中 | 选择一个组件 | Select a component |
| Raw 空态 | 原始字段不可用 | Raw fields are unavailable |
| Advanced 未采集 | 选择此标签以采集 componentDetail 字段 | Select this tab to capture componentDetail fields |
| 清除按钮 | 有查询时出现、无查询时不出现 | 同左 |

文案**逐字取自 `.xcstrings`**，不手打——此前两次（`device.trust.step2`、
`device.record.saveFailed`）因手打弯引号导致断言失败。

## 3. 本批自己的两处疏漏（由检查抓到）

| 疏漏 | 抓到方式 | 处置 |
| --- | --- | --- |
| 新 class 只加了映射、没在原型里定义 CSS | `check:tokens` 双向检查报 `mapped to DumpInspector but the prototype no longer defines it` | 补上 `.viewer-advanced-clear` 的样式 |
| 用字符串替换插入 HTML，产生多余且未闭合的 `<span hidden>` | 检视替换产物 | 修正标记 |

第二条值得记：**改 HTML 用文本替换容易破坏结构**，插入后要看实际产物，不能只看替换是否成功。

## 4. 本批验证

| 检查 | 结果 |
| --- | --- |
| `npm --prefix docs/design/arkdeck-ds test` | **81 项通过，0 失败**（新增 1 项） |
| `check:tokens` | 通过，每个原型 class 均已分类 |
| harness 实测 | 中英各三态 + 清除按钮条件显示，全部正确 |
| 统一本地闸 `scripts/ci/plan.py --run-local` | 退出 0；纯设计/文档车道 |
| 原生 XCUITest / 浏览器走查 / 真实设备 | **均未执行**（本批不改 App） |
