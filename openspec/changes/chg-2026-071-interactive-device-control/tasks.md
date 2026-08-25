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
  剩余：持久派发通道（每次 spawn ~93 ms vs 持久通道 ~10 ms，不属本 change））
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
