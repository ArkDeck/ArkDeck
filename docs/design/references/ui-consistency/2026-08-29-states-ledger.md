# UI 一致性台账 · 2026-08-29 批次二（原型状态补齐）

> 任务：[UI 稿与实现一致性核对任务](../../ui-consistency-audit-task.md)（TASK-AIN-021）
> 基线：`98bedbbe`（批次一 PR #1586 合入后的 `origin/main`）
> **批次范围**：F52 第 1 条登记的「实现有、稿不可达」在 **Overview → Flash → Trace →
> Settings** 四个工作区上的部分，共 13 个 surfaceID。其余 49 个 surfaceID 与组件复用腿
> **本批不重核**，继承[批次一台账](2026-08-29-ledger.md)在基线 `17a30972` 上的结论——
> 这四个工作区之外的稿件与 App 代码在 `17a30972…98bedbbe` 之间没有变化（该区间只有本
> 审计自身的 PR #1586）。
> 差异登记见[审计记录 F53](../../implementation-audit-2026-08-27.md)。
>
> **验证边界**：只核对稿与代码。无浏览器逐页走查、无原生 XCUITest、无设备操作；
> 不构成 App 呈现或真机验收，不翻转任何 Golden Journey 状态。

## 1. 本批重核的界面单元（13）

| 对象 | 本批新增可达状态 | verdict | 证据 |
| --- | --- | --- | --- |
| overview.main | 设备：已绑定 / 多目标 picker / 暂无在线设备；来源：已绑定 / 正在读取 / 未绑定 / 需要处理 / 无法读取；记录：可用 / 正在读取 / 无法读取 / 空；调试线分组 + 「显示另外 N 次」；下一步：需要处理 / 空；「再来一次」六分支 disposition；`⌘R` | `fixed` | F53；`Overview reaches every device, build-source and record state the App renders` |
| overview.environment | 披露标题对回 `overview.environment.title`；`⌘⇧D` 既有。仍缺 Selected Device/Binding、Needs Attention 分组与能力矩阵三列 | `fixed` + `registered` | F53（标题）；F53「本批未覆盖」 |
| overview.resume | 未改动；批次一已核为一致 | `pass` | 继承批次一；`Overview copies typed input and thread into a new draft without a Job or authority` |
| overview.hdcImpact | 未改动；批次一已核为一致 | `pass` | 继承批次一 |
| flash.main | checking / noDevice / importing / invalid / failed；每种阻断都零派发；镜像帮助与成功说明对回 App | `fixed` | F53；`Flash reaches checking, missing device, image import and a failed result` |
| flash.plan | 未改动；阶段数与最高 effect 仍由 Catalog 校验 | `pass` | `Flash stage summaries never lower the published maximum effect` |
| flash.runtime | 未改动；失败终态由 flash.main 的结果区承载 | `pass` | 继承批次一；F53 的失败终态断言 |
| trace.capture | 可用性 checking；无已接管目标（`trace.target.empty` + `trace.blocker.target`）；刷新入口；阻断零提交 | `fixed` | F53；`Trace separates availability, capture outcome and the viewable artifact` |
| trace.runtime | 进行中显示 Job ID + 取消；三种终态：抓取完成 / 结果未知 / 抓取已结束但无可查看 Trace | `fixed` | 同上 |
| trace.artifact | 已就绪文件名 / 正在校验并打开 / 校验失败 + 重试打开 | `fixed` | 同上 |
| settings.toolchains | 共享加载 / 失败 / 成功行；运行中任务时的不同说明 | `fixed` | F53；`Settings panes expose the shared loading, error and success rows` |
| settings.storage | 共享三行；校验失败 / 未分类字节 / 用量不可用（且不显示用量数字） | `fixed` | 同上 |
| settings.general / servers / serverEditor / serverDelete / traceCache / traceLicenses / updates / diagnostics | 共享加载 / 失败 / 成功行（八个面板逐个断言） | `fixed` | 同上 |

> 上表最后一行覆盖 `settings.general`、`settings.servers`、`settings.serverEditor`、
> `settings.serverDelete`、`settings.traceCache`、`settings.traceLicenses`、
> `settings.updates`、`settings.diagnostics` 八个 surfaceID 的共享行状态；它们各自的
> 领域内容未改动，结论继承批次一。

## 2. 顺带闭合的批次一登记项

| 登记项 | 处置 | verdict |
| --- | --- | --- |
| F52-2（History / Overview 样本单语的一半） | `when` 与四条 `what` / `detail` 改为语言对，经 `histText()` 解析；Overview 与 History 两处渲染同步。设备原文不译。 | `fixed` |
| F52-1（Overview / Flash / Trace / Settings 部分） | 本批全部补齐，见上表 | `fixed` |

## 3. 本批未覆盖（继续登记）

| 登记项 | 现状 |
| --- | --- |
| F52-1 剩余 | Job 检查器的 Runtime 不可用 / 残留计数 / 临界写入 / current-epoch 关系；Viewer 的 loading / geometryUnavailable / failed 与 footer「未测量」 |
| F52-2 剩余 | Diagnostics 概念页正文与时间轴上按事实生成的 AX 名称仍单语 |
| F52-3 | 信任页缺 Runtime 事实栏 |
| F52-4 / F52-5 | App 侧共享件收敛与 Viewer 检查器硬编码英文——需要 App 改动与原生回归窗口 |
| F52-6~9 | 资源里的已移除路径键、退役 Automation 样式、preview 无构建守护、`Select` 无 class 映射 |
| F52 待裁决三条 | 内容区重复工具栏标题、Viewer 检查器英文保留范围、App 侧 C-DUP 收敛取舍 |
| Overview 环境披露 | Selected Device/Binding 与 Needs Attention 分组、能力矩阵三列 |

## 4. 本批验证

| 检查 | 结果 |
| --- | --- |
| `npm --prefix docs/design/arkdeck-ds test` | **69 项通过，0 失败**（新增 4 项，全部直接与 App 的 `.xcstrings` 比对） |
| `npm --prefix docs/design/arkdeck-ds run build` | 通过；`check:tokens` 每个原型 class 均已分类 |
| `npm --prefix docs/design/arkdeck-ds run build:review` | 通过 |
| 英文页面 CJK 扫描 | 只剩设备原文（Viewer 节点文本）与已登记的 Diagnostics 概念页 |
| 统一本地闸 `scripts/ci/plan.py --run-local` | 退出 0；纯设计/文档车道，不分配 Swift / App 编译车道 |
| 浏览器逐页走查 / 原生 XCUITest / 真实设备 | **均未执行** |
