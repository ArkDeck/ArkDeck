# ArkDeck Toolkit 与真机操作设计

> Status：draft v1.2（design input，非 normative）
> Date：2026-08-25
> Golden Journey：GJ-2 HAP Debug、GJ-3 Native Debug、GJ-5 Bounded AI Debug Loop
> 交互原型：[`prototype.html?page=tools`](prototype.html?page=tools)
> 行为事实源：Catalog、Runtime contracts 与 accepted specs；本文只定义产品信息架构与交互。未发布的 operation 在产品中必须显示 unavailable。

## 0. 决策摘要

Sidebar 新增独立 **Toolkit** tab，承载可独立使用、目标明确的小工具。第一个工具是 **真机操作**，提供：

- 按需获取设备截图；
- 显式开始和停止真机录屏；
- 可选的低帧率持续预览；
- 把设备画面上的系统鼠标事件直接转换为点击或滑动；
- 查看本次 Control Session 的操作记录和媒体 Artifact。

Toolkit 不替代 Debug、Viewer、Trace 或 Diagnostics。Diagnostics 默认不再持续录屏，而是在 Marker 时按需截图；需要独立观察和控制设备时进入 Toolkit。这样既保留联动诊断能力，也避免日常 Trace 因后台录屏改变设备性能。

## 1. 产品边界

### 1.1 Toolkit 的定位

Toolkit 是一组小型、单一目的、可独立退出的设备工具，不是 raw HDC 控制台：

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

Diagnostics 可以读取由同一 Diagnostic Session 发布的 Screen Artifact，但不会静默启动 Toolkit 的录屏。Toolkit 产生的独立录屏也不会自动加入正在运行的 Diagnostic Session；只有显式选择“关联到诊断”且时间、target、binding 与 Artifact lineage 均可证明时，才能建立关联。

## 2. 性能干扰策略

### 2.1 默认状态

进入真机操作时只显示最近一次已确认截图：

- 不持续取帧；
- 不自动开始录屏；
- 不因为用户发送点击或滑动而自动开启预览；
- 截图时间固定显示，避免把旧画面误认为当前设备状态。

用户可以手动选择“获取截图”。点击或滑动完成后，产品不默认再抓一张截图；如果未来提供“操作后自动截图”，它必须是显式设置并展示额外开销。

### 2.2 低帧率预览

“开启低帧率预览”是独立、可停止状态，第一版目标为固定 `5 fps`，不提供任意码率或 shell 参数。开启后固定显示：

- `低帧率预览 · 5 fps`；
- “可能影响设备性能”；
- 可立即到达的“停止持续预览”。

预览只用于操作反馈，不作为性能诊断证据。发生掉帧、断流或帧时间不可证明时，画面显示 stale / gap，不重复上一帧制造连续假象。

### 2.3 录屏

录屏与预览彼此独立：

- 开始录屏不会自动开启预览；
- 开启预览不会自动录制；
- 两者同时运行时明确展示两个开销状态；
- 第一版使用封闭 preset，例如 `720p · 15 fps · 60 秒上限`；
- 达到时长或 byte budget 后自动停止并进入 Receiving / Validating；
- 没有可靠 byte denominator 时只显示 elapsed，不显示伪造百分比。

录屏 Artifact 默认 sensitive、本地保存且不可原地修改。停止后至少记录名称、时长、size、hash、target、binding、display facts、编码参数、local URL 和 status。

停止录屏不等于完成保存。完整流程固定为：

```text
停止设备端 recorder
  → Receiving：从 job-owned 设备临时路径拉取到 Mac 临时文件
  → Validating：校验 byte count、SHA-256 与容器可读性
  → 原子发布到 ArkDeck managed Artifact storage
  → 显示“录屏已保存到 Mac”、本地位置与后续操作
```

默认位置由 ArkDeck 管理，例如：

```text
~/Library/Application Support/ArkDeck/Artifacts/<control-session>/screen-recording.mp4
```

产品不在开始录屏前要求选择目录，避免打断复现。完成后提供：

- **在 Finder 中显示**：定位 managed raw Artifact；
- **另存为…**：通过系统 `NSSavePanel` 导出一份副本，原始 Artifact 不移动、不修改；
- 明确的文件名、size、duration、hash 和本地位置。

只有本地文件通过 size/hash 校验后才能清理设备端临时文件。拉取失败时保留可恢复的 remote Artifact reference，显示“重新拉取”；不能把 recorder 已停止写成视频已保存，也不能提前删除唯一副本。

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

设备画面不提供「点击 / 滑动」模式切换，也不要求用户输入坐标。一次 primary pointer sequence 在本地先被归类，再生成一个 typed input request：

- `pointer down → pointer up` 的移动距离小于 `6 pt`：转换为一次 tap；
- 移动距离达到或超过 `6 pt`：转换为一次 swipe，起点和终点取 pointer 的实际位置；
- swipe duration 使用 pointer down 到 pointer up 的实际时长，并限制在 operation 发布的封闭范围内；
- secondary click、滚轮和多指手势在没有对应 operation 时不发送设备输入。

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

pointer down 后必须 capture pointer，拖出画面仍可得到完整 pointer up；拖动期间只显示本地轨迹，不向设备流式发送中间点。pointer up 时恰好生成一个 tap 或 swipe intent。成功后显示触点/轨迹反馈和 confirmed 记录；结果 unknown 时保留 unknown，不自动重发，也不能把下一次鼠标操作解释为恢复。

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
  snapshot ── startLowFPS ──> livePreview
      ^                           │
      └──────── stopPreview ──────┘

Recording
  idle ── start ──> recording ── stop/limit ──> receiving ──> validating
    validating ── local publish confirmed ──> ready
    receiving/validating ── failure ──> retryable | partial | failed

Input
  ready ── pointerDown ──> tracking
    tracking ── pointerUp(distance < 6 pt) ──> submit tap
    tracking ── pointerUp(distance ≥ 6 pt) ──> submit swipe
    submit tap/swipe ──> dispatching ──> confirmed | failed | unknown
    tracking ── pointerCancel ──> ready
```

三个状态机互相独立。录屏失败不阻止截图；预览断流不把输入结果改为失败；输入结果 unknown 不自动停止录屏，但会阻止同一 intent 的自动重放。

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
2. 选择“获取截图”，截图时间和操作记录更新；
3. 在设备画面单击，看到对应触点和 confirmed 记录，无需选择模式或输入坐标；
4. 在设备画面按住拖动，看到本地拖动轨迹；松开后只产生一个 swipe 记录；
5. 使用方向键移动虚拟指针，以 Enter 点击、`Shift + 方向键` 滑动，验证完整键盘路径；
6. 开启低帧率预览，确认性能提示和停止入口持续可见；
7. 开始录屏，确认 `REC + elapsed` 可见且预览不会自动开启；
8. 停止录屏，确认先显示“正在拉取视频”，完成后显示“录屏已保存到 Mac”、本地位置、size/hash、「在 Finder 中显示」与「另存为…」；
9. 切换到 Trace 或 Diagnostics 再返回，Toolkit 状态保持且不改变其他工作区。
