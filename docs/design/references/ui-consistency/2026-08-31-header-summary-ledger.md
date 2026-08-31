# UI 一致性台账 · 2026-08-31 批次十九（页头摘要扫全 + 自查 F72 的两处欠妥）

> 任务：[UI 稿与实现一致性核对任务](../../ui-consistency-audit-task.md)（TASK-AIN-021）
> 基线：`4150fc8d`
> **批次范围**：把 F72 在 Settings 上发现的缺口推广到全 App 的 `WorkspaceHeaderBar`，
> 并修正 F72 自身留下的两处欠妥。差异登记见
> [审计记录 F73](../../implementation-audit-2026-08-27.md)。
>
> **验证边界**：只改设计稿与 ds 测试，不改 App；无原生 UI 跑动，无设备操作。

## 1. 扫全：八个页头摘要，一处缺锚点

F72 发现 Settings 五个面板副标题稿件全无。同一个共享页头在别处也渲染摘要，故扫全：

| 调用点 | 键 | App 的 `summaryIdentifier` | 稿件（本批前） | verdict |
| --- | --- | --- | --- | --- |
| `SettingsRootView` ×5 | `settings.*.subtitle` | 无 | F72 已补 | `pass`（F72） |
| `TraceWorkspaceView:14` | `trace.workspace.summary` | `trace.workspace.summary` | 有锚点镜像 | `pass` |
| `DebugWorkspaceView:118` | `debug.scope` | `debug.scope` | 有锚点镜像 | `pass` |
| `FlashWorkspaceView:140` | `flash.workspace.subtitle` | **`flash.workspace.title`** | **文案在、无锚点** | `fixed` |

Flash 这条的**键名与标识符不对称**（键是 `.subtitle`、标识符是 `.title`）是 App 侧既有事实，
本批不改 App，稿件按**标识符**对齐——`data-sync-id` 镜像的是 App 给元素的名字，不是键名。

## 2. 自查：F72 自己留下的两处欠妥，本批一并修

**其一，锚点静态不可见。** F72 把五条副标题的锚点写成 `data-sync-id="${s[2]}"`（模板插值）。
渲染后正确，我的 harness 测试也过——但 **`grep 'data-sync-id="settings.storage.subtitle"'`
在稿件里得 0**。而本核对方法大量依赖静态扫描查 P-DRIFT，一个查不到的锚点等于没有对上账。
本批改成逐条写出字面量。新测试的失败信息里写明了这条要求
（`write the id out literally, not interpolated`），免得日后再犯。

**其二，中文被转义成 `\uXXXX`。** F72 用 `json.dumps` 生成文案，把 CJK 写成了 `自定…`，
而稿件其余部分全是字面 CJK。这是人要逐页评审的文件，可读性不该因为生成脚本图省事而降级。
本批全部改回字面 CJK，全文件 `\u5` 命中数 1 → 0。

## 3. 验证

- ds 交互测试 **83/83**（本批新增一条覆盖全部八个页头摘要），`npm run build` exit 0。
- **负向验证**：删掉刚补的 `flash.workspace.title` 锚点再跑，新测试确实变红
  （`must be anchored as flash.workspace.title`）。
- 新测试的清单**从 App 源码正则派生**并断言恰为 8 条：App 新增一个页头摘要会直接打红，
  直到稿件补上；数目变化也会打红，避免正则悄悄少匹配而假绿。
