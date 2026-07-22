# Verification Plan

> Change:CHG-2026-025-ai-native-unattended-device-ops
> Status:planned # 结论经维护者在 PR 中确认

## Environment

- Core baseline:CORE-2.1.0 + 本 change approved delta overlay;archive 时 ratify
  CORE-3.0.0
- Host:macOS(现行 Swift 全量基线为回归底线);Device:DAYU200(RK3568),
  pinned 参考镜像 7.0.0.33
- toolchain/HDC/Provider 版本与全部 hash 于各任务 readiness PR 钉定(全 OID)

## Acceptance matrix

| AC ID | Verification method | Expected result | Evidence |
| --- | --- | --- | --- |
| AC-FLASH-015-01 | AIN-003 历史回归 + AIN-006 无授权可信门 dispatch=0 + TASK-AIN-004 真机负探针 | passed | TASK-AIN-003/006/004 run 记录 |
| AC-FLASH-015-02 | AIN-006 逐项篡改/过期/超次/读回不符 real-fault + TASK-AIN-004 真机负探针 | passed | TASK-AIN-006/004 run 记录 |
| AC-FLASH-015-03 | AIN-007 产品内 fake executor 端到端 + DAYU200 无人值守真机执行(v3 evidence,executor.kind=agent) | passed | TASK-AIN-007 tests;TASK-AIN-004 脱敏 transcript + EVD 记录 + hardware-matrix 行 |
| AIN-DOC-001(change-local) | 全仓 grep 复核:`AGENTS.md`/`governance/`/`verification/`/`templates/` 无残留"只能由人类执行/Agent 零设备命令"矛盾表述(archive/ 与历史 evidence 除外) | passed | TASK-AIN-001 run 记录附 grep 输出 |
| AIN-SCHEMA-001(change-local) | jsonschema 脚本:正例全 accept,反例(agent 缺 authorizationRef/未知 kind/缺目标确认)全 reject | passed | TASK-AIN-002 run 记录 |
| AIN-AUTH-PROV-001(change-local,r2) | provenance contract：任意 caller file/worktree override/历史 main/伪造 carrier/无 CODEOWNER approval 全 reject；fresh protected-main grant accept | passed | TASK-AIN-006 run 记录 |
| AIN-FACT-001(change-local,r2) | caller context 注入、stale readback、非 durable binding、tool/plan drift 全 dispatch=0；可信 port 同 Job 关联正例通过 | passed | TASK-AIN-006 run 记录 |
| AIN-USAGE-001(change-local,r2) | 并发/崩溃/重试 fault test：`maxRuns=1` 只有一个 durable reservation，crash 不退款、不重复 dispatch | passed | TASK-AIN-006 run 记录 |
| AIN-CONTRACT-001(change-local,r2) | authorizedAgent manifest/journal/usage round-trip；standardAgent destructive success 与无 ref intent 全 reject；v1 历史仍可读 | passed | TASK-AIN-005 run 记录 |
| AIN-DISPATCH-001(change-local,r2) | fake descriptor executor 端到端：grant→reservation→intent→固定 argv→semantic outcome→manifest；handoff/external-shell dispatch=0 | passed | TASK-AIN-007 run 记录 |

## Negative and recovery tests

- 授权缺失/过期/超次、plan hash 漂移、binding revision 不符、身份读回不匹配 →
  一律 dispatch=0(contract + 真机负探针双面);
- caller 提供的 authorization bytes/context/revision/readback/usage 一律不成为可信输入；
  local worktree/main ref 篡改与伪造 GitHub carrier 均 dispatch=0；
- `maxRuns` 并发 reservation 与 intent/outcome crash window 做确定性 fault injection，证明
  ceiling 不超发且 unknown 不退款；
- fake product executor 必须证明实际 argv 只来自 typed Provider plan；测试输出
  `dispatch=0` 的 handoff-only 路径不能再作为 AIN-004 readiness 依据；
- 刷机中断电/未回连 → 沿用 POL-RECOVERY-001 outcomeUnknown 语义,恢复路径 =
  CHG-2026-016 Loader wlx runbook(已演练);
- privacy scan:序列号字节不入仓(只入摘要),transcript 脱敏(RF-001/002 先例);
- 回归:Swift 全量基线不低于 readiness 钉定值,POL-* 其余不变式性质测试全绿。

## Deviations

任何 deviation 必须写明并在 PR review 中确认;不允许隐式豁免。

## Result gate

- [ ] 所有适用 AC passed 且 evidence 可复查
- [ ] Simulation/fake 未计入硬件支持
- [ ] executor.kind=agent 的 evidence 全部携带可解引用的 authorizationRef
- [ ] Traceability updated(AC-FLASH-015-03 入 registry,111 → 112)
- [ ] AIN-AUTH-PROV/FACT/USAGE/CONTRACT/DISPATCH-001 全部有独立 run evidence
- [ ] standardAgent/ordinary CI 与 caller-supplied context 的 destructive dispatch 恒为 0
- [ ] AIN-004 使用的新 authorization 在执行时 fresh、未超次且由产品 executor 消费
