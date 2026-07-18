# Tasks — CHG-2026-002 macOS M1 shared infrastructure

> V2 治理:本文件是任务的唯一事实源;状态经 PR review 合入生效。change r1 已于
> 2026-07-15 经 PR #14 合入 approved；r2 的 CORE-2.0.0 重定向已于 2026-07-16 经
> PR #22 合入生效。以下 TASK-M1-001 closure 状态仅在维护者 review/merge 后生效。

## TASK-M1-001 — ArkDeckCore 域模型、封闭 typed-step registry 与 Job 状态机

- Status:done
- Completion evidence:`evidence/runs/TASK-M1-001/core-2.0.0-closure.md`（contract；
  CORE-2.0.0 closure，状态变更仅在维护者 review/merge 后生效，不构成 change verified）
- Readiness gate:`CHG-2026-004` 已分别经 PR #19 实现、PR #20 验证，并经
  PR #21 archive 到 ratified `CORE-2.0.0`；current spec、journal contract、Swift
  state machine 与 `CORE-CONFORMANCE-2.0.0` 对两个 resume-marker 出口已一致。
- Requirements/AC:REQ-WF-001、REQ-WF-002、REQ-JOB-001；AC-WF-001-01、
  AC-WF-002-01、AC-JOB-001-01…07
- Depends on:none
- Allowed paths:`Packages/ArkDeckKit/Sources/ArkDeckCore/**`、对应 Tests、本 change `evidence/**`
- Deliverables:未知 kind 按 destructive/unsupported 拒绝的封闭 WorkflowStep decode;精确 Core 迁移图的 Job/终态状态机与 property tests;保持原始失败分类的补偿顺序。
- Completion gate:satisfied；已在本 change 的 `evidence/runs/TASK-M1-001/` 追加
  CORE-2.0.0 closure run，二值覆盖 `AC-JOB-001-07` 与全量回归。

## TASK-M1-001R — 非冲突安全复审修复

- Status:done
- Completion evidence:`evidence/runs/TASK-M1-001R/run.md`；implementation/review 已由
  PR #18 合入（commit `2c16a44`）。
- Requirements/AC:REQ-WF-001、REQ-WF-002、REQ-JOB-001；AC-WF-001-01、AC-WF-002-01、AC-JOB-001-02
- Depends on:none
- Allowed paths:`Packages/ArkDeckKit/Sources/ArkDeckCore/**`、对应 Tests、本 change `evidence/**`
- Forbidden paths:`openspec/specs/**`、`openspec/contracts/**`、`openspec/baselines/**`、`openspec/changes/chg-2026-004-resume-confirmed-failure-transition/**`
- Risk:medium（纯 host contract/parser/state-machine verification；无真实设备、HDC、网络或 destructive dispatch）
- Hardware required:no
- Deliverables:Profile exposure 校验覆盖根 Step 与全部 compensation descriptor；严格 JSON decoder 在任意对象层级拒绝 duplicate member name；Job transition 测试直接解析锁定 journal contract 的 pair union，并保留 mode-specific、终态及非法边验证；如实更新 `TASK-M1-001` evidence。
- Verification:`swift format lint` 指定四个 Swift 文件；`swift test --package-path Packages/ArkDeckKit`；`scripts/check-sdd.sh`。PR #18 执行期未自行解除 `TASK-M1-001` blocker 或标记 task/change done/verified；本 r2 状态修正在其维护者 review/merge 之后独立记录 `done`，不构成 change verified。

## TASK-M1-002 — 生产级 ProcessExecutor(语义结果分类、有界流)

- Status:done
- Completion evidence:`evidence/runs/TASK-M1-002/run.md`（contract + platform；包含
  leader 先退出、descendant 持 pipe 的 timeout/cancel P1 回归；状态变更仅在维护者
  review/merge 后生效，不构成 change verified、platform conformance 或 release claim）
- Readiness amendment:本任务包的精确范围与 verification gate 仅在维护者 review/merge
  后生效；readiness PR 不执行 TASK-M1-002、不产生实现 evidence，也不改变任何 Core、
  contract、platform conformance 或 release claim。
- Objective:将 M0A ProcessExecutor prototype 收敛为 `PORT-PROCESS-001` 的生产级
  macOS 实现，并以二值 contract/platform evidence 证明 shell-free argv、byte-safe
  bounded streaming、受控 timeout/cancel 与独立语义结果分类。
- Requirements/AC:`REQ-JOB-005`、`REQ-NFR-002`、`PORT-PROCESS-001`；
  `AC-JOB-005-01`、`AC-NFR-002-01`
- Depends on:`TASK-M1-001`（done；PR #23 merge commit
  `ffb7e50657e3cc208a4bbc9c5774fcf66acaffd9`）
- In scope:absolute executable URL + argument array；不经过 host shell；stdout/stderr
  原始 bytes 独立流式消费；invalid UTF-8 无损保留；有界内存 capture；launch、exit、
  signal、timeout、cancel 与 process-group descendant 结果；Adapter semantic result
  独立于 exit code，exit 0 不自动等于成功。
- Out of scope:HDC discovery/supervisor/parser family、device binding、journal/reconcile、
  Artifact store、UI、真实设备、网络、任何 device/destructive dispatch，以及修改 Core
  Requirement/AC/contract/baseline。
- Allowed paths:
  - `Packages/ArkDeckKit/Sources/ArkDeckProcess/**`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/ArkDeckContractTests.swift`（仅迁移或
    收敛既有 ProcessExecutor cases）
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/ProcessExecutorContractTests.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ProcessExecutor/**`
  - `openspec/changes/chg-2026-002-macos-m1-infrastructure/evidence/runs/TASK-M1-002/**`
- Forbidden paths:`openspec/specs/**`、`openspec/contracts/**`、`openspec/baselines/**`、
  `Packages/ArkDeckKit/Sources/ArkDeckCore/**`、`.../ArkDeckRuntime/**`、
  `.../ArkDeckStorage/**`、`.../ArkDeckOpenHarmony/**`、`.../ArkDeckWorkflows/**`、
  `Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/HDC/**` 与
  `.../Fixtures/HDCServer/**`。
- Risk:medium（真实 host child process、timeout/cancel 与 resource-pressure contract；
  无 HDC、网络、设备或 destructive side effect）
- Hardware required:no
- Required environment:macOS + 仓库声明的 Swift/Xcode toolchain 与仓库内/系统只读
  process fixtures；不下载依赖，不要求外部服务。
- Deliverables:生产级 ProcessExecutor；argv/no-shell 与 process group 门禁；byte-safe
  stdout/stderr 流及每流 64 KiB 默认 retained-capture 上限；semantic evaluator；
  1 GiB logical sparse/generated fixture 与 peak-memory/process-tree fault tests。
- Verification:
  - `TEST-AC-JOB-005-01` / `processContract`（minimum evidence:`contract`）:包含
    空格、中文与 shell metacharacter 的
    路径/参数逐元素原样到达 argv probe；shell spawn 与 expansion sentinel count 均为
    0；stdout/stderr 分离；invalid UTF-8 bytes round-trip；exit-0 semantic-failure fixture
    结论仍为 failure；timeout/cancel 终止受控 process group 且无 surviving descendant。
  - `TEST-AC-NFR-002-01` / `boundedMemoryContract`（minimum evidence:`platform`）:
    至少 1 GiB logical sparse/generated fixture 经 streaming consumer 完整计数；
    每流 retained capture 不超过配置的
    64 KiB，执行进程 peak RSS delta 不超过 64 MiB，fixture logical size 增长不形成线性
    内存聚合；记录 logical/allocated size、byte count 与 peak RSS。
  - `PORT-PROCESS-001` contract（minimum evidence:`platform`）:绝对 executable、
    argument array、独立 byte streams、timeout/cancel、no-shell 五项全部通过；相对
    executable、NUL argv/env 与非法 timeout 在 spawn 前拒绝，child launch count 为 0。
  - Commands:`swift format lint <TASK-M1-002 changed Swift files>`；
    `swift test --package-path Packages/ArkDeckKit --filter ProcessExecutorContractTests`；
    `swift test --package-path Packages/ArkDeckKit`；`scripts/check-sdd.sh`。
- Evidence gate:在
  `evidence/runs/TASK-M1-002/run.md` 记录 base revision、环境、锁定输入 hash、命令与
  结果、fixture logical/allocated size、byte/dispatch/process-tree counters、peak RSS、
  两个 AC 和 Port 的二值结论、偏差与遗留风险；缺任一项不得标记 `done`。

## TASK-M1-003 — write-ahead journal、snapshot、崩溃 reconcile 与审计放弃

- Status:done
- Completion evidence:`evidence/runs/TASK-M1-003/run.md`（contract + macOS platform；
  状态变更仅在维护者 review/merge 后生效，不构成 change verified、platform conformance、
  release claim 或真实硬件 evidence）
- Readiness amendment:本任务包的精确范围与 verification gate 仅在维护者 review/merge
  后生效；本 readiness PR 不执行 TASK-M1-003、不产生实现 evidence，也不改变任何
  Core、contract、platform conformance、release claim 或其他 Task 状态。
- Objective:将 M0A durable-journal prototype 收敛为 CORE-2.0.0 的生产级 journal、
  checkpoint、reconcile 与 recovery-abandonment 基础设施，并以 contract + macOS
  crash-window evidence 证明外部副作用前的 durable intent、outcome 后的 snapshot
  发布、未知结果零重放，以及未完成审计时资源与 hazard 不被释放。
- Requirements/AC:`REQ-JOB-002`、`REQ-JOB-006`、`REQ-JOB-007`；
  `AC-JOB-002-01`、`AC-JOB-006-01`、`AC-JOB-007-01`、`AC-JOB-007-02`；
  `MAC-M1-JOURNAL-001`；继承 `POL-WORKFLOW-001`、`POL-RECOVERY-001` 与
  `POL-SAFETY-001`，不重复认领 TASK-M1-001 已覆盖的 Job 状态机 AC。
- Depends on:`TASK-M1-001`（done；PR #23 merge commit
  `ffb7e50657e3cc208a4bbc9c5774fcf66acaffd9`）
- In scope:
  - 锁定 `journal-event-1.0.0` 的封闭 event vocabulary、严格 encode/decode 与 append-only
    JSONL；event/sequence/correlation、typed step/compensation、binding revision、arguments
    hash、reconcile 与 abandon payload 必须保持 contract 形状，未知 kind、未知字段、
    duplicate member、非法 transition payload 与 malformed completed record fail closed；
  - journal write/file sync/directory-entry durability、outcome-before-checkpoint、同目录临时文件
    + atomic replace + sync 的 checkpoint 发布，以及 torn tail/旧 checkpoint/完整 journal
    的恢复优先级；任一关键持久化失败阻止 dispatch 或 snapshot advancement；
  - 以可注入 Session catalog、Provider recovery evidence、binding evidence、managed-process
    stopper、device-lane/storage-claim releaser 与 fault point 实现启动扫描和 reconcile；仅在
    restartSafe、安全边界、确定 outcome 与已确认 binding 全部成立时选择已批准的安全
    恢复路径，intent-without-outcome 一律 `outcomeUnknown → waitingForRecovery`，destructive
    dispatch/replay/guess-compensation count 恒为 0；
  - `waitingForRecovery → userAbandonRequested` 的审计顺序：durable abandon intent → 按
    policy 停止 managed host process/等待 critical safe boundary → durable abandon outcome
    → 才允许 terminal transition 与 lane/claim release；未成功持久化 terminal outcome 时
    保持 waitingForRecovery 且 release count 为 0；
  - interrupted recovery record 中的 unresolved device hazard 保留；冲突 Job 默认 preflight
    failure，只有 Provider 明确允许、用户显式 risk override 与 durable audit 三者同时存在
    才可解除 gate。本 Task 只交付 gate/decision contract，不派发后续设备 Step。
- Out of scope:完整 Session/Artifact/manifest store 与 host-volume admission（TASK-M1-005）；
  HDC/device binding 实现（TASK-M1-006/007）；runtime clocks/sleep-wake（TASK-M1-004）；
  UI、真实设备、网络、任何真实 device/destructive dispatch；以及修改 Core Requirement、
  AC、`journal-event.schema.json`、`manifest.schema.json`、workflow-step contract 或 baseline。
- Allowed paths:
  - `Packages/ArkDeckKit/Sources/ArkDeckStorage/**`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/**`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/RuntimeAndStorageContractTests.swift`（仅迁移
    或收敛既有 journal/checkpoint prototype cases）
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/JournalRecoveryContractTests.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/JournalRecovery/**`
  - `Packages/ArkDeckKit/Tests/ArkDeckJournalCrashFixture/**`
  - `Packages/ArkDeckKit/Package.swift`（仅注册/连接 dedicated journal crash fixture）
  - `openspec/changes/chg-2026-002-macos-m1-infrastructure/evidence/runs/TASK-M1-003/**`
- Forbidden paths:`openspec/specs/**`、`openspec/contracts/**`、`openspec/baselines/**`、
  `Packages/ArkDeckKit/Sources/ArkDeckCore/**`、
  `Packages/ArkDeckKit/Sources/ArkDeckProcess/**`、
  `Packages/ArkDeckKit/Sources/ArkDeckRuntime/**`、
  `Packages/ArkDeckKit/Sources/ArkDeckOpenHarmony/**`、
  `Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/HDC/**`、
  `Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/HDCServer/**`、
  `Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ProcessExecutor/**`，以及其他
  change 的 evidence。
- Risk:high（Safety-critical durable ordering、crash recovery、unknown destructive outcome、
  audited release 与 hazard gate；验证仅使用本地临时目录、fake/injected side effect 与测试
  子进程，不触达 HDC、网络、设备或真实 destructive operation）
- Hardware required:no
- Required environment:macOS + 仓库声明的 Swift/Xcode toolchain；本地文件系统须支持
  production 实现使用的 sync/atomic-replace primitives；所有 crash fixture 固定仓库来源，
  以 absolute executable + argument array 启动，不下载依赖、不要求外部服务。
- Deliverables:生产级 closed journal codec/store；durable intent/outcome gate；原子且可恢复的
  checkpoint store；未 finalize Session scanner 与 deterministic reconciler；四窗口 crash
  fixture；audited abandonment coordinator；unresolved-hazard preflight gate；对应 fault
  injection/property/contract tests。不得在本 Task 引入新的持久技术选择；若实现发现必须
  新增 ADR、产品行为或安全语义，须停止并先修订 Task 或走独立 change proposal。
- Verification:
  - Locked-contract suite:对 `journal-event.schema.json` 的全部 event kind 与相关
    `manifest.schema.json` recovery/hazard 形状做 encode/decode vector；unknown/duplicate/
    malformed/torn/sequence-correlation invalid vectors 全部拒绝，raw journal 只追加且恢复
    不信任较旧或超前 checkpoint。
  - `TEST-AC-JOB-002-01` / `journalFaultInjection`（minimum evidence:`contract`）:分别在
    append、write、file sync、directory sync、outcome append 与 checkpoint publication
    注入失败；intent 未 durable 时 external dispatch count 为 0，outcome 未 durable 时
    snapshot sequence 不前进，所有 case 进入明确 failure/recovery 结论。
  - `TEST-AC-JOB-006-01` / `crashWindowFaultInjection`（minimum evidence:`contract`）:
    destructive intent durable 后、outcome 前的每个 vector 均恢复为
    `waitingForRecovery/outcomeUnknown`，destructive dispatch/replay/compensation count 为 0；
    confirmed outcome vector 只能按锁定 Job transition 与 recovery evidence 进入已批准路径。
  - `TEST-AC-JOB-007-01` / `abandonJournalFaultInjection`（minimum evidence:`contract`）:
    覆盖 abandon intent 失败、managed-process stop/safe-boundary 未确认、terminal outcome
    sync 失败与成功；前三类保持 waitingForRecovery 且 lane/claim release count 为 0，只有
    durable terminal outcome 成功后各释放一次。
  - `TEST-AC-JOB-007-02` / `hazardGateContract`（minimum evidence:`contract`）:对 Provider
    allow、user override、durable audit 的真值组合做穷举；任一缺失时冲突 preflight 与
    device dispatch 分别为 failed/0，三者齐备时只解除 gate 并保留完整 audit linkage。
  - `TEST-MAC-M1-JOURNAL-001` / macOS crash-window matrix（minimum evidence:`platform`）:
    dedicated 子进程在 intent 前、durable intent 后、side effect 后 outcome 前、durable
    outcome 后 finalize 前四处被 kill；重启扫描逐 case 记录 durable event sequence、state、
    outcome certainty、dispatch/replay/compensation/release counters，证明未知结果保持
    `outcomeUnknown`、零 destructive replay，且 fixture 自身 device/destructive dispatch 为 0。
  - Commands:`swift format lint <TASK-M1-003 changed Swift files>`；
    `swift test --package-path Packages/ArkDeckKit --filter JournalRecoveryContractTests`；
    `swift test --package-path Packages/ArkDeckKit`；`scripts/check-sdd.sh`；`git diff --check`。
- Evidence gate:在 `evidence/runs/TASK-M1-003/run.md` 记录 base revision、环境、锁定
  baseline/conformance/spec/journal/manifest/provider/platform/change 输入 hash、命令与结果、
  每个 fault/crash window 的 durable sequence 与所有 side-effect/replay/release counters、
  五个 Test ID 的二值结论、evidence class、偏差与遗留风险；缺任一项不得标记 `done`。

## TASK-M1-004 — macOS runtime ports:单实例、激活、电源、双时钟、睡眠观察

- Status:done
- Implementation + observation evidence:`evidence/runs/TASK-M1-004/run.md`（自动化 contract/macOS
  platform vectors 与 human-operated attempt 3 已通过；不构成真实硬件、完整 platform
  conformance 或 release claim）
- Completion gate:satisfied。`@lvye` 执行的 production `ContinuousClock`/`SuspendingClock` +
  NSWorkspace bounded manual sleep/wake attempt 3 已通过（2026-07-16 20:22–20:23 Asia/Shanghai，
  elapsed delta=39,913,733,041 ns、active delta=6,955,170,000 ns、suspended delta=32,958,563,041 ns、
  sequence=`sleep,wake`、counters=`1/1/1`），clock deltas、通知序列、counters 与二值结论已回填
  run.md；`blocked→done` 由本独立状态 PR 草拟，仅在维护者 review/merge 后生效，不改变实现、
  evidence 正文或任何 conformance/release 状态。
- Readiness amendment:本任务包的精确范围与 verification gate 仅在维护者 review/merge
  后生效；本 readiness PR 不执行 TASK-M1-004、不产生实现 evidence，也不改变任何 Core、
  contract、platform conformance、release claim 或其他 Task 状态。
- Objective:将 M0A 的单实例与电源租约 prototype 收敛为生产级 macOS runtime ports，并
  补齐 activation、双单调时钟、restart-safe 时间快照与 sleep/wake orchestration；以二值
  platform evidence 证明第二实例零 HDC/Session/Job 副作用、idle-sleep lease 全路径释放、
  wall-clock 跳变不污染进程内时间判断、系统休眠期间 elapsed/active 语义分离，以及 wake
  后的 journal/reconcile/速率分段触发。
- Requirements/AC:`REQ-JOB-008`、`REQ-NFR-001`；`PORT-INSTANCE-001`、
  `PORT-ACTIVATION-001`、`PORT-POWER-001`、`PORT-CLOCK-ELAPSED-001`、
  `PORT-CLOCK-ACTIVE-001`、`PORT-SLEEP-WAKE-001`；`AC-JOB-008-01`、
  `AC-NFR-001-01`、`AC-NFR-001-02`、`AC-NFR-001-03`、`AC-NFR-001-04`；
  `MAC-M1-PORTS-001`。
- Depends on:
  - `TASK-M1-001`（done；PR #23 merge commit
    `ffb7e50657e3cc208a4bbc9c5774fcf66acaffd9`）
  - `TASK-M1-003`（done；PR #27 merge commit
    `c5c82b757d9baa91164fe5feae65d5806089f8df`；提供锁定 journal/reconcile 边界，本任务
    不修改其 durability 或 recovery 语义）
- In scope:
  - 固定 per-user/product Application Support lock path；以 kernel-backed、non-blocking lock
    在任何 HDC、Session 或 Job writer 初始化前完成 single-writer admission；正常竞争只把
    losing process 导向 bounded activation request 后退出，lock path、filesystem 或 locking
    reliability 不可确认时 fail closed 到 read-only diagnostics，三类非 writer 路径的
    HDC/Session/Job side-effect count 均为 0；
  - profile-compatible 的 macOS activation request/listener；激活只请求持锁主实例展示/聚焦，
    不以 process list、notification delivery 或 endpoint presence 替代 single-writer lock，
    request 失败也不得取得 writer 权限；
  - `PowerActivityController` 的单一 production backend、引用计数 lease 与幂等 release；仅在
    critical scope 阻止 idle system sleep，success/failure/cancel/throw/deinit 全路径释放最后
    一个 lease，明确不宣称阻止合盖或用户主动 sleep；
  - 可注入的 wall/audit clock、elapsed/continuous monotonic clock 与
    active-work/suspending monotonic clock；deadline/timeout 只使用 elapsed clock，active
    duration、throughput 与 ETA sample 只使用 active clock，`Date`/UTC 只用于审计与
    restart-safe 判断；
  - restart-safe timing snapshot 只携带 accumulated elapsed/active duration、配置的
    deadline/timeout 与对应 UTC wall timestamp，不序列化或跨进程比较 monotonic instant/
    tick origin；新进程遇到 wall-clock 回退、缺失字段或无法证明剩余 deadline 时统一
    fail safe 为 expired；
  - `SleepWakeObserver` 的 start/stop 生命周期、typed sleep/wake event、重复/乱序通知去抖，
    以及注入式 lifecycle sink；每个有效 wake 记录锁定 `journal-event-1.0.0` 所需 elapsed/
    active duration 与 `throughputSegmentReset=true`，并各触发一次 ETA/throughput segment
    reset、reconnect evaluation 和 reconcile request；本任务只交付触发 contract，不直接
    访问 HDC 或改变 recovery 决策；
  - deterministic fake clocks/notification source、真实双进程 fixture 与 bounded manual
    macOS sleep/wake observation harness；测试不得修改系统 wall clock，Agent 不得自动执行
    host sleep，实际 sleep/wake observation 由人类维护者执行并记录。
- Out of scope:journal codec/durability、reconcile 状态机或 recovery decision 的修改
  （TASK-M1-003）；HDC reconnect 实现、device binding 与 mutation lane（TASK-M1-006/007）；
  diagnostics logging/export（TASK-M1-009）；App UI/composition、真实设备、网络、任何 device
  或 destructive dispatch；自动执行 host sleep、修改 host wall clock；以及修改 Core
  Requirement/AC、locked contract、baseline、platform/integration profile 或 conformance/
  release 状态。
- Allowed paths:
  - `Packages/ArkDeckKit/Sources/ArkDeckRuntime/**`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/RuntimeAndStorageContractTests.swift`
    （仅迁移/收敛既有 runtime prototype cases）
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/RuntimePortContractTests.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/Runtime/**`
  - `Packages/ArkDeckKit/Tests/ArkDeckRuntimePortFixture/**`
  - `Packages/ArkDeckKit/Package.swift`（仅注册/连接 dedicated runtime port fixture）
  - `openspec/changes/chg-2026-002-macos-m1-infrastructure/evidence/runs/TASK-M1-004/**`
  - `openspec/changes/chg-2026-002-macos-m1-infrastructure/tasks.md`（仅更新本任务状态与
    completion evidence）
- Forbidden paths:`openspec/specs/**`、`openspec/contracts/**`、`openspec/baselines/**`、
  `openspec/platforms/**`、`openspec/integrations/**`、`ArkDeckApp/**`、
  `Packages/ArkDeckKit/Sources/ArkDeckCore/**`、`.../ArkDeckProcess/**`、
  `.../ArkDeckStorage/**`、`.../ArkDeckOpenHarmony/**`、`.../ArkDeckWorkflows/**`、
  上述清单以外的 Tests/Fixtures、其他 task/change evidence 与其他 Task 状态。
- Risk:medium（per-user/product writer admission、local activation、power assertion 与 sleep-aware
  time/restart semantics；验证仅使用本地 lock/IPC、fake clocks/notifications、测试子进程及
  维护者执行的 host sleep observation，不触达 HDC、网络、设备或 destructive operation）
- Hardware required:no
- Required environment:macOS 14+、仓库声明的 Swift/Xcode toolchain、Application Support
  目录、kernel file lock、AppKit/NSWorkspace 与 `ContinuousClock`/`SuspendingClock` 或经
  contract 证明等价的系统 API；不下载依赖、不要求外部服务。production 双时钟与
  NSWorkspace notification 的平台结论另需维护者完成一次 bounded manual sleep/wake
  observation；若该观察环境不可得，任务不得标记 `done`。
- Deliverables:生产级 single-instance admission + activation service；引用计数 power
  controller；可注入的 audit/elapsed/active clocks、deadline evaluator、restart-safe timing
  snapshot 与 throughput segment tracker；sleep/wake observer + lifecycle sink；dedicated
  双进程 fixture、fake-clock/notification contract suite 与人工平台观察 harness/runbook。
  不得在本 Task 引入新的持久 schema 或绕开 profile 的 runtime 技术选择；若实现发现必须
  改变产品行为、安全语义或 locked contract，须停止并先修订 Task/平台设计或走独立 change。
- Verification:
  - `TEST-AC-JOB-008-01` / `platformInstanceContract`（minimum evidence:`platform`）:
    dedicated 两进程 fixture 证明恰有一个 writer；losing process 只发一次 activation request
    后退出，Job/HDC/Session open/write count 全为 0；activation delivery 失败不接管 lock；
    lock path symlink/permission/unreliable vectors 进入 read-only diagnostics，副作用计数仍为 0。
  - `PORT-ACTIVATION-001` contract（minimum evidence:`platform`）:主实例 listener 只处理匹配
    product/user 的 bounded request，每个 request 至多激活一次；重复 delivery 可去重，且
    activation success/failure 均不改变 lock ownership 或 writer count。
  - `PORT-POWER-001` contract（minimum evidence:`platform`）:并发/嵌套 lease 只建立一个
    underlying idle-sleep activity；success、failure、cancel、throw、显式 end、deinit 与
    controller teardown 后 begin/end count 精确平衡，重复 release 不 double-end。
  - `TEST-AC-NFR-001-01` / `clockContract`（minimum evidence:`platform`）:对 wall clock
    前跳/回退 vectors，elapsed timeout 与 active duration 仅随各自注入 monotonic clock 变化，
    deadline/duration 结果与未跳变 control 完全相同。
  - `TEST-AC-NFR-001-02` / `sleepClockContract`（minimum evidence:`platform`）:virtual sleep
    60 s 且原 overall deadline 剩余 30 s 时 elapsed 增加 60 s、deadline expired、active 增量
    为 0；维护者 observation 另证明 production clock pair 在一次真实 macOS sleep/wake 窗口
    中保持同一语义，Agent 不执行 sleep command。
  - `TEST-AC-NFR-001-03` / `sleepClockContract`（minimum evidence:`platform`）:有效 wake
    恰好创建一个新 throughput/ETA segment，首个新 sample 不读取 sleep duration 或旧 segment
    瞬时速率；重复/乱序 wake 的 journal、reset、reconnect-evaluation、reconcile count 不增加。
  - `TEST-AC-NFR-001-04` / `restartClockFaultInjection`（minimum evidence:`platform`）:
    新进程只读取 accumulated durations、configured deadline/timeout 与 UTC timestamp；snapshot
    不含 monotonic instant/tick origin；wall-clock 回退、缺失/损坏 timing evidence 与无法证明
    deadline 未到期 vectors 全部得到 expired，旧 tick read/compare count 为 0。
  - `TEST-MAC-M1-PORTS-001` / macOS runtime Port matrix（minimum evidence:`platform`）:
    汇总 instance、activation、power、clock、sleep/wake 全部上述 vectors；每个有效 sleep/wake
    的 journal event shape 可由锁定 contract 校验，wake 的 segment reset 与 reconcile trigger
    各一次；人工 observation 记录 production clock deltas 和 NSWorkspace event sequence。
  - Commands:`swift format lint <TASK-M1-004 changed Swift files>`；
    `swift test --package-path Packages/ArkDeckKit --filter RuntimePortContractTests`；
    `swift test --package-path Packages/ArkDeckKit`；`scripts/check-sdd.sh`；
    `git diff --check`；静态检查确认 deadline/duration 不以 `Date`/wall clock 计算、Runtime
    production source 不直接访问 HDC/Session 且 fixture 不使用 host shell 字符串拼接。
- Evidence gate:在 `evidence/runs/TASK-M1-004/run.md` 记录 base revision、OS/architecture/
  Swift toolchain、锁定 baseline/conformance/spec/journal/ports/platform/change 输入 hash、全部
  命令与结果；逐 vector 记录 writer/activation/Job/HDC/Session、power begin/end、wall/
  elapsed/active/deadline、old-tick read、sleep/wake/journal/reset/reconnect/reconcile counters；
  restart snapshot 字段与 fail-safe 结论；人工 observation 的操作者、时间、macOS build、
  production clock deltas、NSWorkspace sequence 与 pass/fail；六个 Test ID 与六个 Port 的二值结论、
  evidence class、偏差与遗留风险。缺任一项不得标记 `done`；本 evidence 不是 hardware、
  platform conformance 或 release claim。

## TASK-M1-005 — Session/Artifact store、manifest 管线与 host-volume 协调

- Status:done
- Completion evidence:`evidence/runs/TASK-M1-005/run.md`（2026-07-18 review closeout:全部验证命令
  已在有执行能力的主机实测——dedicated 58/0 failures、JournalRecovery 29/0、full-suite 169/0
  failures(1 项既有 opt-in 手动 sleep/wake skip)、format lint 0 diagnostics、`check-sdd` 0 error、
  diff check 通过；此前 remediation 中两项从未执行过的 test fixture 缺陷已修正,并按 review 修复清单
  完成 mechanism-freeze 收口(marker 终态出口、export manifest 身份校验、journal inode 绑定、shard 锁
  post-flock 复验等,详见 run.md Deviations)。实现已由维护者 review 并经 PR #37 合入(main
  `9e1f1da`,2026-07-18);`ready→done` 由本独立状态 PR 执行,仅在维护者 review/merge 后生效,
  不改变实现、evidence 正文或任何状态语义,不构成 change verified、完整 platform conformance、
  release claim 或真实设备 evidence）
- Readiness review(2026-07-17,独立 readiness/status PR):r3 task contract 已由维护者经
  PR #35 合入(main `11eb5cbe69bc9089fd870d6397f698f4c93dd299`),原 blocker(占位条目未满足
  Definition of Ready)解除。独立复核结论:
  - 依赖:`TASK-M1-001` done;`TASK-M1-003` done(PR #27 merge commit
    `c5c82b757d9baa91164fe5feae65d5806089f8df`),`DurableJournalAppending` 等 durability
    primitives 存在于 `ArkDeckStorage`(`RecoveryCoordination.swift`、`DurableFiles.swift`);
  - 接口形状:locked `manifest.schema.json` 的 confirmation 定义已含 `serverLifecycle`
    kind 与 required `relatedStepIds`;本任务两个 production seam 均无需修改任何 locked
    contract/schema;
  - 验证输入:12 个 `AC-ART/STO-*` 与 `MAC-M1-STORE-001` 在 canonical acceptance registry
    与 `scope.yaml` 中精确存在,registry method 与本任务 Verification 声明一致;
  - 环境:base `11eb5cb` 上 `swift build --package-path Packages/ArkDeckKit --build-tests`
    通过;dedicated `SessionArtifactStorageContractTests` 与 `Fixtures/SessionStorage/**`
    尚不存在,由实现按 allowed paths 新建;
  - 路径冲突:allowed paths 与 blocked 的 TASK-I5-001/I5-002、TASK-M1-006 无交集;
    `TASK-M1-009` 占位条目的 allowed paths 含 `ArkDeckStorage/**`,按既有约束两任务不得
    同时实现,M1-009 实现前须先完成自身 readiness 扩写并与本任务错开。
- Readiness gate:本 readiness/status PR 只将本任务从 `blocked` 恢复为 `ready`,不执行
  TASK-M1-005、不产生 implementation evidence,也不改变其他 Task 状态或任何 Core、
  contract、platform conformance、release claim;`ready` 仅在维护者 review/merge 后生效。
- Objective:在 M1-003 已锁定 journal/recovery 语义之上交付 production Session layout、
  Artifact/manifest publication、host-volume admission/retention，以及供上层 workflow 使用的
  通用 durable Session audit 与 manifest publisher；Storage 不依赖 HDC/UI，也不铸造执行
  authority。
- Requirements/AC:`REQ-ART-001`…`REQ-ART-006`、`REQ-STO-001`…`REQ-STO-005`，
  `AC-ART-001-01`、`AC-ART-002-01`、`AC-ART-003-01`、`AC-ART-004-01`、
  `AC-ART-005-01`、`AC-ART-006-01`、`AC-ART-006-02`、`AC-STO-001-01`、
  `AC-STO-002-01`、`AC-STO-003-01`、`AC-STO-004-01`、`AC-STO-005-01`；
  `MAC-M1-STORE-001`。
- Depends on:
  - `TASK-M1-001`（done；提供 typed step/Job/confirmation vocabulary）
  - `TASK-M1-003`（done；提供 locked journal codec、`DurableJournalAppending` 与 recovery
    durability primitives；本任务不改变其 schema/replay 语义）
- In scope:
  - 按规范建立每 Job 独立 Session layout，保留 journal/snapshot、command/event audit、
    raw/derived、partial 与 final manifest；失败/cancel/interrupted 不伪装 success；
  - 流式 Artifact hash/write、`.part` + validation + atomic publication、immutable raw 与 derived
    lineage、默认受控引用而非复制大镜像、privacy export 与 pinned retention；
  - volume identity、metadata/finalization headroom、并发 admission、运行期 ENOSPC 与重挂
    identity fail-closed；
  - 公开通用 `DurableSessionAuditAppending` production seam：接受有界、canonical、typed
    `SessionAuditRecord`（至少含 schema/record/audit/correlation/session/job IDs、category、
    timestamp 与结构化 details），`appendAndSynchronize` 仅在 durable 后返回；支持关闭重开
    后按 correlation replay，写失败显式抛错，不以 actor 内存状态替代 durability；
  - 公开 `SessionManifestPublishing` production seam：按 locked `manifest.schema.json` 原子
    发布，支持既有 `confirmations[]` 中的 `serverLifecycle` kind 与 related Step IDs；manifest
    只是 durable record，不产生或扩大 confirmation/step authority；
  - audit/manifest seam 保持 Storage-neutral，不 import ArkDeckOpenHarmony/SwiftUI，不解释
    HDC output，不执行进程；M1-006 负责把 HDC preview/confirmation/intent/actual argv/outcome
    映射为上述通用 record 并验证 host-wide correlation。
- Out of scope:修改 locked journal/manifest/workflow-step contract 或 Core AC；HDC-specific
  mapping/supervisor/UI、device binding、真实设备/网络、任何 device/destructive dispatch；
  通用 History UI 与 release/conformance 状态。
- Allowed paths:
  - `Packages/ArkDeckKit/Sources/ArkDeckStorage/**`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/SessionArtifactStorageContractTests.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/SessionStorage/**`
  - `openspec/changes/chg-2026-002-macos-m1-infrastructure/evidence/runs/TASK-M1-005/**`
  - `openspec/changes/chg-2026-002-macos-m1-infrastructure/tasks.md`（仅更新本任务状态与
    completion evidence）
- Forbidden paths:`openspec/specs/**`、`openspec/contracts/**`、`openspec/baselines/**`、
  `openspec/platforms/**`、`openspec/integrations/**`、除 ArkDeckStorage 外的所有 Sources、
  上述清单以外的 Tests/Fixtures、其他 task/change evidence 与其他 Task 状态。
- Risk:high（durable publication、ENOSPC、volume identity、并发额度与 retention；全部验证
  使用临时目录/sparse fixture/fault injection，无设备、HDC、外联网络或 destructive side
  effect）
- Hardware required:no
- Deliverables:production Session/Artifact/volume store；`DurableSessionAuditAppending` +
  reopen/replay implementation；`SessionManifestPublishing` + locked-schema atomic publisher；
  12 个 canonical `TEST-AC-ART/STO-*` 与 `TEST-MAC-M1-STORE-001` dedicated tests；run evidence。
- Verification:
  - `TEST-AC-ART-001-01`…`TEST-AC-ART-006-02` 按 acceptance registry 的
    artifactContract/property/faultInjection/manifestSchema/privacyExport/retention methods
    覆盖完整 Scenario；
  - `TEST-AC-STO-001-01`…`TEST-AC-STO-005-01` 按 volume identity、headroom、concurrency、
    ENOSPC 与 remount fault methods 覆盖完整 Scenario；
  - `TEST-MAC-M1-STORE-001` 汇总同卷共享 budget、第二 heavy writer wait/reject、metadata
    headroom、runtime ENOSPC finalize 与不同 volume identity 拒绝；
  - seam contract:preview/confirmation/intent/outcome 类别的 generic audit record 分别
    append+sync，关闭并重开后 record bytes/order/correlation 完整；注入 intent/confirmation
    write failure 时调用方收到 failure，不能得到“durable”成功；manifest 的
    `serverLifecycle` confirmation 与 related Step IDs round-trip，unknown/extra/partial 文件
    fail closed；
  - Commands:`swift format lint <TASK-M1-005 changed Swift files>`；
    `swift test --package-path Packages/ArkDeckKit --filter SessionArtifactStorageContractTests`；
    `swift test --package-path Packages/ArkDeckKit`；`scripts/check-sdd.sh`；
    `git diff --check`。
- Evidence gate:run 记录 base revision、输入 hash、volume/filesystem/toolchain、全部命令与
  结果、fault window、logical/allocated bytes、claims/headroom、audit fsync/reopen/replay、
  manifest hash/round-trip 与全部 13 个 Test ID 的二值结论。缺任一项不得标记 `done`；
  evidence 不包含 HDC capability、真实硬件、platform conformance 或 release claim。

## TASK-M1-006 — HDC supervisor、endpoint 隔离、授权工作流与 fake-hdc 对抗

- Status:ready
- Readiness restoration（2026-07-18，TASK-I5-002 独立 readiness/status PR；`ready` 仅在
  维护者 review/merge 后生效）:原四项 blocker 逐项复核解除——
  - Change-design gate:resolved。CHG-002 r3（最小 HDC UI surface 入 scope、XCUITest
    allowed paths）已由维护者经 PR #35 合入（main `11eb5cbe69bc9089fd870d6397f698f4c93dd299`）。
  - Semantic fixture gate:resolved。CHG-2026-005 已 approve（PR #40，main `3a4d45c`），
    TASK-I5-001 登记已合入（PR #41，main `4ac288c`）:failure（unauthorized/offline）+
    success/healthy/version 五 fixture 在 `Golden/1.0.0/registry.json`、
    `INTEGRATION-PROFILES-0.3.0` 与 `core-conformance.yaml` 三方 hash 一致（I5-002 于 main
    独立重算逐项 1/1/1）；`OPENHARMONY-TOOLS@0.2.0` 逐 family probe/semantic mapping 在案。
    实测披露:真实 hdc 3.2.0d 成功输出不含 M0A parser 假设的 `[success]` 标记（profile
    0.2.0 与 `HDCGoldenResourceContractTests` 已钉死）——本任务接线 parser 必须按登记形态
    扩展 marker，不得静默放宽正则或绕过登记形态。
  - UI gate:resolved。r3 已为本任务授予 `ArkDeckApp/App`、`Features/HDC`、
    Localizable 与 macOS XCUITest 的精确 allowed paths（随 PR #35 生效），UI Scenario 有
    可交付验证面。
  - Durable-audit gate:resolved。TASK-M1-005 已 done（实现 PR #37 main `9e1f1da`、状态
    PR #38 main `0e7aa8e`），production `DurableSessionAuditAppending`（append+full-sync、
    关闭重开 replay、torn-tail 截断）与 `SessionManifestPublishing`（write-once、
    `serverLifecycle` confirmation + relatedStepIds round-trip）的 evidence 在
    `evidence/runs/TASK-M1-005/run.md`。
  - Pinned golden 只读约束:`Fixtures/HDC/Golden/1.0.0/**` 与其 resource declaration 对
    本任务只读，仅经 `Bundle.module` 消费；不得重写/新增 fixture、修改 registry/lock/
    conformance 登记或 resource declaration 后自行判 pass（变更须走新的 approved
    integration change）。
- Readiness amendment:本任务包的精确范围与 verification gate 仅在维护者 review/merge
  后生效；本 readiness PR 不执行 TASK-M1-006、不产生实现 evidence，也不改变任何 Core、
  contract、platform conformance、release claim 或其他 Task 状态。
- Objective:将 M0A-003 的 `HDCServerSupervisor`、discovery 与 parser prototype 收敛为
  生产级 OpenHarmony 工具层：HDC 命令执行统一接入 TASK-M1-002 的 ProcessExecutor 与
  `ProcessSemanticEvaluating`（兑现 TASK-M1-010 在 `HDCSemanticOutputParser` 留下的迁移
  边界），补齐 toolchain snapshot/诊断、endpoint 隔离、unauthorized 授权工作流与独立的
  channel-protection 状态，并以 fake-hdc 真实子进程对抗矩阵证明 external/unknown server
  的自动 lifecycle 调用数恒为 0、ownership/generation 迁移精确、global failure 恰好一次
  fan-out、critical gate 与过期确认按 contract 阻断。
- Requirements/AC:`REQ-HDC-001`…`REQ-HDC-010`（继承 `POL-HDC-001`）；
  `AC-HDC-001-01`、`AC-HDC-001-02`、`AC-HDC-002-01`、`AC-HDC-003-01`、`AC-HDC-003-02`、
  `AC-HDC-004-01`、`AC-HDC-005-01`（adapterGolden，只读消费 CHG-2026-005
  登记并 hash-pin 的 fixture）、
  `AC-HDC-006-01`、`AC-HDC-007-01`、`AC-HDC-007-02`、`AC-HDC-008-01`、`AC-HDC-009-01`、
  `AC-HDC-010-01`、`AC-HDC-010-02`、`AC-HDC-010-03`；`MAC-M1-HDC-001`。本 change 内
  HDC 域 AC 全部由本任务认领，不与 TASK-M1-007（REQ-DEV）重叠。
- Depends on:
  - `TASK-M1-002`（done；PR #25 merge commit
    `11ffbf9755f988d54e1df01d4631c5827b7735c3`；提供 ProcessExecutor 与
    `ProcessSemanticEvaluating`，本任务不修改其行为）
  - `TASK-M1-003`（done；PR #27 merge commit
    `c5c82b757d9baa91164fe5feae65d5806089f8df`；提供 journal/audit durability 边界，本任务
    只经既有接口写 lifecycle audit，不改 durability 或 recovery 语义）
  - `TASK-M1-005`（done；实现 PR #37 main `9e1f1da`、状态 PR #38 main `0e7aa8e`；production
    `DurableSessionAuditAppending`、`SessionManifestPublishing` 已交付并有 reopen/replay/
    confirmation evidence，本任务经其公开边界做 lifecycle audit adapter，不改其语义）
  - `TASK-M1-010`（done；PR #30 merge commit
    `6725bb375e0fee1b261efa9e2adc6cd1e95e6237`；统一 `unknownOutput` 语义族并声明本任务
    执行 parser/executor 接线）
- In scope:
  - Supervisor 生产收敛：host-wide `HDCServerSupervisor` 的发现、健康、版本、endpoint、
    ownership、generation 与事件 fan-out 全部经真实 ProcessExecutor 子进程驱动；
    `external | unknown` ownership 的 kill、restart、`kill -r`、`start -r`、`killall-sub`
    自动调用数恒为 0，`arkDeckManaged` 只能由 PID/tool path/endpoint 启动证据建立；
    server generation/健康变化对共享 endpoint 的全部 recipient 恰好一次 fan-out；
  - `mutateHDCServerLifecycle` typed-step 门禁收敛：impact preview、精确 generation/action
    确认、dispatch 前重验证、critical-Job 阻断、过期确认失效与 host-wide audit/broadcast
    按 REQ-HDC-010 三个 Scenario 落地；audit 只经 TASK-M1-005 已交付并验证的
    durable Session audit/manifest seam（其内部复用 M1-003 durability primitive）；
  - Production durable audit adapter:在 `ArkDeckWorkflows` 组合
    `HDCServerLifecycleAuditStore`、TASK-M1-005 `DurableSessionAuditAppending` 与
    `SessionManifestPublishing`；impact snapshot、user confirmation、typed-step intent、实际
    executable/argv/endpoint、outcome、generation 变化与 affected Job/coordinator IDs 使用同一
    step/audit correlation 持久化。intent/confirmation 未 durable 时 lifecycle executor dispatch
    为 0；outcome 持久失败时保留 `outcomeUnknown` 并对全部 recipient 广播
    reconcile；关闭并重开 durable store 后必须可复查完整 audit，不得以内存
    actor state 充当证据；
  - Toolchain snapshot 与诊断：external-first 候选发现固定 absolute path、来源、hash、
    client/server/daemon version、endpoint 与 server generation 进 Job intent；不可探测字段
    显式 unknown/unverified，不省略、不猜测；`PATH` 顺序变化不得让运行中 Job 静默换工具；
  - Endpoint 隔离：默认端口、`OHOS_HDC_SERVER_PORT` 与显式 endpoint 三源解析，选择结果
    只注入 ArkDeck 自己的子进程环境；不修改用户全局 shell/系统环境；仅更换端口不得推断
    已拥有独立 server；
  - 授权工作流与通道状态：unauthorized 为可恢复状态（提示解锁/信任 → 有界可取消轮询 →
    区分 ready/denied/timedOut），不为重新弹窗 kill server；key 只记录公钥指纹与诊断，
    不复制/删除/上传私钥、不硬编码 key 路径；授权状态与 channel protection 独立建模，
    `encryptedVerified` 需版本化 evidence，否则 `unverifiedAssumeUnprotected`；
  - 最小 HDC UI 闭环：实际 macOS UI 只消费已验证 presentation/use-case
    state，展示 toolchain 全部诊断字段与 unknown/unverified、key 权限错误、
    denied/timedOut + 非破坏重试路径、authorization/channel protection 独立状态及
    不受保护 TCP 警告、external/unknown ownership 的诊断与仅用户确认的恢复选项、
    subserver capability/unknown 的只读展示、critical Job/Step/safe-boundary 阻断说明，以及 lifecycle
    action/endpoint/generation/ownership/affected devices+Jobs/other-client uncertainty/
    interruption/recovery impact preview。UI 不直接执行进程，不从文案或按钮铸造
    authority；输入只来自上述 domain/use-case state；
  - Parser/semantic 收敛：`HDCSemanticOutputParser` 经 `ProcessSemanticEvaluating` 接入
    executor；只读消费 CHG-2026-005 登记的 success/healthy/version 与
    `AC-HDC-005-01` exit-0 + `[Fail]`/错误码/Unauthorized/Offline golden fixture，raw
    stdout/stderr 可查；只接受 profile 声明且 pinned 的 family，未知 output 保持
    unsupported/raw，不得改写 pinned fixture 或放宽 marker/正则（增加 family 属于
    integration change）；
  - fake-hdc 对抗 fixture：dedicated 可执行 target 以真实子进程回放 CHG-005
    approved/pinned semantic raw bytes（success/healthy/version、unauthorized E000002/E000003、
    `[Fail]`、offline）并提供 hang/slow/crash/oversized 等 process fault vectors，驱动
    supervisor/授权/parser 全矩阵（`MAC-M1-HDC-001`）。未登记 raw family 一律
    unknown/unsupported；hang/slow/crash/oversized 只证明 process/fault behavior，不冒充
    semantic golden。fixture 仅使用 loopback ephemeral endpoint 与本地进程/文件通信，
    不 bind 固定保留端口。
- Out of scope:device binding revision、transport 重绑定与 per-device mutation lane
  （TASK-M1-007）；SimulatedFlashProvider（TASK-M1-008）；journal codec/durability 或
  recovery 语义修改（TASK-M1-003）；执行任何已安装真实 `hdc`（`hdc version` 会隐式拉起
  host server——M0A 结论，探测一律走 fake-hdc fixture）；真实 server kill/restart、真实
  设备、loopback 之外的网络、任何 device/destructive dispatch；`MAC-M0A-HDC-001` blocked
  行的状态处理（独立治理动作）；以及修改 Core Requirement/AC、locked contract、baseline、
  platform/integration profile 或 conformance/release 状态。HDC Scenario 明确要求之外的通用
  navigation、History、UI Dump/Trace/Debug/Flash UI 与 `REQ-I18N-001` 整体验收仍不在本任务。
- Allowed paths:
  - `Packages/ArkDeckKit/Sources/ArkDeckOpenHarmony/**`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/HDCServerLifecycleJournalAdapter.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/ArkDeckContractTests.swift`
    （仅迁移/收敛既有 `ProcessAndHDCContractTests` 与 `HDCServerSupervisorContractTests`
    cases）
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/HDCSupervisorContractTests.swift`
    （dedicated suite，可含多个 XCTestCase class）
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/HDCServer/**`
  - `Packages/ArkDeckKit/Tests/ArkDeckFakeHDCFixture/**`
  - `ArkDeckApp/App/ArkDeckApp.swift`（仅接入 HDC diagnostics/lifecycle surface）
  - `ArkDeckApp/Features/HDC/**`
  - `ArkDeckApp/Resources/Localizable.xcstrings`（仅新增本任务 HDC UI key，不认领
    `REQ-I18N-001`）
  - `ArkDeckAppUITests/HDC/**`
  - `ArkDeck.xcodeproj/project.pbxproj`（仅连接 ArkDeckOpenHarmony/Workflows products
    与注册 HDC UI-test target/files）
  - `ArkDeck.xcodeproj/xcshareddata/xcschemes/ArkDeck.xcscheme`（仅注册 HDC UI tests）
  - `Packages/ArkDeckKit/Package.swift`（仅注册/连接 dedicated fake-hdc fixture target，
    以及将 `ArkDeckWorkflows` 连接到 `ArkDeckOpenHarmony`/`ArkDeckStorage` 以提供
    production lifecycle journal/manifest adapter；Golden resource declaration 由 I5-001
    独占，本任务不得修改）
  - `openspec/changes/chg-2026-002-macos-m1-infrastructure/evidence/runs/TASK-M1-006/**`
  - `openspec/changes/chg-2026-002-macos-m1-infrastructure/tasks.md`（仅更新本任务状态与
    completion evidence）
- Forbidden paths:`openspec/specs/**`、`openspec/contracts/**`、`openspec/baselines/**`、
  `openspec/verification/**`、
  `openspec/platforms/**`、`openspec/integrations/**`、
  `Packages/ArkDeckKit/Sources/ArkDeckCore/**`、`.../ArkDeckProcess/**`、
  `.../ArkDeckRuntime/**`、`.../ArkDeckStorage/**`、除上述精确列出的
  `HDCServerLifecycleJournalAdapter.swift` 之外的 `.../ArkDeckWorkflows/**`、
  `Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/HDC/Golden/**`、
  上述清单以外的 App/UI tests/Tests/Fixtures、其他 task/change evidence 与其他
  Task 状态。
- Risk:high（host-wide supervisor 并发 contract + durable lifecycle audit/confirmation 接线 +
  安全阻断 UI + 真实本地 fake-hdc 子进程矩阵；验证
  仅使用仓库 fixture 可执行档、loopback ephemeral endpoint、临时目录与既有 audit 接口，
  无真实 hdc、设备、外联网络或 destructive side effect）
- Hardware required:no
- Required environment:macOS + 仓库声明的 Swift/Xcode toolchain；仅使用仓库内 fixture，
  不要求安装 HDC/DevEco、不下载依赖、不要求外部服务；测试不得执行已安装真实 `hdc`，
  fixture 网络仅限 loopback ephemeral port。锁定 CHG-005 合入后的
  `OPENHARMONY-TOOLS` successor profile version/SHA-256 与完整 Golden resource registry
  作为 run 输入；当前 0.1.0/空 registry 不满足执行门禁。
- Deliverables:接入 ProcessExecutor/`ProcessSemanticEvaluating` 的生产级 supervisor 与
  discovery/toolchain snapshot；endpoint 隔离解析器；授权工作流 + channel-protection 状态
  机；经 I5-001 建立的 `Bundle.module` resource contract 只读消费 approved/pinned
  HDC golden fixtures；dedicated fake-hdc
  fixture target 与全矩阵 contract suite；production lifecycle Session audit/manifest adapter 与
  restart/reopen durability tests；覆盖全部 user-visible HDC Scenario 的最小 macOS UI +
  XCUITest suite；带 `TEST-AC-HDC-*` 锚点的 dedicated tests；实现 PR 必须声明公开
  API 变更（若有）。
  自动 lifecycle/subserver 调用计数等证据输出必须是仪表化 hook 实测值而非分支常量
  （TASK-M1-010/004 准则）；若实现发现必须改变产品行为、安全语义或 locked contract，
  须停止并先修订 Task/设计或走独立 change。
- Verification:
  - `TEST-AC-HDC-001-01` / `toolchainContract`（contract）与 `TEST-AC-HDC-001-02` /
    `toolchainDiagnosticsContract`（platform）:Job intent 固定 path/hash/version/endpoint/
    generation，后续设置变化不影响该 Job；持久化诊断与 macOS XCUITest
    均显示全部字段或显式 unknown/unverified；纯 domain snapshot 测试不单独判定
    `AC-HDC-001-02` passed；
  - `TEST-AC-HDC-002-01` / `supervisorContract`（contract）:同 endpoint 两 recipient 对
    generation/健康变化各收到同一 host-wide 事件恰好一次，不误报单设备故障；
  - `TEST-AC-HDC-003-01` / `lifecycleCallCounter`（contract）与 `TEST-AC-HDC-003-02` /
    `ownershipEvidenceContract`（contract）:external server 探测/授权失败/版本不匹配下
    自动 stop 调用计数恒 0；macOS XCUITest 同时显示 ownership/generation/diagnostics 与
    仅经用户确认进入 lifecycle impact preview 的恢复选项；`arkDeckManaged` 仅凭启动证据建立；
  - `TEST-AC-HDC-004-01` / `endpointIsolationContract`（platform）:显式 endpoint 只进子
    进程 env，用户全局环境前后不变；
  - `TEST-AC-HDC-005-01` / `adapterGolden`（parserGolden）:测试只经 `Bundle.module` 读取
    registry-pinned golden，证明 exit 0 + 失败 marker 非 success 且 raw 可查；不得使用
    `#filePath`/checkout-relative fallback；
  - `TEST-AC-HDC-006-01` / `platformFileAccessContract`（platform）:key 不可访问时给出
    可诊断错误，macOS XCUITest 证明 UI 显示该错误；不删 key、不重置目录、
    不自动重启共享 server；
  - `TEST-AC-HDC-007-01` / `authorizationWorkflowContract`（contract）与
    `TEST-AC-HDC-007-02` / `authorizationFaultInjection`（contract）:信任完成迁移 ready
    且身份匹配时 Job 继续；拒绝/超时区分 denied/timedOut，macOS XCUITest
    显示对应结果与非破坏性重试路径，server lifecycle mutation 计数为 0；
  - `TEST-AC-HDC-008-01` / `securityStateContract`（contract）:已授权 TCP 无协商证据时
    domain 保持 channel protection unverified，macOS XCUITest 同时显示 authorized、
    protection unverified 与只在可信隔离网络使用的警告，不从授权/版本/env
    推断加密；
  - `TEST-AC-HDC-009-01` / `subserverCallCounter`（contract + macOS UI closure）:subserver
    能力只读探测，macOS XCUITest 显示 supported/unsupported/unknown capability 与只读语义，
    自动 spawn-sub/killall-sub 调用计数恒 0；
  - `TEST-AC-HDC-010-01` / `lifecycleCriticalGateContract`、`TEST-AC-HDC-010-02` /
    `lifecycleAuditContract`、`TEST-AC-HDC-010-03` / `lifecycleRaceFaultInjection`
    （contract + macOS UI/platform closure）:critical Step 阻断 dispatch 且计数 0，XCUITest
    显示阻断 Job、Step 与 safe-boundary recovery action；impact preview UI 展示 Core
    要求的全部字段后才能确认；dispatch 前重验证；preview/confirmation/
    intent/actual argv+endpoint/outcome/generation/affected Jobs 按同一 correlation durable
    持久化，关闭重开 store 后可复查，broadcast host-wide；generation/受影响 Job
    变化使确认失效并要求重新预览；内存 audit fake 不单独计为
    `AC-HDC-010-02` evidence；
  - `TEST-MAC-M1-HDC-001` / fake-hdc real-child-process supervisor matrix（platform）:
    汇总上述全部向量于真实子进程矩阵；external/unknown 自动 lifecycle 调用计数 0、
    ownership/generation 迁移精确、endpoint 隔离成立、global failure 恰好一次 fan-out；
  - Commands:`swift format lint <TASK-M1-006 changed Swift files>`；
    `swift test --package-path Packages/ArkDeckKit --filter HDCSupervisorContractTests`；
    `swift test --package-path Packages/ArkDeckKit`；
    `xcodebuild test -project ArkDeck.xcodeproj -scheme ArkDeck -destination 'platform=macOS'`；
    `scripts/check-sdd.sh`；
    `git diff --check`；静态检查确认无真实 `hdc` 执行路径、无用户全局环境写入、fixture
    无 host shell、lifecycle/subserver 计数为仪表化实测而非分支常量。
- Evidence gate:在 `evidence/runs/TASK-M1-006/run.md` 记录 base revision、环境、锁定
  baseline/conformance/spec/integration profile/change 输入 hash、全部命令与结果；逐向量
  记录 automatic lifecycle/subserver 调用、external/unknown recovery option 与 subserver
  capability UI assertion、fan-out、env 隔离、授权轮询与 generation/确认
  重验证 counters、durable audit 文件 hash/重开 replay 结果、manifest confirmation
  关联、actual argv/endpoint 与 macOS XCUITest 逐界面断言，并按 TASK-M1-010/004
  准则标注仪表化实测与结构性推导的分类边界；
  15 个 `TEST-AC-HDC-*` 与 `TEST-MAC-M1-HDC-001` 的二值结论、evidence class、偏差与遗留
  风险。缺任一项不得标记 `done`；本 evidence 不是真实硬件、platform conformance 或
  release claim，也不解除 `MAC-M0A-HDC-001` 的 blocked 状态。

## TASK-M1-007 — device binding revision、transport 重绑定边界与 per-device mutation lane

- Status:ready
- Requirements/AC:AC-DEV-001-01、AC-DEV-002-01 等
- Depends on:TASK-M1-006
- Allowed paths:`.../ArkDeckOpenHarmony/**`、`.../ArkDeckWorkflows/**`、对应 Tests、本 change `evidence/**`

## TASK-M1-008 — SimulatedFlashProvider 隔离 harness

- Status:ready
- Requirements/AC:AC-FLASH-006-01、MAC-M1-SIM-001
- Depends on:TASK-M1-003、TASK-M1-007
- Allowed paths:`.../ArkDeckWorkflows/**`、对应 Tests、本 change `evidence/**`
- Deliverables:可配置延迟/失败/断连/outcomeUnknown 的合成设备 provider;不接受真实 connectKey、不启动外部工具的隔离证明;simulated 证据永不进入硬件支持矩阵。

## TASK-M1-009 — 诊断骨架:分类脱敏日志与有界本地诊断导出

- Status:done
- Completion evidence:`evidence/runs/TASK-M1-009/run.md`(含四轮 remediation 记录与
  post-rebase addendum)。实现经四轮人类 review remediation(round 1-4 各 blocker 见下)
  与独立复审会话逐机制代码复核后,由维护者 `lvye` 经 PR #50 squash 合入 main
  `15697e85444fdacab81779a588c0e290c2f47125`(2026-07-18)——该 review/merge 即构成下方
  各 remediation gate 所要求的"维护者 re-review"。复验结果(rebase 到 `6c92aa5` 后):
  dedicated `DiagnosticsContractTests` 16/0、全量 188/0(1 项既有 opt-in 手动 sleep/wake
  skip)、`swift format lint --strict` 0 diagnostics、`check-sdd` 0 error、
  `git diff --check` 通过、生产文件静态无网络/进程扫描零命中;四个 Test ID
  (`TEST-AC-DIAG-001-01/02`、`TEST-AC-DIAG-002-01`、`TEST-MAC-M1-DIAG-001`)二值 PASS
  (`platform`)。M1-005 文件零修改(跨 deliverable 披露:无),`Package.swift` 未动,
  骨架无遥测、无任何自动上传路径。`ready→done` 由本独立状态 PR 执行,仅在维护者
  review/merge 后生效,不改变实现、evidence 正文或任何状态语义,不构成 change
  verified、完整 platform conformance、release claim 或真实设备 evidence。
- Review remediation(2026-07-18,round 4,已闭环):任务当时保持 `ready`;需将 writer lock 路径
  持续绑定到已加锁 inode，并以稳定目录 inode lock 阻止 lock-file replacement 后的第二
  writer；journal summary 必须与 manifest 的 Session/Job/executionMode 完全一致。
- Review remediation(2026-07-18,round 3,已闭环):任务当时保持 `ready`;需证明 rename 后名称
  `ENOENT` 时 staging inode 已解除链接，否则返回 `exportOutcomeUnknown`，并为预发布文件
  复验增加 non-blocking FIFO 拒绝向量；维护者 re-review 前不得起草 completion。
- Review remediation(2026-07-18,round 2,已闭环):任务当时保持 `ready`;需补齐写入点封闭
  catalog/opaque correlation、preview 父目录身份绑定、导出诊断语义保留、manifest 配额
  边界与 rename 后失败清理，并经复验和维护者 re-review 后方可另行起草 completion。
- Review remediation(2026-07-18,round 1,已闭环):implementation review 要求补齐不可伪造/
  导出边界二次脱敏、preview bytes 单次绑定、父目录 descriptor/inode 锚定和 owner-only
  权限向量;修复与复验完成前不得再次起草 `ready→done`。初始 run 只作为待 remediation 的
  执行记录,不构成 completion evidence。四轮 gate 均已由 PR #50 的维护者 review/merge
  闭环(见 Completion evidence)。
- Readiness review(2026-07-18,独立 readiness PR):
  - 依赖:`TASK-M1-001` done(typed vocabulary);`TASK-M1-004` done(`ArkDeckRuntime`
    平台端口惯例,main `9b58f2d`);`TASK-M1-005` done(实现 PR #37 main `9e1f1da`、
    状态 PR #38 main `0e7aa8e`:SessionDiagnosticExporter 脱敏引擎、manifest/journal 摘要
    来源与 claim 门控导出均已交付);
  - 验证输入:`AC-DIAG-001-01`、`AC-DIAG-001-02`、`AC-DIAG-002-01` 在 `scope.yaml`
    精确存在;`MAC-M1-DIAG-001` 在 canonical acceptance registry(`acceptance-cases.yaml`
    r3)与 `verification.md`(binding `REQ-DIAG-001`、`REQ-DIAG-002`、`PORT-LOGGING-001`,
    minimum evidence `platform`)一致;
  - 接口形状:`PORT-LOGGING-001` `SystemLogger` 端口在 `platform-ports.md` 定义为
    "有界、可脱敏、可导出的 App 自身诊断";本任务无 locked contract/schema 需要修改;
  - 环境:base main `0e7aa8e` 上 `swift build --package-path Packages/ArkDeckKit
    --build-tests` 通过;dedicated `DiagnosticsContractTests` 与 `Fixtures/Diagnostics/**`
    尚不存在,由实现按 allowed paths 新建;
  - 路径冲突:与 blocked 的 `TASK-M1-006`(ArkDeckOpenHarmony/App/HDC tests)与
    `TASK-I5-001/002`(integrations、`Fixtures/HDC/Golden/**`、`Package.swift`)无交集;
    本任务不得修改 `Package.swift`(Golden resource declaration 由 I5-001 独占;新源码
    文件无需 manifest 变更);M1-005 已 done,原"勿同时实现"约束解除,但本任务对
    `ArkDeckStorage/**` 原则上仅新增文件,修改 M1-005 已交付文件须按 M1-005 先例在
    run.md 作跨 deliverable 披露且不得改变其公开语义。
- Readiness gate:本 readiness PR 只扩写本任务条目为完整 task contract,不执行
  TASK-M1-009、不产生 implementation evidence,也不改变其他 Task 状态或任何 Core、
  contract、platform conformance、release claim;扩写后的 `ready` 仅在维护者 review/merge
  后生效。
- Objective:交付 App 自身诊断骨架——`PORT-LOGGING-001` `SystemLogger` 的 macOS
  production 实现(app/hdcServer/workflow/storage/ui 分类、写入时 redaction、correlation
  ID)、有界结构化诊断存储(配额内轮转/清理),以及仅由用户显式触发的本地诊断包
  导出(复用 M1-005 脱敏导出机制,默认排除设备 raw);骨架不含遥测,不存在任何自动
  上传路径。
- Requirements/AC:`REQ-DIAG-001`、`REQ-DIAG-002`;`AC-DIAG-001-01`、`AC-DIAG-001-02`、
  `AC-DIAG-002-01`;`MAC-M1-DIAG-001`(binding 含 `PORT-LOGGING-001`)。
- Depends on:
  - `TASK-M1-001`(done;typed vocabulary 与 correlation 语义)
  - `TASK-M1-004`(done;`ArkDeckRuntime` 平台端口惯例)
  - `TASK-M1-005`(done;脱敏导出引擎、manifest/journal 摘要来源与 Session layout)
- In scope:
  - `SystemLogger` production 端口:canonical 类别(app/hdcServer/workflow/storage/ui)+
    correlation ID;敏感值(设备标识、用户路径、业务字符串)在写入点按 redaction policy
    脱敏,原始敏感字符串不进入默认日志与诊断包;平台系统日志(Unified Logging)与
    结构化诊断文件双通道,后者为导出与测试断言的 durable 来源;
  - 有界结构化诊断存储:按配额轮转/清理,长期运行不无限增长;轮转不破坏正在写入的
    记录,torn-tail 语义与 Storage 既有模式一致;
  - 用户触发的本地诊断包导出骨架:app/build/platform 信息、脱敏后的 HDC/tool/server
    信息占位、最近 Job 的 journal/manifest 摘要、App 日志;设备 raw 默认排除;导出仅经
    显式 API 调用发生;
  - 无自动上传:crash/Job 失败路径不触发任何导出;骨架不引入任何网络 API。
- Out of scope:遥测/上传通道与 opt-in 机制;诊断 UI(M1-006 与后续 UX 任务);真实
  HDC/tool/server 信息采集(M1-006);修改 locked contract/schema 或 Core Requirement/AC;
  真实设备、网络、任何 device/destructive dispatch;改变 M1-005 已交付文件的公开语义。
- Allowed paths:
  - `Packages/ArkDeckKit/Sources/ArkDeckRuntime/**`
  - `Packages/ArkDeckKit/Sources/ArkDeckStorage/**`(原则上仅新增诊断骨架文件;修改
    既有文件须在 run.md 作跨 deliverable 披露)
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/DiagnosticsContractTests.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/Diagnostics/**`
  - `openspec/changes/chg-2026-002-macos-m1-infrastructure/evidence/runs/TASK-M1-009/**`
  - `openspec/changes/chg-2026-002-macos-m1-infrastructure/tasks.md`(仅更新本任务状态与
    completion evidence)
- Forbidden paths:`openspec/specs/**`、`openspec/contracts/**`、`openspec/baselines/**`、
  `openspec/platforms/**`、`openspec/integrations/**`、`openspec/verification/**`、
  `Packages/ArkDeckKit/Package.swift`、除 ArkDeckRuntime/ArkDeckStorage 外的所有 Sources、
  上述清单以外的 Tests/Fixtures、其他 task/change evidence 与其他 Task 状态。
- Risk:medium(本地文件轮转、redaction 与导出组合;全部验证使用临时目录与生成
  fixture,无设备、HDC、网络或 destructive side effect)
- Hardware required:no
- Deliverables:`SystemLogger` production port + 分类/脱敏/correlation 实现;有界结构化
  诊断存储与轮转;用户触发的诊断包导出骨架;dedicated `TEST-AC-DIAG-*` 与
  `TEST-MAC-M1-DIAG-001` tests;run evidence。
- Verification:
  - `TEST-AC-DIAG-001-01`:写入超过配额,断言轮转/清理发生、总量有界,长期运行不
    无限增长;
  - `TEST-AC-DIAG-001-02`:含设备标识/用户路径/业务字符串的事件经五类 logger 写入并
    导出,断言类别与 correlation ID 保留、敏感值按 policy 脱敏、原始敏感字符串不出现
    在默认日志与诊断包字节中;
  - `TEST-AC-DIAG-002-01`:模拟 crash/Job 失败路径,断言无导出发生且骨架无网络调用
    路径;导出仅在显式用户 API 调用后产生;
  - `TEST-MAC-M1-DIAG-001`:平台汇总——Unified Logging 类别接线、bounded rotation 与
    导出包默认排除设备 raw;
  - Commands:`swift format lint <TASK-M1-009 changed Swift files>`;
    `swift test --package-path Packages/ArkDeckKit --filter DiagnosticsContractTests`;
    `swift test --package-path Packages/ArkDeckKit`;`scripts/check-sdd.sh`;
    `git diff --check`。
- Evidence gate:run 记录 base revision、输入 hash、全部命令与结果、rotation 配额与实测
  字节、redaction 前后对照(脱敏值不含原文)、导出包 entry 清单与全部 4 个 Test ID 的
  二值结论;缺任一项不得标记 `done`;evidence 不包含真实 HDC/设备、platform
  conformance 或 release claim。

## TASK-M1-010 — M1 复审修复:证据计数、测试信号与语义词汇收敛

- Status:done
- Completion evidence:`evidence/runs/TASK-M1-010/run.md`，并已在
  `evidence/runs/TASK-M1-002/run.md` 原正文之后追加 evidence-integrity addendum；状态仅在
  维护者 review/merge 后生效，不构成 change verified、platform conformance、release claim 或
  真实硬件 evidence。
- Readiness gate:本任务范围与 `ready` 状态仅在维护者 review/merge 本 readiness PR 后
  生效；readiness PR 只修改本任务条目，不执行实现、不生成 evidence、不修改其他任务状态，
  也不改变 Core、contract、platform conformance 或 release claim。
- Objective:在不改变任何产品行为或验收 pass/fail 的前提下，修复 TASK-M1-002 证据表
  将测试回显字面量误写为运行期度量的问题，删除 M1-001 测试中的套套逻辑计数器，统一
  Process/HDC 第三态词汇，并收敛 M0A 与 M1-002 重复的 ProcessExecutor 测试。
- Requirements/AC:`REQ-WF-001`、`REQ-JOB-001`、`REQ-JOB-003`、`REQ-JOB-005`、
  `REQ-NFR-002`、`REQ-HDC-005`；仅回归既有 `AC-WF-001-01`、`AC-JOB-001-01`、
  `AC-JOB-001-05`、`AC-JOB-003-01`、`AC-JOB-005-01`、`AC-NFR-002-01` 与
  `AC-HDC-005-01`，不新增、修改或重新认领 AC。
- Depends on:`TASK-M1-001`、`TASK-M1-002`、`TASK-M1-003`（均 done）
- In scope:
  - 将 `ProcessExecutorContractTests` 的证据输出改为由本次测试实际观测的值生成，或删除
    不能由测试直接测量的回显；在 `TASK-M1-002/run.md` 原正文之后追加 addendum，明确
    区分原表中的测试回显与运行期实测值，并保留原记录正文不变；
  - 删除 `JobStateMachineTests` 与 `WorkflowStepContractTests` 中前置断言已证明不可达后
    又通过常量或重复 decode 构造的零计数装饰；保留直接验证状态、directive、错误类型与
    invariant violation 的有效断言；
  - 将公开 `ProcessSemanticResult` 第三态从 `indeterminate` 重命名为 `unknownOutput`，与
    `HDCCommandSemanticResult` 及 journal 的 `outcomeUnknown` 语义族收敛；只在
    `HDCSemanticOutputParser` 留下注释，声明 M1-006 将采用 `ProcessSemanticEvaluating`
    协议，本任务不提前执行 M1-006 接线；实现 PR 描述必须声明该公开 API 变更；
  - 删除 `ArkDeckContractTests.swift` 中由 M0A 遗留、已被 M1-002 dedicated suite 重复覆盖
    的六个 `testProcessExecutor*` prototype cases；为 `ProcessExecutorContractTests` 测试名
    增加 canonical `TEST-AC-*` 锚点。
- Out of scope:ProcessExecutor、Job 状态机、WorkflowStep decoder 或 HDC parser 的行为变化；
  M1-006 HDC supervisor/parser 接线；新增 parser family/fixture；Core Requirement/AC、schema、
  contract、baseline、platform/integration profile、conformance/release 状态；真实设备、网络或
  任何 destructive/device dispatch。
- Allowed paths:
  - `Packages/ArkDeckKit/Sources/ArkDeckProcess/ArkDeckProcess.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckOpenHarmony/ArkDeckOpenHarmony.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckCoreTests/JobStateMachineTests.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckCoreTests/WorkflowStepContractTests.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/ArkDeckContractTests.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/ProcessExecutorContractTests.swift`
  - `openspec/changes/chg-2026-002-macos-m1-infrastructure/evidence/runs/TASK-M1-002/run.md`
    （仅在原正文之后追加 evidence-integrity addendum）
  - `openspec/changes/chg-2026-002-macos-m1-infrastructure/evidence/runs/TASK-M1-010/**`
  - `openspec/changes/chg-2026-002-macos-m1-infrastructure/tasks.md`（仅更新本任务状态与
    completion evidence）
- Forbidden paths:`openspec/specs/**`、`openspec/contracts/**`、`openspec/baselines/**`、
  `openspec/platforms/**`、`openspec/integrations/**`、上述清单以外的源码、测试与 evidence。
- Risk:medium（公开 Swift enum case 重命名 + contract test/evidence 修复；验证仅使用本地
  child process、临时目录和生成 fixture，无 HDC、网络、设备或 destructive side effect）
- Hardware required:no
- Required environment:macOS + 仓库声明的 Swift/Xcode toolchain；仅使用仓库内 fixture 与
  系统只读 process 工具，不下载依赖、不要求外部服务。
- Deliverables:运行期生成或删除的 Process 计数回显；不改写历史正文的 evidence addendum；
  删除套套逻辑与重复 M0A process cases；带 AC 锚点的 dedicated process tests；统一的
  `unknownOutput` API 及 M1-006 migration comment；实现 PR 的公开 API 变更声明。
- Verification:`swift format lint` 全部变更 Swift 文件；
  `swift test --package-path Packages/ArkDeckKit --filter ProcessExecutorContractTests`；
  `swift test --package-path Packages/ArkDeckKit`；`scripts/check-sdd.sh`；`git diff --check`；
  静态检查确认原型 `testProcessExecutor*`、`.indeterminate` 及指定常量/不可达计数器均已清除。
- Evidence gate:在 `evidence/runs/TASK-M1-010/run.md` 记录 base revision、环境、命令与结果、
  回显/实测分类、测试数变化、API rename 与 migration boundary、关联 AC 的回归结论、evidence
  class、偏差和遗留风险；同时在 `TASK-M1-002/run.md` 原正文之后追加 addendum。缺任一项不得
  标记 `done`。
