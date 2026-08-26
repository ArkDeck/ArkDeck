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

- Status:in-progress（2026-08-26 复核：九刀已交付且逐刀有真机证据，**但对照本任务自己的
  「交付内容」与 IDC-AC-8，还有五项未做**，逐条列在这里，而不是含糊地挂着 in-progress。
  ① 已于 2026-08-26 交付，余四项未做：
  ① ~~**stale 帧不拒绝输入**~~ **已交付**——AC-8 要求「stale 时 pointer down 被拒且
  有说明」。**这里的 stale 不是帧龄**：runtime 自己的新鲜度预算是 1 秒，而静止画面是人
  按自己的节奏看的——看、想、决定点哪里，没人在一秒内做完，按秒计的规则会拒掉有史以来
  每一个手势，这也正是 `ToolkitScreenFrame.capturedAtUTC` 被刻意不写成新鲜度断言的原因。
  作废画面的是「有东西改了屏幕」，而这个工作区唯一确知的改动就是它自己刚发出去的那个手势。
  故规则为：确认或未知都作废画面，干净失败不作废（什么都没到设备），只有重新截图能恢复。
  规则落在 `ToolkitFrameLiveness`（8 条契约测试 + 负向对照），接线由真机闸
  `ToolkitStaleFrameUITests` 把住（拆掉守卫即变红）。
  **顺带修掉两个从未被真机跑通的 wire 缺陷**：Toolkit 把 `artifact.list` 的**数组**回包
  当对象读，且 `artifact.read` 少传 `jobId`——两者各自都足以让每一次截图都失败。表现是
  runtime 任务成功、`screenshot.png` 已发布，而工作区显示「截图失败」；没有画面，本条
  拒绝也就是死码。现由 `testTheWorkspaceReadsTheArtifactIndexTheRuntimeActuallyWrites`
  用 daemon 自己的 `handleLine` 出线字节驱动工作区自己的读取器把住，不用手写 fixture。
  ② **宿主合成录屏**——运行时腿已交付（2026-08-26），**App 面板未做**。
  先答「系统没有录屏接口吗」：这台设备上 `/system/bin`、`/vendor/bin` **没有任何录屏
  程序**，只有 `snapshot_display`（单张）与 `setresolution_screen`；`uitest` 的
  `screenCap` 是单张、`uiRecord` 录的是 **UI 事件写 CSV** 不是像素。平台确有真正的屏幕
  采集（设备上有 `libnative_avscreen_capture.so` / `libmedia_service_screen_capture.z.so`），
  但那是**应用内 API**，其权限在设备自己的 `permission_definitions.json` 里写着
  `ohos.permission.CAPTURE_SCREEN  grantMode: system_grant  availableLevel: system_core`
  ——只有系统级签名的应用能持有，用户授权不了、shell 够不着。**故「宿主合成」不是设计
  偏好而是唯一可走的路。**
  代价实测（各 20 帧）：PNG 原生 765 ms/帧、JPEG 原生 543 ms、JPEG 360×640 537 ms、
  PNG 360×640 613 ms。**降分辨率几乎不省——瓶颈是显示回读（扣掉 51 ms 进程启动约
  490 ms），不是编码。上限约 1.8 fps。** 所以本腿只报**实测**帧率，不承诺速率。
  （这三行第一次量错过：`snapshot_display` 要求文件后缀与 `-t` 一致，无后缀直接报错
  退出且快得像成功，量到的是「拒绝」。上表为逐帧验证文件确实产出后的复测。）
  已交付：`capture.screen-sequence@1`——拥有目录 + **每帧一次 typed 调用**（设备侧
  `for` 循环是 shell 片段，且只快 54 ms/帧，不值）+ `tar` 归档 + `ls -l` 回读作为凭据；
  清理只按名删自己写过的帧再 `rmdir`，判据是目录不在列表里而非退出码。
  真机证据（TGT-958780b2ffb7）：20 帧 job-5002416b92d3bee45d13ed6427ed7695 succeeded；
  120 帧 job-982bebf009b868db7b8f78d6a105b207 succeeded，74.9 s / 624 ms 每帧，取回
  120 张 720×1280 JPEG，**第 1–39 帧一幅、第 40–120 帧另一幅，切换点正是锁屏钟
  23:29→23:30**——截一次复制 120 份做不到这个。
  **顺带修掉一个从没人发现的洞**：`ProviderSubprocessReceipt.durationSeconds` 对**每一次
  派发**都写死 0，而 `ProviderProcessReceipt.durationSeconds` 是它们的和，所以每个
  processSequence 报的总时长也一直是 0。没人消费过所以没显形；本腿是第一个消费者
  （没有别处能观测到帧率）。现改为单调钟实测，并由
  `DispatchedInvocationDurationContractTests` 对真实子进程把住。
  **App 录屏面已交付（2026-08-26）**：Toolkit 工作区内 Recording 面板，四态
  Capturing→Assembling→Validating→结果条（实测帧率 + 落盘位置 + 在访达中显示/
  另存为/再录一段）。控件是**帧数不是秒数**——速率属于设备回读，要不来。
  宿主合成走 `AVAssetWriter`（H.264/.mov），**每帧呈现时刻取自实测逐帧时长**而非
  平均节奏；Validating 是把写出的文件用 `AVURLAsset` **读回来**比对时长与尺寸，
  因为「写方说写完了」正是这一步该怀疑的那句话。
  为把实测时长送到 App，新增 `RuntimeScreenSequence`（照 `RuntimeRingCoverage`
  先例挂在 job record 上——**时间线只记事实的键名不记值**，不这么做这些测量就丢了），
  并由终结阶段发布 `sequence.json`。
  归档解析 `ToolkitFrameArchive` 是仓内纯字节实现（不 spawn `tar`），截断的归档
  报 `truncated(afterFrames:)` 而不是静默当读完。
  证据：16 条契约测试，其中 3 条用**真机取回的 `frames.tar`**（20 帧 / 720×1280）
  跑通「fixture 取帧 → 合成 → 读回校验」整条流水线，实测 1.84 fps。
  **`ToolkitRecordingUITests` 已补跑（2026-08-26 晚，环境恢复后）**：passed 12.2s，
  与 `ToolkitStaleFrameUITests`（passed 29.8s）一并对真机通过。闸本身修了两处：
  结果条的标识挂在 HStack 上导致图标与文字都继承（`.accessibilityElement(children:
  .combine)` 收成单元素），以及 `.buttonStyle(.link)` 的控件不在 `app.buttons` 里
  （改按标识查）。取速率也改为取 "fps" 前的那个数——原先取行内第一个数会撞上帧数 20，
  会因为错误的原因通过。
  两条负向对照都命中：①把逐帧时长换成固定 1/30，闸报 `30.00 fps` 并失败——这正是它要
  拦的那种误导；②让合成一帧不写，**Validating 抓住**（AVFoundation「此媒体可能已损坏」），
  结果条根本不出现。
  **顺带查实一条不是本任务的失败**：`AppShellUITests.testEnglishSweepOfEveryWorkspace`
  在本机红，断言开窗尺寸 1180×760 而实际 1195×802。**干净 main 上一模一样地失败**
  （同样 1195×802），故与录屏面板无关，是本机先前就有的状况，未在此处修。
  **未做**：录屏面板与 Diagnostics 会话的对齐（录屏目前不落进诊断会话制品）。
  ③ **开始前的配额 preflight 未做**——AC-8 要求失败即阻断。
  ④ **performance notice 未做**——AC-8 要求它与 production-boundary 一样不可删除；
  现在只有 boundary（`toolkit.boundary`）。
  ⑤ **`snapshot_display` JPEG 腿未做**——交付内容 1 点名；现状只有 PNG。代码里出现的
  jpeg 是「设备默认 jpeg，所以必须显式传 `-t png`」这条既有事实，不是一条 JPEG 腿。
  **故 IDC-AC-8 未达成**；AC-5 与 AC-6 的输入侧由已交付部分覆盖并有真机证据。
  ——以下为逐刀记录——
  已交付 ① typed input operations + Provider lowering
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

- Status:done（2026-08-26。八刀交付、逐刀有真机证据，验收读法见下。
  **置 done 时两处与原「交付内容」文字不符，写在这里而不是留给读者去发现**：
  ① 交付内容 1 点名的自动 Marker 是「frame deadline / crash / 关键字」，实际只做了
  crash 与 stepFailed。frameDeadline 与 logKeyword **可以做**——不是平台不允许，是我把
  反推放在 finalize 而那里只有制品元数据没有字节；制品里以 `notDerived` 明写了种类与
  原因，所以它们的缺席不会被读成「这次运行没发生这些事」，但它也确实还没被做。
  ② 「截图 Artifact 记录实际拍摄时刻」已按可观测**区间**实现，而设计的 ±150 ms 配图规则
  在这套硬件上满足不了：`capture-screenshot` 本身宽 913–965 ms，宿主定位快门的不确定度
  约 ±465 ms。reader 因此把「无法判定」与「不是那一刻」分开陈述。真正收口需要设备自己
  报告快门时刻，那是只有它能观测的事实。
  以下为逐刀记录。
  ⑦ **typed `deviceBusyBySession` 已实现**。此前实测是静默排队（相隔 0.05 s 的两次采集
  都成功、第二次 2713 ms vs 1473 ms）——lane 按设备串行化让并发**安全且不可见**，而设计
  要的是**安全且可见**。现在引入「设备会话持有」：只有会话子意图取得持有，别的 client 对
  被持有设备的 mutation 在授权之前被 typed 拒绝，理由里点名谁持有、自何时起、且明说
  「不是排队」。持有 120 s 无动作即过期（人走开了，设备归下一个来问的人）。
  边界有测试钉住——持有者自己不被自己挡、只读不被挡、另一台设备不受影响、host-only 计划
  无设备可忙、普通工作既不取得持有也不因缺持有被挡（一条见谁都拒的规则比没有更糟）。
  反向验证：去掉拒绝那一支，「另一 client 被 typed 拒绝」当场红。
  ⑧ **Diagnostics 采集页已交付**：布防/停止、⌘M 打标、已打标记计数、以及三种状态文案
  （已布防 / 设备正忙被拒 / 采集失败）。采集面在 reader 之上，因为工作就是这个顺序：
  布防 → 复现 → 打标 → 查看。界面上明说「标记只记录一个主机时刻、不碰设备」——否则它
  会被读成一次可能失败的设备操作。
  收尾时的环境：现役 daemon 是 main@#1534 的构建、用维护者自己的 Developer ID 签名；
  历次替换掉的 bundle 全在 Helpers/.backup-*/，拷回并重启 LaunchAgent 即可还原。设备上本轮
  写过的 /data/local/tmp 与 /data/log/hitrace 文件已逐一删除、trace 服务已停；注入的点击
  落在设置里并在其中导航，未安装、卸载或改动任何配置。
  证据 `evidence/runs/TASK-IDC-003/data/closing-state.json`。
  ——以下为逐刀记录——
  ① 环形 trace lowering 已交付：`ringBuffered` additive
  typed input + `--trace_begin / --trace_dump / --trace_finish_nodump` 三段 lowering +
  覆盖锚点（arm 后立刻写设备侧 trace_marker 并回读）。**载体选择与 Spike 建议不同并给出
  理由**：`--dump_bgsrv` 写到服务自选路径，provider 无法拥有该路径，而本 operation 其余
  文件腿都绑定 provider 自铸的临时路径、清理也只碰自己创建的路径；`--trace_dump -o` 收下
  owned path，机械不动。两者能力都在真机验过，这是路径归属之争不是能力之争。
  **一处措辞已就地更正**：先前写「环形自带回溯、快照携带其已持有的内容」——实测两次分别
  是锚点前 25.64 s 与 0.06 s，取决于缓冲区原本存着什么，故回溯深度不是 arm 的属性；catalog、
  lowering、测试三处的说法均已改为「快照携带自 arm 起的内容，实际回溯深度由锚点判定」。
  另实证：`--overwrite` 语义与其名相反（复证 Spike）、dump 后采集继续无需重新 begin、
  重定向作为独立 argv 元素不生效（故 marker 写入用单行、锚点限定为字母数字）。
  证据 `evidence/runs/TASK-IDC-003/data/ring-lowering-facts.json`。
  ② markers.json 与自动 Marker 已交付：`markers` additive typed input（每条是
  RFC 3339 时刻 + 可选 `#label`，走 catalog pattern 校验）+ finalize 合成的
  `markers.json`。手动 Marker 是 host 时间上的标注、不碰设备；自动 Marker v1 由
  **本次运行已确立的事实**反推（crash-log 带字节 → crashLogCaptured；时间线里的
  step 失败 → stepFailed），不重开制品。
  **未反推的种类写进文档本身**（frameDeadline / logKeyword 及其原因）——finalize 手上
  只有制品元数据不是字节，读者看不到 frame marker 时必须能分辨「没有去看」和「没有发生」。
  ring 采集另记 coverage：锚点值 + 该拿哪个制品去查 + 查法（字符串搜索即可），
  但**不声称查过**，因为 finalize 从未打开 trace。
  顺带修一个静默陷阱：数组字段声明的 `pattern` 此前只对标量分支生效，对数组元素不生效
  ——catalog 说值受约束而 runtime 什么都收。已改为逐元素强制（现存无任何数组字段声明
  pattern，故不影响任何调用方），反向验证：去掉强制后畸形 marker 测试即红。
  ③ 会话内截图子意图已交付。设计要求「不新增 operation」，故会话作用域改为**按输入判定**：
  `capture.diagnostics@1` 只有在它选中的腿仅是截图时才是会话的子意图，更大的采集照常走
  普通准入——会话的常驻授权覆盖的是「标记与查看」，不是一次完整诊断采集。
  判定读 catalog 自己的步骤选择、且**只看可选步骤**（非可选步骤对最大的采集也跑，本来就
  区分不了任何东西），因此新增一条腿无法靠「被加进 operation」悄悄挤进会话信封。
  这条规矩当场救了一次：第一版手列了「恒跑步骤清单」，漏掉 `postprocess-index`，
  于是拒绝了每一次仅截图的采集；测试当场抓到，改为只看可选步骤后手列清单整个消失。
  作用域判定结果随 query 走（`sessionScoped`），因为指纹只拿得到 query：若让它从已归约的
  subject 再推一次，会推出与签发时不同的答案——那正是当初让每个手势准入失败的那类失配。
  真机实测：会话首张截图 2101 ms 跑全前导，之后每张只剩身份复核 + 截图腿、carried 2、
  1482 ms（每张标记截图省 620 ms）；带 hilog 的采集在硬件上确认落回普通准入。
  **这一刀自己抓到两个缺陷**：①手列「恒跑步骤」漏了 `postprocess-index`，导致仅截图的
  采集全被拒——测试当场红，改为只看可选步骤后手列清单消失；②把作用域改成按输入判定时，
  我把沿用的**消费端**守卫一并删了，于是该设备上任何操作都开始跳过自己的型号/固件回读
  （带 hilog 的采集回来带着 carried 2）——真机跑更大的采集才看出来，已补守卫与反向验证测试。
  证据 `evidence/runs/TASK-IDC-003/data/session-screenshot-subintent.json`。
  ④ App Diagnostics tab 已交付（reader 面）。正确性放在纯模型 `DiagnosticSessionReading`：
  截图只在拍摄时刻距标记 ≤150 ms 时才可代表该标记，并始终带 `+N ms`；超窗、拍摄失败、
  未拍摄是三个不同事实，各自成文，**不用旧画面或占位图补齐**；缺声明产物即 Partial 并
  点名；「未反推的种类」从采集穿透到 reader，使空 track 不被读成安全。
  对齐三态里**没有第四态**：没有校准事实时默认就是「无法对齐」——时钟桥尚未进产品，
  默认成「大概同一时钟」会让它下面的每一条判读都悄悄不成立。
  选中事件在光标移开后保留并标注偏离（交叉看事件与邻近日志是排障基本动作，看一眼日志
  不该丢掉选中项）。13 条 reader 契约测试。
  ⑤ 真机完整走查已跑（job-f24eebf587fcda2ffbc7fa7e73982cbb）：一次会话同时产出
  2 个手动 Marker + 1 个自动 Marker（`crashLogCaptured`，来自设备上真实到达的
  395942 字节崩溃日志）、回溯 trace、hilog、崩溃日志与截图；9 个已发布制品
  status/privacy/byte/SHA 全过；判据记录 `ringHeldAnchor: true`，且锚点在已发布 trace 中
  实地命中（该次快照锚点前 0.08 s、锚点后 8.35 s）。
  reader 读真实数据的输出：alignment 为 `cannotAlign`（无校准，诚实的默认）；两个手动
  Marker 分别因最近截图相差 +16000 ms / −6000 ms 而**拒绝配图并说出差多远**；notDerived
  穿透到位。
  **走查发现一条缺口**：`+N ms` 这一侧演示不出来，且不是瞄得不准——设计的判定窗口是
  150 ms，而 runtime 记录的是制品的 `createdAtUtc`、**秒级粒度**（且它是「制品写入时刻」
  不是「快门时刻」）。粒度比消费它的窗口粗约七倍，任何瞄准都进不了窗。reader 没有错，
  它拒绝得对也说清了差多少；它需要的那个事实**尚未被发布**。
  ⑥ 快门时刻已按毫秒精度落进制品，并把上面那条缺口的读法一并更正。
  落的是**区间不是点**：宿主看不见快门张开，只看得见自己派发的那段区间，快门在其中；
  记一个点是在发明没人测过的精度。制品新增 `observationWindow`（上线为
  observedFromUtc/observedToUtc）。
  **测量结果推翻了先前的诊断**：先前记为「时间戳秒级粒度」——那只是症状。毫秒精度落地后
  规则仍然满足不了：真机上 `capture-screenshot` 本身宽 **913–965 ms**（五次），
  宿主定位快门的不确定度约 ±465 ms，是那条 150 ms 规则的六倍左右。
  所以 reader 的 `shutterWindowWiderThanTheRule` **不是边角情形，是这套硬件上的常态**；
  在设备自己报告快门时刻之前，「此处无法判定」就是正确答案。
  测量中还改掉一处自己的错：`screenshot.png` 由 `receive-screenshot` 发布，第一版挂上去的
  是**接收**区间（实测 91/118/781 ms），而快门在 `capture-screenshot`。那会是一个「精确得
  很像回事、但属于另一个事件」的数字，比它替换掉的秒级值更糟。现按 operation 自己声明的
  receive→capture 关系解析产出步骤，并有测试钉住「接收产物携带其生产者的窗口」。
  证据 `evidence/runs/TASK-IDC-003/data/shutter-instant.json`。
  原 ready 依据：proposal 与 Spike 前置均已满足；与 T02 可并行实现、共享会话机械。
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
