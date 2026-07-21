# TASK-RF-002 Run — 阶段 B:RockchipRockUSBFlashProvider 与 `arkdeck flash` 接入(contract 面)

- Change:CHG-2026-020-dayu200-real-flash / Task:TASK-RF-002(readiness #232 生效)
- Base revision:`origin/main` `7d2e2ba`(含 RF-001 part 1 契约 #230、part 2 真机 SUCCESS
  evidence #233、RF-001 done #234)。
- Class:contract(host-only,零设备命令、零外部进程、零网络);真机验收(REQ-FLASH-014
  面)沿用 RF-001 人工执行模型,待维护者设备窗口,不在本 PR。
- 环境:macOS,Swift 6.3.3(实测),`swift format` lint 干净;`./scripts/check-sdd.sh`
  0 error / 0 warning / 111 acceptance IDs。

## 交付

| 文件 | 内容 |
| --- | --- |
| `Sources/ArkDeckWorkflows/RockchipFlashProfile.swift` | RF-001 part 1 契约的 typed 化:pinned archive 身份(`fc7637f3…5280`/732948803)、17 成员逐一 SHA-256、9 mapped 分区写序 + FA-001 §2 扇区地址(=`wl` 回退 BeginSec)、禁写面(orphan/6 无成员分区)、prerequisites 声明;archive validation(任一不符 → 阻断 execute 与 planned-success) |
| `Sources/ArkDeckWorkflows/RockchipRockUSBFlashProvider.swift` | typed Provider:`probe`(0x2207:0x350a Loader mode-gate;Maskrom/非 RockUSB 阻断)、`evaluatePrerequisites`、`makePlan`(typed `WorkflowStep`:requestConfirmation → enterUpdater → ppt 前置 → 9×flashPartition(destructive/criticalNonInterruptible)→ rd → postflight;plan/step-set 双 SHA-256 digest)、plan document(executionMode 持久可辨识)、`assessOutcome`(语义 postflight,exit 0 ≠ succeeded)、`recover`(CHG-016 Loader `wlx` RecoveryGuide,honest unknown) |
| `Sources/ArkDeckWorkflows/RockchipFlashAuthorization.swift` | REQ-FLASH-015 授权门:authority(standardAgent/ordinaryCI/humanOperator,CLI 侧 TTY+operator 双条件才 human、env 只能降级)、真实 binding、人工确认逐字段精确匹配(binding/固件/transport/toolchain/Provider/plan/step-set digest)、受控人工 handoff(封闭命令面)、dispatch 仪表(恒 0)、critical write 安全边界(退出请求 durable 记录 + 延迟到安全边界,不 kill 在途写入) |
| `Sources/ArkDeckWorkflows/GzipTarArchiveReader.swift` | 纯 Swift 流式 gzip+tar 成员清单(逐成员流式 SHA-256;不解包落盘、不外部进程),fail closed(corrupt/truncated 即抛) |
| `Sources/ArkDeckCLI/ArkDeckCLIMain.swift` + `Package.swift` | `arkdeck` executable:`flash plan`(planOnly/simulated)、`flash execute`(validate → exact plan → prerequisites 问询 → 双重 destructive 确认(计划 digest 短语 + `ERASE-USERDATA`)→ 人工确认记录 → 授权门 → **人工 handoff 文档,自身零设备 dispatch**)、`flash postflight`(observation JSON → honest 判定 + RecoveryGuide) |
| `Tests/ArkDeckContractTests/RockchipRockUSBFlashProviderContractTests.swift` | 15 个 contract 测试(下表)+ profile 钉死(防漂移)+ tar 读取器 fixture 测试 |

## 认领 AC 结论(contract;测试输出逐行在案)

| AC | 测试 | 结论 |
| --- | --- | --- |
| AC-FLASH-001-01 | `TEST_AC_FLASH_001_01` | PASS:非 RockUSB/Maskrom/未知 mode 三路 preflight 阻断;封闭命令面 = `ld/ppt/wlx/wl/rd`,`db/gpt/ul` 结构性不存在(不试相似命令);handoff 命令逐条落在封闭面内 |
| AC-FLASH-002-01 | `TEST_AC_FLASH_002_01` | PASS:required prerequisite unsatisfied/unknown(含缺观察=unknown、重复观察不升级)→ destructive confirmation 前阻断;human+全确认也无法越过;dispatch 0 |
| AC-FLASH-004-01 | `TEST_AC_FLASH_004_01` | PASS:execute/planOnly/simulated 在 plan document(canonical JSON)中持久可辨识、round-trip 保留、digest 三态互异;schema 版本漂移拒收 |
| AC-FLASH-007-01 | `TEST_AC_FLASH_007_01` | PASS:用户拒绝 destructive 确认 → wlx/rd/erase 及一切 dispatch 计数 0,无 handoff、evidence 不可产生 |
| AC-FLASH-008-01 | `TEST_AC_FLASH_008_01` | PASS:critical write 运行中退出请求 → `RockchipExitDeferralRecord` 经 session audit store durable 落盘并 replay 验证;在途写入不 kill;安全边界后生效 = 后续步骤阻断 |
| AC-FLASH-012-01 | `TEST_AC_FLASH_012_01` | PASS:exit 0 但语义 marker 缺失(写入/复位/postflight 任一)→ 非 succeeded(waitingForRecovery/outcomeUnknown);Loader 子集拒绝 → failed(confirmed);全语义确认才 succeeded |
| AC-FLASH-013-01 | `TEST_AC_FLASH_013_01` | PASS:未回连 → 非 succeeded + RecoveryGuide(CHG-016 Loader `wlx` 人工路径、device mode=unknown、`automaticRecoveryGuaranteed=false`、丢数据/不可启动/厂商工具 disclosures) |
| AC-FLASH-015-01 | `TEST_AC_FLASH_015_01` | PASS:standardAgent/ordinaryCI + 真实 binding + 含 flashPartition 的 execute plan → destructive dispatch 0、job marker `policyBlocked`、受控人工 handoff;planOnly/simulated 分支对 Agent 保持可用 |
| AC-FLASH-015-02 | `TEST_AC_FLASH_015_02` | PASS:人工确认缺失或 8 字段(binding/固件/transport/toolchain/Provider/plan digest/step-set digest/operator)任一不符 → 真实 dispatch 0、evidence eligibility = notEligible;为另一 plan 铸造的确认不能覆盖本 plan(digest 互斥);decision 为不可变值类型,无追认 API |

> AC-FLASH-003-01 由 TASK-RF-001 认领;本 PR 的
> `testArchiveValidationBlocksExecuteAndPlannedSuccessOnAnyMismatch` 提供其 Swift contract
> 面(hash/size/缺失/未声明成员 → 阻断,且 blocked validation 下 plan 结构性不可构造),
> 不改其 ownership。

## 验证记录

- `swift test`:**302 tests, 0 failures**(1 skip 为既有环境性 skip;本任务新增 15 全绿,
  `TEST-AC-FLASH-*` PASS 行逐条打印在案)。
- `./scripts/check-sdd.sh`:0 error / 0 warning / 111 acceptance IDs。
- CLI 冒烟(host-only):
  - `flash plan --images <非 pinned tar.gz>` → 逐条 violation + exit 2(execute 与
    planned-success 双阻断;非 pinned 包 fail closed 实测);
  - 非交互 `flash execute` → 在 validation 即阻断(顺序 validate → plan → gate;授权门
    的 policyBlocked 路径由 contract 测试覆盖);
  - `flash postflight` happy → `succeeded/confirmed` exit 0;未回连 → `waitingForRecovery/
    outcomeUnknown` + RecoveryGuide 全文 exit 5。
- Agent/CI destructive dispatch 仪表化:`RockchipFlashDispatchMonitor` 快照在每条被阻断
  分支断言全 0;代码库内**不存在**任何记账入口被调用的路径(结构性零 dispatch),CLI
  execute 分支终点=handoff 文档。

## 边界与遗留

- 本 run 只构成 contract 面结论;真机验收已于 2026-07-21 设备窗口完成 = **SUCCESS**,
  见 `acceptance-2026-07-21.md`(RF-ACCEPT PASS;hardware-matrix 新增 verified 行
  `EVD-RF002-DAYU200-20260721-001`)。
- 不改 Core spec/kind/状态机;复用 M1-008 seam 零语义变更;`ready → done` 另用独立状态
  PR。Agent 全程零设备命令、零 destructive dispatch。
