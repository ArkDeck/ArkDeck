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
| AC-FLASH-015-01 | Kit contract tests(无授权 → policyBlocked、dispatch=0)+ TASK-AIN-004 真机负探针 | passed | TASK-AIN-003/004 run 记录 |
| AC-FLASH-015-02 | Kit contract tests(逐项篡改/过期/超次/读回不符的 real-fault 注入)+ 真机负探针 | passed | TASK-AIN-003/004 run 记录 |
| AC-FLASH-015-03 | fake executor 层门通过路径 contract test + DAYU200 无人值守真机执行(v3 evidence,executor.kind=agent) | passed | TASK-AIN-003 tests;TASK-AIN-004 脱敏 transcript + EVD 记录 + hardware-matrix 行 |
| AIN-DOC-001(change-local) | 全仓 grep 复核:`AGENTS.md`/`governance/`/`verification/`/`templates/` 无残留"只能由人类执行/Agent 零设备命令"矛盾表述(archive/ 与历史 evidence 除外) | passed | TASK-AIN-001 run 记录附 grep 输出 |
| AIN-SCHEMA-001(change-local) | jsonschema 脚本:正例全 accept,反例(agent 缺 authorizationRef/未知 kind/缺目标确认)全 reject | passed | TASK-AIN-002 run 记录 |

## Negative and recovery tests

- 授权缺失/过期/超次、plan hash 漂移、binding revision 不符、身份读回不匹配 →
  一律 dispatch=0(contract + 真机负探针双面);
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
