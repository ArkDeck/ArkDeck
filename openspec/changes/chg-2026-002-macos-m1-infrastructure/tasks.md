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

- Status:ready
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
- Requirements/AC:AC-JOB-002-01、AC-JOB-006-01 等
- Depends on:TASK-M1-001
- Allowed paths:`.../ArkDeckStorage/**`、`.../ArkDeckWorkflows/**`、对应 Tests、本 change `evidence/**`
- Deliverables:append-only intent/outcome journal、原子 snapshot 替换、torn-tail 检测;intent-without-outcome → outcomeUnknown 且永不重放 destructive;审计化放弃与设备 hazard 保留。

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
