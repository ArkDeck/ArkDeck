# TASK-IDC-001 — 真机 Spike 测量束 · run r1

> Date：2026-08-25（同日两段：锁屏段 + 解锁监督窗口补测段；后者覆盖滚动扰动与
> hilog 负载收缩，见 §2b/§6）
> Device：connect key `5SM0125725000252` · target `TGT-1a62a0dbedd6`（binding r1，2026-08-22 接管）·
> `const.product.model=ohos` · `const.ohos.fullname=OpenHarmony-7.0.0.39` · root shell ·
> 显示 1280×2832（**与仓内旧实测 720×1280 不同**，7.0 固件/面板配置已变）· 全程锁屏（充电，100%）
> Host：本机 macOS · hdc 3.2.0f（DevEco SDK）· 生产 agentd（launchd `com.arkdeck.agentd`，
> catalog digest `be7b7361…` 与 HEAD 一致，wire 兼容）
> Harness：`harness/measure.py`（每条设备命令均 `-t <connectKey>`；输入只注入锁屏惰性坐标
> (640,1500)，前后截图确证无副作用）。原始 trace dump（~29 MB）不入库，`data/*.json` 记录
> byte 数与 SHA-256；hilog 内容不入库（敏感），只记跨度统计。

## 1. 输入延迟（IDC-AC-1）

| 路径 | p50 | p95 | n |
|---|---:|---:|---:|
| Tier 0 · `hdc shell echo`（每次拉起客户端，传输地板） | 102.8 ms | 113.0 ms | 50 |
| Tier 1 · `uitest uiInput click`（裸命令） | **377.0 ms** | **395.9 ms** | 50 |
| Tier 1 · `uiInput swipe`（20 px） | 303.8 ms | 313.6 ms | 15 |
| Tier 1 · `uiInput longClick`（含按住时长） | 1775.6 ms | 1823.2 ms | 15 |
| Tier 2 · daemon probe 面（`trace probe`，~5 次设备读） | 438.7 ms | 459.7 ms | 20 |
| Tier 3a · 只读全 Job（`observe.device@1`，0 失败/8） | 578.3 ms | 619.1 ms | 8 |
| Tier 3b · mutating 全 Job（`capture.diagnostics@1` + uiScreenshot，0 失败/6） | **3339.5 ms** | **3677.8 ms** | 6 |
| 持久通道 · 长驻 `hdc shell` 内 `echo`（PTY，哨兵引号拆分防回显误配） | **10.0 ms** | 12.6 ms | 20 |
| 持久通道 · 长驻 shell 内 `uiInput click` | **316.2 ms** | **406.2 ms** | 15 |

分解与结论：

- 每次拉起 hdc 客户端的固定成本 ≈ **93 ms**（102.8 → 10.0）；`uiInput` 设备端自身执行
  ≈ **306 ms**（进程启动 + 注入），是不可绕开的大头。
- **裸命令 p95 = 395.9 ms 已把 400 ms 门槛吃满**；任何"按次拉起 uitest"的形状（无论
  Runtime 加多少优化）都无法稳定达标。持久通道 + 逐条 uiInput = p50 316 / p95 406——
  贴线但 p95 仍越线。
- **Tier 3b = 3.3–3.7 s：'每次点击一个完整 Job' 判死刑**（超门槛 8×）。Tier 3a 578 ms
  说明 Runtime 自身叠加其实很瘦（见 §5），大头在设备往返与截图腿本身。
- 达标路径：设备侧常驻注入器。`uitest start-daemon <token>` 在本固件存在（help 实测），
  即 arkxtest 常驻测试进程——接其协议属 T02 工程项，预期把注入压到几十 ms 级（未测，
  不作数字承诺）。
- **IDC-AC-1 判定：三档测量完成（方法达成）。产品门槛结论 = per-invocation 不可行，
  T02 的形状必须包含设备侧常驻注入；在其落地前，Toolkit 输入按 verification 预案退回
  「截图上点选 → 显式确认发送」形态。**

## 2. 截图（IDC-AC-2）

| 项 | p50 | p95 | bytes |
|---|---:|---:|---:|
| `snapshot_display -t jpeg`（仅捕获） | 588.4 ms | 643.1 ms | — |
| `snapshot_display -t png`（仅捕获） | 852.0 ms | 860.6 ms | — |
| JPEG 端到端（capture+ls+recv+rm，产品腿形） | **876.6 ms** | 922.0 ms | ~87 KB |
| PNG 端到端 | 1196.3 ms | 1229.8 ms | ~806 KB |

- **JPEG p95 922 ms ≤ 1.5 s ✓ PASS；PNG p95 1230 ms ≤ 2.5 s ✓ PASS**。JPEG/PNG 体积比
  ~1:9.2（87 KB vs 806 KB），支撑「JPEG 预览腿 + PNG 证据腿」的双腿设计。
- 静态锁屏下连续 8 次 JPEG 捕获 464–559 ms，稳定（`snapseries.json`）。

### 2b. 滚动负载下的截图/录屏扰动（解锁监督窗口补测）— 已量化

方法：前台内容瀑布流 app（图片密集、真实渲染负载），fling-only 不点击；帧锚点
`H:RSMainThread::DoComposition`；三阶段各自独立 graphic-only trace 会话
（20 MB 缓冲防回卷）；每次截图由设备侧 trace_marker 括出精确窗口；驱动为持久
`hdc shell`（PTY）。数据：`perturb.json`。

| 阶段 | 帧间隔 median | p95 | p99 | 截图窗口内最大帧隙 |
|---|---:|---:|---:|---:|
| 基线滚动（6 fling） | 8.37 ms | 16.74 ms | 50.30 ms | — |
| 滚动 + 每 fling 一张 JPEG | 8.38 ms | 16.78 ms | 29.96 ms | **29.96 ms**（3 窗口） |
| 滚动 + 连拍 ~1.4 张/s（v1 宿主合成录屏负载） | 8.37 ms | 16.73 ms | 41.57 ms | **83.94 ms**（6 窗口） |

- 面板实测 **120 Hz**（median 8.37 ms）。三阶段 median/p95 完全一致：**截图对滚动
  帧率的稳态影响 ≈ 0**；p99/max 受 fling 收尾的相位性长间隔影响，三阶段等同存在
  （janks 计数同为 8），不构成阶段间差异。
- **单张事后截图**：窗口内最大帧隙 29.96 ms ≈ 3.6 vsync @120 Hz——超出"≤1 vsync"
  理想门槛 ⇒ 按 AC-2 预案，**Timeline 上的截图 instrumentation 痕迹确认为 T03
  必做项**（设计 §4.4 已含）；除此之外扰动可接受。
- **连拍（录屏负载）**：个别窗口出现 ~84 ms（~10 vsync）可感知 hitch——Toolkit
  「录屏可能影响设备性能」提示自此有量化依据；宿主合成录屏期间的 jank 判读必须
  结合 instrumentation 痕迹排除自伤。
- 设备侧截图窗口自测时长 443.9–462.2 ms（marker 括号，与 §2 的 host 端计时相符）。
- 标记完整性：穿插阶段 6 对 marker 落 3 对、连拍 12 对落 6 对（PTY 驱动下部分
  marker echo 未落笔，成因未深究）；已落窗口的度量不受影响，窗口计数如实记录。

## 3. 环形缓冲（IDC-AC-3）— PASS

- `hitrace --trace_begin/--trace_dump/--trace_finish(_nodump)` 全部存在且实测走通；
  `--trace_clock` 支持 `boot(默认)/global/mono/uptime/perf`（help 实测）；默认缓冲
  18432 KB，默认满时**丢最早**（即环形语义），`--overwrite` 反转。
- 功能实测（categories：sched freq graphic ace app ohos）：arm 后 15 s dump₁ 覆盖
  **16.4 s** 连续窗口（11.5 MB / 80k 行）≥ 10 s 门槛 ✓；30 s dump₂ 覆盖 31.9 s
  （16.8 MB）——同一 first_ts，缓冲未回卷。dump 命令自身 ~330–400 ms。
- 另实测 **snapshot-mode trace 服务**：`--start_bgsrv / --dump_bgsrv / --stop_bgsrv`
  全链路可用，dump 落 `/data/log/hitrace/trace_<wall>@<boot>-<n>.sys`（raw 格式，
  文件名内嵌 boot 时戳）。**对会话形态这是比 begin/dump 更好的载体**（服务持有、按需
  快照、raw 可直接喂 TraceStreamer）；T03 的 lowering 建议优先评估 bgsrv。
- 本次 spike 产生的设备端文件已逐一删除（bgsrv dump 亦然）；`/data/local/tmp` 零残留。
- **容量数据点**：graphic+ace+ohos 三类目在滚动+截图负载下，40 MB 环形缓冲 **<70 秒
  即回卷**（首轮合并实验的 78 MB 文本 dump 只剩尾部 17/42 个 marker，留档
  perturb-wrapped）；graphic 单类目下 20 MB 覆盖 24 s 仅用约半仓（38 MB 文本）。
  ⇒ T03 的「回溯 ≥10 s」在默认 18 MB 下对全类目**不宽裕**，回溯窗口与类目集必须
  联动预算，且 dump 后应立即重臂避免长会话丢头。

## 4. 时钟（IDC-AC-4）

- **trace_marker↔realtime 桥**：30/30 marker 命中（环形 trace 内），单次 shell 内
  `trace_marker 写入 → date +%s.%N` 配对，realtime−boot 偏移序列 **spread = 9.74 ms**
  ——Trace(boot) ↔ HiLog(realtime) 的时钟层映射误差包络 **< ±10 ms，优于 30 ms 门槛
  ✓**（残差：hilog 自身打戳抖动未单独量化，见 §7）。
- **时钟域陷阱（重要发现）**：本内核 `/proc/uptime`（51 229 s ≈ 14.2 h，不含睡眠的
  monotonic）与 ftrace boot（204 248 s ≈ 56.7 h，含睡眠 boottime）相差 **42.5 h**；
  与 hilog 最早行（08-23 02:56 开机 ≈ 56.7 h 前）互证。⇒ 任何“boot 时基”不经桥接
  不可互换；`ring.json` 中 `coverage_back_from_dump_s` 为负即此跨域错算的现场标本
  （harness 保留原样，正确口径为 trace 域内跨度，已在 §3 采用）。
- **host↔device（USB）**：hdc 往返 RTT p50 104 / p95 111 / min 76.9 ms；60 次中点法
  offset 复现性 **±7.0 ms（p95 |dev|）**、全程 spread 17.3 ms——但绝对偏差受 RTT
  不对称界（≈ ±RTT_min/2 ≈ ±38 ms），**朴素中点法达不到 ±20 ms 门槛**。
- **架构结论（推荐给 T03）**：Marker 不做 host 时钟映射——**Marker 即设备侧
  `trace_marker` 写入**，与 trace 同域零跨钟误差；host 点击→marker 落笔的传输延迟
  （持久通道 ~10 ms / 每次拉起 ~103 ms）成为唯一且单侧的偏差，可随 marker 一并记录。
  ±20 ms 门槛在该机制下自然满足，无需 RTT 校准。

## 5. Runtime 固定成本（design.md §2 durability 裁决输入）

- journal durable append（本机 SSD，`ARKDECK_RUN_LONG_JOURNAL_TESTS=1` 实测）：
  **3.6–5.3 ms/条**（fileSync 2.9–4.6 ms + dirSync ~0.16 ms；100/1000/10000 历史事件
  三档一致，`journal-append-bench.txt`）。⇒ **逐条 input intent 记账（intent+outcome
  ≈ 2 条 ≈ 8 ms）在延迟预算内可负担；group-commit 不必要**——建议 design.md §2 取
  「保持全量 durability」项，无需维护者在丢失窗口上做权衡。
- hdc 二进制逐次重哈希：6.0 MB，**~2.2 ms/次**（页缓存热）——评审时列为风险，实测
  可忽略；真正的大头是传输地板与 uitest 进程启动（§1）。
- 只读全 Job（Tier 3a）578 ms vs 其含 ~5 次设备往返（~500 ms）⇒ Runtime 叠加
  ≈ 几十 ms 量级，与 journal/记录成本估算吻合。

## 6. hilog（覆盖与格式）

- 缓冲：app 512 K / core 512 K / init 64 K / only_prerelease 512 K（`hilog -g`）。
- 空闲（锁屏）实测：`hilog -x` 一次 drain 8 464 行 / 跨度 **≈ 2.3 天**。
- **交互负载实测（`hilog-load.json`，按 type 分测）**：解锁 + 前台内容 app 时，
  app 缓冲回溯 **4.2 分钟**、core **2.3 分钟**；跑完扰动工作负载（fling + 截图 +
  trace 采集）后，app **9.2 分钟**、core 仅 **85 秒**。⇒ 回溯窗口随负载从"天"塌缩到
  "分钟/秒"级，且**诊断采集自身就是冲刷源**（反馈效应）。T03 对超过 ~1 分钟的会话
  不得依赖 hilog 天然回溯：需在 arm 时按会话时长扩容（`hilog -G`，结束恢复原值）
  或会话中周期性 drain 落盘，二者取一并写进 lowering 契约。
- 时间戳格式 `MM-DD HH:MM:SS.mmm`（realtime，无年份），与 §4 桥接结论衔接。
  另：core 类目 drain 含非 UTF-8 字节（实测 0xd2），宿主侧解析必须按
  bytes + 宽容解码处理，不能假设合法 UTF-8。

## 7. 偏差与残留

1. **AC-4 方法偏差（已声明）**：verification 写的是“测试 HAP 对拍”；本轮用 shell 级
   等价物（trace_marker+date 桥 + uiInput 跨通道事件）完成了时钟层判定。App 层打点
   延迟（hilog 写→戳抖动、应用内 trace 点）未覆盖——若维护者要求 app 层数字，需按
   原案构建测试 HAP（工程量：构建+签名+安装）。
2. ~~AC-2 滚动扰动~~ **已于解锁监督窗口补测**（§2b：单张截图窗口内最大帧隙
   29.96 ms、连拍 83.94 ms，稳态 median/p95 零影响）。
3. ~~hilog 重负载覆盖~~ **已补测**（§6：真实交互负载 + 采集自身负载下 core 塌缩到
   85 秒；未用合成泛洪源，极限泛洪可由测试 HAP 兼做，非阻塞）。
4. `uitest start-daemon` 存在性已证，**协议与延迟未接**——T02 实现项，不在本 spike
   下结论。
5. 扰动实验的 trace_marker 落笔率不足（穿插 3/6、连拍 6/12 对成对命中），成因未
   深究；不影响已落窗口的度量结论，但 **T03 实现 Marker lowering 时必须加落笔
   回读确认**，不能假设 echo 即落笔。
6. 本 spike 在生产 daemon 留下 ~16 个真实 Job（observe.device ~10 + capture.diagnostics 6；
   首轮 CLI 侧拒绝的提交不落库）与对应 artifact（History 可见，操作名即自解释）；
   40 次 trace probe 按其契约不产生 Job/journal/artifact。设备端零残留文件。

## 8. 门槛判定汇总（对照 verification.md）

| AC | 判定 |
|---|---|
| IDC-AC-1 | 方法完成；**per-invocation 不达标为定论**，T02 形状必须含设备侧常驻注入（`uitest start-daemon` 为既证载体），落地前 Toolkit 输入走显式确认预案 |
| IDC-AC-2 | **PASS（全项完成）**：延迟 JPEG 922 ms ≤ 1.5 s、PNG 1230 ms ≤ 2.5 s；扰动已量化（§2b）——单张截图窗口内最大帧隙 29.96 ms（>1 vsync ⇒ 按预案 Timeline instrumentation 痕迹确认为 T03 必做）、连拍 83.94 ms、稳态 median/p95 零影响 |
| IDC-AC-3 | **PASS**（16.4 s ≥ 10 s；clock/环形语义/bgsrv 均实证）|
| IDC-AC-4 | 时钟层 **PASS**（桥 spread 9.7 ms ≤ 30 ms）；host 映射改道 trace_marker 机制（±20 ms 门槛被机制替代性满足）；app 层残留 |

数据正本：`data/*.json`、`data/journal-append-bench.txt`；harness：`harness/measure.py`。
