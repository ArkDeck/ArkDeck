# Verification and Agent Execution Policy

> Version:2.0.0
> Baseline:CORE-1.0.0(candidate)

## Verification layers

1. **Spec lint**:重复/非法 ID、孤立 SHALL、Requirement 无 Scenario、阻塞性 TBD、平台 override、损坏 schema。
2. **Pure Core tests**:状态机、effect/cancellation、binding policy、journal/schema、storage accounting、clock 和 property-based invariants。
3. **Parser golden tests**:HDC、Unauthorized、help/tag、HiDumper、HiLog 和 Flash 输出的已声明 family。
4. **Platform port contract tests**:进程、锁、电源、卷、持久文件访问、工具信任、日志和时钟。
5. **Workflow integration/fault injection**:fake executable、断线、崩溃窗口、ENOSPC、恢复/补偿失败。
6. **Real platform tests**:clean-host、Sandbox/SmartScreen、签名、安装、更新和辅助技术。
7. **Real hardware matrix**:精确设备、固件、HDC、transport、权限和 Provider。

低层测试不能替代高层证据。Simulation/fake 只能证明 orchestration,不证明硬件支持。真实设备 destructive 操作只能由人类执行(见 `governance/enforcement.md`)。

## Core property invariants

性质测试至少覆盖:

- 任意操作序列中同设备同时最多一个 mutation lane;
- external/unknown HDC server 自动 kill 调用数恒为 0;
- 身份确认和 binding revision durable 前 device mutation dispatch 为 0;
- TCP/UART 断线后不存在自动 rebind 路径;
- outcomeUnknown destructive step 不自动重放;
- plan-only mutation/destructive dispatch 为 0;
- simulated Provider 不接收真实 binding/process executor;
- journal/schema encode/decode round-trip;
- terminal Job 不再接受新 mutation;
- HostStorageCoordinator 不超过内部保留线,claim update 不 double-count;
- raw Artifact hash 在所有派生操作前后不变。

性质测试不能替代 HDC contract、平台 Port 或真机验收。

## Definition of Ready

任务进入 `ready` 前必须满足:

- 所属 change 已 approved,任务在 `tasks.md` 中有明确的 objective、in/out of scope 与 allowed/forbidden paths;
- 关联 Requirement/AC 明确,且没有影响任务的阻塞性 TBD;
- 每个 AC 的验证方法和所需 evidence 明确;
- 依赖任务完成,或 fake/fixture contract 已固定;
- 所需硬件/toolchain/系统环境可得;否则任务定位为 Spike/verification 而非实现;
- 风险等级、危险操作、取消和恢复边界明确;
- 任务可在一个独立可评审 PR 内闭环;
- 执行 Agent 不需要做新的产品或 Safety 决策。

## Definition of Done

任务只有在以下全部满足时才能标记 `done`:

- deliverables 完成且没有越过 allowed scope;
- 关联 AC 已通过并有可复查 evidence;
- 适用的正常、错误、取消、崩溃/重启/恢复场景覆盖;
- build、lint、unit、contract/integration tests 通过;
- Requirement → AC → Test → Evidence trace 更新;
- 没有未经批准的 Core、AC、schema 或 safety policy 变化;
- 没有把 simulation/plan-only/fake 记为真机证据;
- 新的持久技术选择形成 ADR,产品行为变化走 change delta;
- diff 自审,无 secret、私钥、真实敏感 Artifact 或无限日志;
- evidence/ 下已追加 run 记录;
- 没有仍属于本任务的 TODO。无法完成则保持 blocked。

`done` 的最终确认由维护者在 PR review 中做出;Agent 不得自行宣告 change verified。

## Change gates

- 全部任务 done 且每个 AC 有证据后,change 才能标记 `verified`(经维护者确认)。
- Core change 合入后必须升版 baseline,受影响平台的 conformance 状态变为 `needsReverification`,直到新 suite 通过。
- 真实 Flash 支持必须有匹配支持矩阵的真实硬件 evidence;未完成硬件证据时 capability/release 状态保持未 verified。
- 发布门(M5 阶段起草具体机制):目标平台所有适用 MUST/Safety AC 100% verified;"适用"由 release 声明的 capability 集合与 `contracts/capability-registry.yaml` 的 required/依赖闭包决定。

## Evidence 与 run 记录

```text
openspec/changes/<change>/evidence/
  summary.md
  runs/<task-id>/          # 每次执行一个子目录或一份记录
    run.md                 # 命令、结果、AC 结论、偏差、遗留风险
    <logs / artifacts>
```

- run 记录轻量但如实:执行了什么、结果如何、哪些 AC 通过/失败、simulation 还是真实环境。
- 真实硬件 evidence 按 `contracts/hardware-evidence.schema.json` 记录设备身份、固件、操作者与时间。
- raw 证据不改写;派生物注明来源。

## Stop conditions

遇到以下情况,Agent 必须停止受影响任务并标记 blocked:

- 需要改变 Core/AC/安全默认值;
- 两个权威规格冲突;
- 设备或 server ownership 无法确认;
- destructive outcomeUnknown;
- 需要未授权的新权限、联网、签名或外部系统变更;
- 必需硬件/fixture/工具缺失;
- 验证无法二值化或证据不可复查。
