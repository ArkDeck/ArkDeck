# Verification — CHG-2026-064

> Change:CHG-2026-064-agent-native-decision-plane@r1
> Status: proposed；本文件不声称任何 merge 结论。各 AC 在对应 Task 的实现 PR
> 中取证并附 evidence；真机项以当前 catalog digest 为准。

## Acceptance

### TASK-AND-001（搬家与去耦）

- **AND-AC-1**（analyzer 搬迁等价）：对同一 faultlog 输入，迁移前后
  `crash-signature` derived artifact **逐字节一致**（hash 对照进 evidence）；
  `analyzer.extract-crash-signature@1` 的 catalog digest 零漂移；
  `--analyze-crash-ledger` 生产路径实测可达。
- **AND-AC-2**（chat 行为不变）：`arkdeck agent chat` 合约测试全绿；
  `ARKDECK_HARNESS_MODEL_*` env 键名不变；chat 组合体的依赖清单中
  `ArkDeckHarness` 不再出现。
- **AND-AC-3**（campaign 去 Harness）：`EvolutionCampaignHost.swift` 零
  `import ArkDeckHarness`；campaign lane（`--hardware-campaign`）合约测试
  全绿；campaign 的 Workflows 侧五文件（Authority/Ledger/Admission/
  EngineLaneAdmitter/CandidatePipeline）零改动或仅注释级改动。

### TASK-AND-002（外部 agent 真机实证）

- **AND-AC-4**（闭环）：headless 外部 agent 一次会话在已接管真机上从真实
  缺陷完成 观察/采集 → 分析 → `workspace.applyPatch` → build → 部署 →
  复验 → 终态结论；循环内人工步骤 0（E0 与已授权 E1）；复验结论以设备侧
  readback/产物为证，不以 agent 自述或 exit 0 为证。
- **AND-AC-5**（纯已发布面）：该会话全程 `task.*` 调用数 **0**（daemon 方法
  日志取证）；全部副作用逐一经 job admission；每次 E1 消耗对应有效
  capability 且台账可对账；三层预算/停止面（agent 运行时预算、capability
  预算与过期、workspace allowed-paths 与 revision 准入）逐项在位说明进
  evidence。
- **AND-AC-6**（防陈旧与宿主无关）：一次故意以陈旧 base revision 提交的
  `applyPatch` 被 runtime 准入**具名拒绝**且零派发（负向用例；拒绝码进
  evidence）。

### TASK-AND-003（移除）

- **AND-AC-7**（移除完整）：`Sources/ArkDeckHarness/` 目录不存在；
  `Package.swift` 无 `ArkDeckHarness` 与 `ArkDeckEvolutionCandidate`；
  daemon 对任意 `task.*` 方法返回既有 unknown-method 错误；CLI 无 `task`
  子命令；App 无 Automation task 投影；`forwardableAutomationMethods` 随之
  清空或移除；生产代码 `import ArkDeckHarness` 与 `HTASK-` 词汇命中 0
  （rg 取证）。
- **AND-AC-8**（架构收紧）：架构测试新增并通过三条断言——target 图不存在
  `ArkDeckHarness`；生产代码零 `import ArkDeckHarness`；job/artifact store
  无 `HTASK-` 词汇。被删除的旧双平面断言逐条列入 PR 描述。
- **AND-AC-9**（安全内核零降级）：workspace capability 主体、
  `expectedWorkspaceRevision` 准入、allowed-paths digest、
  `HumanActionRequired`、intent-before-effect、outcomeUnknown fail-closed
  的既有合约测试**逐条全绿且零改动**（测试文件清单列入 PR 描述；对这些
  测试的任何修改都构成本 AC 失败）。
- **AND-AC-10**（全量与基线）：全量 `swift test` 零失败；App `xcodebuild`
  成功；APIBaseline 再生且 diff 仅含 Harness 公开面移除；已移除配置键被
  显式设置时 daemon/CLI 具名 fail-loud（含正反用例）。
- **AND-AC-11**（孤儿数据与操作者路径）：存在旧 `harness/` 数据目录时
  daemon 正常启动、不读不删；LaunchAgents README 载明升级前 `task.list`
  确认与数据目录处置注记；`arkdeck job submit`/`flash`/`artifact`/
  `agent chat` 冒烟全部可用。

## Golden Journey 影响登记

| GJ | 本 change 前 | 本 change 后 |
| --- | --- | --- |
| GJ-5 | `REAL_DEVICE_PASS`（旧判据：内嵌宿主，2026-08-01/05/06 evidence，历史记录不改写） | **`REAL_DEVICE_PASS`（重述判据，2026-08-19）**：headless 外部 agent 一次会话闭合含修复腿闭环，`task.*` 0、循环内人工 0；evidence = `evidence/runs/TASK-AND-002/run-r2.md`（AND-AC-4/5/6 逐条映射见该文件末节；AND-AC-1..3 已随 TASK-AND-001 实现 PR #1382 取证） |
| GJ-1—GJ-4 | 不变 | 不变（AND-AC-1 保护 GJ-1 crash-signature 链；AND-AC-3 保护 GJ-4 campaign lane） |
