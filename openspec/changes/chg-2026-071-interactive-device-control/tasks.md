# Tasks — CHG-2026-071

三个垂直 Task。`ready` 只有在本 proposal PR 经维护者 review/merge 进入
protected `main` 后生效；合入前不得开始实现 PR。实现 PR 推 `agent/**`
分支由 CI 以 bot 身份开 PR，标题声明 Task ID，先跑
`scripts/check_pr_paths.py --preflight` 并直接看退出码。
**T01 的真机结论是 T02/T03 的准入门**：Spike 数据未落 evidence 前，
T02/T03 不进入实现。

## TASK-IDC-001 — Spike：真机测量束（决定架构，不产出产品面）

- Status:in-progress（2026-08-25 主体测量收官，见 `evidence/runs/TASK-IDC-001/run.md`：
  三档输入延迟 + 持久通道分解、截图双格式、hitrace 环形与 bgsrv 实证 PASS、时钟桥
  spread 9.7 ms、journal append 3.6–5.3 ms/条 ⇒ design.md §2 建议保持全量 durability。
  两条残留腿等待解锁设备的监督窗口：滚动负载下的截图/录屏扰动、hilog 重负载覆盖；
  app 层 ground-truth HAP 视维护者对 AC-4 方法偏差的裁决决定是否补做）
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

- Status:blocked（等 proposal merge 与 TASK-IDC-001 的 Spike 结论）
- Golden Journey:GJ-2
- Platform:macos
- Requirements:proposal「目标」2/3/4/5；design.md §2/§3/§5/§6
- Acceptance:IDC-AC-5、IDC-AC-6（输入侧）、IDC-AC-8
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

- Status:blocked（等 proposal merge 与 TASK-IDC-001 的 Spike 结论；与 T02 可并行实现、共享会话机械）
- Golden Journey:GJ-2 + GJ-5
- Platform:macos
- Requirements:proposal「目标」1/3；design.md §4；
  `diagnostic-mode-design.md` v1.3 §4.4/§12 阶段 1–2
- Acceptance:IDC-AC-6（截图侧）、IDC-AC-7
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
