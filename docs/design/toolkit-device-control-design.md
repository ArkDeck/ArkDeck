# ArkDeck Toolkit 与真机操作设计

> Status：draft v1.3（design input，非 normative）
> Date：2026-08-25（v1.3 按设计评审修订：输入闭集扩为 tap/longClick/swipe 且 tap 锚定按下点；两态触点反馈与 stale 输入作废；预览常显画面年龄、过期时输入暂停、帧率按实测标注；第一版录屏改为宿主逐帧合成，设备侧编码与 remote artifact reference 降为 Spike-gated 目标形态；对应 OpenSpec 提案见 `openspec/changes/chg-2026-071-interactive-device-control/`）
> Golden Journey：GJ-2 HAP Debug、GJ-3 Native Debug、GJ-5 Bounded AI Debug Loop
> 交互原型：[`prototype.html?page=tools`](prototype.html?page=tools)
> 行为事实源：Catalog、Runtime contracts 与 accepted specs；本文只定义产品信息架构与交互。未发布的 operation 在产品中必须显示 unavailable。

## 0. 决策摘要

Sidebar 新增独立 **Toolkit** tab，承载可独立使用、目标明确的小工具。第一个工具是 **真机操作**，提供：

- 按需获取设备截图；
- 显式开始和停止录屏（第一版为宿主逐帧合成的低帧率录像，帧率按实测标注；设备侧编码录屏是 Spike-gated 目标形态）；
- 可选的低帧率持续预览（帧率与画面年龄常显；5 fps 是目标值而非承诺）；
- 把设备画面上的系统鼠标事件直接转换为点击、长按或滑动；
- 查看本次 Control Session 的操作记录和媒体 Artifact。

**延迟是本工具的成立前提**：交互式输入若按每输入一个完整 Runtime Job 落地，端到端延迟为秒级且在 per-device mutation lane 上串行排队，“直接操作”的手感无法成立。落地前必须完成输入延迟 Spike，并按结论选择轻量 in-session 准入面；量化门槛（tap p95 ≤ 400 ms、pending 反馈 ≤ 100 ms）不达标时，本工具退回“截图上点选 → 显式确认发送”的形态，而不是带着秒级延迟假装可以直接点击。

Toolkit 不替代 Debug、Viewer、Trace 或 Diagnostics。Diagnostics 默认不再持续录屏，而是在 Marker 时按需截图；需要独立观察和控制设备时进入 Toolkit。这样既保留联动诊断能力，也避免日常 Trace 因后台录屏改变设备性能。

## 1. 产品边界

### 1.1 Toolkit 的定位

Toolkit 是一组小型、单一目的、可独立退出的设备工具，不是 raw HDC 控制台：

Sidebar 使用带提手与分隔仓的 outline 工具箱图标，表达“多个工具的容器”；不使用单独扳手，避免把 Toolkit 误读成一个维修操作。图标沿用全局 `currentColor`、统一描边和选中态规则，内部「真机操作」继续使用设备图标表达当前工具。

```text
Toolkit
└── 真机操作
    ├── 画面：按需截图 / 低帧率预览
    ├── 媒体：显式录屏
    ├── 输入：点击 / 滑动
    └── 记录：输入事实 / Artifact / 结果
```

后续工具只有在对应 typed operation、Provider lowering、effect 等级和结果事实发布后才出现在列表。Toolkit 不提供“自定义命令”“任意 HDC 参数”或 capability 管理入口。

### 1.2 与 Diagnostics 的分工

| 工作区 | 默认采集 | 适用场景 |
| --- | --- | --- |
| Trace | Trace | 常规性能分析，最低额外干扰 |
| Diagnostics | Trace + HiLog；Marker 时截图 | 偶现问题与跨证据联动 |
| Toolkit · 真机操作 | 按需截图；录屏和低帧率预览默认关闭 | 独立复现、远程操作、录制演示过程 |

Diagnostics 可以读取由同一 Diagnostic Session 发布的 Screen Artifact，但不会静默启动 Toolkit 的录屏。Toolkit 产生的独立录屏也不会自动加入正在运行的 Diagnostic Session；只有显式选择“关联到诊断”且时间、target、binding 与 Artifact lineage 均可证明时，才能建立关联（该关联依赖尚不存在的 Session 概念，属后续阶段）。

**与运行中 Diagnostic Session 的并发是行为级缺口**：“用 Toolkit 远程复现 + Diagnostics 同步取证”是最自然的组合工作流，但采集会话 Job 在当前 Runtime 语义下持有 per-device mutation lane，Toolkit 输入与截图会被结构性阻塞。在 in-session 准入语义（chg-2026-071）发布前，Diagnostics 采集期间 Toolkit 对同一设备必须显示明确的 unavailable 原因并 fail closed，不得静默排队。

## 2. 性能干扰策略

### 2.1 默认状态

进入真机操作时只显示最近一次已确认截图：

- 不持续取帧；
- 不自动开始录屏；
- 不因为用户发送点击或滑动而自动开启预览；
- 截图时间固定显示，避免把旧画面误认为当前设备状态。

用户可以手动选择“获取截图”。点击或滑动完成后，产品不默认再抓一张截图；如果未来提供“操作后自动截图”，它必须是显式设置并展示额外开销。

### 2.2 低帧率预览

“开启低帧率预览”是独立、可停止状态，目标为固定 `5 fps`，不提供任意码率或 shell 参数。**5 fps 是待真机验证的目标值**：在逐帧截图链路上更现实的量级是 1–2 fps，UI 必须显示实测帧率（如 `低帧率预览 · 实测 2.1 fps（目标 5）`），不承诺未证实的数字。开启后固定显示：

- 实测帧率与**画面年龄**（如 `画面 0.6 s 前`）——用户点击的是过去的画面，年龄必须常显；
- “可能影响设备性能”；
- 可立即到达的“停止持续预览”。

画面年龄超过阈值（建议 800 ms）或断流时，操作面进入**输入暂停**：画面盖上“画面已过期 · 输入已暂停”，pointer down 被拒绝并给出状态说明，直到新帧到达。这防止用户按旧画面误触真机（动画、滚动、toast 场景下点错是真实的设备副作用）。

预览只用于操作反馈，不作为性能诊断证据。发生掉帧、断流或帧时间不可证明时，画面显示 stale / gap，不重复上一帧制造连续假象。

### 2.3 录屏

录屏与预览彼此独立：

- 开始录屏不会自动开启预览；
- 开启预览不会自动录制；
- 两者同时运行时明确展示两个开销状态；
- 达到时长或 byte budget 后自动停止；接近 60 秒上限前 10 秒显示持续可见的倒计时提示，完成后提供“再录一段”，分段在操作记录中连成序列——偶现问题的复现经常超过一段录屏的长度，到点静默截断会毁掉复现；
- 没有可靠 byte denominator 时只显示 elapsed，不显示伪造百分比；
- 开始录屏前的 preflight 必须包含宿主 Artifact 配额余量检查（配额满时是拒绝发布而非淘汰，失败必须发生在开始前而不是保存时）。

**第一版录屏 = 宿主逐帧合成**。OpenHarmony 当前没有任何已知的设备侧录屏命令面（Catalog、DEVICE-COMMAND-FACTS、openspec 均无），设备侧编码需要自研 helper 或新平台能力，属于 Spike-gated 目标形态。第一版把录屏定义为：录制期间宿主按预览链路逐帧取帧，停止后在宿主侧合成 MP4 并按实测帧率标注（如 `2.1 fps · 宿主合成`）：

```text
停止取帧
  → Assembling：宿主侧把已取帧合成 MP4
  → Validating：校验 byte count、SHA-256 与容器可读性
  → 原子发布到 ArkDeck managed Artifact storage
  → 显示“录屏已保存到 Mac”、本地位置与后续操作
```

宿主合成路径没有设备端拉取环节，也没有设备端残留文件；取帧断流在合成结果中保留为可见 gap，不插值补帧。

**目标形态（设备侧编码，Spike-gated）**：封闭 preset（如 `720p · 15 fps · 60 秒上限`）在设备侧编码，停止后进入 Receiving / Validating：

```text
停止设备端 recorder
  → Receiving：从 job-owned 设备临时路径拉取到 Mac 临时文件
  → Validating：校验 byte count、SHA-256 与容器可读性
  → 原子发布到 ArkDeck managed Artifact storage
  → 显示“录屏已保存到 Mac”、本地位置与后续操作
```

该形态依赖两项未发布的 Runtime 能力，必须先走 OpenSpec：设备侧录屏 operation 本身，以及跨 Job 可寻址的 **remote artifact reference**（当前设备路径由 jobID 铸造、`hdc file recv` 整文件不可续传且重试先删本地部分，“重新拉取”今天结构性造不出来）。在这两项发布前，产品不得展示设备侧录屏入口。

录屏 Artifact 默认 sensitive、本地保存且不可原地修改。停止后至少记录名称、时长、size、hash、实测帧率、target、binding、display facts、合成/编码参数、local URL 和 status。

默认位置由 ArkDeck 管理，例如：

```text
~/Library/Application Support/ArkDeck/Artifacts/<control-session>/screen-recording.mp4
```

产品不在开始录屏前要求选择目录，避免打断复现。完成后提供：

- **在 Finder 中显示**：定位 managed raw Artifact；
- **另存为…**：通过系统 `NSSavePanel` 导出一份副本，原始 Artifact 不移动、不修改；
- 明确的文件名、size、duration、hash 和本地位置。

设备侧编码形态发布后适用：只有本地文件通过 size/hash 校验才能清理设备端临时文件；拉取失败时保留可恢复的 remote artifact reference，显示“重新拉取”；不能把 recorder 已停止写成视频已保存，也不能提前删除唯一副本。注意 SHA-256 在没有设备端参考摘要时是宿主侧自算指纹（证明“发布后未变”），设备端一致性的依据是 byte count 回读与容器可读性；文案不得把两者混为一谈。

## 3. 真机操作工作区

### 3.1 信息层级

参考宽屏使用三层结构：

1. 顶部工具栏：精确 target / binding / resolution / orientation，以及截图、预览、录屏操作；
2. 左侧设备画面：可直接点击、拖动的操作面和截图时间；
3. 右侧 Inspector：操作方式、操作记录和性能提示。

Toolkit 内部左侧工具列表用于未来扩展。只有“真机操作”发布时，列表只显示这一项和一行扩展说明，不用大面积 Coming Soon 卡片填充页面。

### 3.2 截图

“获取截图”提交一个 bounded read-only operation。成功后原位替换画面，并更新：

- screenshot timestamp；
- target / binding；
- resolution / orientation；
- Artifact name、size、hash 和 privacy；
- 操作记录。

失败时保留上一张截图，并在画面上明确标注“上次截图”和失败原因，不能清空后放置伪造设备画面。

### 3.3 鼠标事件映射

设备画面不提供「点击 / 滑动」模式切换，也不要求用户输入坐标。一次 primary pointer sequence 在本地先被归类，再生成一个 typed input request，闭集为 tap / longClick / swipe（`uitest uiInput` 三者在设备命令面均有对应）：

- 移动距离小于 `6 pt` 且按住不足 `500 ms`：转换为一次 tap，**坐标锚定 pointer down 位置**——sub-6pt 抖动不改变落点，避免在缩小的画面上偏移到相邻控件；
- 移动距离小于 `6 pt` 且按住达到 `500 ms`：转换为一次 longClick，同样锚定 down 位置。**长按不得被静默降级为 tap**——用户长按想要的是上下文菜单，收到一次普通点击是错误的设备副作用；longClick operation 未发布时该手势显示“长按暂不支持”并不发送；
- 移动距离达到或超过 `6 pt`：转换为一次 swipe，起点和终点取 pointer 的实际位置；
- swipe duration 使用 pointer down 到 pointer up 的实际时长，并限制在 operation 发布的封闭范围内（设备命令若以速度而非时长为参数，由 Provider 换算并记录）；
- secondary click、滚轮和多指手势在没有对应 operation 时不发送设备输入，并在操作面就地给出一次性说明（“该手势不会发送到设备”），不能无反馈。

macOS 实现使用一条统一事件管线，避免 `TapGesture` 与 `DragGesture` 竞争后重复派发。SwiftUI 可使用命名 coordinate space 下的 `DragGesture(minimumDistance: 0)` 收集 start / current / end，再在 `onEnded` 按阈值归类；需要更精确的 pointer capture 时使用 `NSView` 的 `mouseDown` / `mouseDragged` / `mouseUp`。无论使用哪种 API，都只在一次 sequence 结束时提交一个 request。

坐标只作为事件转换后的内部 typed input 展示在操作记录中，不在主界面提供坐标表单。转换以设备截图真正的 content rect 为基准，排除 letterbox / padding：

```text
deviceX = clamp(round((localX - contentRect.minX) / contentRect.width  × displayWidth))
deviceY = clamp(round((localY - contentRect.minY) / contentRect.height × displayHeight))
```

提交前必须再次确认：

- target 与 binding 未漂移；
- 当前 display ID、resolution、orientation 与截图事实一致；
- 坐标位于允许范围；
- operation 支持当前设备和输入类型。

pointer down 后必须 capture pointer，拖出画面仍可得到完整 pointer up；拖动期间只显示本地轨迹，不向设备流式发送中间点。pointer up 时恰好生成一个 tap、longClick 或 swipe intent。

**结果反馈是两态的**：intent 提交后 ≤100 ms 内在落点显示 pending 触点（空心/虚线），只有对应 operation 的结果事实到达才转为 confirmed（实心）；failed / unknown 在触点原位显示状态符号，不只藏在操作记录里。真实链路的注入延迟是数百毫秒级，没有 pending 态用户必然重复点击。

**每个 intent 绑定画面 epoch 并有排队时效**：intent 携带其发出时所基于的画面标识（截图时间 / 预览帧序号）与 target/binding/display facts；在队列中滞留超过阈值（建议 1 s）的输入**作废**并显示“画面已过期，输入未发送”，绝不延迟补发——迟到数秒才落在已变化界面上的点击比失败更危险。结果 unknown 时保留 unknown，不自动重发，也不能把下一次鼠标操作解释为恢复。

### 3.4 键盘操作

设备画面保持一个可聚焦操作面，不恢复坐标输入表单：

- 方向键移动画面内的虚拟指针；
- Enter / Space 在虚拟指针位置发送 tap；
- `Shift + 方向键` 从虚拟指针向对应方向发送一个封闭距离和时长的 swipe；
- 当前虚拟指针、键盘帮助和操作结果均可感知，焦点不会因一次操作而丢失。

这是一条与直接鼠标操作等价的设备控制路径，不要求用户理解设备像素坐标。

### 3.5 操作记录

记录按新到旧排列，每项至少展示：

- host timestamp；
- 操作类型；
- 规范化后的 typed inputs；
- confirmed / failed / unknown 结果；
- 对应 Job / intent / Artifact identity。

操作记录是 Control Session 的事实视图，不是可点击的 replay macro。未来若提供自动化编排，必须生成新的 reviewed typed plan，不能直接重放历史坐标序列。

## 4. 状态模型

```text
Preview
  snapshot ── startLowFPS ──> livePreview ──(frame age > 阈值 / 断流)──> stale(输入暂停)
      ^                           │  ^______________ fresh frame ______________|
      └──────── stopPreview ──────┘

Recording（第一版 · 宿主合成）
  idle ── start ──> recording ── stop/limit ──> assembling ──> validating
    validating ── local publish confirmed ──> ready ──「再录一段」──> recording
    assembling/validating ── failure ──> partial | failed

Recording（目标形态 · 设备侧编码，Spike-gated）
  idle ── start ──> recording ── stop/limit ──> receiving ──> validating
    validating ── local publish confirmed ──> ready
    receiving/validating ── failure ──> retryable(remote reference) | partial | failed

Input
  ready ── pointerDown(画面未过期) ──> tracking
    ready ── pointerDown(stale) ──> rejected(说明原因，不产生 intent)
    tracking ── pointerUp(<6 pt, <500 ms) ──> submit tap(锚定 down 点)
    tracking ── pointerUp(<6 pt, ≥500 ms) ──> submit longClick(锚定 down 点)
    tracking ── pointerUp(≥6 pt)          ──> submit swipe
    submit ──> pending ──> confirmed | failed | unknown
    pending ──(排队超时 / epoch 失效)──> invalidated(显示“画面已过期，输入未发送”)
    tracking ── pointerCancel ──> ready
```

三个状态机互相独立。录屏失败不阻止截图；预览断流不把输入结果改为失败，但会让输入面进入暂停；输入结果 unknown 不自动停止录屏，但会阻止同一 intent 的自动重放。

## 5. 安全与隐私

- 所有 device-scoped action 必须绑定精确 target / binding；最近选择的 sidebar 设备不是隐式 authority。
- 点击和滑动属于设备 mutation，必须由已发布 operation materialize，并遵循 Runtime effect admission。
- App 只把经过 content rect 映射和边界校验的 coordinates、duration 与 display facts 组成 typed request，不提交 shell fragment、raw argv 或任意设备路径。
- display facts 在 dispatch 前漂移时 fail closed，并要求重新获取截图或预览帧。
- screenshot / video 默认 sensitive；secure surface、密码、通知和个人信息可能进入 Artifact，导出前必须预览和确认。
- 录屏、预览和截图都不证明输入操作成功；输入 success 只能来自对应 operation 的结果事实。
- simulation / prototype 不得显示为真机执行结果。

## 6. 可访问性与键盘

- 工具列表使用原生 button 或 sidebar selection 语义，选中项同时使用文字和 selection indicator。
- 截图画面是可聚焦操作面，并提供清晰 accessible name；不依赖额外模式切换。
- 方向键虚拟指针、Enter / Space 点击与 `Shift + 方向键` 滑动构成完整键盘路径，不暴露坐标表单。
- 动态截图时间、录屏 elapsed 和操作结果使用稳定 polite status，不重复朗读整个历史列表。
- 录屏和预览状态同时使用 symbol、文案和颜色；不能只依赖红点。
- 所有 icon-only control 至少有 24×24 hit area 和明确 accessible name；macOS 正常密度优先 28×28 以上。
- Reduce Motion 下移除触点和滑动轨迹动画，只保留静态位置与操作记录。

## 7. 当前实现边界

当前原型中的设备画面、截图时间、输入结果和录屏 Artifact 均为演示数据。生产实现前需要逐项确认是否已有完全匹配的 Catalog operation 和 Provider lowering；新增 screenshot、screen recording、input click 或 input swipe operation，或破坏性修改现有 operation，必须遵循仓库规定的审批范围。

App 不得为了让原型可操作而执行 raw HDC fallback。本地 pointer event 只负责产生 typed request；只有 Runtime outcome 才能把操作标记为成功。

## 8. 原型走查

打开 `prototype.html?page=tools`：

1. 默认看到“按需截图 · 无持续取帧”；
2. 选择“获取截图”，先看到“正在获取截图…”pending 记录，完成后截图时间和操作记录更新；
3. 在设备画面单击，看到 pending（空心）触点与“发送中…”记录，随后转为 confirmed（实心）；落点为按下位置，无需选择模式或输入坐标；
4. 在设备画面按住不动 ≥0.5 秒后松开，产生一个长按记录（不会降级为点击）；
5. 在设备画面按住拖动，看到本地拖动轨迹；松开后只产生一个 swipe 记录；
6. 使用方向键移动虚拟指针，以 Enter 点击、`Shift + 方向键` 滑动，验证完整键盘路径；右键/滚轮触发“该手势不会发送到设备”提示；
7. 开启低帧率预览，确认实测帧率与画面年龄常显、性能提示和停止入口持续可见；等到演示断流窗口，确认“画面已过期 · 输入已暂停”遮罩出现且 pointer down 被拒绝并说明原因；
8. 开始录屏，确认 `REC + elapsed` 可见、预览不会自动开启；接近 60 秒时出现倒计时提示；
9. 停止录屏，确认先显示“正在合成视频”（Assembling → Validating），完成后显示“录屏已保存到 Mac”、本地位置、size/实测帧率/hash、「在 Finder 中显示」「另存为…」与「再录一段」；
10. 切换到 Trace 或 Diagnostics 再返回，Toolkit 状态保持且不改变其他工作区。
