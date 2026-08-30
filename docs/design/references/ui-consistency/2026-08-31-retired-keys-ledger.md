# UI 一致性台账 · 2026-08-31 批次九（清掉已移除路径的本地化键）

> 任务：[UI 稿与实现一致性核对任务](../../ui-consistency-audit-task.md)（TASK-AIN-021）
> 基线：`b056126d`
> **批次范围**：F52 第 6 条。差异登记见[审计记录 F60](../../implementation-audit-2026-08-27.md)。
>
> **验证边界**：只删资源键，不改任何 Swift 逻辑、不改文案内容、不改设计稿。
> 无浏览器走查，无原生 UI 跑动（本批不触碰任何渲染路径），无设备操作。

## 1. 判据：静态可达性单独不足以判死一个键

App 有两类**静态扫描抓不到**的引用：

| 形态 | 实例 | 影响 |
| --- | --- | --- |
| 变量查表 | `Text(LocalizedStringKey(serverHealthKey))`、`field(_ titleKey: String, …)`、`Text(LocalizedStringKey(item.nextStepKey))`，全仓 20 余处 | 键从 switch 返回值来，键名只以字面量出现在那个 switch 里 |
| 插值构造 | `"debug.tab.\(tabID)"`、`"job.state.\(state.rawValue)"` | 整个前缀族都可能被动态命中 |

因此判据取三条并集：**字面量出现** ∪ **camelCase 访问器被使用** ∪ **任一插值前缀是该键前缀**。
按此测得的每目录无引用数与 F52-6 登记逐一吻合（Debug 11 / Diagnostics 13 / Flash 29 /
History 6 / Settings 4 = 63），**由此确认登记的 63 条正确，而我批次六期间粗扫得到的 224 条
是误报上界**。

## 2. 逐目录处置

| 目录 | 无引用 | 本批处置 | verdict |
| --- | --- | --- | --- |
| `DebugLocalizable` | 11 | 全删（含 `debug.apps.install.fresh`、`debug.apps.cleanup.restore`，F26 后策略固定不再渲染） | `fixed` |
| `DiagnosticsLocalizable` | 13 | 全删（`diagnostics.capture.*` 交互式采集会话已退役） | `fixed` |
| `FlashLocalizable` | 29 | 全删（旧审阅页 `flash.action.*` / `flash.execute.*` / `flash.disposition.*`） | `fixed` |
| `HistoryLocalizable` | 6 | 全删（`history.column.*` 表列标题，F38/F39 后表格已改） | `fixed` |
| `SettingsLocalizable` | 4 | **保留**：`settings.{general,storage,toolchains,diagnostics}.title` 是面板标题键，与**待裁决第 1 条**（内容区是否允许重复工具栏页面标题）直接相关，裁决为允许则要复用 | `registered` |
| `UIDumpLocalizable` | 25 | **保留**：`viewer.tab/group/field/value/properties.*`，正是 F52 第 5 条所指；**待裁决第 2 条**若定为「空态/动作/搜索控件走目录」，这些正是要接上的键 | `registered` |
| `Localizable` / `Jobs` / `Device` | 24 / 1 / 1 | **保留**：本轮新发现，未经首轮那样的逐条核实 | `registered` |

合计删除 **59 条**，保留 **55 条**（4 + 25 + 26）。

## 3. 一个必须追到消费方才能判的例子

`overview.status.server` 看似无引用，且与 UI 测试使用的**可访问性标识符**
`overview.status.server.value` 同名前缀——很容易据此误判为「在用」或「已废」。追到消费方：
`HDCStatusView` 渲染的是 `Text(LocalizedStringKey(serverHealthKey))`，而
`serverHealthKey` 的 switch 返回的是 `overview.serverHealth.healthy/unavailable/unknown`。
**标识符与本地化键同名前缀，但不是同一个东西。** 故该键确实无人渲染，但仍归入第 2 节的
「本轮新发现、未核实」一档，不在本批删除。

## 4. 删除方式与格式安全

首次尝试用 `json.dumps` 重写文件，产生 **9970 行插入 / 1085 行删除**——因为改动了键序与缩进。
**已回退**，改为按文本块精确删除（花括号配对定位，连同块后逗号一并移除），其余字节不动：

- 四个目录里 Debug / Flash / History 是**紧凑单行**格式（最长行 921 字符），Diagnostics 是
  **展开**格式；文本块删除对两者都适用；
- 结果是**纯删除 267 行、零插入**；
- 每个文件删后校验：仍是合法 JSON、键数等于原数减去删除数、目标键确已不在。

## 5. 回归守护

新增交互测试 `localization catalogs carry no keys for paths the App no longer renders`，
在测试侧复现同一套三条并集判据：

- 四个已清理目录若再出现无引用键 → 失败；
- `UIDumpLocalizable` 的 25 条与 `SettingsLocalizable` 的 4 条**按数量钉住**——清理往前多走一步
  或裁决落地后忘了跟进，都会失败。

## 6. 本批验证

| 检查 | 结果 |
| --- | --- |
| `npm --prefix docs/design/arkdeck-ds test` | **78 项通过，0 失败**（新增 1 项） |
| App 编译 | **通过**（exit 0，无本地化相关错误或告警） |
| 统一本地闸 `scripts/ci/plan.py --run-local` | 退出 0 |
| 原生 XCUITest | **未跑**：本批不触碰任何渲染路径，只删无引用资源键；删除正确性由上述回归与编译守护 |
| 浏览器逐页走查 / 真实设备 | **均未执行** |
