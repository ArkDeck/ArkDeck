# Windows Platform Profile

> ID：PLATFORM-WINDOWS  
> Version：0.2.0
> Status：planned  
> Core baseline：CORE-2.0.0  
> Core strategy：shared-rust-runtime-native-ui-shared-contract-vector-suite
> Strategy status：proposed by CHG-2026-074; pending maintainer PR review
> Shared inputs：由每个 Task 固定 accepted Integration lock、profile 与 Core conformance hash  
> Conformance：notStarted

Windows 版是同一 ArkDeck 产品的另一个 Port。开发 Windows App 时只需决定并实现本文件中的工程细节；所有 Core Requirement、AC、schema 和 release gate 直接继承且 ID 不变。

## XPA-002 / W0 preparation

0.2.0 登记 [CHG-2026-074](../../changes/chg-2026-074-shared-rust-runtime-core/proposal.md)
提出的共享 Rust Runtime 目标和 [Windows 验收骨架](conformance-cases.yaml)，本次 PR
仍需维护者审查。W0/SPK-3 目前只有实现、脚本和用例准备；这里没有 Windows 原生执行
或 DAYU200 结果，Conformance 保持 `notStarted`，不构成 `supported` 或 release 声明。

目标为 `arkdeck-agentd` 经用户私有 named pipe 服务原生客户端。当前基础仅有 `doctor`、
`operation list`、`device candidates` 的 CLI/IPC 只读路径；Catalog operation 全部报告
`unavailable`。Windows HDC tool tuple 与输出 family 尚未注册，因此当前不执行 HDC。
实际边界、Swift 开发基线和缺口见
[XPA-002 实现记录](../../changes/chg-2026-074-shared-rust-runtime-core/evidence/xpa-002-readonly-foundation.md)。

SPK-3 须在真实 Windows 11 x64 上验证 `CreateFileW` 客户端句柄的 server PID、双方
SID/elevation 和服务端安装映像/签名或 package identity。正向连接需要实际受信 daemon
安装；跨账户、提权、远端和 package 用例分别需要第二账户、独立提权终端、另一台主机
及已注册 package。缺少条件时用例保持 `NOT_RUN`；客户端 API 不可用时当前实现零帧
拒绝，不能因此声称 API 已通过或降低原 AC。随后还需经审查注册的 Windows HDC tuple、
真实输出采样与 Windows 11 x64 + DAYU200 的只读链路验收。

WinUI、安装/升级、签名分发、daemon 生命周期和 ARM64 支持格属于后续任务与
[设计 §L.1](../../../docs/design/cross-platform/rust-core-cross-platform-architecture.md#l1-需要维护者裁决ai-不得自行宣称批准)
的裁决范围；本骨架没有替这些事项作决定或扩大 XPA-002 的实现范围。

## Permitted platform decisions

以下技术选择可在 Windows platform change/ADR 中确定：

- UI：WinUI 3 / Windows App SDK、WPF 或其他符合桌面需求的 native-compatible UI；
- 客户端语言与运行时：.NET/C#、C++ 或可满足 contracts 的组合；共享 Core Runtime 按上文待审查的 Rust 目标迁移；
- 进程、线程、async 和 IPC 实现；
- 安装器、MSIX/非 MSIX 分发、签名和更新框架；
- Windows 路径、窗口布局、系统日志和文件选择 UX。

选择不得改变可观察状态、危险确认、失败语义或 AC。

## Expected Port mapping

| Core Port | Windows 实现候选/约束 |
| --- | --- |
| ProcessExecutor | `ProcessStartInfo.ArgumentList` 或 Win32 argv 等价；绝对 executable；禁止 `cmd.exe /c`/PowerShell 字符串拼接 |
| SingleInstanceGuard | Named Mutex 或等价内核对象；必须按同一用户/产品隔离并处理 abandoned owner |
| AppActivationService | Windows App SDK AppInstance/activation 或等价机制 |
| PowerActivityController | `PowerSetRequest`/Power Request 或等价 API；引用计数且全路径释放 |
| VolumeIdentityResolver | Volume GUID/serial/filesystem identity；不能按 drive letter/path 字符串归组 |
| HostStorageProbe | Windows volume free-space API、removable volume change/ENOSPC 映射 |
| PersistentFileAccess | 文件选择器和跨启动 token/bookmark 等价；最小读写权限 |
| ToolTrustInspector | Authenticode、hash、Zone.Identifier/Mark-of-the-Web、SmartScreen/来源状态；不自动解除阻止 |
| DeviceAccessAdvisor | USB/UART driver、设备状态与权限诊断；不静默提权、安装 driver 或改系统策略 |
| SystemLogger | ETW/Event Log 或有界结构化日志；支持隐私和诊断导出 |
| ElapsedDeadlineClock | 选择经 contract test 证明系统睡眠期间继续推进的 Windows 单调源（候选如 `GetTickCount64`）；wall time 只用于审计和跨进程 fail-safe reconcile |
| ActiveWorkClock | 选择经 contract test 证明系统睡眠期间暂停的单调源（候选如 unbiased interrupt time）；只计算 active duration/throughput/ETA，wake 后新建 sample segment |
| SleepWakeObserver | Power/session notification；唤醒后 journal + reconcile + throughput/ETA reset |
| PlatformFileRevealer | Explorer reveal |

候选 API 不是 Core 要求；如果实现语言不同，应选择语义等价的 API。

## Mandatory shared assets

Windows SHALL 复用或生成自同一来源：

- `manifest.schema.json`、`journal-event.schema.json` 与 `workflow-step.schema.json`；
- Job/terminal/effect/cancellation/recovery contract tests；
- HDC/parser golden fixtures；
- Dump Recipe、Trace preset 和 Debug parameter catalogs；
- Requirement/AC ID 和 traceability；
- privacy、localization、risk copy 的语义基线。

## Forbidden Windows exceptions

Windows profile 或实现 SHALL NOT：

- 新建替代 Core 状态机或重编号 Requirement；
- 因 drive letter、COM port 或 IP:port 稳定而把 endpoint 当身份；
- 自动重绑定 TCP/UART；
- 自动 kill external/unknown HDC server；
- 把授权显示为 encrypted；
- 使用 `cmd.exe /c` 或 PowerShell 拼接用户/设备输入；
- 放宽 plan-only、simulation、journal、critical cancellation 或 recovery gate；
- 修改 Core AC 使未符合的 Windows 实现通过；
- 用 fake/simulation 替代真实设备 evidence。

## Windows trust and distribution Spike

正式开发前应建立与 macOS M0A 对称的 Spike：

- DevEco/SDK HDC、浏览器下载工具、带/不带 Mark-of-the-Web、可信/未知 Authenticode；
- Defender/SmartScreen 行为和用户引导；
- USB/UART driver 与非管理员权限；
- HDC server 端口、防火墙、TCP 风险提示；
- 外部镜像、key 和输出目录；
- 安装、升级、卸载、日志和 crash diagnostics；
- 签名发布包与干净 Windows 主机 smoke。

如果平台无法满足 Core Safety Requirement，结论只能是 `nonConformant`、blocked 或不发布该能力。
