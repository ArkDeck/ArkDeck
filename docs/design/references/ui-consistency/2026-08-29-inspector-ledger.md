# UI 一致性台账 · 2026-08-29 批次三（Job 检查器 + Viewer + Overview 环境披露）

> 任务：[UI 稿与实现一致性核对任务](../../ui-consistency-audit-task.md)（TASK-AIN-021）
> 基线：`93b24ae3`（批次二 PR #1587 合入后的 `origin/main`）
> **批次范围**：F52 第 1 条在 `shell.inspector`、`viewer.main`、`overview.environment`
> 三个 surfaceID 上的剩余部分。其余 59 个 surfaceID 与组件复用腿**本批不重核**，继承
> [批次一台账](2026-08-29-ledger.md)（基线 `17a30972`）与
> [批次二台账](2026-08-29-states-ledger.md)（基线 `98bedbbe`）的结论——
> `17a30972…93b24ae3` 之间只有本审计自身的 PR #1586 与 #1587，未触及其余表面的
> App 代码，稿件改动都已在各自台账内记录。
> 差异登记见[审计记录 F54](../../implementation-audit-2026-08-27.md)。
>
> **验证边界**：只核对稿与代码。无浏览器逐页走查、无原生 XCUITest、无设备操作；
> 不构成 App 呈现或真机验收，不翻转任何 Golden Journey 状态。

## 1. 本批重核的界面单元（3）

| 对象 | 本批新增可达状态 | verdict | 证据 |
| --- | --- | --- | --- |
| shell.inspector | `job.list` 可用性三态：正在刷新 / Runtime 不可用（含 reason code 与指引）/ Runtime 可访问但无 Job；折叠条同步这三种摘要并补进行中计数与已运行时间；逐 Job 补残留计数（列表紧凑徽标 + 详情整句）、临界写入提示、established-current-epoch 关系（换状态标签、给恢复关系 ID、保留原始记录状态、撤下未知警告与取消） | `fixed` | F54；`the Job inspector separates an unreachable Runtime from an empty archive` |
| viewer.main | 历史 capture 加载态；空态两种原因（未选目标 / 目标不可抓取）＋抓取失败原因；坐标系无法证明（页头标注 + 页脚说明 + **不渲染命中区**）；截图不可解码；页脚「未测量」；树搜索无匹配且选中不变 | `fixed` | F54；`Viewer refuses to map a screenshot it cannot place, and says when nothing was measured` |
| overview.environment | 按 `HDCStatusView` 重建为四组＋高级诊断：服务器与工具链（九个具名字段 + 选择 HDC）、能力（归属 / 子服务器 / 服务器恢复 + 三列能力矩阵）、所选设备与通道（授权 / 通道保护 / 近期设备事件）、需处理事项（无事项说明或逐条事项＋原因＋最小下一步）、高级诊断（只保留影响预览）；能力矩阵补探测中与探测不可读两态 | `fixed` | F54；`Overview environment keeps the App five groups and its capability matrix states` |

## 2. 本批闭合的登记项

| 登记项 | 处置 | verdict |
| --- | --- | --- |
| F52-1：Job 检查器的 Runtime 不可用、残留计数、临界写入提示、established-current-epoch 关系 | 全部补齐 | `fixed` |
| F52-1：Viewer 的 loading / geometryUnavailable / failed 与 footer「未测量」 | 全部补齐，另补两种空态原因、截图不可用与搜索无匹配 | `fixed` |
| 批次二登记：Overview 环境披露缺 Selected Device/Binding 与 Needs Attention 分组、能力矩阵三列 | 全部补齐 | `fixed` |

**F52 第 1 条至此全部闭合。**

## 3. 本批未覆盖（继续登记）

| 登记项 | 现状 |
| --- | --- |
| F52-2 剩余 | Diagnostics 概念页正文与时间轴上按事实生成的 AX 名称仍单语 |
| F52-3 | 信任页缺 Runtime 事实栏（spec §5.2 要求接管引导在同一详情中） |
| F52-4 | App 侧 `deviceNotice`、Settings 四个副本、19 处手写 `Grid(`、两个 workspace 绕过 `WorkspaceFont`/`WorkspaceMetrics`、`RuntimeExecutionModeBadge` 放置 |
| F52-5 | `ViewerInspectorCopy` 硬编码英文，而目录里的中文键无人引用 |
| F52-6~9 | 资源里的已移除路径键、退役 Automation 样式、preview 无构建守护、`Select` 无 class 映射 |
| F52 待裁决三条 | 内容区重复工具栏标题、Viewer 检查器英文保留范围、App 侧 C-DUP 收敛取舍 |

## 4. 本批验证

| 检查 | 结果 |
| --- | --- |
| `npm --prefix docs/design/arkdeck-ds test` | **72 项通过，0 失败**（新增 3 项，全部直接与 App 的 `.xcstrings` 比对） |
| `npm --prefix docs/design/arkdeck-ds run build` | 通过；`check:tokens` 每个原型 class 均已分类 |
| `npm --prefix docs/design/arkdeck-ds run build:review` | 通过 |
| 英文页面 CJK 扫描 | 只剩设备原文（Viewer 节点文本）与已登记的 Diagnostics 概念页 |
| 统一本地闸 `scripts/ci/plan.py --run-local` | 退出 0；纯设计/文档车道，不分配 Swift / App 编译车道 |
| 浏览器逐页走查 / 原生 XCUITest / 真实设备 | **均未执行** |
