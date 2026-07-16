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

- Status:ready
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

- Status:ready
- Requirements/AC:AC-JOB-008-01、AC-NFR-001-01 等
- Depends on:TASK-M1-001
- Allowed paths:`.../ArkDeckRuntime/**`、对应 Tests、本 change `evidence/**`

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
