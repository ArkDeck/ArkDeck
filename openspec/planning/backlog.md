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
- Sparkle 或其他自动更新；
- 完整源码级 ArkTS/C++ debugger；
- 第三方可执行 Profile/plugin 信任和签名生态；
- 组织级远程 Session/Artifact 存储；
- Journaled execution authority(JAUTH):pre-dispatch 人工确认以 typed journal
  event/append-chain 承载并由 dispatch gate 强制。CHG-2026-008 r3 初稿(PR #128
  `a613b76`)曾将其设为采集前置,经维护者 2026-07-20 裁剪移出;若产品化需要,须另起
  独立 Core MAJOR change(候选任务名 `TASK-JAUTH-CORE-001`,含 schema/validator/迁移/
  恢复/三平台 conformance 与新 baseline ratification),不得由 platform/integration
  change 顺手定义;
- `check_sdd.py` per-change scope 覆盖校验:当前 guard 只查 change artifact 结构与全局
  registry 三方一致,不校验"各任务 Requirements/AC 并集 == 该 change scope.yaml"。
  CHG-2026-002 的 AC-JOB-003/004 归属缺口(2026-07-20 pre-verify 审计发现,已追溯
  修复)即因此静默存在;增强 guard 可防复发。

Backlog 条目没有 Requirement/AC，不得被描述为 partial implementation。

## Pre-execution prerequisite（not backlog）

`AC-HDC-005-01`（parserGolden）已移出 M0A 范围：M0A `TASK-M0A-002` 只产出候选 fixture，该 AC 由后续 change（当前计划为 CHG-2026-002 的 TASK-M1-006）在 fixture 经审查落地后认领。不得由实现任务临时生成一个未审查 fixture 再给自己判 pass。
