# Viewer UI 实现交接任务（TASK-AIN-021）

> 类型：产品实现 brief，不是新的 OpenSpec Task、Readiness Task 或批准载体。
>
> 归属：复用 protected `main` 已存在的 `TASK-AIN-021`。本文件不改变该 Task
> 的状态、Acceptance、Allowed paths，也不修改设计稿版本号。
>
> 2026-08-25 状态：本实现任务已闭合。本文件第 3 节以后保留为历史实现与验收上下文，
> 不是当前产品差距清单。当前 SwiftUI 实现及其本地化、accessibility identifiers 是产品
> 表面的事实源；可交互原型、交互规范、brief 和设计系统组件必须与它同车同步，不得反向
> 要求实现恢复旧稿。

## 1. 交付目标

把当前 App 中以 Window inventory、Recipe、Debug parameter policy 和 Review 表单为主的
`UIDumpWorkspaceView`，替换为可实际抓取并检查 ArkUI 节点的 `Viewer`：

1. 左侧显示当前抓取的设备截图，所有具有有效 bounds 的节点都能从截图选择；
2. 右侧上方显示完整、可展开、可双向滚动的 UI 树；
3. 右侧下方显示当前选中节点的完整属性；
4. 截图、树和属性共用一个 selection identity，任一入口选择后其余两处同步；
5. 截图和树只使用同一 Runtime Job 产生、且通过元数据和内容校验的 Artifact；
6. 导航、页面标题和用户可见任务名统一使用 `Viewer`，不增加 `ArkUI` 前缀。

本任务推进 GJ-1 Device Observe 与 GJ-2 HAP Debug 中的 UI Dump 可观察闭环。它只改变
App/facade 投影和必要测试，不发布新 operation/provider/profile，也不改变 Runtime
admission 或设备命令 lowering。

## 2. 当前事实源与设计镜像

- 当前 App 入口（产品表面事实源）：
  `ArkDeckApp/Features/UIDump/UIDumpWorkspaceView.swift`
- 当前本地化与 accessibility identifiers（用户可见文案和同步锚点）：
  `ArkDeckApp/Resources/UIDumpLocalizable.xcstrings`
- 可交互设计镜像：[`prototype.html?page=dump`](prototype.html?page=dump)，已抓取态使用
  [`prototype.html?page=dump&viewerState=captured`](prototype.html?page=dump&viewerState=captured)
- 交互规范：[`macos-ux-interaction-spec.md` §5.3](macos-ux-interaction-spec.md#53-viewer)
- 设计交接 brief：[`design-agent-briefs.md` §5.3](design-agent-briefs.md#53-viewer)
- 设计系统实现：
  [`viewer.tsx`](arkdeck-ds/src/components/viewer.tsx) 中的
  `ViewerWorkspace`、`ViewerScreenshot`、`ViewerInspectorStack`、
  `ComponentTree` 与 `DumpInspector`
- 当前生产 facade：
  `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/UIDumpApplicationFacade.swift`
- 当前发布 Operation：
  `Catalog/operations/capture.diagnostics.v1.json` 的 `capture.diagnostics@1`
- 可复用 Artifact 读取实现：
  `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RuntimeHistoryApplicationFacade.swift`

SwiftUI 与本地化描述当前产品表面，视觉稿镜像它；Catalog、contracts、Runtime 返回事实和
仓库安全不变量决定生产行为。两者不一致时先把设计镜像同步到实现，不得在 App 中伪造能力，
也不得在视觉稿中保留已经移除的路径。

## 3. 历史实现差距（已关闭）

当前 `UIDumpApplicationFacade` 只读取 `operation.list`、`target.list` 和最近的 `job.list`；
当前 `UIDumpWorkspaceView` 仍展示四种历史 Recipe、候选参数和 disabled run action。它没有：

- 提交并运行 `capture.diagnostics@1` 的生产路径；
- 从同一 Job 列举并读取 `screenshot.png`、`ui-tree.json` 和 `ui-dump.json`；
- ArkUI tree/raw dump 的前向兼容解析，以及 Raw dump 的无损字段保留；
- 截图 bounds 命中、树选择与属性检查器的统一 selection model；
- Artifact 缺失、时代不一致、hash 漂移、内容损坏或 unknown outcome 的 fail-closed UI。

## 4. 生产数据流

### 4.1 抓取

“重新抓取”必须通过现有 Agent XPC 提交 typed request：

```text
Viewer UI
  -> job.submit(RuntimeOperationRequest)
     operation = capture.diagnostics@1
     target = selected targetId + expectedBindingRevision
     inputs = bounded typed inputs
  -> job.run(jobId)
  -> job.status / job.list polling
  -> artifact.list(jobId)
  -> bounded artifact.read(jobId, artifactId, offset, maxBytes, allowSensitive)
```

请求至少使用以下 typed inputs；具体默认值应由 facade 常量集中定义并接受 Catalog 边界校验：

```text
durationSeconds: 1...600 内的短时有界值
hilogFilters: []
uiDump: true
crashLogs: false
uiScreenshot: true
uiComponentTree: true
redactionProfile: "standard"
```

`uiScreenshot` 与 `uiComponentTree` 会使 materialized plan 达到 `deviceMutation`。App 只提交
published operation reference、精确 target/binding 与 typed inputs；Runtime 负责 admission、
capability、provider-owned remote path、cleanup debt 和命令 lowering。App 不得构造或接收
raw HDC/shell/argv、远端路径、trusted fact、capability 或硬件 evidence。

提交成功后保存 Runtime 返回的 `jobId`。只有该 Job terminal facts 可读且
`outcomeUnknown == false` 时，才允许把其 Artifact 更新为当前可交互 capture。失败、取消、
等待人工、residue 或 unknown outcome 必须保留旧的已验证 capture（如有），并明确显示新抓取
未生效；不得把半成品替换成成功结果。

### 4.2 Artifact 读取与同批次约束

从同一个 `jobId` 的 `artifact.list` 中精确选择：

| 文件 | 用途 | 约束 |
|---|---|---|
| `screenshot.png` | 左侧截图 | `published`、`image/png`、PNG magic、byteCount/SHA-256 一致 |
| `ui-tree.json` | 完整树与 bounds | `published`、`application/json`、byteCount/SHA-256 一致 |
| `ui-dump.json` | 节点 raw/补充字段 | 可选；存在时必须同 Job 且通过 byteCount/SHA-256 校验 |

三者都是 `sensitive` Artifact。Viewer 内部读取也必须显式传
`allowSensitive: true`，复用 History 的 bounded chunk、offset、EOF、总字节数和 SHA-256
校验语义；不得根据 daemon 本地路径直接读文件。实现应设置独立的单 Artifact 与总内存上限，
超过上限时拒绝展示并给出原因，不能无限拼接 XPC chunk。

可点击映射至少要求截图与树来自同一个 `jobId`，并记录这一 capture identity。任一 Artifact
缺失、未发布、内容校验失败、JSON 损坏或 job identity 不一致时，Viewer 可以展示明确错误，
但不得建立截图热区，也不得拿上一次截图映射本次树。

### 4.3 window selector 的第一版语义

当前 `capture.diagnostics@1` 没有 `windowId`、`componentId` 或 `recipeId` 输入，截图也是整屏
PNG。第一版 toolbar 中的 window selector 只能列出当前同批 `ui-dump.json` / `ui-tree.json`
内可证明的 window/root，并在本地切换当前检查的树根和截图节点集合；默认选择 active/topmost
window。它不是新的抓取参数。

如果 Artifact 没有稳定 window identity，toolbar 只显示“当前屏幕”，不伪造 `w12`。
若产品未来要求“选定窗口后重新抓取该窗口”，需另行发布带 typed `windowId` 的 Operation；
本任务不得通过复活历史 Recipe 参数或拼接 hidumper argv 实现。

## 5. 数据模型与解析

在 `ArkDeckWorkflows` 中建立与 SwiftUI 解耦、可单元测试的模型，建议最少包含：

```text
ViewerCaptureIdentity(jobId, targetId, bindingRevision, capturedAtUTC)
ViewerCapture(screenshotData, roots, nodeIndex, rawDocuments, identity)
ViewerNode(identity, parentIdentity, children, type, text, inspectorId,
           bounds, visible, enabled, clickable, focusable, rawFields)
ViewerBounds(x, y, width, height)
ViewerSelection(nodeIdentity)
```

要求：

- node identity 在一次 capture 内稳定且唯一；优先使用原始节点 ID，缺失或重复时使用包含
  parent path 的确定性内部 identity，但 UI 不得把合成值冒充设备 component ID；
- parser 对未知字段前向兼容，将每个节点完整原始 JSON 保存在 `rawFields`，结构化解析不得
  丢弃 Raw dump；
- bounds 只接受有限数值、非负宽高且能转换到截图坐标的节点；非法 bounds 让该节点不可从
  截图命中，但不阻止其出现在树和 Raw dump；
- bounds 坐标系或截图尺寸无法证明时，禁用所有截图命中并说明原因，不能猜缩放、旋转或
  safe-area 偏移；
- `ui-tree.json` 与 `ui-dump.json` 不能可靠 join 时，以树节点为主展示，raw 补充标记为
  unavailable，不按数组位置猜配对；
- 搜索只产生当前树的可见/高亮集合，不修改 capture、node identity 或 selection。

## 6. UI 结构与交互要求

### 6.1 Shell 与 toolbar

- 侧栏和页面标题只显示 `Viewer`；内部 Swift 类型是否由 `UIDump*` 重命名可由实现者按
  diff 风险决定，但所有用户可见字符串和 accessibility label 必须统一；
- 无 capture 时 toolbar 只显示 target、`搜索组件 / ID / 文本` 与 `抓取视图`；默认内容区
  显示“没有已验证的 capture”空态；
- capture 验证完成后 toolbar 才增加当前 root、ISO 抓取时间、搜索匹配数与上一项/下一项，
  动作改为 `重新抓取`；
- 删除旧 Window inventory / Recipe / Debug parameter policy / Review 表单；
- 不提供 `全部 / 可交互` segmented control；搜索是唯一树过滤入口；
- 底部全局 Job Inspector 继续存在，抓取中的进度和 terminal timeline 来自 Runtime facts。

### 6.2 左侧截图

- `显示组件边界` 默认关闭；开启后显示低对比度 1 px 普通节点边界；
- 无论 toggle 是否开启，当前节点都使用 2 px accent 边界和 `#<id> <type>` 文本标签；
- 只有具有已验证 bounds 的节点可点击；重叠命中选择指针位置下最深的 visible 节点，深度
  相同时使用稳定的绘制/z-order 规则；父节点从树或 breadcrumb 选择；
- 截图缩放必须使用 aspect-fit 后的真实 content rect 映射，letterbox 区域不响应命中；
- 选择截图节点后，树自动展开祖先并滚动到对应行，但不抢走当前键盘焦点。

### 6.3 右侧 UI 树

- UI 树位于右侧上方，是完整树而不是命中附近摘要；支持展开/折叠、垂直滚动和水平滚动；
- 深层缩进不能用省略号吞掉节点名，节点 type、可用文本与真实 ID 应保持可读；
- 当前节点只有一个选中行，并与截图和属性 header 同步；
- 遵循 macOS outline 键盘模式：上/下移动，左键折叠或回到父节点，右键展开或进入首个
  子节点，Enter/Space 选择，Home/End 到当前可见集合首尾；
- 搜索匹配 type、真实 ID、inspectorId 与文本；保留匹配节点的祖先路径，并显示
  “匹配数 / 总节点数”。空结果不清除原 selection；
- 选中状态不能只靠颜色，至少同时保留 selection indicator、type 与 ID 文本线索。

### 6.4 下方节点属性

- 属性检查器固定在树下方，不增加独立第三栏；
- header 显示节点 type、真实 ID（存在时）、可见/可交互等可证明状态与 breadcrumb；
- tabs：`属性 / 布局 / 无障碍 / Raw dump`；
- `属性` 展示已解析的通用字段；`布局` 展示原始与截图映射后的 bounds、opacity、z-order、
  hit-test；`无障碍` 展示 role/label/value/description/focusable 等已存在字段；
- `Raw dump` 对该节点显示完整、可复制、稳定排序/格式化的原始 JSON。未知字段不能丢失；
- 树和属性之间是紧凑水平 separator：默认树约占 60%，允许范围 35%...68%；指针拖动，
  键盘上/下微调，Home/End 到范围两端；调整比例不得改变 selection identity。

### 6.5 自适应与无障碍

- 宽屏为“截图 | 树/属性”；无法容纳双列时排列为“截图 → 树/属性”，检查器内部始终树在上；
- 任一宽度都不能裁掉 Raw dump 的访问入口或树的双向滚动；
- 截图节点和树行使用原生 button/outline 语义、可见 focus ring 和不小于 24×24 pt 的命中区；
- 选择变化不强制移动焦点，通过稳定的 polite status 播报当前 type/ID；
- separator 提供可访问名称、当前值/范围和键盘操作；
- 尊重 Reduce Motion；selection 变化不使用大面积或持续动画。

## 7. 必须实现的产品状态

| 状态 | UI 行为 |
|---|---|
| 首次加载 | 保留骨架/进度，禁止无目标提交 |
| Operation unavailable | 展示 Runtime reasons；不显示可执行的“重新抓取” |
| 无 target / binding 不完整 | 展示精确 blocker；提交数为 0 |
| 正在抓取 | toolbar 显示 job 状态并防止同 target 重复提交；允许取消剩余安全步骤时使用 `job.cancel` |
| 抓取成功 | 仅在同 Job Artifact 全部验证后原子替换当前 capture |
| screenshot/tree 缺失 | 显示缺少的 Artifact 名称；不可点击映射 |
| JSON、PNG、byteCount 或 SHA-256 无效 | 显示校验失败；不回退到 fixture 或路径直读 |
| bounds/坐标系无效 | 树与 Raw 可读，截图命中整体或对应节点禁用并解释 |
| failed/cancelled/outcomeUnknown/residue | 不投影为成功；保留旧已验证 capture 并显示 needs-attention facts |
| 搜索无结果 | 显示 0 匹配，不清空 capture 或当前 selection |

Production provider 禁止 fixture fallback。Preview 和 UI test fixture 必须通过显式依赖注入，
且不能进入 production `make()` 路径。

## 8. 建议修改范围

实现 AI 应优先在以下已由 `TASK-AIN-021` 授权的路径内完成一个垂直 PR：

- `ArkDeckApp/App/ArkDeckApp.swift`：导航/页面用户可见名与依赖注入；
- `ArkDeckApp/Features/UIDump/UIDumpWorkspaceView.swift`：替换为 Viewer 工作区；如重命名文件，
  同步 `ArkDeck.xcodeproj/project.pbxproj`，不要保留两个生产入口；
- `ArkDeckApp/Resources/UIDumpLocalizable.xcstrings`：Viewer 文案和状态；
- `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/UIDumpApplicationFacade.swift`：typed submit/run、
  polling、Artifact list/read/校验与 presentation；
- `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/` 下新增必要的 parser/model 文件；
- `Packages/ArkDeckKit/Tests/ArkDeckContractTests/UIDumpApplicationFacadeContractTests.swift`：
  production XPC、fail-closed 和零 fixture fallback；
- `Packages/ArkDeckKit/Tests/`：tree/raw/bounds parser 单元测试；
- `ArkDeckAppUITests/AppShell/AppShellUITests.swift` 或独立 Viewer UI test：交互和 accessibility。

若实际资源文件名与上面不同，先用项目引用确认真实路径再修改。不要修改 Catalog、Provider、
contracts、Safety policy、历史 OpenSpec Task 状态或无关页面；发现发布 Operation 本身缺能力时，
如实报告产品 blocker，不在本 PR 扩张协议。

## 9. 实现验收检查

- [ ] `Viewer-01`：侧栏、页面、toolbar、空态和 accessibility 文案中不再出现产品名
  `ArkUI UI Dump`；数据说明可使用 `ArkUI dump`。
- [ ] `Viewer-02`：重新抓取提交的是 `capture.diagnostics@1` + 精确 target/binding +
  bounded typed inputs，且 `uiDump/uiScreenshot/uiComponentTree == true`。
- [ ] `Viewer-03`：只有同一 `jobId` 的截图与树通过 status、privacy、size、SHA-256 和内容
  校验后才创建可点击 capture。
- [ ] `Viewer-04`：截图任一有效节点、树任一节点都可选择，截图框、树行、breadcrumb 和
  属性始终指向同一 node identity。
- [ ] `Viewer-05`：重叠 bounds 命中最深 visible 节点；letterbox、非法 bounds 和未证明
  坐标系不产生点击。
- [ ] `Viewer-06`：完整深树可展开、横向/纵向滚动、自动 reveal，并支持规范中的键盘模式。
- [ ] `Viewer-07`：属性位于树下方；separator 默认/范围/指针/键盘行为正确，改变高度不丢选择。
- [ ] `Viewer-08`：属性、布局、无障碍和 Raw dump 均可达；未知字段在 Raw dump 中完整保留。
- [ ] `Viewer-09`：界面不存在 `全部 / 可交互` filter，也不存在 Recipe、候选 argv、raw command
  或 remote path 输入。
- [ ] `Viewer-10`：Operation/target/Artifact/解析/bounds/outcome 的每种失败态都有可测试的
  fail-closed presentation，不用 fixture 冒充成功。
- [ ] `Viewer-11`：窄屏仍按截图 → 树/属性排列；搜索、树双向滚动和 Raw dump 不被裁掉。
- [ ] `Viewer-12`：生产 facade contract、parser unit tests、SwiftUI UI tests 与仓库本地闸全绿。

## 10. 最小测试矩阵

### ArkDeckKit contract/unit tests

1. `job.submit` canonical request 精确断言 operation、target、binding 与全部 Viewer inputs；
2. submit 缺 job ID、run terminal facts 不完整、outcome unknown 时拒绝发布 capture；
3. `artifact.list` 只能接受同 job、正确文件名/media type/status/privacy 的 Artifact；
4. `artifact.read` 覆盖多 chunk、offset 漂移、空的非 EOF chunk、总长度漂移、base64 错误、
   byteCount 超限、SHA-256 不匹配和敏感读取未 opt-in；
5. parser 覆盖深树、未知字段、重复/缺失 ID、无效 JSON、非有限/负 bounds、无法 join raw；
6. hit-test 覆盖 aspect-fit、letterbox、父子重叠、同深度 z-order、hidden 节点；
7. production `make()` 只创建 XPC provider，不包含 fixture fallback。

### App UI tests

使用显式 fixture provider 提供一个固定同批 capture，至少验证：

1. `Viewer` 用户可见命名与旧表单消失；
2. 点击截图 `#42 Toggle` 后树 reveal/selection 与属性同步；
3. 从树选择父节点后截图与 breadcrumb 同步；
4. 搜索匹配、0 结果、深树水平滚动；
5. separator 的 pointer 替代动作或 keyboard action；
6. 属性四个 tab、Raw 未知字段和 accessibility identifier；
7. missing Artifact、invalid bounds、outcome unknown 三类失败态不出现可点击热区。

### 最终闸与真实运行

实现 PR push 前运行仓库统一入口和路径预检：

```bash
python3 scripts/ci/plan.py \
  --repo-root . \
  --base-revision origin/main \
  --head-revision HEAD \
  --merge-base \
  --include-worktree \
  --run-local

python3 scripts/check_pr_paths.py \
  --repo-root . \
  --preflight \
  --base-revision origin/main \
  --head-revision HEAD
```

真机可用时，Runtime 腿优先使用 `arkdeck agent run` 执行当前 Catalog digest 的
`capture.diagnostics@1`，记录脱敏 target、job ID、Artifact 名称/size/SHA-256 与 terminal
result；不要求维护者用 App 点击来替代 Runtime 验证。App UI test 只证明界面交互，不得把
fixture 或设计稿结果记为 `REAL_DEVICE_PASS`。

## 11. 完成定义与交接输出

实现 AI 应在一个 `agent/**` 产品分支和一个垂直 PR 中交付生产代码、必要测试、最小文档
修正及验证结果；commit subject 声明 `TASK-AIN-021`。完成后不要创建 readiness、verification、
done 或 archive 跟进任务。

交接说明至少包含：

- 生产数据流实际接通到哪些 XPC 方法；
- 当前 window selector 使用了哪一种 Artifact 内 identity；
- capture 原子切换与旧 capture 保留策略；
- parser 接受的已知 tree/raw 形态和未知字段保留方式；
- 已运行的 host gates、UI tests 与真实设备结果；
- 仍存在的唯一产品 blocker（若有）。
