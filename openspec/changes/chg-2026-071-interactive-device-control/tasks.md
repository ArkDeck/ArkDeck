# Tasks — CHG-2026-071

三个垂直 Task。`ready` 只有在本 proposal PR 经维护者 review/merge 进入
protected `main` 后生效；合入前不得开始实现 PR。实现 PR 推 `agent/**`
分支由 CI 以 bot 身份开 PR，标题声明 Task ID，先跑
`scripts/check_pr_paths.py --preflight` 并直接看退出码。
**T01 的真机结论是 T02/T03 的准入门**：Spike 数据未落 evidence 前，
T02/T03 不进入实现。

## TASK-IDC-001 — Spike：真机测量束（决定架构，不产出产品面）

- Status:done（2026-08-25 测量收官，见 `evidence/runs/TASK-IDC-001/run.md`：三档输入
  延迟 + 持久通道分解（裸 click p95 396 ms 吃满门槛 ⇒ T02 必须做设备侧常驻注入）、
  截图双格式 PASS、滚动扰动已量化（单张窗口内最大帧隙 30 ms、连拍 84 ms、稳态零
  影响 ⇒ instrumentation 痕迹为 T03 必做）、hitrace 环形与 bgsrv 实证 PASS（含
  40 MB/三类目 <70 s 回卷的容量数据）、时钟桥 spread 9.7 ms + /proc/uptime 与
  ftrace boot 相差 42.5 h 的时基陷阱 ⇒ Marker 走设备侧 trace_marker、hilog 覆盖在
  采集负载下塌缩到 core 85 s ⇒ 会话需扩容或周期 drain、journal append 3.6–5.3 ms/条
  ⇒ design.md §2 建议保持全量 durability。**开放项已裁决（2026-08-25，维护者）：
  durability 保持全量（design.md §2 已更新）；AC-4 的 shell 级等价物被接受为方法，
  app 层 HAP 对拍不补做。本任务无剩余开放项**）
- Golden Journey:GJ-2（测量不改行为；结论决定后续形状）
- Platform:macos + DAYU200（OpenHarmony 5.0.0.71）
- Acceptance:IDC-AC-1..4（见 verification.md）
- 交付内容（全部落 `evidence/runs/TASK-IDC-001/`，含原始数据与方法）：
  1. **输入延迟三档**：`uitest uiInput click` 裸命令（热 hdc server）/
     probe 形状轻量面 / 完整 Job 链路，各 ≥50 次取 p50/p95；顺带记录
     hdc 二进制重哈希与证据前导的单项耗时。
  2. **截图**：`snapshot_display` PNG 与 JPEG 的捕获延迟 p50/p95；标准
     滚动负载下单次截图注入的渲染停顿（vsync 计）。
  3. **hitrace 环形能力**：`--trace_begin/--trace_dump/--trace_finish`
     在目标固件上的存在性、dump 对 Marker 前 ≥10 s 的覆盖、
     `--trace_clock` 支持面与默认时钟；hilog 缓冲区在重日志负载下对
     60 s 窗口的覆盖率（`-g`/`-G` 现状一并记录）。
  4. **时钟 ground-truth**：测试 HAP 每秒同一调用点写 hilog + trace
     标记 + 翻转屏幕颜色；60 s 采集后离线量 Trace↔HiLog 偏差分布与
     drift；host↔device RTT 校准（USB）误差分布。
  5. 结论页：对照 verification.md 的量化门槛逐条给出 PASS / FAIL /
     形状调整建议（含 design.md §2 durability 取舍所需的 fsync 实测）。

## TASK-IDC-002 — 交互式输入 + Toolkit 真机操作（垂直交付）

- Status:in-progress（2026-08-25。已交付 ① typed input operations + Provider lowering
  + 契约测试 + 真机单发验证（#1498）；②a 会话 scope 授权 + TTL/预算（#1500）；
  ②b 帧 epoch 与超时作废 + display facts 漂移 fail-closed + 帧内坐标界（#1502）。
  **Spike 的达标路径结论已被 T02 实测推翻并取代**：`uitest start-daemon` 对 uiInput
  延迟零影响（CLI 不是它的客户端），瓶颈是 uitest 二进制启动本身（不注入也要 301 ms）；
  既证达标载体是 `uinput -T`（p95 333 ms < 400 ms 门槛），代价是失去设备侧坐标校验，
  使 ②b 的 host 侧帧内界从纵深防御变为唯一防线。证据
  `evidence/runs/TASK-IDC-002/data/injection-path-comparison.json`。
  ③ Toolkit App 面 + XPC facade + uinput lowering 已交付（#1507/#1509）。
  ④ 会话内轻量派发：前导的三步里只有身份确认是防错设备的那一步，且它由 host 侧
  hdc server 应答（p50 35 ms），型号与固件各是一次设备往返（各 p50 150 ms）。会话
  沿用后两者、每次手势仍重读身份 —— 二者都改不了而连接不断（改任一都要重启或重刷，
  两者都会断连），身份复核就是沿用成立的依据。实测前导 292 → 32 ms，每次手势省
  258 ms。沿用过的观察记 `machineReadbackSessionCarried` 与逐片 `carriedFromUTC`，
  这同时是 fail-closed：硬件证据契约只认 `machineReadback`，沿用过的观察因此无法被
  投影成任何硬件证据。证据 `evidence/runs/TASK-IDC-002/data/session-carried-evidence.json`。
  ⑤ capability 使用台账改追加式。开工持久通道前先量了 Runtime 自身开销（设备侧全部
  零成本假件）：p50 245 ms / p95 392 ms，几乎吃满 400 ms 门槛，即传输不是瓶颈。根因：
  session capability 是一条记录（如设计），但其 `consumptions` 每次手势加一条、整份
  文档在每次 consume 与每次 outcome 时被整写——「取一次 use 的代价随该 capability 已
  取过多少次而涨」，恰好在会话作用域本要让它恒定的地方变成二次。实测单次 use 从 use
  50 的 36 ms 涨到 use 450 的 441 ms（一次授权即超出整个手势预算）。改法：文档降为
  checkpoint，每次 use 追加进 durable ledger 并 fsync，读 = checkpoint + 重放；每 128
  个事件整写一次以给重放封顶；解析后的文档按文件身份缓存，另一写者改过即失效。全量
  durability 保持不变（每张收据都留，仅换了写在哪里），维护者裁决未被动。改后单次 use
  在 600 次内平直 11→16 ms，Runtime 每手势 245→107 ms（p95 392→141 ms）。断尾丢弃、
  重放预留 fail closed、篡改 ledger fail closed 均有测试，反向验证 3 条测试 5 处断言会红。
  两条既有测试原本用手改文档构造崩溃窗口，已就地移植到 ledger（更贴近真实崩溃）。证据
  `evidence/runs/TASK-IDC-002/data/capability-use-ledger.json`。
  ⑥ 持久派发通道已落地。平台事实两条：`hdc shell` 在管道上直接拒绝（`Not support stdio
  TTY mode` 后吞掉一切写入），必须走 PTY；且在设备 shell 起来之前写入会被丢弃，所以开场
  要先等远端出声、再用一条成帧的空命令自证（实测 open 59 ms）。命令用「前后各一个标记」
  成帧而非只加结尾哨兵——提示符形状不可预测且设备侧还会回显命令行，两端界定才不必去认
  提示符。交错实测 `uinput`：通道 p50 223 ms vs spawn p50 334 ms，省 111 ms。
  只路由 pointer injection，且只认 `hdc -t <key> shell <裸 token>`；换个动作、进程序列、
  host landing、或任何 shell 会重新解读的 token 一律留在 spawn 路径（加引号会让两种派发
  形态跑出不同命令，比不用通道更糟）。开不出通道只损失延迟不损失操作（未写出，回落
  spawn）；**已写出而无答复 = outcomeUnknown 且绝不重发**（回落会打出第二次手势）。
  通道能取回设备侧退出码（127/42/0，spawn 形态一律 0），但本刀仍按 spawn 形态报 0——
  否则同一手势的判据会取决于它走了哪条路；启用它必须两条路径同时改，不属本刀。
  通道 120 s 无手势即关闭（它是设备上一个常驻 shell）。证据
  `evidence/runs/TASK-IDC-002/data/persistent-shell-channel.json`。
  顺带记一条硬事实：本次会话中设备连接键自行变过（5SM… → 150100424a…），症状是
  `Not match target founded`，误导了约一小时；这也正面支持「每次手势重读身份」。
  ⑦ 端到端真机验证已跑（daemon 按 #1512 重建并用维护者自己的 Developer ID 重签安装，
  旧 bundle 备份在 Helpers/.backup-20260825T205319/）。三种手势全部走通；会话沿用、
  追加台账、持久通道三者均在真机上确认（沿用后设备步骤只剩身份+注入；ledger 出现且
  1.3 MB 文档不再被整写；ps 里有 daemon 名下的常驻 `hdc … shell`）。
  **门槛未达**：经 CLI 的 p50 644 ms（其中 CLI 启动+XPC 往返约 75 ms/次，`--wait` 付两次），
  但 p95 3887 ms——持续点击下同一手势在 636–11820 ms 之间漂。事后立即量设备腿：
  `list targets -v` p50 40 ms 无缺行、`uinput` spawn p50 313 ms、loadavg 2.10（板子基线），
  故长尾在设备与链路侧而非 Runtime，但它是横在分量与门槛之间的东西，尚未刻画。
  两次「失败」不是缺陷：`targetConfirmationMismatch: saw 0`，设备瞬时掉出目标列表，
  两次都失败在注入之前且 outcomeUnknown=false——正是 #1510 保留的每手势身份复核在挡，
  前导里最便宜的那一步抓住了真实瞬态。
  **发现并修掉一个真缺陷**：通道的 120 s 空闲关闭只在下一次派发时清扫，也就是在「没有
  下一次」这个它本该覆盖的情形下永不触发——真机上最后一次手势后 11 分钟仍开着。已改为
  按定时器清扫并在每次使用时重新计时，附反向验证测试。证据
  `evidence/runs/TASK-IDC-002/data/end-to-end-real-device.json`。
  修复后已在真机复验（daemon 按 #1513 重装，备份 Helpers/.backup-20260825T213042/）：
  旧 daemon 的常驻通道随重启消失；一次手势开出通道；此后不再派发，通道在 105–120 s
  之间自行关闭（超时 120 s，每 15 s 采样，消失前 etime 2:01）；下一次手势重新开出新通道，
  随后五次 520–653 ms 且设备步骤只有身份+注入。
  ⑧ p95 长尾已刻画，结论把先前的报数推翻：那些长尾全部量自带 idle-close 缺陷的旧
  daemon，在修复版上不复现——**100 次连续手势零失败、p50 544 / p95 569 / p99 590 /
  max 709 ms，四个区段全平**。故现行数字是 p95 569 ms，不是 3887 ms。
  逐项排除（均有实测）：capability 文档大小（空库 87 ms vs 真实 1.4 MB/333 记录 85 ms）、
  checkpoint（1.4 MB 整写热态 17 ms）、可执行哈希（6 MB SHA-256 2.1 ms）、
  F_FULLFSYNC（静止 p95 3.9 ms，手势负载下 p95 4.2 ms、518 次采样无一超 20 ms）、
  堆积状态（1462 作业目录/1388 制品目录下长跑仍平）。
  旧长尾的首要假说：两版唯一的功能差异是通道会不会被回收，而旧版那条通道已连续开了
  数十分钟；长命 `hdc shell` 退化正好能解释「批内渐慢、批后恢复、偶发掉出目标列表」。
  未证——要证需把一条通道挂满二十分钟再突发，没跑。
  **方法教训**：第一次归因把三种形态顺序跑而非交错，得出「长尾在设备侧」；交错之后结论
  反转（Runtime 净增 p50 249 / p95 1883 ms）。每一相都在往活的 UI 上点，设备状态随相推移
  而变，顺序相不构成受控对照。
  **门槛仍未达但差距是 ~145 ms 而非数秒**：p50 544 ms vs 400 ms。剩下的差额在注入本身——
  `uinput` 未注入即需 ~279 ms、真实 tap ~427 ms（spawn），通道去掉的是 spawn 不是这只二进制。
  400 ms 以上唯一还剩的杠杆是更便宜的注入载体，不属本 change。证据
  `evidence/runs/TASK-IDC-002/data/gesture-tail-attribution.json`。
  ⑨ App 自身路径已验：用 App 实际持有的那个 provider（`ToolkitDeviceControlFacade.make()`）
  经同一条 XPC 传输打真机，40/40 全部 confirmed，p50 519 / p95 592 / p99 721 ms。
  `job.submit` 单独一次往返（含建连接与准入）只要 p50 18 ms，故传输不是成本所在，余下
  ~500 ms 全在 `job.run`（身份复核 + 注入）。
  更正一条既有记载：先前写「App 持长连接、不付 CLI 那笔」——两处都错，App 每次请求新建
  `NSXPCConnection` 用完即作废，且两条路径实测只差约 25 ms（App 519 vs CLI 544）。
  这一趟同时验到 facade 自身的工作面（逐手势 typed inputs、提交、运行、从时间线读判据），
  不只是延迟。证据 `evidence/runs/TASK-IDC-002/data/app-path-verification.json`。
  **门槛结论收口**：App 路径 p50 519 ms vs 400 ms，差 ~119 ms，且差额既不在传输（18 ms）
  也不在 Runtime——真实 tap 的 `uinput` 在设备上 spawn ~427 ms / 通道 ~350 ms，且未注入
  即需 ~279 ms。设备之上已无杠杆，只有更便宜的注入载体能收口，不属本 change）
- Golden Journey:GJ-2
- Platform:macos
- Requirements:proposal「目标」2/3/4/5；design.md §2/§3/§5/§6
- Acceptance:IDC-AC-5、IDC-AC-6（输入侧）、IDC-AC-8
- Allowed paths:
  - `Catalog/**`（operation 的双向声明横跨 operations/profiles/generated 三个子目录，
    一次 op 新增必须同车；schema/ 仅在 operation schema 变化时触碰，本任务不改）
  - `scripts/catalog_gen/test_generate.py`（codegen 的自测把已发布 operation 清单与
    每类 actionRef 出现次数硬编码为期望值；新增 operation 必须同车更新这些计数，
    否则 SDD guard 红。仅改期望数据，不改生成器逻辑）
  - `openspec/contracts/workflow-step-registry.yaml`（仅新增 `injectPointerInput` 一行：
    proposal 已批准的三个 input operation 的封闭 step 载体；不改既有行）
  - `openspec/contracts/workflow-step.schema.json`（仅新增 `injectPointerInput` 的
    kind 枚举项与其封闭 arguments 对象映射；不改既有 kind 的任何条目——registry 与
    schema 由契约测试对偶锁定，二者必须同车）
  - `Packages/ArkDeckKit/Sources/**`
  - `Packages/ArkDeckKit/Tests/**`
  - `ArkDeckApp/**`
  - `ArkDeckAppUITests/**`
  - `ArkDeck.xcodeproj/**`
  - 本 change `tasks.md`（仅本任务段的状态/pins/evidence 引用）
  - 本 change `evidence/runs/TASK-IDC-002/**`
  - 本 change `evidence/runs/TASK-IDC-001/run.md`（仅在本任务的测量推翻 spike 的某条
    结论时，就地标注被取代并指向取代它的测量。留在证据文件里未标注的过时结论，会被
    下一个打开它的人读成现行结论）
- 交付内容：
  1. Catalog：`input.tap@1` / `input.long-press@1` / `input.swipe@1`
     （codegen + digest 更新）；`snapshot_display` JPEG 腿。
  2. Runtime：Interactive Control Session（session-scoped standing
     capability + 封闭输入模板 + input ledger + 预算/TTL/漂移 fail
     closed + 恢复只结算不派发）；durability 取舍按维护者对 Spike 数据
     的裁决落地。
  3. Provider：uiInput lowering + stdout 白名单判据 + epoch/facts 复验 +
     `inputExpired` 作废语义；fake 测试面按 PRODUCT-LOOP §11 断言真实
     argv 形态（含 `-t <connectKey>`）。
  4. App：Toolkit 工作区（两态触点、长按、stale 暂停、宿主合成录屏、
     配额 preflight、操作记录）；XPC 白名单与 facade。
  5. 真机验证一次完整走查并落 evidence。

## TASK-IDC-003 — 环形诊断采集 + Diagnostics Session reader（垂直交付）

- Status:ready（proposal 与 Spike 前置均已满足；与 T02 可并行实现、共享会话机械。
  Spike 已钉的 lowering 要点：bgsrv 快照服务优先于 begin/dump、Marker 走设备侧
  trace_marker 且必须加落笔回读、回溯窗口与类目集联动预算且 dump 后立即重臂、
  hilog 按会话时长扩容或周期 drain、core drain 按 bytes + 宽容解码处理）
- Golden Journey:GJ-2 + GJ-5
- Platform:macos
- Requirements:proposal「目标」1/3；design.md §4；
  `diagnostic-mode-design.md` v1.3 §4.4/§12 阶段 1–2
- Acceptance:IDC-AC-6（截图侧）、IDC-AC-7
- Allowed paths:
  - `Catalog/**`（operation 的双向声明横跨 operations/profiles/generated 三个子目录，
    一次 op 新增必须同车；schema/ 仅在 operation schema 变化时触碰，本任务不改）
  - `scripts/catalog_gen/test_generate.py`（codegen 的自测把已发布 operation 清单与
    每类 actionRef 出现次数硬编码为期望值；新增 operation 必须同车更新这些计数，
    否则 SDD guard 红。仅改期望数据，不改生成器逻辑）
  - `openspec/contracts/workflow-step-registry.yaml`（仅当环形采集需要新封闭 step kind
    时新增对应行；不改既有行）
  - `openspec/contracts/workflow-step.schema.json`（同上：仅当新增 kind 时补其枚举项
    与 arguments 映射；不改既有条目）
  - `openspec/contracts/catalogs/diagnostics-stdout.yaml`（仅为新增的
    `componentDetail` stdout action 登记 exact action ID、typed parameters 与 bounds；
    不改既有 action）
  - `Packages/ArkDeckKit/Sources/**`
  - `Packages/ArkDeckKit/Tests/**`
  - `ArkDeckApp/**`
  - `ArkDeckAppUITests/**`
  - `ArkDeck.xcodeproj/**`
  - 本 change `tasks.md`（仅本任务段的状态/pins/evidence 引用）
  - 本 change `evidence/runs/TASK-IDC-003/**`
- 交付内容：
  1. capture.diagnostics@1 additive inputs（`ringBuffered`、markers 通道）
     与三段 ring lowering；`markers.json` Artifact；finalize 阶段的自动
     Marker 反推（frame deadline / crash / 关键字）。
  2. 会话内 Marker 截图子意图（共用 T02 会话机械）；截图 Artifact 记录
     实际拍摄时刻。
  3. App：Diagnostics tab（采集页 + Session reader），两态对齐、`+N ms`
     事后标注、event identity 保留、Partial/无法对齐降级；采集期间对同
     设备其他 mutation 的 fail-closed 文案。
  4. 真机验证：一次含手动 + 自动 Marker 的完整会话，回溯窗口覆盖断言，
     evidence 落盘。
