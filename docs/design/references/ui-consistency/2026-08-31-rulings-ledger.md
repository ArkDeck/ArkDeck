# UI 一致性台账 · 2026-08-31 批次十二（两条待裁决落地）

> 任务：[UI 稿与实现一致性核对任务](../../ui-consistency-audit-task.md)（TASK-AIN-021）
> 基线：`ea5776f2`
> **批次范围**：维护者的两条结论——①内容区不允许重复工具栏页面标题；②Viewer 空态和搜索
> 控件走目录。差异登记见[审计记录 F65](../../implementation-audit-2026-08-27.md)。
>
> **验证边界**：本批同时触碰 `ArkDeckApp/**`、`ArkDeckAppUITests/**` 与 `docs/design/**`。
> 无浏览器逐页走查，无设备操作。

## 1. 对 F52 第 5 条的更正（先说不实之处）

F52-5 写「`UIDumpLocalizable.xcstrings` 里这些键都有中文译文且无人引用」并列了六条。实测：

| 该条列举的文案 | 目录里是否有键 | 实情 |
| --- | --- | --- |
| `Select a component` | ✅ `viewer.properties.selectPrompt` | 属实 |
| `Raw fields are unavailable` | ✅ `viewer.properties.rawUnavailable` | 属实 |
| `Retry` | ❌ | **无键** |
| `Search fields or values` | ❌ | **无键** |
| `Clear search` | ❌ | **无键** |
| `No matching fields or values` | ❌ | **无键** |

**六条里四条不实。** 落地裁决 ② 因此不是「接上已有译文」，而是**新增键并新译**：本批新增
7 条 `viewer.advancedDump.*`，中英成对。原记述保留不改写，以此更正为准。

## 2. 裁决 ②：逐条分类与对抗复核

对 `ViewerInspectorCopy` 的 34 个成员按**渲染点**分类（不按名字猜），每条非 english 的判断
再交一轮对抗复核，复核方被明确要求「裁决措辞未覆盖就驳回」。

| verdict | 数量 | 成员 |
| --- | --- | --- |
| **走目录** | 9 | 空态：`selectPrompt`、`rawUnavailable`、`advancedUnavailable`；搜索控件：`advancedSearch`、`…Placeholder`、`…Shortcut`、`…Results`、`…Clear`、`…NoResults` |
| 保持英文 | 23 | 5 个 tab 名、6 个分组名、4 个字段名、2 个 chip、4 个值（`Yes`/`No`/`Available`/`Verified`）、`show(_:)`、`retry` 等 |
| **复核驳回** | 2 | `advancedLoading`（加载态）、`advancedIdentifiersUnavailable`（失败原因） |

**驳回的理由值得留痕**：裁决只说「空态和搜索控件」。项目自己的台账一贯把**加载态**与**空态**
分列（见 2026-08-29 两份台账），而失败原因与空态也是两回事；且同一通道上另一条失败文案本就是
Provider 透传或硬编码英文，只译这一条会让同一行有时中文有时英文。**措辞没覆盖，就不动。**

同理，`retry`（失败分支的恢复动作）、`show(_:)`（动作）、`Yes`/`No`（技术字段列表里的值）
均保持英文。这条边界写进了 `ViewerInspectorCopy` 的类型注释。

## 3. 裁决 ①：不能一刀切

`DiagnosticsWorkspaceView` 的标题是三元表达式：

| 上下文 | 显示 | 与工具栏 | 处置 |
| --- | --- | --- | --- |
| HiLog 摘要 | `diagnostics.hilog.title` | **不同名** | **保留** |
| 普通 | `diagnostics.title` | **同名** | **删除** |

改为只在 HiLog 上下文渲染。稿件侧 `pDiagnostics()` 的字面 `<b>Diagnostics</b>` 一并删除
（该页第 3063 行已用 `data-page-title="Diagnostics"` 声明页面标题，3064 行是重复）。

**连带死键**：`diagnostics.title` 随之无人引用（窗口标题走导航项的 `localizationKey`），已删。
`settings.*.title` 四条此前正是**因这条裁决未决**才在 F60 保留，现确认死键，一并删除。

## 4. UI 断言：一条须改，其余不受影响

| 断言 | 处置 |
| --- | --- |
| `AppShellUITests.swift:622` `assertDisplayed(app.staticTexts["diagnostics.workspace.title"], equals: "Diagnostics")` | **改为断言该元素不存在**——它钉住的正是被裁决判为违规的行为 |
| 其余 20 处 Viewer/Advanced Dump 相关断言 | **不受影响**：一律按 accessibility identifier 查询，不依赖文案，故文案中文化不会打红 |

这一点是本批动手前专门扫过的：如果有测试在 zh-Hans 启动下断言那些英文串，改文案就会连带打红。
实测为零。

## 5. 稿件侧：已渲染的三条双语化，其余登记

稿件的 Advanced Dump 区此前把搜索控件写死英文。本批把**稿件里已经渲染**的三条改为双语，
取值**逐字读自 App 目录**（不手打——此前两次因手打弯引号出错）：

| 稿件文案 | 处置 |
| --- | --- |
| 搜索框 `aria-label`（Search Advanced Dump） | `viewerCopy("viewer.advancedDump.search")` |
| 搜索框 `placeholder`（Search fields or values） | `viewerCopy("viewer.advancedDump.search.placeholder")` |
| 无结果（No matching fields or values） | `viewerCopy("viewer.advancedDump.search.noResults")` |

**本批未覆盖、已登记**：稿件缺 `selectPrompt`、`rawUnavailable`、`advancedUnavailable` 三个空态
与 `search.clear` / `search.results` / `search.shortcut` 三个搜索辅助控件的镜像（勘察结果：
稿件侧 6 条 absent）。补齐需要在稿件里新建这些状态与控件，属独立一批。

## 6. 回归

`localization catalogs carry no keys for paths the App no longer renders` 随裁决落地更新：

- `SettingsLocalizable` 的无引用键断言由「4 条」改为 **`[]`**；
- `UIDumpLocalizable` 由「25 条」改为 **23 条**，并断言 `selectPrompt` / `rawUnavailable`
  **已被引用**；
- 新增一条：**每一条仍被保留的 Viewer 键都必须匹配 `viewer.(tab|group|field|chip|value|action|tree).`**
  ——保证「保留英文」的集合里藏不进任何空态或搜索控件。

## 7. 本批验证

| 检查 | 结果 |
| --- | --- |
| `npm --prefix docs/design/arkdeck-ds test` | **80 项通过，0 失败** |
| App 编译 `build-for-testing` | **通过**（exit 0，0 error） |
| 原生定向复核 · `ViewerUITests` 全类 | **通过**（含性能断言，见第 8 节） |
| 原生定向复核 · `testEnglishSweepOfEveryWorkspace` | **失败**，但**在未改动 `main` 上以相同消息复现**（两样本），既有缺陷，非本批引入 |
| 统一本地闸 `scripts/ci/plan.py --run-local` | 退出 0 |
| 浏览器逐页走查 / 真实设备 | **均未执行** |

## 8. 复核过程中本批自己引入又修掉的两个回归

原生跑动抓到两处**编译与设计测试都发现不了**的问题，两处都是我改的：

| 回归 | 症状 | 根因 | 修法 |
| --- | --- | --- | --- |
| 性能 | `typing a field query must not block on rebuilding hundreds of rows`：实测 **3.71s**，上限 2.0s | 把九条文案改成 `static var { viewerText(...) }`，**每次访问都查 Bundle**；而 Advanced Dump 搜索每敲一个字符重建数百行，正是热路径 | 改回 `static let`（lazy、只求值一次）。语言由启动参数固定，进程内不变，一次解析即正确。理由写进类型注释 |
| 时序 | — | 把 `assertDisplayed`（**会等待**）换成 `XCTAssertFalse(...exists)`（立即返回），顺手删掉了一个隐式同步点 | 先 `waitForExistenceFast` 等该页自己的内容到位，再断言重复标题不存在 |

第二条的修复**没有**解决当时观察到的 Debug 面板失败——那是另一回事（见第 9 节）。但这个写法本身更严谨，予以保留：紧跟导航之后的否定断言不该无等待。

## 9. `testEnglishSweepOfEveryWorkspace` 的归因（五个样本）

该测试在本批分支上失败，且失败点在两处之间摇摆。逐样本比对后判为**既有缺陷**：

| 运行 | 代码 | 失败点 |
| --- | --- | --- |
| 本批 ×4 | 分支 | 3 次 `:699`（`sweep` 内 Debug 面板，`file:line` 报在调用点）、1 次 `:1796` snapshot |
| **干净 `main` ×3** | `main` | 1 次 `:1793` snapshot、**2 次 `:699` Debug 面板，消息与本批逐字相同** |

`:1793` 与 `:1796` 是同一处——本批改测试文件多出 3 行。**两侧在同样的两个位置之间摇摆，消息一致，全部样本有效性信号为 0。** 因此本批不引入新失败，也不为该测试转绿负责。

**归因方法留痕**：先在干净 `main` 上取样本，而不是因为「我没碰 Debug 工作区」就推给既有。这一判断被今晚两次打脸校正过——上表两个回归当初都「看起来不是我的」。另外先排除了文案原因：Debug 面板标题来自 `DebugLocalizable`，本批的资源改动只涉及 Diagnostics / Settings / UIDump 三个目录。
