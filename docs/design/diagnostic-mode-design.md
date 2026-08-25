# ArkDeck 诊断模式设计

> Status：draft v1.3（design input，非 normative）
> Date：2026-08-25（v1.3 按设计评审修订：Marker 改为「标记 + 环形缓冲回溯取证」，截图按实际拍摄时刻标注；新增自动 Marker 与免手路径；时间对齐承诺分两阶段；定义会话内并发准入缺口；对应 OpenSpec 提案见 `openspec/changes/chg-2026-071-interactive-device-control/`）
> Golden Journey：GJ-2 HAP Debug、GJ-3 Native Debug、GJ-5 Bounded AI Debug Loop
> 交互原型：[`prototype.html?page=diagnostics`](prototype.html?page=diagnostics)
> 行为事实源：Catalog、Runtime contracts 与 accepted specs；本文只定义产品心智、信息架构和交互。原型中的未来能力不得解释为 production availability。

## 0. 决策摘要

诊断模式不是“同时打开录屏、Trace 和日志三个工具”，而是创建一个 **Diagnostic Session**：

1. 用户选择目标设备和诊断 preset；
2. Runtime 校验 required channel，让 Trace、HiLog 进入同一个有界采集会话；持续录屏是默认关闭的 optional channel；
3. 所有 required channel 就绪后，界面明确提示“现在开始复现”；
4. **Marker 只记录时间点；问题前的现场由环形缓冲在 Marker/停止时回溯保存**。手动 Marker 会额外触发一次“事后截图”，其拍摄时刻按事实标注（`拍摄于 Marker 后 +N ms`），不假装是标记瞬间的画面；自动 Marker（frame deadline missed、crash 等特征触发）补齐人工反应慢一拍的缺口；
5. 查看器以 Trace 时间轴为主轴。选择事件或时间点后，左侧显示可证明对应的 Marker 截图或显式录屏帧，右侧显示选中事件和邻近日志；已选 event 的 identity 不会被画面/日志/slider 点击清空；
6. 跨来源时间映射必须展示误差。无法证明对齐时显示缺口，不沿用旧画面或猜测日志关系。第一版只承诺「同一时钟 / 无法对齐」两态；「已校准 ±N ms」在 ground-truth 实验量化误差后启用。

信息架构上，Diagnostic Session 使用独立的 **Diagnostics** tab。现有 **Trace** tab 的抓取配置、参数快照、抓取状态、Artifact 结果和 ArkTrace Viewer 入口全部保留；Diagnostics 不复用或改写 Trace 页的 view state、preset、时长、筛选条件与最近打开记录。独立录屏、低帧率预览、截图和设备输入位于 [`Toolkit · 真机操作`](./toolkit-device-control-design.md)，不会被 Diagnostics 静默启动。

第一版默认只在 Marker 时保存截图。用户显式开启录屏时才保存原始视频和帧索引，不为每个视频帧生成一张长期保存的 PNG。Viewer 按需解码当前帧，缩略图属于可删除、可重建的 derived Artifact。

## 1. 要解决的问题

一次问题复现通常同时需要：

- 当时设备画面发生了什么；
- 哪个 Trace event、线程或 frame 出现异常；
- 同一时刻前后有哪些日志；
- 这些证据是否真的来自同一设备、同一采集会话和可比较的时间范围。

现有工具常把录屏、Trace 和日志分别采集、分别打开。工程师需要手工记时间、拖动视频、搜索日志，再凭经验猜测它们是否对应。ArkDeck 的目标是把这一步变成有证据边界的联动查看，而不是仅把三个文件放进同一个目录。

### 1.1 成功标准

- 开始采集后，用户能明确知道何时可以开始复现。
- 问题出现时，一次操作即可留下 Marker，不打断采集。
- 选择 Trace event 后，不超过一次视线移动即可看到当前画面和邻近日志。
- 当前画面始终显示相对 Trace 光标的时间差，例如 `画面 -8 ms`。
- 日志默认展示光标前后 `100 ms`，每行展示相对时间差。
- 任一 channel 缺失、时间映射漂移或画面间断都有明确状态，不把 partial session 标成完整。
- Raw Artifact 本地保存且不可原地修改；导出由用户发起，并预览敏感内容。

### 1.2 非目标

- 不在第一版提供远程直播或云端协作回放。
- 不把录屏图像内容自动 OCR 后写入日志。
- 不用视频画面推断 Runtime target identity、Trace event 或 Job 成功。
- 不在 App 中暴露 raw HDC、shell、任意远端路径或 capability 管理。
- 不要求 Trace、可选录屏和日志必须全部成功才允许查看已有证据；partial session 可查看，但必须保留缺口。
- 不以 Diagnostics 替换、重命名或扩展现有 Trace tab；两者可以同时存在运行中的 Job，页面状态独立保存。

## 2. 当前产品边界

当前已发布的 `capture.diagnostics@1` 可以在一个 bounded Job 中产出 `hilog.txt`、`ui-dump.json`、`ui-tree.json`、`screenshot.png`、`trace.htrace`、`capture.log`、`artifact-index.json` 与 `capture-summary.json` 等 Artifact。它已经解决精确 target/binding、typed inputs、Artifact 校验和本地保存问题。

它尚未提供以下目标能力：

| 缺口 | 对诊断模式的影响 |
| --- | --- |
| 屏幕视频 Artifact | 只能看到单张截图，无法逐帧回放复现过程 |
| 多 channel 并发 arm/stop 证明 | 现有 Artifact 同属一个 Job，不等于采集区间天然重合；当前 lowering 甚至是顺序执行（hilog drain 在前、trace 阻塞在后），两者并不覆盖同一区间 |
| 环形缓冲 / 回溯窗口 | 无法在“问题已经出现之后”回头保存问题前的现场；Marker 的取证价值取决于此（设备侧 `hitrace` 环形模式待真机确认） |
| 会话内并发准入 | 采集会话 Job 持有 per-device mutation lane；Marker 截图与 Toolkit 输入在会话期间会被结构性阻塞，需要新的 in-session 准入语义 |
| source clock calibration | 无法给出 Trace、视频 PTS 与 HiLog 之间的误差上界；Marker 位于 host 时域，还需要 host↔device 校准 |
| Marker track | 用户无法在问题出现时留下稳定时间锚点 |
| frame/log linkage index | Viewer 需要临时猜测或全文件扫描，无法稳定联动 |

另有两个与设计声明冲突的 Runtime 事实必须在实现前对齐：`uiScreenshot` 腿在当前 Catalog 中会把作业升级为 deviceMutation（截图不是 read-only）；`hilog -x` 是一次性缓冲区 drain 而非持续采集——后者恰好是回溯窗口可以直接利用的性质。

因此，本轮原型表达的是目标体验，不声称这些能力已经 production available。后续实现若新增 operation，或改变已发布 operation 的行为与 Artifact 契约，必须按仓库规则走对应 OpenSpec change + PR；不能只把原型按钮接到 raw command。

## 3. 产品心智：一个 Session，多个有证据边界的 Track

Diagnostic Session 是用户可打开、重命名、标记和导出的最小单位。它至少包含：

```text
Diagnostic Session
├── Identity：session / job / target / binding / operation / tool facts
├── Capture interval：session monotonic [start, end]
├── Trace track：raw trace + parsed events
├── Screen track：Marker screenshots；可选 raw video + frame PTS index
├── Log track：raw HiLog + parsed timestamp index
├── Marker track：用户标记 + Runtime channel boundaries
├── Alignment：每个 source → session time 的映射与误差
└── Artifact lineage：raw / derived、size、hash、privacy、status
```

Trace 是主导航轴，但不是唯一事实源：

- 选择 Trace event：光标移动到 event start，保留 event identity；
- 选择 Trace range：画面显示 range start，日志展示 range 内记录；
- 选择视频缩略图或日志：光标移动到对应时间，Trace 轨道滚动到该位置；
- 任何反向选择都不伪造 Trace event identity，只改变时间光标。

## 4. 采集流程

### 4.1 入口与 preset

Sidebar 在 Trace 之后新增独立的 **Diagnostics** tab。进入后默认打开最近一次 Diagnostic Session；“新建诊断”只在 Diagnostics 内切换采集配置，不改变 Trace 工作区。采集页默认提供两个 preset：

| Preset | 默认时长 | Required channels | Optional channels | 适用问题 |
| --- | ---: | --- | --- | --- |
| 低干扰诊断 | 60 秒 | Trace（环形缓冲）、HiLog（缓冲区回溯） | Marker 截图、自动 Marker（默认开）、屏幕录制、UI dump、Crash index | 卡顿、闪退、偶现功能错误 |
| 图形诊断 | 30 秒 | Trace、HiLog、frame/display facts | Marker 截图、自动 Marker（默认开）、屏幕录制、UI tree、window/layer/input facts | 动画、转场、掉帧、触控与布局问题 |

Preset 是 reviewed typed input 的组合，不是 shell 模板。设备或 Provider 不支持 required channel 时，主操作旁直接显示 unavailable 原因，并引导选择可用 preset；不能先消耗 Runtime admission，再到执行中才发现能力不存在。

高级设置使用 disclosure 展示时长、Trace categories、HiLog filters、Artifact byte budget 和可选 channel。屏幕录制默认关闭，启用后在采集前和采集中固定显示“可能影响设备性能”；不会展示 raw argv 或任意设备路径。

### 4.2 开始顺序

```text
选择 target / binding
  → Availability + storage + privacy preflight
  → 点击“开始诊断”
  → Arming：逐项显示 channel 状态
  → required channels 全部进入 recording
  → 显示“采集已开始，现在开始复现”
  → 用户在设备上复现
  → 可“标记并截图”
  → 到达时限，或点击“停止并生成结果”
  → Finalizing：接收、hash 校验、clock mapping、索引
  → Ready / Partial / Failed
```

关键约束：

- “现在开始复现”只在 required channel 已经 recording 后出现。
- Arming 或 Finalizing 没有可靠总量时使用阶段 + elapsed，不显示伪造百分比。
- 录制中持续显示精确 target/binding、已用时、剩余上限、channel 状态、已采集大小和 Marker 数量。
- Marker 本身是 host-owned session annotation，只记录时间点；“标记并截图”额外提交一次 bounded screenshot operation，不开启持续取帧。快捷键为 `⌘M`。**效果分级必须诚实**：截图腿在当前 Catalog 事实下会升级为 deviceMutation（远端临时文件 + cleanup），不得在 UI 或文档中称其为 read-only。
- **截图是事后取证**：从点击到设备完成截图有人工反应 + 执行延迟。截图必须记录实际拍摄时刻，Viewer 与录制页固定显示 `拍摄于 Marker 后 +N ms`；问题瞬间的现场由环形缓冲回溯负责，不由截图假装（见 §4.4）。
- **会话内并发准入是行为级缺口**：采集会话 Job 持有 per-device mutation lane，Marker 截图与 Toolkit 输入在会话期间需要显式的 in-session 准入语义；在对应 OpenSpec delta 发布前，产品必须 fail closed 并解释原因，不得静默排队到会话结束后执行。
- “停止并生成结果”只请求 Runtime 在已发布的安全边界停止和 finalize；按钮点击不是新的 authority。
- required channel 在录制中失败时继续收集仍有价值的 channel，但 terminal 状态为 Partial，并明确失败时间和受影响的时间段。

### 4.3 录制状态文案

主状态固定使用以下词汇：

| State | 主文案 | 次要说明 |
| --- | --- | --- |
| arming | 正在准备诊断 | 等待所有必需采集通道就绪 |
| recording | 采集已开始，现在开始复现 | 在问题出现时选择“标记并截图” |
| finalizing | 正在生成诊断结果 | 正在接收、校验并建立时间索引 |
| ready | 诊断结果已就绪 | 画面、Trace 和日志可联动查看 |
| partial | 部分诊断数据不可用 | 明确列出缺失 channel 和影响范围 |
| failed | 无法开始诊断 | 说明失败点和可执行的下一步 |

### 4.4 Marker 与回溯取证

偶现问题的根本矛盾是：问题出现在人点击标记*之前*。任何“点击时开始取证”的机制都恒慢一拍。因此 Marker 机制按以下原则设计：

1. **Marker 只记录时间点**（host 时域，经校准映射到 Session 时间）。它不是取证动作。
2. **问题前的现场由环形缓冲回溯保存**：Trace 以环形模式持续驻留（目标机制为 `hitrace` 的 begin/dump/finish 环形能力，**待真机确认**），在 Marker 或停止时 dump 出覆盖 Marker 前至少 10 秒的窗口；HiLog 的缓冲区 drain 天然是回溯的（`hilog -x` 读的就是过去）。这使“先复现、后决定保存”成立，也避免了整场流式采集的工程量与扰动。
3. **截图是事后补充**，按实际拍摄时刻标注（`拍摄于 Marker 后 +N ms`），并在 Timeline 上把截图动作自身的执行区间画为 instrumentation 痕迹——截图的 GPU 读回与传输恰好会在用户最关心的时刻注入扰动，证据必须能自我声明。
4. **自动 Marker 是免手路径**：复现时工程师双手在真机上，⌘M 在 Mac 键盘上，单人场景点不上。frame deadline missed、crash、可配置的 HiLog 关键字命中时自动打标（默认开启，只打标不截图，避免扰动风暴）；自动与手动 Marker 在 track 上用不同样式区分。**v1 的自动 Marker 在 finalize 阶段从已回溯的 trace/HiLog 中按特征模式反向推导**——不需要任何实时流式信号处理，Viewer 价值等同；采集中的实时提示是后续增强。设备侧手势（如音量键组合）作为候选二级方案，待平台能力确认。
5. Marker 截图失败（存储不足、secure surface、设备离线）时，**Marker 时间点保留**，失败原因随 Session 保存并在 Viewer 原位展示；不用旧画面或占位图补齐。

## 5. Viewer 信息架构

参考宽度 1180×760 时，Viewer 使用三段式布局：

```text
┌ Session toolbar ─────────────────────────────────────────────┐
│ 返回采集｜Session｜target/binding｜对齐状态｜搜索｜导出       │
├ 当前画面 ───────────────┬ 当前时间上下文 ────────────────────┤
│ video frame             │ selected Trace event              │
│ frame PTS / Δ / status  │ logs around cursor / filters      │
├─────────────────────────┴─────────────────────────────────────┤
│ Marker / Screen / Frame / CPU / Thread / HiLog tracks       │
│                 shared ruler + time cursor                   │
└───────────────────────────────────────────────────────────────┘
```

### 5.1 Session toolbar

- 左侧“新建诊断”返回采集配置，不销毁当前 Session。
- Session picker 展示时间、preset 和 terminal 状态；Partial 必须带文字状态。
- target/binding 是只读 Runtime 事实，值过长时中间省略但完整值可复制。
- 对齐状态是可操作的 disclosure：`同一时钟`、`已校准 ±12 ms` 或 `无法对齐`。
- 搜索只过滤/定位日志与 Trace 文本，不改变 Session Artifact。
- 导出前展示 Artifact、size、hash 与 privacy；不自动上传。

### 5.2 当前画面

- 面板名称使用“当前画面”，因为它可能是 Marker 截图，也可能是从显式录屏按需解码的 frame。
- 有视频时，给定光标 `t`，选择满足 `frame.pts ≤ t < nextFrame.pts` 的 frame；没有视频时，只在 Marker screenshot 的适用点展示画面，不把单张截图延伸为连续区间。**适用点定义为截图的实际拍摄时刻 ±150 ms**；命中时 metadata 固定展示 `拍摄于 Marker N 后 +N ms` 与“截图只代表拍摄时刻，不代表 Marker 时刻的画面”。
- 画面下方固定展示 frame PTS、相对光标差值和映射状态，例如 `00:13.233 · 画面 -9 ms · 已校准 ±12 ms`。
- 若当前 Session 未启用录屏且附近没有 Marker 截图，或光标位于录屏 gap / 映射误差超限，显示“这一时刻没有可证明对应的画面”；不得保留上一帧制造连续假象。
- Secure surface、录屏权限拒绝或黑帧必须作为 Screen track gap 展示，并说明原因。
- 画面可进入适应窗口 / 1:1 查看，但缩放不改变选择时间。

### 5.3 当前时间上下文

右侧始终同时展示：

1. **选中事件**：event name、process/thread、start、duration、category 与参数；没有 event identity 时显示“当前仅选择了时间点”。
2. **邻近日志**：默认窗口为 `[t - 100 ms, t + 100 ms]`，可切换 `±20 / ±100 / ±500 ms`。每行展示 `Δt`、level、tag、message；当前最近一行使用选中态，不只使用颜色。

点击日志只移动时间光标；只有用户明确选择 Trace event 时才更新 event identity。**已选 event 的 identity 与详情面板在光标移走后保留**，并显示偏离标注（如“光标已离开该事件 · 相对 start +966 ms”）——交叉查看事件与邻近日志是排障的基本动作，不应因为看一眼日志就丢失选中事件。日志内容支持复制，默认按 privacy policy 处理动态值。

### 5.4 Timeline 与 Track 顺序

Track 固定按问题定位顺序排列：

1. Marker：用户问题标记、channel start/stop、gap；
2. Screen：Marker 截图、可选视频缩略图和录屏缺口；
3. Frame / Display：vsync、jank、missed frame；
4. CPU / Process / Thread：Trace events；
5. HiLog：按 level 聚合的事件点与密度；
6. 其他平台 track：window/layer/input，仅在有事实时出现。

左侧 Track header 固定，时间内容水平滚动。所有 Track 共用一个 ruler、一个 time cursor 和一个 selection range。滚轮平移、捏合/`⌘+` 缩放、方向键移动光标；`Shift + 方向键` 扩展 range。缩略图、Trace event 和日志 marker 使用原生 button/AX element，并有可见 focus ring。

高频拖动不做自定义动画。光标移动立即更新静态选中态；画面解码未完成时保留 frame metadata 并显示小型 loading，不把旧 frame 标成新时间。

## 6. 时间模型与可信度

Session 只使用单调时间作为内部主轴，墙上时间只用于显示 Session 创建时间。每个 source 必须声明自己的时间域，并提供到 Session time 的映射：

```text
T_session = a × T_source + b
```

`a` 用于描述可证明的 clock drift，`b` 描述 offset。映射至少记录采样点、适用区间、计算方法和 `maxError`；start/end 两端都有校准点时才能对长会话估算 drift。

**承诺分两阶段**：第一版只承诺「同一时钟」与「无法对齐」两态——当前仓内没有任何设备时钟域处理代码（hitrace 未指定 `--trace_clock`、hilog 时间格式未解析、host↔device 无校准机制），任何 ±N ms 数字在 ground-truth 实验（设备侧同一调用点同时写 hilog + trace 标记 + 翻转屏幕颜色，离线量三通道两两偏差分布）量化误差之前都不得出现在产品 UI 中。「已校准 ±N ms」是第二阶段能力；本设计与原型中的 ±12/±8 ms 均为演示值。Marker 位于 host 时域，其映射依赖 host↔device RTT 校准，在 USB 通道上以 ±20 ms 为目标、TCP/UART 上按实测放宽并如实显示。

Viewer 使用三档状态：

| 状态 | 条件 | UI 行为 |
| --- | --- | --- |
| 同一时钟 | source 与 Session 使用同一 monotonic clock，映射无跨进程猜测 | 正常联动，仍显示 frame/log 的实际 `Δt` |
| 已校准 ±N ms | 有 bounded calibration，但存在传输/采样误差 | 正常联动，并持续显示误差上界 |
| 无法对齐 | timestamp 缺失、校准点不足、drift 超限或区间不覆盖 | Track 可独立查看，但禁止自动关联画面、日志与 Trace |

对齐状态按区间计算，不给整个 Session 一个永久绿色结论。设备重启、transport 重连、recorder restart 或 timestamp 回退都会切断 alignment segment；Viewer 在边界画 gap。

## 7. Artifact 与索引

以下名称描述目标形态，不是本轮新增的 normative contract：

### 7.1 Raw / immutable

- `trace.htrace`
- `hilog.txt`
- `screen-recording.mp4`
- `markers.json`
- `clock-calibration.json`
- 现有 `artifact-index.json`、`capture-summary.json`、`capture.log`

### 7.2 Derived / rebuildable

- `video-frame-index.json`：frame number、PTS、keyframe、decode offset；
- `hilog-index.sqlite`：timestamp、level、tag、message offset；
- `timeline-link-index.sqlite`：source timestamp 到 Session time 的映射结果；
- `thumbnails/`：稀疏预览帧。

Derived Artifact 必须记录 source hash、tool identity、参数、size 和 hash。索引损坏时从 immutable raw 重建；不得修改 raw 文件，也不得把 derived 数据导出成“原始设备证据”。

## 8. 隐私、容量与保留

- 所有设备画面、HiLog、UI tree 与 raw Trace 默认标记为 sensitive，本地优先且不自动上传。
- 开始诊断前的 preflight 必须包含宿主 Artifact 存储配额余量检查：当前 Artifact store 配额满时的行为是**拒绝发布而非淘汰旧数据**，失败必须出现在“开始诊断”之前，而不是复现完成后的 finalize 阶段。Session 保留/清理策略（含 Pinned）与第一个实现 change 同车交付。
- 开始前展示预计上限，而不是伪造精确大小；实际上限由 `duration × bitrate`、Trace buffer、log byte budget 和 total Artifact budget 共同约束。
- 达到 byte budget 时明确结束受影响 channel，并在 Timeline 画出截断位置；不能静默丢尾部数据。
- 导出默认选择 Session manifest 和 derived summary，raw video/log/trace 需逐项预览选择。
- Session 删除应先展示将删除哪些 raw/derived Artifact；Pinned Session 不参与自动清理。
- Screen track 可在 UI 中隐藏，但隐藏不是脱敏；导出仍按 Artifact privacy 决定。

## 9. 异常和降级

| 场景 | Viewer 行为 |
| --- | --- |
| Trace 可用，录屏未启用 | Trace 与日志正常；只在 Marker 截图的拍摄时刻显示画面并标注 `+N ms`，其余时间说明“未持续录屏” |
| Marker 截图失败 | Marker 时间点保留；画面区原位显示失败原因（存储不足 / secure surface / 设备离线），不用旧画面或占位图补齐 |
| 自动 Marker 误报密集 | 自动 Marker 可按触发类别在 Timeline 中过滤显示；raw markers.json 不修改 |
| 录屏可用，Trace 解析失败 | 录屏可独立播放；保留 raw Trace 和 parser 诊断，不显示伪 event |
| 日志 timestamp 不可映射 | 日志按原顺序独立查看；不自动滚动到 Trace 光标 |
| 录屏中间断流 | Screen track 画 gap；光标落入 gap 时不显示旧 frame |
| Session finalization 被取消 | 已校验 raw 可列出；terminal 为 Cancelled/Partial，不显示 Ready |
| Artifact hash/size 不一致 | 对应 Artifact 不进入 Viewer，不写 Recent；保留校验错误 |
| target/binding 漂移 | Runtime 停止危险推进；已有证据保留，Session 标记边界和 blocker |

## 10. 可访问性、本地化与键盘

- 页面只有 toolbar 中一个主标题；面板使用连续 heading 层级。
- Timeline 的可见光标同时提供可聚焦 slider 语义，报告当前相对时间和 selected event；每个离散 marker/event 仍可单独 Tab 到达。
- `Tab` 在面板与 composite widget 之间移动；方向键在 Timeline 内移动；`Enter/Space` 选择事件；`⌘M` 添加 Marker；`⌘F` 搜索；`Esc` 关闭 disclosure/sheet 并恢复焦点。
- 状态同时使用 symbol + 文案，不只依赖绿/橙/红；focus ring 至少 2 px。
- 录制状态通过稳定 polite live region 播报。Partial、hash 失败等阻断性结果使用邻近错误说明，不用短暂 toast。
- 200% text/zoom 和 900×600 下，主操作、当前画面 metadata、对齐状态和日志内容仍可达；布局按“当前画面 → 时间上下文 → Timeline”单列重排。
- 中英文使用完整本地化字符串；时间、bytes、duration 按 locale 格式化，ID/hash 使用 monospaced 与 tabular numbers。

## 11. 原型走查

`prototype.html?page=diagnostics` 默认打开**第一版默认形态的演示 Session（无录屏、仅 Marker 截图）**，另有「含录屏」与「Partial + 无法对齐」两个 Session，并必须支持：

1. 点击“新建诊断”进入低干扰/图形 preset 配置，并确认屏幕录制默认关闭、自动 Marker 默认开启、Trace/HiLog 标注环形缓冲回溯；
2. 点击“开始诊断”进入 Recording，并看到“现在开始复现”；采集中看到自动 Marker 触发（演示）；
3. 选择“标记并截图”或按 `⌘M`：Marker 立即记录，截图先显示“正在截图…（事后拍摄）”，完成后显示“拍摄于标记后 +N ms”；
4. 点击“停止并生成结果”，生成一个新的 marker-only Session 并打开联动 Viewer，光标落在第一个 Marker；
5. 点击视频缩略图、Marker 截图、Trace event 或日志后，共享光标和三处上下文同步；已选 event identity 不被非事件点击清空，并显示“光标已离开该事件”偏离标注；
6. 使用 Timeline slider 的方向键移动时间；
7. 打开对齐 disclosure 查看 per-source 明细；切换到 Partial Session 验证「无法对齐」的 HiLog 独立查看、截图失败原位说明与 Partial 横幅；
8. 走查 light/dark、1180×760、900×600、200% zoom 与 Reduce Motion；
9. 始终看到“演示数据，不代表 production availability”的边界说明（环形缓冲、自动 Marker、时钟校准包含在内）。

## 12. 分阶段实现建议

0. **Spike（先于一切实现）**：hitrace 环形模式与 `--trace_clock` 支持面；`snapshot_display` 延迟与扰动；host↔device 时钟校准误差分布（ground-truth 实验）；hilog 缓冲区覆盖能力。量化门槛见 chg-2026-071 verification。
1. **Session reader**：先让现有 `trace.htrace + hilog.txt + screenshot.png` 以同 Job identity 打开，并只在有时间事实时联动；单张截图标注 capture time 与 `+N ms` 事后标注，不称为视频 frame。对齐只做「同一时钟 / 无法对齐」两态。
2. **Ring-buffer capture + Marker**：通过 reviewed behavior delta 把 capture.diagnostics 改造为环形缓冲回溯模式，新增 Marker track、自动 Marker 与会话内截图准入语义（chg-2026-071 的核心范围）。
3. **Optional screen recording + clock calibration**：通过 reviewed operation/Provider contract 增加显式录屏、并发 channel boundaries 和 calibration Artifact；默认低干扰路径仍保持录屏关闭；「已校准 ±N ms」在此阶段随 ground-truth 数据启用。
4. **Linkage indexes**：建立视频 frame、HiLog 和 Trace 的 derived index，完成按需解码与 range 查询。
5. **Graphics profile**：在平台 Provider 能提供 reviewed window/layer/input facts 后增加对应 Track；缺失平台能力保持 unavailable，不用 Core 豁免。

Android 交互参考 Winscope 的逐帧状态查看，时间数据模型参考 Perfetto；iOS 参考 Instruments 的 Display/vsync 与 Signpost lane。ArkDeck 不复制某个平台的私有格式，而是统一表达“source time → Session time → 可见误差”。
