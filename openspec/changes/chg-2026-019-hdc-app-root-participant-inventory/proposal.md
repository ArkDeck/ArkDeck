---
id: CHG-2026-019-hdc-app-root-participant-inventory
revision: 1
status: proposed
class: implementation-only
core_change_level: none
owner: lvye
core_baseline: CORE-2.0.0
platforms: [macos]
---

# Production App-root participant/critical-state inventory feed(M1-006 缺口 ① 的处置载体)

## Why

TASK-M1-006 closeout(PR #191/#192,`run.md` addendum 23)认定的缺口 ① 原文:
"`HDCProductionApplicationDiagnostics` still supplies an unavailable App-root participant and
critical-state inventory. This safely blocks lifecycle mutation, but it is not a production
participant feed and cannot demonstrate the real App-root critical gate."

合入版现状:`HDCApplicationDiagnosticsHost.compose` 的类型入口已强制要求
`impactInventory: HDCApplicationHostImpactInventory`(`.complete([participant])` 或
`.unavailable(reason)`),Supervisor 需要 endpoint-identity 与 participant-impact 两类显式
reliability receipt 才可能出 impact preview;而 production facade
(`HDCApplicationDiagnosticsFacade.swift:160`)只能诚实地喂 `.unavailable` ——因为 App 没有
任何架构面能证明「这就是全部 participant」。结果:production lifecycle mutation 永久
unavailable,`MAC-M1-HDC-001` 所需的真实 App-root critical gate 无法演示,TASK-M1-006 无法
`done`,CHG-2026-002 无法 verify。

关键事实:当前 M1 产品面里 App 没有任何创建 HDC-lifecycle-相关 Job/DeviceCoordinator 的
功能入口(Flash/Dump 等均未接线 UI)。所以缺的不是「枚举现有 participant」,而是
「App-root 对 participant 创建权的架构性独占」——只要 Job/recipient 只能经 App-root 的单一
registry 产生,registry 的枚举就**构造性完备**,现阶段可诚实喂 `.complete([])`(空但完备),
未来功能接线后自动携带真实 participant 与 critical state。

## What changes

### In scope

- `TASK-PI-001`:在 `ArkDeckWorkflows` 交付 App-root participant registry:
  - 单一 root registry 类型,是 App 进程内向 host Supervisor 注册 lifecycle-相关
    Job/DeviceCoordinator recipient 与 critical-state 更新的唯一 production 入口;绕过
    registry 的注册路径对 App 不可达(类型/可见性封闭,contract 测试证明);
  - production facade 改为经 registry 喂 `HDCApplicationDiagnosticsHost.compose`:registry
    健康时 `.complete(registry.participants)`(当前产品态 = 空但构造性完备),registry
    不可用/不一致时保持 `.unavailable` fail-closed;
  - 既有 fail-closed 语义零放宽:duplicate/跨 endpoint participant 仍拒;两类 reliability
    receipt 仍缺一不可;`@_spi(Testing)` 遗留入口不扩大;
  - contract 测试:构造性完备(registry 外无注册路径)、空-完备 inventory 使 participant
    reliability 为 true、注入 critical Flash Job 时 preview 显示且 dispatch 阻断计数 0、
    duplicate/mismatch 仍 fail-closed;
  - signed Sandbox XCUITest:production 启动(非 fixture)下 inventory-unavailable 文案消失,
    lifecycle recovery 的 unavailable 理由收敛为 server-identity/endpoint 前置(对
    `/usr/bin/true` 候选仍 fail-closed),证明 participant 门由真实 feed 满足而非绕过。
- 完成后效果:addendum 23 缺口 ① 关闭。配合 CHG-2026-018(缺口 ②③)落地后,TASK-M1-006
  可另行起草 done/closeout 修订(独立状态 PR),随后 CHG-2026-002 verify。

### Out of scope / Non-goals

- 不修改 Core Requirement/AC/contract/schema(class implementation-only,零 Core 变更);
- 不触碰 `ArkDeckOpenHarmony`/`ArkDeckCore`/`ArkDeckProcess`/`ArkDeckStorage` Sources
  (Supervisor/host 的既有 package API 已足够);
- 不改 readonly-probes registry/integration/platform profile/lock;
- 不做 Flash/Dump 等功能的 UI 接线(未来 change 各自经 registry 注册即可);
- 不翻转 TASK-M1-006 状态、不构成 CHG-2026-002 verified、platform conformance、
  hardware/support 或 release claim。

## Approval and flow

V2 治理:本 propose PR 合入仅登记提案;批准须独立 approval-only PR;`TASK-PI-001` 在
approve + readiness 双前置满足前保持 `blocked`。实现须 signed Sandbox XCUITest 环境
(先例 M1-006:DevMode 已启用,解锁态执行)。
