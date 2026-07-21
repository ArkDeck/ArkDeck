---
id: CHG-2026-001-macos-m0a
status: archived # 2026-07-21 archive PR(先例 #178/#235/#241/#242;引用面收口:唯一活跃路径引用 = ADR-0001 一处 evidence 指针,同 PR 更新为 archive 路径;docs/reviews 历史快照与 archived CHG-017 字节内引用不改写,断链接受并记录,先例 #211;M0A 移交的 TRUST/SANDBOX 等 blocked 行已随 M1/CHG-018 各自处置)。原注: 2026-07-15 M0A 收官:矩阵 5 passed/8 blocked,阻断经 PR #10/#12 维护者接受,verification gate 的"显式 platform blocker 被接受"条款满足;汇总见 evidence/runs/TASK-M0A-006/rollup.md;经本 PR 合并确认
class: platform
core_change_level: none
owner: lvye
core_baseline: CORE-1.0.0
platforms: [macos]
---

# Establish the macOS M0A feasibility baseline

## Why

ArkDeck 尚无 Xcode 工程或运行代码。外部 HDC、共享 server、App Sandbox、Gatekeeper/quarantine、USB/UART、持久文件访问、单实例和电源保持是开始功能开发前必须验证的平台风险。

## What changes

### In scope

- 建立最小 SwiftUI/App shell 和 ArkDeckKit package boundaries；
- 建立可测试 ProcessExecutor/HDC discovery/supervisor prototype；
- 验证 single-instance、journal durable write、power activity；
- 在干净 VM/实机执行 Sandbox/Gatekeeper/external HDC matrix；
- 产出 distribution decision record。

### Out of scope

- 实现完整 UI Dump/Trace/Debug/Flash；
- 宣称任何真实硬件支持；
- 修改 Core Requirement/AC；
- 捆绑 HDC 或自动更新。

## Impacted specifications

- Core behavior：none
- Platform profile：`openspec/platforms/macos/profile.md`
- Verification：`openspec/platforms/macos/verification.md`
- Baseline bump：no

## Safety, privacy, and compatibility

- Prototype 不自动 kill external HDC server；
- 不清除 quarantine、不重签外部工具；
- 测试 key 时不复制/记录私钥；
- 不执行真实 Flash/destructive step；
- Sandbox 不可行时记录 non-conformance 并选择非 Sandbox prototype，而非放宽 Core。

## Archive deferral（2026-07-20 注记）

本 change 自 2026-07-15 起 `verified`，暂不 archive：M0A 移交的 blocked 验证行
（`MAC-M0A-HDC-001`、`TRUST-001..004`、`SANDBOX-001`）与 ADR-0001 分发决策仍被
CHG-2026-002（M1）作为活跃输入引用。archive 时点＝上述移交项随 CHG-2026-002 收口
处置后，由独立 archive PR 裁量（先例 #21/#49/#87/#88）。本注记不改变 verified 结论
与任何 evidence。

