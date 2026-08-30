# UI 一致性台账 · 2026-08-30 批次八（字号回到共享刻度，收尾 F52 第 4 条）

> 任务：[UI 稿与实现一致性核对任务](../../ui-consistency-audit-task.md)（TASK-AIN-021）
> 基线：`c222fc69`
> **批次范围**：F52 第 4 条最后一半——73 处 `.font(.system(size:…))` 绕过 `WorkspaceFont`。
> 本批收敛 50 处，保留 23 处（20 处 10pt 按维护者裁决 + 3 处离群字形记 exception）。
> 差异登记见[审计记录 F59](../../implementation-audit-2026-08-27.md)。
>
> **验证边界**：只改字体表达，不改结构、文案、状态或动作。无浏览器走查，无设备操作。

## 1. 逐类处置

| 现写法 | 处置 | 渲染变化 | 处数 | verdict |
| --- | --- | --- | --- | --- |
| `.system(size: 11)` | → `WorkspaceFont.caption` | **无**（11/regular 逐字等值） | 28 | `fixed` |
| `.system(size: 13, weight: .semibold)` | → `WorkspaceFont.sectionTitle` | **无** | 7 | `fixed` |
| `.system(size: 12, design: .monospaced)` | → `WorkspaceFont.monospacedValue` | **无** | 2 | `fixed` |
| `.system(size: 11, design: .monospaced)` | → `WorkspaceFont.monospacedDense` | **无** | 2 | `fixed` |
| `.system(size: 12, weight: .medium)` | → `WorkspaceFont.secondary` | 字重 medium→regular，**变细**；字号不变 | 6 | `fixed`（维护者裁决） |
| `.system(size: 11, weight: .medium)` | → `WorkspaceFont.label` | 字重 medium→semibold，**变粗**；字号不变 | 5 | `fixed`（维护者裁决） |
| `.system(size: 10)` 及其 mono / semibold 变体 | 保留 | 无 | 20 | `exception`（维护者裁决） |
| `.system(size: 9, weight: .semibold)` / `36` / `28, weight: .semibold)` | 保留 | 无 | 3 | `exception` |

分布：`DiagnosticsWorkspaceView` 29 处、`DeviceWorkspaceView` 21 处。

## 2. 两条裁决的理由（写进代码，不只写进台账）

**10pt 保留。** spec §2 最小的非 mono 角色是 secondary 12，`WorkspaceFont` 另补了 label 与
caption 两个 11 的角色，10pt 在两者之下——共享刻度里**没有这一档**。提到 11 会改变采集时间轴、
HiLog 条这些密集表面的布局密度，属产品判断，裁决为保留。理由写在 `WorkspaceFont` 的文档注释
里，一处覆盖全部调用点。

**medium 收敛，尺寸就近优先。** 保持字号、只动字重，对布局影响最小。12pt 只有 `secondary`
一个角色，故变细；11pt 的 `label` 与 `caption` 到 medium 字重等距，按语义选 `label`——那 5 处
全是徽章与「标题 + 10pt 说明」结构，正是 `label`（列头、chip 与装饰）的定位。

## 3. 回归守护（双向）

新增交互测试 `App type sizes that have a shared role use it`：

- **正向**：六种已收敛写法只要在任何 `appViewFiles` 里再出现即失败；
- **反向**：把仍写 `.system(size:)` 的档位按名单锁住（`10` / `10 semibold` / `9 semibold` /
  `36` / `28 semibold`），出现**新的**脱离字号即失败；
- 并断言保留的 10pt 一档规模不变（19 处 bare 与 mono），以及共享词表里那段说明 10pt 为何
  留在刻度外的注释仍在。

## 4. 本批验证

| 检查 | 结果 |
| --- | --- |
| `npm --prefix docs/design/arkdeck-ds test` | **77 项通过，0 失败**（新增 1 项） |
| App 编译 `build-for-testing` | **通过**（exit 0） |
| 原生定向复核（Diagnostics 表面） | **失败**，但**在未改动 `main` 上以相同消息与相同几何复现**——既有缺陷，非本批引入（见下） |
| 统一本地闸 `scripts/ci/plan.py --run-local` | 退出 0；App 编译车道 `build-for-testing` 通过 |
| 浏览器逐页走查 / 真实设备 | **均未执行** |

## 5. 复核结论与那条既有失败

负载 4.25 时取得有效 run（七条有效性信号均为 0）。
`testDiagnosticsReadsPublishedSessionAndGlobalLogWithoutInventingAlignment` 失败于
`Unable to find hit point for ScrollView, {{252.0, 441.0}, {648.0, 0.0}}`；随即在**干净 `main`
同一 commit** 上重跑，**同一条消息、同一组几何**，同样零有效性信号。

**这条对本批是正面证据**：改了 29 处字号的 Diagnostics 工作区，其失败几何与未改动版本逐字
相同，说明 39 处等值替换确实没有改变渲染尺寸。

**根因指向共享 helper，不是产品**：该宿主高度为 0。`AppShellUITests.scrollIntoView` 挑宿主的
判据只有「宽度非零且横向包含目标 x，取面积最小者」，**没有要求宿主可命中**，所以高度 0 的
容器会被选中。F58 里另一处同族失败的宿主则在屏外（x=1647，超出本机逻辑宽度）。
两处指向同一个缺口。**本批不改该 helper**——它有八处调用点，改动需要独立一批与足够的重复
运行来确认不引入新的不稳定。已在审计记录登记。

**本批因此不主张把这条测试修绿**，只主张：字号收敛未引入任何回归。

## 6. 前三次无效运行（不计入结论）

| 次序 | 无效信号 | 处置 |
| --- | --- | --- |
| 一 | `Timed out while enabling automation mode`（用了 `--no-build`，该模式按脚本注释会跳过陈旧 runner 清理） | 去掉该参数重跑 |
| 二、三 | `The test runner hung before establishing connection` | 查到本机 1 分钟负载 14.7–16.0；该负载下 runner 握手必然超时。改为**等负载降到 6 以下再跑**，4.25 时一次取得有效 run |

`runner hung` 一族由此成为有效性判据的第七条（脚本头注释已载明它属 runner 启动面，不是测试失败）。