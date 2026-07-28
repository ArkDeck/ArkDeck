# Trace Capture Specification Delta

> Change:CHG-2026-025-ai-native-unattended-device-ops@r3
> Target capability:`openspec/specs/trace/spec.md`
> Baseline:CORE-2.1.0
> Proposed baseline:CORE-3.0.0

## ADDED Requirements

### Requirement: REQ-TRACE-010 Agent-owned trace lifecycle

在 Adapter family、configuration、durable binding 与所需 E1 capability 已验证时，
ArkDeck SHALL 允许 Agent 无人值守完成 capability probe、parameter snapshot/set/readback、
可选 reboot/rebind、capture start/stop、verified receive、raw publication、host
postprocess、owned cleanup、parameter restore 与 terminal manifest。只读 help/tag probe
为 E0；parameter mutation、remote capture file、reboot 与 cleanup 为 E1。每次 mutation
SHALL 重新通过 trusted admission，Agent 分析或旧 probe SHALL NOT 充当 capability。

#### Scenario: AC-TRACE-010-01 Agent Trace 失败后自动补偿

- GIVEN Agent Trace Job 已通过 E1 admission，参数原值可恢复，remote path 属于当前 Job
- WHEN capture 或 receive 失败
- THEN系统保留 raw/partial evidence，按 typed compensation 停止 capture、恢复原参数并
  只清理可证明 owned 且已安全接收的远端文件
- AND compensation 任一 outcome unknown 时进入 needsAttention/waitingForRecovery，
  不要求人类代跑 cleanup/restore 命令也不盲目重试
