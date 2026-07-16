# macOS M1 Shared Infrastructure Design

> Status：draft  
> Proposal：CHG-2026-002-macos-m1-infrastructure@r2
> Core baseline：CORE-2.0.0

## Components

```text
ArkDeckCore          typed steps / effect registry / Job state machines (TASK-M1-001)
ArkDeckProcess       ProcessExecutor + semantic results + streaming    (TASK-M1-002)
ArkDeckStorage       journal/snapshot + Session/Artifact + volumes     (TASK-M1-003/005)
ArkDeckRuntime       instance/activation/power/clocks/sleep-wake/logs  (TASK-M1-004/009)
ArkDeckOpenHarmony   HDC supervisor/auth + device binding/lanes        (TASK-M1-006/007)
ArkDeckWorkflows     orchestration + reconcile + SimulatedFlashProvider(TASK-M1-003/007/008)
```

依赖方向遵守 `architecture/system.md`：Core 不依赖平台框架；OpenHarmony/Workflows 依赖 Process/Storage/Runtime 的 Port 接口；无任何组件绕过 typed step 直接拼装设备命令。

## Execution order and staging

Task 依赖图即 roadmap 依赖序：Core(001) → Process(002)/Journal(003)/Runtime(004)/Diagnostics(009) → Storage(005)/HDC(006) → Binding(007) → Simulation(008)。每个 Task 是一个可独立评审的 PR，交付物、验证方法与停止条件记录在 `tasks.md` 对应任务段(V2 单一事实源,经 PR review 修改)。

## Evidence strategy

- Core AC 全部采用 canonical acceptance-cases 的 method/Test ID；expected evidence 直接指向规范 Scenario block，禁止转述；
- fake hdc 是仓库内确定性可执行 fixture,作为真实子进程运行以覆盖 supervisor/process 边界,但绝不触达真实设备或默认端口之外的网络;
- crash-window 注入覆盖 intent 前、intent durable 后、副作用后 outcome 前、outcome 后 finalize 前四个窗口；
- 单实例、电源、时钟语义按 Port contract tests 在 macOS 上验证（MAC-M1-PORTS-001）。

## Explicit non-goals

真实设备证据、parser golden family 扩展、任何功能 UI、以及 release capability 声明都不属于本 change；见 `spec-impact.md` 的排除清单。
