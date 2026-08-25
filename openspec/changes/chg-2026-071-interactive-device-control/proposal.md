---
id: CHG-2026-071-interactive-device-control
revision: 1
status: proposed
class: capability
core_change_level: none
owner: fuhanfeng
core_baseline: CORE-3.0.0
platforms: [macos]
---

# CHG-2026-071 — 交互式设备控制与环形诊断采集

> **本文件不构成批准。** 本 proposal 经维护者 review/merge 进 protected
> `main` 后，Task 方可开始实现 PR。
> 设计输入：`docs/design/diagnostic-mode-design.md`（v1.3）、
> `docs/design/toolkit-device-control-design.md`（v1.3）、
> `docs/design/macos-ux-interaction-spec.md`（v1.3）§5.5/§5.6、
> `docs/design/prototype.html?page=diagnostics|tools`（v1.3 可点击事实）。

## 背景

2026-08-25 的设计评审（Diagnostics + Toolkit v1.2）确认两份设计的信息架构
与诚实性原则成立，但按当前 Runtime 事实落地会得到「看起来能用、真实排障
时不好用」的产品。四个决定性事实（均已在仓内核实）：

1. **没有输入与独立截图 operation**。`Catalog/operations/` 25 个描述符中无
   tap/swipe/screenshot；设备命令面已有 `uitest uiInput
   click|longClick|swipe|…`（`DEVICE-COMMAND-FACTS.md` §7）与
   `snapshot_display -t png`（真机验证 449,756 B / 720×1280）。
2. **每输入一个完整 Job 的固定成本是秒级**。6 步只读 Job 用进程内假
   dispatcher 的契约测试实测空载 0.98 s、负载 2.4–7.1 s（PR #1080 记录）；
   每 Job 含 5 步证据前导（`list targets -v` + 2×`param get` + `df -k`）、
   ~16 次 journal 追加（每次 fsync+F_FULLFSYNC+目录 fsync）、每次 hdc
   spawn 前对整个 hdc 二进制重算 SHA-256（无缓存）。tap 属 deviceMutation
   → per-device mutation lane 严格串行、队列无上限；相同坐标 + 相同
   idempotency key 会被静默去重。
3. **采集会话与会话内操作互斥**。含 trace 落盘 + cleanup 的
   `capture.diagnostics@1` 升级为 deviceMutation 并持有 mutation lane 直到
   结束；`uiScreenshot` 腿同样升级（截图不是 read-only）——「标记并截图」
   与「Toolkit 复现 + Diagnostics 取证」在当前语义下被结构性阻塞。
4. **当前采集顺序拿不到「问题前」的现场**。lowering 顺序为 hilog `-x`
   drain（回溯过去）在前、`hitrace -t N` 阻塞采集（覆盖未来）在后，两者
   不覆盖同一区间；偶现问题出现在人点击标记之前，任何「点击时开始取证」
   机制恒慢一拍。

## 目标

一句话：**让「先复现、后取证」成立，让「直接操作真机」不撒谎。**

1. **环形诊断采集（capture.diagnostics@1 行为 delta，沿用 CHG-2026-049 的
   「加 typed input 不加 operation」先例）**：Trace 以环形模式驻留
   （`hitrace --trace_begin/--trace_dump/--trace_finish`，Spike 确认），
   Marker/停止时回溯保存覆盖 Marker 前 ≥10 s 的窗口；HiLog 继续用 `-x`
   的天然回溯性；新增 `markers.json` Artifact（host 时间点 + 种类）；
   自动 Marker v1 在 finalize 阶段从已回溯的 trace/HiLog 按特征反推
   （frame deadline missed / crash / 关键字），不需要实时流式处理。
2. **交互式设备输入（新 operations：`input.tap@1`、`input.long-press@1`、
   `input.swipe@1`）**：`uitest uiInput` lowering，`-t <connectKey>` 绑定，
   成功判据沿用已记录的 stdout 白名单；每个 intent 绑定画面 epoch 与
   display facts，排队超时作废不补发；每次 pointer sequence 铸新
   idempotency key（连续两次同坐标点击是两个意图，不得被去重吞掉）。
3. **会话内准入语义（in-session admission）**：采集会话持有 lane 期间，
   Marker 截图与（可选）输入以会话拥有的封闭子意图形式执行，逐条
   intent-before-effect 记账；无该语义的路径一律 fail closed 并给 typed
   reason，不静默排队。具体机械形状见 `design.md`（含一处需要维护者
   裁决的 durability 取舍）。
4. **Toolkit 第一版产品面**：按需截图（新增 JPEG 腿用于预览/合成，
   PNG 保留为证据格式）、tap/longClick/swipe（两态触点：pending ≤100 ms
   → confirmed）、宿主逐帧合成录屏（Assembling → Validating → 原子发布，
   无设备残留）、预览实测帧率 + 画面年龄常显、过期输入暂停。
5. **量化门槛是发布条件不是愿望**：tap 端到端 p95 ≤ 400 ms；不达标则
   Toolkit 输入退回「截图上点选 → 显式确认发送」形态，不带着秒级延迟
   假装可以直接点击。

## 诚实边界

- 第一版时间对齐只承诺「同一时钟 / 无法对齐」两态；「已校准 ±N ms」在
  IDC-AC-4 的 ground-truth 实验量化误差之前不进产品 UI（设计与原型中的
  ±12/±8 ms 均标注为演示值）。
- 截图是事后取证：UI 固定标注「拍摄于 Marker 后 +N ms」；截图动作自身的
  执行区间在 Timeline 上画为 instrumentation 痕迹。
- 5 fps 预览是目标值：UI 显示实测帧率；宿主取帧链路上更现实的量级是
  1–2 fps，以 Spike 实测为准。
- 宿主合成录屏按实测帧率标注（如 `2.1 fps · 宿主合成`），取帧断流保留为
  可见 gap，不插值补帧。
- 录屏/会话开始前 preflight 必须含宿主 Artifact 配额余量检查（配额满是
  拒绝发布而非淘汰，失败必须发生在开始前）。

## 非目标（显式排除，避免范围蔓延）

- 设备侧编码录屏（720p·15fps preset + Receiving 链）：OHOS 无已知命令面，
  需要 helper 或新平台能力——另立 change，且依赖下一条。
- 跨 Job 可寻址的 remote artifact reference（「重新拉取」）：当前设备路径
  由 jobID 铸造、`file recv` 不可续传，属新 Runtime 面——另立 change。
- 流式预览传输通道（XPC 推送）：v1 预览用按需截图轮询表达。
- `已校准 ±N ms` 校准 Artifact 与视频 PTS 联动（阶段 3）。
- 图形诊断 preset 的 window/layer/input Track；「关联到诊断」；Android/iOS。

## 影响面

`Catalog/operations/`（3 个新 input operation + capture.diagnostics 的
additive typed inputs 与 markers.json artifact，走 codegen）、
`Packages/ArkDeckKit/Sources/ArkDeckWorkflows/DeviceProviders/`（uiInput
lowering、ring-trace 三段 lowering、JPEG 截图腿、成功判据）、
`RuntimeJobEngine` / `RuntimeCapabilityStore`（in-session admission；见
design.md）、`ArkDeckAgentDaemon` + `AgentXPCContract`（新 job kind 与
client 白名单）、`ArkDeckApp/Features/`（Toolkit 工作区、Diagnostics
Session reader）。零 raw HDC、零任意远端路径；App 只提交 operation
reference + typed inputs。

## Golden Journey

GJ-2（HAP Debug 的证据质量：复现窗口 + 联动查看）与 GJ-5（Bounded AI
Debug Loop 的 Artifact 输入面：markers + 回溯窗口是 AI 分析的时间锚点）。
本 change 与 GJ-2/GJ-5 交付同车，不是独立治理项目。
