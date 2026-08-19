---
id: CHG-2026-065-retire-maskrom-rescue-component
revision: 1
status: proposed
class: integration
core_change_level: none
owner: fuhanfeng
core_baseline: CORE-3.0.0
platforms: [macos]
---

# CHG-2026-065 — 退役 Maskrom 救援组件：App 不再携带 rkdeveloptool

> **本文件不构成批准。** 本 proposal 经维护者 review/merge 进 protected
> `main` 后，各 Task 方可开始实现 PR；merge 同时构成对 DEC-011 outcome 与
> TASK-NRU-004 交付内容第 4 条「救援保留」半句的正式取代（维护者
> 2026-08-19 决定：救援组件整体退役）。

## 目标

把 CHG-2026-063（NRU-004）退役后仅存的「operator 手动 Maskrom 救援」
`rkdeveloptool` 从产品与工程面整体移除。终态：

- `ArkDeck.app` 不再嵌入 `rkdeveloptool` 二进制与
  `Resources/RockchipComponent/**` 元数据（pbxproj 两个 Embed 相位删除）；
- 构建它的流水线退役：`.github/workflows/rockchip-component.yml`、
  `scripts/rockchip_component/**`、`openspec/integrations/rockchip/
  bundled-component/**` 删除（`manual_ui_flash.swift` 与该组件无关，
  迁至 `scripts/manual_ui_flash/`）；
- `swift-ci` 与本地计划器不再传 `ROCKCHIP_COMPONENT_INPUT`；
- 守卫测试反转：全源码 `rkdeveloptool` tripwire **保留**，
  「pbxproj 必须含 Embed 相位」的断言改为「必须不含」；
- 发布 tuple 相应缩为单 App（GPL source-offer/SBOM/notice 义务随二进制
  停止分发而卸除——义务跟随分发，见 `docs/release/
  rockchip-component-distribution.md` 自身的义务条款）。

## 为什么可以退役救援件

1. **恢复通道不是 Maskrom。** 2026-07 的恢复演练已实证：DAYU200 的
   Maskrom 按键路径 `db` 建链即失败（#173/#218/#220），实际可行的恢复
   通道是 **Loader 态整分区重写**——正是 `arkforged` 原生 lane 拥有的
   路径（enter-loader / write-partition / reset-device）。救援件针对的
   场景在这块板上从未成立过。
2. **原生面已两次真机全量通过。** 2026-08-18 首过
   （`EVD-AFA-DAYU200-20260818-001`）与 2026-08-19 vendor 移除后复验
   （`EVD-NRU-DAYU200-20260819-001`，chg-2026-063 evidence），
   readback 证据同形；恢复用的 rebind/verify 也在 lane 内。
3. **保留的成本是真实的**：每次 push main 跑一条组件构建 workflow、
   Debug/CI 把 `/usr/bin/false` 伪装成 `rkdeveloptool` 嵌进包、release
   tuple 多一个二进制 + 五份元数据 + GPL 义务面，而 agentd 对它
   零解析/零启动/零信任（NRU-004 边界）——纯负债。

## 取代与保留

- **取代**：DEC-011 `selected:bundledRockchipComponent` 的 outcome
  （open-questions 已注记）；ADR-0003 与 `docs/release/rockchip-component-*`
  的「救援保留」横幅（改为「已退役」）；TASK-NRU-004 交付内容第 4 条
  后半句；CHG-2026-036 已封存的 release tuple（其 evidence 保持原样，
  历史不改写）。
- **保留**：RockUSB 字节文法的上游 pin（ArkForge
  `rockusb_protocol.rs` 钉 `rockchip-linux/rkdeveloptool@304f0737…`）——
  协议知识出处，不含二进制；`SessionManifest.swift` 的 legacy 解码常量
  （读历史 manifest 的迁移垫片）；全源码 `rkdeveloptool` tripwire。
- **回退路径**：若未来出现真实的 Maskrom-only 场景，另立 change 携证据
  重新引入——被删流水线与密闭配方全部在 git 历史与上游 pin 里，
  不失可复现性。

## 影响面

`ArkDeck.xcodeproj`、`ArkDeckApp/RockchipComponent.entitlements`、
`.github/workflows/{rockchip-component,swift-ci}.yml`、`scripts/ci/plan.py`、
`scripts/test_agent_pr_workflow.py`、`scripts/rockchip_component/**`、
`openspec/integrations/rockchip/**`、`Packages/ArkDeckKit/Tests/**` 守卫、
`docs/adr/0003`、`docs/release/**`、`.gitignore`。零 Core delta，
零 Catalog delta，`flash.dayu200` 行为不变（产品路径本就零引用）。

顺带（TASK-RRC-002）：清理 NRU 后确认死亡的 vendor 时代代码
（`RockchipFlashExecutionStaging` 的 tar 展开、`RuntimeJobEngine` 为它
预留的容量门、无调用方的 `RockchipProductExecutePlanFactPort`）与两处
误导命名（`RockchipFlashExecutionHost` 不执行 flash、
`RockchipFlashSessionReconcile` reconcile 的宿主已不存在）。
两份分区表/两个计划模型的归一**不在本 change 范围**（需单独设计）。
