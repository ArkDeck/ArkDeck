# r2 Security Review — AI Native unattended execution

> Date:2026-07-22
> Scope:CHG-2026-025 r1 governance、CLI、standing-authorization gate、locked contracts、
> TASK-AIN-004 readiness
> Result:blocked before real destructive dispatch

## Findings

### P0-AUTH-001 Caller-controlled authorization provenance

`arkdeck flash execute` 接受任意 `--authorization <path>`；parser 只校验 JSON shape、非空
`approvedBy/carrier` 与 pin 格式，没有证明 bytes 位于 freshly fetched protected main、没有
核对承载 commit/blob OID，也没有核对 GitHub merged PR/CODEOWNER approval。调用方可以同时
制造 authorization 与 carrier 文本。

### P0-FACT-001 Caller-controlled execution facts

`--unattended-context` 允许调用方声明 prior run count、durable binding revision、
prerequisites 和 identity readback。validator 不拥有 journal/device/tool ports，也不检查
readback freshness 或跨 Session 原子 usage。`maxRuns=1` 在并发 Job 中可被多个
`priorRunCount=0` 同时通过。

### P0-DISPATCH-001 Authorization is not product execution

gate success 只以普通文件写 intent 并输出 handoff command lines；CLI/Provider 明确不 spawn
真实工具。现有正例 contract 输出 `dispatch=0 real_device=0`，因此只证明 compare function，
不证明 intent-before-effect、critical safe boundary、semantic outcome 或 postflight 的产品链。

### P0-CONTRACT-001 Approved delta does not cover locked contracts

current manifest schema/semantic validator 仍要求 `standardAgent` destructive Step 为 notRun，
provider contract 仍声明 standardAgent 恒拒绝；journal/confirmation actor 也没有
authorizationRef 形态。r1 scoped delta 只覆盖 Constitution、REQ-FLASH-015 与 hardware
evidence schema，不能隐式覆盖这些 locked contracts。

### P1-CAPABILITY-001 Execution capability is not isolated

若 Agent OS 进程可直接运行 HDC/rkdeveloptool 或打开相同 USB capability，任何应用内 gate
都可被绕过。完整 zero-touch 支持需要产品执行宿主成为唯一 device/tool capability owner；
无法证明隔离的环境只能标记 blocked/nonConformant，不能进入 hardware support matrix。

## Disposition

- `TASK-AIN-004` 从 ready 回到 blocked；#296 readiness 作为历史保留但不得复用。
- 先完成 TASK-AIN-005/006/007，再以新的 main OID、授权载体和执行环境证据重新 readiness。
- 本 review 不修改/撤销 standing authorization 文件；Agent 依 POL-AGENT-001 不得自行修改
  authorization。任务状态阻断与后续可信 resolver 均 fail closed。
