# UI 一致性台账 · 2026-08-31 批次十八（#1644 增量轮：Settings 面板副标题与未识别 Session）

> 任务：[UI 稿与实现一致性核对任务](../../ui-consistency-audit-task.md)（TASK-AIN-021）
> 基线：`c745a248`
> **批次范围**：`#1644`（Settings 存储面板改造）触发的增量轮。差异登记见
> [审计记录 F72](../../implementation-audit-2026-08-27.md)。
>
> **验证边界**：只改设计稿与 ds 测试，不改 App、Runtime、Catalog 或准入策略；
> 无原生 UI 跑动，无设备操作。

## 1. 增量轮的触发与范围

`#1644` 动了 `SettingsRootView.swift` + `SettingsLocalizable.xcstrings` + `prototype.html`：
把一个无标签的用量数字拆成「Runtime Artifact」与「Session 输出根」两块存储。
**它自己已经镜像了主结构**，因此本轮不是补它漏掉的主体，而是核对它的镜像是否完整。
逐条比对删/增键与稿件的结果如下。

## 2. 逐条比对

| 键 | App | 稿件（`#1644` 后） | verdict |
| --- | --- | --- | --- |
| `settings.storage.runtimeUnavailable` | 渲染 | 有锚点镜像 | `pass` |
| `settings.storage.runtimeUsage` / `.detail` | 渲染 | 有锚点镜像 | `pass` |
| `settings.storage.sessionUsage` / `.detail` | 渲染 | 有锚点镜像 | `pass` |
| `settings.storage.runtimeTotal` | `settingsFact(...)` 标签 | **文案在、无 `data-sync-id`** | `fixed` |
| `settings.storage.remaining` | `settingsFact(...)` 标签 | **文案在、无 `data-sync-id`** | `fixed` |
| `settings.storage.unaccountedFormat` | `unaccountedSessionCount > 0` 时渲染警告 | **完全缺失，状态不可达** | `fixed` |
| 已删的 `settings.common.unknown` / `storage.admission*` / `storage.usage` | 已删 | 稿件零残留 | `pass` |

## 3. 顺带查出的系统性缺口：五个面板副标题稿件全无

比对 `settings.storage.subtitle` 时发现稿件里根本没有面板副标题结构，于是把范围扩到全部：

| 键 | App 渲染处 | 稿件（本批前） |
| --- | --- | --- |
| `settings.general.subtitle` | `SettingsRootView.swift:90` | 无 |
| `settings.remoteSources.subtitle` | `:130` | 无 |
| `settings.toolchains.subtitle` | `:669` | 无 |
| `settings.storage.subtitle` | `:800` | 无 |
| `settings.diagnostics.subtitle` | `:1040` | 无 |

五条全部经 `WorkspaceHeaderBar(summary:)` 真实渲染，稿件五条全缺 —— 按 §6 属 **P-DRIFT
（实现有、稿无）**，且**不是 `#1644` 引入的**，是此前各轮都没抓到的既有缺口。
本批在 `settingsPane()` 里按 App 的同一位置补齐，文案逐字取自 `.xcstrings`。

稿件有而 App 没有的两个页签（`trace` / `updates`）不配副标题——它们没有对应的 App 面板，
不为它们编造文案。

## 4. 一次差点发生的误判

`settings.storage.unaccountedFormat` 用 `git grep` 扫 Swift **零命中**，看起来是 `#1644`
顺手加进目录的死键。追下去才发现它经**生成符号**被消费：
`LocalizedStringResource.SettingsLocalizable.settingsStorageUnaccountedFormat(...)`
（`SettingsRootView.swift:1005`）。我的快扫用了 `storageUnaccounted` 作模式，漏掉了
`settings` 前缀。**救回来的是 F60/F70 定的 camelCase 访问器判据**——字面量扫描单独不足以判死
一个键，这次是它把「死键」纠正成「活键且稿件缺镜像」，结论正好相反。

## 5. 验证

- ds 交互测试 **82/82**（新增一条），`npm run build`（含双向 `check:tokens`）exit 0。
- **负向验证**：把稿件回退到 `origin/main` 再跑，新测试确实变红
  （`must carry its App summary word for word`），不是只对当前实现成立的套套逻辑。
- 新测试的面板清单**从 App 源码正则派生**（扫 `WorkspaceHeaderBar(summary: Text(settingsText("…")))`），
  不是写死在测试里：App 将来新增带副标题的面板会直接打红，直到稿件补上。
