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

- Status:ready
- Requirements/AC:AC-ART-001-01、AC-ART-002-01、AC-STO-* 等
- Depends on:TASK-M1-001、TASK-M1-003
- Allowed paths:`.../ArkDeckStorage/**`、对应 Tests、本 change `evidence/**`

## TASK-M1-006 — HDC supervisor、endpoint 隔离、授权工作流与 fake-hdc 对抗

- Status:ready
- Requirements/AC:AC-HDC-001-01/02、AC-HDC-005-01(parserGolden,fixture 在本 change 落地)等
- Depends on:TASK-M1-002、TASK-M1-003
- Allowed paths:`.../ArkDeckOpenHarmony/**`、对应 Tests 与 Fixtures、本 change `evidence/**`

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

- Status:ready
- Requirements/AC:AC-DIAG-001-01/02 等
- Depends on:TASK-M1-001
- Allowed paths:`.../ArkDeckRuntime/**`、`.../ArkDeckStorage/**`、对应 Tests、本 change `evidence/**`

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
