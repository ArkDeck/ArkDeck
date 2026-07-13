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
- 组织级远程 Session/Artifact 存储。

Backlog 条目没有 Requirement/AC，不得被描述为 partial implementation。

## Pre-execution prerequisite（not backlog）

M0A `TASK-M0A-002` 的 `AC-HDC-005-01` 需要真实采集、脱敏、审查并 hash-pinned 的 exit-zero semantic-failure golden fixture。当前 Integration lock 与 Conformance fixtures 为空，所以该 Task 保持 draft。治理 bootstrap 后应先建立独立 Integration fixture change；不得由实现 Task 临时生成一个未批准 fixture 再给自己判 pass。
