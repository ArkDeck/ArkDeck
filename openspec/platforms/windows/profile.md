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
仍需维护者审查。Windows Server 2025 hosted CI 已运行契约、平台拒绝测试和 CLI 录制；
Windows 11 x64 上的完整 W0/SPK-3 与 DAYU200 验收仍未执行。Conformance 保持
`notStarted`，不构成 `supported` 或 release 声明，具体结果见下文 XPA-002 实现记录。

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
| ProcessExecutor | 绝对 executable；禁止 `cmd.exe /c`/PowerShell 字符串拼接。已定（2026-09-30）：`CreateProcessW` 按 argv 数组启动、kill-on-close Job object、不经 shell，见下文 [Windows 平台决定](#windows-平台决定2026-09-30)第 5 条 |
| SingleInstanceGuard | 必须按同一用户/产品隔离并处理 abandoned owner。已定（2026-09-30）：Named Mutex `Local\ArkDeck.Agentd.<user SID>` + `instance.lock` 上的 `LockFileEx` owner lock，见下文 Windows 平台决定第 2 条 |
| AppActivationService | Windows App SDK AppInstance/activation 或等价机制 |
| PowerActivityController | `PowerSetRequest`/Power Request 或等价 API；引用计数且全路径释放 |
| VolumeIdentityResolver | Volume GUID/serial/filesystem identity；不能按 drive letter/path 字符串归组。已定（2026-09-30）：持有句柄的 volume GUID（与 macOS `uuid:` 同一拼写）与 `FileIdInfo`，见下文 Windows 平台决定第 4 条 |
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

## Windows 平台决定（2026-09-30）

按 [Windows 阶段 Agent 提示](../../../docs/design/cross-platform/windows-phase-agent-prompt.md) §2.1
「和 profile 的 Port mapping 核对，并把平台决定记录下来」，本节登记截至 2026-09-30 已作出的
Windows 平台决定，每条指向其证据。上文 W0 段列为「后续任务与 §L.1 裁决范围」的事项，已裁决的
部分以本节为准。本节不声明任何支持或验证：Conformance 仍为 `notStarted`；所列 run record 均为
参考主机上的 host test 或 spike，不是 Windows 平台验收，也不是设备验收。Core Requirement、AC
与上文 Forbidden 清单不变。

证据目录缩写：`EV` = [`../../changes/chg-2026-074-shared-rust-runtime-core/evidence/`](../../changes/chg-2026-074-shared-rust-runtime-core/evidence/)；
「裁决 N」= [维护者 2026-09-30 裁决](../../changes/chg-2026-074-shared-rust-runtime-core/evidence/windows-maintainer-rulings-20260930.md)
第 N 条（#2343）。

1. **支持格：仅 Windows 11 x64。** ARM64 延后且不作支持声明；Windows 10 不支持；32 位 x86 不是
   目标。加入 ARM64 需另开 revision。证据：[CHG-2026-074 proposal](../../changes/chg-2026-074-shared-rust-runtime-core/proposal.md)
   Revision 13 第 1–2 条（修订 r12 decision 5 中 §L.1 item 9 的「x64 + ARM64」，#2342）。
2. **状态目录与单实例（SingleInstanceGuard）。**
   - 账户状态根 `%LOCALAPPDATA%\ArkDeck\Agentd`，由进程 token 的
     `SHGetKnownFolderPath(FOLDERID_LocalAppData)` 求得，不读 `LOCALAPPDATA` 环境变量（设计 §D.2）。
     新建的 `ArkDeck`、`Agentd` 为 owner-only（owner = 用户 SID，受保护 DACL 仅用户与 SYSTEM）；
     运行期间从盘符到状态根的各级目录以不共享删除的方式保持打开。
   - 已存在但 DACL 非 owner-only 的账户状态根：**拒绝启动**，启动消息与 `runtime service verify`
     指明目录与修复方法；daemon 从不改写已有 ACL（裁决 5）。
   - 跨登录会话互斥：`instance.lock` 上 `LockFileEx(EXCLUSIVE | FAIL_IMMEDIATELY)`，锁定数据区之外的
     单字节；持有者死亡即由内核释放。
   - 会话内单实例：Named Mutex `Local\ArkDeck.Agentd.<user SID>`，显式 DACL，owner 非用户 SID 或
     无法打开即拒绝启动；`WAIT_ABANDONED` 记一行后按崩溃后启动处理，不视为干净交接。选 `Local\`
     而非 `Global\`，以免其他账户预建同名对象造成跨账户拒绝服务；跨会话互斥由 owner lock 承担。
   - 停止源：每实例的 manual-reset event `<guard 名>.Stop.<pid>`（owner-only DACL）及
     Ctrl+C/Ctrl+Break；停止请求只在同一登录会话内有效（裁决 4）。停止后按 `serve_control` 的
     drain（20 s 期限）结束；drain 未完成则持有 guard 退出，让后继看到 abandoned。
   - 端点：`\\.\pipe\arkdeck-agentd-<logon SID>`；同账户抢占者占用该名时（Win32 5 或 231）
     fail closed，报告「held by another instance」。客户端第二层服务端认证可用：SPK-3 实测
     `GetNamedPipeServerProcessId` 在 `CreateFileW` 客户端句柄上返回本连接的服务端 PID（PASS）。
   - 证据：`EV/runs/TASK-XPA-002/windows-daemon-lifecycle-run.md`、`EV/runs/TASK-XPA-002/pipe-busy-squat-run.md`、
     `EV/runs/TASK-XPA-002/spk-3-20260930-run.md`。SPK-3 的签名 daemon、第二账户、提权、远端与 MSIX
     各行仍为 `NOT_RUN` 或设计内拒绝，本条不以其为通过。
3. **由客户端启动 daemon（proposal r12 decision 5 中 §L.1 item 11）与 Windows 上的
   `runtime service`。** Windows 没有 launchd；daemon 由其客户端启动、单实例（裁决 10 把
   launchd 对应到 client-started daemon）。实现选择（**待 #2344 合并**，其 run record
   `EV/runs/TASK-XPA-002/client-started-daemon-run.md` 目前只在分支
   `agent/xpa-002-client-started-daemon-20260930` 上，除账户根 DACL 一行即裁决 5 外，均为待维护者
   审查的提议）：
   - 仅当 daemon 的 pipe 不存在时启动；私有 `ARKDECK_ENDPOINT` 不启动。并发启动者依次取
     `Local\<scope>.Start` 互斥量后再看一次 pipe；daemon 自身的单实例 guard 仍是唯一权威。
   - 启动前按文件校验钉住的映像（`ARKDECK_DAEMON_PATH` 或 CLI 同目录，绝对路径、非 reparse
     point、钉住签名者的 Authenticode）；package family 只能在运行进程上证明，故延后到连接时。
     映像及其各级目录在 `CreateProcessW` 返回前保持打开且不共享写/删除。
   - 以 `DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP | CREATE_NO_WINDOW`、不继承句柄、映像本身
     作为唯一 argv 启动；有界等待 pipe；随后执行与每次连接相同的身份校验，失败报告
     `identityRefused` 与 PID，从不信任。启动过程不发送任何帧，丢失的请求从不重放。
   - `runtime service status|verify|restart` 在 Windows 上沿用 macOS 的信封与退出码
     （`daemonService` 对应 `launchAgent`）；`restart` 经 stop event 与有界 guard 获取实现；
     `install`/`update`/`uninstall` 为 `unsupportedOnPlatform`。
4. **持久化原语（PersistentFileAccess / VolumeIdentityResolver 相关的 host store）。** NTFS 上：
   - 原子替换 = POSIX 语义 rename（`FileRenameInformationEx`，`POSIX_SEMANTICS`
     [+ `REPLACE_IF_EXISTS`]，相对目录句柄），**不用 `MoveFileExW`**：后者在任一读者持有目标时失败
     （Win32 5）。Runtime 打开的每个可替换文件句柄都带 `FILE_SHARE_DELETE`，缺少时替换 fail closed。
   - 锁只加在专用锁文件上：`LockFileEx` 在 NTFS 上是强制锁且按句柄生效，锁定范围放在数据区之外；
     同一进程不得经两个句柄取同一锁。
   - 目录持久化需要以 `GENERIC_WRITE` 打开的目录句柄做 `FlushFileBuffers`（只读句柄为 Win32 5）。
   - 文件身份 = `FileIdInfo`（volume serial + file id），对应 Unix 的 (dev, ino)；卷身份为持有句柄的
     volume GUID，从不用盘符。
   - torn-tail 规则不变：进程被杀后所见均为字节前缀，现有 replay 切分与截断修复在 NTFS 上成立。
   - 证据：`EV/runs/TASK-XPA-005/spk-5-20260930-run.md`（SPK-5 go；断电/OS 崩溃与系统卷上的复测
     未覆盖）、`EV/runs/TASK-XPA-005/ntfs-host-store-run.md`。
5. **进程执行（ProcessExecutor）。** `CreateProcessW` 按 argv 数组启动（从不经 `cmd.exe`/PowerShell），
   以挂起态创建、分配到 kill-on-close Job object、证明映像为所保留的已验证文件后再恢复；基础环境仅
   `PATH`/`SystemRoot`/`WINDIR` 加受校验的覆盖项（不得覆盖这三项或 `__COMPAT_LAYER`）；`NUL` stdin；
   超时与取消以 `TerminateJobObject` 结束整棵子进程树，与 macOS 先 TERM 后 KILL 进程组按 T1 等同
   （裁决 2）。证据：`EV/runs/TASK-XPA-005/windows-tool-dispatch-run.md`（#2341，仅用 fake tool，
   daemon 尚未组装这些 Windows owner）。
6. **不读 argv 的 HDC server 证明（裁决 1）。** 仅当 server 由本 daemon 实例启动、仍在该实例的 Job
   object 内，且已验证工具的映像路径与 SHA-256、进程创建时间和确切的 loopback 监听都相符时，才算
   **managed**；其余一律 **external**，从不接管或停止（fail closed；daemon 重启后前一实例的 server
   视为 external）。不使用跨重启的命名 Job，不读未公开的命令行。另：映像被改名移走报 `NotFound`，
   无法打开的监听 owner 使证明为 `PermissionDenied`（裁决 3）。实现与证据同上（#2341）。
7. **USB census 映射（DeviceAccessAdvisor / Target observation 相关；CHG-2026-078 TASK-WHR-003）。**
   只读 SetupAPI census，不静默提权、不装 driver、不改系统策略。各字段依据维护者 2026-10-04 的
   DAYU200 USB 属性采样（`EV/runs/TASK-XPA-004/dayu200-usb-properties-20261004-run.md` 及同名目录下
   的 sanitized `usb-*.json`；下称“采样记录”）与维护者裁决 2026-10-04 第 4、5 项
   （[CHG-2026-078](../../changes/chg-2026-078-windows-hdc-registration/design.md) §4）：
   - **条目 = 在场的设备级节点。** `USB` 枚举器下 `USB\VID_xxxx&PID_xxxx\<后缀>`（无 `&MI_xx`）且
     在场的节点；接口节点（如有）归入其设备、从不计数。不在场的 phantom 节点保留上次 attachment 的
     陈旧属性，从不成为条目（采样记录 “Nodes the board creates”：phantom `PID_350A` loader 节点）。
   - **VID/PID** 取 `DEVPKEY_Device_HardwareIds`，按十六进制解析为与 macOS 相同的数值
     （采样记录 mapping 表 `idVendor`/`idProduct` 行）。
   - **serial 与身份。** instance ID 第三段为 serial。含 `&` 的后缀为 Windows 生成的端口派生 ID：
     无 serial、无身份，fail closed。其余后缀先做**显式 ASCII 小写折叠**再与 HDC connect key 比较或
     用作身份 serial；connect key 本身不改写。长期设备身份 = 折叠后的 serial（与已小写化的
     `stable_identity_sha256_for_serial` 一致）。采样中后缀为 32 位大写十六进制、connect key 为
     小写，仅在折叠后相等（采样记录 “Serial and the connect key”）。
   - **attachment = (instance ID, `DEVPKEY_Device_LastArrivalDate`)。** 两者单独都不构成 attachment；
     instance ID 与 `PDOName` 跨 attachment 重复，`LastArrivalDate` 每次接入都更新、单次接入内不变；
     缺失或为零的 arrival 不形成 relation（采样记录 mapping 表 attachment 行）。
   - **topology 仅在单个 attachment 内有效。** topology = 首个 `DEVPKEY_Device_LocationPaths` 条目
     SHA-256 前 8 字节（大端）的十进制，从不等于 macOS 值（裁决 11）；它不进入长期身份。采样中同一
     物理接口重插后从 `USB(10)`/`HS10` 变为 `USB(26)`/`SS10`，`LocationInfo`、地址与 `ContainerId`
     同样改变（采样记录 “Topology”）；因此 USB 2→USB 3 重新枚举是同一设备身份、新的 attachment。
   - **产品名** 取 `DEVPKEY_Device_BusReportedDeviceDesc`（采样为带双引号的 `"HDC Device"`，与 macOS
     fixture 相同）；`FriendlyName`/`DeviceDesc` 为 INF 文本，不作设备事实。
   - **driver** 记录 `DEVPKEY_Device_Service`（采样为 `WINUSB`），从不修改。
   早先无板的 host-only census 见 `EV/runs/TASK-XPA-004/windows-usb-census-run.md`。
8. **MSIX 关闭写虚拟化（裁决 8）。** 包声明 `unvirtualizedResources`，关闭文件系统与注册表写虚拟化，
   使 App、daemon 与 xcopy 形态的 CLI 共用同一物理 `%LOCALAPPDATA%\ArkDeck\Agentd`。分发形态本身
   （MSIX 打包 + self-contained Windows App SDK，Azure Artifact Signing，App Installer 更新，
   daemon/CLI 另有 xcopy 形态）见 proposal r12 decision 5 中 §L.1 item 10。
9. **开发期 daemon 身份（proposal r12 decision 6，§L.1 item 22）。** 维护者在参考主机上创建仅本机信任
   的开发代码签名证书；客户端经 `ARKDECK_DAEMON_SIGNER_SHA256` 钉住签名者，daemon 位于钉住的路径；
   CI 在 hosted runner 上以临时自签证书测正向路径。永不添加跳过身份校验的开关（XPA-AC-6、设计 §F.2
   不变）。开发 MSIX publisher 为 `CN=ArkDeck Development`，仅主机信任；客户端代码位于 `windows/`
   （裁决 12）。
10. **客户端技术栈与 UI 风格。** 目标栈 WinUI 3 + Windows App SDK 2.5.1 + .NET 10（当日最新稳定版；
    WinUI alpha 项目模板已接受），Fluent 2 风格，产品语义取自
    [`docs/design/arkdeck-ds/src/tokens.css`](../../../docs/design/arkdeck-ds/src/tokens.css)（维护者裁决
    记录末段）。**SPK-4（WinUI 3 vs WPF，设计 §H.4）尚未运行**，其前置条件见
    `EV/runs/TASK-XPA-007/spk-4-prerequisites-crib-20260930.md`；只有某项标准失败且在两周内无法修复时，
    同一 harness 才对 WPF（.NET 10 Fluent）shell 再运行（`tasks.md` SPK-4 行）。

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
