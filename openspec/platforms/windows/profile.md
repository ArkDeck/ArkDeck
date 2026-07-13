# Windows Platform Profile

> ID：PLATFORM-WINDOWS  
> Version：0.1.0  
> Status：planned  
> Core baseline：CORE-1.0.0  
> Core strategy：native-conforming-shared-contract-vector-suite  
> Shared inputs：由每个 Task 固定 accepted Integration lock、profile 与 Core conformance hash  
> Conformance：notStarted

Windows 版是同一 ArkDeck 产品的另一个 Port。开发 Windows App 时只需决定并实现本文件中的工程细节；所有 Core Requirement、AC、schema 和 release gate 直接继承且 ID 不变。

## Permitted platform decisions

以下技术选择可在 Windows platform change/ADR 中确定：

- UI：WinUI 3 / Windows App SDK、WPF 或其他符合桌面需求的 native-compatible UI；
- 语言与运行时：.NET/C#、C++ 或可满足 contracts 的组合；
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
