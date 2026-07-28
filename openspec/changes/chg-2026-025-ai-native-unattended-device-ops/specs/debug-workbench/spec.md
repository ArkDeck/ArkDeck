# Debug Workbench Specification Delta

> Change:CHG-2026-025-ai-native-unattended-device-ops@r3
> Target capability:`openspec/specs/debug-workbench/spec.md`
> Baseline:CORE-2.1.0
> Proposed baseline:CORE-3.0.0

## ADDED Requirements

### Requirement: REQ-DEBUG-008 Agent-owned diagnostics and deployment loop

ArkDeck SHALL 允许 Agent 通过 closed typed operations 组合 HiLog、HAP install/replace、
应用启停、port forward、owned file transfer 与 native library deployment，并与 UI Dump/
Trace 及 host analysis 组成有界 debug Job。HiLog host stream/read-only inspection 为 E0；
保留数据的 HAP install/replace、应用生命周期、forward、reboot 与受控文件 publish 为
E1，须有匹配的 per-device typed capability；HAP uninstall/clear-data/downgrade、持久
参数/全局 buffer、会清除数据、覆盖 system/vendor、需要 root/remount、影响 boot/runtime
或无法证明 rollback 的 native deployment SHALL 提升为 E2 并要求 standing authorization，
或在现行 Core 要求时返回结构化 impact approval blocker。

HAP install SHALL 验证 Artifact lease、bundle/version/signing/hash、target binding、data
impact 和安装后 readback。`.so` profile SHALL 固定 ABI、ELF build ID/hash、目标 bundle/
process/namespace/canonical path、owner/mode、旧值 snapshot、staging/atomic publish、
loader verification、restart、rollback 与 hazard policy；caller SHALL NOT 提供任意远端
路径或 argv。闭环中每个后续 effect SHALL 重新 admission，host analysis 只能生成下一份
typed request 草案，不能升级 authority。

#### Scenario: AC-DEBUG-008-01 Agent HiLog 长时采集

- GIVEN ready task 请求 registered HiLog host-stream profile，目标 binding 与 storage
  budget 有效
- WHEN Agent 启动并在预算或 deadline 到达时停止采集
- THEN系统无人值守完成 bounded rotation、raw shard publication、hash/顺序 manifest 与
  host analysis
- AND clear/resize/device-side persist/deviceMutation/destructive 调用数均为 0

#### Scenario: AC-DEBUG-008-02 Agent 部署 HAP 并复验

- GIVEN HAP Artifact、bundle/version/signing/hash、target binding、data impact 与 E1
  capability 全部匹配
- WHEN Agent 执行 install → start Ability → capture diagnostics → readback
- THEN所有 deviceMutation 从同一 durable binding revision materialize，安装后 package
  state 与期待值一致，Job 产出完整 evidence
- AND 任一 pin 或 semantic output 漂移时后续 start/capture dispatch 为 0

#### Scenario: AC-DEBUG-008-03 Native library publish 失败

- GIVEN `.so` deployment profile 声明 app-owned target、旧值 snapshot、atomic publish、
  loader verification 与 rollback
- WHEN publish 后 loader verification 失败
- THEN系统执行 typed rollback 并验证原 hash；rollback 成功时记录 failed+restored
- AND publish/rollback outcome 任一 unknown 时进入 waitingForRecovery，既不盲目重发也
  不把退出码 0 解释为部署成功

#### Scenario: AC-DEBUG-008-04 分析结果不能提升权限

- GIVEN host analysis 建议执行一个未在当前 capability scope 内的 E1/E2 operation
- WHEN Agent 把建议提交为下一步 request
- THEN trusted host 重新执行完整 admission，缺少 capability/authorization 时 effect
  dispatch 为 0
- AND derived report、LLM 输出或上一 Job 的 success 不构成 authority
