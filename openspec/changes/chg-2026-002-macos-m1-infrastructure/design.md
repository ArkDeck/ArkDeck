# macOS M1 Shared Infrastructure Design

> Status：draft  
> Proposal：CHG-2026-002-macos-m1-infrastructure@r3
> Core baseline：CORE-2.0.0

## Components

```text
ArkDeckCore          typed steps / effect registry / Job state machines (TASK-M1-001)
ArkDeckProcess       ProcessExecutor + semantic results + streaming    (TASK-M1-002)
ArkDeckStorage       journal/snapshot + Session/Artifact + volumes     (TASK-M1-003/005)
ArkDeckRuntime       instance/activation/power/clocks/sleep-wake/logs  (TASK-M1-004/009)
ArkDeckOpenHarmony   HDC supervisor/auth + device binding/lanes        (TASK-M1-006/007)
ArkDeckWorkflows     orchestration + reconcile + SimulatedFlashProvider(TASK-M1-003/007/008)
ArkDeckApp           HDC diagnostics/safety presentation only          (TASK-M1-006)
```

依赖方向遵守 `architecture/system.md`：Core 不依赖平台框架；OpenHarmony/Workflows 依赖
Process/Storage/Runtime 的 Port 接口；App 的 HDC surface 只消费 use-case/presentation state，
无任何 UI 或组件绕过 typed step 直接拼装或执行设备命令。

## Execution order and staging

Task 依赖图即 roadmap 依赖序：Core(001) → Process(002)/Journal(003)/Runtime(004)/
Diagnostics(009) → Storage(005) → HDC(006) → Binding(007) → Simulation(008)。M1-005
必须先交付并验证通用的 `DurableSessionAuditAppending` 与
`SessionManifestPublishing` production seam；M1-006 才能在 Workflows 组合 HDC lifecycle
audit adapter。每个 Task 是一个可独立评审的 PR，交付物、验证方法与停止条件记录在
`tasks.md` 对应任务段(V2 单一事实源,经 PR review 修改)。

## Evidence strategy

- Core AC 全部采用 canonical acceptance-cases 的 method/Test ID；expected evidence 直接指向规范 Scenario block，禁止转述；
- fake hdc 是仓库内确定性可执行 fixture,作为真实子进程运行以覆盖 supervisor/process
  边界,但绝不触达真实设备或默认端口之外的网络；任何被 parser/probe 当成已支持语义的
  raw output 都必须来自 approved integration change 登记的 version/hash-pinned golden，
  未登记的 success/healthy/version output 只能得到 unknown/unsupported，不能作为 pass
  evidence；
- HDC Scenario 的用户可见结果由 macOS XCUITest 与对应 domain/contract evidence 共同
  闭环；XCUITest 至少覆盖完整诊断、external/unknown 确认式恢复选项、subserver capability
  只读展示、授权/通道警告、critical blocker 与 lifecycle impact preview；
- crash-window 注入覆盖 intent 前、intent durable 后、副作用后 outcome 前、outcome 后 finalize 前四个窗口；
- 单实例、电源、时钟语义按 Port contract tests 在 macOS 上验证（MAC-M1-PORTS-001）。

## Explicit non-goals

真实设备证据、在 M1-006 中自行扩展 parser golden family、UI Dump/Trace/Debug/Flash
功能工作流及其 UI、HDC Scenario 明文要求之外的通用功能 UI，以及 release capability
声明都不属于本 change。唯一 UI 例外是已认领 HDC AC 的最小 diagnostics/safety surface；
该例外属于 r3 change design 本身，不由 tasks.md 单方面覆盖。见 `spec-impact.md`。
