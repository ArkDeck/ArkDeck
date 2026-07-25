---
id: CHG-2026-036-macos-bundled-rockchip-component
revision: 1
status: proposed # 本 proposal PR 只登记 change；approval/readiness/implementation/evidence/status/verification 均须后续独立 PR
class: platform
core_change_level: none
owner: lvye
core_baseline: CORE-2.1.0
platforms: [macos]
---

# macOS bundled Rockchip component 供应链、签名与产品接线

## Why

ADR-0003 已由 CHG-2026-035 选择
`selected:bundledRockchipComponent`：ArkDeck 应把 source-pinned
`rkdeveloptool` 作为 App-owned nested component 放入同一个 signed/notarized App
bundle，由 Sandboxed App 直接作为 child process 启动。CHG-2026-035 verification
与 archive 已分别由 PR #533/#534 合入；archive merge OID 为
`5fc517f7ecfccd61ed0d140f9080e4b49e2cad95`。

该 ADR 同时明确：选定架构不等于可实现或可分发。当前仓库仍缺少 upstream source 与
build recipe 的可复现闭包、GPL-2.0 distribution 决策、libusb/libiconv dependency
闭包与 SBOM、nested code 的 inside-out 签名/公证规则、product-owned component
descriptor 与 file lease 接线，以及 signed Sandbox/clean-host evidence。当前
`RockchipFlashExecutionHost` 仍读取用户选择的 external tool bookmark；把它直接替换成
bundle 路径会绕过上述判断门，并可能把“App 能找到 child”误报成“child 能访问文件/
RockUSB/设备”。

本 change 把 ADR-0003 的七项 handoff 收敛为六个顺序任务。在不改变 Core、HDC
external-first 决策或 CHG-2026-026 状态的前提下，先闭合发布责任，再构建、打包、
接线并逐层取证；任一门失败都保持 execute fail closed。

## What changes

### In scope

- 记录维护者接受的 Rockchip component source/license/dependency/distribution
  envelope：exact upstream commit、source acquisition、builder/toolchain、minimum
  macOS、architectures、GPL-2.0 notices/corresponding-source 机制、dependency
  licensing、SBOM/CVE owner、update/rollback owner 与 release retention。
- 建立 hermetic/reproducible unsigned component build、versioned bundled-component
  registry、dependency lock 与 reviewable SBOM；禁止 Homebrew、PATH、host ambient
  headers/libraries 或 unpinned network input 进入 release artifact。
- 把 component 置于固定 App bundle location，固定 identifier、minimum OS、
  architectures、exact two-entitlement child profile
  (`app-sandbox=true`、`inherit=true`)，并闭合 inside-out Developer ID signing、
  Hardened Runtime、notarization 与 stapling 验证。
- 新增 product-owned bundled component descriptor/identity seam；把 production
  composition 从 caller/user-selected executable 迁移为 bundle-owned identity，
  只允许 typed argv、bounded stdout/stderr、semantic result、durable
  intent/outcome，以及显式 image/key/output/cancel/timeout/crash/reconcile lease。
- 分阶段取得 contract/fake、signed Sandbox E0、file-access、RockUSB read-only 与
  clean-host/VM Developer ID/notarized DMG/update/rollback evidence；每类证据如实
  分类，不能互相替代。
- 完成后只形成“bundled component platform prerequisite 已验证”的 handoff；
  CHG-2026-026 的 scope/readiness/UI/真实 flash acceptance 必须在后续独立 revision
  中处理。

### Out of scope

- 本 proposal PR 不下载、vendor、build、sign、notarize、launch 或运行任何
  component，不访问网络、USB、设备或用户文件，不生成实现/evidence。
- 不批准 GPL-2.0 或 dependency distribution 条款，不替维护者/legal 作接受判断；
  `TASK-BRC-001` 必须以独立 D1 decision/evidence PR 记录接受或 blocked 结论。
- 不修改 Core Requirement/AC、locked contract/schema、Flash Provider/Profile、
  hardware support matrix、standing authorization 或 CHG-2026-026 的任何文件/
  task 状态。
- 不捆绑 HDC，不改变 DEC-007 的 HDC external-first；不增加 helper、XPC、daemon、
  login item、installer、privilege escalation、system rule/group/ACL 或额外 App
  entitlement。
- 不提供 external tool、文件选择器、PATH、shell、download、copy、symlink/alias、
  re-sign unknown binary、去 quarantine 或非 Sandbox fallback。
- 不执行 RockUSB mutation、Loader transition、write/reset、E1/E2 或 destructive
  acceptance；真实刷机仍由 CHG-2026-026 的后续独立门负责。

### Observable behavior before/after

- Before：仓库只有已批准的 bundled-component 架构与 external-bookmark 旧实现；
  没有可发布的 bundled Rockchip component，也没有其 signed Sandbox/clean-host
  evidence。
- After（仅当六个任务和 change verification 后续全部通过）：signed/notarized App
  可从 product-owned 固定身份定位并启动 source-pinned Rockchip component，
  supply-chain、nested signature、typed composition、E0/file-access 与 distribution
  evidence 可复查；Flash UI/真实 destructive dispatch 仍未因此启用。

## Scope（涉及的 Requirement/AC）

- Requirements：`REQ-FLASH-001`、`REQ-FLASH-004`、`REQ-FLASH-005`、
  `REQ-FLASH-008`、`REQ-FLASH-012`、`REQ-FLASH-013`、`REQ-FLASH-015`、
  `REQ-JOB-002`、`REQ-JOB-003`、`REQ-JOB-005`、`REQ-JOB-006`、
  `REQ-UX-007`
- Canonical Acceptance：`AC-FLASH-001-01`、`AC-FLASH-005-01`、
  `AC-FLASH-008-01`、`AC-FLASH-012-01`、`AC-FLASH-013-01`、
  `AC-FLASH-015-01`、`AC-JOB-002-01`、`AC-JOB-003-01`、
  `AC-JOB-005-01`、`AC-JOB-006-01`、`AC-UX-007-01`
- Change-local Acceptance：`BRC-SUPPLY-001`、`BRC-REPRO-001`、
  `BRC-PACKAGE-001`、`BRC-COMPOSITION-001`、`BRC-SANDBOX-E0-001`、
  `BRC-DISTRIBUTION-001`、`BRC-HANDOFF-001`
- Contracts/schemas：零 locked Core contract/schema 修改；新增 versioned
  Rockchip bundled-component integration registry 与 SBOM/build receipts
- 是否需要 Core baseline bump：否；`spec-impact.md` 记录 no-op Core delta

## Safety, privacy, and compatibility

- 所有 production 路径必须是
  `ArkDeckApp composition root → RockchipFlashApplicationFacade /
  RockchipFlashExecutionHost → typed plan + binding →
  RockchipFlashAuthorizationGate → product-owned bundled descriptor →
  FoundationRockchipExecutionProcessPort → FoundationProcessExecutor →
  RockUSB effect → durable intent/outcome`。调用方不得提交 executable URL/hash、
  raw argv/environment、component receipt 或 authority bytes。
- Build 与 runtime identity 必须分别验证；source pin、build receipt、bundle registry、
  code signature、runtime hash/version 任一不一致都 fail closed，不能选择 external
  fallback。
- signed Sandbox E0 只允许 version/`ld` 与封闭只读观察；file-access 验证与 RockUSB
  观察分栏计数。E0 不产生 mutation/destructive authority，也不能证明真实 Flash。
- image/key/output lease、partial output、timeout、cancel、child crash、App crash、
  restart 与 reconciliation 必须有 typed verdict；unknown effect 保持
  `waitingForRecovery`，不得自动 replay。
- Evidence 不入仓 bookmark bytes、用户绝对路径、raw Sandbox log、credential、
  Developer ID/notarization secret、设备 identifier、未审计 binary 或用户 image/key
  内容。只保存 sanitized metadata、digest 与可复查 release receipt。
- Rollback 必须能恢复到 execute-disabled 状态，并移除 bundled production
  reachability；不得在 rollback 时回退到 external executable。Windows/Linux 仍为
  not started，不形成对应平台支持声明。

## Approval and flow

本 proposal PR 只登记七个 change-local AC、六个 `blocked` 任务及其顺序门。正式
批准必须由独立 approval-only PR 完成；approval 不构成 GPL/dependency distribution
接受，不使任何任务 `ready`，也不授权 source download/build、sign/notarize、
process/USB/device 或 E1/E2。

批准后仅 `TASK-BRC-001` 可进入独立 D1 readiness。每个后继任务都必须等待依赖任务
的 done merge，并由自己的 readiness PR 固定 exact inputs、allowed paths、环境、
验证命令、operator/credential 边界与 effect budget。判断门之后零投机堆叠；每个
implementation/evidence PR 合入后再使用独立 D0 status PR。

只有六个任务全部 done 且 verification closure 合入，才可另开 CHG-2026-026
revision/readiness。该后续 change 仍须单独决定 UI 与真实 destructive acceptance；
本 change 的 proposal、approval 或实现 evidence 均不授权一键刷机。
