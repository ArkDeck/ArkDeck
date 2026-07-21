# Backlog

以下项目不属于当前 Core/MVP 执行范围。进入开发前必须创建独立 change，不得顺手加入现有 Task。

- FaultLoggerd/HiviewDFX crash、Rust panic、AppFreeze、coredump/minidump/active stack artifacts；
- HDC `bugreport` / system diagnostic snapshot；
- 完整 PTY/VT100 交互终端；
- 内嵌 SmartPerf/Trace Streamer 时间线；
- Bundled HDC fallback；
- HDC subserver 自动管理；
- Fastboot、Rockchip/upgrade_tool 和厂商 Provider；
- Remote crash upload / telemetry；
- Sparkle 或其他自动更新(**2026-07-21 经 DEC-004 决定纳入 v1 更新渠道**,
  ADR-0002;进入开发仍须独立 change 评估框架/XPC/签名链/隐私披露/网络面,该
  change verified 前手动公证 DMG 为过渡通道)；
- 完整源码级 ArkTS/C++ debugger；
- 第三方可执行 Profile/plugin 信任和签名生态；
- 组织级远程 Session/Artifact 存储；
- 组织级脱敏策略层(MDM/managed-config 强制 redact、可插拔脱敏类别;DEC-006 决定
  MVP 不设,启用须独立 change)；
- Journaled execution authority(JAUTH):pre-dispatch 人工确认以 typed journal
  event/append-chain 承载并由 dispatch gate 强制。CHG-2026-008 r3 初稿(PR #128
  `a613b76`)曾将其设为采集前置,经维护者 2026-07-20 裁剪移出;若产品化需要,须另起
  独立 Core MAJOR change(候选任务名 `TASK-JAUTH-CORE-001`,含 schema/validator/迁移/
  恢复/三平台 conformance 与新 baseline ratification),不得由 platform/integration
  change 顺手定义;

Backlog 条目没有 Requirement/AC，不得被描述为 partial implementation。

## Pre-execution prerequisite（not backlog）

`AC-HDC-005-01`（parserGolden）已移出 M0A 范围：M0A `TASK-M0A-002` 只产出候选 fixture，该 AC 由后续 change（当前计划为 CHG-2026-002 的 TASK-M1-006）在 fixture 经审查落地后认领。不得由实现任务临时生成一个未审查 fixture 再给自己判 pass。
