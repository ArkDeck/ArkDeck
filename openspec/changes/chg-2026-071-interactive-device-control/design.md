# Design — CHG-2026-071

> 本文记录机械形状与被拒绝的替代方案。行为词表以 proposal 与两份
> `docs/design/*-design.md`（v1.3）为准。

## 1. 为什么不能「每输入一个 Job」

仓内已实证的固定成本（详见 proposal 背景）：证据前导 4 次 hdc spawn、
~16 次 journal 追加（每次 3 组 fsync）、2 次 capability 文档整写、每次
spawn 前 hdc 二进制全量 SHA-256、mutation lane 串行 + 无上限排队 +
idempotency 静默去重。空载假 dispatcher 已 0.98 s；真实链路只会更慢。
交互输入的体验门槛是 p95 ≤ 400 ms、pending 反馈 ≤ 100 ms——两者相差
一个数量级，不是优化能弥合的，是形状问题。

被拒绝的方案：

- **A. 每输入一个完整 Job**：如上，拒绝。
- **B. 走 `DebugRuntimeProbe` 形状**：probe 是 readOnly-by-construction
  （不落 journal、不消耗 capability、无 mutation lane），把 mutation 塞进
  probe 面会绕开统一安全内核——PRODUCT-LOOP §12 明令禁止的形态，拒绝。

## 2. 选定形状：Interactive Control Session（C）

一次显式的「进入真机操作」动作向 Runtime 申请一个 **session-scoped
standing capability**（device + binding revision + 封闭输入模板集 +
TTL + 预算：maxInputs / maxWallClock），一次性走完整 admission（含
evidence preflight 与 lane 获取）。会话存续期间：

- 每个输入 intent 仍逐条 **intent-before-effect** 记入会话拥有的
  append-only input ledger（保留 outcomeUnknown / 不重放语义与崩溃恢复），
  但**免去逐输入的 plan 重物化、capability 文档整写与证据前导**——这些
  在会话准入时做一次，之后按「binding revision / display facts 未漂移」
  的轻量校验守门，漂移即 fail closed 结束会话；
- 会话持有该设备的 mutation lane；会话内输入是 lane 拥有者的子意图，
  与「采集会话内的 Marker 截图」共用同一机械（见 §4）；
- 会话结束（显式退出 / TTL / 预算耗尽 / 漂移 / 断连）时结清 ledger 并
  `recordOutcome`；恢复语义沿用现有 journal replay——恢复只结算，不派发。

**需要维护者裁决的一处 durability 取舍**：input intent 的 journal 追加
若沿用每条 F_FULLFSYNC×2 + 目录 fsync，成本由 IDC-AC-1 的 Spike 实测；
若实测超出延迟预算，备选是会话内 group-commit（有界丢失窗口：崩溃时
最后一组未 fsync 的输入 intent 可能丢失记录——丢的是「审计行」，不是
「未记账的副作用」，因为丢失窗口内的 dispatch 同样未发生）。两个选项都
保持 intent-before-effect 的相对顺序；选择权在维护者，Spike 数据先行。

## 3. 输入 operations 与 lowering

- `input.tap@1` / `input.long-press@1` / `input.swipe@1`：
  `["-t",<connectKey>,"shell","uitest","uiInput",
  "click|longClick|swipe",…coords…]`；swipe 若设备参数为速度而非时长，
  由 Provider 按距离/时长换算并把换算记入 disclosure。成功判据沿用
  DEVICE-COMMAND-FACTS §7 的 stdout 白名单（exit 0 且不含
  `illegal|fail|error|incorrect|…`）。
- typed inputs 携带：设备坐标（App 侧已做 content-rect 映射与钳制）、
  duration、**画面 epoch**（截图时间戳/预览帧序号）、display facts
  快照。dispatch 前校验 epoch 对应 facts 未漂移；在队列滞留 > 1 s 的
  intent 直接作废（typed reason：`inputExpired`），绝不迟发。
- **idempotency**：每个 pointer sequence 铸新 key。连续两次同坐标 tap
  是两个独立意图；现有「同 key 同请求去重」语义对交互输入是错误的，
  必须避开（新 key 即避开，无需改 admission）。

## 4. 环形采集与会话内截图

- capture.diagnostics@1 增加 additive typed inputs：`ringBuffered`
  （选择 `--trace_begin/--trace_dump/--trace_finish` 三段 lowering，
  替代 `-t N` 阻塞式）、`markers` 通道开关。新 Artifact：`markers.json`
  （host 时间点、种类 manual/auto、触发特征、截图关联）。不新增
  operation（沿用 CHG-2026-049 r5 uiScreenshot 的先例）。
- 会话运行期间的「标记并截图」：Marker 是 host-owned annotation（零设备
  交互，零延迟）；截图作为**会话拥有的子意图**走 §2 的同一机械（会话已
  持有 lane，无需第二个 Job 排队）。截图 Artifact 记录实际拍摄时刻。
- 自动 Marker v1 在 finalize 从回溯产物反推（无实时流处理）；实时提示
  是后续增强，不进本 change。
- Toolkit 与 Diagnostics 对同一设备并发：v1 仍互斥（一个设备同时只有
  一个 lane 拥有者），但失败是显式 typed reason（`deviceBusyBySession`），
  不是静默排队。「诊断会话内用 Toolkit 复现」= 未来把 Toolkit 输入也
  注册为该会话的子意图，机械已就位，范围留给后续 change。

## 5. Toolkit 录屏（宿主合成）与截图 JPEG 腿

- `snapshot_display -t jpeg` 腿（41 KB vs 449 KB，11×，已实测）用于预览
  轮询与录屏取帧；PNG 腿保留为证据格式。JPEG 腿的魔数校验换 JFIF。
- 录屏 = 会话内按预览链路循环取帧（实测节奏，不承诺 5 fps），停止后
  宿主用 AVAssetWriter 合成 MP4，Validating（byte count / SHA-256 /
  容器可读）后原子发布。无设备端驻留文件，无 Receiving 链。取帧间隔
  超过阈值的段落写入 gap 元数据，Viewer/播放侧如实呈现。
- 开始前 preflight：宿主 Artifact 配额余量（复用 `preflight-host-storage`
  形状）。

## 6. App 面

- Toolkit 工作区按 `toolkit-device-control-design.md` v1.3：两态触点、
  长按不降级、tap 锚定 down 点、stale 遮罩与输入暂停、非闭集手势就地
  提示、结果条含实测帧率与「再录一段」。
- Diagnostics Session reader 按 `diagnostic-mode-design.md` v1.3 §12
  阶段 1：同 Job identity 联动、两态对齐、`+N ms` 事后标注、event
  identity 保留、Partial/无法对齐降级（原型三个演示 Session 即验收
  基线形态）。
- XPC：新 `AgentXPCAppJobKind`（controlSession / input / sessionCapture）
  进 `AgentXPCContract` 白名单；App 侧新 facade，不触碰设备。
