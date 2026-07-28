# ArkUI UI Dump Specification Delta

> Change:CHG-2026-025-ai-native-unattended-device-ops@r3
> Target capability:`openspec/specs/ui-dump/spec.md`
> Baseline:CORE-2.1.0
> Proposed baseline:CORE-3.0.0

## ADDED Requirements

### Requirement: REQ-DUMP-009 Agent-owned UI Dump execution

在 Recipe、tool family、durable binding 与所需 E1 capability 已验证时，ArkDeck SHALL
允许 Agent 无人值守完成 window inventory、Recipe capture、独立 raw stdout/sidecar
publication、derived redaction/merge、owned cleanup 与 terminal manifest。仅产生 stdout
的 readOnly Recipe SHALL 作为 E0；创建/删除 remote sidecar、设置/恢复 Debug 参数或启停
fixture SHALL 按 E1 admission 执行。系统 SHALL NOT 要求人类复制命令、输入已可由 parser
确定的 window/component ID，或把新 run 固定分类为 `controlledHumanCapture`。

#### Scenario: AC-DUMP-009-01 Agent 完成四 Recipe capture

- GIVEN 目标 build 的四个 canonical Recipe family、window/component selector 与所需
  E1 capability 均已验证
- WHEN Agent 请求一个完整 ArkUI UI Dump Job
- THEN 产品 executor 从 durable binding materialize typed HDC step，分别发布 raw
  origins、可重建 derived Artifact 与 executor.kind=agent manifest
- AND 任一 sidecar ownership、parameter restore 或 parser 结果不确定时 fail closed，
  不读取/删除其他 Session 文件且不请求人类代跑命令
