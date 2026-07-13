---
id: CHG-2026-002-macos-m1-infrastructure
revision: 1
status: proposed
supersedes_change_id: null
supersession_barrier_attestation_id: null
class: platform
schema: arkdeck-platform
core_change_level: none
owner: pending-human-owner
core_baseline: CORE-1.0.0
platforms: [macos]
---

# Implement the macOS M1 shared infrastructure

## Why

M0A 只交付可行性原型与分发决策。所有分阶段功能（UI Dump、Trace、Debug、Flash）都建立在同一批共享基础设施上：typed workflow/Job 状态机、write-ahead journal 与 reconcile、ProcessExecutor、macOS runtime ports、Session/Artifact store、host-volume 协调、HDC server supervisor、device binding 与 simulation/diagnostics skeleton。这些必须先按既有 Core baseline 实现并通过 contract/platform 证据，功能阶段才有可复用的安全地基。

## What changes

### In scope

- 按 CORE-1.0.0 实现五个 foundation capability 的 host 侧可验行为：workflow-journal-recovery、session-artifact-storage、toolchain-hdc-server（fake-hdc 矩阵）、device-targeting-auth（binding/lanes）与 desktop-ux-observability 的 diagnostics 子集；
- 实现全部 M1 runtime/storage/logging/clock platform ports 并通过 Port contract tests；
- 实现 `SimulatedFlashProvider` 隔离 harness（REQ-FLASH-006）；
- 交付 crash-window、ENOSPC、fake-hdc、单实例与 clock 语义的 fault-injection/contract 证据。

### Out of scope

- 任何真实设备/真机证据（REQ-DEV-007、REQ-HDC 真机授权 UX 等 parserGolden/realHardware 留给后续 change 与受控 lab task）；
- UI Dump/Trace/Debug/Flash 功能工作流与其 UI；
- desktop-ux-observability 的导航/History/i18n（REQ-UX-*、REQ-I18N-001）；
- 修改任何 Core Requirement/AC/contract；
- 宣称任何 capability 达到可发布状态——发布范围由 release subject 的 `includedCapabilities` 另行声明。

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
- 诊断与日志按 privacy redaction 落地,导出默认不含设备 raw。

## Approval

- Human decision：pending
- Approved revision：—
