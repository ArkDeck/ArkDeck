# Linux Verification Profile

> Status：planned / future  
> Core baseline：CORE-1.0.0  
> Shared inputs：由每个 Task 固定 accepted Integration lock、profile 与 Core conformance hash  
> Conformance：notStarted

Linux SHALL 执行与其他平台相同、hash 固定的 Core conformance suite，并增加 Linux Port、权限、desktop 与分发验证。当前状态不构成支持。

## Required platform suites

- `posix_spawn`/argv/no-shell/process-tree/timeout/cancel/large stream；
- per-user `flock` 单实例、stale file 和 D-Bus 主实例激活；
- logind inhibitor 引用计数、异常释放、sleep/wake 通知；
- mount/filesystem identity、mount path 变化、拔出/只读重挂/ENOSPC；
- XDG Portal 与 direct-path child HDC 文件访问；
- 无统一 trust verdict、package provenance、owner/mode/hash 的诚实状态映射；
- USB/UART udev/group allow/deny matrix，自动 sudo/rule mutation 次数为 0；
- journald/结构化日志脱敏、轮转和诊断导出；
- `CLOCK_BOOTTIME` 跨 suspend 继续、`CLOCK_MONOTONIC` 跨 suspend 暂停、wake 后 ETA reset；
- FileManager1 存在/缺失和多 desktop fallback；
- deb/rpm/AppImage/Flatpak/Snap 候选中的已选 release path、签名、升级/卸载和 clean-host smoke；
- `zh-Hans`/`en`、键盘、屏幕阅读器、Wayland/X11 和危险确认。

## Release condition

L0 只证明 feasibility。实现进度只由 Change/Task/run 表达，不创建 `implemented` 等额外 Platform lock 状态。Linux 只有在 accepted lock 中 exact Profile/release subject 的 `conformance_status` 为 `verified`、全部适用 Core/Safety AC 与平台 cases 在 Linux 上通过、分发包通过 clean-host smoke，且真实设备声明具备精确 hardware evidence 后才能发布。Windows/macOS evidence 不得替代 Linux Port evidence。

Release PCE 必须 exact 覆盖 `conformance-cases.yaml` 的平台 case/support cell，并固定 source commit、package artifact hash、distro/OS build、architecture、desktop/toolchain 与有效期。新增发行版、架构或包格式只扩展 Platform support matrix，不改 Core，但在独立证据通过前不得声称支持。
