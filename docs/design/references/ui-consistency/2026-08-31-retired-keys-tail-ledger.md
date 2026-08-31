# UI 一致性台账 · 2026-08-31 批次十六（结清 F60 保留的最后 25 条无引用键）

> 任务：[UI 稿与实现一致性核对任务](../../ui-consistency-audit-task.md)（TASK-AIN-021）
> 基线：`e94c575b`
> **批次范围**：F60 台账第 2 节最后一行（`Localizable` / `Jobs` / `Device`，当时记 24 / 1 / 1，
> verdict `registered`，理由是「本轮新发现，未经首轮那样的逐条核实」）。
> 差异登记见[审计记录 F70](../../implementation-audit-2026-08-27.md)。
>
> **验证边界**：只删资源键，不改任何 Swift 逻辑、不改文案内容、不改设计稿。
> 无浏览器走查，无原生 UI 跑动，无设备操作。

## 1. 判据比 F60 多一条

沿用 F60 的三判据并集（**字面量出现** ∪ **camelCase 访问器被使用** ∪ **任一插值前缀是该键前缀**），
并补上它没覆盖的第四种形态：**字符串拼接构造**（`"prefix." + variable`）。
全 App 扫描该形态**零命中**，故三判据在本仓当前状态下无缺口——但这一条现在写进台账，
以后重跑不必再重新发现。

复扫结果：`Localizable` 24 / `JobsLocalizable` 1 / `DeviceLocalizable` **0**。
F60 记的 Device 那 1 条已在此后的批次里被消费掉，本批不再需要处理。

## 2. 逐条核实（25 条，全部追到消费方）

| 键族 | 条数 | 追到的消费方 | 结论 | verdict |
| --- | --- | --- | --- | --- |
| `overview.status.{server,trust,channel,needsAttention}` | 4 | `HDCStatusView.swift:141-151` 只渲染**值**（`Text(LocalizedStringKey(serverHealthKey))` 等，键来自 `overview.serverHealth.*` / `overview.trustSummary.*` 的 switch），四个同名前缀只作为**可访问性标识符** `overview.status.X.value` 出现 | 旧表格布局的行标签；现布局是 `·` 分隔的单行，无标签 | `fixed` |
| `overview.record.empty.{title,description,run,thread,artifact}` | 5 | 空态实际渲染 `overview.record.recent.empty`（`OverviewRecordView.swift:424`）；`overview.record.empty` 仅为该处的可访问性标识符 | 旧的「标题＋说明＋三条 Runtime 记账说明」富空态已被单行替代 | `fixed` |
| `overview.record.action.{flash,trace,uiDump,debugHAP,device}` | 5 | 全仓零引用（含插值与拼接） | 旧的「按记录类型给动作标签」已不存在 | `fixed` |
| `overview.record.availability.{available,limited,notProbed,unavailable}` | 4 | 全仓零引用 | 同上族，可用性以别的方式呈现 | `fixed` |
| `overview.record.recent.rules` | 1 | 全仓零引用 | 重放规则的长段说明，现由授权闸自身承担 | `fixed` |
| `history.column.{job,operation,state}` | 3 | 全仓零引用 | 与 F60 已删的 `HistoryLocalizable` 六条 `history.column.*` 同族，F38/F39 改表后的残留 | `fixed` |
| `app.unavailable.{reason,noOperationSubmitted}` | 2 | 全仓零引用 | 「本构建未接 Runtime」的旧兜底文案 | `fixed` |
| `jobInspector.readOnly` | 1 | 全仓零引用（`readOnly` 的命中全是 Flash 的 `flash.effect.readOnly`，不同键） | 旧检查器只读标注 | `fixed` |

## 3. 稿件侧对照：删键不掩盖任何 P-DRIFT

判死一个键说明 **App 不渲染它**；如果**稿件仍画着它**，那是「稿有、实现无」，
删键不能代替登记。因此对每条的英文原值回稿件与 spec 核对：

| 文案 | 稿件命中 | 结论 |
| --- | --- | --- |
| `No runs recorded yet` / `not a log written afterwards` / `Every thread` | 0 | 稿件的空态是 `overview.record.recent.empty`，与 App **逐字一致**（`No recent runs yet. Start from a workflow in the sidebar.`）；旧富空态两侧都没有 |
| `re-enters its authorization gate`（重放规则长段） | 0 | 两侧均无 |
| `Device Trust` / `Not probed` / `Read-only Runtime facts` / `No operation was submitted` | 0 | 两侧均无 |
| `Needs Attention` | 1 | **不是同一个东西**：命中的是 `overview.section.needsAttention`（分区标题，两侧都在，spec §141 要求的也是它），不是状态行标签 `overview.status.needsAttention` |

**结论：25 条全部是两侧都已不存在的呈现，删除不掩盖任何差异，本批不产生新的 P-DRIFT。**

## 4. 编辑手法

`.xcstrings` 用**花括号匹配的文本块删除**，不用 `json.dumps` 重写——后者会重排整个文件
（F60 期间实测产生 9970 行插入）。本批 diff 为 **0 插入 / 400 删除**，删后 `json.load` 合法、
条数分别为 255（279−24）与 70（71−1）。`JobsLocalizable` 是单行紧凑格式、`Localizable` 是
多行缩进格式，锚点只认 `"key": {` 再靠花括号匹配定界，两种格式通吃。

## 5. 至此 F60 的保留项全部结清

| F60 保留 | 结清于 |
| --- | --- |
| `SettingsLocalizable` 4 条 | F65（裁决第 1 条定为「内容区不允许重复工具栏标题」→ 确认为死键并删除） |
| `UIDumpLocalizable` 25 条 | F65 / F67（裁决第 2 条定为「空态与搜索控件走目录」→ 接上其中若干，其余保留并由回归钉住 23 条） |
| `Localizable` / `Jobs` / `Device` 26 条 | **本批**（实为 25 条，Device 那条已被消费） |
