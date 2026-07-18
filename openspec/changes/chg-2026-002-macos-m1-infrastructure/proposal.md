---
id: CHG-2026-002-macos-m1-infrastructure
status: approved # r1-r4 已批准；r5 legacy-contract safety-alignment amendment 仅在对应 PR 合入后生效
class: platform
core_change_level: none
owner: lvye
core_baseline: CORE-2.0.0
platforms: [macos]
---

# Implement the macOS M1 shared infrastructure

## Why

M0A 只交付可行性原型与分发决策。所有分阶段功能（UI Dump、Trace、Debug、Flash）都建立在同一批共享基础设施上：typed workflow/Job 状态机、write-ahead journal 与 reconcile、ProcessExecutor、macOS runtime ports、Session/Artifact store、host-volume 协调、HDC server supervisor、device binding 与 simulation/diagnostics skeleton。这些必须先按既有 Core baseline 实现并通过 contract/platform 证据，功能阶段才有可复用的安全地基。

## What changes

### In scope

- 按 CORE-2.0.0 实现五个 foundation capability 的 host 侧可验行为：workflow-journal-recovery、session-artifact-storage、toolchain-hdc-server（fake-hdc 矩阵）、device-targeting-auth（binding/lanes）与 desktop-ux-observability 的 diagnostics 子集；
- 为本 change 已认领且 Scenario 明文要求 UI 结果的 HDC AC 交付最小 macOS
  diagnostics/safety presentation：toolchain/authorization/channel diagnostics、external/unknown
  server 的确认式恢复入口、subserver capability 只读展示、critical gate 与 lifecycle impact
  preview；该 surface 只消费 use-case state，不扩展到任何产品功能工作流；
- 收拢 M1-006 的 toolchain execution boundary：Core 持有 durable Job toolchain intent，
  Process 以原子 launch gate 将已核验 descriptor/inode 与实际执行绑定，Workflows 封闭组合
  Core typed Step、OpenHarmony Adapter、durable executor/outcome/finalizer，App 只依赖 Core 与
  Workflows 的 use-case/presentation API；
- 只读消费 verified OpenHarmony integration profile 已登记的 identity、authorization、
  server-health/version 与 subserver capability probe，并在 macOS platform profile 精确映射
  其平台 access/diagnostics；以实际签名的 Sandbox test build + XCUITest 闭合 UI/权限诊断；
  该路径只使用仓库 fake fixture，不是 v1 分发路径；
- 实现全部 M1 runtime/storage/logging/clock platform ports 并通过 Port contract tests；
- 实现 `SimulatedFlashProvider` 隔离 harness（REQ-FLASH-006）；
- 交付 crash-window、ENOSPC、fake-hdc、单实例与 clock 语义的 fault-injection/contract 证据。

### Out of scope

- 任何真实设备/真机证据（realHardware 一律留给后续由人类执行的硬件任务）；
  HDC parser/probe 只读消费经 approved integration change version/hash-pinned 的
  output family，M1-006 不得自行生成 golden 后给自己判 pass；
- UI Dump/Trace/Debug/Flash 功能工作流与其 UI，以及 HDC Scenario 明文要求之外的
  通用功能 UI；
- desktop-ux-observability 的导航/History/i18n（REQ-UX-*、REQ-I18N-001）；
- 修改任何 Core Requirement/AC/contract；
- 变更 ADR-0001 选定的非 Sandbox v1 分发路径，或把签名 Sandbox/XCUITest 证据解释为
  Developer ID、公证、真机、platform conformance 或 release evidence；
- 宣称任何 capability 达到可发布状态——发布范围在 M5 release change 中另行声明。

## Impacted specifications

- Core behavior：none
- Platform profile：`openspec/platforms/macos/profile.md`
- Verification：`openspec/platforms/macos/verification.md` 与本 change 的 verification plan
- Baseline bump：no

## Safety, privacy, and compatibility

- 全部 Task 运行在 `standardAgent` 环境,`hardwareRequirement: none`;不接触真实设备,fake hdc 是仓库内可执行 fixture;
- Supervisor 实现继承「不自动 kill external/unknown server」并以 call-counter 证明;
- SimulatedFlashProvider 不接受真实 connectKey、不启动外部工具,其证据永久分类为 simulated;
- journal/reconcile 在 destructive outcomeUnknown 上 fail closed,不自动重放;
- tool path/hash/identity 与实际启动对象不一致时 child launch count 为 0；App、UI 与 profile
  均不能绕过 Core typed Step 和 durable intent/outcome/finalization 链；
- 诊断与日志按 privacy redaction 落地,导出默认不含设备 raw。

## Approval

- Initial approval：维护者 `lvye` review 并合入 PR #14，merge commit
  `df9e088`，r1 的 `status: approved` 由此生效。
- r2 retarget：PR #21 已将 CHG-2026-004 archive 并 ratify
  `CORE-2.0.0`（merge commit `7e3998c`）。本修订将实现目标改钉
  `CORE-2.0.0`，把 `AC-JOB-001-07` 加入精确 scope，并解除
  `TASK-M1-001` 的旧 authority-conflict blocker。
- r2 approval：上述 retarget 已由维护者 review 并经 PR #22 合入，merge commit
  `eb9b9dc64ab422a51a518066f70b728e9ff5ba24`；r2 scope/task state 已生效，且该 PR
  未执行 `TASK-M1-001`、未产生实现 evidence、未改变 macOS
  `conformance_status: notStarted`。
- r3 HDC readiness/design amendment：将 HDC AC 明文要求的最小 UI 从原 design 的
  blanket UI non-goal 中精确移入 scope，补齐 M1-005 durable audit/manifest seam 的任务
  contract，并把 M1-006 使用的全部 semantic output family 置于 approved/pinned fixture
  gate 后；已由维护者 review 并经 PR #35 合入，merge commit
  `11eb5cbe69bc9089fd870d6397f698f4c93dd299`。
- r4 execution-boundary amendment：只修订 M1-006 的 scope、allowed/forbidden paths、模块与
  Task 依赖和相应验证门禁；不修改任何源码、profile、Core/AC/contract、任务状态、platform
  conformance、ADR 或 release claim；已由维护者 review 并经 main `87a3a99` 合入生效。
- r5 legacy-contract safety-alignment amendment：只解除 r4“不得改写既有 cases”与 required
  full-suite gate 的两个精确冲突，授权两个具名 legacy HDC case 及其直接 private helper/import
  按 r4 已批准的 live-process ownership evidence 与 terminal reconciliation 语义对齐；不改变
  Core/AC/contract、产品实现范围、任务状态或任何其他既有 case。r5 仅在维护者 review/merge
  后生效，不能由本草案自行产生实现授权。
