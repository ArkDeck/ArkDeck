# Linux Platform Profile

> ID：PLATFORM-LINUX  
> Version：0.1.0  
> Status：planned / future（not supported, not releasable）  
> Core baseline：CORE-2.0.0  
> Core strategy：native-conforming-shared-contract-vector-suite  
> Shared inputs：由每个 Task 固定 accepted Integration lock、profile 与 Core conformance hash  
> Conformance：notStarted

Linux 是同一 ArkDeck 产品的 future Port，不是当前 macOS 交付范围。进入实现前必须先完成 L0 Spike；本 Profile 只锁定平台工程边界，不能构成“Linux 已支持”的声明。

## Permitted platform decisions

- UI/toolkit：GTK4/libadwaita、Qt 或其他可满足桌面可访问性与打包需求的方案；
- language/runtime：Rust、C++、JVM/.NET 或满足 language-neutral Core contract 的组合；
- distro baseline、Wayland/X11 集成、D-Bus 与 desktop portal 实现；
- deb/rpm/AppImage/Flatpak/Snap 的取舍、签名、repository 与更新机制；
- Linux 路径、桌面布局、系统日志和文件选择 UX。

选择不得改变 Core 状态、危险确认、失败/恢复语义或 AC。Core 的物理复用遵守 `architecture/core-portability.md`，不要求链接 Swift Core。

## Expected Port mapping

| Core Port | Linux 实现候选/约束 |
| --- | --- |
| ProcessExecutor | `posix_spawn`/`execve` 等价的绝对 executable + argv；分离 stdout/stderr；禁止 `/bin/sh -c`、`bash -c` 或字符串拼接 |
| SingleInstanceGuard | `$XDG_RUNTIME_DIR` 中 per-user lock + `flock`/等价内核锁；必须处理 stale file 而不把文件存在当锁 |
| AppActivationService | D-Bus well-known name/activation 或受控 local IPC；只激活持锁主实例 |
| PowerActivityController | logind `org.freedesktop.login1` inhibitor 或经验证等价机制；引用计数、全路径释放并如实声明合盖/显式 suspend 限制 |
| VolumeIdentityResolver | mount ID、filesystem UUID/device identity 与 `/proc/self/mountinfo`/udev 证据；不得按 mount path 字符串归组 |
| HostStorageProbe | `statvfs`/等价 API，处理 mount 消失、只读重挂与 ENOSPC |
| PersistentFileAccess | XDG Desktop Portal/Document Portal token 或非沙箱最小 POSIX 权限；Flatpak/Snap 不假定 host path 自动传给 child HDC |
| ToolTrustInspector | path/hash/owner/mode、package/repository/signature provenance（若可验证）；Linux 无统一 OS executable trust verdict 时必须显示 `unavailable/unverified`，不得显示 trusted |
| DeviceAccessAdvisor | 诊断 udev rule、seat/group、USB node 与 UART group；只给出 distro-specific 最小权限引导，不自动 sudo、不写 `/etc/udev/rules.d`、不 reload rules |
| SystemLogger | journald/syslog 或有界结构化本地日志；支持脱敏与显式诊断导出 |
| ElapsedDeadlineClock | `CLOCK_BOOTTIME` 或 contract test 证明 suspend 期间继续推进的等价时钟 |
| ActiveWorkClock | `CLOCK_MONOTONIC` 或 contract test 证明 suspend 期间暂停的等价时钟 |
| SleepWakeObserver | logind `PrepareForSleep`/等价通知；wake 后 journal、reconcile 和 ETA segment reset |
| PlatformFileRevealer | D-Bus `org.freedesktop.FileManager1.ShowItems`；不可用时明确 fallback 打开父目录，不假装已选中文件 |

候选 API 只有通过 Linux Port tests 后才能成为实现决定。

## Trust, USB and distribution boundary

- “可执行”权限位、root ownership 或来自系统 PATH 均不等于可信；无法验证 package provenance 时显示 hash 与 unverified 来源；
- udev rule/driver/group 调整是安装/运维动作，不由 ArkDeck 或自主 Agent 自动执行；不得要求全局 `chmod 777` 或以 root 运行整个 App；
- Flatpak/Snap 的 device/filesystem/socket 权限与 child HDC/server 行为必须端到端验证；沙箱不可行时选择经评审的非沙箱包，而不是放宽 Core；
- TCP HDC 继续遵守未验证保护/不可信网络提示，不因 Linux firewall 状态推断安全；
- package signature、repository metadata、SBOM 和 updater trust 属于 release profile。

## L0 Linux feasibility Spike

正式开发前至少覆盖：

- 选定 distro/desktop/architecture support matrix（候选 Ubuntu LTS + Fedora、x86_64/arm64）；
- Wayland/X11、D-Bus activation、FileManager1 与无该接口的桌面；
- DevEco/SDK HDC 和浏览器下载 HDC 的 path/hash/provenance/permission；
- 非 root USB、UART、udev/group 缺失及可恢复指导；
- direct package、AppImage、Flatpak/Snap child-process/server/device/file-access matrix；
- `CLOCK_BOOTTIME`/`CLOCK_MONOTONIC` sleep contract、logind inhibitor/notification；
- signed package/repository、升级/卸载、diagnostics 与 clean-host smoke。

## Forbidden Linux exceptions

Linux Profile/实现 SHALL NOT：

- 把 endpoint、USB node、`/dev/tty*` 或 mount path 当设备/卷身份；
- 因缺少 Gatekeeper/SmartScreen 等价物而把外部 HDC 默认标记 trusted；
- 自动安装 udev rule、driver、package，调用 sudo/pkexec，或降低全局设备权限；
- 用 shell 拼接、root App、沙箱豁免或 fake evidence 绕过 Core；
- 自动 kill external/unknown HDC server、自动重绑定 TCP/UART，或放宽 plan-only/recovery/journal；
- 修改 Core AC 使 Linux 未符合的实现通过。

不能满足 Core 时只能标记 `nonConformant`、blocked 或不发布该能力。
