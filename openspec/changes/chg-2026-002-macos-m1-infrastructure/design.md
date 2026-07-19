# macOS M1 Shared Infrastructure Design

> Status：draft  
> Proposal：CHG-2026-002-macos-m1-infrastructure@r7
> Core baseline：CORE-2.0.0

## Components

```text
ArkDeckCore          typed steps / Job state + durable toolchain intent(TASK-M1-001/006)
ArkDeckProcess       ProcessExecutor + descriptor-bound launch gate    (TASK-M1-002/006)
ArkDeckStorage       journal/snapshot + Session/Artifact + volumes     (TASK-M1-003/005)
ArkDeckRuntime       instance/activation/power/clocks/sleep-wake/logs  (TASK-M1-004/009)
ArkDeckOpenHarmony   HDC supervisor/auth + device binding/lanes        (TASK-M1-006/007)
ArkDeckWorkflows     closed execution/finalization composition         (TASK-M1-003/006/007/008)
ArkDeckApp           HDC diagnostics/safety presentation only          (TASK-M1-006)
```

依赖方向遵守 `architecture/system.md`，r4 的精确新增依赖为：`ArkDeckWorkflows` 可依赖
`ArkDeckCore`、`ArkDeckOpenHarmony` 与 `ArkDeckStorage`，并由 OpenHarmony 既有依赖间接使用
`ArkDeckProcess`；App 只可 import `ArkDeckCore` 与 `ArkDeckWorkflows`。Core 不依赖任何平台
模块，Workflows 不直接 import Process，App 不直接 import Process/OpenHarmony/Storage。
因此链路保持 `Core typed Step → Workflows use case → OpenHarmony Adapter → Process atomic
launch`，并由 Workflows 经 Storage 完成 durable intent/outcome 与 terminal finalization；UI
不能直接拼装 argv、启动进程或铸造 authority。

## Execution order and staging

Task 依赖图即 roadmap 依赖序：Core(001) → Process(002)/Journal(003)/Runtime(004)/
Diagnostics(009) → Storage(005) → HDC(006) → Binding(007) → Simulation(008)。M1-005
必须先交付并验证通用的 `DurableSessionAuditAppending` 与
`SessionManifestPublishing` production seam；M1-006 才能在 Workflows 组合 HDC lifecycle
audit adapter。每个 Task 是一个可独立评审的 PR，交付物、验证方法与停止条件记录在
`tasks.md` 对应任务段(V2 单一事实源,经 PR review 修改)。

r4 进一步把 M1-006 明确依赖到已完成的 M1-001/002/003/005/009/010 与已验证的
CHG-2026-005 fixture/profile 输入。对 Core/Process 的修改是 M1-006 为关闭既有 HDC AC
所需的精确 cross-deliverable extension，不重开已完成 Task 的状态，也不授权其他行为变化。

r5 不改变上述设计。它只允许两个 pre-r4 legacy contract 与已批准设计同向收敛：构造的
PID/path/endpoint 字段形状不能建立 `arkDeckManaged` ownership，positive ownership evidence
留在 dedicated process-backed contract；successful lifecycle 的 audit 断言必须包含 terminal
reconciliation。相应修改不得删除、迁移或重命名旧 case，也不得改变其他旧 case 的断言。

r6 只解耦 M1-007 的 implementation scheduling。CHG-2026-014 已证明固定 M1-006 package
bytes/interfaces 在 `main` 且原 package 会话排他占用解除；M1-007 的九项 `AC-DEV-*` 在
canonical registry 中全部是 contract evidence,不要求 M1-006 的 server identity/generation、
authorization/key-access/subserver probe、signed Sandbox XCUITest 或 `MAC-M1-HDC-001`。

consumer 逐项边界如下：

| M1-007 deliverable | 使用的 consolidated interface | 需要 M1-006 source AC | 结论 |
| --- | --- | --- | --- |
| OriginalTargetSnapshot / CurrentDeviceBinding value + revision policy | ArkDeckCore/module boundary；不使用 HDC probe | no | may proceed headless |
| device-scoped typed HDC argv materialization | ArkDeckOpenHarmony target 与 typed value seam；不启动 process/server | no | may proceed headless |
| durable binding/rebind/step-intent adapter | TASK-M1-003 locked journal binding events + TASK-M1-005 generic manifest/audit seams | no | may proceed headless |
| USB/TCP/UART rebind policy、effect gate、per-device lane | Core/Workflows actor + synthetic identity/evidence | no | may proceed headless |

M1-007 dedicated implementation/tests 不调用 `HDCProduction` 的 server lifecycle/
authorization/probe 实现,不读取 integration golden,不运行真实或 fake HDC child。它只生成
完整参数数组并交给测试 counter；缺 binding、revision mismatch、歧义或未确认时 counter
为 0。required full-suite regression MAY 运行既有、显式路径绑定的 fake-HDC tests,但这些
既有结果不属于 M1-007 AC evidence。将来把该 typed command 接到真实 HDC execution 仍须
独立 consumer/integration readiness,不能由 M1-007 contract evidence推断。

r7 不解锁或执行 M1-008；它把历史简写 contract 补成以下两轴均可锁屏执行、但必须绑定
同一 implementation revision 的 headless task：

| M1-008 evidence axis | canonical gate | interactive/real-device dependency | conclusion |
| --- | --- | --- | --- |
| simulation isolation contract | `AC-FLASH-006-01` / `TEST-AC-FLASH-006-01` (`contract`) | none | synthetic success evidence 永久为 simulated，hardware-support verified writer call count 0 |
| macOS orchestration | `MAC-M1-SIM-001` / `TEST-MAC-M1-SIM-001` (`platform`) | local macOS filesystem only | journal/cancel/reconcile/reopen 可 headless 二值验证，real connectKey 与 external-tool launch count 0 |

`platform` 在这里表示实际 macOS storage/runtime seam 的可复查运行，不表示 signed App、GUI、
HDC、真实设备或 hardware evidence。Provider API 只暴露 synthetic fixture identity 与封闭 fault
scenario；它不接收 `CurrentDeviceBinding`、connectKey 或 ProcessExecutor。Workflows 通过
TASK-M1-003 的 locked journal/reconcile、Session manifest validator 和 TASK-M1-007 合入后的
synthetic identity/effect boundary 组合成功、delay、failure、disconnect、outcomeUnknown 与
cancellation。所有结果都持久化 `executionMode:simulated`；outcomeUnknown 不自动重放，任何
simulation receipt 都没有升级 hardware support 的路径。

因此 M1-008 的旧 `ready` 在 TASK-M1-007 未 done 时不满足 Definition of Ready。r7 只把它
置回 `blocked` 并固定两个新 Swift 文件、run path 和验证矩阵；TASK-M1-007 implementation/
done 合入后，另一个 readiness PR 才能固定实际 dependency OID、toolchain 与 baseline tests。

## Evidence strategy

- Core AC 全部采用 canonical acceptance-cases 的 method/Test ID；expected evidence 直接指向规范 Scenario block，禁止转述；
- M1-007 的九项 `AC-DEV-*` 以 pure contract/property/fault tests 覆盖 immutable snapshot、
  durable monotonic revision、exact `-t` target、USB threshold、TCP/UART reconfirmation、
  ambiguous effect rejection 与 per-device lane invariants；测试只用 synthetic identity/
  connectKey,M1-007 dedicated 真实 HDC/device/network/process dispatch count 为 0；
- M1-008 的两个 canonical Test ID 必须来自同一 headless implementation revision：
  contract test 覆盖 simulated evidence classification 与 hardware-support writer 零调用；
  macOS platform test 使用本地临时 Session/journal/manifest 覆盖 success/cancel/failure/
  disconnect/outcomeUnknown、reconcile 与 reopen，且 dedicated real connectKey、external process、
  network、HDC/device dispatch count 全为 0；
- fake hdc 是仓库内确定性可执行 fixture,作为真实子进程运行以覆盖 supervisor/process
  边界,但绝不触达真实设备或默认端口之外的网络；任何被 parser/probe 当成已支持语义的
  raw output 都必须来自 approved integration change 登记的 version/hash-pinned golden，
  未登记的 success/healthy/version output 只能得到 unknown/unsupported，不能作为 pass
  evidence；
- HDC Scenario 的用户可见结果由 macOS XCUITest 与对应 domain/contract evidence 共同
  闭环；XCUITest 至少覆盖完整诊断、external/unknown 确认式恢复选项、subserver capability
  只读展示、授权/通道警告、critical blocker 与 lifecycle impact preview；
- tool candidate 从 identity/hash/trust 检查到 launch 必须保持同一已打开 descriptor/inode
  binding；path/symlink/inode substitution fault 在任何 child 启动前 fail closed；
- macOS UI closure 使用实际 code-signed Sandbox test build，记录 app hash、签名身份与
  entitlement dump；只运行 profile 声明的 fake/read-only probe，不接触真实 HDC/设备，且
  该证据不改变 ADR-0001 的非 Sandbox v1 distribution decision；
- crash-window 注入覆盖 intent 前、intent durable 后、副作用后 outcome 前、outcome 后 finalize 前四个窗口；
- 单实例、电源、时钟语义按 Port contract tests 在 macOS 上验证（MAC-M1-PORTS-001）。

## Explicit non-goals

真实设备证据、在 M1-006 中自行扩展 parser golden 或 mutating probe family、改变
ADR-0001 分发路径、UI Dump/Trace/Debug/Flash
功能工作流及其 UI、HDC Scenario 明文要求之外的通用功能 UI，以及 release capability
声明都不属于本 change。唯一 UI 例外是已认领 HDC AC 的最小 diagnostics/safety surface；
该例外属于 r3 change design 本身，不由 tasks.md 单方面覆盖。见 `spec-impact.md`。
