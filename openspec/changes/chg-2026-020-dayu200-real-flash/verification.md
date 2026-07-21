# CHG-2026-020 Verification Plan

> Status:planned
> Change:CHG-2026-020-dayu200-real-flash@r1
> Core baseline:CORE-2.0.0(零 Core 变更;认领 flashing REQ-FLASH-* 的 DAYU200 面)

本 change 认领 Core `REQ-FLASH-*` 的 DAYU200 Rockchip Provider 面。canonical AC 的
method/expected result/minimum evidence 以 `openspec/verification/acceptance-cases.yaml`
为准,本 change 不改写。真机 destructive 面由**人类维护者亲手执行**(REQ-FLASH-015),
Agent 零设备命令、只做起草与核验;任何超出 design §0 封闭命令面、任何 hash 未校验即
写入、任何 Agent destructive dispatch 均整体 fail。中止如实记录为 blocked-attempt。

## 认领的 Core AC(DAYU200 Rockchip Provider 面;逐项 ownership)

| AC | Task | Method(canonical) | 本 change 的 DAYU200 面 |
| --- | --- | --- | --- |
| AC-FLASH-001-01 | RF-002 | contract | RockUSB 不适用设备 preflight 阻断,不试相似命令 |
| AC-FLASH-002-01 | RF-002 | contract | loader/recoveryPath prerequisite unsatisfied/unknown 时 destructive 前阻断 |
| AC-FLASH-003-01 | RF-001 | contract | `images.tar.gz` 成员 hash 不符 → execute 与 planned-success 阻断 |
| AC-FLASH-004-01 | RF-002 | contract | execute/planOnly/simulated 模式在 Job/manifest/History 可辨识 |
| AC-FLASH-007-01 | RF-002 | contract | 用户拒绝 destructive 确认 → wlx/rd/erase 调用 0 |
| AC-FLASH-008-01 | RF-002 | contract | 分区写(criticalNonInterruptible)运行中退出请求延迟到安全边界 |
| AC-FLASH-012-01 | RF-002 | contract | 工具 exit 0 但 postflight(ppt/list targets)不匹配 → 非 succeeded |
| AC-FLASH-013-01 | RF-002 | contract | 未回连 → 非 succeeded + Provider RecoveryGuide(Loader wlx 恢复路径)+ unknown |
| AC-FLASH-014-01 | RF-001 | realHardware | DAYU200/Rockchip/rkdeveloptool 1.32 完整验收 → hardware matrix supported 行;simulation 不可替代 |
| AC-FLASH-015-01 | RF-001/002 | contract | Agent/CI execute+真实 binding → destructive dispatch 0、policyBlocked、人工 handoff |
| AC-FLASH-015-02 | RF-001/002 | contract | 人工确认与计划/目标不一致或缺失 → 真实 dispatch 0、不产生 verified realHardware evidence |

> 逐 AC 的 canonical method/minimum evidence 以 acceptance-cases.yaml 为准;本 change 不
> 认领任何非上述 AC,不与 M1-008 已覆盖的 AC-FLASH-005/006 重叠(复用其 seam)。

## Change-local

| Evidence ID | Method | Expected result |
| --- | --- | --- |
| RF-CONTRACT-001 | documentReview | `images.tar.gz` 契约 + `RockchipFlashProfile` 与 design §1/§2 逐项一致:允许分区=PD-002 mapped 9 项、orphan/无成员/空洞禁写、逐成员 hash、写序、prerequisites 声明;锚定 PD-002/FA-001 可追溯 |
| RF-REALFLASH-001 | realHardware | 人类维护者按 design §0 正向烧写 pinned `images.tar.gz` 全流程:进态→ppt 前置→逐分区 wlx→rd→postflight Connected;逐命令 argv/输出/判定、hash 校验、destructive 确认、operator/窗口/恢复路径在案;Agent destructive dispatch 0 |

## Gate

本 change `verified` 前提:两 task done(各有 merged 实现 + 独立 done PR + evidence);
认领的 Core AC 有可复查证据(contract 全绿 + AC-FLASH-014-01 realHardware 验收);Agent/CI
destructive dispatch 恒 0(仪表化);hardware matrix supported 行有真实 evidence 背书。
不构成 DAYU200 以外设备支持;simulated/fake 永不进 hardware matrix。DEC-002 整体 resolve
由维护者在阶段 A 验收后判定。
