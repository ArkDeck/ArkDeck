# Workflow, Journal, and Recovery Specification Delta

> Change:CHG-2026-025-ai-native-unattended-device-ops@r3
> Target capability:`openspec/specs/workflow-journal-recovery/spec.md`
> Baseline:CORE-2.1.0
> Proposed baseline:CORE-3.0.0

## ADDED Requirements

### Requirement: REQ-WF-003 Agent-native typed device-operation control plane

ArkDeck SHALL 提供本地、机器可读的 Agent device-operation control plane，用于
submit、status、cancel、reconcile 与读取 terminal result。请求 SHALL 只引用已登记的
operation/profile、durable target selector、受控 Artifact lease、execution mode 与可选
authorization ID；它 SHALL NOT 接受 executable、argv、shell/command string、任意远端
path、authorization bytes/path、caller-supplied binding/readback/prerequisite/usage/outcome、
executor identity 或 effect override。未知 operation/profile SHALL 按
destructive/unsupported fail closed。executor identity SHALL 由可信宿主从受控本地
transport/进程上下文 mint，不得信任 request 自报 actor。

可信执行宿主 SHALL 根据 Core minimum effect、ready task、fresh durable binding、tool/
server/device facts 与 E1/E2 授权材料决定 admission。E0 readOnly 在 ready task 内 MAY
无人值守执行；E1 deviceMutation 另需匹配的 per-device typed capability evidence；E2
destructive 另需匹配的 standing authorization。Agent 提交请求或分析结果本身 SHALL NOT
mint、提升或复用 authority。每个已准入 effect SHALL 继续遵守 durable intent/outcome、
binding revision、lane/storage coordination、semantic result、cancellation、compensation、
recovery 与 Artifact 不可变规则。

Agent realHardware evidence SHALL 携带可信宿主解析的 `authorizationRef`：E0 指向
protected-main ready task/execution policy，E1 指向 accepted per-device capability，
E2 指向 standing authorization。request SHALL NOT 提供或覆盖该 ref。

#### Scenario: AC-WF-003-01 E0 无人工窗口执行

- GIVEN approved change 中一个 ready task 请求 registered E0 operation，且可信宿主持有
  fresh durable binding 与匹配的 tool/server facts
- WHEN Agent 提交 machine-readable request
- THEN Job 无需 device window 或人类代跑即执行 readOnly step，并产出 journal、raw
  Artifact、manifest 与 executor.kind=agent evidence
- AND deviceMutation/destructive dispatch 数均为 0

#### Scenario: AC-WF-003-02 E1 capability 漂移

- GIVEN Agent 请求一个 E1 operation，但 per-device typed capability 的 target、binding、
  tool/profile、operation scope、validity、次数或 compensation 任一不匹配
- WHEN trusted host 在首个 deviceMutation step 前 admission
- THEN deviceMutation/destructive dispatch 数均为 0，Job 返回精确 policy blocker
- AND caller 提供的 capability bytes、readback 或聊天确认不能使该请求通过

#### Scenario: AC-WF-003-03 禁止 shell 和自报成功

- GIVEN Agent request 含 executable、argv、shell、任意远端 path、effect override 或
  caller-supplied outcome/success
- WHEN control plane 解析并校验 request
- THEN request 在创建外部 effect intent 前被拒绝，外部进程调用数为 0
- AND 审计记录未知/禁止字段但不回显 secret 或敏感 raw value
