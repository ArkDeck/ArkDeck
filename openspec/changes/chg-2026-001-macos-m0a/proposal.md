---
id: CHG-2026-001-macos-m0a
status: approved # 2026-07-13 由维护者批准(V1 签名审批作废后按人类真实意图保留;见 planning/postmortem-2026-07-governance.md)
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

